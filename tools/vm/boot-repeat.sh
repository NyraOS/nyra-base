#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only, on request (image.yml, boot-rounds): boots a copy of the installed test disk ROUNDS times,
# each from the same state, under Secure Boot (the image's UKI certificate enrolled as a MOK, as in
# tools/vm/boot-protection.sh), to find boots that fail only now and then. udev logs at debug level
# in the initrd; a boot that ends in emergency mode prints what udev saw (vm-boot.py), and its serial
# log is kept. First, one boot whose root mount is made to fail in the initrd checks that those
# diagnostics show up.
#   tools/vm/boot-repeat.sh IMAGE DISK.raw UKI_CERT WORKDIR LOGDIR SUMMARY ROUNDS
set -euo pipefail

image="$1" disk="$2" uki_cert="$3" work="$4" logs="$5" summary="$6" rounds="$7"
br="$work/boot-repeat"
mnt="$br/esp"
loop=""
mkdir -p "$mnt"
trap 'sudo umount -q "$mnt" 2>/dev/null || true; [ -z "$loop" ] || sudo losetup -d "$loop" || true; rm -rf "$br"' EXIT

openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=Nyra CI add-on test key" \
  -keyout "$br/local.key" -out "$br/local.crt" 2>/dev/null
tools/vm/test-addon.sh "$image" "$br/console.addon.efi" "systemd.import_credentials=yes rd.udev.log_level=debug" \
  "$br/local.key" "$br/local.crt"
virt-fw-vars --input /usr/share/OVMF/OVMF_VARS_4M.ms.fd --output "$br/vars.fd" \
  --add-mok 605dab50-e046-4300-abb6-3dd810dd8b23 "$uki_cert" \
  --add-mok 605dab50-e046-4300-abb6-3dd810dd8b23 "$br/local.crt"
cp "$disk" "$br/disk.raw"
loop="$(sudo losetup -P --show -f "$br/disk.raw")"
esp=""
for p in "$loop"p*; do
  if [ "$(sudo blkid -o value -s TYPE "$p")" = vfat ]; then esp="$p"; fi
done
test -n "$esp"
sudo mount "$esp" "$mnt"
sudo mkdir -p "$mnt/loader/addons"
sudo cp "$br/console.addon.efi" "$mnt/loader/addons/nyra-test-console.addon.efi"
sudo umount "$mnt"
sudo losetup -d "$loop"
loop=""

boot() {
  python3 tools/vm/vm-boot.py --secure-boot "$br/vars.fd" --autologin --disk "$br/disk.raw" --timeout 240 \
    --summary "$br/summary.md" "$@"
}

boot --log "$logs/serial-boot-repeat-diagnostics.log" --refused '@@ end of diagnostics' \
  --credential $'systemd.unit-dropin.sysroot.mount=[Mount]\nOptions=nyra-test-bad-option\n' \
  --title "Repeated boots: a boot made to fail in the initrd prints the diagnostics"
grep -q 'ID_PART_GPT_AUTO_ROOT=1' "$logs/serial-boot-repeat-diagnostics.log"

failed=()
start=$SECONDS
for i in $(seq "$rounds"); do
  if ! boot --log "$br/serial.log" --title "Boot $i" --command true > "$br/out.txt"; then
    failed+=("$i")
    cp "$br/serial.log" "$logs/serial-boot-repeat-$i.log"
    cat "$br/out.txt"
  fi
done
{
  echo "### Repeated boots: ${#failed[@]} of $rounds failed"
  echo
  echo "Secure Boot, the same disk state every time, $((SECONDS - start)) s.${failed[*]:+ Failed: ${failed[*]} (serial logs kept).}"
  echo
} | tee -a "$summary"
test "${#failed[@]}" = 0
