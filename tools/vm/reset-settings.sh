#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: "Nyra OS Reset settings" on a copy of the installed test disk (docs/BOOT.md), with Secure
# Boot on (the image's UKI certificate enrolled as a MOK) and one firmware variable store for all
# boots. One system:
#   1. normal boot: an administrator with a password and a file in /home, a host name; then the
#      configuration broken as a user could (garbage in /etc/fstab and /etc/passwd, systemd-resolved
#      masked, /etc/resolv.conf deleted, a stray file), and accounts written by root: a name twice in
#      passwd and shadow, first with UID 0, then with a regular UID, a group name twice, first
#      with GID 0, then with a regular GID, a user with the primary GID 0, a user whose subordinate
#      UIDs start at 0 (and whose subordinate GIDs are valid), and a user with two subordinate UID
#      ranges; the reset entry (profile 2) is there; it is picked for the next boot only (bootctl
#      set-oneshot);
#   2-3. the reset entry, answered with something else than RESET, then with Control-D: nothing
#      changes, the normal boot continues;
#   4. the reset, with a power cut as it starts building the new /etc; 5. a normal boot: /etc is
#      either all old or all new, never half;
#   6. the reset, with a power cut as it switches to the new /etc; 7. the same check;
#   8. the reset, with a power cut right after the switch; 9. the new /etc is in place, the system
#      runs, and the previous /etc is still there as etc.nyra-new (kept by the next reset); the
#      reset's marker, still in /etc, is 0600: the files the reset makes (its temporary copies of
#      group and gshadow too) are for root only (umask 077);
#   10. the reset: /etc is the image's again, the system reboots by itself into the normal boot:
#      the breakage is gone, the administrator, their password, their groups and /home are kept, and
#      so are the machine ID (0444) and the host name (0644); nothing of the duplicated names is kept
#      (root is the only UID 0), nor the user with GID 0, nor the subordinate UIDs from 0 or of the
#      name found twice (those users and the valid subordinate GIDs are kept), while the
#      administrator keeps their groups and their own ranges; the previous /etc is kept as
#      etc.nyra-old (0700);
#   11. the reset, with a power cut right after it makes the new /etc's directory; 12. no
#      etc.nyra-new without its marker (which the next reset would keep instead of etc.nyra-old), and
#      etc.nyra-old as it was;
#   13. /etc/fstab broken without nofail (a disk that is not connected, a line that is not a mount, a
#      proc mount with an option it does not know, which fails before the ESP and /tmp are mounted, a
#      swap partition on a disk that is not connected), then a normal boot: no emergency mode, only
#      the wrong mount failed; the boot loader random seed ordered after boot.mount, and the ESP
#      checked, then mounted, then written by it; nyra-boot-repair run; the boot's tmpfiles ordered
#      after tmp.mount and run after it (/tmp/.X11-unix root, 1777); the device timeout is 10 s, and
#      the journal names the missing disk less than 20 s after the start of the system;
#   14. the reset entry with that /etc/fstab, answered with something else than RESET: fstab=no on the
#      command line, /etc/fstab not read, no emergency mode, the question within 30 s of the start of
#      the system;
#   15. the reset with that /etc/fstab; the normal boot after it runs, without those lines;
#   16. /etc emptied, then a power cut; 17. the normal boot (not the reset entry): a first boot, so
#      systemd-firstboot runs, but it asks for no root password and the boot goes on; root is locked
#      (its line in /etc/shadow, printed on the console by a drop-in passed as a credential, so the
#      check does not depend on a login with /etc emptied).
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
  --command "useradd -m -G sudo -s /bin/bash nyra-admin && printf 'nyra-admin:%s\\n' '$pw' | chpasswd && echo kept > /home/nyra-admin/keep.txt && echo nyra-test-host > /etc/hostname && mkdir -p $before && cp /etc/machine-id $before/ && grep '^nyra-admin:' /etc/shadow > $before/shadow && id nyra-admin && id -nG nyra-admin > $before/groups && grep '^nyra-admin:' /etc/subuid /etc/subgid > $before/subids && cat $before/subids && test \"\$(wc -l < $before/subids)\" = 2" \
  --command 'echo "garbage line, not a mount" >> /etc/fstab && echo broken-line >> /etc/passwd && systemctl mask systemd-resolved.service && rm -f /etc/resolv.conf && echo junk > /etc/nyra-test-junk' \
  --command 'printf "nyra-dup:x:0:0::/root:/bin/bash\nnyra-dup:x:1001:1001::/home/nyra-dup:/bin/bash\n" >> /etc/passwd && printf "nyra-dup:*:1::::::\nnyra-dup:*:1::::::\n" >> /etc/shadow && printf "nyra-dupg:x:0:nyra-admin\nnyra-dupg:x:1002:nyra-admin\n" >> /etc/group && grep "^nyra-dup" /etc/passwd /etc/group' \
  --command "printf 'nyra-gid0:x:1004:0::/home/nyra-gid0:/bin/bash\\nnyra-sub:x:1005:1005::/home/nyra-sub:/bin/bash\\nnyra-sub2:x:1006:1006::/home/nyra-sub2:/bin/bash\\n' >> /etc/passwd && printf 'nyra-gid0:*:1::::::\\nnyra-sub:*:1::::::\\nnyra-sub2:*:1::::::\\n' >> /etc/shadow && printf 'nyra-sub:x:1005:\\nnyra-sub2:x:1006:\\n' >> /etc/group && printf 'nyra-sub:!::\\nnyra-sub2:!::\\n' >> /etc/gshadow && printf 'nyra-gid0:296608:65536\\nnyra-sub:0:65536\\nnyra-sub2:427680:65536\\nnyra-sub2:493216:65536\\n' >> /etc/subuid && printf 'nyra-sub:362144:65536\\n' >> /etc/subgid && grep -h '^nyra-gid0:\\|^nyra-sub' /etc/passwd /etc/subuid /etc/subgid" \
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
  --command 'stat -c "%a %n" /etc/.nyra-reset-new && test "$(stat -c %a /etc/.nyra-reset-new)" = 600 && echo "the files the reset makes are for root only"' \
  --command "$oneshot"

