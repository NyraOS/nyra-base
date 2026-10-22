#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: the verified pull (tools/install/verified-pull.sh) and the install from the image it
# pulled (docs/UPDATES.md, "Moving a machine"), against a throwaway registry that answers as
# updates.nyraos.com (tools/signing/local-registry.sh). No secret is used: the test images are signed
# with a key made for this run, so the checkout the script runs from is a copy whose policy trusts
# that key instead of the release signer (the script is the same file).
#   - signed image: accepted, the image ID printed;
#   - a repository outside the two-value allow-list, and the amd64 image published as nyra-base-arm64
#     (validly signed there): refused, by the name and by the image's architecture;
#   - a tag re-pointed to an older, validly signed image: refused, by the digest and, given that
#     image's digest, by the version label; an image with another revision label: refused;
#   - an unsigned image: refused; nothing is left in the storage after a refusal;
#   - a name that was never pulled: podman run --pull=never fails;
#   - the same pull from a release tree (the files of the release, a RELEASE instead of the .git, git
#     not available): the same image; a RELEASE of another digest or commit, or of the other
#     architecture, is refused (tools/install/test-release-tree.sh: the rest of the RELEASE's rules);
#   - bootc install to-disk from the image ID (--pull=never, no network, --target-imgref), the
#     reference and digest bootc recorded read back from the disk (tools/install/check-recorded.sh);
#   - boot: bootc status shows exactly that reference and digest; bootc switch to a second signed
#     version works, and that boot shows the new ones.
#   tools/install/test-verified-pull.sh IMAGE WORKDIR LOGDIR SUMMARY
set -euo pipefail

image="$1" t="$2/verified-pull" logs="$3" summary="$4"
repo=updates.nyraos.com/nyra-base
v1=2026.10.1 v2=2026.10.2 old=2026.9.9
mkdir -p "$t/context"
start=$SECONDS

tools/signing/local-registry.sh "$t"
# The runner's skopeo (the script's) reaches the registry over plain HTTP.
printf '[[registry]]\nlocation = "updates.nyraos.com"\ninsecure = true\n' \
  | sudo tee /etc/containers/registries.conf.d/99-verified-pull-test.conf >/dev/null
sudo mkdir -p /etc/containers/registries.d
printf 'docker:\n  updates.nyraos.com:\n    use-sigstore-attachments: true\n' \
  | sudo tee /etc/containers/registries.d/99-verified-pull-test.yaml >/dev/null

echo nyra-verified-pull-test > "$t/pass"
sudo podman run --rm --tmpfs /var/tmp -v "$t:/t:z" "$image" \
  skopeo generate-sigstore-key --output-prefix /t/sigstore --passphrase-file /t/pass >/dev/null
sudo chown -R "$(id -u):$(id -g)" "$t"

# The script from a copy of this checkout (root's, as on an installer), trusting the test key.
revision="$(git rev-parse HEAD)"
sudo cp -R "$PWD/." "$t/checkout"
sudo cp "$t/sigstore.pub" "$t/checkout/files/usr/lib/nyra/containers/test-sigstore.pub"
policy="$t/checkout/files/usr/lib/nyra/containers/policy.json"
sudo jq '.transports.docker["updates.nyraos.com"] = [{
    type: "sigstoreSigned", keyPath: "/usr/lib/nyra/containers/test-sigstore.pub",
    signedIdentity: {type: "matchRepository"}}]' "$policy" | sudo tee "$policy.new" >/dev/null
sudo mv "$policy.new" "$policy"
pull="$t/checkout/tools/install/verified-pull.sh"
cmp tools/install/verified-pull.sh "$pull"

