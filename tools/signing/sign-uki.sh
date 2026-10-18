#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The only place a UKI gets its Secure Boot signature (docs/SIGNING.md):
#   tools/signing/sign-uki.sh IN_DIR OUT_DIR --key KEY --cert CERT [--engine ENGINE]
# KEY is a file, or a pkcs11: URI when ENGINE is given; no other option is accepted, so nothing else
# reaches sbsign. IN_DIR holds exactly one file, a regular *.efi (no symlink), read once: a copy in a
# private directory is checked and signed, never the original. The copy must pass the checks of the
# sealed UKI and be unsigned: uki-check.py against ci/uki-cmdline.txt (one UKI, not an add-on, the
# sealed command line; 0 signatures) and pcr-policy.py check against the PCR policy public key in
# $PCR_PUBKEY (the main profile's policy and no other). OUT_DIR must not exist; it is created, gets
# the signed UKI, and sbverify with CERT and uki-check.py (exactly 1 signature) must accept it.
# Any failure stops the script.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
die() { echo "sign-uki.sh: $*" >&2; exit 1; }
usage="usage: sign-uki.sh IN_DIR OUT_DIR --key KEY --cert CERT [--engine ENGINE]"

[ "$#" -ge 6 ] || die "$usage"
in_dir="$1" out_dir="$2"
shift 2
key="" cert="" engine=""
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || die "$usage"
  case "$1" in
    --key) [ -z "$key" ] || die "--key given twice"; key="$2" ;;
    --cert) [ -z "$cert" ] || die "--cert given twice"; cert="$2" ;;
    --engine) [ -z "$engine" ] || die "--engine given twice"; engine="$2" ;;
    *) die "unknown option $1; $usage" ;;
  esac
  shift 2
done
[ -n "$key" ] && [ -n "$cert" ] || die "$usage"
[ -n "${PCR_PUBKEY:-}" ] || die "PCR_PUBKEY (the PCR policy public key) is not set"
[ -d "$in_dir" ] || die "$in_dir is not a directory"
[ ! -e "$out_dir" ] && [ ! -L "$out_dir" ] || die "$out_dir exists"

shopt -s nullglob dotglob
files=("$in_dir"/*)
if [ "${#files[@]}" != 1 ] || [[ "${files[0]}" != *.efi ]] || [ -L "${files[0]}" ] || [ ! -f "${files[0]}" ]; then
  die "expected exactly one regular UKI file (*.efi, no symlink) in $in_dir, found: ${files[*]:-nothing}"
fi
name="${files[0]##*/}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp -- "${files[0]}" "$work/$name"
uki="$work/$name"

python3 -I "$root/tools/signing/uki-check.py" "$uki" "$root/ci/uki-cmdline.txt" 0
python3 -I "$root/tools/signing/pcr-policy.py" check "$uki" "$PCR_PUBKEY"

mkdir "$out_dir"
sign=(sbsign)
[ -z "$engine" ] || sign+=(--engine "$engine")
"${sign[@]}" --key "$key" --cert "$cert" --output "$out_dir/$name" "$uki"
sbverify --cert "$cert" "$out_dir/$name"
python3 -I "$root/tools/signing/uki-check.py" "$out_dir/$name" "$root/ci/uki-cmdline.txt" 1
