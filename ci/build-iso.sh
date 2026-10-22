#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Writes the installer ISO (docs/ISO.md) from the pieces the earlier steps made. Run as root, from the
# checkout of COMMIT (the release commit). Nothing here is signed, and nothing on the ISO is secret.
#   ci/build-iso.sh WORKDIR ISO VERSION COMMIT release|test IMAGE
# WORKDIR holds the installer system (ci/build-iso-os.sh: os/nyra-installer-os) and the registry store
# (ci/iso-registry.sh: registry, registry-digest and, for test, registry-test.pub). IMAGE is the release
# image in podman's storage, only to list the names of its accounts (tools/install/reserved-names.sh).
#
# What the ISO holds, and where:
#   ESP image (a FAT file system, also the second partition of a USB stick written with the ISO):
#     EFI/BOOT/BOOTX64.EFI  shim, signed by Microsoft
#     EFI/BOOT/grubx64.efi  GRUB, signed by Debian (the CD build of it, which looks for /boot/grub/grub.cfg)
#     EFI/BOOT/mmx64.efi    MokManager
#     nyra.cer              the Nyra certificate (DER) for MokManager's "Enroll key from disk"
#     boot/grub/grub.cfg    for a stick: finds the ISO file system and reads the menu there (iso/grub-esp.cfg)
#   ISO 9660 file system, volume NYRA-ISO:
#     boot/vmlinuz, boot/initrd.img  Debian's signed kernel, and the installer system as its RAM disk
#     boot/grub/grub.cfg             not covered by Secure Boot (docs/ISO.md)
#     release/                       the release tree (RELEASE, the scripts, the policy, the trust roots)
#     registry/                      the registry store: the signed image
# release: the policy of the tree is the shipped one. test: it trusts the key of this run for
# updates.nyraos.com instead (a pull request has no release signature), with the shipped signer kept under
# a scope of no image so that `check` still names it; the test policy is only in test ISOs.
# SOURCE_DATE_EPOCH must be set.
set -euo pipefail

[ $# = 6 ] || { echo "usage: build-iso.sh WORKDIR ISO VERSION COMMIT release|test IMAGE" >&2; exit 1; }
work="$(realpath -m "$1")" iso="$(realpath -m "$2")" version="$3" commit="$4" mode="$5" image="$6"
[ "$(id -u)" = 0 ] || { echo "build-iso.sh: run as root" >&2; exit 1; }
: "${SOURCE_DATE_EPOCH:?SOURCE_DATE_EPOCH must be set}"
[[ "$version" =~ ^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]] || { echo "build-iso.sh: not a version: $version" >&2; exit 1; }
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "build-iso.sh: not a commit: $commit" >&2; exit 1; }
[ "$mode" = release ] || [ "$mode" = test ] || { echo "build-iso.sh: mode is release or test" >&2; exit 1; }
# --git-dir: git refuses to read a checkout owned by another user (the runner's, under sudo), unless told which one.
[ "$(git --git-dir=.git rev-parse HEAD)" = "$commit" ] || { echo "build-iso.sh: the checkout is not at $commit" >&2; exit 1; }
os="$work/os/nyra-installer-os"
digest="$(cat "$work/registry-digest")"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "build-iso.sh: no image digest in $work/registry-digest" >&2; exit 1; }
[ -d "$work/registry/docker/registry/v2" ] || { echo "build-iso.sh: no registry store in $work" >&2; exit 1; }
[ -d "$os" ] || { echo "build-iso.sh: no installer system at $os" >&2; exit 1; }

stage="$work/stage"
rm -rf "$stage"
mkdir -p "$stage/iso/boot/grub" "$stage/esp"

# --- the release tree --------------------------------------------------------------------------------
# Only what tools/install reads (docs/INSTALL.md, "From a release tree"); the tests and the rest of the
# repository stay out. Owned by root, as the cpio and the ISO make everything.
tree="$stage/iso/release"
install -d -m 0755 "$tree" "$tree/tools/install" "$tree/docs" "$tree/files/usr/lib/nyra/containers/registries.d" \
  "$tree/files/usr/lib/nyra/sigstore" "$tree/files/usr/lib/nyra/secureboot"
for f in nyra-install.sh in-image.sh verified-pull.sh check-recorded.sh; do install -m 0755 "tools/install/$f" "$tree/tools/install/$f"; done
for f in lib.sh machine.sh release-tree.sh; do install -m 0644 "tools/install/$f" "$tree/tools/install/$f"; done
install -m 0644 docs/SIGNING.md "$tree/docs/SIGNING.md"
install -m 0644 files/usr/lib/nyra/containers/registries.d/nyra.yaml "$tree/files/usr/lib/nyra/containers/registries.d/nyra.yaml"
install -m 0644 files/usr/lib/nyra/sigstore/fulcio-ca.pem files/usr/lib/nyra/sigstore/rekor.pub "$tree/files/usr/lib/nyra/sigstore/"
install -m 0644 files/usr/lib/nyra/secureboot/nyra.crt "$tree/files/usr/lib/nyra/secureboot/nyra.crt"
if [ "$mode" = release ]; then
  install -m 0644 files/usr/lib/nyra/containers/policy.json "$tree/files/usr/lib/nyra/containers/policy.json"
