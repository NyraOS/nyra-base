#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds the bootc image from the mkosi root filesystem, with a sealed UKI (docs/BOOT.md):
#   1. the root filesystem without kernel and initramfs (Containerfile target "sealed"), committed;
#   2. the UKI from that committed image (ci/ukify.sh): bootc container ukify puts its composefs digest
#      on the command line; a second profile boots the same system into recovery. It reads the committed layers (podman --mount type=image), so file times are
#      the ones bootc will see after --timestamp, not the build's;
#   3. the UKI signed outside the image build: first its PCR 11 policy (the main profile's enter-initrd
#      phase only, tools/signing/pcr-policy.py), then the whole file for Secure Boot. Here: with two keys made for
#      this run only, deleted right after signing; the UKI certificate and the policy's public key stay
#      in UKI_DIR for the tests. The real Nyra keys will sign at this point, without CI ever holding
#      them. Only one file is signed, and only if it is the sealed UKI (tools/signing/uki-check.py,
#      ci/uki-cmdline.txt) and carries exactly the main profile's policy (pcr-policy.py check): both
#      checks, the signature and its verification are tools/signing/sign-uki.sh, the only script
#      that signs a UKI, here with the run's key and later with the real one;
#   4. the final image: the committed root filesystem plus the signed UKI in /boot/EFI/Linux.
# Before step 1, the next PCR policy key's public half is put in place for the image (below), and
# the crates of nyra-updated, zlib-rs and ntpd-rs are fetched into UKI_DIR/crates (cargo fetch
# --locked: the checksums in the Cargo.lock of updated/, zlib/ and ntpd-rs/), the only download of
# the build; the Containerfile checks each one against its Cargo.lock again and compiles them
# without network.
# With UKI_DIR/signed already there (ci/check-reproducible.sh), steps 2 and 3 are skipped and that
# UKI is used again; with UKI_DIR/crates there, those crates are, and nothing is downloaded.
# The image version (year.month.run) comes from the environment, VERSION (image.yml, arm64.yml): every build of
# a run writes the same one into os-release (Containerfile, NYRA_VERSION), and with it the UKI; dev
# without it (a local build).
#   VERSION=... ci/build-image.sh ROOTFS_IMAGE TAG UKI_DIR [podman build options...]
set -euo pipefail

rootfs="$1" tag="$2" uki="$3"
shift 3
build() {
  sudo podman build --timestamp "$SOURCE_DATE_EPOCH" --build-arg ROOTFS="$rootfs" --build-arg NYRA_VERSION="${VERSION:-dev}" \
    --build-context crates="$uki/crates" \
    --build-context pcrnext="$uki/pcr-next" "$@" -f Containerfile .
}

# The next PCR policy key's public half goes into the image (/usr/lib/nyra/secureboot), so that disks
# are enrolled for it before a release signs with it (docs/SIGNING.md, "The PCR policy key"): the
# committed one, or else one made for this run, whose private half is deleted at once (it signs
# nothing in CI). Made once per UKI_DIR, so a second build of the same inputs uses the same one.
if [ ! -f "$uki/pcr-next/tpm2-pcr-public-key-next.pem" ]; then
  mkdir -p "$uki/pcr-next"
  if [ -f files/usr/lib/nyra/secureboot/tpm2-pcr-public-key-next.pem ]; then
    cp files/usr/lib/nyra/secureboot/tpm2-pcr-public-key-next.pem "$uki/pcr-next/"
  else
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null |
      openssl pkey -pubout -out "$uki/pcr-next/tpm2-pcr-public-key-next.pem"
  fi
fi

# 10 retries instead of cargo's 3: these span over a minute for each request, cargo's about 10 s.
if [ ! -d "$uki/crates" ]; then
  mkdir -p "$uki/crates"
  for src in updated zlib ntpd-rs; do
    sudo podman run --rm -e CARGO_NET_RETRY=10 -v "$PWD/$src:/src:ro" -v "$uki/crates:/root/.cargo" localhost/nyra-tools \
      cargo fetch --locked --manifest-path /src/Cargo.toml
  done
else
  echo "build-image.sh: the crates are the ones fetched before ($uki/crates), nothing is downloaded" >&2
fi

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
  # The PCR 11 policy: pcr-policy.py computes the main profile's enter-initrd policy from the UKI and
  # signs only that, after checking that step 2 asked for exactly it; the signature is joined into the
  # UKI with the image's own ukify (no key in that container), then checked. --hwids '': nothing else
  # added (ukify builds a .hwids section by itself on arm64, see ci/ukify.sh).
  python3 -I tools/signing/pcr-policy.py sign "$f" "$key/pcr.key" > "$uki/pcr/pcrsig.json"
  mkdir -p "$uki/policy"
  sudo podman run --rm --network none --tmpfs /tmp --tmpfs /var/tmp -v "$uki/unsigned:/in:ro" \
    -v "$uki/pcr:/pcr:ro" -v "$uki/policy:/out" "$tag-sealed" \
    ukify build --hwids '' --join-pcrsig "/in/${f##*/}" --pcrsig @/pcr/pcrsig.json --output "/out/${f##*/}"
  sudo chown -R "$(id -u):$(id -g)" "$uki/policy"
  f="$uki/policy/${f##*/}"
  openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=Nyra CI per-run UKI key" \
    -keyout "$key/uki.key" -out "$uki/uki.crt" 2>/dev/null
  # The one script every UKI signature goes through: it repeats the checks above on the joined file,
  # signs, and verifies with the certificate (tools/signing/sign-uki.sh).
  PCR_PUBKEY="$uki/pcr/tpm2-pcr-public-key.pem" tools/signing/sign-uki.sh "$uki/policy" "$uki/signed.tmp" -- \
    --key "$key/uki.key" --cert "$uki/uki.crt"
  rm -rf "$key"
  mv "$uki/signed.tmp" "$uki/signed"
fi
build "$@" --build-arg SEALED="$tag-sealed" --build-context uki="$uki/signed" -t "$tag"
