#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: tests the UKI release gate (tools/signing/uki-gate.sh, docs/SIGNING.md) on IMAGE, whose UKI
# is signed with this run's throwaway key (RUN_CERT) and carries a PCR policy signed with this run's
# throwaway policy key (RUN_PCR_KEY, its public half), on every build:
#   - accepted with RUN_CERT and RUN_PCR_KEY (the gate passes a correct image, so its refusals below
#     mean something);
#   - refused exactly as the sign job runs it, with the committed Nyra certificate and policy key: an
#     image signed with test keys never gets a release signature;
#   - refused with a certificate that did not sign it, and with a policy key that did not sign its
#     policy; refused when the image's next policy key (RUN_NEXT_KEY, which it carries) is not the one
#     given, when the next key given is the current one, when the image carries none, and when none is
#     given;
#   - refused, even when signed with the trusted key: an add-on in place of the UKI, the UKI with
#     another command line, a second UKI, an add-on next to the UKI, the UKI without its Nyra SBAT
#     component, without its PCR policy, with a policy signature that does not verify, and with the
#     policy moved to the recovery profile (without the policy and with it moved: also by
#     pcr-policy.py alone);
#   - refused, even when signed with the trusted key, wherever pefile's reading of the UKI could
#     differ from systemd-stub's after shim loaded it (tools/signing/pe_sections.py), and wherever the
#     sections are not exactly the sealed UKI's: a section header pefile does not read, a pefile
#     warning, a section name with a NUL inside, a profile without a command line, a profile with two,
#     an .initrd in a profile, two profiles' command lines swapped in the section table, a control
#     character or a space in a command line, overlapping sections, a section beyond the image or
#     empty in memory, a command line that is not readable, discardable or uninitialized data (shim
#     does not copy it), a base relocation that changes a command line, a second Authenticode
#     signature, a nested one, also with its tag in the high tag number form, and bytes after the
#     signature in its certificate entry;
#   - refused, signed with the trusted key and then changed (so its signature no longer holds; it is
#     refused before that check): section data in the certificate table.
# The "gate" and "other" keys are made here, live only in WORKDIR on the ephemeral runner and are
# deleted at the end: never commit or upload them, never use a real key here.
#   tools/signing/test-uki-gate.sh IMAGE RUN_CERT RUN_PCR_KEY RUN_NEXT_KEY WORKDIR
set -euo pipefail

image="$1" run_cert="$2" run_pcr="$3" run_next="$4" work="$5"
t="$work/uki-gate-test"
nyra_cert=files/usr/lib/nyra/secureboot/nyra.crt
nyra_pcr=files/usr/lib/nyra/secureboot/tpm2-pcr-public-key.pem
nyra_next=files/usr/lib/nyra/secureboot/tpm2-pcr-public-key-next.pem
mkdir -p "$t"
trap 'sudo rm -rf "$t"' EXIT

# gate BOOT_DIR CERT [PCR_KEY [NEXT_KEY [IMAGE_NEXT_KEY]]]: this run's policy keys and the image's next
# key unless given.
gate() { tools/signing/uki-gate.sh "$1" "$2" "${3:-$run_pcr}" "${4:-$run_next}" "${5:-$t/image-next.pem}"; }
# refused REASON BOOT_DIR CERT [PCR_KEY]: the gate must fail, and for REASON (an extended regular expression).
refused() {
  local reason="$1" out
  shift
  if out="$(gate "$@" 2>&1)"; then
    echo "$out"
    echo "::error::The UKI gate accepted $* (expected: refused, $reason)"
    exit 1
  fi
  echo "$out"
  grep -Eq "$reason" <<<"$out" || { echo "::error::The UKI gate refused $*, but not for: $reason"; exit 1; }
  echo "refused as expected: $*"
}
# copy NAME: a fresh copy of the image's /boot as $t/NAME.
copy() { rm -rf "${t:?}/$1"; cp -a "$t/image" "$t/$1"; }

cid="$(sudo podman create -q "$image")"
sudo podman cp "$cid:/boot" "$t/image"
sudo podman cp "$cid:/usr/lib/systemd/boot/efi/addonx64.efi.stub" "$t/"
sudo podman cp "$cid:/usr/lib/nyra/secureboot/tpm2-pcr-public-key-next.pem" "$t/image-next.pem"
sudo podman rm -f "$cid" >/dev/null
sudo chown -R "$(id -u):$(id -g)" "$t"
uki="$(cd "$t/image" && echo EFI/Linux/*.efi)"
echo "The image's /boot:"; (cd "$t/image" && find . -mindepth 1 | LC_ALL=C sort)

openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=Nyra CI UKI gate test key" \
  -keyout "$t/gate.key" -out "$t/gate.crt" 2>/dev/null
openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=Nyra CI key that signed nothing" \
  -keyout "$t/other.key" -out "$t/other.crt" 2>/dev/null
sign() { sbsign --key "$t/gate.key" --cert "$t/gate.crt" --output "$2" "$1"; }

# The image as built.
gate "$t/image" "$run_cert"
refused "no Nyra UKI certificate|no Nyra PCR policy public key|no next Nyra PCR policy public key|is not signed with|PCR policy signed with|next PCR policy key is not" \
  "$t/image" "$nyra_cert" "$nyra_pcr" "$nyra_next"
refused "is not signed with" "$t/image" "$t/other.crt"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null | openssl pkey -pubout -out "$t/other-pcr.pem"
refused "\\.pcrpkey is not" "$t/image" "$run_cert" "$t/other-pcr.pem"
# The next policy key: not the one the image carries, or the current one.
refused "the image's next PCR policy key is not" "$t/image" "$run_cert" "$run_pcr" "$t/other-pcr.pem"
refused "the next PCR policy key is the current one" "$t/image" "$run_cert" "$run_pcr" "$run_pcr" "$run_pcr"
refused "the image carries no next PCR policy key" "$t/image" "$run_cert" "$run_pcr" "$run_next" "$t/none.pem"
refused "no next Nyra PCR policy public key" "$t/image" "$run_cert" "$run_pcr" "$t/none.pem"

# The image's UKI signed with the "gate" key instead: accepted with its certificate (the control).
cp "$t/image/$uki" "$t/unsigned.efi"
sbattach --remove "$t/unsigned.efi"
copy resigned
sign "$t/unsigned.efi" "$t/resigned/$uki"
gate "$t/resigned" "$t/gate.crt"

# A signed add-on (a kernel command line that turns credential import back on) in place of the UKI.
sudo podman run --rm --network none --tmpfs /tmp --tmpfs /var/tmp -v "$t:/t" "$image" ukify build --stub /t/addonx64.efi.stub \
  --cmdline systemd.import_credentials=yes --output /t/addon.efi
sudo chown -R "$(id -u):$(id -g)" "$t"
copy addon
sign "$t/addon.efi" "$t/addon/$uki"
refused "not a UKI" "$t/addon" "$t/gate.crt"

# The UKI with credential import turned on in the main profile's command line, signed.
python3 -I - "$t/unsigned.efi" "$t/cmdline.efi" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
old, new = b"systemd.import_credentials=no ", b"systemd.import_credentials=on "
assert data.count(old) == 3, data.count(old)
open(sys.argv[2], "wb").write(data.replace(old, new, 1))
PY
copy cmdline
sign "$t/cmdline.efi" "$t/cmdline/$uki"
refused "command line not as committed" "$t/cmdline" "$t/gate.crt"

# The UKI without its Nyra SBAT component (the line renamed), signed: it could not be revoked.
python3 -I - "$t/unsigned.efi" "$t/nosbat.efi" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
assert data.count(b"\nnyra,") == 1, data.count(b"\nnyra,")
open(sys.argv[2], "wb").write(data.replace(b"\nnyra,", b"\nnyrx,"))
PY
copy nosbat
sign "$t/nosbat.efi" "$t/nosbat/$uki"
refused "one Nyra component line" "$t/nosbat" "$t/gate.crt"

# A second UKI next to the image's, and an add-on next to it (both signed).
copy second
sign "$t/unsigned.efi" "$t/second/EFI/Linux/second.efi"
sign "$t/unsigned.efi" "$t/second/$uki"
refused "exactly one UKI" "$t/second" "$t/gate.crt"
copy extra
sign "$t/unsigned.efi" "$t/extra/$uki"
mkdir "$t/extra/$uki.extra.d"
sign "$t/addon.efi" "$t/extra/$uki.extra.d/console.addon.efi"
refused "exactly one UKI" "$t/extra" "$t/gate.crt"

