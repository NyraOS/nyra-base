#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck disable=SC2034  # mnt, running and secure are for the scripts that source this file
# CI only (titanic.yml): sourced by the Titanic tests that follow one installed system with Secure
# Boot on, tools/titanic/hostile-root.sh (T12) and tools/titanic/broken-config.sh (T8):
#   . tools/titanic/secure-boot-system.sh IMAGE DISK.qcow2 UKI_CERT DIR SUMMARY
# DIR is the test's own directory, removed at exit (with any background job of the test stopped).
# As in tools/vm/reset-settings.sh: a copy of the installed test disk, and one firmware variable
# store for all boots, with Secure Boot on (the Microsoft keys; the image's UKI certificate and a key
# made here as MOKs). The test console add-on that tools/vm/test-console.sh put on the disk is
# replaced by one signed with that key ("local"; it lives only in DIR).
# Gives: esp rw|ro and unesp (the ESP of the test disk on $mnt); vm, which runs
# tools/vm/vm-boot.py on that system, written to its disk and variable store (more options after it);
# and the guest commands $running (the system is running, no failed unit) and $secure (Secure Boot
# and the lockdown on).

sb_image="$1" sb_disk="$2" sb_uki_cert="$3" sb_dir="$4" sb_summary="$5"
mnt="$sb_dir/esp"
loop=""
mkdir -p "$mnt"
trap 'kill $(jobs -p) 2>/dev/null || true; sudo umount -q "$mnt" 2>/dev/null || true; [ -z "$loop" ] || sudo losetup -d "$loop" || true; rm -rf "$sb_dir"' EXIT

openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=Nyra CI add-on test key" \
  -keyout "$sb_dir/local.key" -out "$sb_dir/local.crt" 2>/dev/null
tools/vm/test-addon.sh "$sb_image" "$sb_dir/console.addon.efi" systemd.import_credentials=yes \
  "$sb_dir/local.key" "$sb_dir/local.crt"
# Owner GUID: shim's. Secure Boot on, Microsoft keys, the UKI certificate and the local key as MOKs.
virt-fw-vars --input /usr/share/OVMF/OVMF_VARS_4M.ms.fd --output "$sb_dir/vars.fd" \
  --add-mok 605dab50-e046-4300-abb6-3dd810dd8b23 "$sb_uki_cert" \
  --add-mok 605dab50-e046-4300-abb6-3dd810dd8b23 "$sb_dir/local.crt"

qemu-img convert -O raw "$sb_disk" "$sb_dir/disk.raw"
esp() { # mount the ESP of the test disk on $mnt with these options (rw or ro)
  loop="$(sudo losetup -P --show -f "$sb_dir/disk.raw")"
  local p e=""
  for p in "$loop"p*; do
    if [ "$(sudo blkid -o value -s TYPE "$p")" = vfat ]; then e="$p"; fi
  done
  test -n "$e"
  sudo mount -o "$1" "$e" "$mnt"
}
unesp() { sudo umount "$mnt" && sudo losetup -d "$loop" && loop=""; }
esp rw
sudo test -f "$mnt/loader/addons/nyra-test-console.addon.efi"
sudo cp "$sb_dir/console.addon.efi" "$mnt/loader/addons/nyra-test-console.addon.efi"
unesp

vm() {
  python3 -B tools/vm/vm-boot.py --secure-boot "$sb_dir/vars.fd" --keep-vars --disk "$sb_dir/disk.raw" --persist \
    --autologin --timeout 240 --summary "$sb_summary" "$@"
}

# Guest commands. Each must end with the status of its whole check (vm-boot.py reads only the last
# one). The guest shell is interactive: no "!" right before a word inside double quotes (history
# expansion).
running='s="$(systemctl is-system-running --wait)"; echo "system: $s"; systemctl --no-pager --failed; test "$s" = running'
secure='mokutil --sb-state && cat /sys/kernel/security/lockdown && mokutil --sb-state | grep -qx "SecureBoot enabled" && grep -q "\[integrity\]" /sys/kernel/security/lockdown'
