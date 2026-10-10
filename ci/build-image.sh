#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds the bootc image from the mkosi root filesystem, with a sealed UKI (docs/BOOT.md):
#   1. the root filesystem without kernel and initramfs (Containerfile target "sealed"), committed;
#   2. the UKI from that committed image (ci/ukify.sh): bootc container ukify puts its composefs digest
#      on the command line; a second profile boots the same system into recovery. It reads the committed layers (podman --mount type=image), so file times are
#      the ones bootc will see after --timestamp, not the build's;
#   3. the UKI signed outside the image build: first its PCR 11 policy (main profile only,
#      tools/signing/pcr-policy.py), then the whole file for Secure Boot. Here: with two keys made for
#      this run only, deleted right after signing; the UKI certificate and the policy's public key stay
#      in UKI_DIR for the tests. The real Nyra keys will sign at this point, without CI ever holding
#      them. Only one file is signed, and only if it is the sealed UKI (tools/signing/uki-check.py,
#      ci/uki-cmdline.txt) and carries exactly the main profile's policy (pcr-policy.py check);
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
  key="$(mktemp -d)"
  trap 'rm -rf "$key"' EXIT
  # The PCR policy key of this run: its public half goes into the UKI (.pcrpkey) in step 2.
  mkdir -p "$uki/pcr"
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$key/pcr.key" 2>/dev/null
  openssl pkey -in "$key/pcr.key" -pubout -out "$uki/pcr/tpm2-pcr-public-key.pem"
  build "$@" --build-context uki="$uki/none" --target kernel -t "$tag-kernel"
  mkdir -p "$uki/unsigned"
  cid="$(sudo podman create -q "$tag-kernel")"
  sudo podman cp "$cid:/kernel" "$uki/kernel"
  sudo podman rm -f "$cid" >/dev/null
  sudo podman run --rm --network none --tmpfs /tmp --tmpfs /var/tmp \
    --mount "type=image,source=$tag-sealed,target=/target" \
    -v "$uki/kernel:/kernel:ro" -v "$uki/pcr:/pcr:ro" -v "$uki/unsigned:/out" -v "$PWD/ci/ukify.sh:/ukify.sh:ro" "$tag-sealed" \
    sh /ukify.sh
  sudo chown -R "$(id -u):$(id -g)" "$uki"
  # The signing step signs one file, and only the sealed UKI (tools/signing/uki-check.py): never an
  # add-on or another PE file, whatever ukify.sh left in the directory.
  files=("$uki"/unsigned/*)
  if [ "${#files[@]}" != 1 ] || [[ "${files[0]}" != *.efi ]]; then
    echo "build-image.sh: expected exactly one UKI to sign, found: ${files[*]}" >&2
    exit 1
  fi
  f="${files[0]}"
  python3 -I tools/signing/uki-check.py "$f" ci/uki-cmdline.txt
  # The PCR 11 policy digests that step 2 put in the main profile, signed and joined into the UKI with
  # the image's own ukify (no key in that container), then checked.
  python3 -I tools/signing/pcr-policy.py sign "$f" "$key/pcr.key" > "$uki/pcr/pcrsig.json"
  mkdir -p "$uki/policy"
  sudo podman run --rm --network none --tmpfs /tmp --tmpfs /var/tmp -v "$uki/unsigned:/in:ro" \
    -v "$uki/pcr:/pcr:ro" -v "$uki/policy:/out" "$tag-sealed" \
    ukify build --join-pcrsig "/in/${f##*/}" --pcrsig @/pcr/pcrsig.json --output "/out/${f##*/}"
  sudo chown -R "$(id -u):$(id -g)" "$uki/policy"
  f="$uki/policy/${f##*/}"
  python3 -I tools/signing/uki-check.py "$f" ci/uki-cmdline.txt
  python3 -I tools/signing/pcr-policy.py check "$f" "$uki/pcr/tpm2-pcr-public-key.pem"
  openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=Nyra CI per-run UKI key" \
    -keyout "$key/uki.key" -out "$uki/uki.crt" 2>/dev/null
  mkdir -p "$uki/signed.tmp"
  sbsign --key "$key/uki.key" --cert "$uki/uki.crt" --output "$uki/signed.tmp/${f##*/}" "$f"
  rm -rf "$key"
  sbverify --cert "$uki/uki.crt" "$uki"/signed.tmp/*.efi
  mv "$uki/signed.tmp" "$uki/signed"
fi
build "$@" --build-arg SEALED="$tag-sealed" --build-context uki="$uki/signed" -t "$tag"
