#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: puts the base images the CI takes from Amazon ECR Public's copy of Docker Hub's official
# images (Docker Hub limits unauthenticated pulls per runner IP) into podman's storage, as
#   localhost/pinned/debian    the CI tools' base, the FROM of ci/tools.Containerfile (built with --from)
#   localhost/pinned/registry  registry 3.0.0, the test registry of tools/signing/local-registry.sh
# ECR Public also refuses busy runner IPs ("toomanyrequests: Data limit exceeded"), so an image is
# pulled by its digest only when DIR has no copy of it, and saved there, as an OCI layout with
# uncompressed layers, for the Actions cache (.github/actions/pinned-images). A pulled image must have
# the image ID below: the digest of its config, which the pinned index names through its linux/amd64
# manifest. A copy is loaded only after ci/verify-oci.py has checked that it is exactly that image,
# layer by layer against the config's DiffIDs.
#   ci/pinned-images.sh DIR
set -euo pipefail

mkdir -p "$1"
while read -r name id ref; do
  [[ "$id" =~ ^[0-9a-f]{64}$ && "$ref" =~ @sha256:[0-9a-f]{64}$ ]]
  if [ -d "$1/$name" ]; then
    echo "$name: from the cache ($1/$name), not from ECR Public"
    python3 -I ci/verify-oci.py "$1/$name" "$id"
    sudo podman load -q -i "$1/$name"
  else
    echo "$name: no cached copy, pulling $ref"
    got="$(sudo podman pull -q "$ref")"
    if [ "$got" != "$id" ]; then
      echo "::error::$ref is image $got, not the pinned $id (update the ID in $0)"
      exit 1
    fi
    sudo podman save -q --format oci-dir --uncompressed -o "$1/$name" "$id"
    sudo chown -R "$(id -u):$(id -g)" "$1/$name"
    python3 -I ci/verify-oci.py "$1/$name" "$id" # what a later job checks: fail here, not there
  fi
  sudo podman image exists "$id"
  sudo podman tag "$id" "localhost/pinned/$name"
  echo "$name: image ID $id, as pinned for $ref"
done <<EOT
debian a23b5ee2cd75d1c22cb4ded04e78e8a0d930d57f77bd2695038367e0d5c09940 $(sed -n 's/^FROM //p' ci/tools.Containerfile)
registry 99b916d8206bcbfc54c95fb06076751932c902254277f149b082dd5d4d67fccb public.ecr.aws/docker/library/registry@sha256:6c5666b861f3505b116bb9aa9b25175e71210414bd010d92035ff64018f9457e
EOT
