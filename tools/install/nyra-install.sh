#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The Nyra installer (docs/INSTALL.md): installs the release VERSION, whose manifest digest is
# DIGEST, onto the whole disk DEVICE of the machine it runs on, as root, from a Debian live session.
#   tools/install/nyra-install.sh DEVICE VERSION DIGEST
# VERSION, DIGEST and the commit of the checkout come from the release run on github.com.
#
# It runs from one of two trees (tools/install/release-tree.sh): a git checkout of the release commit,
# or a release tree, the files of the release without any git (the installer ISO), whose file RELEASE
# names the version, the digest, the commit and the architecture. It reads the policy, the trust roots
# and the certificate from that tree alone. A RELEASE that disagrees with VERSION, DIGEST or this
# machine's architecture is refused; its commit must be the revision label of the image, as the commit
# of a checkout must.
#
# What it does, in order:
#   1. refuses unless the checkout is clean and at a detached commit (a release tree: unless its
#      RELEASE agrees with the arguments), the machine has one TPM2 and Secure Boot on, and DEVICE is a
#      whole disk nothing uses; the owner types DEVICE to confirm;
#   2. pulls the image with tools/install/verified-pull.sh (the shipped policy, the pinned digest and
#      labels): it prints the image ID, and from there on only that ID is used, never a name;
#   3. partitions the disk and runs everything else in that image's container, without network and
#      without any pull (tools/install/in-image.sh; the same steps CI tests): LUKS2, ext4, bootc
#      install, the record of what bootc recorded read back, the recovery key shown once (the user
#      writes it down and presses Enter), the temporary TPM2 enrollment, the removal of the key of the installation, esp-sync.
#      With the machine interface below, the first administrator too: the image's own tools make the
#      yescrypt hash of the password (admin-record, before the disk is touched), and the name and
#      the hash go into the new system's /var/lib/nyra/first-admin, which the first boot turns into
#      the account (docs/BOOT.md, "The first administrator"). And a disk that opens with a password
#      instead of the TPM (answer unlock password; no TPM is needed): password-memory before anything is
#      written, the password as key slot 1 (password-add, from a file of $secrets that is deleted at
#      once), and in the end wipe-install-slot instead of the TPM enrollment (docs/BOOT.md, "Disk
#      encryption");
#   4. imports the Nyra certificate as a Machine Owner Key (the owner confirms it in MokManager at
#      the next boot).
# After a failure past the point where the disk is changed, the disk must be installed again from the
# start: there is no way to continue.
#
# A program (the text installer of the ISO) drives the same script through four subcommands that take
# no DEVICE, VERSION or DIGEST (they come from RELEASE, and they run from a release tree only):
#   nyra-install.sh check | disks                                    JSON on stdout
#   nyra-install.sh install --events-fd N --answers-fd M             events and answers as JSON lines
#   nyra-install.sh mok-import --events-fd N --answers-fd M          the same, for the Secure Boot key
# The steps are the same; what differs is where the questions are answered and where the recovery key
# and the one-time password of mokutil go (docs/INSTALL-INTERFACE.md).
set -euo pipefail

# Where die writes: stderr, or the log once the machine interface has one.
logfd=2
die() {
  echo "nyra-install: $*" >&"$logfd"
  exit 1
}
# A tree that is not the release asked for (release-tree.sh): one kind of refusal here.
refuse() { die "$@"; }

checkout="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
storage_dir=/var/lib/containers
storage="$storage_dir/storage"
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
. "$checkout/tools/install/release-tree.sh"
. "$checkout/tools/install/machine.sh"

# changed: the disk was written to and the installation is not finished. touched: it was, at any time
# (exit status 11, disk_changed in the event fail). own_secrets: $secrets is this run's, to remove.
# handoff_open: the terminal is not the installer's. fail_id: what the event fail names.
unlock=tpm device="" disk_entry="" events_fd="" answers_fd="" changed="" touched="" own_secrets="" handoff_open="" fail_id=verify

