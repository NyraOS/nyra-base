#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The join of an arm64 release (docs/SIGNING.md, "Release mode"; image.yml's release-sign-arm64 and
# arm64.yml's join test): the signed PCR policy (PCRSIG, pcr-policy.py's output) joined into the
# unsigned UKI with the sealed image's own ukify, an arm64 program, on the x86_64 runner where the KMS
# library runs. The container is the one release-sign runs for x86_64, plus --platform:
#   - the image by ID (IMAGE must be loaded, its config must say PLATFORM), --pull=never;
#   - no network, no environment, only three fresh directories (WORKDIR/in and WORKDIR/pcr read-only,
#     WORKDIR/out), never the workspace;
#   - for another architecture than the runner's, qemu-user runs it: the binfmt_misc entry must be
#     Ubuntu's qemu-user-static's (installed and registered from Ubuntu's archive, before any
#     credential is in the job), with the F flag (the emulator opened at registration, so nothing in the
#     container is used as the emulator). qemu-user is not a boundary: the container is (docs/SIGNING.md).
# The joined UKI is WORKDIR/out/<the UKI's name>. WORKDIR must not exist.
#   tools/signing/join-pcrsig.sh IMAGE PLATFORM UKI PCRSIG WORKDIR
set -euo pipefail

image="$1" platform="$2" uki="$3" pcrsig="$4" join="$5"
die() { echo "join-pcrsig.sh: $*" >&2; exit 1; }

case "$platform" in
  linux/amd64) machine=x86_64 entry="" ;;
  linux/arm64) machine=aarch64 entry=qemu-aarch64 ;;
  *) die "unknown platform '$platform'" ;;
esac
[ -f "$uki" ] && [ ! -L "$uki" ] && [[ "$uki" == *.efi ]] || die "$uki is not a regular *.efi file"
[ -f "$pcrsig" ] && [ ! -L "$pcrsig" ] || die "$pcrsig is not a regular file"
[ ! -e "$join" ] && [ ! -L "$join" ] || die "$join exists"
id="$(sudo podman image inspect -f '{{.Id}}' "$image")"
[[ "$id" =~ ^[0-9a-f]{64}$ ]] || die "no image ID for $image"
got="$(sudo podman image inspect -f '{{.Os}}/{{.Architecture}}' "$id")"
[ "$got" = "$platform" ] || die "$image is $got, not $platform"

if [ "$(uname -m)" != "$machine" ]; then
  [ -n "$entry" ] || die "no emulator allowed for $platform"
  f="/proc/sys/fs/binfmt_misc/$entry"
  [ -f "$f" ] && grep -qx enabled "$f" || die "binfmt_misc has no enabled $entry entry"
  interpreter="$(sed -n 's/^interpreter //p' "$f")"
  flags="$(sed -n 's/^flags: //p' "$f")"
  [[ "$flags" == *F* ]] || die "the $entry entry has no F flag (flags: $flags)"
  for path in "$interpreter" "$(readlink -f "$interpreter")"; do
    owner="$(dpkg -S "$path" 2>/dev/null | cut -d: -f1)" || true
    [ "$owner" = qemu-user-static ] || die "the $entry interpreter $path is not qemu-user-static's (${owner:-no package})"
  done
  echo "join-pcrsig.sh: $platform under $interpreter ($(dpkg-query -W -f '${Package} ${Version}' qemu-user-static), flags $flags)"
fi

name="${uki##*/}"
mkdir -p "$join/in" "$join/pcr" "$join/out"
cp -- "$uki" "$join/in/$name"
cp -- "$pcrsig" "$join/pcr/pcrsig.json"
sudo podman run --rm --pull=never --platform "$platform" --network none --tmpfs /tmp --tmpfs /var/tmp \
  -v "$join/in:/in:ro" -v "$join/pcr:/pcr:ro" -v "$join/out:/out" "$id" \
  ukify build --hwids '' --join-pcrsig "/in/$name" --pcrsig @/pcr/pcrsig.json --output "/out/$name"
sudo chown -R "$(id -u):$(id -g)" "$join/out"
[ -f "$join/out/$name" ] || die "ukify wrote no $join/out/$name"
