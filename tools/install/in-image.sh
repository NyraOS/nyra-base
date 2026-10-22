#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The steps of an installation that run inside the container of the image being installed, so that
# the cryptsetup, systemd-cryptenroll, mkfs and bootc used are that image's own (the systemd its
# initrd and tpm-enroll read), never the live system's. Started by in_image (tools/install/lib.sh),
# by the installer (tools/install/nyra-install.sh) and by CI (tools/vm/install-encrypted.sh), so
# CI tests the same commands and the same LUKS parameters.
#   bash in-image.sh STEP ARGS...
set -euo pipefail

# The partition N of DISK: /dev/vda1, /dev/nvme0n1p1, /dev/loop0p1.
part() {
  case "$1" in
    *[0-9]) echo "${1}p$2" ;;
    *) echo "$1$2" ;;
  esac
}

# format DISK KEYFILE: the ESP and the LUKS2 header, with KEYFILE as the first key slot.
format() {
  local disk="$1" key="$2"
  mkfs.fat -n EFI-SYSTEM "$(part "$disk" 1)" > /dev/null
  cryptsetup luksFormat -q --type luks2 --cipher aes-xts-plain64 --key-size 512 --sector-size 4096 \
    --pbkdf argon2id --key-file "$key" "$(part "$disk" 2)"
}

# recovery-show DISK KEYFILE: adds the recovery key and prints it (with its QR code) on the
# terminal, nowhere else: the caller runs this with a terminal and --log-driver=none.
recovery-show() {
  systemd-cryptenroll --unlock-key-file="$2" --recovery-key "$(part "$1" 2)"
}

# recovery-check DISK SLOT: asks for a passphrase on the terminal and checks it against the key
# slot SLOT only.
recovery-check() {
  cryptsetup open --test-passphrase --key-slot "$2" "$(part "$1" 2)"
}

# recovery-wipe DISK KEYFILE: removes the recovery key (one the user could not type back).
recovery-wipe() {
  systemd-cryptenroll --unlock-key-file="$2" --wipe-slot=recovery "$(part "$1" 2)"
}

# recovery-to-file DISK KEYFILE: CI only (it needs the key to boot the disk): the recovery key goes
# to /secrets/recovery-key. systemd-cryptenroll's other output (it shows the key as a QR code too)
# stays in a file next to it, shown only if the enrollment fails, and is deleted.
recovery-to-file() {
  [ "${NYRA_CI:-}" = 1 ] || { echo "in-image: recovery-to-file is for CI only" >&2; exit 1; }
  local root
  root="$(part "$1" 2)"
  if ! systemd-cryptenroll --unlock-key-file="$2" --recovery-key "$root" \
      > /secrets/recovery-key.out 2> /secrets/recovery-key.err; then
    grep -v -i -e 'recovery key has been generated' /secrets/recovery-key.err | head -20 >&2 || true
    rm -f /secrets/recovery-key.err /secrets/recovery-key.out
    exit 1
  fi
  rm /secrets/recovery-key.err
  # The key alone, without the newline, as the password.
  tr -d '\n' < /secrets/recovery-key.out > /secrets/recovery-key && rm /secrets/recovery-key.out
  grep -Eqx '([cbdefghijklnrtuv]{8}-){7}[cbdefghijklnrtuv]{8}' /secrets/recovery-key
}

# luks-json DISK: the LUKS2 header's metadata as JSON (no secret in it).
luks-json() {
  cryptsetup luksDump --dump-json-metadata "$(part "$1" 2)"
}

# install-system DISK KEYFILE TPM [IMGREF DIGEST]: ext4 with fs-verity on the opened volume, then
# bootc. TPM=tpm adds the empty record of the TPM2 enrollments. With IMGREF and DIGEST, bootc is
# told the reference the machine updates from and the record it made is read back before anything
# is closed (tools/install/check-recorded.sh).
install-system() {
  local root key="$2" tpm="$3" imgref="${4:-}" digest="${5:-}"
  root="$(part "$1" 2)"
  # Discards are allowed for good (a flag in the header), so TRIM reaches the disk.
  cryptsetup open --key-file "$key" --allow-discards --persistent "$root" nyra-install-root
  trap 'umount -q /target 2>/dev/null || true; cryptsetup close nyra-install-root || true' EXIT
  mkfs.ext4 -q -O verity -L root /dev/mapper/nyra-install-root
  mkdir -p /target
  mount /dev/mapper/nyra-install-root /target
  # No root= argument: the sealed command line has none, the initrd finds the root by its type.
  bootc install to-filesystem --composefs-backend --bootloader systemd --root-mount-spec "" \
    ${imgref:+--target-imgref "$imgref"} /target
  if [ "$tpm" = tpm ]; then
    # The shared /var that bootc made (state/os/default/var), mounted at /var in the running system.
    # bootc's finalization (fstrim, then read-only, which flushes the journal) leaves /target read-only:
    # writable for this one file, then read-only again, as bootc left it.
    local var=/target/state/os/default/var
    [ -d "$var" ] && [ ! -L "$var" ] || { echo "in-image: no $var after bootc install" >&2; exit 1; }
    mount -o remount,rw /target
    install -d -m 0755 "$var/lib/nyra"
    install -m 0644 /dev/null "$var/lib/nyra/tpm2-slots"
    mount -o remount,ro /target
  fi
  if [ -n "$imgref" ]; then
    /nyra-install/check-recorded.sh /target "$imgref" "$digest"
  fi
}

