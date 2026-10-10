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
#     policy;
#   - refused, even when signed with the trusted key: an add-on in place of the UKI, the UKI with
#     another command line, a second UKI, an add-on next to the UKI, the UKI without its PCR policy,
#     with a policy signature that does not verify, and with the policy moved to the recovery profile.
# The "gate" and "other" keys are made here, live only in WORKDIR on the ephemeral runner and are
# deleted at the end: never commit or upload them, never use a real key here.
#   tools/signing/test-uki-gate.sh IMAGE RUN_CERT RUN_PCR_KEY WORKDIR
set -euo pipefail

image="$1" run_cert="$2" run_pcr="$3" work="$4"
t="$work/uki-gate-test"
nyra_cert=files/usr/lib/nyra/secureboot/nyra.crt
nyra_pcr=files/usr/lib/nyra/secureboot/tpm2-pcr-public-key.pem
mkdir -p "$t"
trap 'sudo rm -rf "$t"' EXIT

# gate BOOT_DIR CERT [PCR_KEY]: the policy key is this run's unless given.
gate() { tools/signing/uki-gate.sh "$1" "$2" "${3:-$run_pcr}"; }
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
refused "no Nyra UKI certificate|no Nyra PCR policy public key|is not signed with|PCR policy signed with" \
  "$t/image" "$nyra_cert" "$nyra_pcr"
refused "is not signed with" "$t/image" "$t/other.crt"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null | openssl pkey -pubout -out "$t/other-pcr.pem"
refused "\\.pcrpkey is not" "$t/image" "$run_cert" "$t/other-pcr.pem"

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
# section header swapped with the one of the recovery profile's .profile, right after it).
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
refused "not in the main profile alone" "$t/nopolicy" "$t/gate.crt"
refused "does not verify" "$t/badsig" "$t/gate.crt"
refused "not in the main profile alone: .*'recovery'" "$t/recovery" "$t/gate.crt"

echo "The UKI release gate passed all checks."
