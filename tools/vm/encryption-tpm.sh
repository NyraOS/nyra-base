#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: Titanic T10 with a TPM (docs/BOOT.md, "Disk encryption"). The image is installed on an
# encrypted root for a machine with a TPM, as the installer does it (tools/vm/install-encrypted.sh
# with the VM's swtpm state): a recovery key and a temporary TPM2 enrollment without any policy, no
# password. The VM has that TPM, Secure Boot on (Microsoft keys, the image's UKI certificate as a MOK)
# and one firmware variable store for all boots. Then:
#   1. the first boot unlocks by itself, and its initrd replaces the temporary enrollment with the one
#      bound to the UKI's signed PCR 11 policy (reference "initrd") and PCR 7 and 12, unsealed once to
#      check it; no unit failed. Read offline afterwards: the recovery key slot and exactly that one
#      TPM2 enrollment, nothing else;
#   2. the next boot unlocks by itself, with nothing to enroll;
#   3. without the TPM (as when it is turned off in the firmware) the disk asks for its recovery key,
#      which unlocks it; no unit failed;
#   4. with the TPM back, it unlocks by itself again;
#   5. the TPM stops answering after the disk is unlocked, before leave-initrd is measured: a forced
#      reboot (FailureAction=reboot-force), never a running system; 6. then it unlocks by itself again;
#   5. the recovery key is nowhere in the serial logs, in the unencrypted part of the disk or in the
#      decrypted root file system.
# A boot that should unlock by itself fails if the console ever asks for the disk. The test console
# add-on (tools/vm/test-console.sh) is signed with a key made here and enrolled as a MOK; it is
# measured into PCR 12 at every boot, the first one included, so it is part of the enrolled state.
#   tools/vm/encryption-tpm.sh IMAGE UKI_CERT WORKDIR LOGDIR SUMMARY
set -euo pipefail

image="$1" uki_cert="$2" work="$3/encryption-tpm" logs="$4" summary="$5"
# swtpm's state under LOGDIR (RUNNER_TEMP): Ubuntu's AppArmor profile for swtpm allows no other place.
tpm="$logs/encryption-tpm-state"
secrets="$work/secrets"
mnt="$work/esp"
loop=""
mkdir -p "$work" "$tpm" "$mnt"
mkdir -m 0700 "$secrets"
trap 'sudo umount -q "$mnt" 2>/dev/null || true; [ -z "$loop" ] || sudo losetup -d "$loop" || true; sudo rm -rf "$secrets" "$tpm" "$work"' EXIT

start=$SECONDS
tools/vm/install-encrypted.sh "$image" "$work" "$secrets" "$tpm"
key="$(cat "$secrets/recovery-key")"
printf '%s\n' "$key" > "$secrets/patterns"
{
  echo "## Disk encryption with a TPM (Titanic T10)"
  echo
  echo "Installed on LUKS2 with a recovery key and a temporary TPM2 enrollment (tools/vm/install-encrypted.sh), $((SECONDS - start)) s; swtpm, Secure Boot on."
  echo
} >> "$summary"

