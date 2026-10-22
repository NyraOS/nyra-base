#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The names an administrator cannot take, for a release tree (docs/INSTALL-INTERFACE.md, "check"): the
# file reserved-names at the root of the tree, one name per line, made by the image itself
# (/usr/lib/nyra/first-admin reserved-names: root, its accounts and groups, the names its sysusers.d
# files declare). The installer's last step and the first boot check the name against the same list.
# Run once for every release, by whatever makes the tree, as the user whose podman holds the image:
#   tools/install/reserved-names.sh IMAGE TREE
# The file is made next to the tree's root and moved into place, so a tree never has half a list. It is
# refused unless it is plain names, sorted, without repeats, and has root and the group sudo.
set -euo pipefail

[ $# = 2 ] || { echo "usage: reserved-names.sh IMAGE TREE" >&2; exit 1; }
image="$1" tree="$2"
[ -d "$tree" ] && [ ! -L "$tree" ] || { echo "reserved-names: $tree is not a directory" >&2; exit 1; }
tmp="$(mktemp "$tree/.reserved-names.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
${PODMAN:-podman} run --rm --pull=never --network none "$image" /usr/lib/nyra/first-admin reserved-names > "$tmp"
LC_ALL=C
export LC_ALL
[ -s "$tmp" ] || { echo "reserved-names: the image gave an empty list" >&2; exit 1; }
! grep -vqE '^[a-z][a-z0-9_-]{0,31}$' "$tmp" || { echo "reserved-names: a line is not a name an administrator could take" >&2; exit 1; }
[ "$(sort -u "$tmp")" = "$(cat "$tmp")" ] || { echo "reserved-names: the list is not sorted, without repeats" >&2; exit 1; }
for n in root sudo; do
  grep -qx "$n" "$tmp" || { echo "reserved-names: the list has not $n" >&2; exit 1; }
done
chmod 0644 "$tmp"
mv -f "$tmp" "$tree/reserved-names"
echo "reserved-names: $(wc -l < "$tree/reserved-names") names in $tree/reserved-names"
