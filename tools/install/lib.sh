# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash disable=SC2154 # image, secrets: set by the script that sources this
# Sourced by tools/install/nyra-install.sh and the CI scripts that make a Nyra disk
# (tools/vm/install-encrypted.sh, tools/install/test-recovery-key.sh): what they share on the host.

install_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# partition_disk TARGET: the same sizes and types as bootc install to-disk with the composefs backend,
# without the BIOS boot partition (UEFI only). TARGET is a disk or a file.
partition_disk() {
  sfdisk -q --wipe always --wipe-partitions always "$1" <<'EOF'
label: gpt
size=1024MiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="EFI-SYSTEM"
type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709, name="root"
EOF
}

# in_image [PODMAN_OPTION...] -- STEP [ARG...]: a step of tools/install/in-image.sh in a container of
# $image (an image ID in the installer; as_root is "sudo" or empty). --pull=never: nothing is ever
# pulled, whatever the system's signature policy says. No network, except for in_image_network (CI's
# swtpm); no time limit, except in_image_timeout seconds. $secrets is mounted at /secrets, this
# directory at /nyra-install.
# DM_DISABLE_UDEV: the container has no udev, so device-mapper makes its device nodes itself instead
# of waiting for udev's confirmation, which never comes there (closing the volume hung forever).
in_image() {
  local options=()
  while [ "$1" != -- ]; do
    options+=("$1")
    shift
  done
  shift
  # shellcheck disable=SC2086 # as_root is empty or "sudo"
  timeout --foreground "${in_image_timeout:-0}" ${as_root:-} podman run --rm --pull=never \
    --privileged --pid=host --network "${in_image_network:-none}" -e DM_DISABLE_UDEV=1 \
    -v /dev:/dev -v /var/lib/containers:/var/lib/containers -v "$secrets:/secrets" \
    -v "$install_dir:/nyra-install:ro" "${options[@]}" "$image" bash /nyra-install/in-image.sh "$@"
}

# recovery_slot: the key slot of the recovery key, from the LUKS2 header's JSON on stdin.
recovery_slot() {
  jq -er '[.tokens[] | select(.type == "systemd-recovery") | .keyslots[]] | if length == 1 then .[0] else empty end'
}

# check_luks_header: succeeds only if the LUKS2 header's JSON on stdin is that of a finished
# installation for a TPM: exactly the recovery key and one TPM2 enrollment without any policy (no
# PCR, no public key or signed policy, no pcrlock, no PIN), and no other key slot: the key of the
# installation is gone.
check_luks_header() {
  jq -e '
    [.tokens[]] as $tokens
    | [$tokens[] | select(.type == "systemd-tpm2")] as $tpm2
    | ($tokens | length) == 2
      and ([$tokens[] | select(.type == "systemd-recovery")] | length) == 1
      and ($tpm2 | length) == 1
      and ($tpm2[0] | ((."tpm2-pcrs" // []) | length) == 0
          and ((.tpm2_pubkey // "") == "") and ((.tpm2_pubkey_pcrs // []) | length) == 0
          and ((.tpm2_pcrlock // false) == false) and ((."tpm2-pin" // false) == false))
      and ((.keyslots | keys | sort) == ([$tokens[].keyslots[]] | sort))
      and (.keyslots | length) == 2' > /dev/null
}

# check_luks_header_password: succeeds only if the LUKS2 header's JSON on stdin is that of a finished
# installation with a password: exactly two key slots, the recovery key (one token, systemd-recovery,
# for one key slot) and the password (no token), whose key derivation is argon2id with at least
# 256 MiB of memory (262144 KiB); no TPM2 token, nothing else. The key of the installation is gone.
check_luks_header_password() {
  jq -e '
    [.tokens[]] as $tokens
    | ($tokens | length) == 1
      and ($tokens[0].type == "systemd-recovery")
      and (($tokens[0].keyslots | length) == 1)
      and ((.keyslots | length) == 2)
      and ([.keyslots | keys[] | select(. != $tokens[0].keyslots[0])] as $other
          | ($other | length) == 1
            and (.keyslots[$other[0]] | .type == "luks2" and .key_size == 64
                 and .kdf.type == "argon2id" and .kdf.memory >= 262144 and .kdf.time >= 1))' > /dev/null
}
