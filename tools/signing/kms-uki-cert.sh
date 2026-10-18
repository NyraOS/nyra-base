#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Makes the Nyra UKI certificate: self-signed, signed by the Cloud KMS key itself, so the private
# key never leaves KMS. Run once by the owner in Cloud Shell (docs/SIGNING.md, "Making the UKI
# certificate"); it prints the certificate as PEM on stdout and nothing else. Needs
# `libengine-pkcs11-openssl` (OpenSSL's PKCS#11 engine; Cloud Shell has OpenSSL 3, and this package
# is the one Google's guide uses) and an account allowed to use and view the key.
#   tools/signing/kms-uki-cert.sh > nyra.crt
set -euo pipefail

key_ring=projects/nyra-signing-3076/locations/europe-west3/keyRings/nyra
key=uki
version=1
subject="/CN=Nyra OS Secure Boot 2026/O=Wagg Software"
days=5479 # 15 years, 4 leap days

die() { echo "kms-uki-cert: $*" >&2; exit 1; }

openssl engine pkcs11 >/dev/null 2>&1 ||
  die "OpenSSL has no pkcs11 engine; run: sudo apt-get install -y libengine-pkcs11-openssl"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Downloads and checks Google's pinned PKCS#11 library and exports its config and module path.
. "$(dirname "$0")/kms-pkcs11.sh" "$tmp" "$key_ring"

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
