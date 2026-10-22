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
# shellcheck disable=SC2086 # PRIV is empty or a command
priv() { ${PRIV-sudo} "$@"; }

priv rm -rf "$work/os" "$work/boot" "$work/tmp" "$work/extra"
mkdir -p "$work/os" "$work/boot" "$work/tmp" "$work/extra/usr/bin" "$work/packages"
install -m 0755 "$work/installer/nyra-installer" "$work/extra/usr/bin/nyra-installer"
pod run --rm --privileged -v "$PWD/iso:/src" -v "$work:/work" -v "$work/packages:/packages" localhost/nyra-tools \
  mkosi -C /src --snapshot="$snapshot" --output-directory=/work/os --workspace-directory=/work/tmp \
    --package-cache-dir=/packages --extra-tree=/work/extra:/ --source-date-epoch="$SOURCE_DATE_EPOCH" --force build
# The boot files: the same snapshot and tools, another tree.
pod run --rm --privileged -v "$PWD/iso/boot:/src" -v "$work:/work" -v "$work/packages:/packages" localhost/nyra-tools \
  mkosi -C /src --snapshot="$snapshot" --output-directory=/work/boot --workspace-directory=/work/tmp \
    --package-cache-dir=/packages --source-date-epoch="$SOURCE_DATE_EPOCH" --force build
priv rm -rf "$work/tmp" "$work/extra"
ls -l "$work/os" "$work/boot"