# The LUKS2 header, read offline: the key slots and tokens, as "TYPE:what" words.
root_start="$(sfdisk -J "$work/disk.raw" | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["partitiontable"]["partitions"][1]["start"])')"
slots() {
  dd if="$work/disk.raw" of="$work/header" bs=512 skip="$root_start" count=32768 status=none
  sudo podman run --rm --network none -v "$work/header:/header:ro" "$image" \
    cryptsetup luksDump --dump-json-metadata /header | python3 -I -c '
import json, sys
h = json.load(sys.stdin)
out, used = [], set()
for t in h["tokens"].values():
    used.update(t["keyslots"])
    if t["type"] == "systemd-tpm2":
        if t["tpm2-policy-hash"] == "0" * 64:
            out.append("tpm2:temporary")
        else:
            out.append("tpm2:pubkey-pcrs=%s,ref=%s,pcrs=%s" % (
                "+".join(map(str, t.get("tpm2_pubkey_pcrs", []))), t.get("tpm2_pubkey_ref", "none"),
                "+".join(map(str, t.get("tpm2-pcrs", [])))))
    else:
        out.append(t["type"])
out += ["slot-without-token"] * len(set(h["keyslots"]) - used)
print(" ".join(sorted(out)))'
}
fail=0
expect_slots() { # expect_slots WHEN EXPECTED
  local got mark=OK
  got="$(slots)"
  if [ "$got" != "$2" ]; then mark=WRONG; fail=1; fi
  echo "encryption-tpm: key slots $1: $got [$mark]"
  printf '| Key slots %s | `%s` | %s |\n' "$1" "$got" "$mark" >> "$summary"
}
{ echo "| Check | Result | |"; echo "|---|---|---|"; } >> "$summary"
expect_slots "after the installation" "systemd-recovery tpm2:temporary"

# Secure Boot: Microsoft keys, the UKI certificate and the add-on key as MOKs; the add-on, signed.
openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=Nyra CI add-on test key" \
  -keyout "$secrets/local.key" -out "$work/local.crt" 2>/dev/null
tools/vm/test-addon.sh "$image" "$work/console.addon.efi" systemd.import_credentials=yes "$secrets/local.key" "$work/local.crt"
virt-fw-vars --input /usr/share/OVMF/OVMF_VARS_4M.ms.fd --output "$work/vars.fd" \
  --add-mok 605dab50-e046-4300-abb6-3dd810dd8b23 "$uki_cert" \
  --add-mok 605dab50-e046-4300-abb6-3dd810dd8b23 "$work/local.crt"
loop="$(sudo losetup -P --show -f "$work/disk.raw")"
esp="$(tools/vm/esp-of.sh "$loop")"
sudo mount "$esp" "$mnt"
sudo mkdir -p "$mnt/loader/addons"
sudo cp "$work/console.addon.efi" "$mnt/loader/addons/nyra-test-console.addon.efi"
sudo umount "$mnt" && sudo losetup -d "$loop" && loop=""

# With a TPM the disk has no password: the prompt asks for the recovery key only.
ask="Please enter (passphrase or )?recovery key for disk [^\r\n]*:"
running='s="$(systemctl is-system-running --wait)"; echo "system: $s"; systemctl --no-pager --failed; test "$s" = running'
# Units that failed in this boot, the initrd included (systemctl --failed sees only the running system).
nofail='f="$(journalctl -b -o cat | grep -E "Failed to start|failed with result" || true)"; echo "${f:-no unit failed in this boot, the initrd included}"; test -z "$f"'
enrolled='journalctl -b -o cat -u nyra-tpm-enroll.service | grep nyra-tpm-enroll:'
vm() { # vm NAME TITLE ARGS...
  local name="$1" title="$2"
  shift 2
  python3 -B tools/vm/vm-boot.py --secure-boot "$work/vars.fd" --keep-vars --disk "$work/disk.raw" \
    --autologin --timeout 240 --log "$logs/serial-encryption-tpm-$name.log" --summary "$summary" \
    --title "$title" "$@"
}
asked() { # asked NAME: did the console of that boot ask for the disk?
  grep -q -a -E "Please enter (passphrase or )?recovery key for disk" "$logs/serial-encryption-tpm-$1.log"
}

vm first "TPM 1: the first boot unlocks by itself and enrolls the disk" --tpm "$tpm" --persist --poweroff \
  --command "$running" --command "$nofail" \
  --command "$enrolled && $enrolled | grep -q 'enrolled with the TPM'" || fail=1
! asked first || { echo "::error::the first boot asked for the disk"; fail=1; }
expect_slots "after the first boot" "systemd-recovery tpm2:pubkey-pcrs=11,ref=initrd,pcrs=7+12"
vm second "TPM 2: the next boot unlocks by itself, nothing to enroll" --tpm "$tpm" --persist --poweroff \
  --command "$running" --command "$nofail" --command "! $enrolled && echo 'nyra-tpm-enroll: nothing to do'" || fail=1
