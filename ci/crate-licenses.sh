#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Image build (Containerfile), after ci/vendor-crates.sh and cargo build: the licence notices of every
# crate the package in the current directory links (cargo tree, normal dependencies, this target),
# copied from the unpacked crates in $HOME/vendor to OUT/<crate>-<version>/. The build fails when a
# crate has no licence file.
#   crate-licenses.sh OUT
set -eu

out="$1"
cargo tree --locked --offline -e normal --target x86_64-unknown-linux-gnu --prefix none > "$HOME/tree"
# "name vX.Y.Z" for each crate from the lock; our own package has its path after it, a crate already
# listed has "(*)".
sed -n 's/^\([^ ]*\) v\([^ ]*\)$/\1-\2/p' "$HOME/tree" | sort -u > "$HOME/crates"
test -s "$HOME/crates"
while read -r crate; do
	mkdir -p "$out/$crate"
	find "$HOME/vendor/$crate" -maxdepth 1 -type f \
		\( -iname 'licen[cs]e*' -o -iname 'copying*' -o -iname 'copyright*' -o -iname 'notice*' \) -exec cp {} "$out/$crate/" \;
	[ -n "$(ls "$out/$crate")" ] || { echo "$crate: no licence file" >&2; exit 1; }
done < "$HOME/crates"
