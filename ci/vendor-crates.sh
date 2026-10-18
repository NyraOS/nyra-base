#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Image build (Containerfile), without network: the crates that LOCK lists become cargo's only source
# of crates. They come from the build context "crates" (mounted at /crates), which ci/build-image.sh
# fetched with cargo fetch --locked. Cargo does not check a crate already in its download cache against
# Cargo.lock, and takes features from the registry index, which nothing pins. So neither cargo's cache
# nor the index is used: each .crate the lock lists is copied, checked against the lock's checksum, and
# unpacked into a directory source that replaces crates.io ($HOME/vendor, $HOME/.cargo/config.toml).
#   vendor-crates.sh LOCK
set -eu

lock="$1"
set -- /crates/registry/cache/*/
[ $# = 1 ] || { echo "expected one crate cache directory, found: $*" >&2; exit 1; }
cache="$1"
mkdir -p "$HOME/vendor" "$HOME/.cargo"
awk -F'"' '/^name = /{n=$2} /^version = /{v=$2} /^checksum = /{print $2 " " n "-" v}' "$lock" > "$HOME/sums"
test -s "$HOME/sums"
while read -r sum crate; do
	cp "$cache$crate.crate" "$HOME/x.crate"
	echo "$sum  $HOME/x.crate" | sha256sum --quiet --strict -c -
	tar -xzf "$HOME/x.crate" -C "$HOME/vendor"
	printf '{"files":{},"package":"%s"}' "$sum" > "$HOME/vendor/$crate/.cargo-checksum.json"
done < "$HOME/sums"
printf '[source.crates-io]\nreplace-with = "checked"\n[source.checked]\ndirectory = "%s/vendor"\n' "$HOME" \
	> "$HOME/.cargo/config.toml"