# close-root: closes what install-system left open if it was killed.
close-root() {
  cryptsetup close nyra-install-root 2> /dev/null || true
}

# tpm-enroll DISK KEYFILE DEVICE: the temporary TPM2 enrollment without any policy, which unlocks
# the first boot; its initrd replaces it with the real one (nyra-tpm-enroll.service).
tpm-enroll() {
  systemd-cryptenroll --unlock-key-file="$2" --tpm2-device="$3" --tpm2-pcrs= "$(part "$1" 2)"
}

# wipe-install-key DISK: removes the key slot that held the key of the installation (the only
# "password" one) and lists what is left.
wipe-install-key() {
  local root
  root="$(part "$1" 2)"
  systemd-cryptenroll --wipe-slot=password "$root"
  systemd-cryptenroll "$root"
}

# The password of a disk without a TPM (docs/BOOT.md, "Disk encryption"). The key slots at the end of
# an installation: 0 is the key of the installation (format) until wipe-install-slot removes it, 1 is
# the password. The password is read from a file, never from an argument, a variable or the
# environment, and the caller deletes the file as soon as password-add is done.
password_slot=1
# The least memory the password's key derivation may use: 256 MiB, in KiB (cryptsetup's unit).
password_memory_floor=262144

# argon2id_memory: the memory, in KiB, that cryptsetup's benchmark settles on for about 2 s on this
# machine, up to 1 GiB (it takes less on a machine with little memory or a slow one); 0 if it fails.
argon2id_memory() {
  local kdf memory
  while read -r kdf _ _ memory _; do
    [ "$kdf" = argon2id ] && { echo "$memory"; return; }
  done < <(cryptsetup benchmark --pbkdf argon2id --iter-time 2000 --pbkdf-memory 1048576 2> /dev/null)
  echo 0
}

# password-memory: asks, before anything is written to the disk, whether this machine can derive a
# key from a password with at least 256 MiB of memory. Exit 3 if not.
password-memory() {
  local memory
  memory="$(argon2id_memory)"
  echo "in-image: the password's key derivation would use $memory KiB (least: $password_memory_floor)"
  [ "$memory" -ge "$password_memory_floor" ] 2> /dev/null || exit 3
}

# password-add DISK KEYFILE PWFILE: the password in PWFILE (exactly its bytes, no newline) as key slot
# 1, argon2id with cryptsetup's benchmark (about 2 s, up to 1 GiB), authorized by KEYFILE (key slot 0).
# Exit 4, the disk unchanged: a password that is not 12 to 64 printable ASCII characters (the rules
# of whatever asks for it; the initrd reads a US keyboard). The password must unlock its slot. That
# the derivation came out with at least 256 MiB is for check_luks_header_password
# (tools/install/lib.sh), which the caller runs on the finished header; password-memory said so
# beforehand, on the same machine.
password-add() {
  local root key="$2" pw="$3" size
  root="$(part "$1" 2)"
  size="$(wc -c < "$pw")"
  { [ "$size" -ge 12 ] && [ "$size" -le 64 ] && [ "$(LC_ALL=C tr -d ' -~' < "$pw" | wc -c)" = 0 ]; } \
    || { echo "in-image: the password is not 12 to 64 printable ASCII characters" >&2; exit 4; }
  cryptsetup luksAddKey -q --key-file "$key" --key-slot "$password_slot" \
    --pbkdf argon2id --iter-time 2000 --pbkdf-memory 1048576 "$root" "$pw"
  cryptsetup open --test-passphrase --key-slot "$password_slot" --key-file "$pw" "$root"
}

# wipe-install-slot DISK KEYFILE: removes key slot 0, which must be the one KEYFILE unlocks, and
# checks that KEYFILE unlocks nothing any more. (wipe-install-key above removes every "password" slot:
# on a disk with a password it would remove that too.)
wipe-install-slot() {
  local root
  root="$(part "$1" 2)"
  cryptsetup open --test-passphrase --key-slot 0 --key-file "$2" "$root"
  cryptsetup luksKillSlot -q "$root" 0
  if cryptsetup open --test-passphrase --key-file "$2" "$root" 2> /dev/null; then
    echo "in-image: the key of the installation still unlocks the disk" >&2
    exit 1
  fi
  systemd-cryptenroll "$root"
}

# esp-sync DISK: the boot files and loader.conf on the new ESP.
esp-sync() {
  mkdir -p /esp
  mount "$(part "$1" 1)" /esp
  /usr/lib/nyra/boot/esp-sync install /esp
  umount /esp
}

case "${1:-}" in
  format | recovery-show | recovery-check | recovery-wipe | recovery-to-file | luks-json \
    | install-system | close-root | tpm-enroll | wipe-install-key | esp-sync \
    | password-memory | password-add | wipe-install-slot)
    step="$1"
    shift
    "$step" "$@"
    ;;
  *)
    echo "in-image: unknown step: ${1:-}" >&2
    exit 2
    ;;
esac