# --- the images ----------------------------------------------------------------------------------
# Versions 1 and the older one differ from IMAGE in their labels only, so IMAGE's UKI stays valid.
relabel() { # relabel NAME VERSION REVISION
  printf 'FROM %s\n' "$image" | sudo podman build -q --format oci \
    --annotation "org.opencontainers.image.version=$2" --label "org.opencontainers.image.version=$2" \
    --label "org.opencontainers.image.revision=$3" -t "localhost/nyra-test:$1" -f - "$t/context" >/dev/null
}
# Version 2 changes /usr, so it needs its own UKI (tools/vm/boot-counting.sh): the kernel and
# initramfs taken out of IMAGE's UKI, unsigned (these boots run without Secure Boot).
cat > "$t/kernel-from-uki.py" <<'EOF'
import sys
import pefile
pe = pefile.PE(sys.argv[1])
for s in pe.sections:
    name = {b".linux": "vmlinuz", b".initrd": "initramfs.img"}.get(s.Name.rstrip(b"\0"))
    if name:
        with open(f"{sys.argv[2]}/{name}", "wb") as f:
            f.write(s.get_data()[:s.Misc_VirtualSize])
EOF
newer() { # newer NAME VERSION
  printf 'FROM %s\nRUN rm -rf /boot/EFI && echo %s > /usr/lib/nyra-test-version\n' "$image" "$2" \
    | sudo podman build -q -t "localhost/nyra-test:$1-rootfs" -f - "$t/context" >/dev/null
  mkdir -p "$t/$1-uki"
  sudo podman run --rm --network none --tmpfs /tmp --tmpfs /var/tmp \
    --mount "type=image,source=localhost/nyra-test:$1-rootfs,target=/target" \
    -v "$t/kernel-from-uki.py:/kernel-from-uki.py:ro" -v "$t/$1-uki:/out" "$image" \
    sh -c 'u="$(ls /boot/EFI/Linux/*.efi)" && k="$(basename "$u" .efi)" && mkdir -p "/tmp/kernel/$k" &&
      python3 /kernel-from-uki.py "$u" "/tmp/kernel/$k" &&
      bootc container ukify --rootfs /target --kernel-dir "/tmp/kernel/$k" -- --output "/out/$k.efi"' >/dev/null
  printf 'FROM localhost/nyra-test:%s-rootfs\nCOPY --from=uki . /boot/EFI/Linux/\n' "$1" \
    | sudo podman build -q --format oci --annotation "org.opencontainers.image.version=$2" \
      --label "org.opencontainers.image.version=$2" --label "org.opencontainers.image.revision=$revision" \
      -t "localhost/nyra-test:$1" --build-context uki="$t/$1-uki" -f - "$t/context" >/dev/null
}
relabel one "$v1" "$revision"
relabel old "$old" "$revision"
relabel other-revision 2026.10.5 0000000000000000000000000000000000000000
relabel unsigned 2026.10.3 "$revision"
newer two "$v2"

push() { # push NAME TAG [signed]: prints nothing, the digest is in WORKDIR/NAME.digest
  sudo podman push -q --tls-verify=false --format oci --digestfile "$t/$1.digest" \
    ${3:+--sign-by-sigstore-private-key "$t/sigstore.private" --sign-passphrase-file "$t/pass"} \
    "localhost/nyra-test:$1" "docker://$repo:$2"
  [[ "$(sudo cat "$t/$1.digest")" =~ ^sha256:[0-9a-f]{64}$ ]]
}
digest() { sudo cat "$t/$1.digest"; }
push one "$v1" signed
push old "$old" signed
push other-revision 2026.10.5 signed
push unsigned 2026.10.3
push two "$v2" signed
# The same (amd64) image under the arm64 repository, with a valid signature for that name: only its
# architecture is wrong.
sudo podman push -q --tls-verify=false --format oci --sign-by-sigstore-private-key "$t/sigstore.private" \
  --sign-passphrase-file "$t/pass" localhost/nyra-test:one "docker://updates.nyraos.com/nyra-base-arm64:$v1"

