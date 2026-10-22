#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The one verified pull of a Nyra release (installer, verify-published): the image
# updates.nyraos.com/REPOSITORY:VERSION, accepted by the signature policy of this checkout, with the
# manifest digest DIGEST, into the container storage under STORAGE. Prints the local image ID (and
# only that) on stdout; the caller then uses that ID and never the name.
#   tools/install/verified-pull.sh REPOSITORY VERSION DIGEST STORAGE
# REPOSITORY is one of two names, each the images of one architecture (docs/ARM64.md, "Releases"):
# nyra-base is linux/amd64 and nyra-base-arm64 is linux/arm64. Anything else is refused, and so is a
# pulled image whose config says another OS or architecture.
# Run as root, from a checkout of the release commit, or from a release tree: the files of the release
# with a file RELEASE instead of a .git, and no git needed (tools/install/release-tree.sh). STORAGE is a
# podman --root directory; bootc finds the image there when it is /var/lib/containers/storage.
#
# Why DIGEST is mandatory: the policy's matchRepository binds a signature to the repository, not to
# the tag. Anyone who can write to the registry can point :VERSION at an older image that is still
# validly signed (a rollback to a version with known holes). The digest, which the person
# installing takes from the release, and the labels in the signed config tie the image to this
# release. If any check fails the image is removed from STORAGE again.
# The image is pulled twice, by tag and by digest (machines update by digest: nyra-updated runs
# bootc switch with nyra-base@DIGEST), under the same policy; only manifest and signature are new.
# Exit codes: 0 pulled and verified; 2 pulled but a check failed (digest, labels): a caller must not
# retry; 1 anything else (usage, policy, the pull itself): a caller may retry.
set -euo pipefail

die() {
  echo "verified-pull: $*" >&2
  exit 1
}
# The pull worked and the image is not the release's: no retry will change that.
refuse() {
  echo "verified-pull: $*" >&2
  exit 2
}

[ $# = 4 ] || die "usage: verified-pull.sh REPOSITORY VERSION DIGEST STORAGE"
name="$1" version="$2" digest="$3" storage="$4"
# The allow-list: a constant per run, never a free name (nobody can point this script at another registry).
case "$name" in
  nyra-base) platform=linux/amd64 ;;
  nyra-base-arm64) platform=linux/arm64 ;;
  *) die "not a Nyra image repository (nyra-base, nyra-base-arm64): $name" ;;
esac
[[ "$version" =~ ^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]] || die "not a version: $version"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "not a sha256 digest: $digest"
# A policy from the environment would replace the one checked here.
[ -z "${CONTAINERS_POLICY_JSON:-}" ] || die "CONTAINERS_POLICY_JSON is set"

repo=updates.nyraos.com/$name
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$root/tools/install/release-tree.sh"
tree_identify "$root" "$name" "$version" "$digest"
revision="$tree_commit"

tmp="$(mktemp -d)" || die "cannot create a temporary directory"
cleanup() {
  local rc=$?
  # No --force: a container that uses the image keeps it.
  if [ "$rc" != 0 ]; then
    podman --root "$storage" rmi "$repo:$version" >/dev/null 2>&1 || true
    podman --root "$storage" rmi "$repo@$digest" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

# The trust roots (the Fulcio CA, the Rekor key) are the checkout's, not those of the system the
# script runs on: the policy's /usr/lib/nyra/ paths point into the checkout's files/.
policy="$tmp/policy.json"
jq --arg root "$root/files" '
  (.. | strings | select(startswith("/usr/lib/nyra/"))) |= $root + .' \
  "$root/files/usr/lib/nyra/containers/policy.json" > "$policy" || die "cannot read the policy"
jq -e --arg root "$root/files/" \
  '[.. | strings | select(startswith("/"))] | length > 0 and all(startswith($root))' \
  "$policy" > /dev/null || die "the policy points outside $root/files"

# overlay is the driver bootc reads the image from.
skopeo --policy "$policy" --registries.d "$root/files/usr/lib/nyra/containers/registries.d" \
  copy --preserve-digests --digestfile "$tmp/digest" \
  "docker://$repo:$version" "containers-storage:[overlay@$storage]$repo:$version" >&2 \
  || die "cannot pull $repo:$version"
id="$(podman --root "$storage" image inspect --format '{{.Id}}' "$repo:$version")" \
  || die "cannot find the pulled image $repo:$version"

got="$(cat "$tmp/digest")" || die "cannot read the digest of $repo:$version"
[ "$got" = "$digest" ] || refuse "$repo:$version is $got, not $digest"
# .Digest can name another stored manifest; RepoDigests lists what the pull by digest recorded.
repo_digests="$(podman --root "$storage" image inspect --format '{{json .RepoDigests}}' "$id")" \
  || die "cannot read the digests of the pulled image"
jq -e --arg ref "$repo@$digest" 'index($ref) != null' <<< "$repo_digests" > /dev/null \
  || refuse "the stored image does not have the digest $digest"
# The signed config says which architecture this is: an image of the other one is never installed.
[ "$(podman --root "$storage" image inspect --format '{{.Os}}/{{.Architecture}}' "$id")" = "$platform" ] \
  || refuse "$repo:$version is not $platform, the platform of $name"
label() {
  podman --root "$storage" image inspect --format "{{index .Labels \"org.opencontainers.image.$1\"}}" "$id"
}
[ "$(label version)" = "$version" ] || refuse "the image's version label is not $version"
[ "$(label revision)" = "$revision" ] || refuse "the image's revision label is not $revision, the commit of this tree"

# The reference machines switch to, accepted by the same policy; refused means the script fails.
skopeo --policy "$policy" --registries.d "$root/files/usr/lib/nyra/containers/registries.d" \
  copy --preserve-digests --digestfile "$tmp/digest-ref" \
  "docker://$repo@$digest" "containers-storage:[overlay@$storage]$repo@$digest" >&2 \
  || die "cannot pull $repo@$digest"
[ "$(cat "$tmp/digest-ref")" = "$digest" ] || refuse "$repo@$digest was stored as another digest"

echo "verified-pull: $repo:$version and $repo@$digest are accepted by the policy; digest $digest" >&2
echo "$id"