# The PCR policy changed in the UKI, which is then signed with the trusted key: removed (its section
# renamed), its first signature changed by one character, and moved into the recovery profile (its
# section header swapped with the one of the recovery profile's .profile, right after it: the stub
# reads the sections in the order of the table, whatever their addresses).
python3 -I - "$t/unsigned.efi" "$t" <<'PY'
import sys
import pefile
src, out = sys.argv[1:]
data = open(src, "rb").read()
pe = pefile.PE(src, fast_load=True)
names = [s.Name.rstrip(b"\0") for s in pe.sections]
assert names.count(b".pcrsig") == 1, names
sig = pe.sections[names.index(b".pcrsig")]
nxt = pe.sections[names.index(b".pcrsig") + 1]
assert nxt.Name.rstrip(b"\0") == b".profile" and b"ID=recovery" in nxt.get_data(), names
def write(name, patched):
    open(f"{out}/{name}.efi", "wb").write(patched)
p = bytearray(data)
p[sig.get_file_offset():sig.get_file_offset() + 8] = b".pcrsix\0"
write("nopolicy", p)
p = bytearray(data)
at = data.index(b'"sig": "', sig.PointerToRawData) + len(b'"sig": "') + 10
p[at] = ord("A") if p[at] != ord("A") else ord("B")
write("badsig", p)
a, b = sig.get_file_offset(), nxt.get_file_offset()
p = bytearray(data)
p[a:a + 40], p[b:b + 40] = data[b:b + 40], data[a:a + 40]
write("recovery", p)
PY
for v in nopolicy badsig recovery; do
  copy "$v"
  sign "$t/$v.efi" "$t/$v/$uki"
done
# Without a policy, or with it in the recovery profile, the sections are not the sealed UKI's
# (uki-check.py refuses first); pcr-policy.py alone refuses them as well.
layout="found: +[0-9]+ \\.cmdline in the base sections, profiles \\["
refused "$layout'\\.profile', '\\.pcrsix', " "$t/nopolicy" "$t/gate.crt"
refused "does not verify" "$t/badsig" "$t/gate.crt"
refused "$layout'\\.profile', '\\.profile', '\\.pcrsig', " "$t/recovery" "$t/gate.crt"
policy_refused() {
  local reason="$1" out
  if out="$(python3 -I tools/signing/pcr-policy.py check "$2" "$run_pcr" 2>&1)"; then
    echo "$out"; echo "::error::pcr-policy.py accepted $2 (expected: refused, $reason)"; exit 1
  fi
  echo "$out"
  grep -Eq "$reason" <<<"$out" || { echo "::error::pcr-policy.py refused $2, but not for: $reason"; exit 1; }
}
policy_refused "not in the main profile alone" "$t/nopolicy/$uki"
policy_refused "not in the main profile alone: .*'recovery'" "$t/recovery/$uki"

# The UKI read as systemd-stub reads it (tools/signing/pe_sections.py, uki-check.py), each variant made
# from the image's UKI by changing its section headers or command lines, then signed with the trusted
# key. Section headers are 40 bytes: Name, VirtualSize (+8), VirtualAddress (+12), SizeOfRawData
# (+16), PointerToRawData (+20), Characteristics (+36).
python3 -I - "$t/unsigned.efi" "$t" <<'PY'
import struct
import sys
import pefile
src, out = sys.argv[1:]
data = bytes(open(src, "rb").read())
pe = pefile.PE(data=data, fast_load=True)
table = sorted(pe.sections, key=lambda s: s.get_file_offset())
names = [s.Name.rstrip(b"\0") for s in table]
at = [s.get_file_offset() for s in table]
p0, p1, p2 = [i for i, n in enumerate(names) if n == b".profile"]
cmd = names.index(b".cmdline")
assert names[p1 + 1] == names[p2 + 1] == b".cmdline" and p2 + 2 == len(names) and cmd < p0, names
def write(name, p):
    open(f"{out}/{name}.efi", "wb").write(p)
def field(p, i, offset, value):
    struct.pack_into("<I", p, at[i] + offset, value)
def prefix(i, byte):
    """Section i's command line with BYTE in front of it (one byte more in VirtualSize)."""
    s, p = table[i], bytearray(data)
    assert s.Misc_VirtualSize < s.SizeOfRawData
    p[s.PointerToRawData:s.PointerToRawData + s.Misc_VirtualSize + 1] = byte + data[s.PointerToRawData:s.PointerToRawData + s.Misc_VirtualSize]
    field(p, i, 8, s.Misc_VirtualSize + 1)
    return p
