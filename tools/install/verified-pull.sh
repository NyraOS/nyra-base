#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The one verified pull of a Nyra release (installer, verify-published): the image
# updates.nyraos.com/nyra-base:VERSION, accepted by the signature policy of this checkout, with the
# manifest digest DIGEST, into the container storage under STORAGE. Prints the local image ID (and
# only that) on stdout; the caller then uses that ID and never the name.
#   tools/install/verified-pull.sh VERSION DIGEST STORAGE
# Run as root, from a checkout of the release commit. STORAGE is a podman --root directory; bootc
# finds the image there when it is /var/lib/containers/storage.
#
# Why DIGEST is mandatory: the policy's matchRepository binds a signature to the repository, not to
# the tag. Anyone who can write to the registry can point :VERSION at an older image that is still
# validly signed (a rollback to a version with known holes). The digest, which the person
# installing takes from the release, and the labels in the signed config tie the image to this
# release. If any check fails the image is removed from STORAGE again.
set -euo pipefail

die() {
  echo "verified-pull: $*" >&2
  exit 1
}

[ $# = 3 ] || die "usage: verified-pull.sh VERSION DIGEST STORAGE"
version="$1" digest="$2" storage="$3"
[[ "$version" =~ ^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]] || die "not a version: $version"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "not a sha256 digest: $digest"
# A policy from the environment would replace the one checked here.
[ -z "${CONTAINERS_POLICY_JSON:-}" ] || die "CONTAINERS_POLICY_JSON is set"

# The repository is not an argument: nobody can point this script at another registry.
repo=updates.nyraos.com/nyra-base
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# --git-dir: git refuses to read a checkout owned by another user (sudo), unless told which one.
revision="$(git --git-dir="$root/.git" rev-parse HEAD)"

tmp="$(mktemp -d)"
id=""
cleanup() {
  local rc=$?
  [ "$rc" = 0 ] || [ -z "$id" ] || podman --root "$storage" rmi --force "$id" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

# The trust roots (the Fulcio CA, the Rekor key) are the checkout's, not those of the system the
# script runs on: the policy's /usr/lib/nyra/ paths point into the checkout's files/.
policy="$tmp/policy.json"
jq --arg root "$root/files" '
  (.. | strings | select(startswith("/usr/lib/nyra/"))) |= $root + .' \
  "$root/files/usr/lib/nyra/containers/policy.json" > "$policy"
jq -e --arg root "$root/files/" \
  '[.. | strings | select(startswith("/"))] | length > 0 and all(startswith($root))' \
  "$policy" > /dev/null || die "the policy points outside $root/files"

# overlay is the driver bootc reads the image from.
skopeo --policy "$policy" --registries.d "$root/files/usr/lib/nyra/containers/registries.d" \
  copy --preserve-digests --digestfile "$tmp/digest" \
  "docker://$repo:$version" "containers-storage:[overlay@$storage]$repo:$version" >&2
id="$(podman --root "$storage" image inspect --format '{{.Id}}' "$repo:$version")"

got="$(cat "$tmp/digest")"
[ "$got" = "$digest" ] || die "$repo:$version is $got, not $digest"
[ "$(podman --root "$storage" image inspect --format '{{.Digest}}' "$id")" = "$digest" ] \
  || die "the stored image does not have the digest $digest"
label() {
  podman --root "$storage" image inspect --format "{{index .Labels \"org.opencontainers.image.$1\"}}" "$id"
}
[ "$(label version)" = "$version" ] || die "the image's version label is not $version"
[ "$(label revision)" = "$revision" ] || die "the image's revision label is not $revision, the commit of this checkout"

echo "verified-pull: $repo:$version has the digest $digest, accepted by the policy" >&2
echo "$id"