# --- cleanup ---------------------------------------------------------------------------------------
cleanup() {
  local rc=$?
  trap - EXIT
  # The volume is closed in the image's container, if the install was killed while it was open.
  if [ -n "$changed" ] && [ -n "$image" ] && [ -d "$secrets" ]; then
    in_image -- close-root > /dev/null 2>&1 || true
  fi
  [ -z "$own_secrets" ] || rm -rf "$secrets"
  # A failure while the terminal was handed over: what it showed does not stay.
  [ -z "$handoff_open" ] || printf '\033[H\033[2J\033[3J' > /dev/tty 2> /dev/null || true
  if [ "$rc" != 0 ] && [ -n "$changed" ]; then
    echo "nyra-install: failed after $device was changed. It must be installed again from the start," \
      "with this script: nothing on it is to be used as it is." >&"$logfd"
  fi
  if [ "$rc" != 0 ] && [ -n "$events_fd" ]; then
    # 10: nothing on the disk was changed. 11: it was. Why is in the log, not in the event.
    if [ -n "$touched" ]; then
      rc=11
      emit "{\"event\":\"fail\",\"id\":\"$fail_id\",\"disk_changed\":true}"
    else
      rc=10
      emit "{\"event\":\"fail\",\"id\":\"$fail_id\",\"disk_changed\":false}"
    fi
  fi
  exit "$rc"
}

# mok_enroll: shows the fingerprint (mok_fingerprint has checked it) and requests the import of the
# certificate in $cert as a Machine Owner Key: DER in $der. The terminal mode asks to be sure first; the
# machine interface has had the owner's yes on the screen of the installer.
mok_enroll() {
  local rc=0
  echo "The Nyra certificate, SHA-256 fingerprint:"
  echo "  $fingerprint"
  echo "It is the one of docs/SIGNING.md. Compare it with your own notes (docs/INSTALL.md) before going on."
  [ "$cmd" != cli ] || read -r -p "Press Enter to import it as a Machine Owner Key (Ctrl-C to stop): " _
  openssl x509 -in "$cert" -outform DER -out "$der"
  # mokutil --test-key: 0 = not enrolled, 1 = already enrolled or already requested. CI cannot reach
  # this line (no live session with Secure Boot and a MOK database).
  mokutil --test-key "$der" > /dev/null || rc=$?
  case "$rc" in
    0)
      # mokutil asks for the one-time password itself: never as an argument.
      mokutil --import "$der" || die "mokutil --import failed. The disk is installed: run it again (docs/INSTALL.md)"
      ;;
    1) echo "The key is already enrolled or its enrollment is already requested." ;;
    *) die "mokutil --test-key failed (exit $rc). The disk is installed: run it again (docs/INSTALL.md)" ;;
  esac
}

# recovery_key: the recovery key is shown on the terminal only (the container has no log:
# --log-driver=none), written nowhere. The user writes it down on paper and presses Enter; nothing is
# typed back and nothing is checked against the disk. The screen is cleared afterwards (the handoff does
# it in the machine interface, this script at the end in the terminal mode).
recovery_key() {
  in_image -it --log-driver=none -- recovery-show "$device" "$key"
  echo
  echo "Write the recovery key down now, on paper: it is the only way in if the TPM refuses the disk."
  echo "It is shown only once, and nothing checks what you wrote."
  read -r -p "Press Enter when you have written it down: " _
}

trap cleanup EXIT
trap 'exit 130' INT TERM

# --- what was asked --------------------------------------------------------------------------------
# A subcommand of the machine interface (docs/INSTALL-INTERFACE.md), or, with none, the terminal mode.
cmd=cli
want_events="" want_answers=""
case "${1:-}" in
  check | disks | install | mok-import)
    cmd="$1"
    shift
    ;;
