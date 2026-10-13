#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: puts the base images NAME... (only those the job needs) into podman's storage, as
#   localhost/pinned/debian    the CI tools' base, the FROM of ci/tools.Containerfile (built with --from)
#   localhost/pinned/registry  registry 3.0.0, the test registry of tools/signing/local-registry.sh
# Each is pinned by the digest of its index and by its image ID. An image is pulled by that digest
# only when DIR has no copy of it, and then cached in DIR (.github/actions/pinned-images) as an OCI
# layout with uncompressed layers. The pull tries the sources in order: Amazon ECR Public's copy of
# Docker Hub's official images first (Docker Hub limits unauthenticated pulls per runner IP), then
# Docker Hub itself, which serves the same index under the same digest. ECR Public also refuses busy
# runner IPs ("toomanyrequests: Data limit exceeded"), and release jobs never use the cache. Neither
# source is trusted: podman checks what it pulls against the digest, and the checks below are the
# same for both and for the cache.
# A copy from DIR is not trusted either: podman reads it (the oci: transport, one image), and what
# podman then stores is checked. The image must have the image ID below (the digest of its config,
# which the pinned index names through its linux/amd64 manifest), and a fresh `podman save` of it must
# pass ci/verify-oci.py: every layer, as stored, is the config's DiffID at its position (podman 4.9
# does not check that when it reads an image). Only then is it tagged; otherwise it is removed and the
# job fails, with no other source to fall back to.
#   ci/pinned-images.sh DIR NAME...
#   ci/pinned-images.sh --self-test   (needs the network and sudo; a podman store of its own)
set -euo pipefail

sources="public.ecr.aws/docker/library docker.io/library"
store=()

# The pinned image ID and index digest of NAME.
pinned() {
  case "$1" in
    debian) echo "a23b5ee2cd75d1c22cb4ded04e78e8a0d930d57f77bd2695038367e0d5c09940 $(sed -n 's/^FROM .*@sha256://p' ci/tools.Containerfile)" ;;
    registry) echo "99b916d8206bcbfc54c95fb06076751932c902254277f149b082dd5d4d67fccb 6c5666b861f3505b116bb9aa9b25175e71210414bd010d92035ff64018f9457e" ;;
    *) echo "::error::No pinned image $1" >&2; return 1 ;;
  esac
}

run_podman() {
  sudo podman "${store[@]}" "$@"
}

# Pulls NAME by DIGEST from the first source that serves it and prints the image ID podman stored.
pull() {
  local source got
  for source in $sources; do
    echo "$1: pulling $source/$1@sha256:$2" >&2
    if got="$(run_podman pull -q "$source/$1@sha256:$2")"; then
      echo "$1: pulled from $source" >&2
      echo "$got"
      return 0
    fi
    echo "::warning::$1: not pulled from $source" >&2
  done
  echo "::error::$1: no source served sha256:$2" >&2
  return 1
}

# Puts NAME, with image ID ID and index digest DIGEST, into podman's storage from DIR or a pull.
load() {
  local dir="$1" name="$2" id="$3" digest="$4" got out
  [[ "$id" =~ ^[0-9a-f]{64}$ && "$digest" =~ ^[0-9a-f]{64}$ ]]
  mkdir -p "$dir"
  if [ -d "$dir/$name" ]; then
    echo "$name: from the cache ($dir/$name), not pulled"
    got="$(run_podman pull -q "oci:$dir/$name")"
  else
    echo "$name: no cached copy"
    got="$(pull "$name" "$digest")" || return 1
  fi
  if [ "$got" != "$id" ]; then
    echo "::error::$name is image $got, not the pinned $id"
    run_podman rmi -f "$got" >/dev/null
    return 1
  fi
  out="$(mktemp -d)"
  run_podman save -q --format oci-dir --uncompressed -o "$out/$name" "$id"
  sudo chown -R "$(id -u):$(id -g)" "$out"
  if ! python3 -I ci/verify-oci.py "$out/$name" "$id"; then
    run_podman rmi -f "$id" >/dev/null
    return 1
  fi
  [ -d "$dir/$name" ] || mv "$out/$name" "$dir/$name"
  rm -rf "$out"
  run_podman tag "$id" "localhost/pinned/$name"
  echo "$name: image ID $id, every layer checked against its DiffID, as pinned for sha256:$digest"
}

# The first source unreachable: registry comes from the second, with the same checks. A digest no
# source has, and a copy whose image ID is not the pinned one, fail. The log of each case is shown
# with its workflow commands defused, so the expected errors make no annotations.
self_test() {
  local t id digest
  t="$(mktemp -d)"
  store=(--root "$t/root" --runroot "$t/run")
  sources="nyra-unreachable.invalid/library docker.io/library"
  read -r id digest <<<"$(pinned registry)"
  load "$t/cache" registry "$id" "$digest" 2>&1 | tee "$t/log" | sed 's/^::/(self-test) ::/'
  grep -qx "registry: pulled from docker.io/library" "$t/log"
  [ "$(run_podman image inspect -f '{{.Id}}' localhost/pinned/registry)" = "$id" ]
  if pull registry "$(printf '%064d' 0)" >"$t/log" 2>&1; then
    echo "::error::self-test: a digest that no source has was pulled"
    exit 1
  fi
  sed 's/^::/(self-test) ::/' "$t/log"
  grep -q "^::error::registry: no source served sha256:0\{64\}$" "$t/log"
  if load "$t/cache" registry "$(pinned debian | cut -d' ' -f1)" "$digest" >"$t/log" 2>&1; then
    echo "::error::self-test: an image with another image ID was accepted"
    exit 1
  fi
  sed 's/^::/(self-test) ::/' "$t/log"
  grep -q "^::error::registry is image $id, not the pinned " "$t/log"
  sudo rm -rf "$t"
  echo "pinned-images.sh self-test: ok"
}

if [ "${1:-}" = --self-test ]; then
  self_test
  exit 0
fi
[ $# -ge 2 ] || { echo "usage: $0 DIR NAME..." >&2; exit 2; }
dir="$1"
shift
for name in "$@"; do
  pin="$(pinned "$name")"
  read -r id digest <<<"$pin"
  load "$dir" "$name" "$id" "$digest"
done
