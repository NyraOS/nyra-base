#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: checks the signature policy shipped in IMAGE with the image's own skopeo (the same
# containers/image code that bootc uses), against the registry from local-registry.sh.
# The only test-only configuration is "insecure" (plain HTTP) for the two local registry names.
#   tools/signing/test-policy.sh IMAGE WORKDIR [SIGNED_DIGEST]
# Always: unsigned and wrongly signed images under updates.nyraos.com are refused; other
# registries and local transports (oci-archive) are accepted.
# With SIGNED_DIGEST (the image signed in CI, in the registry as updates.nyraos.com/nyra-base):
# it is accepted, and its signature is refused on another image and in another repository.
set -euo pipefail

image="$1" work="$2" signed="${3:-}"
repo=updates.nyraos.com/nyra-base

t="$work/policy-test"
mkdir -p "$t"
cp "$work/tiny.oci.tar" "$t/tiny.oci.tar"
printf '[[registry]]\nlocation = "updates.nyraos.com"\ninsecure = true\n\n[[registry]]\nlocation = "other.test"\ninsecure = true\n' \
  > "$t/99-test.conf"
echo "nyra-policy-test" > "$t/pass"

# The bootc image ships an empty /var (tmpfiles fills it at boot); skopeo needs /var/tmp.
skopeo() {
  sudo podman run --rm --network host --tmpfs /var/tmp -v "$t:/t:z" \
    -v "$t/99-test.conf:/etc/containers/registries.conf.d/99-test.conf:ro,z" "$image" skopeo "$@"
}
accepted() {
  skopeo "$@" >/dev/null
  echo "accepted as expected: skopeo $*"
}
refused() {
  local want="$1" out
  shift
  if out="$(skopeo "$@" 2>&1)"; then
    echo "::error::accepted, but must be refused: skopeo $*"
    return 1
  fi
  if ! grep -qF -- "$want" <<<"$out"; then
    printf '%s\n' "$out"
    echo "::error::refused for another reason than \"$want\": skopeo $*"
    return 1
  fi
  echo "refused as expected ($want): skopeo $*"
}

# The shipped configuration is the one in effect.
sudo podman run --rm "$image" sh -c 'readlink /etc/containers/policy.json /etc/containers/registries.d/nyra.yaml'

# Other registries and local transports keep working (user containers, bootc install).
accepted copy oci-archive:/t/tiny.oci.tar docker://other.test/user/tiny:1
accepted copy docker://other.test/user/tiny:1 dir:/t/pull-other

# Our registry: no signature.
accepted copy oci-archive:/t/tiny.oci.tar "docker://$repo:tiny"
refused "A signature was required, but no signature exists" copy "docker://$repo:tiny" dir:/t/pull

# Our registry: a signature by someone else (a key of their own, attached the way we attach ours).
skopeo generate-sigstore-key --output-prefix /t/attacker --passphrase-file /t/pass >/dev/null
accepted copy --sign-by-sigstore-private-key /t/attacker.private --sign-passphrase-file /t/pass \
  oci-archive:/t/tiny.oci.tar "docker://$repo:tiny"
refused "missing dev.sigstore.cosign/bundle annotation" copy "docker://$repo:tiny" dir:/t/pull
# Same export as the sign job's, on this signature: proves the step works before GCP exists.
tiny="$(skopeo inspect --format '{{.Digest}}' "docker://$repo:tiny")"
skopeo copy --insecure-policy --preserve-digests "docker://$repo:${tiny/:/-}.sig" "oci:/t/signature:${tiny/:/-}.sig" >/dev/null

[ -n "$signed" ] || exit 0

# The image signed in CI is accepted.
accepted copy "docker://$repo@$signed" dir:/t/pull-signed

# Its signature moved to another image (replacing the attacker's) is refused.
sig="${signed/:/-}.sig"
skopeo copy --insecure-policy "docker://$repo:$sig" "docker://$repo:${tiny/:/-}.sig" >/dev/null
refused "does not match" copy "docker://$repo:tiny" dir:/t/pull

# The image and its signature copied to another repository are refused (matchRepository).
skopeo copy --insecure-policy --remove-signatures --preserve-digests \
  "docker://$repo@$signed" docker://updates.nyraos.com/elsewhere:1 >/dev/null
skopeo copy --insecure-policy "docker://$repo:$sig" "docker://updates.nyraos.com/elsewhere:$sig" >/dev/null
refused "is not accepted" copy "docker://updates.nyraos.com/elsewhere@$signed" dir:/t/pull