vm --poweroff --log "$logs/serial-reset-settings-10.log" --chat-then-login --chat "$answer=>RESET" \
  --title "Reset settings 10: the reset, then the normal boot with the image's /etc and the kept accounts" \
  --command "$running" \
  --command 'test ! -e /etc/nyra-test-junk && ! grep -q garbage /etc/fstab && ! grep -q broken-line /etc/passwd && test "$(systemctl is-enabled systemd-resolved.service)" != masked && test -L /etc/resolv.conf && test ! -e /etc/.nyra-reset-new && echo "the broken settings are gone"' \
  --command "id nyra-admin && id -nG nyra-admin | grep -qw sudo && passwd -S nyra-admin | grep -q ' P ' && grep '^nyra-admin:' /etc/shadow | cmp - $before/shadow && echo 'the administrator and their password are kept'" \
  --command 'awk -F: "\$3 == 0" /etc/passwd; test "$(awk -F: "\$3 == 0 { print \$1 }" /etc/passwd)" = root && ! grep -q "^nyra-dup" /etc/passwd /etc/shadow /etc/group /etc/gshadow && ! id -nG nyra-admin | grep -qw nyra-dupg && echo "nothing of the duplicated names is kept; root is the only UID 0"' \
  --command "grep '^nyra-admin:' /etc/subuid /etc/subgid | cmp - $before/subids && id -nG nyra-admin | cmp - $before/groups && grep '^nyra-sub' /etc/passwd /etc/subuid /etc/subgid && ! grep '^nyra-gid0:' /etc/passwd /etc/shadow /etc/subuid /etc/subgid && grep -q '^nyra-sub:x:1005:1005:' /etc/passwd && grep -q '^nyra-sub2:x:1006:1006:' /etc/passwd && ! grep -q '^nyra-sub:' /etc/subuid && grep -qx 'nyra-sub:362144:65536' /etc/subgid && ! grep -q '^nyra-sub2:' /etc/subuid && echo 'no user with GID 0, no subordinate range from 0 or of a name found twice (those users kept, a valid range kept); the administrator keeps their groups and ranges'" \
  --command "test \"\$(cat /home/nyra-admin/keep.txt)\" = kept && cmp /etc/machine-id $before/machine-id && test \"\$(cat /etc/hostname)\" = nyra-test-host && test \"\$(stat -c %a /etc/machine-id) \$(stat -c %a /etc/hostname)\" = '444 644' && echo '/home, the machine ID (0444) and the host name (0644) are kept'" \
  --command "$state; ls -a \$s; test \"\$(stat -c %a \$s/etc.nyra-old)\" = 700 && test ! -e \$s/etc.nyra-new && echo 'the previous /etc is kept as etc.nyra-old (0700)'" \
  --command "$oneshot"

vm --log "$logs/serial-reset-settings-11.log" --chat "$answer=>RESET" --power-cut-at 'reset-settings: preparing the new /etc' \
  --title "Reset settings 11: power cut right after the new /etc's directory is made"

