#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Offline tests for sbom.py: canned Debian/OSV data instead of the network.

usage: python3 tools/sbom/test_sbom.py   (needs the cvss package, tools/sbom/requirements.txt)
"""
import contextlib
import datetime
import io
import json
import lzma
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sbom  # noqa: E402

CRITICAL = "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"  # 9.8
HIGH = "CVSS:3.1/AV:L/AC:L/PR:N/UI:R/S:U/C:H/I:H/A:H"  # 7.8
MEDIUM = "CVSS:3.1/AV:L/AC:L/PR:L/UI:N/S:U/C:N/I:N/A:H"  # 5.5
PACKAGES = """Package: libfoo1
Version: 1.0-1
Architecture: amd64
Source: foo

Package: bar
Version: 2.0-1
Architecture: amd64

Package: polkitd
Version: 128-1
Architecture: amd64
"""
TRACKER = {
    "foo": {
        "CVE-2026-0001": {"releases": {"sid": {"status": "open", "urgency": "not yet assigned"}}},
        "CVE-2026-0002": {"releases": {"sid": {"status": "open", "urgency": "not yet assigned"}}},
    },
    "bar": {
        "CVE-2026-0003": {"releases": {"sid": {"status": "resolved", "fixed_version": "2.0-2",
                                               "urgency": "not yet assigned"}}},
    },
}
# The same crate issue under two IDs, each listing the other as an alias.
OSV = {
    "DEBIAN-CVE-2026-0001": {"severity": [{"type": "CVSS_V3", "score": CRITICAL}]},
    "DEBIAN-CVE-2026-0002": {"severity": [{"type": "CVSS_V3", "score": MEDIUM}]},
    "DEBIAN-CVE-2026-0003": {"severity": [{"type": "CVSS_V3", "score": HIGH}]},
    "RUSTSEC-2026-0001": {"aliases": ["GHSA-aaaa-bbbb-cccc"], "affected": [{}],
                          "severity": [{"type": "CVSS_V3", "score": HIGH}]},
    "GHSA-aaaa-bbbb-cccc": {"aliases": ["RUSTSEC-2026-0001", "CVE-2026-0009"], "affected": [{}],
                            "severity": [{"type": "CVSS_V3", "score": HIGH}]},
}


URLS = []


def fake_fetch(url, data=None):
    URLS.append(url)
    if url.endswith("/binary-arm64/Packages.xz"):
        return lzma.compress(PACKAGES.replace("amd64", "arm64").encode())
    if url.endswith("/binary-amd64/Packages.xz"):
        return lzma.compress(PACKAGES.encode())
    if url == sbom.TRACKER:
        return json.dumps(TRACKER).encode()
    if url.endswith("/querybatch"):
        baz = {"vulns": [{"id": "RUSTSEC-2026-0001"}, {"id": "GHSA-aaaa-bbbb-cccc"}]}
        return json.dumps({"results": [baz if q["package"]["name"] == "baz" else {} for q in data["queries"]]}).encode()
    record = OSV.get(url.rsplit("/", 1)[1])
    return json.dumps(record).encode() if record else None


class Gate(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = lambda name: os.path.join(self.dir, name)
        with open(self.path("mkosi.conf"), "w") as f:
            f.write("Snapshot=20261006T060000Z\nRepositories=main\n")
        with open(self.path("commit"), "w") as f:
            f.write("1" * 40 + "\n")
        with open(self.path("manifest.json"), "w") as f:
            json.dump({"config": {"distribution": "debian", "release": "unstable", "architecture": "x86-64"},
                       "packages": [{"name": "libfoo1", "version": "1.0-1", "architecture": "amd64"},
                                    {"name": "bar", "version": "2.0-1", "architecture": "amd64"},
                                    {"name": "polkitd", "version": "128-1", "architecture": "amd64"}]}, f)
        with open(self.path("Cargo.lock"), "w") as f:
            f.write('[[package]]\nname = "baz"\nversion = "0.1.0"\n'
                    'source = "registry+https://github.com/rust-lang/crates.io-index"\n')
        with open(self.path("iso-mkosi.conf"), "w") as f:
            f.write("[Content]\nPackages=\n        libfoo1\n        bar\n\n[Build]\n")
        with open(self.path("installer-commit"), "w") as f:
            f.write("2" * 40 + "\n")
        self.patches = {"fetch": fake_fetch, "INSTALLER_COMMIT": self.path("installer-commit"), "ISO_MKOSI_CONF": self.path("iso-mkosi.conf"), "MKOSI_CONF": self.path("mkosi.conf"),
                        "MITIGATIONS": self.path("mitigations.toml"), "MITIGATIONS_ISO": self.path("mitigations-iso.toml"),
                        "MITIGATIONS_ISO_ARM64": self.path("mitigations-iso-arm64.toml"),
                        "PAM_TOTP_COMMIT": self.path("commit")}
        self.saved = {k: getattr(sbom, k) for k in self.patches}
        for k, v in self.patches.items():
            setattr(sbom, k, v)
        os.environ.update(BOOTC_REF="v0", BOOTC_COMMIT="0" * 40)

    def tearDown(self):
        for k, v in self.saved.items():
            setattr(sbom, k, v)
        shutil.rmtree(self.dir)

    def run_gate(self, *entries, extra_locks=(), iso=False, iso_entries=(), arm64_entries=(), arch=None, mode=None):
        """Runs main() with these (id, package, days until expiry); returns (exit code, report)."""
        today = datetime.datetime.now(datetime.UTC).date()
        for name, listed in (("mitigations.toml", entries), ("mitigations-iso.toml", iso_entries),
                             ("mitigations-iso-arm64.toml", arm64_entries)):
            with open(self.path(name), "w") as f:
                for vid, package, days in listed:
                    f.write(f'[[mitigation]]\nid = "{vid}"\npackage = "{package}"\nreason = "test"\n'
                            f"expires = {today + datetime.timedelta(days=days)}\n")
        sys.argv = ["sbom.py", *([f"--vulnerabilities={mode}"] if mode else []), *(["--iso"] if iso else []), *(["--arch", arch] if arch else []), self.path("manifest.json"), self.path("Cargo.lock"), self.path("sbom.json"), *extra_locks]
        out = io.StringIO()
        code = 0
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            try:
                sbom.main()
            except SystemExit as e:
                code = e.code
        return code, out.getvalue()

    def test_nothing_accepted_blocks(self):
        code, report = self.run_gate()
        self.assertEqual(code, 1)
        self.assertIn("| **Blocking** (critical, high or unknown severity) | **4** |", report)

    def test_one_entry_covers_all_aliases(self):
        # The RUSTSEC entry also covers the GHSA record; a CVE alias works as well.
        for vid in ("RUSTSEC-2026-0001", "GHSA-aaaa-bbbb-cccc", "CVE-2026-0009"):
            code, report = self.run_gate(("CVE-2026-0001", "foo", 10), ("CVE-2026-0003", "bar", 10), (vid, "baz", 10))
            self.assertEqual(code, 0, vid)
            self.assertIn("| Accepted (`tools/sbom/mitigations.toml`) | 4 |", report)
            self.assertNotIn("remove it", report)

    def test_alias_needs_the_same_package(self):
        code, report = self.run_gate(("CVE-2026-0001", "foo", 10), ("CVE-2026-0003", "bar", 10),
                                     ("RUSTSEC-2026-0001", "other", 10))
        self.assertEqual(code, 1)
        self.assertIn("RUSTSEC-2026-0001 (other) matches nothing any more", report)

    def test_expired_blocks(self):
        code, report = self.run_gate(("CVE-2026-0001", "foo", 10), ("CVE-2026-0003", "bar", -1),
                                     ("RUSTSEC-2026-0001", "baz", 10))
        self.assertEqual(code, 1)
        self.assertIn("| CVE-2026-0003 | bar | 2.0-1 | high 7.8 | 2.0-2 (bump the snapshot) |", report)
        self.assertIn("Mitigation for CVE-2026-0003 (bar) expired on", report)

    def test_block_mode_fails_and_is_the_default(self):
        for mode in (None, "block"):
            code, report = self.run_gate(mode=mode)
            self.assertEqual(code, 1)
            self.assertIn("| CVE-2026-0001 | foo | 1.0-1 | critical 9.8 |", report)
            self.assertNotIn("Report mode", report)

    def test_report_mode_prints_the_findings_and_exits_0(self):
        code, report = self.run_gate(mode="report")
        self.assertEqual(code, 0)
        self.assertIn("| **Blocking** (critical, high or unknown severity) | **4** |", report)
        self.assertIn("| CVE-2026-0001 | foo | 1.0-1 | critical 9.8 |", report)
        self.assertIn("Report mode: these do not fail this run", report)
        with open(self.path("sbom.json")) as f:
            self.assertEqual(len(json.load(f)["components"]), 6)

    def test_report_mode_lists_unknown_severity(self):
        # No CVSS vector in any record: the severity is unknown, which blocks, so the report must show it.
        TRACKER["foo"]["CVE-2026-0007"] = {"releases": {"sid": {"status": "open", "urgency": "not yet assigned"}}}
        try:
            code, report = self.run_gate(mode="report")
        finally:
            del TRACKER["foo"]["CVE-2026-0007"]
        self.assertEqual(code, 0)
        self.assertIn("| CVE-2026-0007 | foo | 1.0-1 | unknown |", report)

    def test_report_mode_in_the_iso_scans(self):
        self.assertEqual(self.run_gate(iso=True, mode="report")[0], 0)
        self.assertEqual(self.run_gate(iso=True, mode="block")[0], 1)

    def test_report_mode_still_fails_on_everything_but_findings(self):
        # An expired exception and an invalid exception file.
        code, report = self.run_gate(("CVE-2026-0001", "foo", 10), ("CVE-2026-0003", "bar", -1),
                                     ("RUSTSEC-2026-0001", "baz", 10), mode="report")
        self.assertEqual(code, 1)
        self.assertIn("Mitigation for CVE-2026-0003 (bar) expired on", report)
        code, _ = self.run_gate(("CVE-2026-0001", "foo", 10), ("CVE-2026-0001", "foo", 20), mode="report")
        self.assertIn("is listed twice", str(code))
        # No Debian packages in the manifest.
        with open(self.path("manifest.json"), "w") as f:
            json.dump({"config": {"distribution": "debian", "release": "unstable", "architecture": "x86-64"},
                       "packages": []}, f)
        code, _ = self.run_gate(mode="report")
        self.assertIn("lists no Debian packages", str(code))

    def test_report_mode_fails_when_the_scan_cannot_run(self):
        def no_network(url, data=None):
            if url == sbom.TRACKER:
                raise OSError("no route to host")
            return fake_fetch(url, data)
        sbom.fetch = no_network
        try:
            with self.assertRaises(OSError):
                self.run_gate(mode="report")
        finally:
            sbom.fetch = fake_fetch

    def test_unknown_mode_refused(self):
        code, _ = self.run_gate(mode="warn")
        self.assertIn("--vulnerabilities=report|block", str(code))

    def test_stale_entries_reported(self):
        code, report = self.run_gate(("CVE-2026-0001", "foo", 10), ("CVE-2026-0003", "bar", 10),
                                     ("RUSTSEC-2026-0001", "baz", 10),
                                     ("CVE-2026-0002", "foo", 10), ("CVE-2026-0099", "foo", 10))
        self.assertEqual(code, 0)
        self.assertIn("CVE-2026-0002 (foo) no longer blocks (now medium 5.5): remove it.", report)
        self.assertIn("CVE-2026-0099 (foo) matches nothing any more (fixed or gone): remove it.", report)

    def test_duplicate_refused_after_writing_the_sbom(self):
        code, _ = self.run_gate(("CVE-2026-0001", "foo", 10), ("CVE-2026-0001", "foo", 20))
        self.assertIn("is listed twice", str(code))
        with open(self.path("sbom.json")) as f:
            components = json.load(f)["components"]
        self.assertEqual(len(components), 6)  # bootc, pam-totp, 3 Debian packages, 1 crate
        self.assertIn("pkg:github/NyraOS/pam-totp@" + "1" * 40, [c["purl"] for c in components])

    def test_more_cargo_locks(self):
        # A second Cargo.lock: its crates are in the SBOM and scanned; one already listed counts once.
        with open(self.path("other.lock"), "w") as f:
            f.write('[[package]]\nname = "baz"\nversion = "0.1.0"\n'
                    'source = "registry+https://github.com/rust-lang/crates.io-index"\ndependencies = ["qux"]\n\n'
                    '[[package]]\nname = "qux"\nversion = "1.0.0"\n'
                    'source = "registry+https://github.com/rust-lang/crates.io-index"\n\n'
                    '[[package]]\nname = "local"\nversion = "0.0.0"\n')
        code, report = self.run_gate(extra_locks=[self.path("other.lock")])
        self.assertEqual(code, 1)
        self.assertIn("(3 Debian packages, 2 Rust crates, bootc, pam-totp)", report)
        self.assertIn("| **Blocking** (critical, high or unknown severity) | **4** |", report)
        with open(self.path("sbom.json")) as f:
            purls = [c.get("purl") for c in json.load(f)["components"]]
        self.assertEqual(purls.count("pkg:cargo/baz@0.1.0"), 1)
        self.assertIn("pkg:cargo/qux@1.0.0", purls)

    def test_pam_totp_commit_checked(self):
        with open(self.path("commit"), "w") as f:
            f.write("main\n")
        code, _ = self.run_gate()
        self.assertIn("is not a commit", str(code))

    def test_iso_mode(self):
        # The ISO: the installer program instead of bootc and pam-totp, no bootc environment, the same scan.
        saved = {k: os.environ.pop(k) for k in ("BOOTC_REF", "BOOTC_COMMIT")}
        try:
            code, report = self.run_gate(iso=True)
        finally:
            os.environ.update(saved)
        self.assertEqual(code, 1)
        self.assertIn("Rust crates, nyra-installer).", report)
        self.assertIn("| **Blocking** (critical, high or unknown severity) | **4** |", report)

    def test_image_exceptions_do_not_apply_to_the_iso(self):
        everything = (("CVE-2026-0001", "foo", 10), ("CVE-2026-0003", "bar", 10), ("RUSTSEC-2026-0001", "baz", 10))
        saved = {k: os.environ.pop(k) for k in ("BOOTC_REF", "BOOTC_COMMIT")}
        try:
            code, report = self.run_gate(*everything, iso=True)
            own, own_report = self.run_gate(iso=True, iso_entries=everything)
        finally:
            os.environ.update(saved)
        self.assertEqual(code, 1)
        self.assertIn("| Accepted (`tools/sbom/mitigations-iso.toml`) | 0 |", report)
        self.assertNotIn("remove it", report)  # the image's entries are not the ISO's business
        self.assertEqual(own, 0)
        self.assertIn("| Accepted (`tools/sbom/mitigations-iso.toml`) | 4 |", own_report)

    def test_iso_exceptions_do_not_apply_to_the_image(self):
        everything = (("CVE-2026-0001", "foo", 10), ("CVE-2026-0003", "bar", 10), ("RUSTSEC-2026-0001", "baz", 10))
        code, report = self.run_gate(iso_entries=everything)
        self.assertEqual(code, 1)
        self.assertIn("| Accepted (`tools/sbom/mitigations.toml`) | 0 |", report)
        self.assertNotIn("remove it", report)

    def test_iso_exception_file_is_checked_like_the_image_one(self):
        saved = {k: os.environ.pop(k) for k in ("BOOTC_REF", "BOOTC_COMMIT")}
        try:
            code, _ = self.run_gate(iso=True, iso_entries=(("CVE-2026-0001", "foo", 91),))
            code2, report = self.run_gate(iso=True, iso_entries=(("CVE-2026-9999", "nothing", 10),))
        finally:
            os.environ.update(saved)
        self.assertIn("mitigations-iso.toml", str(code))
        self.assertIn("expires more than 90 days ahead", str(code))
        self.assertIn("matches nothing any more", report)

    def test_iso_sbom_names_the_installer(self):
        saved = {k: os.environ.pop(k) for k in ("BOOTC_REF", "BOOTC_COMMIT")}
        try:
            self.run_gate(iso=True)
        finally:
            os.environ.update(saved)
        with open(self.path("sbom.json")) as f:
            bom = json.load(f)
        self.assertEqual(bom["metadata"]["component"]["name"], "nyra-installer-iso")
        purls = [c.get("purl") for c in bom["components"]]
        self.assertIn("pkg:github/NyraOS/installer@" + "2" * 40, purls)
        self.assertFalse([p for p in purls if p and ("bootc" in p or "pam-totp" in p)])

    def iso_refused(self):
        saved = {k: os.environ.pop(k) for k in ("BOOTC_REF", "BOOTC_COMMIT")}
        try:
            return self.run_gate(iso=True)[0]
        finally:
            os.environ.update(saved)

    def test_iso_needs_all_its_packages_and_a_crate(self):
        with open(self.path("iso-mkosi.conf"), "w") as f:
            f.write("[Content]\nPackages=\n        libfoo1\n        bar\n        missing-one\n")
        self.assertIn("missing-one", str(self.iso_refused()))
        with open(self.path("iso-mkosi.conf"), "w") as f:
            f.write("[Content]\nPackages=\n        libfoo1\n        bar\n")
        with open(self.path("Cargo.lock"), "w") as f:
            f.write('[[package]]\nname = "nyra-installer"\nversion = "0.1.0"\n')  # the program itself: no source
        self.assertIn("no crate", str(self.iso_refused()))

    def test_iso_refuses_git_crates(self):
        with open(self.path("Cargo.lock"), "a") as f:
            f.write('[[package]]\nname = "gitty"\nversion = "0.1.0"\nsource = "git+https://example.invalid/x#abc"\n')
        self.assertIn("git source", str(self.iso_refused()))

    def test_iso_installer_commit_checked(self):
        with open(self.path("iso-mkosi.conf"), "w") as f:
            f.write("[Content]\nPackages=\n        libfoo1\n        bar\n\n[Build]\n")
        with open(self.path("installer-commit"), "w") as f:
            f.write("main\n")
        saved = {k: os.environ.pop(k) for k in ("BOOTC_REF", "BOOTC_COMMIT")}
        try:
            code, _ = self.run_gate(iso=True)
        finally:
            os.environ.update(saved)
        self.assertIn("is not a commit", str(code))

    def set_polkitd(self, version):
        """Writes the manifest without polkitd (version None) or with this version."""
        with open(self.path("manifest.json")) as f:
            manifest = json.load(f)
        manifest["packages"] = [p for p in manifest["packages"] if p["name"] != "polkitd"]
        if version:
            manifest["packages"].append({"name": "polkitd", "version": version, "architecture": "amd64"})
        with open(self.path("manifest.json"), "w") as f:
            json.dump(manifest, f)

    def test_polkitd_needs_128_1(self):
        # Newer versions, a binNMU among them, pass; older, a pre-release or a missing package fail.
        def check(version):
            packages = [{"name": "polkitd", "version": version}] if version else []
            try:
                sbom.check_minimum_versions({"packages": packages})
            except SystemExit as e:
                return str(e)
        for version in ("128-1", "128-1+b1", "128-2", "129-1"):
            self.assertIsNone(check(version), version)
        for version in ("127-2", "128~rc1-1"):
            self.assertIn("is older than 128-1", check(version), version)
        self.assertIn("is not in the manifest", check(None))
        # main() refuses the image's manifest without polkitd.
        self.set_polkitd(None)
        code, _ = self.run_gate()
        self.assertIn("polkitd is not in the manifest", str(code))

    def test_iso_does_not_check_polkitd(self):
        self.set_polkitd(None)
        code, _ = self.run_gate(iso=True)
        self.assertNotIn("polkitd", str(code))

    def test_no_debian_packages_refused(self):
        with open(self.path("manifest.json")) as f:
            manifest = json.load(f)
        manifest["packages"] = []
        with open(self.path("manifest.json"), "w") as f:
            json.dump(manifest, f)
        code, _ = self.run_gate()
        self.assertIn("lists no Debian packages", str(code))

    def test_invalid_file_still_writes_the_sbom(self):
        code, _ = self.run_gate(("CVE-2026-0001", "foo", 91))
        self.assertIn("expires more than 90 days ahead", str(code))
        self.assertTrue(os.path.exists(self.path("sbom.json")))


    # --- the aarch64 ISO: the same scan on the arm64 index, with exceptions of its own ------------------
    def arm64_manifest(self, architecture="arm64", package_arch="arm64"):
        with open(self.path("manifest.json"), "w") as f:
            json.dump({"config": {"distribution": "debian", "release": "unstable", "architecture": architecture},
                       "packages": [{"name": "libfoo1", "version": "1.0-1", "architecture": package_arch},
                                    {"name": "bar", "version": "2.0-1", "architecture": package_arch}]}, f)

    def run_arm64(self, **kw):
        saved = {k: os.environ.pop(k) for k in ("BOOTC_REF", "BOOTC_COMMIT")}
        try:
            return self.run_gate(iso=True, arch="arm64", **kw)
        finally:
            os.environ.update(saved)

    def test_arm64_iso_reads_the_arm64_index(self):
        self.arm64_manifest()
        del URLS[:]
        code, report = self.run_arm64()
        self.assertEqual(code, 1)
        self.assertIn("| **Blocking** (critical, high or unknown severity) | **4** |", report)
        self.assertTrue([u for u in URLS if u.endswith("/binary-arm64/Packages.xz")])
        self.assertFalse([u for u in URLS if "binary-amd64" in u])
        self.assertIn("| Accepted (`tools/sbom/mitigations-iso-arm64.toml`) | 0 |", report)
        with open(self.path("sbom.json")) as f:
            bom = json.load(f)
        self.assertEqual(bom["metadata"]["component"]["name"], "nyra-installer-iso-arm64")
        self.assertIn("aarch64", bom["metadata"]["component"]["description"])
        self.assertTrue([c for c in bom["components"] if "arch=arm64" in c.get("purl", "")])

    def test_arm64_iso_wants_the_arm64_kernel(self):
        # iso/mkosi.conf names the x86_64 kernel; for arm64 the manifest must hold linux-image-arm64.
        self.arm64_manifest()
        with open(self.path("iso-mkosi.conf"), "w") as f:
            f.write("[Content]\nPackages=\n        libfoo1\n        linux-image-amd64\n")
        self.assertIn("linux-image-arm64", str(self.run_arm64()[0]))
        with open(self.path("manifest.json")) as f:
            manifest = json.load(f)
        manifest["packages"][1]["name"] = "linux-image-arm64"
        with open(self.path("manifest.json"), "w") as f:
            json.dump(manifest, f)
        # Not in the fake index: refused for that, not for the missing package.
        self.assertIn("is not in the snapshot", str(self.run_arm64()[0]))

    def test_arm64_iso_refuses_an_x86_manifest_and_the_reverse(self):
        self.arm64_manifest("x86-64", "amd64")
        self.assertIn("only Debian unstable arm64", str(self.run_arm64()[0]))
        self.arm64_manifest()
        saved = {k: os.environ.pop(k) for k in ("BOOTC_REF", "BOOTC_COMMIT")}
        try:
            self.assertIn("only Debian unstable x86-64", str(self.run_gate(iso=True)[0]))
        finally:
            os.environ.update(saved)

    def test_arm64_iso_has_exceptions_of_its_own(self):
        everything = (("CVE-2026-0001", "foo", 10), ("CVE-2026-0003", "bar", 10), ("RUSTSEC-2026-0001", "baz", 10))
        self.arm64_manifest()
        # The image's and the x86_64 ISO's files do not apply to it, and it is not told to remove them.
        code, report = self.run_gate_arm64_with(everything, everything, ())
        self.assertEqual(code, 1)
        self.assertIn("| Accepted (`tools/sbom/mitigations-iso-arm64.toml`) | 0 |", report)
        self.assertNotIn("remove it", report)
        code, report = self.run_arm64(arm64_entries=everything)
        self.assertEqual(code, 0)
        self.assertIn("| Accepted (`tools/sbom/mitigations-iso-arm64.toml`) | 4 |", report)
        # And its entries do not apply to the x86_64 ISO or to the image.
        with open(self.path("manifest.json"), "w") as f:
            json.dump({"config": {"distribution": "debian", "release": "unstable", "architecture": "x86-64"},
                       "packages": [{"name": "libfoo1", "version": "1.0-1", "architecture": "amd64"},
                                    {"name": "bar", "version": "2.0-1", "architecture": "amd64"},
                                    {"name": "polkitd", "version": "128-1", "architecture": "amd64"}]}, f)
        saved = {k: os.environ.pop(k) for k in ("BOOTC_REF", "BOOTC_COMMIT")}
        try:
            code, report = self.run_gate(iso=True, arm64_entries=everything)
        finally:
            os.environ.update(saved)
        self.assertEqual(code, 1)
        self.assertIn("| Accepted (`tools/sbom/mitigations-iso.toml`) | 0 |", report)
        code, report = self.run_gate(arm64_entries=everything)
        self.assertEqual(code, 1)

    def run_gate_arm64_with(self, image_entries, iso_entries, arm64_entries):
        saved = {k: os.environ.pop(k) for k in ("BOOTC_REF", "BOOTC_COMMIT")}
        try:
            return self.run_gate(*image_entries, iso=True, arch="arm64", iso_entries=iso_entries, arm64_entries=arm64_entries)
        finally:
            os.environ.update(saved)

    def test_arch_goes_with_the_iso_only(self):
        self.assertIn("--arch", str(self.run_gate(arch="arm64")[0]))


if __name__ == "__main__":
    unittest.main()
