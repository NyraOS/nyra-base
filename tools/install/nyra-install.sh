#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The Nyra installer (docs/INSTALL.md): installs the release VERSION, whose manifest digest is
# DIGEST, onto the whole disk DEVICE of the machine it runs on, as root, from a Debian live session.
#   tools/install/nyra-install.sh DEVICE VERSION DIGEST
# VERSION, DIGEST and the commit of the checkout come from the release run on github.com.
#
# What it does, in order:
#   1. refuses unless the checkout is clean and at a detached commit, the machine has one TPM2 and
#      Secure Boot on, and DEVICE is a whole disk nothing uses; the owner types DEVICE to confirm;
#   2. pulls the image with tools/install/verified-pull.sh (the shipped policy, the pinned digest and
#      labels): it prints the image ID, and from there on only that ID is used, never a name;
#   3. partitions the disk and runs everything else in that image's container, without network and
#      without any pull (tools/install/in-image.sh; the same steps CI tests): LUKS2, ext4, bootc
#      install, the record of what bootc recorded read back, the recovery key shown once and typed
#      back, the temporary TPM2 enrollment, the removal of the key of the installation, esp-sync;
#   4. imports the Nyra certificate as a Machine Owner Key (the owner confirms it in MokManager at
#      the next boot).
# After a failure past the point where the disk is changed, the disk must be installed again from the
# start: there is no way to continue.
set -euo pipefail

die() {
  echo "nyra-install: $*" >&2
  exit 1
}

[ $# = 3 ] || die "usage: nyra-install.sh DEVICE VERSION DIGEST"
device="$1" version="$2" digest="$3"
[ "$(id -u)" = 0 ] || die "run as root"
[[ "$version" =~ ^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]] || die "not a version: $version"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "not a sha256 digest: $digest"
[ -z "${CONTAINERS_POLICY_JSON:-}" ] || die "CONTAINERS_POLICY_JSON is set"
[ -z "${NYRA_CI:-}" ] || die "NYRA_CI is set: the recovery key would go to a file"
[ -t 0 ] && [ -t 1 ] || die "run it from a terminal: the recovery key is shown there and typed back"

# The repository is chosen by this machine's architecture, from a two-value allow-list, and is not an
# argument: nobody can point this script at another registry or name. The reference is spelled exactly
# like this (docs/UPDATES.md): the policy compares the name as written.
case "$(uname -m)" in
  x86_64) repo_name=nyra-base ;;
  aarch64) repo_name=nyra-base-arm64 ;;
  *) die "no Nyra image for the architecture $(uname -m)" ;;
esac
repo=updates.nyraos.com/$repo_name
imgref="$repo:$version"
checkout="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
storage=/var/lib/containers/storage
secrets=/run/nyra-install
# shellcheck disable=SC2034 # used by in_image (lib.sh): empty, as this runs as root
as_root=""
image=""
# Assigned, not taken from the environment: the installer's containers have no network and no time limit.
# shellcheck disable=SC2034 # used by in_image (lib.sh)
in_image_network=none
# shellcheck disable=SC2034 # used by in_image (lib.sh)
in_image_timeout=0
. "$checkout/tools/install/lib.sh"

# --- the checkout ----------------------------------------------------------------------------------
# --git-dir (and --work-tree): git refuses to read a checkout owned by another user, unless told.
git_checkout() { git --git-dir="$checkout/.git" --work-tree="$checkout" "$@"; }
if git_checkout symbolic-ref -q HEAD > /dev/null; then
  die "the checkout is on a branch: git checkout --detach <the release commit>"
fi
[ -z "$(git_checkout status --porcelain)" ] || die "the checkout has changes: use a fresh clone"
echo "nyra-install: the checkout is at the commit $(git_checkout rev-parse HEAD)"

# --- the machine -----------------------------------------------------------------------------------
tpms=(/dev/tpmrm*)
[ "${#tpms[@]}" = 1 ] && [ "${tpms[0]}" = /dev/tpmrm0 ] && [ -c /dev/tpmrm0 ] \
  || die "needs exactly one TPM2 (/dev/tpmrm0); a machine without one is not installed by this script"
