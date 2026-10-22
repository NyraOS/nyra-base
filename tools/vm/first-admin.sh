#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: the first administrator on a copy of the installed test disk, with Secure Boot on (the
# image's UKI certificate enrolled as a MOK, as in tools/vm/reset-settings.sh) (docs/BOOT.md, "The first
# administrator"). The record is made by the image's own admin-record step (tools/install/in-image.sh)
# and put where the installer puts it, /var/lib/nyra/first-admin of the new system, before the first
# boot. The same record installed on an encrypted disk, with the password never typed, is tools/vm/encryption.sh;
# this one is for what only a disk that starts again can show:
#   1. the first boot: nyra-first-admin.service ran before systemd-firstboot and finished; the account
#      is in the group sudo with a home and a password hash, root is locked, nobody has an empty
#      password, the record is gone, the host name is nyra, the locale en_US.UTF-8 and the time zone UTC
#      are set, nothing failed; a file is added to /etc and the reset entry is picked for the next boot;
#   2. "Nyra OS Reset settings", answered RESET: the file is gone, and the account is kept as it was
#      (the same line of /etc/shadow, the same groups, UID and home, the file in its home), root is
#      locked, nothing made the account again (the unit's condition is not met), the host name is kept;
#   3. a second copy of the disk with a record that is not as the installer leaves it (mode 0644): the
#      unit refuses and fails (that and nothing else), no account is made, the record is removed, the
#      fixed defaults are set, root is locked.
# The test console add-on that tools/vm/test-console.sh put on the disk is replaced by one signed with a
# key made here and enrolled as a MOK; both live only in WORKDIR and are deleted at the end. The
# password is random, for these throwaway disks only, and is never typed or printed.
#   tools/vm/first-admin.sh IMAGE DISK.qcow2 UKI_CERT WORKDIR LOGDIR SUMMARY
set -euo pipefail

image="$1" disk="$2" uki_cert="$3" work="$4" logs="$5" summary="$6"
fa="$work/first-admin"
mnt="$fa/esp"
loop=""
mkdir -p "$mnt" "$fa/secrets"
chmod 0700 "$fa/secrets"
trap 'sudo umount -q "$mnt" 2>/dev/null || true; [ -z "$loop" ] || sudo losetup -d "$loop" || true; sudo rm -rf "$fa"' EXIT
# shellcheck disable=SC2034 # used by in_image (lib.sh)
as_root=sudo
secrets="$fa/secrets"
. tools/install/lib.sh

# The record, as the installer makes it.
openssl rand -hex 12 | tr -d '\n' > "$secrets/password"
in_image -i -- admin-record maria /secrets/first-admin < "$secrets/password"
sudo test -s "$secrets/first-admin"

openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=Nyra CI add-on test key" \
  -keyout "$fa/local.key" -out "$fa/local.crt" 2>/dev/null
tools/vm/test-addon.sh "$image" "$fa/console.addon.efi" systemd.import_credentials=yes "$fa/local.key" "$fa/local.crt"
virt-fw-vars --input /usr/share/OVMF/OVMF_VARS_4M.ms.fd --output "$fa/vars.fd" \
  --add-mok 605dab50-e046-4300-abb6-3dd810dd8b23 "$uki_cert" \
  --add-mok 605dab50-e046-4300-abb6-3dd810dd8b23 "$fa/local.crt"

# prepare RAW MODE: the signed console add-on on the ESP of RAW, and the record in the new system's /var
# with MODE.
prepare() {
  loop="$(sudo losetup -P --show -f "$1")"
  local esp p roots
  esp="$(tools/vm/esp-of.sh "$loop")"
  sudo mount "$esp" "$mnt"
  sudo test -f "$mnt/loader/addons/nyra-test-console.addon.efi"
  sudo cp "$fa/console.addon.efi" "$mnt/loader/addons/nyra-test-console.addon.efi"
  sudo umount "$mnt"
  # The root file system: the one partition with ext4 (the ESP is vfat; a BIOS boot partition has none).
  roots=()
  for p in "$loop"p*; do
    if [ "$(sudo blkid -o value -s TYPE "$p" || true)" = ext4 ]; then roots+=("$p"); fi
  done
  [ "${#roots[@]}" = 1 ] || { echo "::error::Not exactly one ext4 partition on $loop: ${roots[*]:-none}" >&2; exit 1; }
  sudo mount "${roots[0]}" "$mnt"
  local var="$mnt/state/os/default/var"
  sudo test -d "$var"
  sudo test ! -e "$var/lib/nyra/first-admin"
  sudo install -d -m 0755 "$var/lib/nyra"
  sudo install -m "$2" -o root -g root "$secrets/first-admin" "$var/lib/nyra/first-admin"
  sudo umount "$mnt"
  sudo losetup -d "$loop"
  loop=""
}

qemu-img convert -O raw "$disk" "$fa/disk.raw"
cp --sparse=always "$fa/disk.raw" "$fa/bad.raw"
prepare "$fa/disk.raw" 0600
prepare "$fa/bad.raw" 0644

