#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The UKI release gate (docs/SIGNING.md): the sign job runs it before it signs an image, with the
# image's /boot copied to BOOT_DIR and the Nyra UKI certificate committed in this repository.
# It refuses unless:
#   - /boot holds exactly one file, EFI/Linux/<name>.efi, and nothing else (no second UKI, no add-on,
#     no <uki>.efi.extra.d directory): bootc installs every PE file it finds there;
#   - that file is the sealed UKI (tools/signing/uki-check.py: read as systemd-stub reads it, a kernel,
#     one command line per profile, exactly the committed ones of ci/uki-cmdline.txt, and at most one
#     Authenticode signature);
#   - it carries the PCR 11 policy for TPM2 unlock signed for its main profile only, with PCR_KEY as
#     the policy key (tools/signing/pcr-policy.py check, which compares the keys as DER), and its
#     .pcrpkey section is PCR_KEY's file byte for byte (a disk knows a key by the SHA-256 of that file);
#   - it is signed with CERT, so with exactly one signature, CERT's;
#   - the image carries NEXT_KEY, the next policy key, as IMAGE_NEXT_KEY (its
#     /usr/lib/nyra/secureboot/tpm2-pcr-public-key-next.pem), and NEXT_KEY is not PCR_KEY: disks are
#     enrolled for the next key before a release signs with it (docs/SIGNING.md, "The PCR policy key"),
#     not even in another encoding of the same key;
#   - the image carries RETIRED, the committed list of retired policy keys, as IMAGE_RETIRED (its
#     /usr/lib/nyra/secureboot/tpm2-pcr-retired-keys), every line of which is a comment or a key's
#     SHA-256, and it lists neither PCR_KEY nor NEXT_KEY.
#   The certificate and both policy keys are committed; until a release UKI is signed with the Nyra
#   key and its PCR policy with pcr-policy-1, every image is refused.
#   tools/signing/uki-gate.sh BOOT_DIR CERT PCR_KEY NEXT_KEY IMAGE_NEXT_KEY RETIRED IMAGE_RETIRED
set -euo pipefail

boot="$1" cert="$2" pcr_key="$3" next_key="$4" image_next="$5" retired="$6" image_retired="$7"
here="$(dirname "$0")"
refuse() { echo "uki-gate: refused: $*" >&2; exit 1; }

[ -f "$cert" ] || refuse "no Nyra UKI certificate at $cert; commit it first (docs/SIGNING.md)"
[ -f "$pcr_key" ] || refuse "no Nyra PCR policy public key at $pcr_key; commit it first (docs/SIGNING.md)"
[ -f "$next_key" ] || refuse "no next Nyra PCR policy public key at $next_key; commit it first (docs/SIGNING.md)"
[ -f "$image_next" ] || refuse "the image carries no next PCR policy key"
cmp -s "$next_key" "$image_next" || refuse "the image's next PCR policy key is not $next_key"
der() { openssl pkey -pubin -in "$1" -outform DER 2>/dev/null | sha256sum | cut -c1-64; }
[ "$(der "$next_key")" != "$(der "$pcr_key")" ] || refuse "the next PCR policy key is the current one"
[ -f "$retired" ] || refuse "no list of retired PCR policy keys at $retired"
[ -f "$image_retired" ] || refuse "the image carries no list of retired PCR policy keys"
cmp -s "$retired" "$image_retired" || refuse "the image's list of retired PCR policy keys is not $retired"
! grep -Evq '^(#.*|[0-9a-f]{64})$' "$retired" || refuse "$retired has a line that is neither a comment nor a key's SHA-256"
for k in "$pcr_key" "$next_key"; do
  ! grep -qx "$(sha256sum < "$k" | cut -c1-64)" "$retired" || refuse "$k is listed as retired in $retired"
done
mapfile -t entries < <(find "$boot" -mindepth 1 -printf '%y %P\n' | LC_ALL=C sort)
if [ "${#entries[@]}" != 3 ] || [ "${entries[0]}" != "d EFI" ] || [ "${entries[1]}" != "d EFI/Linux" ] ||
   ! [[ "${entries[2]}" =~ ^f\ EFI/Linux/[^/]+\.efi$ ]]; then
  refuse "/boot must hold exactly one UKI, in EFI/Linux, and nothing else; it holds: ${entries[*]}"
fi
uki="$boot/${entries[2]#f }"
python3 -I "$here/uki-check.py" "$uki" "$here/../../ci/uki-cmdline.txt" || refuse "${uki#"$boot"/} is not the sealed UKI"
python3 -I "$here/pcr-policy.py" check "$uki" "$pcr_key" || refuse "${uki#"$boot"/} does not carry the main profile's PCR policy signed with $pcr_key"
python3 -I - "$uki" "$pcr_key" <<'PY' || refuse "the .pcrpkey of ${uki#"$boot"/} is not $pcr_key byte for byte"
import sys
import pefile
pe = pefile.PE(sys.argv[1], fast_load=True)
keys = [s.get_data()[:s.Misc_VirtualSize] for s in pe.sections if s.Name.rstrip(b"\0") == b".pcrpkey"]
sys.exit(0 if len(keys) == 1 and keys[0] == open(sys.argv[2], "rb").read() else 1)
PY
sbverify --cert "$cert" "$uki" || refuse "${uki#"$boot"/} is not signed with $cert"
echo "uki-gate: accepted: ${uki#"$boot"/}, the sealed UKI, signed with $cert, PCR policy key $pcr_key, next $next_key"
