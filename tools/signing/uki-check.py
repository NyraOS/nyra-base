#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Refuses any PE file that is not the image's sealed UKI (docs/SIGNING.md, "The UKI gate").

The sections are read as systemd-stub reads them (pe_sections.py: in the order of the section table,
names up to the first NUL, refused on any pefile warning, on overlapping sections or on more than
one Authenticode signature). Accepted only:
  - exactly one .linux section (a kernel, so not an add-on or another PE file);
  - the .cmdline and .profile sections, in table order, exactly: the base .cmdline (inherited by
    profile 0), then profile 0's .profile, then .profile and its own .cmdline for each further
    profile, with as many profiles as lines in EXPECTED (ci/uki-cmdline.txt). So no profile is
    without a command line (the stub would take the boot loader's), none has a second one, none is
    extra;
  - each command line exactly its line of EXPECTED, in order: compared as bytes, only trailing NULs
    cut (the stub stops at the first NUL), every byte in 0x20-0x7e; DIGEST is the composefs digest,
    128 hex digits, the same in every profile.
Runs before the UKI is signed (ci/build-image.sh) and in the release gate (tools/signing/uki-gate.sh).
    python3 -I tools/signing/uki-check.py UKI EXPECTED
"""
import os
import re
import sys

sys.dont_write_bytecode = True  # nothing written into the checkout
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pefile  # noqa: E402
from pe_sections import Refused, sections  # noqa: E402


def check(uki, expected_path):
    with open(expected_path, encoding="ascii") as f:
        expected = [line.rstrip("\n") for line in f if line.strip() and not line.startswith("#")]
    secs = sections(uki)
    names = [name for name, _ in secs]
    if names.count(".linux") != 1:
        return f"{names.count('.linux')} .linux sections, not 1: not a UKI (an add-on or another PE file)"
    structure = [name for name in names if name in (".cmdline", ".profile")]
    want = [".cmdline", ".profile"] + [".profile", ".cmdline"] * (len(expected) - 1)
    if structure != want:
        return (f".cmdline and .profile sections not one command line per profile, {len(expected)} profiles:\n"
                f"  found:    {structure}\n  expected: {want}")
    found = [data.rstrip(b"\0") for name, data in secs if name == ".cmdline"]
    digests = set()
    for profile, (line, got) in enumerate(zip(expected, found)):
        bad = sorted({hex(b) for b in got if not 0x20 <= b <= 0x7E})
        if bad:
            return f"command line of profile {profile} has bytes outside 0x20-0x7e: {bad}: {got}"
        m = re.fullmatch(re.escape(line).replace("DIGEST", "([0-9a-f]{128})"), got.decode("ascii"))
        if not m:
            return (f"command line not as committed in {expected_path}:\n"
                    f"  profile {profile}: {got.decode('ascii')}\n  expected:  {line}")
        digests.update(m.groups())
    if len(digests) != 1:
        return f"the profiles do not carry one and the same composefs digest: {sorted(digests)}"
    return None


def main():
    uki, expected_path = sys.argv[1:]
    try:
        error = check(uki, expected_path)
    except Refused as e:
        error = str(e)
    except (OSError, ValueError, pefile.PEFormatError) as e:
        error = f"cannot read it: {e}"
    if error:
        print(f"uki-check: refused {uki}: {error}", file=sys.stderr)
        sys.exit(1)
    print(f"uki-check: {uki} is the sealed UKI")


if __name__ == "__main__":
    main()
