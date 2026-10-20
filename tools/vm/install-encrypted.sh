#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: installs IMAGE to WORKDIR/disk.raw on an encrypted root, as the installer does it
# (docs/BOOT.md, "Disk encryption"): a GPT with the ESP and the root partition (its Discoverable
# Partitions type, so the initrd finds it without a root= argument), LUKS2 on the root with a recovery
# key, ext4 with fs-verity on top, then bootc install to-filesystem and esp-sync install, as
# tools/vm/install-disk.sh. The steps are those of the installer's (tools/install/in-image.sh,
# tools/install/lib.sh). Unlike the installer, which shows the recovery key once on the console and
# writes it nowhere, this script needs it to boot the disk: it goes to SECRETS_DIR/recovery-key
# (mode 0600), never to the output (tools/install/test-recovery-key.sh tests the installer's way).
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
as_root=sudo
. tools/install/lib.sh
loop="" swpid=""
trap '[ -z "$loop" ] || sudo losetup -d "$loop" || true; [ -z "$swpid" ] || kill "$swpid" 2>/dev/null || true' EXIT
key=password
if [ -n "$tpm" ]; then
  key=install-key
  ( umask 077; head -c 32 /dev/urandom | base64 -w0 > "$secrets/$key" )
fi
truncate -s 12G "$work/disk.raw"
partition_disk "$work/disk.raw"
loop="$(sudo losetup -P --show -f "$work/disk.raw")"
for _ in $(seq 50); do [ -b "${loop}p2" ] && break; udevadm settle --timeout=10 || true; sleep 0.2; done
[ -b "${loop}p2" ] || { echo "::error::No partitions on $loop after 10 s" >&2; exit 1; }
in_image -- format "$loop" "/secrets/$key"
in_image -e NYRA_CI=1 -- recovery-to-file "$loop" "/secrets/$key"
sudo chown "$(id -u):$(id -g)" "$secrets/recovery-key" && chmod 0600 "$secrets/recovery-key"
in_image_timeout=900 in_image -- install-system "$loop" "/secrets/$key" "${tpm:+tpm}"

if [ -n "$tpm" ]; then
  # The machine's TPM, reached over TCP from the image's systemd-cryptenroll.
  swtpm socket --tpm2 --tpmstate "dir=$tpm" --server type=tcp,port=2321 --ctrl type=tcp,port=2322 \
    --flags not-need-init,startup-clear &
  swpid=$!
  for _ in $(seq 50); do (exec 3<>/dev/tcp/127.0.0.1/2321) 2>/dev/null && break; sleep 0.2; done
  in_image_network=host in_image -- tpm-enroll "$loop" "/secrets/$key" swtpm:host=127.0.0.1
  in_image -- wipe-install-key "$loop"
  # The header check of the installer (tools/install/nyra-install.sh), on the header CI boots from.
  in_image -- luks-json "$loop" | check_luks_header \
    || { echo "::error::The LUKS header is not recovery key + one policy-less TPM2 slot" >&2; exit 1; }
  kill "$swpid" && wait "$swpid" || true
  swpid=""
  rm "$secrets/$key"
fi

in_image -- esp-sync "$loop"
sudo losetup -d "$loop" && loop=""
sudo chown "$(id -u):$(id -g)" "$work/disk.raw"
