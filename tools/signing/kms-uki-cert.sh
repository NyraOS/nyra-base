#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Makes the Nyra UKI certificate: self-signed, signed by the Cloud KMS key itself, so the private
# key never leaves KMS. Run once by the owner in Cloud Shell (docs/SIGNING.md, "Making the UKI
# certificate"); it prints the certificate as PEM on stdout and nothing else. Needs
# `libengine-pkcs11-openssl` (OpenSSL's PKCS#11 engine; Cloud Shell has OpenSSL 3, and this package
# is the one Google's guide uses) and an account allowed to use and view the key.
#   tools/signing/kms-uki-cert.sh > nyra.crt
#
# Google's PKCS#11 library for Cloud KMS, pinned: the exact release asset and its SHA-256, which
# is the digest GitHub shows for the asset of release pkcs11-v1.9.
# Usage guide: https://github.com/GoogleCloudPlatform/kms-integrations/blob/master/kmsp11/docs/user_guide.md
set -euo pipefail

key_ring=projects/nyra-signing-3076/locations/europe-west3/keyRings/nyra
key=uki
version=1
lib_url=https://github.com/GoogleCloudPlatform/kms-integrations/releases/download/pkcs11-v1.9/libkmsp11-1.9-linux-amd64.tar.gz
lib_sha256=5397f965073cd5d1e2c43e5148f102f31a7c835902f97eb41c7c9c0f1b876a40
subject="/CN=Nyra OS Secure Boot 2026/O=Wagg Software"
days=5479 # 15 years, 4 leap days

die() { echo "kms-uki-cert: $*" >&2; exit 1; }

openssl engine pkcs11 >/dev/null 2>&1 ||
  die "OpenSSL has no pkcs11 engine; run: sudo apt-get install -y libengine-pkcs11-openssl"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL --retry 3 -o "$tmp/lib.tar.gz" "$lib_url"
echo "$lib_sha256  $tmp/lib.tar.gz" | sha256sum -c - >&2
tar -xzf "$tmp/lib.tar.gz" -C "$tmp"
lib="$(find "$tmp" -name libkmsp11.so | head -n 1)"
[ -n "$lib" ] || die "libkmsp11.so not in the archive"

# The library wants a config file that only its owner can write. It holds no secret: the library
# authenticates with the account's gcloud credentials (Cloud Shell sets them up).
cat >"$tmp/kmsp11.yaml" <<EOF
---
tokens:
  - key_ring: "$key_ring"
    label: "nyra"
EOF
chmod 600 "$tmp/kmsp11.yaml"
export KMS_PKCS11_CONFIG="$tmp/kmsp11.yaml" PKCS11_MODULE_PATH="$lib"

# The key as KMS publishes it, fetched without the PKCS#11 library: the certificate must match it.
gcloud kms keys versions get-public-key "$version" --key="$key" --keyring="${key_ring##*/}" \
  --location="$(echo "$key_ring" | cut -d/ -f4)" --project="$(echo "$key_ring" | cut -d/ -f2)" \
  --output-file="$tmp/kms-public.pem" >&2

# CA:FALSE because the key signs only boot binaries (shim takes the certificate as a MOK entry, or
# from db, and needs no CA bit). shim does not require codeSigning, but it refuses a MOK certificate
# whose only EKU is module signing, so codeSigning is set; sbsign/sbverify need nothing more.
# digitalSignature is the one key usage Authenticode needs.
cat >"$tmp/openssl.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = x
[ext]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
EOF

# The key is picked by its label (the CryptoKey name): the library's id is the whole version name,
# which the engine cannot take when it is longer than 100 characters. A key ring with a second
# enabled version of "$key" would be ambiguous; the public key check below catches that.
openssl req -new -x509 -config "$tmp/openssl.cnf" -extensions ext -subj "$subject" -days "$days" \
  -sha256 -engine pkcs11 -keyform engine -key "pkcs11:object=$key;type=private" \
  -out "$tmp/nyra.crt" >&2

# DER of both public keys must be byte-identical (the openssl CLI has no key-compare command).
openssl x509 -in "$tmp/nyra.crt" -pubkey -noout | openssl pkey -pubin -outform DER >"$tmp/a.der"
openssl pkey -pubin -in "$tmp/kms-public.pem" -outform DER >"$tmp/b.der"
cmp -s "$tmp/a.der" "$tmp/b.der" || die "the certificate's public key is not the KMS key's"
openssl verify -check_ss_sig -CAfile "$tmp/nyra.crt" -purpose any "$tmp/nyra.crt" >&2 ||
  die "the certificate does not verify against itself"

openssl x509 -in "$tmp/nyra.crt" -noout -subject -issuer -dates -fingerprint -sha256 >&2
cat "$tmp/nyra.crt"
