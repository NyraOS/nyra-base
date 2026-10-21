# SBOM and vulnerability gate

Every build of nyra-base produces a software bill of materials and checks it for known
vulnerabilities. A known critical or high vulnerability without a documented mitigation fails the
build, so it is never signed or released.

The last step of the `build` job in `.github/workflows/image.yml` runs
[`tools/sbom/sbom.py`](../tools/sbom/sbom.py). It writes these files to the `nyra-base-sbom`
artifact:

| File | Contents |
|---|---|
| `nyra-base.cdx.json` | the SBOM, CycloneDX 1.6 JSON |
| `nyra-base.vulnerabilities.md` | the scan report, also shown in the job summary |
| `nyra-base.manifest.json` | the mkosi package list it is made from |
| `bootc-<tag>-<commit>.Cargo.lock` | the Rust crates compiled into bootc |
| `nyra-zlib.Cargo.lock` | the Rust crates compiled into the image's zlib (zlib-rs, docs/DEFAULTS.md) |
| `nyra-ntpd.Cargo.lock` | the Rust crates compiled into the time client (ntpd-rs, docs/DEFAULTS.md) |
| `pam-totp.Cargo.lock` | the Rust crates compiled into the SSH two-step authentication (pam-totp, docs/DEFAULTS.md "SSH") |

The licence notices of each Rust program in the image (ntpd-rs, nyra-updated, nyra-zlib, pam-totp) are in
`/usr/share/doc/<program>/third-party/`, next to its `Cargo.lock`; the build fails if one is missing.

Once images are published, releases will attach the SBOM next to the image.

## The SBOM

mkosi removes the dpkg database from the image, so the package list comes from its JSON manifest
(`ManifestFormat=json`), with exact versions. The manifest names binary packages only. The script
maps each one to its source package through the `Packages` index of the same snapshot
(`snapshot.debian.org`, over https). Vulnerability data is keyed by source package.

Components:

- one per Debian package: `pkg:deb/debian/<name>@<version>?arch=<arch>&distro=sid&upstream=<source>`
  (`upstream` carries `@<source version>` when it differs, as syft writes it);
- bootc itself: `pkg:github/bootc-dev/bootc@<commit>`;
- pam-totp itself (the SSH two-step authentication, built from its own repository at the commit in
  `pam-totp/commit`): `pkg:github/NyraOS/pam-totp@<commit>`;
- one per crate in bootc's `Cargo.lock`, `zlib/Cargo.lock`, `ntpd-rs/Cargo.lock` and
  `pam-totp/Cargo.lock` (zlib-rs, ntpd-rs and pam-totp, which the image build compiles; the last is a
  copy of pam-totp's own, and the build fails when they differ): `pkg:cargo/<name>@<version>` (git sources add
  `vcs_url`); a crate in several counts once. ntpd-rs's crates `ntpd` and `ntp-proto` are listed at
  their upstream version; the image's `ntp-proto` carries our patch
  (`patches/upstream/ntpd-rs-wrong-clock.md`).

Debian's `zlib1g` stays in the list: the package is installed, only its library file is replaced
with zlib-rs (docs/DEFAULTS.md, "zlib"). A finding for Debian's zlib therefore blocks like any
other; its mitigation entry can say that the image does not use that library.

The timestamp is the snapshot date, so the same inputs give the same file.

The image's `/etc/os-release` names Nyra OS (`ID=nyra`, `ID_LIKE=debian`; docs/DEFAULTS.md, "Name
and version"). The scan never reads it: the Debian packages come from the package list, and the
script refuses a list without any.

## The scan

