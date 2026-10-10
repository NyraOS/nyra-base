#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: tests the UKI release gate (tools/signing/uki-gate.sh, docs/SIGNING.md) on IMAGE, whose UKI
# is signed with this run's throwaway key (RUN_CERT), on every build:
#   - accepted with RUN_CERT (the gate passes a correct image, so its refusals below mean something);
#   - refused exactly as the sign job runs it, with the committed Nyra certificate: an image signed
#     with a test key never gets a release signature;
#   - refused with a certificate that did not sign it;
#   - refused, even when signed with the trusted key: an add-on in place of the UKI, the UKI with
#     another command line, a second UKI, an add-on next to the UKI.
# The "gate" and "other" keys are made here, live only in WORKDIR on the ephemeral runner and are
# deleted at the end: never commit or upload them, never use a real key here.
#   tools/signing/test-uki-gate.sh IMAGE RUN_CERT WORKDIR
set -euo pipefail

image="$1" run_cert="$2" work="$3"
t="$work/uki-gate-test"
nyra_cert=files/usr/lib/nyra/secureboot/nyra.crt
mkdir -p "$t"
trap 'sudo rm -rf "$t"' EXIT

gate() { tools/signing/uki-gate.sh "$@"; }
# refused REASON BOOT_DIR CERT: the gate must fail, and for REASON (an extended regular expression).
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
refused "no Nyra UKI certificate|is not signed with" "$t/image" "$nyra_cert"
refused "is not signed with" "$t/image" "$t/other.crt"

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

echo "The UKI release gate passed all checks."