vm --poweroff --log "$logs/serial-reset-settings-12.log" \
  --title "Reset settings 12: after that power cut, no etc.nyra-new without its marker, etc.nyra-old as it was" \
  --command "$running" \
  --command "$state; ls -a \$s; { test ! -e \$s/etc.nyra-new || test -e \$s/etc.nyra-new/.nyra-reset-new; } && test -f \$s/etc.nyra-old/passwd && test \"\$(stat -c %a \$s/etc.nyra-old)\" = 700 && echo 'no etc.nyra-new without the marker; etc.nyra-old is intact'"

# A broken /etc/fstab (docs/BOOT.md, "Mounts from /etc/fstab"), none of its lines with nofail: a disk
# that is not connected, a swap partition on a disk that is not connected (tmp.mount waits for
# swap.target), a line that is not a mount, and a mount that fails at once (proc with an option it does
# not know: unlike tmpfs it does not wait for swap.target), so local-fs.target fails before the ESP and
# /tmp are mounted.
break_fstab="printf 'garbage line, not a mount\\nLABEL=nyra-missing /var/mnt/missing ext4 defaults 0 2\\nLABEL=nyra-missing-swap none swap defaults 0 0\\nproc /var/mnt/invalid proc nyra-no-such-option 0 0\\n' >> /etc/fstab && cat /etc/fstab"
no_emergency='test "$(systemctl show -P ActiveEnterTimestampMonotonic emergency.target)" = 0 && echo "emergency mode was never entered"'
missing='/dev/disk/by-label/nyra-missing'
# The ESP's order, whatever local-fs.target did: its file system check, then boot.mount, and only then
# the boot loader's random seed, the first unit that writes to it (through esp-writable); then
# nyra-boot-repair ran. Monotonic times in microseconds. The only file system check that ran is the
# ESP's (the missing disk's never starts).
esp_order='i="$(systemctl show -P StateChangeTimestampMonotonic var-mnt-invalid.mount)"; echo "var-mnt-invalid.mount failed at $i"; systemctl show -P After systemd-boot-random-seed.service | tr " " "\n" | grep -qx boot.mount && echo "systemd-boot-random-seed: After=boot.mount" && c="$(systemctl list-units --plain --no-legend --state=active "systemd-fsck@*" | cut -d " " -f 1)"; f="$(systemctl show -P ActiveEnterTimestampMonotonic "$c")"; m="$(systemctl show -P ActiveEnterTimestampMonotonic boot.mount)"; r="$(systemctl show -P InactiveExitTimestampMonotonic systemd-boot-random-seed.service)"; echo "$c done at $f, boot.mount at $m, the boot loader random seed started at $r"; systemctl is-active boot.mount && test "$f" -gt 0 && test "$m" -ge "$f" && test "$r" -ge "$m" && test "$i" -gt 0 && test "$i" -lt "$m" && test "$(systemctl show -P Result nyra-boot-repair.service)" = success && test "$(systemctl show -P ExecMainExitTimestampMonotonic nyra-boot-repair.service)" -gt 0 && echo "the ESP was checked and mounted before anything wrote to it; nyra-boot-repair ran"'
# /tmp's order too: tmp.mount, then the boot's tmpfiles, which made /tmp/.X11-unix (root, 1777).
tmp_order='systemctl show -P After systemd-tmpfiles-setup.service | tr " " "\n" | grep -qx tmp.mount && echo "systemd-tmpfiles-setup: After=tmp.mount" && i="$(systemctl show -P StateChangeTimestampMonotonic var-mnt-invalid.mount)"; m="$(systemctl show -P ActiveEnterTimestampMonotonic tmp.mount)"; t="$(systemctl show -P InactiveExitTimestampMonotonic systemd-tmpfiles-setup.service)"; echo "tmp.mount at $m, the boot'"'"'s tmpfiles started at $t"; stat -c "%U %a %n" /tmp/.X11-unix; systemctl is-active tmp.mount systemd-tmpfiles-setup.service && test "$m" -gt 0 && test "$t" -ge "$m" && test "$i" -lt "$m" && test "$(stat -c "%U %a" /tmp/.X11-unix)" = "root 1777" && echo "/tmp was mounted before the boot'"'"'s tmpfiles ran"'

