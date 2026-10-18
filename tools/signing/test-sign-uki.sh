#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Offline test of tools/signing/sign-uki.sh (docs/SIGNING.md): the refused cases make no sbsign call,
# the good case exactly one. sbsign and sbverify are stubs that record their calls; uki-check.py and
# pcr-policy.py are stubs too (they need a real UKI; test-uki-gate.sh tests them), made to fail on a
# file named like the case.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A copy of the script in a tree of its own, so that it finds the stub checks.
mkdir -p "$tmp/tree/tools/signing" "$tmp/tree/ci" "$tmp/bin"
cp "$here/sign-uki.sh" "$tmp/tree/tools/signing/"
touch "$tmp/tree/ci/uki-cmdline.txt"
cat > "$tmp/tree/tools/signing/uki-check.py" <<'STUB'
import sys
sys.exit(1 if "badcmdline" in sys.argv[1] else 0)
STUB
cat > "$tmp/tree/tools/signing/pcr-policy.py" <<'STUB'
import sys
sys.exit(1 if "badpolicy" in sys.argv[2] else 0)
STUB
cat > "$tmp/bin/sbsign" <<'STUB'
#!/bin/bash
echo "sbsign $*" >> "$CALLS"
out=""
while [ "$#" -gt 0 ]; do [ "$1" = --output ] && out="$2"; shift; done
echo signed > "$out"
STUB
cat > "$tmp/bin/sbverify" <<'STUB'
#!/bin/bash
echo "sbverify $*" >> "$CALLS"
[ -z "${SBVERIFY_FAILS:-}" ]
STUB
chmod +x "$tmp/bin/sbsign" "$tmp/bin/sbverify"

export PATH="$tmp/bin:$PATH" CALLS="$tmp/calls" PCR_PUBKEY=/pcr.pem
script="$tmp/tree/tools/signing/sign-uki.sh"
keys=(--key k.key --cert k.crt)
fails=0

# run NAME SBSIGN_CALLS ok|fail [FILE...]: the FILEs go in a fresh input directory.
run() {
  local name="$1" calls="$2" want="$3" f status=ok
  shift 3
  rm -rf "$tmp/in" "$tmp/out" "$CALLS"
  mkdir "$tmp/in"
  touch "$CALLS"
  for f in "$@"; do touch "$tmp/in/$f"; done
  "$script" "$tmp/in" "$tmp/out" -- "${keys[@]}" 2>/dev/null || status=fail
  local got
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
run "good" 1 ok nyra.efi
[ "$(cat "$tmp/out/nyra.efi")" = signed ] \
  || { echo "FAIL good: no output file" >&2; fails=$((fails + 1)); }
grep -qx "sbsign --key k.key --cert k.crt --output $tmp/out/nyra.efi $tmp/in/nyra.efi" "$CALLS" \
  || { echo "FAIL good: sbsign arguments" >&2; fails=$((fails + 1)); }
grep -qx "sbverify --cert k.crt $tmp/out/nyra.efi" "$CALLS" \
  || { echo "FAIL good: sbverify arguments" >&2; fails=$((fails + 1)); }

SBVERIFY_FAILS=1 run "sbverify fails" 1 fail nyra.efi

keys=(--key k.key)
run "no --cert in the arguments" 0 fail nyra.efi
keys=(--key k.key --cert=k.crt)
run "--cert=FILE form" 1 ok nyra.efi

unset PCR_PUBKEY
run "no PCR_PUBKEY" 0 fail nyra.efi

[ "$fails" = 0 ] || exit 1
echo "sign-uki.sh: all cases passed"