# Two more section headers: one of zeros, where pefile stops with only a warning, then a copy of
# profile 0's .profile, which the stub reads on to: a fourth profile, without a command line.
p = bytearray(data)
end = at[-1] + 40
assert p[end:end + 80] == bytes(80)
p[end + 40:end + 80] = data[at[p0]:at[p0] + 40]
struct.pack_into("<H", p, pe.FILE_HEADER.get_file_offset() + 2, len(names) + 2)
write("count", p)
# The recovery command line one byte into its file alignment: pefile warns (and reads it elsewhere).
p = bytearray(data)
field(p, p1 + 1, 20, table[p1 + 1].PointerToRawData + 1)
write("warning", p)
# .sdmagic renamed ".linux\0s": the stub compares names up to the first NUL, so it is a .linux, the
# first one in the table.
p = bytearray(data)
p[at[names.index(b".sdmagic")]:at[names.index(b".sdmagic")] + 8] = b".linux\0s"
write("nulname", p)
# The base command line moved into profile 0 and a fourth profile without a command line (.sdmagic
# renamed .profile, moved last): the stub boots that profile with the boot loader's command line.
order = [i for i in range(len(names)) if i not in (cmd, names.index(b".sdmagic"))]
order.insert(order.index(p0) + 1, cmd)
order.append(names.index(b".sdmagic"))
p = bytearray(data)
p[at[0]:at[-1] + 40] = b"".join(data[at[i]:at[i] + 40] for i in order)
p[at[-1]:at[-1] + 8] = b".profile"
write("nocmdline", p)
# The reset profile's .profile renamed: the recovery profile has two command lines.
p = bytearray(data)
p[at[p2]:at[p2] + 8] = b".profilX"
write("twocmdlines", p)
# The recovery and reset command lines swapped in the section table (their addresses keep their order).
p = bytearray(data)
p[at[p1 + 1]:at[p1 + 1] + 40], p[at[p2 + 1]:at[p2 + 1] + 40] = data[at[p2 + 1]:at[p2 + 1] + 40], data[at[p1 + 1]:at[p1 + 1] + 40]
write("order", p)
# The recovery command line with \x1c (which Python's strip() takes for whitespace), or a space, in front.
write("ctrl", prefix(p1 + 1, b"\x1c"))
write("space", prefix(p1 + 1, b" "))
# The reset command line at the recovery one's address: loaded over it.
p = bytearray(data)
field(p, p2 + 1, 12, table[p1 + 1].VirtualAddress)
write("overlap", p)
# The base command line beyond SizeOfImage: the stub ignores it and takes the boot loader's.
p = bytearray(data)
field(p, cmd, 12, pe.OPTIONAL_HEADER.SizeOfImage)
write("outside", p)
# The reset profile's .profile empty in memory.
p = bytearray(data)
field(p, p2, 8, 0)
write("empty", p)
# An .initrd of its own in the reset profile (a section added after the last one, with the first
# 512 bytes of the base initramfs): the reset profile would boot another initramfs, and the main
# profile, the only one the PCR policy covers, is unchanged.
fa, sa = pe.OPTIONAL_HEADER.FileAlignment, pe.OPTIONAL_HEADER.SectionAlignment
end, va = at[-1] + 40, pe.OPTIONAL_HEADER.SizeOfImage
assert data[end:end + 40] == bytes(40) and end + 40 <= pe.OPTIONAL_HEADER.SizeOfHeaders and va % sa == 0
p = bytearray(data) + bytes(-len(data) % fa)
initrd = table[names.index(b".initrd")]
p[end:end + 40] = struct.pack("<8s6I2HI", b".initrd", 0x200, va, 0x200, len(p), 0, 0, 0, 0, 0x40000040)
struct.pack_into("<H", p, pe.FILE_HEADER.get_file_offset() + 2, len(names) + 1)
struct.pack_into("<I", p, pe.OPTIONAL_HEADER.get_file_offset() + 56, va + sa)  # SizeOfImage
p += data[initrd.PointerToRawData:initrd.PointerToRawData + 0x200]
write("initrd", p)
# Command lines that shim does not copy as they are: the recovery one not readable (without
# IMAGE_SCN_MEM_READ), the base one discardable (IMAGE_SCN_MEM_DISCARDABLE) or uninitialized data
# (IMAGE_SCN_CNT_UNINITIALIZED_DATA). The stub would read zeros or whatever memory held.
assert table[p1 + 1].Characteristics == table[cmd].Characteristics == 0x40000040, hex(table[cmd].Characteristics)
p = bytearray(data)
field(p, p1 + 1, 36, 0x00000040)
write("noread", p)
p = bytearray(data)
field(p, cmd, 36, 0x42000040)
write("discardable", p)
p = bytearray(data)
field(p, cmd, 36, 0x400000C0)
write("uninitialized", p)
# The first base relocation (DIR64) moved to the start of the base command line: shim adds the load
# offset to those 8 bytes in memory.
reloc = table[names.index(b".reloc")]
page, size = struct.unpack_from("<II", data, reloc.PointerToRawData)
assert size > 8 and pe.OPTIONAL_HEADER.DATA_DIRECTORY[5].VirtualAddress == reloc.VirtualAddress, (page, size)
p = bytearray(data)
struct.pack_into("<IIH", p, reloc.PointerToRawData, table[cmd].VirtualAddress, size, 0xA000)
write("reloc", p)
PY
# variant NAME REASON: $t/NAME.efi signed with the trusted key as the image's UKI, refused for REASON.
variant() {
  copy "$1"
  sign "$t/$1.efi" "$t/$1/$uki"
  refused "$2" "$t/$1" "$t/gate.crt"
  rm -rf "${t:?}/$1" "$t/$1.efi"
}
variant count "pefile read [0-9]+ of the [0-9]+ section headers"
variant warning "pefile warnings: .*PointerToRawData should normally be a multiple of FileAlignment"
variant nulname "two \\.linux sections"
variant nocmdline "found: +0 \\.cmdline in the base sections"
variant initrd "$layout.*'\\.profile', '\\.cmdline', '\\.initrd'\\]"
variant twocmdlines "two \\.cmdline sections"
variant order "profile 1: lockdown=.*systemd\\.unit=nyra-reset-settings\\.target"
variant ctrl "command line of profile 1 has bytes outside 0x20-0x7e: \\['0x1c'\\]"
variant space "profile 1:  lockdown="
variant overlap "overlaps the headers or another section in memory"
variant outside "reaches beyond the image in memory"
variant empty "is empty in memory"
variant noread "section \\.cmdline is not readable \\(no IMAGE_SCN_MEM_READ\\)"
variant discardable "section \\.cmdline is discardable \\(IMAGE_SCN_MEM_DISCARDABLE\\)"
variant uninitialized "section \\.cmdline is uninitialized data \\(IMAGE_SCN_CNT_UNINITIALIZED_DATA\\)"
variant reloc "a base relocation at 0x[0-9a-f]+ changes \\.cmdline, not only systemd-stub's code and data"

