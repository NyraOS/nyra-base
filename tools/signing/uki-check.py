#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Refuses any PE file that is not the image's sealed UKI (docs/SIGNING.md, "The UKI gate").

The sections are read as systemd-stub reads them (pe_sections.py: in the order of the section table,
names up to the first NUL, as the loader puts them in memory; refused wherever that reading could
differ from the stub's, and on more than one Authenticode signature). Accepted only:
  - exactly one .linux section (a kernel, so not an add-on or another PE file);
  - exactly one .cmdline in the base sections (inherited by profile 0), and each profile's sections
    exactly, in table order: profile 0 .profile and .pcrsig (its PCR policy, pcr-policy.py), each
    further profile .profile and its own .cmdline, with as many profiles as lines in EXPECTED
    (ci/uki-cmdline.txt). So no profile is without a command line (the stub would take the boot
    loader's), none has a second one or any other section (an .initrd of its own), none is extra;
  - each command line exactly its line of EXPECTED, in order: compared as bytes, only trailing NULs
    cut (the stub stops at the first NUL), every byte in 0x20-0x7e; DIGEST is the composefs digest,
    128 hex digits, the same in every profile;
  - exactly one .sbat section, with exactly one Nyra component line (nyra,<generation>,...), so that
    the UKI can be revoked with older Nyra UKIs (docs/BOOT.md, "SBAT").
Runs before the UKI is signed (tools/signing/sign-uki.sh) and in the release gate
(tools/signing/uki-gate.sh). With SIGNATURES (0 or 1) the UKI must carry exactly that many
Authenticode signatures; without it, none or one (more is always refused).
    python3 -I tools/signing/uki-check.py UKI EXPECTED [SIGNATURES]
"""
import os
import re
import sys

sys.dont_write_bytecode = True  # nothing written into the checkout
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pefile  # noqa: E402
from pe_sections import SECURITY, Refused, sections  # noqa: E402


def check(uki, expected_path, signatures=None):
    with open(expected_path, encoding="ascii") as f:
        expected = [line.rstrip("\n") for line in f if line.strip() and not line.startswith("#")]
    secs = sections(uki)
    names = [name for name, _ in secs]
    if names.count(".linux") != 1:
        return f"{names.count('.linux')} .linux sections, not 1: not a UKI (an add-on or another PE file)"
    first = names.index(".profile") if ".profile" in names else len(names)
    base, profiles = names[:first], names[first:]
    want = [".profile", ".pcrsig"] + [".profile", ".cmdline"] * (len(expected) - 1)
    if base.count(".cmdline") != 1 or profiles != want:
        return (f"not one .cmdline in the base sections and exactly these sections in {len(expected)} profiles:\n"
                f"  found:    {base.count('.cmdline')} .cmdline in the base sections, profiles {profiles}\n"
                f"  expected: 1 .cmdline in the base sections, profiles {want}")
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
    sbat = [data for name, data in secs if name == ".sbat"]
    nyra = [line for line in b"".join(sbat).split(b"\n") if line.startswith(b"nyra,")]
    if len(sbat) != 1 or len(nyra) != 1 or not re.fullmatch(rb"nyra,[1-9][0-9]*,.*", nyra[0]):
        return f"not one .sbat section with one Nyra component line (nyra,<generation>,...): {nyra}"
    # sections() accepted the certificate table: it is empty or exactly one signature.
    found = int(bool(pefile.PE(uki, fast_load=True).OPTIONAL_HEADER.DATA_DIRECTORY[SECURITY].Size))
    if signatures is not None and found != signatures:
        return f"{found} Authenticode signatures, not {signatures}"
    return None


def main():
    uki, expected_path, *signatures = sys.argv[1:]
    try:
        error = check(uki, expected_path, int(signatures[0]) if signatures else None)
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
