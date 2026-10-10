#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: "Nyra OS Reset settings" on a copy of the installed test disk (docs/BOOT.md), with Secure
# Boot on (the image's UKI certificate enrolled as a MOK) and one firmware variable store for all
# boots. One system:
#   1. normal boot: an administrator with a password and a file in /home, a host name; then the
#      configuration broken as a user could (garbage in /etc/fstab and /etc/passwd, systemd-resolved
#      masked, /etc/resolv.conf deleted, a stray file); the reset entry (profile 2) is there; it is
#      picked for the next boot only (bootctl set-oneshot);
#   2-3. the reset entry, answered with something else than RESET, then with Control-D: nothing
#      changes, the normal boot continues;
#   4. the reset, with a power cut as it starts building the new /etc; 5. a normal boot: /etc is
#      either all old or all new, never half;
#   6. the reset, with a power cut as it switches to the new /etc; 7. the same check;
#   8. the reset, with a power cut right after the switch; 9. the new /etc is in place, the system
#      runs, and the previous /etc is still there as etc.nyra-new (kept by the next reset);
#   10. the reset: /etc is the image's again, the system reboots by itself into the normal boot:
#      the breakage is gone, the administrator, their password, their groups and /home are kept, and
#      so are the machine ID and the host name; the previous /etc is kept as etc.nyra-old (0700);
#   11. the reset, with a power cut right after it makes the new /etc's directory; 12. no
#      etc.nyra-new without its marker (which the next reset would keep instead of etc.nyra-old), and
#      etc.nyra-old as it was.
# The test console add-on that tools/vm/test-console.sh put on the disk is replaced by one signed
# with a key made here and enrolled as a MOK ("local"; it lives only in WORKDIR and is deleted at the
# end). The password is random, for this throwaway disk only.
#   tools/vm/reset-settings.sh IMAGE DISK.qcow2 UKI_CERT WORKDIR LOGDIR SUMMARY
set -euo pipefail

image="$1" disk="$2" uki_cert="$3" work="$4" logs="$5" summary="$6"
rs="$work/reset-settings"
mnt="$rs/esp"
loop=""
mkdir -p "$mnt"
trap 'sudo umount -q "$mnt" 2>/dev/null || true; [ -z "$loop" ] || sudo losetup -d "$loop" || true; rm -rf "$rs"' EXIT

openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=Nyra CI add-on test key" \
  -keyout "$rs/local.key" -out "$rs/local.crt" 2>/dev/null
tools/vm/test-addon.sh "$image" "$rs/console.addon.efi" systemd.import_credentials=yes "$rs/local.key" "$rs/local.crt"
# Owner GUID: shim's. Secure Boot on, Microsoft keys, the UKI certificate and the local key as MOKs.
virt-fw-vars --input /usr/share/OVMF/OVMF_VARS_4M.ms.fd --output "$rs/vars.fd" \
  --add-mok 605dab50-e046-4300-abb6-3dd810dd8b23 "$uki_cert" \
  --add-mok 605dab50-e046-4300-abb6-3dd810dd8b23 "$rs/local.crt"

qemu-img convert -O raw "$disk" "$rs/disk.raw"
loop="$(sudo losetup -P --show -f "$rs/disk.raw")"
esp=""
for p in "$loop"p*; do
  if [ "$(sudo blkid -o value -s TYPE "$p")" = vfat ]; then esp="$p"; fi
done
test -n "$esp"
sudo mount "$esp" "$mnt"
entries=("$mnt"/loader/entries/bootc_*.conf)
test "${#entries[@]}" = 1
uki="$(sed -n 's/^uki[[:space:]]\+//p' "${entries[0]}")"
sudo grep -aq 'TITLE=Nyra OS Reset settings' "$mnt$uki"
sudo grep -aq 'systemd.unit=nyra-reset-settings.target' "$mnt$uki"
sudo test -f "$mnt/loader/addons/nyra-test-console.addon.efi"
sudo cp "$rs/console.addon.efi" "$mnt/loader/addons/nyra-test-console.addon.efi"
sudo umount "$mnt"

pw="$(openssl rand -hex 12)"
vm() {
  python3 -B tools/vm/vm-boot.py --secure-boot "$rs/vars.fd" --keep-vars --disk "$rs/disk.raw" --persist \
    --autologin --timeout 240 --summary "$summary" "$@"
}
running='s="$(systemctl is-system-running --wait)"; echo "system: $s"; systemctl --no-pager --failed; test "$s" = running'
oneshot='bootctl set-oneshot nyra-reset.CONF && echo "next boot: reset entry"'
before=/home/nyra-admin/before
# systemd-boot reports entry IDs in lower case (LoaderEntrySelected = nyra-reset.conf).
efivar() { # guest command that prints a systemd-boot EFI variable (UTF-16 text after 4 attribute bytes)
  echo "tail -c +5 /sys/firmware/efi/efivars/$1-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f | tr -d '\\000'"
}
# /etc entirely as broken in boot 1, or entirely reset: nothing in between.
whole='a=0; b=0; for t in "test -e /etc/nyra-test-junk" "grep -q garbage /etc/fstab" "grep -q broken-line /etc/passwd" "test -L /etc/systemd/system/systemd-resolved.service"; do if eval "$t"; then a=$((a+1)); else b=$((b+1)); fi; done; echo "old: $a, reset: $b"; test "$a" = 4 || test "$b" = 4'
answer='Type RESET to reset, anything else or Control-D to boot normally: '
unchanged='test -e /etc/nyra-test-junk && grep -q garbage /etc/fstab && echo "the settings are as they were"'
state='s="/sysroot/state/deploy/$(sed -En "s/^(.* )?composefs=([0-9a-f]+)( .*)?$/\2/p" /proc/cmdline)"'