sb_state="$(mokutil --sb-state 2>&1)" || die "cannot read the Secure Boot state: not booted in UEFI mode?"
grep -qx 'SecureBoot enabled' <<< "$sb_state" && ! grep -qi 'setup mode' <<< "$sb_state" \
  || die "Secure Boot must be on and not in setup mode: $sb_state"
# MokSBState: with it set, shim loads anything, signed or not.
! grep -qi 'validation is disabled' <<< "$sb_state" || die "shim validation is off (MokSBState): $sb_state"

# --- the target ------------------------------------------------------------------------------------
[ -b "$device" ] || die "$device is not a block device"
[ "$(lsblk -dnro TYPE "$device")" = disk ] || die "$device is not a whole disk"
# Mounted: anything of the disk (the live system's own medium included) or its partitions.
[ -z "$(lsblk -nro MOUNTPOINTS "$device" | tr -d '[:space:]')" ] || die "$device or its partitions are in use (mounted or swap)"
lsblk -nro FSTYPE "$device" | grep -qx iso9660 && die "$device holds an ISO image: the live medium?"

# --- cleanup ---------------------------------------------------------------------------------------
# changed: the disk was written to and the installation is not finished.
changed=""
cleanup() {
  local rc=$?
  trap - EXIT
  # The volume is closed in the image's container, if the install was killed while it was open.
  if [ -n "$changed" ] && [ -n "$image" ] && [ -d "$secrets" ]; then
    in_image -- close-root > /dev/null 2>&1 || true
  fi
  rm -rf "$secrets"
  if [ "$rc" != 0 ] && [ -n "$changed" ]; then
    echo "nyra-install: failed after $device was changed. It must be installed again from the start," \
      "with this script: nothing on it is to be used as it is." >&2
  fi
  exit "$rc"
}

# The key of the installation: random, in a directory only root reads, in memory, gone at any exit.
mkdir -m 0700 "$secrets" || die "$secrets exists: another installation is running, or was killed"
trap cleanup EXIT
trap 'exit 130' INT TERM
[ "$(findmnt -no FSTYPE -T "$secrets")" = tmpfs ] || die "$secrets is not in memory"
( umask 077; head -c 32 /dev/urandom | base64 -w0 > "$secrets/install-key" )
key=/secrets/install-key

# --- the image ---------------------------------------------------------------------------------------
# The live root is an overlayfs, which cannot be the upperdir of the overlay driver that the pull
# uses: the storage goes in memory then.
mkdir -p /var/lib/containers
if [ "$(findmnt -no FSTYPE -T /var/lib/containers)" = overlay ]; then
  mount -t tmpfs tmpfs /var/lib/containers || die "cannot mount a tmpfs on /var/lib/containers"
fi
image="$("$checkout/tools/install/verified-pull.sh" "$repo_name" "$version" "$digest" "$storage")"
[[ "$image" =~ ^[0-9a-f]{64}$ ]] || die "verified-pull.sh did not print an image ID"
echo "nyra-install: installing the image $image ($imgref, $digest)"

# --- the disk ----------------------------------------------------------------------------------------
# Asked after the pull, which takes a while, so that the answer is not left waiting.
lsblk -o NAME,SIZE,MODEL,FSTYPE,LABEL "$device"
read -r -p "Everything on $device will be erased. Type its path to go on: " typed
[ "$typed" = "$device" ] || die "not confirmed"
changed=1
partition_disk "$device"
for _ in $(seq 50); do
  udevadm settle --timeout=10 || true
  [ "$(lsblk -nro TYPE "$device" | grep -c '^part$')" = 2 ] && break
  sleep 0.2
done
[ "$(lsblk -nro TYPE "$device" | grep -c '^part$')" = 2 ] || die "no partitions on $device after 10 s"
in_image -- format "$device" "$key"
# The record bootc made of the reference and the digest is read back inside, before the volume is
# closed: a machine that records anything else would update from somewhere else.
in_image -- install-system "$device" "$key" tpm "$imgref" "$digest"