# Two Authenticode signatures, the trusted key's and another (sbverify --cert accepts either), and a
# section whose data is in the certificate table (not covered by the signature).
sbsign --key "$t/other.key" --cert "$t/other.crt" --output "$t/twosigs.efi" "$t/unsigned.efi"
variant twosigs "not exactly one Authenticode signature"
# A nested signature: another key's, in the unsigned attributes of the trusted key's signature, which
# still verifies (the control: sbverify passes); Windows would take the nested one as well.
copy nested
sign "$t/unsigned.efi" "$t/nested.efi"
rm "$t/nested/$uki"
osslsigncode sign -nest -h sha256 -certs "$t/other.crt" -key "$t/other.key" -in "$t/nested.efi" -out "$t/nested/$uki" >/dev/null
sbverify --cert "$t/gate.crt" "$t/nested/$uki"
refused "not exactly one Authenticode signature: unsigned attributes in the PKCS#7 signature" "$t/nested" "$t/gate.crt"
# The same, with the unsigned attributes' tag [1] (A1) written in the high tag number form (BF 01),
# which OpenSSL also reads as [1], and the lengths around it made to match.
copy hightag
python3 -I - "$t/nested/$uki" "$t/hightag/$uki" <<'PY'
import struct
import sys
import pefile
data = open(sys.argv[1], "rb").read()
pe = pefile.PE(data=data, fast_load=True)
at = pe.OPTIONAL_HEADER.DATA_DIRECTORY[4].VirtualAddress
pkcs7 = data[at + 8:at + struct.unpack_from("<I", data, at)[0]]
def node(b, i):
    """tag, start of the contents and end of the DER element at i (one-byte tags)."""
    n, j = b[i + 1], i + 2
    if n & 0x80:
        n, j = int.from_bytes(b[j:j + (n & 0x7F)], "big"), j + (n & 0x7F)
    return b[i], j, j + n
