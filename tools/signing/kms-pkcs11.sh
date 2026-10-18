# SPDX-License-Identifier: GPL-3.0-or-later
# Google's PKCS#11 library for Cloud KMS, pinned in this one place. Sourced, not run:
#   . tools/signing/kms-pkcs11.sh TMPDIR KEY_RING
# Downloads the library into TMPDIR (an existing directory), checks its SHA-256, writes the
# library's config for KEY_RING (projects/P/locations/L/keyRings/R) and exports KMS_PKCS11_CONFIG
# and PKCS11_MODULE_PATH for OpenSSL's pkcs11 engine. Any error ends the sourcing shell with
# status 1 (exit, not return, so a caller without `set -e` cannot go on without the check).
#
# The pin is the exact release asset and its SHA-256, which is the digest GitHub shows for the
# asset of release pkcs11-v1.9.
# Usage guide: https://github.com/GoogleCloudPlatform/kms-integrations/blob/master/kmsp11/docs/user_guide.md

kms_pkcs11_url=https://github.com/GoogleCloudPlatform/kms-integrations/releases/download/pkcs11-v1.9/libkmsp11-1.9-linux-amd64.tar.gz
kms_pkcs11_sha256=5397f965073cd5d1e2c43e5148f102f31a7c835902f97eb41c7c9c0f1b876a40

kms_pkcs11_die() { echo "kms-pkcs11: $*" >&2; exit 1; }

[ "$#" -eq 2 ] || kms_pkcs11_die "usage: . kms-pkcs11.sh TMPDIR KEY_RING"
[ -d "$1" ] || kms_pkcs11_die "$1 is not a directory"
kms_pkcs11_dir="$1"
kms_pkcs11_key_ring="$2"

curl -fsSL --retry 3 -o "$kms_pkcs11_dir/lib.tar.gz" "$kms_pkcs11_url" ||
  kms_pkcs11_die "download failed"
echo "$kms_pkcs11_sha256  $kms_pkcs11_dir/lib.tar.gz" | sha256sum -c - >&2 ||
  kms_pkcs11_die "the library does not match its pinned SHA-256"
tar -xzf "$kms_pkcs11_dir/lib.tar.gz" -C "$kms_pkcs11_dir" ||
  kms_pkcs11_die "cannot unpack the library"
kms_pkcs11_lib="$(find "$kms_pkcs11_dir" -name libkmsp11.so | head -n 1)"
[ -n "$kms_pkcs11_lib" ] || kms_pkcs11_die "libkmsp11.so not in the archive"

# The library wants a config file that only its owner can write. It holds no secret: the library
# authenticates with the account's gcloud credentials (Cloud Shell sets them up).
cat >"$kms_pkcs11_dir/kmsp11.yaml" <<YAML
---
tokens:
  - key_ring: "$kms_pkcs11_key_ring"
    label: "nyra"
YAML
chmod 600 "$kms_pkcs11_dir/kmsp11.yaml"
export KMS_PKCS11_CONFIG="$kms_pkcs11_dir/kmsp11.yaml" PKCS11_MODULE_PATH="$kms_pkcs11_lib"