esac
case "$cmd" in
  cli)
    [ $# = 3 ] || die "usage: nyra-install.sh DEVICE VERSION DIGEST"
    device="$1" version="$2" digest="$3"
    ;;
  install | mok-import)
    [ $# = 4 ] && [ "$1" = --events-fd ] && [ "$3" = --answers-fd ] \
      || die "usage: nyra-install.sh $cmd --events-fd N --answers-fd M"
    # 3 to 8: 9 is the log's, and 0 to 2 are the terminal's.
    [[ "$2" =~ ^[3-8]$ && "$4" =~ ^[3-8]$ && "$2" != "$4" ]] \
      || die "the events and the answers need two different descriptors from 3 to 8"
    { : >&"$2" && : <&"$4"; } 2> /dev/null || die "the descriptors $2 and $4 are not open"
    want_events="$2" want_answers="$4"
    ;;
  *) [ $# = 0 ] || die "usage: nyra-install.sh $cmd" ;;
esac
[ "$(id -u)" = 0 ] || die "run as root"
if [ "$cmd" = disks ]; then
  disks_json
  exit 0
fi
# From here on a failure is reported as an event, if there is a descriptor for it.
events_fd="$want_events" answers_fd="$want_answers"
if [ -n "$events_fd" ]; then
  # Nothing on the terminal but the handoffs; the rest goes to the log, in memory. It holds no secret:
  # none is an argument or in the environment, and the terminal steps do not write to it.
  trap '' PIPE
  mkdir -p "$log_dir"
  chmod 0700 "$log_dir"
  [ "$(findmnt -no FSTYPE -T "$log_dir")" = tmpfs ] || die "$log_dir is not in memory"
  ( umask 077; : >> "$log_dir/install.log" )
  chmod 0600 "$log_dir/install.log"
  exec 9>> "$log_dir/install.log"
  logfd=9
  exec >&9 2>&9 < /dev/null
  if [ "$cmd" = install ]; then step verify; else fail_id=mok; fi
fi
if [ "$cmd" != cli ]; then
  # The values of the release are RELEASE's; tree_identify below reads the whole file against them.
  release_values "$checkout"
  version="$release_version" digest="$release_digest"
fi
[[ "$version" =~ ^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]] || die "not a version: $version"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "not a sha256 digest: $digest"
[ -z "${CONTAINERS_POLICY_JSON:-}" ] || die "CONTAINERS_POLICY_JSON is set"
[ -z "${NYRA_CI:-}" ] || die "NYRA_CI is set: the recovery key would go to a file"
if [ "$cmd" = cli ]; then
  [ -t 0 ] && [ -t 1 ] || die "run it from a terminal: the recovery key is shown there"
fi

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

# --- the checkout or the release tree --------------------------------------------------------------
tree_identify "$checkout" "$repo_name" "$version" "$digest"
if [ "$tree_mode" = git ]; then
  # --git-dir (and --work-tree): git refuses to read a checkout owned by another user, unless told.
  git_checkout() { git --git-dir="$checkout/.git" --work-tree="$checkout" "$@"; }
  if git_checkout symbolic-ref -q HEAD > /dev/null; then
    die "the checkout is on a branch: git checkout --detach <the release commit>"
  fi
  [ -z "$(git_checkout status --porcelain)" ] || die "the checkout has changes: use a fresh clone"
  echo "nyra-install: the checkout is at the commit $tree_commit"
elif [ "$cmd" != check ]; then
  echo "nyra-install: the release tree is $version, $digest, the commit $tree_commit"
fi

# --- the machine -----------------------------------------------------------------------------------
machine_facts
if [ "$cmd" = check ]; then
  check_json
  exit 0
fi
if [ "$cmd" = cli ]; then
  require_tpm
  require_secure_boot
elif [ "$cmd" = install ]; then
  # What the answers ask for, and that this machine can do it. A TPM is needed only to unlock with it; Secure
  # Boot is needed either way.
  read_answers
  unlock="$a_unlock"
  [ "$uefi" = true ] || die "not booted in UEFI mode"
  if [ "$unlock" = tpm ]; then require_tpm; fi
  require_secure_boot
  fail_id=memory
  [ "$mem_tenths" -ge $((min_memory_gib * 10)) ] \
    || die "this machine has $((mem_tenths / 10)).$((mem_tenths % 10)) GiB of memory; the installer needs $min_memory_gib GiB"
  fail_id=verify
  jq -e --arg name "$a_admin_name" 'index($name) == null' <<< "$(reserved_names)" > /dev/null \
    || die "the administrator name is a name of the system"
  tty_ready
  chosen_disk
  device="$a_device"
fi

# --- the target ------------------------------------------------------------------------------------
if [ "$cmd" = cli ]; then
  [ -b "$device" ] || die "$device is not a block device"
  [ "$(lsblk -dnro TYPE "$device")" = disk ] || die "$device is not a whole disk"
  # Mounted: anything of the disk (the live system's own medium included) or its partitions.
  [ -z "$(lsblk -nro MOUNTPOINTS "$device" | tr -d '[:space:]')" ] || die "$device or its partitions are in use (mounted or swap)"
  lsblk -nro FSTYPE "$device" | grep -qx iso9660 && die "$device holds an ISO image: the live medium?"
fi

# The key of the installation: random, in a directory only root reads, in memory, gone at any exit.
mkdir -m 0700 "$secrets" || die "$secrets exists: another installation is running, or was killed"
own_secrets=1
[ "$(findmnt -no FSTYPE -T "$secrets")" = tmpfs ] || die "$secrets is not in memory"

# --- the Machine Owner Key, alone ------------------------------------------------------------------
# The certificate of the tree, not the disk's: the disk is already installed.
if [ "$cmd" = mok-import ]; then
  cert="$checkout/$cert_file" der="$secrets/nyra.der"
  mok_fingerprint "$cert"
  handoff mok-password mok_enroll
  emit '{"event":"done"}'
  exit 0
fi

( umask 077; head -c 32 /dev/urandom | base64 -w0 > "$secrets/install-key" )
key=/secrets/install-key

# --- the image ---------------------------------------------------------------------------------------
# The live root is an overlayfs, which cannot be the upperdir of the overlay driver that the pull
# uses: the storage goes in memory then.
mkdir -p "$storage_dir"
if [ "$(findmnt -no FSTYPE -T "$storage_dir")" = overlay ]; then
  mount -t tmpfs tmpfs "$storage_dir" || die "cannot mount a tmpfs on $storage_dir"
fi
image="$("$checkout/tools/install/verified-pull.sh" "$repo_name" "$version" "$digest" "$storage")"
[[ "$image" =~ ^[0-9a-f]{64}$ ]] || die "verified-pull.sh did not print an image ID"
echo "nyra-install: installing the image $image ($imgref, $digest)"
admin=""
if [ "$cmd" = install ]; then
  # The first administrator's record, made by the image's own tools before the disk is touched: the
  # password goes in on the standard input of the container (printf is a builtin: no argument), and the
  # record, the name and the yescrypt hash, is a file in $secrets until install-system puts it in the new
  # system. The password is gone from this script after it.
  printf '%s\n' "$a_admin_password" | in_image -i --log-driver=none -- admin-record "$a_admin_name" /secrets/first-admin \
    || die "cannot make the record of the administrator $a_admin_name"
  a_admin_password=""
  admin=/secrets/first-admin
  # With a password, whether this machine can derive the disk's key from it with at least 256 MiB of
  # memory, before anything is written (docs/BOOT.md, "Disk encryption").
  if [ "$unlock" = password ]; then
    in_image -- password-memory || die "this machine cannot derive a disk key from a password with at least 256 MiB of memory"
  fi
fi
step_end verify

# --- the disk ----------------------------------------------------------------------------------------
if [ "$cmd" = cli ]; then
  # Asked after the pull, which takes a while, so that the answer is not left waiting.
  lsblk -o NAME,SIZE,MODEL,FSTYPE,LABEL "$device"
  read -r -p "Everything on $device will be erased. Type its path to go on: " typed
  [ "$typed" = "$device" ] || die "not confirmed"
else
  # The answers came before the pull: the disk is looked at again just before the first write.
  chosen_disk
fi
step prepare
changed=1 touched=1
emit '{"event":"disk-changed"}'
partition_disk "$device"
for _ in $(seq 50); do
  udevadm settle --timeout=10 || true
  [ "$(lsblk -nro TYPE "$device" | grep -c '^part$')" = 2 ] && break
  sleep 0.2
done
[ "$(lsblk -nro TYPE "$device" | grep -c '^part$')" = 2 ] || die "no partitions on $device after 10 s"
in_image -- format "$device" "$key"
if [ "$unlock" = password ]; then
  # The disk's password, from the answers to a file only root reads, in memory, for password-add alone: it is
  # written just before and deleted just after, so that only that container can see it. Never an argument,
  # never the environment, never the log.
  ( umask 077; printf '%s' "$a_disk_password" > "$secrets/password" )
  a_disk_password=""
  in_image -- password-add "$device" "$key" /secrets/password
  rm -f "$secrets/password"
fi
step_end prepare
step install
# The record bootc made of the reference and the digest is read back inside, before the volume is
# closed: a machine that records anything else would update from somewhere else.
tpm_arg=""
[ "$unlock" != tpm ] || tpm_arg=tpm
in_image -- install-system "$device" "$key" "$tpm_arg" "$imgref" "$digest" ${admin:+"$admin"}
step_end install

# --- the recovery key --------------------------------------------------------------------------------
step protect
if [ "$cmd" = cli ]; then recovery_key; else handoff recovery-key recovery_key; fi

# --- the TPM, or the password ---------------------------------------------------------------------------
if [ "$unlock" = tpm ]; then
  # No PCR, no policy: the first boot of the installed system replaces this enrollment with the real one.
  in_image -- tpm-enroll "$device" "$key" "$tpm_dev"
  in_image -- wipe-install-key "$device"
  in_image -- luks-json "$device" | check_luks_header \
    || die "the LUKS header is not the recovery key and one TPM2 enrollment without a policy"
else
  # The password is key slot 1 already. Only the key of the installation, slot 0, goes (wipe-install-key
  # would remove every "password" slot, the password included).
  in_image -- wipe-install-slot "$device" "$key"
  in_image -- luks-json "$device" | check_luks_header_password \
    || die "the LUKS header is not the recovery key and one password slot (argon2id, 256 MiB or more)"
fi
if [ "$cmd" = cli ]; then printf '\033[H\033[2J\033[3J'; fi
echo "nyra-install: the key of the installation is gone, the header is as expected."

in_image -- esp-sync "$device"
changed=""
step_end protect

# --- the Machine Owner Key -------------------------------------------------------------------------
# From the verified image, and equal to the checkout's copy (which the release gate checks against
# the UKI's signature).
step final
cert="$secrets/nyra.crt" der="$secrets/nyra.der"
podman run --rm --pull=never --network none "$image" cat /usr/lib/nyra/secureboot/nyra.crt > "$cert"
cmp "$cert" "$checkout/$cert_file" \
  || die "the certificate of the image is not the checkout's; the disk is installed, do not import it"
mok_fingerprint "$cert"
if [ "$cmd" = cli ]; then mok_enroll; else handoff mok-password mok_enroll; fi
step_end final

echo
echo "nyra-install: done. $imgref ($digest) is installed and was read back from the disk."
echo "Detach the live medium and reboot now: MokManager comes first (docs/INSTALL.md, step 6)."
emit '{"event":"done"}'