vm --poweroff --log "$logs/serial-reset-settings-1.log" \
  --title "Reset settings 1: an administrator and a host name, then broken settings; the reset entry is there" \
  --command "$running" \
  --command "useradd -m -G sudo -s /bin/bash nyra-admin && printf 'nyra-admin:%s\\n' '$pw' | chpasswd && echo kept > /home/nyra-admin/keep.txt && echo nyra-test-host > /etc/hostname && mkdir -p $before && cp /etc/machine-id $before/ && grep '^nyra-admin:' /etc/shadow > $before/shadow && id nyra-admin" \
  --command 'echo "garbage line, not a mount" >> /etc/fstab && echo broken-line >> /etc/passwd && systemctl mask systemd-resolved.service && rm -f /etc/resolv.conf && echo junk > /etc/nyra-test-junk' \
  --command 'cat /boot/loader/entries/nyra-reset.CONF; grep -qx "profile 2" /boot/loader/entries/nyra-reset.CONF' \
  --command "$oneshot"

vm --poweroff --log "$logs/serial-reset-settings-2.log" --chat-then-login --chat "$answer=>no" \
  --title "Reset settings 2: the reset entry answered with something else than RESET: nothing changes" \
  --command "$(efivar LoaderEntrySelected); echo; test \"\$($(efivar LoaderEntrySelected))\" = nyra-reset.conf" \
  --command "$unchanged" \
  --command "$oneshot"

vm --poweroff --log "$logs/serial-reset-settings-3.log" --chat-then-login --chat "$answer=>@ctrl-d" \
  --title "Reset settings 3: the reset entry answered with Control-D: nothing changes" \
  --command "$(efivar LoaderEntrySelected); echo; test \"\$($(efivar LoaderEntrySelected))\" = nyra-reset.conf" \
  --command "$unchanged" \
  --command "$oneshot"

vm --log "$logs/serial-reset-settings-4.log" --chat "$answer=>RESET" --power-cut-at 'reset-settings: building the new /etc' \
  --title "Reset settings 4: power cut as the reset starts building the new /etc"

vm --poweroff --log "$logs/serial-reset-settings-5.log" \
  --title "Reset settings 5: after that power cut, /etc is whole" \
  --command "$whole" \
  --command "$oneshot"

vm --log "$logs/serial-reset-settings-6.log" --chat "$answer=>RESET" --power-cut-at 'reset-settings: switching to the new /etc' \
  --title "Reset settings 6: power cut as the reset switches to the new /etc"

vm --poweroff --log "$logs/serial-reset-settings-7.log" \
  --title "Reset settings 7: after that power cut, /etc is whole" \
  --command "$whole" \
  --command "$oneshot"

vm --log "$logs/serial-reset-settings-8.log" --chat "$answer=>RESET" --power-cut-at 'reset-settings: switched to the new /etc' \
  --title "Reset settings 8: power cut right after the switch"

vm --poweroff --log "$logs/serial-reset-settings-9.log" \
  --title "Reset settings 9: after that power cut, the new /etc is in place and the previous one is still there" \
  --command "$running" \
  --command 'test ! -e /etc/nyra-test-junk && ! grep -q garbage /etc/fstab && ! grep -q broken-line /etc/passwd && test ! -L /etc/systemd/system/systemd-resolved.service && echo "old: 0, reset: 4"' \
  --command "$state; ls -a \$s; test -e \$s/etc.nyra-new/nyra-test-junk && test ! -e \$s/etc.nyra-new/.nyra-reset-new && echo 'etc.nyra-new holds the previous /etc (no marker)'" \
  --command "$oneshot"

vm --poweroff --log "$logs/serial-reset-settings-10.log" --chat-then-login --chat "$answer=>RESET" \
  --title "Reset settings 10: the reset, then the normal boot with the image's /etc and the kept accounts" \
  --command "$running" \
  --command 'test ! -e /etc/nyra-test-junk && ! grep -q garbage /etc/fstab && ! grep -q broken-line /etc/passwd && test "$(systemctl is-enabled systemd-resolved.service)" != masked && test -L /etc/resolv.conf && test ! -e /etc/.nyra-reset-new && echo "the broken settings are gone"' \
  --command "id nyra-admin && id -nG nyra-admin | grep -qw sudo && passwd -S nyra-admin | grep -q ' P ' && grep '^nyra-admin:' /etc/shadow | cmp - $before/shadow && echo 'the administrator and their password are kept'" \
  --command "test \"\$(cat /home/nyra-admin/keep.txt)\" = kept && cmp /etc/machine-id $before/machine-id && test \"\$(cat /etc/hostname)\" = nyra-test-host && echo '/home, the machine ID and the host name are kept'" \
  --command "$state; ls -a \$s; test \"\$(stat -c %a \$s/etc.nyra-old)\" = 700 && test ! -e \$s/etc.nyra-new && echo 'the previous /etc is kept as etc.nyra-old (0700)'" \
  --command "$oneshot"

vm --log "$logs/serial-reset-settings-11.log" --chat "$answer=>RESET" --power-cut-at 'reset-settings: preparing the new /etc' \
  --title "Reset settings 11: power cut right after the new /etc's directory is made"

vm --poweroff --log "$logs/serial-reset-settings-12.log" \
  --title "Reset settings 12: after that power cut, no etc.nyra-new without its marker, etc.nyra-old as it was" \
  --command "$running" \
  --command "$state; ls -a \$s; { test ! -e \$s/etc.nyra-new || test -e \$s/etc.nyra-new/.nyra-reset-new; } && test -f \$s/etc.nyra-old/passwd && test \"\$(stat -c %a \$s/etc.nyra-old)\" = 700 && echo 'no etc.nyra-new without the marker; etc.nyra-old is intact'"
