#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: the recovery boot entry on a copy of the installed test disk (docs/BOOT.md), with Secure
# Boot on (the image's UKI certificate enrolled as a MOK) and one firmware variable store for both
# boots. Checks:
#   0. the image's signed UKI has the "Nyra OS Recovery" profile with systemd.unit=rescue.target;
#   1. a normal boot writes the recovery entry ("profile 1", after bootc's entries); bootc status does
#      not see it (one booted image, no queued rollback); the test adds an administrator (group sudo),
#      one with an empty password and a plain user, and picks the recovery entry for the next boot
#      only (bootctl set-oneshot);
#   2. the recovery entry boots profile 1 under Secure Boot and asks for an administrator: an
#      administrator with an empty password and a plain user are refused without a password prompt,
#      a wrong password gives no shell, the right one gives a root shell in rescue.target.
# The test console add-on that tools/vm/test-console.sh put on the disk is replaced by one signed
# with a key made here and enrolled as a MOK ("local"; it lives only in WORKDIR and is deleted at the
# end). The passwords are random, for this throwaway disk only.
#   tools/vm/recovery.sh IMAGE DISK.qcow2 UKI_CERT WORKDIR LOGDIR SUMMARY
set -euo pipefail

image="$1" disk="$2" uki_cert="$3" work="$4" logs="$5" summary="$6"
rc="$work/recovery"
mnt="$rc/esp"
loop=""
mkdir -p "$mnt"
trap 'sudo umount -q "$mnt" 2>/dev/null || true; [ -z "$loop" ] || sudo losetup -d "$loop" || true; rm -rf "$rc"' EXIT

openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=Nyra CI add-on test key" \
  -keyout "$rc/local.key" -out "$rc/local.crt" 2>/dev/null
tools/vm/test-addon.sh "$image" "$rc/console.addon.efi" systemd.import_credentials=yes "$rc/local.key" "$rc/local.crt"
# Owner GUID: shim's. Secure Boot on, Microsoft keys, the UKI certificate and the local key as MOKs.
virt-fw-vars --input /usr/share/OVMF/OVMF_VARS_4M.ms.fd --output "$rc/vars.fd" \
  --add-mok 605dab50-e046-4300-abb6-3dd810dd8b23 "$uki_cert" \
  --add-mok 605dab50-e046-4300-abb6-3dd810dd8b23 "$rc/local.crt"

qemu-img convert -O raw "$disk" "$rc/disk.raw"
loop="$(sudo losetup -P --show -f "$rc/disk.raw")"
esp=""
for p in "$loop"p*; do
  if [ "$(sudo blkid -o value -s TYPE "$p")" = vfat ]; then esp="$p"; fi
done
test -n "$esp"

# 0. The UKI bootc installed: signed as a whole, with the recovery profile.
sudo mount "$esp" "$mnt"
entries=("$mnt"/loader/entries/bootc_*.conf)
test "${#entries[@]}" = 1
uki="$(sed -n 's/^uki[[:space:]]\+//p' "${entries[0]}")"
sudo cp "$mnt$uki" "$rc/uki.efi"
sudo chown "$(id -u):$(id -g)" "$rc/uki.efi"
sbverify --cert "$uki_cert" "$rc/uki.efi"
{
  echo "### Recovery: the image's UKI"
  echo
  echo '```'
  ukify inspect "$rc/uki.efi" | grep -E -A3 '^\.(profile|cmdline):' | grep -v -- '--' || true
  echo '```'
} >> "$summary"
grep -aq 'TITLE=Nyra OS Recovery' "$rc/uki.efi"
grep -aq 'systemd.unit=rescue.target' "$rc/uki.efi"
sudo test -f "$mnt/loader/addons/nyra-test-console.addon.efi"
sudo cp "$rc/console.addon.efi" "$mnt/loader/addons/nyra-test-console.addon.efi"
sudo umount "$mnt"

pw="$(openssl rand -hex 12)" wrong="wrong-$(openssl rand -hex 4)"
vm() {
  python3 -B tools/vm/vm-boot.py --secure-boot "$rc/vars.fd" --keep-vars --disk "$rc/disk.raw" --persist \
    --poweroff --timeout 240 --summary "$summary" "$@"
}
# systemd-boot reports entry IDs in lower case (LoaderEntrySelected = nyra-recovery.conf).
efivar() { # guest command that prints a systemd-boot EFI variable (UTF-16 text after 4 attribute bytes)
  echo "tail -c +5 /sys/firmware/efi/efivars/$1-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f | tr -d '\\000'"
}

vm --autologin --log "$logs/serial-recovery-1.log" \
  --title "Recovery 1: normal boot, the recovery entry is written, an administrator is added" \
  --command 's="$(systemctl is-system-running --wait)"; echo "system: $s"; test "$s" = running' \
  --command 'ls /boot/loader/entries; cat /boot/loader/entries/nyra-recovery.CONF; grep -qx "profile 1" /boot/loader/entries/nyra-recovery.CONF && grep -q "^uki /EFI/Linux/bootc/bootc_composefs-" /boot/loader/entries/nyra-recovery.CONF' \
  --command 'j="$(bootc status --format json)"; echo "$j" | grep -o "\"rollbackQueued\":[a-z]*"; echo "$j" | grep -q "\"rollbackQueued\":false" && test "$(bootc status --booted --format json | grep -o "\"imageDigest\"" | wc -l)" = 1 && echo "bootc sees one booted image and no queued rollback"' \
  --command "useradd -m -G sudo -s /bin/bash nyra-admin && useradd -m -s /bin/bash nyra-user && useradd -m -G sudo -s /bin/bash nyra-nopw && printf 'nyra-admin:%s\\nnyra-user:%s\\n' '$pw' '$pw' | chpasswd && passwd -d nyra-nopw && passwd -S nyra-admin && passwd -S nyra-user && passwd -S nyra-nopw" \
  --command 'bootctl set-oneshot nyra-recovery.CONF && bootctl list --no-pager | grep -B2 -A8 "Nyra OS Recovery"'

again='Wrong user name or password, or not an administrator\.(.|\n)*Administrator user name: '
vm --log "$logs/serial-recovery-2.log" \
  --title "Recovery 2: the recovery entry asks for an administrator; a wrong password gives no shell" \
  --chat 'Administrator user name: =>nyra-nopw' \
  --chat "$again=>nyra-user" \
  --chat "$again=>nyra-admin" \
  --chat "Password: =>$wrong" \
  --chat "$again=>nyra-admin" \
  --chat "Password: =>$pw" \
  --command 'id; test "$(id -u)" = 0' \
  --command "e=\"\$($(efivar LoaderEntrySelected))\"; p=\"\$($(efivar StubProfile))\"; echo \"entry: \$e, profile: \$p\"; test \"\$e\" = nyra-recovery.conf && test \"\$p\" = 1" \
  --command 'cat /proc/cmdline; grep -q "systemd.unit=rescue.target" /proc/cmdline && grep -Eq "(^| )composefs=[0-9a-f]{128}( |$)" /proc/cmdline' \
  --command 'mokutil --sb-state; mokutil --sb-state | grep -qx "SecureBoot enabled"' \
  --command 'systemctl is-active rescue.target'
