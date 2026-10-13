#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: prints the EFI system partition (the vfat one) of a disk image attached with
# `losetup -P --show`. The partition devices can be missing for a moment after losetup (udev may
# still be rereading the partition table): it waits for udev, then tries again for up to 10 s, and
# fails with a message that names what is missing, never with an empty result.
#   tools/vm/esp-of.sh LOOP_DEVICE
set -euo pipefail

loop="$1"
end=$((SECONDS + 10))
while :; do
  udevadm settle --timeout=10 || true
  parts=() esp=""
  for p in "$loop"p*; do
    [ -e "$p" ] || continue # no partition yet: the pattern itself
    parts+=("$p")
    if [ "$(sudo blkid -o value -s TYPE "$p" || true)" = vfat ]; then esp="$p"; fi
  done
  if [ -n "$esp" ]; then echo "$esp"; exit 0; fi
  [ "$SECONDS" -lt "$end" ] || break
  sleep 0.5
done
echo "::error::No EFI system partition (vfat) on $loop after 10 s; its partitions: ${parts[*]:-none}" >&2
exit 1