# --- refusals, each into an empty storage ---------------------------------------------------------
n=0
refused_in() { # refused_in REPOSITORY VERSION DIGEST MESSAGE
  local s out
  n=$((n + 1))
  s="$t/storage-$n"
  if out="$(sudo "$pull" "$1" "$2" "$3" "$s" 2>&1)"; then
    echo "::error::accepted, but must be refused: $1 $2 $3"
    return 1
  fi
  if ! grep -qF -- "$4" <<<"$out"; then
    printf '%s\n' "$out"
    echo "::error::refused for another reason than \"$4\": $1 $2 $3"
    return 1
  fi
  [ -z "$(sudo podman --root "$s" images -q)" ] || { echo "::error::an image is left after the refusal"; return 1; }
  echo "refused as expected ($4): $1 $2 $3"
}
refused() { refused_in nyra-base "$@"; } # refused VERSION DIGEST MESSAGE
refused "$v1" "not-a-digest" "not a sha256 digest"
refused "$v1" "" "not a sha256 digest"
refused 2026.10.3 "$(digest unsigned)" "A signature was required, but no signature exists"
# The "never pulled" check: that refusal left storage-3 empty, and a run there pulls nothing.
if sudo podman --root "$t/storage-3" run --pull=never --network none "$repo:2026.10.3" true 2>"$t/never.err"; then
  echo "::error::a name that was never pulled ran"
  exit 1
fi
cat "$t/never.err"
for other in nyra-base-x86 nyra-base-arm64/x elsewhere "" "../nyra-base"; do
  refused_in "$other" "$v1" "$(digest one)" "not a Nyra image repository"
done
refused_in nyra-base-arm64 "$v1" "$(digest one)" "is not linux/arm64, the platform of nyra-base-arm64"
refused 2026.10.5 "$(digest other-revision)" "revision label is not $revision"
# The tag of version 1 re-pointed to the older image, whose signature is valid.
push old "$v1" signed
refused "$v1" "$(digest one)" "is $(digest old), not $(digest one)"
refused "$v1" "$(digest old)" "version label is not $v1"
push one "$v1" signed

# --- the pull, then the install from the image ID --------------------------------------------------
storage=/var/lib/containers/storage
id="$(sudo "$pull" nyra-base "$v1" "$(digest one)" "$storage")"
[[ "$id" =~ ^[0-9a-f]{64}$ ]]
sudo podman --root "$storage" image inspect --format '{{json .RepoDigests}}' "$id" \
  | jq -e --arg ref "$repo@$(digest one)" 'index($ref) != null' > /dev/null
echo "pulled: $id"

# --- the same pull from a release tree: the files of the release, no .git, a RELEASE ------------------
# A git that fails stands in for a machine without one: the tree must not need it.
rt="$t/release-tree"
sudo cp -R "$t/checkout" "$rt"
sudo rm -rf "$rt/.git"
mkdir "$t/nogit"
printf '#!/bin/sh\necho "git was run: $*" >&2\nexit 1\n' > "$t/nogit/git"
chmod +x "$t/nogit/git"
release_file() { # release_file VERSION DIGEST COMMIT ARCHITECTURE
  printf 'version=%s\ndigest=%s\ncommit=%s\narchitecture=%s\n' "$1" "$2" "$3" "$4" | sudo tee "$rt/RELEASE" >/dev/null
}
release_file "$v1" "$(digest one)" "$revision" amd64
rid="$(sudo env PATH="$t/nogit:$PATH" "$rt/tools/install/verified-pull.sh" nyra-base "$v1" "$(digest one)" "$storage")"
[ "$rid" = "$id" ] || { echo "::error::the release tree pulled $rid, the checkout $id"; exit 1; }
echo "pulled from a release tree without git: $rid"
git_pull="$pull"
pull="$rt/tools/install/verified-pull.sh"
# A RELEASE of another digest, of another commit (the image's revision label is this checkout's), and of
# the other architecture, for the repository of each.
release_file "$v1" "$(digest old)" "$revision" amd64
refused_in nyra-base "$v1" "$(digest one)" "RELEASE does not name the digest $(digest one)"
release_file "$v1" "$(digest one)" 0000000000000000000000000000000000000000 amd64
refused_in nyra-base "$v1" "$(digest one)" "revision label is not 0000000000000000000000000000000000000000"
release_file "$v1" "$(digest one)" "$revision" arm64
refused_in nyra-base "$v1" "$(digest one)" "RELEASE is not for amd64, the architecture of nyra-base"
refused_in nyra-base-arm64 "$v1" "$(digest one)" "is not linux/arm64, the platform of nyra-base-arm64"
release_file "$v1" "$(digest one)" "$revision" amd64
refused_in nyra-base-arm64 "$v1" "$(digest one)" "RELEASE is not for arm64, the architecture of nyra-base-arm64"
pull="$git_pull"

