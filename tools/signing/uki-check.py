#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Refuses any PE file that is not the image's sealed UKI (docs/SIGNING.md, "The UKI gate").

Accepted only: exactly one .linux section (a kernel, so not an add-on or another PE file) and
.cmdline sections that are exactly the lines of EXPECTED (ci/uki-cmdline.txt), in order, one per
profile, where DIGEST is the composefs digest: 128 hex digits, the same in every profile. Runs before
the UKI is signed (ci/build-image.sh) and in the release gate (tools/signing/uki-gate.sh).
    python3 -I tools/signing/uki-check.py UKI EXPECTED
"""
import re
import sys

import pefile


def check(uki, expected_path):
    with open(expected_path, encoding="utf-8") as f:
        expected = [line.strip() for line in f if line.strip() and not line.startswith("#")]
    pe = pefile.PE(uki, fast_load=True)
    names = [s.Name.rstrip(b"\0") for s in pe.sections]
    if names.count(b".linux") != 1:
        return f"{names.count(b'.linux')} .linux sections, not 1: not a UKI (an add-on or another PE file)"
    found = [s.get_data()[:s.Misc_VirtualSize].rstrip(b"\0").decode("ascii").strip()
             for s in pe.sections if s.Name.rstrip(b"\0") == b".cmdline"]
    if len(found) != len(expected):
        return f"{len(found)} command lines, expected {len(expected)} (one per profile): {found}"
    digests = set()
    for want, got in zip(expected, found):
        m = re.fullmatch(re.escape(want).replace("DIGEST", "([0-9a-f]{128})"), got)
        if not m:
            return f"command line not as committed in {expected_path}:\n  found:    {got}\n  expected: {want}"
        digests.update(m.groups())
    if len(digests) != 1:
        return f"the profiles do not carry one and the same composefs digest: {sorted(digests)}"
    return None


def main():
    uki, expected_path = sys.argv[1:]
    try:
        error = check(uki, expected_path)
    except (OSError, UnicodeDecodeError, pefile.PEFormatError) as e:
        error = f"cannot read it: {e}"
    if error:
        print(f"uki-check: refused {uki}: {error}", file=sys.stderr)
        sys.exit(1)
    print(f"uki-check: {uki} is the sealed UKI")


if __name__ == "__main__":
    main()
