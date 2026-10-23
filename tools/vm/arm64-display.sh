#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only (.github/workflows/arm64.yml, docs/ARM64.md, "The screen"): a person's aarch64 virtual machine
# (UTM on Apple Silicon: UEFI with Secure Boot, a virtio GPU, a USB keyboard, a virtio console) boots the
# system the installer makes on an encrypted disk with a password and no TPM, and the test looks at the
# screen. Nothing else in CI has a screen: the other tests read the serial console, where the initrd's
# password prompt does not go (tools/vm/screen-boot.py).
#   1. installer-layout: the disk as tools/vm/install-encrypted.sh leaves it, which is how the installer
#      partitions a disk (tools/install/lib.sh, partition_disk);
#   2. arm64-root-type: the same disk with the root partition's type changed to the one aarch64 systems
#      look for (Discoverable Partitions, root-arm64), to tell a missing display driver from a root
#      partition the initrd cannot find.
# The image is signed with the key of the run (UKI_CERT, enrolled as a MOK, as tools/vm/arm64-boot.sh
# does). Both boots run, each reports its own result; the PNGs of the screen and the serial logs go to OUT.
#   tools/vm/arm64-display.sh IMAGE UKI_CERT WORKDIR OUT SUMMARY
set -euo pipefail

image="$1" uki_cert="$2" work="$3" out="$4" summary="$5"
d="$work/arm64-display"
secrets="$d/secrets"
mkdir -p "$out"
mkdir -p "$d"
mkdir -m 0700 "$secrets"
trap 'sudo rm -rf "$d"' EXIT

# Letters and digits only: the initrd reads the keyboard as US, whatever the user's layout.
python3 -I -c 'import secrets, string; print("".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(20)), end="")' > "$secrets/password"
tools/vm/install-encrypted.sh "$image" "$d" "$secrets"
# Owner GUID: shim's. The firmware variables come with Secure Boot on and the Microsoft keys.
virt-fw-vars --input /usr/share/AAVMF/AAVMF_VARS.ms.fd --output "$d/vars.fd" \
  --add-mok 605dab50-e046-4300-abb6-3dd810dd8b23 "$uki_cert"

rc=0
python3 -B tools/vm/screen-boot.py --name installer-layout --disk "$d/disk.raw" --vars "$d/vars.fd" \
  --out "$out" --summary "$summary" --password-file "$secrets/password" \
  --timeout 1200 --blind-after 600 --stop-on-reboot || rc=1

cp --sparse=always "$d/disk.raw" "$d/disk-arm64-type.raw"
sfdisk -q --part-type "$d/disk-arm64-type.raw" 2 B921B045-1DF0-41C3-AF44-4C6F280D3FAE
python3 -B tools/vm/screen-boot.py --name arm64-root-type --disk "$d/disk-arm64-type.raw" --vars "$d/vars.fd" \
  --out "$out" --summary "$summary" --password-file "$secrets/password" \
  --timeout 1800 --blind-after 700 || rc=1
[ "$rc" = 0 ] || echo "::error::The password prompt of the encrypted aarch64 disk is not on the screen, or the disk does not unlock: see the SCREEN-TEST lines and the PNGs in the artifact"
exit "$rc"
