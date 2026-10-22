#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Offline test of tools/install/reserved-names.sh: the file reserved-names at the root of a release
# tree is made from what the image prints (a stand-in podman), in the form the installer reads (one name
# per line), and only then. Refused, and no file left in the tree (nor a half-written one): an empty list,
# a line that is not a name an administrator could take (an upper case letter, a space, a dot, an empty
# line, a name of 33 characters), a list that is not sorted or repeats a name, a list without root or
# sudo, a failing image; a list that was there before is not touched by a refusal. Each refusal is shown
# to be the check's: a list the check takes is taken.
#   tools/install/test-reserved-names.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT
fail() {
  echo "::error::$*" >&2
  exit 1
}
mkdir "$t/bin" "$t/tree"
cat > "$t/bin/podman" << 'EOF2'
#!/bin/bash
# podman run --rm --pull=never --network none IMAGE /usr/lib/nyra/first-admin reserved-names
[ "$*" = "run --rm --pull=never --network none nyra-image /usr/lib/nyra/first-admin reserved-names" ] || exit 2
[ "$LIST" != fail ] || exit 1
printf '%b' "$LIST"
EOF2
chmod +x "$t/bin/podman"
export PATH="$t/bin:$PATH"

make() { LIST="$1" tools/install/reserved-names.sh nyra-image "$t/tree" > "$t/out" 2>&1; }
good='daemon\nroot\nsudo\nsystemd-network\n'
make "$good" || { cat "$t/out"; fail "a good list is refused"; }
[ "$(cat "$t/tree/reserved-names")" = "$(printf '%b' "$good")" ] || fail "the file is not the list"
[ "$(stat -c %a "$t/tree/reserved-names")" = 644 ] || fail "the file is not 0644"
[ "$(ls -A "$t/tree")" = reserved-names ] || fail "something else is left in the tree: $(ls -A "$t/tree")"
echo "a good list is the file reserved-names at the root of the tree, 0644, one name per line"
refuses() { # refuses WHAT LIST
  local before
  before="$(cat "$t/tree/reserved-names")"
  if make "$2"; then cat "$t/out"; fail "$1: taken"; fi
  [ "$(cat "$t/tree/reserved-names")" = "$before" ] || fail "$1: the list that was there was changed"
  [ "$(ls -A "$t/tree")" = reserved-names ] || fail "$1: something is left in the tree"
  echo "refused: $1"
}
refuses "an empty list" ''
refuses "a failing image" fail
refuses "an upper case letter" 'Root\nroot\nsudo\n'
refuses "a space" 'a b\nroot\nsudo\n'
refuses "a dot" 'a.b\nroot\nsudo\n'
refuses "an empty line" 'root\n\nsudo\n'
refuses "a name of 33 characters" "root\nsudo\n$(printf 'z%.0s' $(seq 33))\n"
refuses "a list that is not sorted" 'sudo\nroot\n'
refuses "a name twice" 'root\nroot\nsudo\n'
refuses "a list without root" 'daemon\nsudo\n'
refuses "a list without sudo" 'daemon\nroot\n'
refuses "a carriage return" 'root\r\nsudo\n'
# The control: names of 32 characters and with - and _ are taken, so the refusals above are the check's.
make 'a\nroot\nsudo\nz-z_9\n'"$(printf 'z%.0s' $(seq 32))"'\n' || { cat "$t/out"; fail "a list of good names is refused"; }
echo "a name of 32 characters, with - and _, is taken"
rm "$t/tree/reserved-names"
ln -s /nonexistent "$t/tree/reserved-names"
make "$good" && [ ! -L "$t/tree/reserved-names" ] && [ -f "$t/tree/reserved-names" ] || fail "a link in place of the file is not replaced by the file"
echo "a link in place of the file is replaced by the file"
if tools/install/reserved-names.sh nyra-image "$t/nothing" > /dev/null 2>&1; then fail "a tree that is not there"; fi
echo "ok"
