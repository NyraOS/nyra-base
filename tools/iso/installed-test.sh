#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: boots the system that tools/iso/install-test.py installed from the ISO, with Secure Boot on, and
# checks it (docs/ISO.md):
#   - the first boot: the disk unlocks with the password typed at the prompt (password) or by itself with
#     the TPM (tpm); the first administrator exists, in the group sudo, with a home and a password hash;
#     root is locked, nobody has an empty password, the record is gone, the fixed defaults are set,
#     nothing failed; bootc status names the signed reference and the digest of the release;
#   - a second boot: the recovery key opens the disk (both ways; with the TPM, on a TPM that has no state,
#     which cannot unseal the temporary enrollment of the first boot).
# The installed image's sealed command line has no console, so, as in the other tests (tools/vm/first-admin.sh),
# the disk gets a test console add-on, signed with a key made here and enrolled, with the image's UKI
# certificate, as a Machine Owner Key in a copy of the firmware variables. That stands in for MokManager,
# which CI cannot drive; the request the installer made is checked by install-test.py. The key lives only in
# WORKDIR and is deleted at the end.
#   tools/iso/installed-test.sh IMAGE WORKDIR UKI_CERT TPM_DIR password|tpm DIGEST VERSION LOGDIR SUMMARY
set -euo pipefail

image="$1" work="$2" uki_cert="$3" tpm="$4" unlock="$5" digest="$6" version="$7" logs="$8" summary="$9"
t="$work/installed"
mnt="$t/esp"
loop=""
mkdir -p "$mnt"
trap 'sudo umount -q "$mnt" 2>/dev/null || true; [ -z "$loop" ] || sudo losetup -d "$loop" || true; rm -rf "$t"' EXIT
secrets="$work/secrets"

openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=Nyra CI add-on test key" \
  -keyout "$t/local.key" -out "$t/local.crt" 2>/dev/null
tools/vm/test-addon.sh "$image" "$t/console.addon.efi" systemd.import_credentials=yes "$t/local.key" "$t/local.crt"
virt-fw-vars --input /usr/share/OVMF/OVMF_VARS_4M.ms.fd --output "$t/vars.fd" \
  --add-mok 605dab50-e046-4300-abb6-3dd810dd8b23 "$uki_cert" \
  --add-mok 605dab50-e046-4300-abb6-3dd810dd8b23 "$t/local.crt"

loop="$(sudo losetup -P --show -f "$work/disk.raw")"
esp="$(tools/vm/esp-of.sh "$loop")"
sudo mount "$esp" "$mnt"
sudo mkdir -p "$mnt/loader/addons"
sudo cp "$t/console.addon.efi" "$mnt/loader/addons/nyra-test-console.addon.efi"
sudo umount "$mnt"
sudo losetup -d "$loop"
loop=""

ask="Please enter passphrase or recovery key for disk [^\r\n:]*:"
# Every command is traced in the guest, so a failure shows what failed.
vm() {
  local args=() prev="" a
  for a in "$@"; do
    if [ "$prev" = --command ]; then args+=("( set -x; $a )"); else args+=("$a"); fi
    prev="$a"
  done
  python3 -B tools/vm/vm-boot.py --secure-boot "$t/vars.fd" --keep-vars --disk "$work/disk.raw" --persist --poweroff \
    --autologin --timeout 300 --summary "$summary" "${args[@]}"
}
defaults='h="$(cat /etc/hostname)"; l="$(cat /etc/locale.conf 2>&1)"; echo "host name: [$h]; /etc/locale.conf: [$l]"; test "$h" = nyra && echo "$l" | grep -qx LANG=en_US.UTF-8 && cmp /etc/localtime /usr/share/zoneinfo/UTC && echo "the fixed defaults are set"'
running='s="$(systemctl is-system-running --wait)"; echo "system: $s"; systemctl --no-pager --failed; test "$s" = running'
account='id maria && id -nG maria | tr " " "\n" | grep -qx sudo && passwd -S maria | grep -q " P " && passwd -S root | grep -q " L " && ! cut -d: -f2 /etc/shadow | grep -qx "" && grep -q "^maria:[\$]y[\$]" /etc/shadow && test "$(stat -c %U /var/home/maria)" = maria && test ! -e /var/lib/nyra/first-admin && echo "the administrator: in sudo, a yescrypt hash, a home; root locked; no empty password; the record is gone"'
booted='d="$(bootc status --booted --format json | grep -o "\"imageDigest\":\"[^\"]*\"" | cut -d\" -f4)"; echo "booted imageDigest: $d"; test "$d" = '"$digest"'; v="$(bootc status --booted --format json | grep -o "\"version\":\"[^\"]*\"" | cut -d\" -f4)"; echo "booted version: $v"; test "$v" = '"$version"'; bootc status --booted --format json | grep -o "\"image\":\"[^\"]*\"" | head -n 1 | grep -q "updates.nyraos.com/nyra-base" && echo "the reference is updates.nyraos.com/nyra-base"'
sb='mokutil --sb-state | grep -q "SecureBoot enabled" && echo "Secure Boot is on"'

if [ "$unlock" = password ]; then
  pw="$(cat "$secrets/disk-password")"
  vm --chat "$ask=>$pw" --chat-then-login --log "$logs/serial-installed-1.log" \
    --title "Installed from the ISO, disk password: the first boot" \
    --command "$running" --command "$account" --command "$defaults" --command "$booted" --command "$sb"
  # The recovery key opens the disk too.
  vm --chat "$ask=>$(cat "$secrets/recovery-key")" --chat-then-login --log "$logs/serial-installed-2.log" \
    --title "Installed from the ISO, disk password: the recovery key opens the disk" \
    --command "$running" --command "$account"
else
  # The test console add-on changes what PCR 12 measures, so the first boot is opened by the temporary
  # enrollment (no policy) and no real one is made (that is the encryption tests' business,
  # tools/vm/encryption-first-boot.sh: a boot without the add-on); the temporary enrollment stays, so a
  # second boot with the same TPM opens by itself again. A TPM with no state cannot unseal it: that boot
  # asks for the disk, and the recovery key opens it.
  vm --tpm "$tpm" --log "$logs/serial-installed-1.log" \
    --title "Installed from the ISO, TPM: the first boot unlocks by itself" \
    --command "$running" --command "$account" --command "$defaults" --command "$booted" --command "$sb"
  if python3 -B tools/vm/vm-boot.py --on-console "Please enter (passphrase or )?recovery key for disk" "$logs/serial-installed-1.log"; then
    echo "::error::the first boot asked for the disk: the TPM should have opened it"
    exit 1
  fi
  empty="$tpm-empty"
  rm -rf "$empty"
  mkdir -p "$empty"
  # A disk with a TPM and the recovery key only (no password slot) asks for "recovery key", not for "passphrase or
  # recovery key"; the prompt of the first run showed it ("Please enter recovery key for disk root:").
  vm --tpm "$empty" --chat "Please enter (passphrase or )?recovery key for disk [^\r\n:]*:=>$(cat "$secrets/recovery-key")" --chat-then-login --log "$logs/serial-installed-2.log" \
    --title "Installed from the ISO, TPM: the recovery key opens the disk" \
    --command "$running" --command "$account"
fi
