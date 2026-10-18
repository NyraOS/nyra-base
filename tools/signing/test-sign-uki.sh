#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Offline test of tools/signing/sign-uki.sh (docs/SIGNING.md): the refused cases make no sbsign call
# when they refuse before signing, the good case exactly one. sbsign and sbverify are stubs that record
# their calls; uki-check.py and pcr-policy.py are stubs too (they need a real UKI; test-uki-gate.sh
# tests them), made to fail on a file named like the case. The stub sbsign appends a line "signed" to
# the file it copies; the stub uki-check.py counts those lines (and "presigned" in a name is one).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A copy of the script in a tree of its own, so that it finds the stub checks.
mkdir -p "$tmp/tree/tools/signing" "$tmp/tree/ci" "$tmp/bin"
cp "$here/sign-uki.sh" "$tmp/tree/tools/signing/"
touch "$tmp/tree/ci/uki-cmdline.txt"
# argv: UKI EXPECTED SIGNATURES
cat > "$tmp/tree/tools/signing/uki-check.py" <<'STUB'
import sys
uki, want = sys.argv[1], int(sys.argv[3])
found = open(uki).read().count("signed") + ("presigned" in uki)
sys.exit(1 if "badcmdline" in uki or found != want else 0)
STUB
cat > "$tmp/tree/tools/signing/pcr-policy.py" <<'STUB'
import sys
sys.exit(1 if "badpolicy" in sys.argv[2] else 0)
STUB
cat > "$tmp/bin/sbsign" <<'STUB'
#!/bin/bash
echo "sbsign $*" >> "$CALLS"
out=""
while [ "$#" -gt 1 ]; do [ "$1" = --output ] && out="$2"; shift; done
{ cat "$1"; echo signed; [[ "$1" != *twosigs* ]] || echo signed; } > "$out"
STUB
cat > "$tmp/bin/sbverify" <<'STUB'
#!/bin/bash
echo "sbverify $*" >> "$CALLS"
[ -z "${SBVERIFY_FAILS:-}" ]
STUB
chmod +x "$tmp/bin/sbsign" "$tmp/bin/sbverify"

export PATH="$tmp/bin:$PATH" CALLS="$tmp/calls" PCR_PUBKEY=/pcr.pem
script="$tmp/tree/tools/signing/sign-uki.sh"
args=(--key k.key --cert k.crt)
fails=0

# run NAME SBSIGN_CALLS ok|fail [FILE...]: the FILEs go in a fresh input directory, with no output
# directory; the script gets $args after the two directories.
run() {
  local name="$1" calls="$2" want="$3" f status=ok got
  shift 3
  rm -rf "$tmp/in" "$tmp/out" "$CALLS"
  mkdir "$tmp/in"
  touch "$CALLS"
  for f in "$@"; do echo data > "$tmp/in/$f"; done
  [ -z "${SETUP:-}" ] || "$SETUP"
  "$script" "$tmp/in" "$tmp/out" "${args[@]}" 2>/dev/null || status=fail
  got="$(grep -c '^sbsign ' "$CALLS" || true)"
  if [ "$status" != "$want" ] || [ "$got" != "$calls" ]; then
    echo "FAIL $name: $status, $got sbsign calls (wanted $want, $calls)" >&2
    fails=$((fails + 1))
  else
    echo "ok   $name"
  fi
}

run "no file" 0 fail
run "two files" 0 fail a.efi b.efi
run "not .efi" 0 fail a.bin
run "an extra non-efi file" 0 fail a.efi a.txt
run "a hidden file" 0 fail .a
run "uki-check fails" 0 fail badcmdline.efi
run "pcr-policy fails" 0 fail badpolicy.efi
run "already signed" 0 fail presigned.efi
setup_symlink() { rm "$tmp/in/a.efi"; echo data > "$tmp/target"; ln -s "$tmp/target" "$tmp/in/a.efi"; }
SETUP=setup_symlink run "a symlink" 0 fail a.efi
setup_dir() { mkdir "$tmp/in/a.efi"; }
SETUP=setup_dir run "a directory named .efi" 0 fail
setup_fifo() { mkfifo "$tmp/in/a.efi"; }
SETUP=setup_fifo run "a fifo named .efi" 0 fail
setup_out() { mkdir "$tmp/out"; }
SETUP=setup_out run "OUT_DIR exists" 0 fail nyra.efi
run "output with two signatures" 1 fail twosigs.efi

run "good" 1 ok nyra.efi
[ "$(cat "$tmp/out/nyra.efi")" = "$(printf 'data\nsigned')" ] \
  || { echo "FAIL good: output file" >&2; fails=$((fails + 1)); }
grep -Eqx "sbsign --key k.key --cert k.crt --output $tmp/out/nyra.efi /.*/nyra.efi" "$CALLS" \
  && ! grep -q "nyra.efi $tmp/in/" "$CALLS" \
  || { echo "FAIL good: sbsign arguments (a copy of the input, not the input)" >&2; fails=$((fails + 1)); }
grep -qx "sbverify --cert k.crt $tmp/out/nyra.efi" "$CALLS" \
  || { echo "FAIL good: sbverify arguments" >&2; fails=$((fails + 1)); }

args=(--key obj:x --cert k.crt --engine eng)
run "engine" 1 ok nyra.efi
grep -Eq "^sbsign --engin[e] eng --key obj:x --cert k.crt --output " "$CALLS" \
  || { echo "FAIL engine: sbsign arguments" >&2; fails=$((fails + 1)); }
args=(--cert k.crt --engine e --key k.key)
run "options in another order" 1 ok nyra.efi

SBVERIFY_FAILS=1 run "sbverify fails" 1 fail nyra.efi

args=(--key k.key)
run "no --cert" 0 fail nyra.efi
args=(--cert k.crt)
run "no --key" 0 fail nyra.efi
args=(--key k.key --cert=k.crt)
run "--cert=FILE form" 0 fail nyra.efi
args=(--key k.key --cert k.crt --tool x)
run "unknown option" 0 fail nyra.efi
args=(--key k.key --cert k.crt --output x)
run "an sbsign option" 0 fail nyra.efi
args=(--key k.key --cert k.crt --key other.key)
run "repeated --key" 0 fail nyra.efi
args=(--key k.key --cert k.crt --cert other.crt)
run "repeated --cert" 0 fail nyra.efi
args=(--key k.key --cert k.crt --engine e --engine f)
run "repeated --engine" 0 fail nyra.efi
args=(--key k.key --cert k.crt --engine)
run "--engine without a value" 0 fail nyra.efi

args=(--key k.key --cert k.crt)
unset PCR_PUBKEY
run "no PCR_PUBKEY" 0 fail nyra.efi

[ "$fails" = 0 ] || exit 1
echo "sign-uki.sh: all cases passed"
