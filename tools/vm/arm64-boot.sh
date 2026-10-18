#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only (.github/workflows/arm64.yml, docs/ARM64.md): the first boots of the aarch64 image, on its
# installed test disk (tools/vm/install-disk.sh, tools/vm/test-console.sh), with QEMU's virt machine
# and edk2 (AAVMF); KVM when the runner has it, otherwise emulated (tools/vm/vm-boot.py).
#   1. no Secure Boot: the system starts with no failed unit, the booted image is IMAGE_DIGEST, /usr
#      is read-only, the ESP holds the arm64 boot files and the "Nyra OS" firmware entry exists. No
#      TPM: Debian's arm64 kernel has no driver for the TPMs of QEMU's virt machine (docs/ARM64.md);
#   2. Secure Boot with the Microsoft keys (AAVMF_VARS.ms.fd): Debian's shim for arm64 (signed by
#      Microsoft) -> Debian's systemd-boot for arm64 -> the UKI as bootc installed it, signed with
#      this run's key (UKI_CERT, enrolled as a MOK, as tools/vm/secure-boot.sh does on x86_64). The
#      test console add-on is signed with a key made here, enrolled too, and deleted at the end.
#   tools/vm/arm64-boot.sh IMAGE IMAGE_DIGEST DISK.qcow2 UKI_CERT WORKDIR LOGDIR SUMMARY TIMEOUT
set -euo pipefail

image="$1" image_digest="$2" disk="$3" uki_cert="$4" work="$5" logs="$6" summary="$7" timeout="$8"
ab="$work/arm64-boot"
mnt="$ab/esp"
loop=""
mkdir -p "$mnt"
# Set before the key exists, so it is deleted whatever fails.
trap 'sudo umount -q "$mnt" 2>/dev/null || true; [ -z "$loop" ] || sudo losetup -d "$loop" || true; rm -rf "$ab"' EXIT

booted='d="$(bootc status --booted --format json | grep -o "\"imageDigest\":\"[^\"]*\"" | cut -d\" -f4)"; echo "booted imageDigest: $d"; test "$d" = '"$image_digest"
running='s="$(systemctl is-system-running --wait)"; echo "system: $s"; systemctl --no-pager --failed; systemd-analyze; test "$s" = running'

# Both boots run, each reports its own result.
rc=0
python3 -B tools/vm/vm-boot.py --autologin --disk "$disk" --timeout "$timeout" \
  --command 'uname -m; systemd-detect-virt; test "$(uname -m)" = aarch64' \
  --command "$running" \
  --command "$booted" \
  --command 'findmnt -T /usr; findmnt -T /usr -no OPTIONS | tr , "\n" | grep -qx ro && touch /usr/.nyra-rw-test 2>&1 | grep "Read-only file system"' \
  --command 'ls /boot/EFI/BOOT /boot/EFI/nyra; s=/usr/lib/shim/shimaa64.efi.signed b=/usr/lib/systemd/boot/efi/systemd-bootaa64.efi.signed; cmp $s /boot/EFI/BOOT/BOOTAA64.EFI && cmp $s /boot/EFI/nyra/shimaa64.efi && cmp $b /boot/EFI/BOOT/grubaa64.efi && cmp $b /boot/EFI/nyra/grubaa64.efi' \
  --command 'efibootmgr; efibootmgr | grep -q "^Boot[0-9A-F]\{4\}\* Nyra OS"' \
  --log "$logs/serial-arm64-boot.log" --summary "$summary" --title "aarch64: boot without Secure Boot" ||
  rc=1

openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=Nyra CI add-on test key" \
  -keyout "$ab/local.key" -out "$ab/local.crt" 2>/dev/null
# Owner GUID: shim's. The firmware variables come with Secure Boot on and the Microsoft keys.
virt-fw-vars --input /usr/share/AAVMF/AAVMF_VARS.ms.fd --output "$ab/vars.fd" \
  --add-mok 605dab50-e046-4300-abb6-3dd810dd8b23 "$uki_cert" \
  --add-mok 605dab50-e046-4300-abb6-3dd810dd8b23 "$ab/local.crt"
qemu-img convert -O raw "$disk" "$ab/disk.raw"
loop="$(sudo losetup -P --show -f "$ab/disk.raw")"
esp="$(tools/vm/esp-of.sh "$loop")"
sudo mount "$esp" "$mnt"
uki="$(sudo sed -n 's/^uki[[:space:]]\+//p' "$mnt"/loader/entries/*.conf)"
sudo sbverify --cert "$uki_cert" "$mnt$uki"
tools/vm/test-addon.sh "$image" "$ab/console.addon.efi" systemd.import_credentials=yes "$ab/local.key" "$ab/local.crt"
sudo cp "$ab/console.addon.efi" "$mnt/loader/addons/nyra-test-console.addon.efi"
sudo umount "$mnt"
sudo losetup -d "$loop"
loop=""
rm "$ab/local.key"

python3 -B tools/vm/vm-boot.py --autologin --disk "$ab/disk.raw" --secure-boot "$ab/vars.fd" --timeout "$timeout" \
  --command 'mokutil --sb-state; mokutil --sb-state | grep -qx "SecureBoot enabled"' \
  --command "$booted" \
  --command "$running" \
  --log "$logs/serial-arm64-secure-boot.log" --summary "$summary" \
  --title "aarch64: Secure Boot, shim -> systemd-boot -> the signed UKI" || rc=1
exit "$rc"
