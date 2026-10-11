# SPDX-License-Identifier: GPL-3.0-or-later
"""The sections of a UKI as systemd-stub reads them, for uki-check.py and pcr-policy.py.

sections(path) returns [(name, data)] in the order of the section table, which is the order the stub
reads them in (pefile sorts its own list by address). The name ends at its first NUL, as the stub
compares it; data is the section in memory once loaded: VirtualSize bytes, the file's bytes up to
min(VirtualSize, SizeOfRawData), then zeros. The stub reads what the loader (shim's, or the firmware's)
put in memory, so sections() raises Refused for any file where that could differ from this reading:
  - a section header pefile did not read, or any pefile warning (pefile stops at some malformed
    headers and only warns, while the stub reads on);
  - a certificate table that is neither empty (before signing) nor exactly one Authenticode
    signature: one PKCS#7 entry that fills the table, at the end of the file, DER with one-byte tags,
    with one signer, no unsigned attributes (where a nested signature would be) and nothing after it;
  - a section the loader does not copy as it is: without IMAGE_SCN_MEM_READ or with
    IMAGE_SCN_MEM_DISCARDABLE (shim does not copy it; only .reloc may be discardable, shim reads it
    from the file), or with IMAGE_SCN_CNT_UNINITIALIZED_DATA (shim fills it with zeros);
  - a section that is empty in memory, overlaps the headers or another section in memory (the loader
    copies one over the other) or reaches beyond SizeOfImage (the stub ignores it);
  - section data that is not in the file before the certificate table (not covered by the signature);
  - a base relocation that changes anything but the stub's own code and data (STUB_SECTIONS): the
    loader applies them in memory before the stub reads its sections. They are read as shim reads them
    (from the .reloc section in the file), so a relocation table elsewhere is refused too (the
    firmware reads it at the directory's address);
  - two sections of the same name in the base sections or in one profile (the stub reads the first).
"""
import struct

import pefile

SECURITY = pefile.DIRECTORY_ENTRY["IMAGE_DIRECTORY_ENTRY_SECURITY"]
BASERELOC = pefile.DIRECTORY_ENTRY["IMAGE_DIRECTORY_ENTRY_BASERELOC"]
MEM_READ, MEM_DISCARDABLE, CNT_UNINITIALIZED_DATA = 0x40000000, 0x02000000, 0x00000080
# The bytes each base relocation type changes (ABSOLUTE, HIGH, LOW, HIGHLOW, DIR64); shim refuses others.
RELOCATION_SIZE = {0: 0, 1: 2, 2: 2, 3: 4, 10: 8}
# systemd-stub's own sections, the only ones its relocations may change.
STUB_SECTIONS = {".text", ".rodata", ".data"}


class Refused(Exception):
    pass


def name_of(s):
    return s.Name.split(b"\0")[0].decode("ascii")


def der(data, at, end):
    """(tag, start, end of the contents) of the DER element at AT, which must end by END. Tags are one
    byte: the high tag number form (low five bits all set) is refused, OpenSSL would read it."""
    if at + 2 > end:
        raise Refused("the PKCS#7 signature does not parse")
    tag, n, at = data[at], data[at + 1], at + 2
    if tag & 0x1F == 0x1F:
        raise Refused("the PKCS#7 signature does not parse (not DER: a high tag number)")
    if n & 0x80:
        k = n & 0x7F
        if not 1 <= k <= 4:
            raise Refused("the PKCS#7 signature does not parse (not DER)")
        n, at = int.from_bytes(data[at:at + k], "big"), at + k
    if at + n > end:
        raise Refused("the PKCS#7 signature does not parse")
    return tag, at, at + n


def children(data, element):
    tag, at, end = element
    found = []
    while at < end:
        found.append(der(data, at, end))
        at = found[-1][2]
    return found


def one_signer(data, at, end):
    """Refuses a PKCS#7 SignedData with other than one SignerInfo, or one with unsigned attributes, or
    bytes after it in the certificate entry."""
    whole = der(data, at, end)
    content_info = children(data, whole)
    explicit = children(data, content_info[1]) if [tag for tag, _, _ in content_info] == [0x06, 0xA0] else []
    signed_data = children(data, explicit[0]) if [tag for tag, _, _ in explicit] == [0x30] else []
    if not signed_data or signed_data[-1][0] != 0x31:
        raise Refused("the PKCS#7 signature does not parse")
    signers = children(data, signed_data[-1])
    if len(signers) != 1:
        raise Refused(f"not exactly one Authenticode signature: {len(signers)} signers in the PKCS#7 signature")
    if any(tag == 0xA1 for tag, _, _ in children(data, signers[0])):
        raise Refused("not exactly one Authenticode signature: unsigned attributes in the PKCS#7 signature "
                      "(a nested signature, for example)")
    if whole[2] != end:
        raise Refused(f"not exactly one Authenticode signature: {end - whole[2]} bytes after the PKCS#7 signature "
                      "in its certificate entry")


