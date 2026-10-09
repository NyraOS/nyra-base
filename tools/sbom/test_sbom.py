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


def fake_fetch(url, data=None):
    if url.endswith("/Packages.xz"):
        return lzma.compress(PACKAGES.encode())
    if url == sbom.TRACKER:
        return json.dumps(TRACKER).encode()
    if url.endswith("/querybatch"):
        return json.dumps({"results": [{"vulns": [{"id": "RUSTSEC-2026-0001"}, {"id": "GHSA-aaaa-bbbb-cccc"}]}]}).encode()
    record = OSV.get(url.rsplit("/", 1)[1])
    return json.dumps(record).encode() if record else None


class Gate(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = lambda name: os.path.join(self.dir, name)
        with open(self.path("mkosi.conf"), "w") as f:
            f.write("Snapshot=20261006T060000Z\nRepositories=main\n")
        with open(self.path("manifest.json"), "w") as f:
            json.dump({"config": {"distribution": "debian", "release": "unstable", "architecture": "x86-64"},
                       "packages": [{"name": "libfoo1", "version": "1.0-1", "architecture": "amd64"},
                                    {"name": "bar", "version": "2.0-1", "architecture": "amd64"}]}, f)
        with open(self.path("Cargo.lock"), "w") as f:
            f.write('[[package]]\nname = "baz"\nversion = "0.1.0"\n'
                    'source = "registry+https://github.com/rust-lang/crates.io-index"\n')
        self.patches = {"fetch": fake_fetch, "MKOSI_CONF": self.path("mkosi.conf"),
                        "MITIGATIONS": self.path("mitigations.toml")}
        self.saved = {k: getattr(sbom, k) for k in self.patches}
        for k, v in self.patches.items():
            setattr(sbom, k, v)
        os.environ.update(BOOTC_REF="v0", BOOTC_COMMIT="0" * 40)

    def tearDown(self):
        for k, v in self.saved.items():
            setattr(sbom, k, v)
        shutil.rmtree(self.dir)

    def run_gate(self, *entries):
        """Runs main() with these (id, package, days until expiry); returns (exit code, report)."""
        today = datetime.datetime.now(datetime.UTC).date()
        with open(self.path("mitigations.toml"), "w") as f:
            for vid, package, days in entries:
                f.write(f'[[mitigation]]\nid = "{vid}"\npackage = "{package}"\nreason = "test"\n'
                        f"expires = {today + datetime.timedelta(days=days)}\n")
        sys.argv = ["sbom.py", self.path("manifest.json"), self.path("Cargo.lock"), self.path("sbom.json")]
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
            self.assertEqual(len(json.load(f)["components"]), 4)  # bootc, 2 Debian packages, 1 crate

    def test_invalid_file_still_writes_the_sbom(self):
        code, _ = self.run_gate(("CVE-2026-0001", "foo", 91))
        self.assertIn("expires more than 90 days ahead", str(code))
        self.assertTrue(os.path.exists(self.path("sbom.json")))


if __name__ == "__main__":
    unittest.main()
