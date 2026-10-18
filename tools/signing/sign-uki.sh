#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The only place a UKI gets its Secure Boot signature (docs/SIGNING.md):
#   tools/signing/sign-uki.sh IN_DIR OUT_DIR -- SBSIGN_KEY_ARGS...
# IN_DIR holds exactly one file, a *.efi. Before any signature it must pass the checks of the sealed
# UKI: uki-check.py against ci/uki-cmdline.txt (one UKI, not an add-on, the sealed command line) and
# pcr-policy.py check against the PCR policy public key in $PCR_PUBKEY (the main profile's policy
# and no other). Then `sbsign SBSIGN_KEY_ARGS --output OUT_DIR/<name> IN_DIR/<name>`, and sbverify
# with the certificate given by --cert in the key arguments. Any failure stops the script; whatever
# key the arguments name (a file today, a pkcs11: URI later), it signs only what passed the checks.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
die() { echo "sign-uki.sh: $*" >&2; exit 1; }

[ "$#" -ge 3 ] && [ "$3" = -- ] || die "usage: sign-uki.sh IN_DIR OUT_DIR -- SBSIGN_KEY_ARGS..."
in_dir="$1" out_dir="$2"
shift 3
[ -d "$in_dir" ] || die "$in_dir is not a directory"
[ -n "${PCR_PUBKEY:-}" ] || die "PCR_PUBKEY (the PCR policy public key) is not set"

cert=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    --cert) cert="${args[i + 1]:-}" ;;
    --cert=*) cert="${args[i]#--cert=}" ;;
  esac
done
[ -n "$cert" ] || die "no --cert in the key arguments: the signature could not be verified"

shopt -s nullglob dotglob
files=("$in_dir"/*)
if [ "${#files[@]}" != 1 ] || [[ "${files[0]}" != *.efi ]] || [ ! -f "${files[0]}" ]; then
  die "expected exactly one UKI (*.efi) in $in_dir, found: ${files[*]:-nothing}"
fi
uki="${files[0]}"
name="${uki##*/}"

python3 -I "$root/tools/signing/uki-check.py" "$uki" "$root/ci/uki-cmdline.txt"
python3 -I "$root/tools/signing/pcr-policy.py" check "$uki" "$PCR_PUBKEY"

mkdir -p "$out_dir"
sbsign "$@" --output "$out_dir/$name" "$uki"
sbverify --cert "$cert" "$out_dir/$name"