# --- the recovery key --------------------------------------------------------------------------------
# Shown on this terminal only (the container has no log: --log-driver=none), written nowhere. The
# key typed back is checked against the recovery key slot alone. The key of the installation is
# removed only after that. A key that does not match is replaced by a new one, shown the same way:
# keeping the old one to show it again would mean holding it in a file or a variable.
while :; do
  in_image -it --log-driver=none -- recovery-show "$device" "$key"
  echo
  echo "Write the recovery key down now, on paper: it is the only way in if the TPM refuses the disk."
  echo "Then type it below to check it."
  slot="$(in_image -- luks-json "$device" | recovery_slot)" || die "cannot find the recovery key slot"
  [[ "$slot" =~ ^[0-9]+$ ]] || die "not a key slot: $slot"
  if in_image -it --log-driver=none -- recovery-check "$device" "$slot"; then
    break
  fi
  echo "That is not the recovery key. The key above no longer works; a new one follows."
  in_image -- recovery-wipe "$device" "$key"
done

# --- the TPM -------------------------------------------------------------------------------------------
# No PCR, no policy: the first boot of the installed system replaces this enrollment with the real one.
in_image -- tpm-enroll "$device" "$key" /dev/tpmrm0
in_image -- wipe-install-key "$device"
in_image -- luks-json "$device" | check_luks_header \
  || die "the LUKS header is not the recovery key and one TPM2 enrollment without a policy"
printf '\033[H\033[2J\033[3J'
echo "nyra-install: the recovery key is checked, the key of the installation is gone, the header is as expected."

in_image -- esp-sync "$device"
changed=""

# --- the Machine Owner Key -------------------------------------------------------------------------
# From the verified image, and equal to the checkout's copy (which the release gate checks against
# the UKI's signature).
cert="$secrets/nyra.crt" der="$secrets/nyra.der"
podman run --rm --pull=never --network none "$image" cat /usr/lib/nyra/secureboot/nyra.crt > "$cert"
cmp "$cert" "$checkout/files/usr/lib/nyra/secureboot/nyra.crt" \
  || die "the certificate of the image is not the checkout's; the disk is installed, do not import it"
fingerprint="$(openssl x509 -noout -fingerprint -sha256 -in "$cert")"
fingerprint="${fingerprint#*=}"
expected="$(grep -Eo '([0-9A-F]{2}:){31}[0-9A-F]{2}' "$checkout/docs/SIGNING.md")"
[ "$(wc -l <<< "$expected")" = 1 ] || die "docs/SIGNING.md does not hold exactly one SHA-256 fingerprint"
echo "The Nyra certificate, SHA-256 fingerprint:"
echo "  $fingerprint"
[ "$fingerprint" = "$expected" ] || die "that is not the fingerprint of docs/SIGNING.md: $expected; the disk is installed, do not import it"
echo "It is the one of docs/SIGNING.md. Compare it with your own notes (docs/INSTALL.md) before going on."
read -r -p "Press Enter to import it as a Machine Owner Key (Ctrl-C to stop): " _
openssl x509 -in "$cert" -outform DER -out "$der"
# mokutil --test-key: 0 = not enrolled, 1 = already enrolled or already requested. CI cannot reach
# this line (no live session with Secure Boot and a MOK database).
rc=0
mokutil --test-key "$der" > /dev/null || rc=$?
case "$rc" in
  0)
    # mokutil asks for the one-time password itself: never as an argument.
    mokutil --import "$der" || die "mokutil --import failed. The disk is installed: run it again (docs/INSTALL.md)"
    ;;
  1) echo "The key is already enrolled or its enrollment is already requested." ;;
  *) die "mokutil --test-key failed (exit $rc). The disk is installed: run it again (docs/INSTALL.md)" ;;
esac

echo
echo "nyra-install: done. $imgref ($digest) is installed and was read back from the disk."
echo "Detach the live medium and reboot now: MokManager comes first (docs/INSTALL.md, step 6)."