def relocations(pe, data):
    """(address, size) of each base relocation, read as shim reads them: RelocDir.Size bytes of the
    .reloc section's data in the file."""
    table = pe.OPTIONAL_HEADER.DATA_DIRECTORY[BASERELOC]
    if not table.Size:
        return []
    reloc = [s for s in pe.sections if s.Name == b".reloc\0\0"]
    if len(reloc) != 1 or reloc[0].VirtualAddress != table.VirtualAddress or \
            table.Size > min(reloc[0].Misc_VirtualSize, reloc[0].SizeOfRawData):
        raise Refused("the base relocation table is not at the start of one .reloc section")
    at = reloc[0].PointerToRawData
    end = at + table.Size
    found = []
    while at < end - 1:  # shim's loop condition
        page, size = struct.unpack_from("<II", data, at)
        if size < 8 or size % 2 or at + size > end:
            raise Refused(f"a base relocation block of {size} bytes")
        for (entry,) in struct.iter_unpack("<H", data[at + 8:at + size]):
            kind = entry >> 12
            if kind not in RELOCATION_SIZE:
                raise Refused(f"a base relocation of type {kind}")
            if RELOCATION_SIZE[kind]:
                found.append((page + (entry & 0xFFF), RELOCATION_SIZE[kind]))
        at += size
    return found


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
    if len(pe.OPTIONAL_HEADER.DATA_DIRECTORY) <= max(SECURITY, BASERELOC):
        raise Refused("no certificate table or base relocation entry in the optional header")
    table = pe.OPTIONAL_HEADER.DATA_DIRECTORY[SECURITY]
    if table.VirtualAddress or table.Size:
        at = table.VirtualAddress
        length, revision, kind = struct.unpack_from("<IHH", data, at) if 8 <= table.Size == len(data) - at else (0, 0, 0)
        if (length + 7) // 8 * 8 != table.Size or revision != 0x0200 or kind != 0x0002:
            raise Refused("not exactly one Authenticode signature: the certificate table is not one "
                          "PKCS#7 entry at the end of the file")
        one_signer(data, at + 8, at + length)
        signed_end = at

    end = pe.OPTIONAL_HEADER.SizeOfHeaders
    for s in sorted(pe.sections, key=lambda s: s.VirtualAddress):
        name = name_of(s)
        if not s.Characteristics & MEM_READ:
            raise Refused(f"section {name} is not readable (no IMAGE_SCN_MEM_READ): shim does not load it")
        if s.Characteristics & MEM_DISCARDABLE and s.Name != b".reloc\0\0":
            raise Refused(f"section {name} is discardable (IMAGE_SCN_MEM_DISCARDABLE): shim does not load it")
        if s.Characteristics & CNT_UNINITIALIZED_DATA:
            raise Refused(f"section {name} is uninitialized data (IMAGE_SCN_CNT_UNINITIALIZED_DATA): "
                          "shim loads zeros")
        if s.Misc_VirtualSize == 0:
            raise Refused(f"section {name} is empty in memory")
        if s.VirtualAddress < end:
            raise Refused(f"section {name} overlaps the headers or another section in memory")
        end = s.VirtualAddress + s.Misc_VirtualSize
        if end > pe.OPTIONAL_HEADER.SizeOfImage:
            raise Refused(f"section {name} reaches beyond the image in memory (SizeOfImage)")

    for address, size in relocations(pe, data):
        inside = [name_of(s) for s in pe.sections
                  if s.VirtualAddress <= address and address + size <= s.VirtualAddress + s.Misc_VirtualSize]
        if not inside or inside[0] not in STUB_SECTIONS:
            raise Refused(f"a base relocation at {address:#x} changes {inside[0] if inside else 'no single section'}, "
                          f"not only systemd-stub's code and data")

    result, seen = [], set()
    for s in sorted(pe.sections, key=lambda s: s.get_file_offset()):
        name = name_of(s)
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
