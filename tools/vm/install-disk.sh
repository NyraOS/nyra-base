#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: installs IMAGE to WORKDIR/disk.raw as the installer does (docs/BOOT.md): bootc install to
# a 12 GiB disk, then the boot files and loader.conf on the new ESP from the image (esp-sync install),
# before the first boot.
#   tools/vm/install-disk.sh IMAGE WORKDIR
set -euo pipefail

image="$1" work="$2"
truncate -s 12G "$work/disk.raw"
sudo podman run --rm --privileged --pid=host \
  -v /dev:/dev -v /var/lib/containers:/var/lib/containers -v "$work:/output" \
  "$image" \
  bootc install to-disk --composefs-backend --bootloader systemd --filesystem ext4 \
    --wipe --via-loopback /output/disk.raw
loop="$(sudo losetup -P --show -f "$work/disk.raw")"
esp=""
for p in "$loop"p*; do
  if [ "$(sudo blkid -o value -s TYPE "$p")" = vfat ]; then esp="$p"; fi
done
test -n "$esp"
mkdir -p "$work/esp" && sudo mount "$esp" "$work/esp"
sudo podman run --rm --network none -v "$work/esp:/esp" "$image" \
  /usr/lib/nyra/boot/esp-sync install /esp
sudo umount "$work/esp" && sudo losetup -d "$loop"
sudo chown "$(id -u):$(id -g)" "$work/disk.raw"
