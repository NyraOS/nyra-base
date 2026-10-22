#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds the operating system of the installer ISO (iso/mkosi.conf, docs/ISO.md) and, in a tree of its own,
# the boot files (iso/boot/mkosi.conf) with mkosi, in the tools
# image, from the same snapshot as the image (mkosi/mkosi.conf, the only place the date is set), and puts
# the installer program (ci/build-installer.sh) in it. Writes WORKDIR/os/nyra-installer-os (the tree) and
# WORKDIR/os/nyra-installer-os.manifest (the exact Debian package versions, for the SBOM), and
# WORKDIR/boot/nyra-installer-boot (and its manifest): shim and GRUB.
# SOURCE_DATE_EPOCH must be set (image.yml). Nothing here is signed or secret.
#   ci/build-iso-os.sh WORKDIR       (WORKDIR/installer/nyra-installer is the program)
# ISO_ARCH: amd64 (default) or arm64, the architecture of the ISO. The files in iso/ are the x86_64 ones; for
# arm64 the build works on a copy of them in which the architecture and the three packages named after it
# (the kernel, GRUB) are changed, and fails if any other line still names x86_64 (as the arm64 image build
# does with mkosi/mkosi.conf, docs/ARM64.md). It is built natively on an arm64 machine.
# PODMAN and PRIV: the podman command and the prefix of commands that need root, default "sudo podman" and
# "sudo" (CI); a local rehearsal in rootless podman sets its own store and an empty PRIV.
set -euo pipefail

[ $# = 1 ] || { echo "usage: build-iso-os.sh WORKDIR" >&2; exit 1; }
work="$(realpath -m "$1")"
: "${SOURCE_DATE_EPOCH:?SOURCE_DATE_EPOCH must be set}"
snapshot="$(sed -n 's/^Snapshot=//p' mkosi/mkosi.conf)"
[[ "$snapshot" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || { echo "build-iso-os.sh: no snapshot date in mkosi/mkosi.conf" >&2; exit 1; }
[ -x "$work/installer/nyra-installer" ] || { echo "build-iso-os.sh: no $work/installer/nyra-installer" >&2; exit 1; }
# shellcheck disable=SC2086 # PODMAN is a command with its options
pod() { ${PODMAN:-sudo podman} "$@"; }
arch="${ISO_ARCH:-amd64}"
[ "$arch" = amd64 ] || [ "$arch" = arm64 ] || { echo "build-iso-os.sh: ISO_ARCH is amd64 or arm64, not $arch" >&2; exit 1; }
# shellcheck disable=SC2086 # PRIV is empty or a command
priv() { ${PRIV-sudo} "$@"; }

priv rm -rf "$work/os" "$work/boot" "$work/tmp" "$work/extra" "$work/conf"
mkdir -p "$work/os" "$work/boot" "$work/tmp" "$work/extra/usr/bin" "$work/packages"
conf_os="$PWD/iso" conf_boot="$PWD/iso/boot"
if [ "$arch" = arm64 ]; then
  # The copy of iso/ for arm64: the same files, with the architecture changed.
  mkdir -p "$work/conf"
  cp -a iso "$work/conf/iso"
  conf_os="$work/conf/iso" conf_boot="$work/conf/iso/boot"
  for f in "$conf_os/mkosi.conf" "$conf_boot/mkosi.conf"; do
    sed -i -e 's/^Architecture=x86-64$/Architecture=arm64/' \
      -e 's/^\( *\)linux-image-amd64$/\1linux-image-arm64/' \
      -e 's/^\( *\)grub-efi-amd64-signed$/\1grub-efi-arm64-signed/' "$f"
    # What is left must not name the architecture except in comments.
    if grep -v '^#' "$f" | grep -nE 'amd64|x86' ; then
      echo "build-iso-os.sh: $f still names x86_64 after the change for arm64" >&2
      exit 1
    fi
    grep -qx 'Architecture=arm64' "$f" || { echo "build-iso-os.sh: $f has no Architecture=arm64" >&2; exit 1; }
  done
  grep -qx ' *linux-image-arm64' "$conf_os/mkosi.conf" && grep -qx ' *grub-efi-arm64-signed' "$conf_boot/mkosi.conf" \
    || { echo "build-iso-os.sh: the arm64 kernel and GRUB are not in the package lists" >&2; exit 1; }
fi
install -m 0755 "$work/installer/nyra-installer" "$work/extra/usr/bin/nyra-installer"
pod run --rm --privileged -v "$conf_os:/src" -v "$work:/work" -v "$work/packages:/packages" localhost/nyra-tools \
  mkosi -C /src --snapshot="$snapshot" --output-directory=/work/os --workspace-directory=/work/tmp \
    --package-cache-dir=/packages --extra-tree=/work/extra:/ --source-date-epoch="$SOURCE_DATE_EPOCH" --force build
# The boot files: the same snapshot and tools, another tree.
pod run --rm --privileged -v "$conf_boot:/src" -v "$work:/work" -v "$work/packages:/packages" localhost/nyra-tools \
  mkosi -C /src --snapshot="$snapshot" --output-directory=/work/boot --workspace-directory=/work/tmp \
    --package-cache-dir=/packages --source-date-epoch="$SOURCE_DATE_EPOCH" --force build
priv rm -rf "$work/tmp" "$work/extra" "$work/conf"
ls -l "$work/os" "$work/boot"
