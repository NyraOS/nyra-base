# SPDX-License-Identifier: GPL-3.0-or-later
"""The sections of a UKI as systemd-stub reads them, for uki-check.py and pcr-policy.py.

sections(path) returns [(name, data)] in the order of the section table, which is the order the stub
reads them in (pefile sorts its own list by address). The name ends at its first NUL, as the stub
compares it; data is the section in memory once loaded: VirtualSize bytes, the file's bytes up to
min(VirtualSize, SizeOfRawData), then zeros. Raises Refused for anything this reading could get
different from the stub or the firmware:
  - a section header pefile did not read, or any pefile warning (pefile stops at some malformed
    headers and only warns, while the stub reads on);
  - a certificate table that is neither empty (before signing) nor exactly one Authenticode
    signature (one PKCS#7 entry that fills the table, at the end of the file);
  - a section that is empty in memory, overlaps the headers or another section in memory (the loader
    copies one over the other) or reaches beyond SizeOfImage (the stub ignores it);
  - section data that is not in the file before the certificate table (not covered by the signature);
  - two sections of the same name in the base sections or in one profile (the stub reads the first).
"""
import struct

import pefile

SECURITY = pefile.DIRECTORY_ENTRY["IMAGE_DIRECTORY_ENTRY_SECURITY"]


class Refused(Exception):
    pass


def sections(path):
    with open(path, "rb") as f:
        data = f.read()
    pe = pefile.PE(data=data, fast_load=True)
    if len(pe.sections) != pe.FILE_HEADER.NumberOfSections:
        raise Refused(f"pefile read {len(pe.sections)} of the {pe.FILE_HEADER.NumberOfSections} section headers")
    if pe.get_warnings():
        raise Refused(f"pefile warnings: {pe.get_warnings()}")

    # The certificate table: its address is a file offset; each entry is 8-byte aligned.
    signed_end = len(data)
    if len(pe.OPTIONAL_HEADER.DATA_DIRECTORY) <= SECURITY:
        raise Refused("no certificate table entry in the optional header")
    table = pe.OPTIONAL_HEADER.DATA_DIRECTORY[SECURITY]
    if table.VirtualAddress or table.Size:
        at = table.VirtualAddress
        length, revision, kind = struct.unpack_from("<IHH", data, at) if 8 <= table.Size == len(data) - at else (0, 0, 0)
        if (length + 7) // 8 * 8 != table.Size or revision != 0x0200 or kind != 0x0002:
            raise Refused("not exactly one Authenticode signature: the certificate table is not one "
                          "PKCS#7 entry at the end of the file")
        signed_end = at

    end = pe.OPTIONAL_HEADER.SizeOfHeaders
    for s in sorted(pe.sections, key=lambda s: s.VirtualAddress):
        name = s.Name.split(b"\0")[0]
        if s.Misc_VirtualSize == 0:
            raise Refused(f"section {name} is empty in memory")
        if s.VirtualAddress < end:
            raise Refused(f"section {name} overlaps the headers or another section in memory")
        end = s.VirtualAddress + s.Misc_VirtualSize
        if end > pe.OPTIONAL_HEADER.SizeOfImage:
            raise Refused(f"section {name} reaches beyond the image in memory (SizeOfImage)")

    result, seen = [], set()
    for s in sorted(pe.sections, key=lambda s: s.get_file_offset()):
        name = s.Name.split(b"\0")[0].decode("ascii")
        size = min(s.Misc_VirtualSize, s.SizeOfRawData)
        if s.PointerToRawData + size > signed_end:
            raise Refused(f"the data of section {name} is not in the file before the certificate table")
        if name == ".profile":
            seen = set()
        if name in seen:
            raise Refused(f"two {name} sections in the base sections or in one profile (systemd-stub reads the first)")
        seen.add(name)
        result.append((name, data[s.PointerToRawData:s.PointerToRawData + size] + bytes(s.Misc_VirtualSize - size)))
    return result
