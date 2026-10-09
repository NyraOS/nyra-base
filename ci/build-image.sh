#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds the bootc image from the mkosi root filesystem, with a sealed UKI (docs/BOOT.md):
#   1. the root filesystem without kernel and initramfs (Containerfile target "sealed"), committed;
#   2. the UKI from that committed image: bootc container ukify puts its composefs digest on the
#      command line. It reads the committed layers (podman --mount type=image), so file times are
#      the ones bootc will see after --timestamp, not the build's;
#   3. the UKI signed outside the image build. Here: with a key made for this run only, deleted
#      right after signing; its certificate stays in UKI_DIR for the Secure Boot test. The real
#      Nyra key will sign at this point, without CI ever holding it;
#   4. the final image: the committed root filesystem plus the signed UKI in /boot/EFI/Linux.
# With UKI_DIR/signed already there (ci/check-reproducible.sh), steps 2 and 3 are skipped and that
# UKI is used again.
#   ci/build-image.sh ROOTFS_IMAGE TAG UKI_DIR [podman build options...]
set -euo pipefail

rootfs="$1" tag="$2" uki="$3"
shift 3
build() { sudo podman build --timestamp "$SOURCE_DATE_EPOCH" --build-arg ROOTFS="$rootfs" "$@" -f Containerfile .; }

# The first two targets do not use the "uki" context; it is given anyway (empty) so that nothing
# tries to resolve it as an image name.
mkdir -p "$uki/none"
build "$@" --build-context uki="$uki/none" --target sealed -t "$tag-sealed"
if [ ! -d "$uki/signed" ]; then
  build "$@" --build-context uki="$uki/none" --target kernel -t "$tag-kernel"
  mkdir -p "$uki/unsigned"
  cid="$(sudo podman create -q "$tag-kernel")"
  sudo podman cp "$cid:/kernel" "$uki/kernel"
  sudo podman rm -f "$cid" >/dev/null
  sudo podman run --rm --network none --tmpfs /tmp --tmpfs /var/tmp \
    --mount "type=image,source=$tag-sealed,target=/target" \
    -v "$uki/kernel:/kernel:ro" -v "$uki/unsigned:/out" "$tag-sealed" \
    sh -c 'k="$(ls /kernel)" && bootc container ukify --rootfs /target --kernel-dir "/kernel/$k" -- --output "/out/$k.efi"'
  sudo chown -R "$(id -u):$(id -g)" "$uki"
  key="$(mktemp -d)"
  trap 'rm -rf "$key"' EXIT
  openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=Nyra CI per-run UKI key" \
    -keyout "$key/uki.key" -out "$uki/uki.crt" 2>/dev/null
  mkdir -p "$uki/signed.tmp"
  for f in "$uki"/unsigned/*.efi; do
    sbsign --key "$key/uki.key" --cert "$uki/uki.crt" --output "$uki/signed.tmp/${f##*/}" "$f"
  done
  rm -rf "$key"
  sbverify --cert "$uki/uki.crt" "$uki"/signed.tmp/*.efi
  mv "$uki/signed.tmp" "$uki/signed"
fi
build "$@" --build-arg SEALED="$tag-sealed" --build-context uki="$uki/signed" -t "$tag"
