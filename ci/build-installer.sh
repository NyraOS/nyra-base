#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds the text installer of the ISO (nyra-installer, github.com/NyraOS/installer) from the commit
# pinned in iso/installer-commit, the same way ci/build-image.sh builds pam-totp: only that commit is
# fetched (git hashes every object it receives, and the commit is checked against the pin), the crates
# are fetched with the checksums of its Cargo.lock (cargo fetch --locked, the only other download), and
# the build runs without a network, --locked --offline, in the tools image (localhost/nyra-tools).
# Writes OUT/nyra-installer (stripped) and OUT/Cargo.lock (the crates in it, for the SBOM), and prints
# the commit and the sha256 of both. No secret is used and nothing from the source runs outside the
# build container.
#   ci/build-installer.sh OUT
# PODMAN: the podman command, default "sudo podman" (CI); a local rehearsal sets its own store.
set -euo pipefail

[ $# = 1 ] || { echo "usage: build-installer.sh OUT" >&2; exit 1; }
out="$(realpath -m "$1")"
commit="$(cat iso/installer-commit)"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "build-installer.sh: iso/installer-commit is not a commit" >&2; exit 1; }
# shellcheck disable=SC2086 # PODMAN is a command with its options
pod() { ${PODMAN:-sudo podman} "$@"; }

rm -rf "$out"
mkdir -p "$out/src" "$out/cargo" "$out/target"
git init -q --bare "$out/installer.git"
git -C "$out/installer.git" fetch -q --depth 1 https://github.com/NyraOS/installer.git "$commit:refs/heads/pinned"
[ "$(git -C "$out/installer.git" rev-parse "$commit^{commit}")" = "$commit" ] \
  || { echo "build-installer.sh: the fetched commit is not $commit" >&2; exit 1; }
git -C "$out/installer.git" archive "$commit" | tar -x -C "$out/src"

pod run --rm -e CARGO_NET_RETRY=10 -v "$out/src:/src:ro" -v "$out/cargo:/root/.cargo" localhost/nyra-tools \
  cargo fetch --locked --manifest-path /src/Cargo.toml
# The program is the only product; the crates and the source stay out of the ISO. The container (root,
# so it can read what podman made) hands the two files to the user running this script.
owner="${OWNER:-$(id -u):$(id -g)}"
pod run --rm --network none -e OWNER="$owner" -v "$out/src:/src:ro" -v "$out/cargo:/root/.cargo" -v "$out/target:/target" \
  -v "$out:/out" localhost/nyra-tools sh -c '
    cargo build --release --locked --offline --manifest-path /src/Cargo.toml --target-dir /target &&
    cp /target/release/nyra-installer /src/Cargo.lock /out/ &&
    chown "$OWNER" /out/nyra-installer /out/Cargo.lock &&
    rm -rf /out/src /out/cargo /out/target /out/installer.git'
echo "nyra-installer: commit $commit"
(cd "$out" && sha256sum nyra-installer Cargo.lock)
