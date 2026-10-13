#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only (image.yml): boots a copy of the installed test disk ROUNDS times, each from the same state,
# under Secure Boot (the image's UKI certificate enrolled as a MOK, as in tools/vm/boot-protection.sh),
# to find boots that fail only now and then (on request, boot-rounds). A boot that ends in
# emergency mode prints what udev saw (vm-boot.py), and its serial log is kept. udev logs at its usual
# level, as in the other boot tests: the boots that failed now and then in CI did so without debug
# logging, never with it. The test add-on also turns the image's rd.emergency=reboot into a halt, so
# that a boot that ends in the initrd's emergency mode does not start again (after its diagnostics).
# First, three checks:
# - a boot whose root mount is made to fail in the initrd shows those diagnostics;
# - a boot whose first probe of the boot disk cannot read LoaderDevicePartUUID (a test-only udev rule
#   puts a 1-byte file over it for that probe only, inside systemd-udevd's own mount namespace)
#   without the image's rule that probes the disk again (masked): the initrd waits for its root in
#   vain, as in the boots that failed in CI;
# - the same boot with that rule: the root partition is found and the system starts.
# install-boot runs these checks on every image (ROUNDS 0), so that a systemd or dracut update that
# changes the order of the udev rules or what the initrd holds is caught.
#   tools/vm/boot-repeat.sh IMAGE DISK UKI_CERT WORKDIR LOGDIR SUMMARY ROUNDS   (DISK: raw or qcow2)
set -euo pipefail

image="$1" disk="$2" uki_cert="$3" work="$4" logs="$5" summary="$6" rounds="$7"
br="$work/boot-repeat"
mnt="$br/esp"
loop=""
mkdir -p "$mnt"
trap 'sudo umount -q "$mnt" 2>/dev/null || true; [ -z "$loop" ] || sudo losetup -d "$loop" || true; rm -rf "$br"' EXIT

openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=Nyra CI add-on test key" \
  -keyout "$br/local.key" -out "$br/local.crt" 2>/dev/null
tools/vm/test-addon.sh "$image" "$br/console.addon.efi" "systemd.import_credentials=yes rd.emergency=halt" \
  "$br/local.key" "$br/local.crt"
virt-fw-vars --input /usr/share/OVMF/OVMF_VARS_4M.ms.fd --output "$br/vars.fd" \
  --add-mok 605dab50-e046-4300-abb6-3dd810dd8b23 "$uki_cert" \
  --add-mok 605dab50-e046-4300-abb6-3dd810dd8b23 "$br/local.crt"
qemu-img convert -O raw "$disk" "$br/disk.raw"
loop="$(sudo losetup -P --show -f "$br/disk.raw")"
esp="$(tools/vm/esp-of.sh "$loop")"
sudo mount "$esp" "$mnt"
sudo mkdir -p "$mnt/loader/addons"
sudo cp "$br/console.addon.efi" "$mnt/loader/addons/nyra-test-console.addon.efi"
sudo umount "$mnt"
sudo losetup -d "$loop"
loop=""

boot() {
  python3 tools/vm/vm-boot.py --secure-boot "$br/vars.fd" --autologin --disk "$br/disk.raw" --timeout 240 \
    --summary "$summary" "$@"
}

boot --log "$logs/serial-boot-repeat-diagnostics.log" --refused '@@ end of diagnostics' \
  --credential $'systemd.unit-dropin.sysroot.mount=[Mount]\nOptions=nyra-test-bad-option\n' \
  --title "Repeated boots: a boot made to fail in the initrd prints the diagnostics"
grep -q 'ID_PART_GPT_AUTO_ROOT=1' "$logs/serial-boot-repeat-diagnostics.log"

# The failed read of LoaderDevicePartUUID: a drop-in for systemd-udevd (initrd only; no system call
# filter, so that its rules may mount) writes two rules around the probe in 60-persistent-storage.rules,
# for the first event of the boot disk only. The second one leaves a mark that the file was in place.
fail_once="$(sed "s|@VAR@|/sys/firmware/efi/efivars/LoaderDevicePartUUID-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f|g" <<'EOF'
systemd.unit-dropin.systemd-udevd.service=[Service]
SystemCallFilter=
ExecStartPre=/bin/sh -c "test -e /etc/initrd-release || exit 0; echo x >/run/nyra-test-efivar; mkdir -p /run/udev/rules.d; \
  echo 'ACTION==\"add\", SUBSYSTEM==\"block\", KERNEL==\"vda\", TEST==\"/etc/initrd-release\", \
  PROGRAM=\"/bin/mount --bind /run/nyra-test-efivar @VAR@\"' >/run/udev/rules.d/59-nyra-test-efivar.rules; \
  echo 'ACTION==\"add\", SUBSYSTEM==\"block\", KERNEL==\"vda\", TEST==\"/etc/initrd-release\", \
  PROGRAM=\"/bin/umount @VAR@\", RUN+=\"/bin/mkdir /run/nyra-test-efivar-failed-once\"' \
  >/run/udev/rules.d/60-zz-nyra-test-efivar.rules"
EOF
)"
masked="${fail_once%\"}; : >/run/udev/rules.d/61-nyra-gpt-auto-root.rules\""
boot --log "$logs/serial-boot-repeat-efivar-unread.log" --refused '@@ end of diagnostics' --credential "$masked" \
  --title "Repeated boots: the first probe of the boot disk cannot read LoaderDevicePartUUID, no second probe"
grep -q 'ls: cannot access .*/dev/gpt-auto-root' "$logs/serial-boot-repeat-efivar-unread.log"
if grep -q 'ID_PART_GPT_AUTO_ROOT=1' "$logs/serial-boot-repeat-efivar-unread.log"; then
  echo "the root partition was marked although LoaderDevicePartUUID could not be read"
  exit 1
fi
boot --log "$logs/serial-boot-repeat-efivar-unread-probed-again.log" --credential "$fail_once" \
  --title "Repeated boots: the first probe of the boot disk cannot read LoaderDevicePartUUID, the second one can" \
  --command 'test -d /run/nyra-test-efivar-failed-once && echo "the first probe of the boot disk could not read LoaderDevicePartUUID; the system started"'

if [ "$rounds" = 0 ]; then exit 0; fi
failed=()
start=$SECONDS
for i in $(seq "$rounds"); do
  # Only the result of all the rounds goes into the summary (below): the last --summary counts.
  if ! boot --summary "$br/summary.md" --log "$br/serial.log" --title "Boot $i" --command true > "$br/out.txt"; then
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