| Question | Source |
|---|---|
| Is our version of a Debian source package affected? | [Debian Security Tracker](https://security-tracker.debian.org/tracker/data/json), release `sid`: open, undetermined, or fixed in a version newer than ours |
| Is a crate of bootc, zlib-rs, ntpd-rs or pam-totp affected? | [OSV](https://osv.dev), ecosystem `crates.io` (RustSec's advisories among them) |
| How bad is it? | the CVSS vectors in the OSV record (`DEBIAN-<id>`, then `<id>`), scored with the [`cvss`](https://github.com/RedHatProductSecurity/cvss) library: critical ≥ 9.0, high ≥ 7.0 |

A finding **blocks the build** when its severity is critical, high or unknown (no CVSS vector
anywhere) and it is not listed in [`tools/sbom/mitigations.toml`](../tools/sbom/mitigations.toml).
Debian's own urgency `high` counts as high whatever the score. Unknown blocks because a fresh CVE
without a score may well be critical: a person decides, not the absence of data.

Not blocking, but listed in the report: medium and low findings, and RustSec informational
advisories (unmaintained, unsound). Findings that Debian marks `unimportant` are only counted:
the Debian security team has already documented why they do not matter for Debian's build.

The data is fetched at build time, so the same image can pass today and fail tomorrow. That is
the point: the gate answers "is anything known now".

## When the build is blocked

1. **Fixed in Debian** (the report shows the version): the snapshot is older than the fix. Move
   `Snapshot=` in `mkosi/mkosi.conf` to a date that has it. This also rebuilds bootc (the snapshot is
   part of its cache key). A crate of zlib-rs or ntpd-rs with a fixed version: update the version
   in `zlib/` or `ntpd-rs/` (`Cargo.toml`, `Cargo.lock`; Dependabot opens that pull request). A new
   version of `ntpd` or `ntp-proto` needs our patch made again for it. A crate of pam-totp: update
   it in pam-totp's repository, then its commit in `pam-totp/commit` and the copy of its
   `Cargo.lock` in `pam-totp/`.
2. **No fix yet:** check whether the image is exposed. If it is not, or the damage is limited, add
   an entry to `tools/sbom/mitigations.toml`:

   ```toml
   [[mitigation]]
   id = "CVE-2026-00000"
   package = "example"   # Debian source package or Rust crate, as in the report
   reason = "Needs plugin X, which is in libexample-modules, not in the image."
   expires = 2026-12-31  # at most 90 days ahead
   ```

   The reason says why the image is not exposed (or what limits the damage) and what ends the
   exception. Entries go through review like any other change (security review is required).
   `id` can be any of the advisory's IDs (for a crate: RUSTSEC, GHSA or CVE, through OSV aliases),
   so one entry covers the issue however many records OSV returns for it. The same `id` and
   `package` twice makes the file invalid, and an invalid file blocks the build (the SBOM is still
   written and uploaded). An expired entry blocks again; an entry that no longer blocks (now medium
   or low) or matches nothing any more (fixed, package gone) is reported for removal.
3. **Exposed and no fix:** remove or replace the package, or patch it in the Nyra apt repository.

Our rule is 48 hours for critical and 7 days for high vulnerabilities once a fix exists. A
mitigation entry for a fixable vulnerability should only bridge that time (a snapshot bump that is
waiting for a Debian transition, for example), so its expiry should be just as short.

An exception that rests on nothing in the image reaching the vulnerable code holds only while that
stays true. A change that brings a thumbnail consumer (a thumbnail service or anything that asks for
thumbnails), a file manager, xdg-desktop-portal or a desktop shell into the image must first remove
the libheif and glycin exceptions, or bring a fixed libheif with it: those exceptions assume that
no image from outside is ever decoded. glycin's sandbox limits the damage, but it does not replace
the fix.

## Running it locally

```bash
python3 -m venv /tmp/sbom-venv
/tmp/sbom-venv/bin/pip install --no-deps --require-hashes -r tools/sbom/requirements.txt
gh run download <run-id> -n nyra-base-sbom -D /tmp/sbom
BOOTC_REF=<tag> BOOTC_COMMIT=<commit> /tmp/sbom-venv/bin/python tools/sbom/sbom.py \
  /tmp/sbom/nyra-base.manifest.json /tmp/sbom/bootc-*.Cargo.lock /tmp/sbom/nyra-base.cdx.json \
  /tmp/sbom/nyra-zlib.Cargo.lock
```

## Before a push: the scan on a branch

The gate depends on the advisories of the day, not only on the change, so a branch can fail it
although it touches nothing the scanner looks at. The scan runs in about a minute on a machine
without KVM, with this checkout's scanner, mitigations and Cargo.lock files against the package list
of the last image built on main (the same inputs as the `sbom` job of `image.yml`). Run it before
pushing a change to `tools/sbom/`, to `mitigations.toml`, to the package list or to a Cargo.lock, and
whenever a pull request failed the gate, to see if a new advisory or the change is the cause. It
needs `gh` (logged in), `podman` and the network.

```bash
set -o pipefail         # the exit status of the scan, not of tee
D=/var/tmp/sbom-main     # main's SBOM inputs, downloaded once and refreshed when main moves
S=/var/tmp/sbom-scan     # a podman store of its own: never use the shared default store for this
mkdir -p "$D"
# The newest unexpired nyra-base-sbom artifact of a successful push run on main that built.
for run in $(gh run list -R NyraOS/nyra-base --workflow image.yml --branch main --event push \
               --status success -L 30 --json databaseId --jq '.[].databaseId'); do
  id="$(gh api "repos/NyraOS/nyra-base/actions/runs/$run/artifacts?name=nyra-base-sbom" \
    --jq '[.artifacts[] | select(.expired == false)][0].id // empty')"
  [ -z "$id" ] || break
done
gh api "repos/NyraOS/nyra-base/actions/artifacts/$id/zip" > "$D/sbom.zip" && python3 -m zipfile -e "$D/sbom.zip" "$D"

# From the root of the checkout of the branch. The tag and commit of bootc are the two lines of image.yml.
BOOTC_REF="$(sed -n 's/^  BOOTC_REF: //p' .github/workflows/image.yml)"
BOOTC_COMMIT="$(sed -n 's/^  BOOTC_COMMIT: //p' .github/workflows/image.yml)"
podman --root "$S/root" --runroot "$S/run" run --rm -v "$PWD:/repo:ro" -v "$D:/in:ro" -w /repo \
  -e BOOTC_REF="$BOOTC_REF" -e BOOTC_COMMIT="$BOOTC_COMMIT" \
  docker.io/library/python@sha256:4873c73fa393882cf10f9d1054c928e95201c1559ca2107c1589786ece10f49f \
  sh -c 'python3 -m venv /tmp/v &&
    /tmp/v/bin/pip install -q --no-deps --require-hashes -r tools/sbom/requirements.txt &&
    /tmp/v/bin/python tools/sbom/test_sbom.py &&
    /tmp/v/bin/python tools/sbom/sbom.py /in/nyra-base.manifest.json \
      "/in/bootc-$BOOTC_REF-$BOOTC_COMMIT.Cargo.lock" /tmp/nyra-base.cdx.json \
      zlib/Cargo.lock ntpd-rs/Cargo.lock pam-totp/Cargo.lock' | tee /tmp/sbom-report.md
```

The report is the one the job summary shows; the exit status is 1 when a vulnerability blocks. The
image is python:3.13-slim by digest (the index of the multi-arch image), and the container runs
as a rootless user with the checkout read-only. Remove the store with `podman unshare rm -rf "$S"`
when it is not needed any more. This is a safety net, not a gate: CI runs the real one on every
build.

The offline tests (canned tracker and OSV data) run first in CI:
`/tmp/sbom-venv/bin/python tools/sbom/test_sbom.py`.

The scan needs network access (about 25 MB: the snapshot `Packages` index and the tracker data) and
takes about 10 seconds.
