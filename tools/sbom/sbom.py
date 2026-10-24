#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""CycloneDX SBOM and vulnerability gate for nyra-base (docs/SBOM.md).

usage: sbom.py [--iso [--arch amd64|arm64]] MANIFEST CARGO_LOCK SBOM_OUT [CARGO_LOCK...]
  MANIFEST    mkosi JSON manifest (exact Debian package versions)
  CARGO_LOCK  bootc's Cargo.lock (the Rust crates compiled into bootc); after SBOM_OUT, the
              Cargo.lock of other Rust code the image build compiles (zlib-rs); a crate in several
              counts once
  SBOM_OUT    CycloneDX 1.6 JSON written here
--iso: the installer ISO (docs/ISO.md) instead of the image. MANIFEST is the manifest of the installer
system, CARGO_LOCK the Cargo.lock of nyra-installer, whose commit is iso/installer-commit; no bootc or
pam-totp. The same scan, with its own exceptions, tools/sbom/mitigations-iso.toml: an exception of the
image never applies to the ISO, nor one of the ISO to the image.
--iso --arch arm64: the aarch64 installer ISO. MANIFEST is the manifest of its installer system (Debian
unstable, arm64, from the arm64 Packages index), the packages iso/mkosi.conf lists with the architecture's
name for the kernel (linux-image-arm64), and its own exceptions, tools/sbom/mitigations-iso-arm64.toml: the
file of the x86_64 ISO never applies to it, nor this one to the x86_64 ISO or the image.
Environment (not with --iso): BOOTC_REF, BOOTC_COMMIT. Snapshot and repositories come from mkosi/mkosi.conf, the
commit of pam-totp (built into the image from its own repository) from pam-totp/commit.