# After the reboot: the journal's line for the missing disk (waited for: the login prompt can come
# first), and how long after the start of the system (systemd in the root file system) it came.
vm --poweroff --log "$logs/serial-reset-settings-13.log" \
  --title "Reset settings 13: /etc/fstab with a disk that is not connected and wrong lines; the normal boot goes on" \
  --command "$break_fstab" \
  --command '@reboot systemctl reboot' \
  --command 's="$(systemctl is-system-running --wait)"; echo "system: $s"; systemctl --no-pager --failed; test "$s" = degraded && test "$(systemctl --failed --plain --no-legend | cut -d " " -f 1)" = var-mnt-invalid.mount && echo "only the mount that cannot work failed"' \
  --command "$no_emergency" \
  --command "$esp_order" \
  --command "$tmp_order" \
  --command "journalctl -b -o cat --no-pager | grep -E 'nyra-missing|var-mnt-'; for i in \$(seq 60); do l=\"\$(journalctl -b -o short-monotonic --no-pager | grep -m 1 'Timed out waiting for device .* - $missing\\.\$')\"; test -n \"\$l\" && break; sleep 1; done; test -n \"\$l\" && echo \"\$l\" && t=\"\$(echo \"\$l\" | sed -E 's/^\\[ *([0-9]+)\\..*/\\1/')\" && u=\$((\$(systemctl show -P UserspaceTimestampMonotonic) / 1000000)) && echo \"the journal names the missing disk, \$((t - u)) s after the start of the system\" && test \$((t - u)) -lt 20" \
  --command "u=\"\$(systemd-escape -p --suffix=device $missing)\" && systemctl show -p JobRunningTimeoutUSec \"\$u\" && test \"\$(systemctl show -P JobRunningTimeoutUSec \"\$u\")\" = 10s && ! mountpoint -q /var/mnt/missing" \
  --command "$oneshot"

vm --poweroff --log "$logs/serial-reset-settings-14.log" --chat-then-login --chat "$answer=>no" \
  --title "Reset settings 14: the reset entry with that /etc/fstab: the question at once, no emergency mode" \
  --command 'cat /proc/cmdline; grep -Eq "(^| )fstab=no( |$)" /proc/cmdline' \
  --command "$no_emergency" \
  --command 'test "$(systemctl show -P LoadState var-mnt-missing.mount)" = not-found && test "$(systemctl show -P LoadState var-mnt-invalid.mount)" = not-found && ! journalctl -b -o cat --no-pager | grep "Timed out waiting for device" && echo "/etc/fstab was not read"' \
  --command 'q=$(( ($(systemctl show -P InactiveExitTimestampMonotonic nyra-reset-settings.service) - $(systemctl show -P UserspaceTimestampMonotonic)) / 1000000 )); echo "the reset question $q s after the start of the system"; test "$q" -lt 30' \
  --command "$oneshot"

vm --poweroff --log "$logs/serial-reset-settings-15.log" --chat-then-login --chat "$answer=>RESET" \
  --title "Reset settings 15: the reset with that /etc/fstab, then the normal boot without it" \
  --command "$running" \
  --command "! grep -s 'nyra-missing\\|nyra-no-such-option' /etc/fstab && echo 'the broken /etc/fstab lines are gone'"

# A normal boot with /etc emptied (docs/BOOT.md, "No first-boot questions"): any first-boot question
# would stop the boot before multi-user.target. "Initial Setup." shows that systemd-firstboot did run.
vm --log "$logs/serial-reset-settings-16.log" --power-cut-at 'nyra-test: power cut' \
  --title "Reset settings 16: /etc emptied, then a power cut" \
  --command 'find /etc -mindepth 1 -delete; echo "left in /etc: $(ls -A /etc | wc -l)"; test -z "$(ls -A /etc)"' \
  --command 'sync && echo "nyra-test: power"" cut"'
# The printed marker (NYRA-ROOT-LOCKED) does not appear literally in the drop-in.
root_locked="systemd.unit-dropin.systemd-user-sessions.service=[Service]
ExecStartPost=/bin/sh -c 'grep \"^root:\" /etc/shadow | cut -d: -f1,2 >/dev/ttyS0; grep -q \"^root:[!*]\" /etc/shadow && echo NYRA-ROOT-\$\$(echo LOCKED) >/dev/ttyS0'"
vm --log "$logs/serial-reset-settings-17.log" --credential "$root_locked" \
  --marker 'NYRA-ROOT-LOCKED' --marker-expected yes \
  --title "Reset settings 17: the normal boot with /etc emptied: no root password question, root locked"
if grep -aE 'Please enter the new' "$logs/serial-reset-settings-17.log" || ! grep -aq 'Initial Setup\.' "$logs/serial-reset-settings-17.log"; then
  echo "reset settings 17: systemd-firstboot asked a question, or did not run"
  exit 1
fi