# Every command is traced in the guest (set -x in a subshell), so a failure shows what failed.
vm() {
  local args=() prev="" a
  for a in "$@"; do
    if [ "$prev" = --command ]; then args+=("( set -x; $a )"); else args+=("$a"); fi
    prev="$a"
  done
  python3 -B tools/vm/vm-boot.py --secure-boot "$fa/vars.fd" --keep-vars --disk "${raw:-$fa/disk.raw}" \
    --autologin --timeout 240 --summary "$summary" "${args[@]}"
}
defaults='h="$(cat /etc/hostname)"; l="$(cat /etc/locale.conf 2>&1)"; echo "host name: [$h]; /etc/locale.conf: [$l]; /etc/localtime: $(readlink /etc/localtime)"; test "$h" = nyra && echo "$l" | grep -qx LANG=en_US.UTF-8 && cmp /etc/localtime /usr/share/zoneinfo/UTC && echo "the fixed defaults are set"'
running='s="$(systemctl is-system-running --wait)"; echo "system: $s"; systemctl --no-pager --failed; test "$s" = running'
oneshot='bootctl set-oneshot nyra-reset.CONF && echo "next boot: reset entry"'
answer='Type RESET to reset, anything else or Control-D to boot normally: '
before=/var/home/maria/before
# The account as the first boot made it.
account='id maria && id -nG maria | tr " " "\n" | grep -qx sudo && passwd -S maria | grep -q " P " && passwd -S root | grep -q " L " && ! cut -d: -f2 /etc/shadow | grep -qx "" && test ! -e /var/lib/nyra/first-admin'

vm --persist --poweroff --log "$logs/serial-first-admin-1.log" \
  --title "First administrator 1: the first boot makes the account, before systemd-firstboot" \
  --command "$running" \
  --command "$account && test \"\$(stat -c %U /var/home/maria)\" = maria && grep -q '^maria:\\\$y\\\$' /etc/shadow && echo 'the account: in sudo, a yescrypt hash, a home; root locked; no empty password; the record is gone'" \
  --command "$defaults" \
  --command 'for u in nyra-first-admin systemd-firstboot; do echo "$u: $(systemctl show -P ActiveState $u.service), $(systemctl show -P Result $u.service)"; test "$(systemctl show -P ActiveState $u.service)" = active && test "$(systemctl show -P Result $u.service)" = success; done; a=$(systemctl show -P ExecMainExitTimestampMonotonic nyra-first-admin.service); b=$(systemctl show -P ExecMainStartTimestampMonotonic systemd-firstboot.service); echo "the account was made at $a us, systemd-firstboot started at $b us"; test "$a" -gt 0 && test "$a" -le "$b"' \
  --command "mkdir -p $before && grep '^maria:' /etc/shadow > $before/shadow && id maria > $before/id && id -nG maria > $before/groups && echo kept > /var/home/maria/keep.txt && echo junk > /etc/nyra-test-junk && stat -c %u /var/home/maria > $before/homeuid" \
  --command "$oneshot"

vm --persist --poweroff --log "$logs/serial-first-admin-2.log" --chat-then-login --chat "$answer=>RESET" \
  --title "First administrator 2: Reset settings keeps the account" \
  --command "$running" \
  --command 'test ! -e /etc/nyra-test-junk && echo "the settings were reset"' \
  --command "$account && grep '^maria:' /etc/shadow | cmp - $before/shadow && id maria | cmp - $before/id && id -nG maria | cmp - $before/groups && test \"\$(stat -c %u /var/home/maria)\" = \"\$(cat $before/homeuid)\" && test \"\$(cat /var/home/maria/keep.txt)\" = kept && echo 'the account is kept as it was: the same hash, groups, IDs and home'" \
  --command 'test "$(cat /etc/hostname)" = nyra && echo "the host name is kept"' \
  --command 'test "$(systemctl show -P ConditionResult nyra-first-admin.service)" = no && test "$(systemctl show -P ActiveState nyra-first-admin.service)" = inactive && echo "nothing made the account again (no record, the unit does not start)"'

raw="$fa/bad.raw" vm --poweroff --log "$logs/serial-first-admin-3.log" \
  --title "First administrator 3: a record with the wrong mode: refused, no account, the defaults still set" \
  --command 's="$(systemctl is-system-running --wait)"; echo "system: $s"; systemctl --no-pager --failed; test "$s" = degraded' \
  --command 'f="$(systemctl list-units --state=failed --plain --no-legend | cut -d" " -f1)"; echo "failed: $f"; test "$f" = nyra-first-admin.service' \
  --command 'journalctl -b -u nyra-first-admin.service -o cat --no-pager | grep "is not owned by root, mode 0600, with one link"' \
  --command '! id maria && test ! -e /var/lib/nyra/first-admin && passwd -S root | grep -q " L " && ! cut -d: -f2 /etc/shadow | grep -qx "" && echo "no account, the record is gone, root locked, no empty password"' \
  --command "$defaults"