Writes the SBOM, then prints a Markdown report and exits 1 if a vulnerability blocks the build:
critical, high or unknown severity, not marked unimportant by Debian, and not listed in
tools/sbom/mitigations.toml with a reason and an expiry date at most 90 days ahead.
An entry matches by ID or any OSV alias; duplicates refuse the file; entries that no longer
block are reported for removal. Offline tests: tools/sbom/test_sbom.py.
"""
import datetime
import gzip
import json
import lzma
import os
import re
import subprocess
import sys
import time
import tomllib
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

from cvss import CVSS2, CVSS3, CVSS4

HERE = os.path.dirname(os.path.abspath(__file__))
MKOSI_CONF = os.path.join(HERE, "..", "..", "mkosi", "mkosi.conf")
MITIGATIONS = os.path.join(HERE, "mitigations.toml")
MITIGATIONS_ISO = os.path.join(HERE, "mitigations-iso.toml")
MITIGATIONS_ISO_ARM64 = os.path.join(HERE, "mitigations-iso-arm64.toml")
PAM_TOTP_COMMIT = os.path.join(HERE, "..", "..", "pam-totp", "commit")
INSTALLER_COMMIT = os.path.join(HERE, "..", "..", "iso", "installer-commit")
ISO_MKOSI_CONF = os.path.join(HERE, "..", "..", "iso", "mkosi.conf")
TRACKER = "https://security-tracker.debian.org/tracker/data/json"
OSV = "https://api.osv.dev/v1"
BLOCKING = ("critical", "high", "unknown")
MAX_DAYS = 90
# The image has no dpkg database (docs/LESSONS.md), so the build cannot ask dpkg for a version: the
# manifest is where versions are checked. Image only. polkitd 128-1 has the fix for CVE-2026-85498 in the
# password helper, whose socket is on (docs/DEFAULTS.md, "Passwords through polkit").
MINIMUM_VERSIONS = {"polkitd": "128-1"}


def fetch(url, data=None):
    headers = {"User-Agent": "nyra-base-sbom", "Accept-Encoding": "gzip"}
    if data is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(data).encode()
    for attempt in range(3):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, data, headers), timeout=120) as r:
                body = r.read()
                return gzip.decompress(body) if r.headers.get("Content-Encoding") == "gzip" else body
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            if attempt == 2:
                raise
        except OSError:
            if attempt == 2:
                raise
        time.sleep(5 * (attempt + 1))


# Debian version comparison (deb-version(7)), as dpkg --compare-versions.
def _order(c):
    if c == "~":
        return -1
    if c.isdigit():
        return 0
    return ord(c) if c.isalpha() else ord(c) + 256


def _cmp_part(a, b):
    while a or b:
        ra, rb = re.match(r"\D*", a).group(), re.match(r"\D*", b).group()
        a, b = a[len(ra):], b[len(rb):]
        for i in range(max(len(ra), len(rb))):
            x = _order(ra[i]) if i < len(ra) else 0
            y = _order(rb[i]) if i < len(rb) else 0
            if x != y:
                return -1 if x < y else 1
        na, nb = re.match(r"\d*", a).group(), re.match(r"\d*", b).group()
        a, b = a[len(na):], b[len(nb):]
        if int(na or 0) != int(nb or 0):
            return -1 if int(na or 0) < int(nb or 0) else 1
    return 0


def version_cmp(a, b):
    def split(v):
        epoch, _, rest = v.partition(":") if ":" in v else ("0", "", v)
        upstream, _, revision = rest.rpartition("-") if "-" in rest else (rest, "", "0")
        return int(epoch), upstream, revision
    (ea, ua, ra), (eb, ub, rb) = split(a), split(b)
    if ea != eb:
        return -1 if ea < eb else 1
    return _cmp_part(ua, ub) or _cmp_part(ra, rb)


def severity(vuln_ids):
    """Highest CVSS base severity in the first OSV record that has one; 'unknown' if none."""
    for vid in vuln_ids:
        body = fetch(f"{OSV}/vulns/{vid}")
        record = json.loads(body) if body else {}
        scores = []
        for s in record.get("severity", []):
            calc = {"CVSS_V2": CVSS2, "CVSS_V3": CVSS3, "CVSS_V4": CVSS4}.get(s["type"])
            if calc:
                scores.append(float(calc(s["score"]).base_score))
        if scores:
            top = max(scores)
            return top, "critical" if top >= 9 else "high" if top >= 7 else "medium" if top >= 4 else "low"
    return None, "unknown"


def mkosi_setting(key):
    return re.search(rf"^{key}=(.*)$", open(MKOSI_CONF).read(), re.M).group(1).strip()


# The architectures: Debian's name (the Packages index, the package list) and mkosi's.
ARCHES = {"amd64": "x86-64", "arm64": "arm64"}


def debian_sources(manifest, snapshot, arch="amd64"):
    """Map each binary package to its source package and source version (Packages index)."""
    cfg = manifest["config"]
    if (cfg["distribution"], cfg["release"], cfg["architecture"]) != ("debian", "unstable", ARCHES[arch]):
        sys.exit(f"sbom.py: only Debian unstable {ARCHES[arch]} is supported here, not {cfg}")
    # The scan matches Debian packages from this list, never from the image's os-release (which names
    # Nyra OS): an empty list would scan nothing and pass.
    if not manifest["packages"]:
        sys.exit("sbom.py: the manifest lists no Debian packages")
    index = {}
    for component in mkosi_setting("Repositories").split(","):
        url = f"https://snapshot.debian.org/archive/debian/{snapshot}/dists/unstable/{component}/binary-{arch}/Packages.xz"
        for para in lzma.decompress(fetch(url)).decode().split("\n\n"):
            f = dict(re.findall(r"^(Package|Version|Architecture|Source): (.*)$", para, re.M))
            if f:
                index[f["Package"], f["Version"], f["Architecture"]] = f.get("Source", f["Package"])
    out = []
    for p in manifest["packages"]:
        source = index.get((p["name"], p["version"], p["architecture"]))
        if source is None:
            sys.exit(f"sbom.py: {p['name']} {p['version']} {p['architecture']} is not in the snapshot's Packages index")
        name, _, version = source.partition(" ")
        out.append((p, name, version.strip("()") or p["version"]))
    return out


def check_minimum_versions(manifest):
    """Exit if a package of MINIMUM_VERSIONS is missing from the manifest or older than its minimum."""
    versions = {p["name"]: p["version"] for p in manifest["packages"]}
    for name, minimum in MINIMUM_VERSIONS.items():
        if name not in versions:
            sys.exit(f"sbom.py: {name} is not in the manifest (it must be {minimum} or newer)")
        if subprocess.run(["dpkg", "--compare-versions", versions[name], "ge", minimum]).returncode != 0:
            sys.exit(f"sbom.py: {name} {versions[name]} is older than {minimum}")


def write_sbom(path, snapshot, debs, crates, applications, name, description):
    """applications: the programs built from their own repositories, as (name, version, purl)."""
    q = lambda s: urllib.parse.quote(s, safe="")
    components = [{"type": "application", "bom-ref": n, "name": n, "version": v, "purl": purl} for n, v, purl in applications]
    for p, src, src_version in debs:
        upstream = src if src_version == p["version"] else f"{src}@{src_version}"
        purl = f"pkg:deb/debian/{p['name']}@{q(p['version'])}?arch={p['architecture']}&distro=sid&upstream={q(upstream)}"
        components.append({"type": "library", "bom-ref": purl, "name": p["name"], "version": p["version"], "purl": purl})
    for c in crates:
        purl = f"pkg:cargo/{c['name']}@{q(c['version'])}"
        if not c["source"].startswith("registry+"):
            purl += f"?vcs_url={q(c['source'])}"
        components.append({"type": "library", "bom-ref": purl, "name": c["name"], "version": c["version"], "purl": purl})
    created = datetime.datetime.strptime(snapshot, "%Y%m%dT%H%M%SZ").strftime("%Y-%m-%dT%H:%M:%SZ")
    bom = {
        "bomFormat": "CycloneDX", "specVersion": "1.6", "version": 1,
        "metadata": {
            "timestamp": created,
            "tools": {"components": [{"type": "application", "name": "nyra-base tools/sbom/sbom.py"}]},
            "component": {
                "type": "operating-system", "bom-ref": name, "name": name, "version": snapshot,
                "description": description.format(snapshot=snapshot),
            },
        },
        "components": components,
    }
    with open(path, "w") as f:
        json.dump(bom, f, indent=1, sort_keys=True)
        f.write("\n")
    return len(components)


def debian_findings(debs):
    tracker = json.loads(fetch(TRACKER))
    findings, unimportant = [], 0
    for src, version in sorted({(s, v) for _, s, v in debs}):
        for vid, info in tracker.get(src, {}).items():
            sid = info.get("releases", {}).get("sid")
            if not sid:
                continue
            fixed = sid.get("fixed_version") if sid["status"] == "resolved" else None
            if fixed and version_cmp(version, fixed) >= 0:
                continue
            if sid["urgency"] == "unimportant":
                unimportant += 1
                continue
            findings.append({"id": vid, "package": src, "version": version, "fixed": fixed,
                             "debian_high": sid["urgency"] == "high",
                             "ids": {vid}, "osv": [f"DEBIAN-{vid}"] + ([vid] if vid.startswith("CVE-") else []),
                             "about": info.get("description", "")})
    return findings, unimportant


def crate_findings(crates):
    registry = [c for c in crates if c["source"].startswith("registry+")]
    queries = [{"package": {"name": c["name"], "ecosystem": "crates.io"}, "version": c["version"]} for c in registry]
    results = json.loads(fetch(f"{OSV}/querybatch", {"queries": queries}))["results"]
    findings = []
    for c, res in zip(registry, results):
        for v in res.get("vulns", []):
            record = json.loads(fetch(f"{OSV}/vulns/{v['id']}"))
            info = [a.get("database_specific", {}).get("informational") for a in record["affected"]]
            findings.append({"id": v["id"], "package": c["name"], "version": c["version"], "fixed": None,
                             "ids": {v["id"], *record.get("aliases", [])},
                             "debian_high": False, "osv": [v["id"]], "about": record.get("summary", ""),
                             "informational": next((i for i in info if i), None)})
    # OSV aliases are not always listed both ways: findings of one crate that share an ID share all IDs.
    for f in findings:
        for g in findings:
            if f["package"] == g["package"] and f["ids"] & g["ids"]:
                f["ids"] |= g["ids"]
                g["ids"] = f["ids"]
    return findings


def load_mitigations(today, path):
    name = f"tools/sbom/{os.path.basename(path)}"
    entries = tomllib.load(open(path, "rb")).get("mitigation", [])
    out = {}
    for e in entries:
        ok = all(isinstance(e.get(k), str) and e[k].strip() for k in ("id", "package", "reason"))
        if not ok or type(e.get("expires")) is not datetime.date:
            sys.exit(f"sbom.py: {name}: each entry needs id, package, reason and expires (a date): {e}")
        if (e["expires"] - today).days > MAX_DAYS:
            sys.exit(f"sbom.py: {name}: {e['id']} expires more than {MAX_DAYS} days ahead; review it closer to the date")
        if (e["id"], e["package"]) in out:
            sys.exit(f"sbom.py: {name}: {e['id']} ({e['package']}) is listed twice")
        out[e["id"], e["package"]] = e
    return out


def main():
    iso = sys.argv[1:2] == ["--iso"]
    args = sys.argv[2:] if iso else sys.argv[1:]
    arch = "amd64"
    if args[:1] == ["--arch"]:
        if not iso or args[1:2] not in (["amd64"], ["arm64"]):
            sys.exit("sbom.py: --arch amd64|arm64 goes after --iso (the image is x86_64)")
        arch, args = args[1], args[2:]
    manifest_path, lock_path, sbom_path = args[:3]
    snapshot = mkosi_setting("Snapshot")
    today = datetime.datetime.now(datetime.UTC).date()
    manifest = json.load(open(manifest_path))
    crates = {}
    for path in [lock_path, *args[3:]]:
        for p in tomllib.load(open(path, "rb"))["package"]:
            if "source" in p:
                crates.setdefault((p["name"], p["version"], p["source"]), p)
    crates = list(crates.values())
    debs = debian_sources(manifest, snapshot, arch)
    if not iso:
        check_minimum_versions(manifest)
    def commit_of(path):
        commit = open(path).read().strip()
        if not re.fullmatch(r"[0-9a-f]{40}", commit):
            sys.exit(f"sbom.py: {path} is not a commit: {commit!r}")
        return commit

    if iso:
        # No silent empty scan: every package the ISO is configured with is in the manifest, and the
        # installer program has crates, all from the registry (a git source is not pinned by a checksum).
        block = re.search(r"^Packages=\s*\n((?:[ \t]+\S+\n)+)", open(ISO_MKOSI_CONF).read(), re.M)
        wanted = set(block.group(1).split()) if block else set()
        # iso/mkosi.conf is the x86_64 one: the kernel is named after the architecture (ci/build-iso-os.sh).
        wanted = {w.replace("linux-image-amd64", f"linux-image-{arch}") for w in wanted}
        missing = sorted(wanted - {p["name"] for p in manifest["packages"]})
        if not wanted or missing:
            sys.exit(f"sbom.py: iso/mkosi.conf lists {len(wanted)} packages, not in the manifest: {missing}")
        if not crates:
            sys.exit("sbom.py: --iso: the Cargo.lock lists no crate from a registry")
        git = sorted(c["name"] for c in crates if not c["source"].startswith("registry+"))
        if git:
            sys.exit(f"sbom.py: --iso: crates from a git source are not accepted: {git}")
        commit = commit_of(INSTALLER_COMMIT)
        applications = [("nyra-installer", commit, f"pkg:github/NyraOS/installer@{commit}")]
        name = "nyra-installer-iso" if arch == "amd64" else "nyra-installer-iso-arm64"
        description = "Nyra OS installer ISO (" + ("x86_64" if arch == "amd64" else "aarch64") + "): Debian unstable snapshot {snapshot}"
        what = "nyra-installer"
    else:
        pam_totp_commit = commit_of(PAM_TOTP_COMMIT)
        applications = [("bootc", os.environ["BOOTC_REF"], f"pkg:github/bootc-dev/bootc@{os.environ['BOOTC_COMMIT']}"),
                        ("pam-totp", pam_totp_commit, f"pkg:github/NyraOS/pam-totp@{pam_totp_commit}")]
        name, description = "nyra-base", "Nyra OS base image (desktop): Debian unstable snapshot {snapshot}, x86_64"
        what = "bootc, pam-totp"
    count = write_sbom(sbom_path, snapshot, debs, crates, applications, name, description)
    exceptions = (MITIGATIONS_ISO_ARM64 if arch == "arm64" else MITIGATIONS_ISO) if iso else MITIGATIONS
    mitigations = load_mitigations(today, exceptions)  # after the SBOM: an invalid file still blocks, but the SBOM is there

    findings, unimportant = debian_findings(debs)
    findings += crate_findings(crates)
    rated = [f for f in findings if not f.get("informational")]
    with ThreadPoolExecutor(8) as pool:
        for f, (score, level) in zip(rated, pool.map(lambda f: severity(f["osv"]), rated)):
            if f["debian_high"] and level in ("medium", "low"):
                level = "high"
            f["score"], f["level"] = score, level

    def level(f):
        return f.get("informational") or (f"{f['level']} {f['score']}" if f["score"] is not None else f["level"])

    # An entry matches a finding of the same package by its ID or any OSV alias (RUSTSEC, GHSA, CVE).
    blocking, accepted, expired, other = [], [], [], []
    needed, no_longer = set(), {}
    for f in sorted(findings, key=lambda f: (f["package"], f["id"])):
        m = next((m for (i, p), m in mitigations.items() if p == f["package"] and i in f["ids"]), None)
        key = m and (m["id"], m["package"])
        if f.get("informational") or f["level"] not in BLOCKING:
            other.append(f)
            if m:
                no_longer[key] = level(f)
        elif m and m["expires"] >= today:
            accepted.append((f, m))
            needed.add(key)
        else:
            blocking.append(f)
            if m:
                expired.append(m)
                needed.add(key)

    def fixed(f):
        return f"{f['fixed']} (bump the snapshot)" if f["fixed"] else ""

    def short(text):
        text = " ".join(text.split()).replace("|", "/")
        return text if len(text) <= 140 else text[:137] + "..."

    print("## Vulnerability scan (docs/SBOM.md)\n")
    print(f"SBOM: CycloneDX 1.6, {count} components ({len(debs)} Debian packages, {len(crates)} Rust crates, {what}).")
    print(f"Sources: Debian Security Tracker (`sid`) and OSV, {datetime.datetime.now(datetime.UTC):%Y-%m-%d %H:%M} UTC; "
          f"Debian snapshot `{snapshot}`.\n")
    print("| | |\n|---|---|")
    print(f"| **Blocking** (critical, high or unknown severity) | **{len(blocking)}** |")
    print(f"| Accepted (`tools/sbom/{os.path.basename(exceptions)}`) | {len(accepted)} |")
    print(f"| Not blocking (medium, low, Rust informational) | {len(other)} |")
    print(f"| Marked unimportant by Debian | {unimportant} |\n")
    if blocking:
        print("### Blocking\n\n| ID | Package | Version | Severity | Fixed in Debian | Description |\n|---|---|---|---|---|---|")
        for f in blocking:
            print(f"| {f['id']} | {f['package']} | {f['version']} | {level(f)} | {fixed(f)} | {short(f['about'])} |")
        print()
    for m in expired:
        print(f"- Mitigation for {m['id']} ({m['package']}) expired on {m['expires']}: review it again.")
    for key, m in mitigations.items():
        if key in no_longer and key not in needed:
            print(f"- Mitigation for {m['id']} ({m['package']}) no longer blocks (now {no_longer[key]}): remove it.")
        elif key not in needed:
            print(f"- Mitigation for {m['id']} ({m['package']}) matches nothing any more (fixed or gone): remove it.")
    if accepted:
        print("\n### Accepted\n\n| ID | Package | Severity | Expires | Reason |\n|---|---|---|---|---|")
        for f, m in accepted:
            print(f"| {f['id']} | {f['package']} | {level(f)} | {m['expires']} | {short(m['reason'])} |")
    if other:
        print("\n<details><summary>Not blocking</summary>\n\n| ID | Package | Version | Severity | Fixed in Debian |\n|---|---|---|---|---|")
        for f in other:
            print(f"| {f['id']} | {f['package']} | {f['version']} | {level(f)} | {fixed(f)} |")
        print("\n</details>")
    if blocking:
        print(f"sbom.py: {len(blocking)} blocking vulnerabilities (see the report)", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
