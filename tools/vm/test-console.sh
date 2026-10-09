#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: gives an installed test disk its test console (docs/BOOT.md). The sealed command line
# does not import systemd credentials; vm-boot.py passes the console and login settings as
# credentials, so the disk gets an add-on for every UKI (loader/addons/ on the ESP, also used by
# updated versions) that turns credential import back on: the last occurrence on the command line
# wins. Unsigned here; tools/vm/secure-boot.sh replaces it with a signed one.
#   tools/vm/test-console.sh IMAGE DISK.raw WORKDIR
set -euo pipefail

image="$1" disk="$2" work="$3"
mnt="$work/test-console"
loop=""
mkdir -p "$mnt"
trap 'sudo umount -q "$mnt" 2>/dev/null || true; [ -z "$loop" ] || sudo losetup -d "$loop" || true; rm -rf "$mnt"' EXIT
tools/vm/test-addon.sh "$image" "$work/console.addon.efi" systemd.import_credentials=yes
loop="$(sudo losetup -P --show -f "$disk")"
esp=""
for p in "$loop"p*; do
  if [ "$(sudo blkid -o value -s TYPE "$p")" = vfat ]; then esp="$p"; fi
done
test -n "$esp"
sudo mount "$esp" "$mnt"
sudo mkdir -p "$mnt/loader/addons"
sudo cp "$work/console.addon.efi" "$mnt/loader/addons/nyra-test-console.addon.efi"
sudo umount "$mnt"
