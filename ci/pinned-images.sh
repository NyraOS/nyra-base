#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: puts the base images the CI takes from Amazon ECR Public's copy of Docker Hub's official
# images (Docker Hub limits unauthenticated pulls per runner IP) into podman's storage, as
#   localhost/pinned/debian    the CI tools' base, the FROM of ci/tools.Containerfile (built with --from)
#   localhost/pinned/registry  registry 3.0.0, the test registry of tools/signing/local-registry.sh
# ECR Public also refuses busy runner IPs ("toomanyrequests: Data limit exceeded"), so an image is
# pulled by its digest only when DIR has no copy of it, and then cached in DIR (.github/actions/
# pinned-images) as an OCI layout with uncompressed layers. A copy from DIR is not trusted: podman reads
# it (the oci: transport, one image), and what podman then stores is checked. The image must have the
# image ID below (the digest of its config, which the pinned index names through its linux/amd64
# manifest), and a fresh `podman save` of it must pass ci/verify-oci.py: every layer, as stored, is
# the config's DiffID at its position (podman 4.9 does not check that when it reads an image). Only
# then is it tagged; otherwise it is removed and the job fails, with no pull to fall back to.
#   ci/pinned-images.sh DIR
set -euo pipefail

mkdir -p "$1"
while read -r name id ref; do
  [[ "$id" =~ ^[0-9a-f]{64}$ && "$ref" =~ @sha256:[0-9a-f]{64}$ ]]
  if [ -d "$1/$name" ]; then
    echo "$name: from the cache ($1/$name), not from ECR Public"
    got="$(sudo podman pull -q "oci:$1/$name")"
  else
    echo "$name: no cached copy, pulling $ref"
    got="$(sudo podman pull -q "$ref")"
  fi
  if [ "$got" != "$id" ]; then
    echo "::error::$name is image $got, not the pinned $id"
    sudo podman rmi -f "$got" >/dev/null
    exit 1
  fi
  out="$(mktemp -d)"
  sudo podman save -q --format oci-dir --uncompressed -o "$out/$name" "$id"
  sudo chown -R "$(id -u):$(id -g)" "$out"
  if ! python3 -I ci/verify-oci.py "$out/$name" "$id"; then
    sudo podman rmi -f "$id" >/dev/null
    exit 1
  fi
  [ -d "$1/$name" ] || mv "$out/$name" "$1/$name"
  rm -rf "$out"
  sudo podman tag "$id" "localhost/pinned/$name"
  echo "$name: image ID $id, every layer checked against its DiffID, as pinned for $ref"
done <<EOT
debian a23b5ee2cd75d1c22cb4ded04e78e8a0d930d57f77bd2695038367e0d5c09940 $(sed -n 's/^FROM //p' ci/tools.Containerfile)
registry 99b916d8206bcbfc54c95fb06076751932c902254277f149b082dd5d4d67fccb public.ecr.aws/docker/library/registry@sha256:6c5666b861f3505b116bb9aa9b25175e71210414bd010d92035ff64018f9457e
EOT
