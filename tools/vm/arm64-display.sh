#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only (.github/workflows/arm64.yml, docs/ARM64.md, "The screen"): a person's aarch64 virtual machine
# (UTM on Apple Silicon: UEFI with Secure Boot, a virtio GPU, a USB keyboard, a virtio console) boots the
# system the installer makes on an encrypted disk with a password and no TPM, and the test looks at the
# screen. Nothing else in CI has a screen: the other tests read the serial console, where the initrd's
# password prompt does not go (tools/vm/screen-boot.py). The disk is the one tools/vm/install-encrypted.sh
# leaves, which partitions as the installer does (tools/install/lib.sh): its root partition must have the
# type that aarch64 systems look for (Discoverable Partitions, root-arm64), or the initrd never finds it
# and restarts the machine; the prompt must be on the screen, which takes the display driver in the initrd.
# The image is signed with the key of the run (UKI_CERT, enrolled as a MOK, as tools/vm/arm64-boot.sh
# does). The PNGs of the screen and the serial log go to OUT.
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
# GitHub's log hides this string from now on, in case the blind typing (screen-boot.py) echoes it.
[ -z "${GITHUB_ACTIONS:-}" ] || echo "::add-mask::$(cat "$secrets/password")"
tools/vm/install-encrypted.sh "$image" "$d" "$secrets"
# Owner GUID: shim's. The firmware variables come with Secure Boot on and the Microsoft keys.
virt-fw-vars --input /usr/share/AAVMF/AAVMF_VARS.ms.fd --output "$d/vars.fd" \
  --add-mok 605dab50-e046-4300-abb6-3dd810dd8b23 "$uki_cert"

# The installer's partitioning gave the root partition the aarch64 type.
root_kind="$(sfdisk -J "$d/disk.raw" | jq -r '.partitiontable.partitions[1].type')"
echo "the root partition's type: $root_kind"
[ "${root_kind^^}" = B921B045-1DF0-41C3-AF44-4C6F280D3FAE ] || { echo "::error::The root partition's type is $root_kind, not the aarch64 one"; exit 1; }

# What the UKI and its initramfs weigh, and the display drivers in it (docs/BOOT.md, "Space on the ESP").
# Only for the summary: a failure here is a warning, not a failed screen test.
report_sizes() {
  # shellcheck disable=SC2024 # the file is the caller's, only podman needs root
  sudo podman run --rm --network none "$image" sh -c 'cat /boot/EFI/Linux/*.efi' > "$d/uki.efi"
  python3 -I - "$d/uki.efi" "$d/initrd.cpio" << 'PY' >> "$summary"
import struct, sys
f = open(sys.argv[1], "rb").read()
pe = struct.unpack_from("<I", f, 0x3C)[0]
count, opt = struct.unpack_from("<H", f, pe + 6)[0], struct.unpack_from("<H", f, pe + 20)[0]
sizes = {}
for i in range(count):
    name, size, _, _, offset = struct.unpack_from("<8sIIII", f, pe + 24 + opt + 40 * i)
    name = name.rstrip(b"\0").decode()
    sizes.setdefault(name, size)
    if name == ".initrd":
        open(sys.argv[2], "wb").write(f[offset:offset + size])
print(f"## Sizes\n\nThe UKI is {len(f) / 1e6:.1f} MB, its initramfs {sizes['.initrd'] / 1e6:.1f} MB, "
      f"its kernel {sizes['.linux'] / 1e6:.1f} MB.\n")
PY
  # The initramfs is compressed with zstd (Containerfile); the sizes below are those of the module files in it.
  zstd -dc "$d/initrd.cpio" | cpio -itv 2> /dev/null \
    | awk '/kernel\/drivers\/gpu\// && /\.ko/ { n++; b += $5 } END { printf "Display drivers in the initramfs (drivers/gpu): %d modules, %.2f MB.\n\n", n, b / 1e6 }' >> "$summary"
}
report_sizes || echo "::warning::The sizes of the UKI and its display drivers could not be read"

rc=0
python3 -B tools/vm/screen-boot.py --name installed --disk "$d/disk.raw" --vars "$d/vars.fd" \
  --out "$out" --summary "$summary" --password-file "$secrets/password" \
  --timeout 1800 --blind-after 700 --stop-on-reboot || rc=1
[ "$rc" = 0 ] || echo "::error::The password prompt of the encrypted aarch64 disk is not on the screen, or the disk does not unlock: see the SCREEN-TEST lines and the PNGs in the artifact"
exit "$rc"
