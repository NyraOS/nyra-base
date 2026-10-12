#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: puts the base images the CI takes from Amazon ECR Public's copy of Docker Hub's official
# images (Docker Hub limits unauthenticated pulls per runner IP) into podman's storage, as
#   localhost/pinned/debian    the CI tools' base, the FROM of ci/tools.Containerfile (built with --from)
#   localhost/pinned/registry  registry 3.0.0, the test registry of tools/signing/local-registry.sh
# ECR Public also refuses busy runner IPs ("toomanyrequests: Data limit exceeded"), so an image is
# pulled by its digest only when DIR has no copy of it, and saved there for the Actions cache
# (.github/actions/pinned-images). Either way it must have the image ID below: the digest of its
# config, which the pinned index names through its linux/amd64 manifest. A copy that is not that
# image is refused.
#   ci/pinned-images.sh DIR
set -euo pipefail

mkdir -p "$1"
while read -r name id ref; do
  [[ "$id" =~ ^[0-9a-f]{64}$ && "$ref" =~ @sha256:[0-9a-f]{64}$ ]]
  if [ -f "$1/$name.oci.tar" ]; then
    echo "$name: from the cache ($1/$name.oci.tar), not from ECR Public"
    sudo podman load -q -i "$1/$name.oci.tar"
  else
    echo "$name: no cached copy, pulling $ref"
    got="$(sudo podman pull -q "$ref")"
    if [ "$got" != "$id" ]; then
      echo "::error::$ref is image $got, not the pinned $id (update the ID in $0)"
      exit 1
    fi
    sudo podman save -q --format oci-archive -o "$1/$name.oci.tar" "$id"
  fi
  if ! sudo podman image exists "$id"; then
    echo "::error::$1/$name.oci.tar does not hold image $id"
    exit 1
  fi
  sudo podman tag "$id" "localhost/pinned/$name"
  echo "$name: image ID $id, as pinned for $ref"
done <<EOT
debian a23b5ee2cd75d1c22cb4ded04e78e8a0d930d57f77bd2695038367e0d5c09940 $(sed -n 's/^FROM //p' ci/tools.Containerfile)
registry 99b916d8206bcbfc54c95fb06076751932c902254277f149b082dd5d4d67fccb public.ecr.aws/docker/library/registry@sha256:6c5666b861f3505b116bb9aa9b25175e71210414bd010d92035ff64018f9457e
EOT
