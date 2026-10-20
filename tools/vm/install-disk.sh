#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: installs IMAGE to WORKDIR/disk.raw as the installer does (docs/BOOT.md): bootc install to
# a 12 GiB disk, then the boot files and loader.conf on the new ESP from the image (esp-sync install),
# before the first boot.
# With TARGET_IMGREF, IMAGE is an image ID from tools/install/verified-pull.sh and nothing can be
# pulled: --pull=never, no network, and bootc is told which reference the machine updates from
# (docs/BOOT.md).
#   tools/vm/install-disk.sh IMAGE WORKDIR [TARGET_IMGREF]
set -euo pipefail

image="$1" work="$2" target="${3:-}"
truncate -s 12G "$work/disk.raw"
sudo podman run --rm --privileged --pid=host ${target:+--pull=never --network none} \
  -v /dev:/dev -v /var/lib/containers:/var/lib/containers -v "$work:/output" \
  "$image" \
  bootc install to-disk --composefs-backend --bootloader systemd --filesystem ext4 \
    ${target:+--target-imgref "$target"} --wipe --via-loopback /output/disk.raw
loop="$(sudo losetup -P --show -f "$work/disk.raw")"
esp="$(tools/vm/esp-of.sh "$loop")"
mkdir -p "$work/esp" && sudo mount "$esp" "$work/esp"
sudo podman run --rm --network none -v "$work/esp:/esp" "$image" \
  /usr/lib/nyra/boot/esp-sync install /esp
sudo umount "$work/esp" && sudo losetup -d "$loop"
sudo chown "$(id -u):$(id -g)" "$work/disk.raw"
