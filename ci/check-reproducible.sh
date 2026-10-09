#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Reproducibility check (docs/LESSONS.md): builds the root filesystem (mkosi) and the bootc layer
# (Containerfile) a second time from the same inputs and compares the layers with the first build,
# localhost/nyra-base:ci. On a difference it lists the files that differ in the mkosi layer.
# Runs after the build job's own build, with its WORK, SOURCE_DATE_EPOCH, tools image and caches.
# Limit: both builds use the same bootc binary ($WORK/bootc), so bootc's own build is not checked here
# (release builds compare it with the cached build, see image.yml), and both run on the same runner.
#   ci/check-reproducible.sh
set -euo pipefail

sudo podman run --rm --privileged -v "$PWD/mkosi:/src" -v "$WORK:/work" -v ~/cache/mkosi-packages:/packages \
  localhost/nyra-tools mkosi -C /src \
    --output-directory=/work/out2 --workspace-directory=/work/tmp --package-cache-dir=/packages \
    --extra-tree=/work/bootc:/ --source-date-epoch="$SOURCE_DATE_EPOCH" --force build
id="$(sudo podman pull -q "oci:$WORK/out2/nyra-base-rootfs")"
sudo podman tag "$id" localhost/nyra-base-rootfs:again
# Same steps as the first build (ci/build-image.sh), with the UKI it signed: the root filesystem is
# rebuilt and compared, the signature is not made twice.
ci/build-image.sh localhost/nyra-base-rootfs:again localhost/nyra-base:again "$WORK/uki" -q --no-cache >/dev/null

layers() { sudo podman image inspect -f '{{range .RootFS.Layers}}{{println .}}{{end}}' "$1"; }
if diff <(layers localhost/nyra-base:ci) <(layers localhost/nyra-base:again); then
  echo "Reproducible: the second build has the same $(layers localhost/nyra-base:ci | grep -c .) layers."
  exit 0
fi

echo "::error::Two builds of the same commit differ. The first layer is mkosi's, the others follow the Containerfile."
for o in out out2; do
  oci="$WORK/$o/nyra-base-rootfs"
  manifest="$(sudo jq -r '.manifests[0].digest' "$oci/index.json")"
  layer="$(sudo jq -r '.layers[0].digest' "$oci/blobs/sha256/${manifest#sha256:}")"
  sudo mkdir -p "$WORK/$o-layer"
  sudo tar -C "$WORK/$o-layer" -xf "$oci/blobs/sha256/${layer#sha256:}"
done
echo "Files that differ in the mkosi layer:"
sudo diff -rq --no-dereference "$WORK/out-layer" "$WORK/out2-layer" || true
exit 1
