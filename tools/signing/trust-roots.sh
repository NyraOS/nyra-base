#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Writes the Sigstore trust roots that the image's signature policy uses (Fulcio CA chain,
# Rekor v1 public key) from a pinned trusted_root.json of sigstore/root-signing, checked
# against its SHA-256. CI runs it and fails if the committed files differ (docs/SIGNING.md).
#   tools/signing/trust-roots.sh [OUTPUT_DIR]
set -euo pipefail

commit=c9bda74ad2221f938f7d2e0295ca3aad2da710a8
sha256=6494e21ea73fa7ee769f85f57d5a3e6a08725eae1e38c755fc3517c9e6bc0b66
out="${1:-files/usr/lib/nyra/sigstore}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
root="$tmp/trusted_root.json"
curl -fsSL --retry 3 -o "$root" \
  "https://raw.githubusercontent.com/sigstore/root-signing/$commit/targets/trusted_root.json"
echo "$sha256  $root" | sha256sum -c - >/dev/null

pem() { echo "-----BEGIN $1-----"; fold -w 64; echo "-----END $1-----"; }

mkdir -p "$out"
# The current public Fulcio CA (no end date): intermediate, then root.
jq -r '[.certificateAuthorities[] | select(.uri == "https://fulcio.sigstore.dev" and .validFor.end == null)]
       | if length == 1 then .[0].certChain.certificates[].rawBytes else error("expected one current Fulcio CA") end' "$root" |
  while read -r der; do pem CERTIFICATE <<<"$der"; done > "$out/fulcio-ca.pem"
# The Rekor v1 log: containers/image verifies its signed entry timestamps (SET); Rekor v2 has none.
jq -r '[.tlogs[] | select(.baseUrl == "https://rekor.sigstore.dev")]
       | if length == 1 then .[0].publicKey.rawBytes else error("expected one Rekor v1 log") end' "$root" |
  pem "PUBLIC KEY" > "$out/rekor.pub"
