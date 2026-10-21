#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Pull requests only (image.yml's build, arm64.yml's build): what a release builds before its UKI is
# signed outside the job (ci/build-image.sh, NYRA_RELEASE=1). The image with the unsigned UKI must
# pass the Containerfile's `bootc container lint`, and the UKI must carry the committed policy key and
# no signature at all; nothing a release signs or certifies is made (no signing directories, no
# certificate, no private key). A release run does this for real. The crates and the next key of the
# build in WORK/uki are reused (no download).
#   VERSION=... SOURCE_DATE_EPOCH=... ci/release-smoke.sh ROOTFS_IMAGE WORK
set -euo pipefail

rootfs="$1" work="$2"
mkdir "$work/uki-release"
sudo cp -a "$work/uki/crates" "$work/uki/pcr-next" "$work/uki-release/"
NYRA_RELEASE=1 ci/build-image.sh "$rootfs" localhost/nyra-base:release-smoke "$work/uki-release" \
  --annotation org.opencontainers.image.version="$VERSION" \
  --label org.opencontainers.image.version="$VERSION" >/dev/null
files=("$work"/uki-release/unsigned/*)
[ "${#files[@]}" = 1 ] && [ -f "${files[0]}" ] || { echo "::error::$work/uki-release/unsigned must hold exactly the unsigned UKI"; exit 1; }
python3 -I tools/signing/uki-check.py "${files[0]}" ci/uki-cmdline.txt 0
python3 -I - "${files[0]}" files/usr/lib/nyra/secureboot/tpm2-pcr-public-key.pem <<'PY'
import json, sys
import pefile
sections = [(s.Name.rstrip(b"\0"), s.get_data().rstrip(b"\0")) for s in pefile.PE(sys.argv[1]).sections]
committed = open(sys.argv[2], "rb").read().strip()
keys = [data.strip() for name, data in sections if name == b".pcrpkey"]
assert keys and all(key == committed for key in keys), "the UKI's .pcrpkey is not the committed key"
for name, data in sections:
    if name == b".pcrsig":
        assert not any("sig" in policy for bank in json.loads(data).values() for policy in bank), \
            "the unsigned UKI carries a PCR policy signature"
print("release mode: the UKI has the committed policy key and no signature")
PY
for path in signed policy uki.crt; do
  [ ! -e "$work/uki-release/$path" ] || { echo "::error::$work/uki-release/$path must not exist in release mode"; exit 1; }
done
keys="$(grep -rlI --exclude-dir=crates 'PRIVATE KEY' "$work/uki-release")" || [ $? = 1 ]
[ -z "$keys" ] || { echo "::error::private key in release mode output: $keys"; exit 1; }
