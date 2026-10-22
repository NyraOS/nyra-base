#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Puts the release image, and its signature, into the files of a registry: the store that the ISO carries
# and that the registry of the installer system serves, read-only, on 127.0.0.1 (docs/ISO.md). The
# registry and skopeo that write it are the ones the ISO carries (the installer system, run as a
# container from its own tree), with no network, so the files are what that registry reads.
#   ci/iso-registry.sh WORKDIR ARCHIVE VERSION release SIGNATURE_DIR
#   ci/iso-registry.sh WORKDIR ARCHIVE VERSION test
# ARCHIVE is the oci-archive of the image. release: SIGNATURE_DIR holds the files of the sign job's
# artifact (signature/, an OCI layout with the one signature, and image-digest); the signature is the
# release's, and it is pushed as it is. test: a pull request has no release signature, so the image is
# signed with a key made here for this run (skopeo generate-sigstore-key) and the public half is left in
# WORKDIR/registry-test.pub for the test policy (ci/build-iso.sh); this key signs nothing else.
# Writes WORKDIR/registry (the store) and WORKDIR/registry-digest (the manifest digest it holds).
# WORKDIR/os/nyra-installer-os is the installer system (ci/build-iso-os.sh).
# PODMAN and PRIV: as in ci/build-iso-os.sh. ISO_ARCH (amd64, default, or arm64) names the repository: nyra-base
# or nyra-base-arm64, the two-value allow-list of the architectures (docs/ARM64.md, "Releases").
set -euo pipefail

mode="${4:-}"
{ [ "$mode" = release ] && [ $# = 5 ]; } || { [ "$mode" = test ] && [ $# = 4 ]; } \
  || { echo "usage: iso-registry.sh WORKDIR ARCHIVE VERSION release SIGNATURE_DIR | test" >&2; exit 1; }
work="$(realpath -m "$1")" archive="$(realpath "$2")" version="$3"
[[ "$version" =~ ^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]] || { echo "iso-registry.sh: not a version: $version" >&2; exit 1; }
case "${ISO_ARCH:-amd64}" in
  amd64) repo_name=nyra-base ;;
  arm64) repo_name=nyra-base-arm64 ;;
  *) echo "iso-registry.sh: ISO_ARCH is amd64 or arm64" >&2; exit 1 ;;
esac
os="$work/os/nyra-installer-os"
[ -d "$os" ] || { echo "iso-registry.sh: no installer system at $os" >&2; exit 1; }
# shellcheck disable=SC2086 # PODMAN is a command with its options
pod() { ${PODMAN:-sudo podman} "$@"; }
# shellcheck disable=SC2086 # PRIV is empty or a command
priv() { ${PRIV-sudo} "$@"; }

mounts=(-v "$archive:/in/nyra-base.oci.tar:ro")
if [ "$mode" = release ]; then
  sig="$(realpath "$5")"
  image_digest="$(cat "$sig/image-digest")"
  [[ "$image_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "iso-registry.sh: $sig/image-digest is not a digest" >&2; exit 1; }
  [ -f "$sig/signature/index.json" ] || { echo "iso-registry.sh: no signature layout in $sig" >&2; exit 1; }
  mounts+=(-v "$sig/signature:/in/signature:ro")
else
  image_digest=""
fi

priv rm -rf "$work/registry" "$work/registry-out"
mkdir -p "$work/registry" "$work/registry-out"
guest='
set -euo pipefail
cat > /tmp/registry.yml <<YML
version: 0.1
log: {level: warn}
storage:
  filesystem: {rootdirectory: /registry}
http: {addr: "127.0.0.1:80"}
YML
docker-registry serve /tmp/registry.yml &
registry=$!
for _ in $(seq 100); do (exec 3<>/dev/tcp/127.0.0.1/80) 2> /dev/null && break; sleep 0.2; done
repo=docker://updates.nyraos.com/$REPO_NAME
mkdir -p /tmp/registries.d
printf "docker:\n  updates.nyraos.com:\n    use-sigstore-attachments: true\n" > /tmp/registries.d/test.yaml
if [ "$MODE" = test ]; then
  echo nyra-iso-test > /tmp/pass
  skopeo generate-sigstore-key --output-prefix /out/sigstore --passphrase-file /tmp/pass > /dev/null
  skopeo --insecure-policy --registries.d /tmp/registries.d copy --dest-tls-verify=false --preserve-digests \
    --digestfile /out/digest --sign-by-sigstore-private-key /out/sigstore.private --sign-passphrase-file /tmp/pass \
    oci-archive:/in/nyra-base.oci.tar "$repo:$VERSION"
else
  skopeo --insecure-policy copy --dest-tls-verify=false --preserve-digests --digestfile /out/digest \
    oci-archive:/in/nyra-base.oci.tar "$repo:$VERSION"
  [ "$(cat /out/digest)" = "$IMAGE_DIGEST" ]
  sigtag="${IMAGE_DIGEST/:/-}.sig"
  skopeo --insecure-policy copy --dest-tls-verify=false --preserve-digests "oci:/in/signature:$sigtag" "$repo:$sigtag"
fi
kill "$registry"
wait "$registry" || true
'
pod run --rm --no-hosts --network none --rootfs -e MODE="$mode" -e REPO_NAME="$repo_name" -e VERSION="$version" -e IMAGE_DIGEST="$image_digest" \
  "${mounts[@]}" -v "$work/registry:/registry" -v "$work/registry-out:/out" "$os:O" bash -c "$guest"

digest="$(cat "$work/registry-out/digest")"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "iso-registry.sh: no image digest was written" >&2; exit 1; }
echo "$digest" > "$work/registry-digest"
if [ "$mode" = test ]; then cp "$work/registry-out/sigstore.pub" "$work/registry-test.pub"; fi
priv rm -rf "$work/registry-out"
# Transient upload state is not part of the store the ISO carries.
priv find "$work/registry" -name _uploads -prune -exec rm -rf {} +
echo "iso-registry: $version is $digest"
