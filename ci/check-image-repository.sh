#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The repository an image is released to is bound to its architecture (docs/ARM64.md, "Releases"):
#   nyra-base        linux/amd64
#   nyra-base-arm64  linux/arm64
# and nothing else. Refuses unless REPOSITORY is one of these, the image's config says that OS and
# architecture, and the image's /usr/lib/nyra/updates/updated.conf names exactly that repository
# (one `repository = ` line), so that a machine follows the channel sheets of its own architecture.
# Reads the image with podman create and cp: nothing from the image runs.
#   ci/check-image-repository.sh IMAGE REPOSITORY
set -euo pipefail

image="$1" repository="$2"
refuse() { echo "check-image-repository: refused: $*" >&2; exit 1; }

case "$repository" in
  nyra-base) want=linux/amd64 ;;
  nyra-base-arm64) want=linux/arm64 ;;
  *) refuse "'$repository' is not a release repository (nyra-base, nyra-base-arm64)" ;;
esac
got="$(sudo podman image inspect -f '{{.Os}}/{{.Architecture}}' "$image")"
[ "$got" = "$want" ] || refuse "$image is $got, $repository takes $want"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cid="$(sudo podman create -q "$image")"
sudo podman cp "$cid:/usr/lib/nyra/updates/updated.conf" "$tmp/updated.conf"
sudo podman rm -f "$cid" >/dev/null
lines="$(sudo grep -E '^[[:space:]]*repository[[:space:]]*=' "$tmp/updated.conf")" || true
[ "$lines" = "repository = $repository" ] ||
  refuse "$image's updated.conf must have exactly the line 'repository = $repository', it has: ${lines:-none}"
echo "check-image-repository: $image is $got and follows $repository"