! asked second || { echo "::error::the second boot asked for the disk"; fail=1; }
vm no-tpm "TPM 3: without the TPM, the recovery key unlocks the disk" \
  --chat "$ask=>$key" --chat-then-login --command "$running" --command "$nofail" || fail=1
vm back "TPM 4: with the TPM back, the disk unlocks by itself again" --tpm "$tpm" \
  --command "$running" || fail=1
! asked back || { echo "::error::the boot with the TPM back asked for the disk"; fail=1; }
# A TPM that stops answering after the disk is unlocked: leave-initrd cannot be measured, so PCR 11
# would stay at the signed enter-initrd value in the running system. systemd-pcrphase-initrd's
# FailureAction=reboot-force reboots at once instead; no login prompt ever comes.
vm leave-initrd "TPM 5: the TPM fails before leave-initrd is measured: a forced reboot, no running system" \
  --tpm "$tpm" --tpm-fail-at 'Finished .{0,80}Cryptography Setup for root\.' --expect-reboot || fail=1
grep -q -a -i -E "(pcrphase-initrd|PCR Barrier \(initrd\)).*fail|fail.*(pcrphase-initrd|PCR Barrier \(initrd\))|Forcibly rebooting" \
  "$logs/serial-encryption-tpm-leave-initrd.log" ||
  { echo "::error::the forced reboot did not come from the failed leave-initrd measurement"; fail=1; }
vm after-fail "TPM 6: then, with the TPM answering again, the disk unlocks by itself" --tpm "$tpm" \
  --command "$running" || fail=1
! asked after-fail || { echo "::error::the boot after the TPM failure asked for the disk"; fail=1; }
expect_slots "at the end" "systemd-recovery tpm2:pubkey-pcrs=11,ref=initrd,pcrs=7+12"

# The recovery key nowhere outside the user's hands (grep -c reads to the end: with -q, head would end
# on SIGPIPE, which pipefail counts as a failure).
found=""
for f in "$logs"/serial-encryption-tpm-*.log "$summary"; do
  if grep -q -a -F -f "$secrets/patterns" "$f"; then found+=" $(basename "$f")"; fi
done
n="$(head -c $(((root_start + 32768) * 512)) "$work/disk.raw" | grep -c -a -F -f "$secrets/patterns" || true)"
[ "$n" = 0 ] || found+=" the unencrypted part of the disk"
loop="$(sudo losetup -P --show -f "$work/disk.raw")"
for _ in $(seq 50); do [ -b "${loop}p2" ] && break; udevadm settle --timeout=10 || true; sleep 0.2; done
inside="$(timeout 600 sudo podman run --rm -i --privileged --network none -e DM_DISABLE_UDEV=1 -v /dev:/dev -v "$secrets:/secrets:ro" "$image" \
  bash -s "${loop}p2" <<'EOF'
set -euo pipefail
cryptsetup open --readonly --key-file /secrets/recovery-key "$1" nyra-check-root
trap 'umount -q /target 2>/dev/null || true; cryptsetup close nyra-check-root' EXIT
mkdir -p /target && mount -o ro,noload /dev/mapper/nyra-check-root /target
test -n "$(find /target/state -name '*.journal' -print -quit)"
grep -r -l -a -F -f /secrets/patterns /target | sed 's|^/target|the root file system: |' || true
EOF
)" || inside="the root file system could not be checked"
sudo losetup -d "$loop" && loop=""
found+="${inside:+ $inside}"
if [ -n "$found" ]; then
  echo "::error::The recovery key was found in:$found"
  printf '| Recovery key | **found in:%s** | WRONG |\n\n' "$found" >> "$summary"
  fail=1
else
  printf '| Recovery key | not in the serial logs, the ESP and LUKS2 header, or the decrypted root file system | OK |\n\n' >> "$summary"
fi
exit "$fail"