def length(n):
    return bytes([n]) if n < 0x80 else bytes([0x80 | (n.bit_length() + 7) // 8]) + n.to_bytes((n.bit_length() + 7) // 8, "big")
def rewrite(b, i, path):
    """The element at i, its descendant along path (child indexes) re-tagged BF 01."""
    tag, start, end = node(b, i)
    if not path:
        assert tag == 0xA1, hex(tag)
        return b"\xbf\x01" + length(end - start) + b[start:end]
    kids, k = [], start
    while k < end:
        kids.append(k)
        k = node(b, k)[2]
    parts = [b[k:node(b, k)[2]] for k in kids]
    parts[path[0]] = rewrite(b, kids[path[0]], path[1:])
    return bytes([tag]) + length(sum(map(len, parts))) + b"".join(parts)
# ContentInfo > [0] > SignedData > signerInfos (last) > SignerInfo > unsigned attributes (last).
new = rewrite(pkcs7, 0, [1, 0, -1, 0, -1])
entry = struct.pack("<IHH", 8 + len(new), 0x0200, 0x0002) + new
entry += bytes(-len(entry) % 8)
p = bytearray(data[:at] + entry)
struct.pack_into("<I", p, pe.OPTIONAL_HEADER.DATA_DIRECTORY[4].get_file_offset() + 4, len(entry))
open(sys.argv[2], "wb").write(p)
PY
sbverify --cert "$t/gate.crt" "$t/hightag/$uki"
refused "the PKCS#7 signature does not parse \\(not DER: a high tag number\\)" "$t/hightag" "$t/gate.crt"
rm -rf "${t:?}/nested" "$t/nested.efi" "${t:?}/hightag"
# Two bytes after the trusted key's PKCS#7 signature, inside its certificate entry (osslsigncode leaves
# such bytes, sbsign none): the signature still verifies.
copy trailing
sign "$t/unsigned.efi" "$t/trailing.efi"
python3 -I - "$t/trailing.efi" "$t/trailing/$uki" <<'PY'
import struct
import sys
import pefile
data = open(sys.argv[1], "rb").read()
pe = pefile.PE(data=data, fast_load=True)
at = pe.OPTIONAL_HEADER.DATA_DIRECTORY[4].VirtualAddress
n = struct.unpack_from("<I", data, at)[0]
entry = struct.pack("<I", n + 2) + data[at + 4:at + n] + b"\0\0"
entry += bytes(-len(entry) % 8)
p = bytearray(data[:at] + entry)
struct.pack_into("<I", p, pe.OPTIONAL_HEADER.DATA_DIRECTORY[4].get_file_offset() + 4, len(entry))
open(sys.argv[2], "wb").write(p)
PY
sbverify --cert "$t/gate.crt" "$t/trailing/$uki"
refused "not exactly one Authenticode signature: 2 bytes after the PKCS#7 signature in its certificate entry" "$t/trailing" "$t/gate.crt"
rm -rf "${t:?}/trailing" "$t/trailing.efi"
copy certdata
sign "$t/unsigned.efi" "$t/certdata/$uki"
python3 -I - "$t/certdata/$uki" <<'PY'
import struct
import sys
import pefile
path = sys.argv[1]
p = bytearray(open(path, "rb").read())
pe = pefile.PE(data=bytes(p), fast_load=True)
last = max(pe.sections, key=lambda s: s.get_file_offset())
struct.pack_into("<I", p, last.get_file_offset() + 20, pe.OPTIONAL_HEADER.DATA_DIRECTORY[4].VirtualAddress)
open(path, "wb").write(p)
PY
refused "data of section .* is not in the file before the certificate table" "$t/certdata" "$t/gate.crt"
rm -rf "${t:?}/certdata"

echo "The UKI release gate passed all checks."