else
  [ -f "$work/registry-test.pub" ] || { echo "build-iso.sh: no test key in $work" >&2; exit 1; }
  install -m 0644 "$work/registry-test.pub" "$tree/files/usr/lib/nyra/containers/test-sigstore.pub"
  jq '(.transports.docker["updates.nyraos.com"][0]) as $real
      | .transports.docker["updates.nyraos.com"] = [{type: "sigstoreSigned", keyPath: "/usr/lib/nyra/containers/test-sigstore.pub",
                                                     signedIdentity: {type: "matchRepository"}}]
      | .transports.docker["signer-of-the-release.invalid"] = [$real]' \
    files/usr/lib/nyra/containers/policy.json > "$tree/files/usr/lib/nyra/containers/policy.json"
  chmod 0644 "$tree/files/usr/lib/nyra/containers/policy.json"
fi
printf 'version=%s\ndigest=%s\ncommit=%s\narchitecture=amd64\n' "$version" "$digest" "$commit" > "$tree/RELEASE"
chmod 0644 "$tree/RELEASE"
tools/install/reserved-names.sh "$image" "$tree"

# --- the registry store, the kernel -------------------------------------------------------------------
cp -a "$work/registry" "$stage/iso/registry"
kernels=("$os"/boot/vmlinuz-*)
[ "${#kernels[@]}" = 1 ] || { echo "build-iso.sh: expected one kernel in $os/boot" >&2; exit 1; }
install -m 0644 "${kernels[0]}" "$stage/iso/boot/vmlinuz"
install -m 0644 iso/grub.cfg "$stage/iso/boot/grub/grub.cfg"

# --- the installer system as the RAM disk -------------------------------------------------------------
# The whole tree but the boot files, which are on the ISO already, the kernel's initial RAM disk of the
# package (the installer system is the initial RAM disk), and the files of the boot chain.
ln -sfn usr/lib/systemd/systemd "$os/init"
(
  cd "$os"
  find . \( -path ./boot -o -path ./usr/lib/shim -o -path ./usr/lib/grub -o -path ./initrd.img -o -path ./initrd.img.old \
            -o -path ./vmlinuz -o -path ./vmlinuz.old -o -path './var/cache/*' -o -path './var/lib/apt/*' \) -prune -o -print0 \
    | LC_ALL=C sort -z \
    | cpio --null --create --format newc --quiet --reproducible --owner 0:0
) | zstd -T0 -19 --quiet -o "$stage/iso/boot/initrd.img"

# --- the boot files, and the ESP image ----------------------------------------------------------------
shim="$os/usr/lib/shim/shimx64.efi.signed"
mm="$os/usr/lib/shim/mmx64.efi.signed"
grub="$os/usr/lib/grub/x86_64-efi-signed/gcdx64.efi.signed"
for f in "$shim" "$mm" "$grub"; do [ -f "$f" ] || { echo "build-iso.sh: no $f" >&2; exit 1; }; done
openssl x509 -in files/usr/lib/nyra/secureboot/nyra.crt -outform DER -out "$stage/nyra.cer"
esp="$stage/esp.img"
truncate -s 16M "$esp"
mkfs.vfat -n NYRA-ESP -F 12 --invariant "$esp" > /dev/null
mmd -i "$esp" ::EFI ::EFI/BOOT ::boot ::boot/grub
mcopy -i "$esp" "$shim" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "$esp" "$grub" ::EFI/BOOT/grubx64.efi
mcopy -i "$esp" "$mm" ::EFI/BOOT/mmx64.efi
mcopy -i "$esp" "$stage/nyra.cer" ::nyra.cer
mcopy -i "$esp" iso/grub-esp.cfg ::boot/grub/grub.cfg

# --- the ISO --------------------------------------------------------------------------------------------
# Hybrid: the ESP image is the El Torito boot image of a CD and, as the second partition of a GPT, what
# the firmware boots from a USB stick. The volume label starts with NYRA-ISO: the installer does not offer
# the disk or partition it started from (docs/INSTALL-INTERFACE.md, "disks").
mkdir -p "$(dirname "$iso")"
rm -f "$iso"
xorriso -as mkisofs -quiet -o "$iso" -r -iso-level 3 -V NYRA-ISO \
  -append_partition 2 0xef "$esp" -appended_part_as_gpt \
  -e --interval:appended_partition_2:all:: -no-emul-boot -isohybrid-gpt-basdat \
  "$stage/iso"
rm -rf "$stage"
ls -l "$iso"
