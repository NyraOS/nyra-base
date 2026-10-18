#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: installs IMAGE to WORKDIR/disk.raw on an encrypted root, as the installer does it
# (docs/BOOT.md, "Disk encryption"): a GPT with the ESP and the root partition (its Discoverable
# Partitions type, so the initrd finds it without a root= argument), LUKS2 on the root with a recovery
# key, ext4 with fs-verity on top, then bootc install to-filesystem and esp-sync install, as
# tools/vm/install-disk.sh. The recovery key goes to SECRETS_DIR/recovery-key (mode 0600), never to
# the output.
#   - Without a TPM: the password in SECRETS_DIR/password (taken as it is, no newline) is the other
#     key slot.
#   - With TPM_DIR, the state of the machine's TPM (swtpm): no password. A temporary TPM2 enrollment
#     without any policy, made in that TPM, unlocks the first boot, whose initrd replaces it with the
#     real enrollment (nyra-tpm-enroll.service). The key used during the installation is removed.
#     An empty record of the TPM2 enrollments goes inside the encrypted root
#     (/var/lib/nyra/tpm2-slots): the disk is one installed for the TPM, so a first boot without the
#     TPM or with Secure Boot off is enrolled later, once the recovery key is typed with them back.
#   tools/vm/install-encrypted.sh IMAGE WORKDIR SECRETS_DIR [TPM_DIR]
set -euo pipefail

image="$1" work="$2" secrets="$3" tpm="${4:-}"
loop="" swpid="" mnt="$work/install-esp"
trap 'sudo umount -q "$mnt" 2>/dev/null || true; [ -z "$loop" ] || sudo losetup -d "$loop" || true; [ -z "$swpid" ] || kill "$swpid" 2>/dev/null || true' EXIT
key=password
if [ -n "$tpm" ]; then
  key=install-key
  ( umask 077; head -c 32 /dev/urandom | base64 -w0 > "$secrets/$key" )
fi
truncate -s 12G "$work/disk.raw"
# The same sizes and types as bootc install to-disk with the composefs backend, without the BIOS boot
# partition (UEFI only).
sfdisk -q "$work/disk.raw" <<'EOF'
label: gpt
size=1024MiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="EFI-SYSTEM"
type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709, name="root"
EOF
loop="$(sudo losetup -P --show -f "$work/disk.raw")"
for _ in $(seq 50); do [ -b "${loop}p2" ] && break; udevadm settle --timeout=10 || true; sleep 0.2; done
[ -b "${loop}p2" ] || { echo "::error::No partitions on $loop after 10 s" >&2; exit 1; }
# In the image's own container, with its cryptsetup, systemd-cryptenroll, mkfs and bootc. The recovery
# key is printed alone on stdout; systemd-cryptenroll's other output (it shows the key as a QR code
# too) stays in a file next to it, shown only if the enrollment fails, and is deleted.
# DM_DISABLE_UDEV: the container has no udev, so device-mapper makes its device nodes itself instead
# of waiting for udev's confirmation, which never comes there (closing the volume hung forever).
timeout 900 sudo podman run --rm -i --privileged --pid=host --network none -e DM_DISABLE_UDEV=1 \
  -v /dev:/dev -v /var/lib/containers:/var/lib/containers -v "$secrets:/secrets" \
  "$image" bash -s "$loop" "$key" "${tpm:+tpm}" <<'EOF'
set -euo pipefail
esp="${1}p1" root="${1}p2" key="/secrets/$2" tpm="${3:-}"
mkfs.fat -n EFI-SYSTEM "$esp" >/dev/null
cryptsetup luksFormat -q --type luks2 --cipher aes-xts-plain64 --key-size 512 --sector-size 4096 \
  --pbkdf argon2id --key-file "$key" "$root"
if ! systemd-cryptenroll --unlock-key-file="$key" --recovery-key "$root" \
    > /secrets/recovery-key.out 2> /secrets/recovery-key.err; then
  grep -v -i -e 'recovery key has been generated' /secrets/recovery-key.err | head -20 >&2 || true
  rm -f /secrets/recovery-key.err /secrets/recovery-key.out
  exit 1
fi
rm /secrets/recovery-key.err
# The key alone, without the newline, as the password.
tr -d '\n' < /secrets/recovery-key.out > /secrets/recovery-key && rm /secrets/recovery-key.out
grep -Eqx '([cbdefghijklnrtuv]{8}-){7}[cbdefghijklnrtuv]{8}' /secrets/recovery-key
# Discards are allowed for good (a flag in the header), so TRIM reaches the disk.
cryptsetup open --key-file "$key" --allow-discards --persistent "$root" nyra-install-root
trap 'umount -q /target 2>/dev/null || true; cryptsetup close nyra-install-root || true' EXIT
mkfs.ext4 -q -O verity -L root /dev/mapper/nyra-install-root
mkdir -p /target
mount /dev/mapper/nyra-install-root /target
# No root= argument: the sealed command line has none, the initrd finds the root by its type.
bootc install to-filesystem --composefs-backend --bootloader systemd --root-mount-spec "" /target
if [ -n "$tpm" ]; then
  # The shared /var that bootc made (state/os/default/var), mounted at /var in the running system.
  # bootc's finalization (fstrim, then read-only, which flushes the journal) leaves /target read-only:
  # writable for this one file, then read-only again, as bootc left it.
  var=/target/state/os/default/var
  [ -d "$var" ] && [ ! -L "$var" ] || { echo "install-encrypted: no $var after bootc install" >&2; exit 1; }
  mount -o remount,rw /target
  install -d -m 0755 "$var/lib/nyra"
  install -m 0644 /dev/null "$var/lib/nyra/tpm2-slots"
  mount -o remount,ro /target
fi
EOF
sudo chown "$(id -u):$(id -g)" "$secrets/recovery-key" && chmod 0600 "$secrets/recovery-key"

if [ -n "$tpm" ]; then
  # The machine's TPM, reached over TCP from the image's systemd-cryptenroll.
  swtpm socket --tpm2 --tpmstate "dir=$tpm" --server type=tcp,port=2321 --ctrl type=tcp,port=2322 \
    --flags not-need-init,startup-clear &
  swpid=$!
  for _ in $(seq 50); do (exec 3<>/dev/tcp/127.0.0.1/2321) 2>/dev/null && break; sleep 0.2; done
  sudo podman run --rm -i --network host -v /dev:/dev --privileged -v "$secrets:/secrets" \
    "$image" bash -s "${loop}p2" <<'EOF'
set -euo pipefail
systemd-cryptenroll --unlock-key-file=/secrets/install-key --tpm2-device=swtpm:host=127.0.0.1 --tpm2-pcrs= "$1"
systemd-cryptenroll --wipe-slot=password "$1"
systemd-cryptenroll "$1"
EOF
  kill "$swpid" && wait "$swpid" || true
  swpid=""
  rm "$secrets/install-key"
fi

esp="$(tools/vm/esp-of.sh "$loop")"
mkdir -p "$mnt" && sudo mount "$esp" "$mnt"
sudo podman run --rm --network none -v "$mnt:/esp" "$image" /usr/lib/nyra/boot/esp-sync install /esp
sudo umount "$mnt" && sudo losetup -d "$loop" && loop=""
sudo chown "$(id -u):$(id -g)" "$work/disk.raw"