tools/vm/install-disk.sh "$id" "$t" "$repo:$v1"
loop="" mnt="$t/root"
trap 'sudo umount -q "$mnt" 2>/dev/null || true; [ -z "$loop" ] || sudo losetup -d "$loop" || true' EXIT
loop="$(sudo losetup -P --show -f "$t/disk.raw")"
tools/vm/esp-of.sh "$loop" >/dev/null
for p in "$loop"p*; do [ "$(sudo blkid -o value -s TYPE "$p" || true)" = ext4 ] && root="$p"; done
mkdir -p "$mnt" && sudo mount -o ro "$root" "$mnt"
sudo tools/install/check-recorded.sh "$mnt" "$repo:$v1" "$(digest one)"
sudo umount "$mnt" && sudo losetup -d "$loop" && loop=""
tools/vm/test-console.sh "$image" "$t/disk.raw" "$t"
qemu-img convert -O qcow2 "$t/disk.raw" "$t/disk.qcow2"
rm "$t/disk.raw"
{
  echo "## Verified pull and install (docs/UPDATES.md)"
  echo
  echo "Refusals, the pull of \`$repo:$v1\` and the install from the image ID \`${id:0:12}\`: $((SECONDS - start)) s before the first boot."
  echo
} >> "$summary"

# --- boots -----------------------------------------------------------------------------------------
cat > "$t/guest-policy.json" <<'EOF'
{
  "default": [{ "type": "insecureAcceptAnything" }],
  "transports": {
    "docker": {
      "updates.nyraos.com": [
        {
          "type": "sigstoreSigned",
          "keyPath": "/etc/nyra-test/sigstore.pub",
          "signedIdentity": { "type": "matchRepository" }
        }
      ]
    }
  }
}
EOF
printf '[[registry]]\nlocation = "updates.nyraos.com"\ninsecure = true\n' > "$t/99-nyra-test.conf"
put() { # guest commands that write the local file $1 to $2, in pieces the console takes
  local b64 i
  b64="$(base64 -w0 < "$1")"
  echo "--command"
  echo "mkdir -p \"\$(dirname $2)\" && : > $2.b64"
  for ((i = 0; i < ${#b64}; i += 1500)); do
    echo "--command"
    echo "printf %s ${b64:i:1500} >> $2.b64"
  done
  echo "--command"
  echo "base64 -d $2.b64 > $2 && rm $2.b64"
}
mapfile -t trust < <(
  put "$t/guest-policy.json" /etc/nyra-test/policy.json
  put "$t/sigstore.pub" /etc/nyra-test/sigstore.pub
  put "$t/99-nyra-test.conf" /etc/containers/registries.conf.d/99-nyra-test.conf
)
booted() { # guest command: the booted image is reference $1 with the digest $2
  echo 'j="$(bootc status --booted --format json)"; j="${j#*\"booted\":}"; r="$(echo "$j" | grep -o "\"image\":\"[^\"]*\"" | head -1 | cut -d\" -f4)"; d="$(echo "$j" | grep -o "\"imageDigest\":\"[^\"]*\"" | head -1 | cut -d\" -f4)"; echo "booted: $r $d"; test "$r" = '"$1"' && test "$d" = '"$2"
}
n=0
vm() {
  n=$((n + 1))
  python3 -B tools/vm/vm-boot.py --autologin --persist --poweroff --disk "$t/disk.qcow2" --timeout 240 \
    --log "$logs/serial-verified-pull-$n.log" --summary "$summary" --title "Verified pull, boot $n: $1" "${@:2}"
}
vm "the installed image, then bootc switch to version 2" \
  --command "$(booted "$repo:$v1" "$(digest one)")" \
  --command 'bootc status' \
  "${trust[@]}" \
  --command 'ln -sfn /etc/nyra-test/policy.json /etc/containers/policy.json && echo "10.0.2.2 updates.nyraos.com" >> /etc/hosts' \
  --command "bootc switch --quiet $repo:$v2 && ls /boot/loader/entries.staged"
vm "after bootc switch: version 2" \
  --command "$(booted "$repo:$v2" "$(digest two)")" \
  --command "test \"\$(cat /usr/lib/nyra-test-version)\" = $v2"
