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
#      reboot (FailureAction=reboot-force of systemd-pcrphase-initrd), never a running system;
#   6. then it unlocks by itself again;
#   7. Secure Boot off (PCR 7): the recovery key unlocks it, and it is not enrolled again (7 and 10:
#      the typed key is no longer in the kernel's cache once the system runs);
#   8. with Secure Boot on again it unlocks by itself (the old enrollment);
#   9. the recovery profile asks for the disk;
#   10. one more add-on (PCR 12): the recovery key unlocks it, and it is not enrolled again;
#   11. without that add-on it unlocks by itself;
#   12-17. without the test console add-on (PCR 12 as a machine measures it), without a login: each
#      time the TPM refuses (12: PCR 12 no longer the enrolled one, 14: a new Secure Boot database,
#      PCR 7, 16: a new TPM), the recovery key typed at the prompt unlocks the disk and its initrd
#      enrolls it again (read offline: a new enrollment, and the journal); the boot after each (13, 15,
#      17) unlocks by itself;
#   18. a disk set up with a password, whose header got a forged TPM2 token (a copy of the one above,
#      pointing at the password's key slot), is not enrolled when the password is typed on this
#      machine with its TPM and Secure Boot, and no key slot is removed;
#   19. the recovery key is nowhere in the serial logs, in the unencrypted part of the disk or in the
#      decrypted root file system.
# A boot that should unlock by itself fails if the console ever asks for the disk (blind: if the guest
# does not power off on the power button, which only a booted system does). The test console add-on
# (tools/vm/test-console.sh) is signed with a key made here and enrolled as a MOK; it is measured into
# PCR 12 at every boot it is there, the first one included, so it is part of the first enrollment, and
# a boot with it is never enrolled again (rows 5 to 9 check what refuses first).
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
check() { # check WHAT EXPECTED GOT
  local mark=OK
  if [ "$2" != "$3" ]; then mark=WRONG; fail=1; fi
  echo "encryption-tpm: $1: expected $2, got $3 [$mark]"
  printf '| %s | `%s` | %s |\n' "$1" "$3" "$mark" >> "$summary"
}
policy() { # the TPM2 enrollment (its sealed blob and policy), from the header
  dd if="$work/disk.raw" of="$work/header" bs=512 skip="$root_start" count=32768 status=none
  sudo podman run --rm --network none -v "$work/header:/header:ro" "$image" \
    cryptsetup luksDump --dump-json-metadata /header | python3 -I -c '
import json, sys
import hashlib
print(" ".join(hashlib.sha256((t["tpm2-blob"] + t["tpm2-policy-hash"]).encode()).hexdigest()[:16]
               for t in json.load(sys.stdin)["tokens"].values() if t["type"] == "systemd-tpm2"))'
}
addon() { # addon add NAME FILE | addon remove NAME: an add-on for every UKI, on the ESP (loader/addons)
  loop="$(sudo losetup -P --show -f "$work/disk.raw")"
  sudo mount "$(tools/vm/esp-of.sh "$loop")" "$mnt"
  if [ "$1" = add ]; then sudo cp "$3" "$mnt/loader/addons/$2"; else sudo rm "$mnt/loader/addons/$2"; fi
  sudo umount "$mnt" && sudo losetup -d "$loop" && loop=""
}
journal() { # nyra-tpm-enroll's and systemd-cryptsetup's lines in the disk's journal (all boots), read with the recovery key
  loop="$(sudo losetup -P --show -f "$work/disk.raw")"
  for _ in $(seq 50); do [ -b "${loop}p2" ] && break; udevadm settle --timeout=10 || true; sleep 0.2; done
  timeout 600 sudo podman run --rm -i --privileged --network none -e DM_DISABLE_UDEV=1 -v /dev:/dev -v "$secrets:/secrets:ro" "$image" \
    bash -s "${loop}p2" <<'EOF' || true
set -euo pipefail
cryptsetup open --readonly --key-file /secrets/recovery-key "$1" nyra-check-root
trap 'umount -q /target 2>/dev/null || true; cryptsetup close nyra-check-root' EXIT
mkdir -p /target && mount -o ro,noload /dev/mapper/nyra-check-root /target
journalctl --directory="$(dirname "$(find /target/state -name 'system.journal' -print -quit)")" -o cat \
  -u nyra-tpm-enroll.service -u systemd-cryptsetup@root.service --no-pager
EOF
  sudo losetup -d "$loop" && loop=""
}
{ echo "| Check | Result | |"; echo "|---|---|---|"; } >> "$summary"
expect_slots "after the installation" "systemd-recovery tpm2:temporary"

# Secure Boot: Microsoft keys, the UKI certificate and the add-on key as MOKs; the add-on, signed.
openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=Nyra CI add-on test key" \
  -keyout "$secrets/local.key" -out "$work/local.crt" 2>/dev/null
tools/vm/test-addon.sh "$image" "$work/console.addon.efi" systemd.import_credentials=yes "$secrets/local.key" "$work/local.crt"
tools/vm/test-addon.sh "$image" "$work/extra.addon.efi" nyra.test-addon=1 "$secrets/local.key" "$work/local.crt"
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
vm back "TPM 4: with the TPM back, the disk unlocks by itself again" --tpm "$tpm" --persist --poweroff \
  --command "$running" || fail=1
! asked back || { echo "::error::the boot with the TPM back asked for the disk"; fail=1; }
# A TPM that stops answering after the disk is unlocked: leave-initrd cannot be measured, so PCR 11
# would stay at the signed enter-initrd value in the running system. systemd-pcrphase-initrd's
# FailureAction=reboot-force reboots at once instead; no login prompt ever comes.
vm leave-initrd "TPM 5: the TPM fails before leave-initrd is measured: a forced reboot, no running system" \
  --tpm "$tpm" --tpm-fail-at 'Finished .{0,80}Cryptography Setup for root\.' --expect-reboot || fail=1
# The console shortens the unit's name: "Forcibly rebooting: unit systemd-pc…d.service failed".
LC_ALL=C grep -q -a -E "Forcibly rebooting: unit systemd-pc(rphase-initrd|.{1,3}d)\.service failed" \
  "$logs/serial-encryption-tpm-leave-initrd.log" ||
  { echo "::error::the forced reboot did not come from the failed leave-initrd measurement"; fail=1; }
vm after-fail "TPM 6: then, with the TPM answering again, the disk unlocks by itself" --tpm "$tpm" \
  --command "$running" || fail=1
! asked after-fail || { echo "::error::the boot after the TPM failure asked for the disk"; fail=1; }

# After the TPM refused: enrolled again only with Secure Boot on and nothing measured into PCR 12.
notagain='journalctl -b -o cat -u nyra-tpm-enroll.service | grep "not enrolled with the TPM again: '
# The key typed at the prompt is no longer in the kernel's cache in the running system.
nocache='! keyctl search @u user cryptsetup && echo "the typed key is not in the kernel cache"'
before="$(policy)"
python3 -B tools/vm/vm-boot.py --tpm "$tpm" --disk "$work/disk.raw" --persist --poweroff --autologin --timeout 240 \
  --log "$logs/serial-encryption-tpm-sb-off.log" --summary "$summary" \
  --title "TPM 7: Secure Boot off (PCR 7): the recovery key unlocks the disk, no new enrollment" \
  --chat "$ask=>$key" --chat-then-login --command "$running" --command "${notagain}Secure Boot is off\"" \
  --command "$nocache" || fail=1
vm sb-on "TPM 8: Secure Boot on again, the disk unlocks by itself (the old enrollment)" --tpm "$tpm" \
  --persist --poweroff --command "$running" \
  --command 'bootctl set-oneshot nyra-recovery.CONF && bootctl list --no-pager | grep -A3 "Nyra OS Recovery"' || fail=1
! asked sb-on || { echo "::error::the boot with Secure Boot on again asked for the disk"; fail=1; }
vm recovery "TPM 9: the recovery profile asks for the disk (not in the signed policy)" --tpm "$tpm" --persist \
  --refused "Please enter (passphrase or )?recovery key for disk" || fail=1
addon add nyra-test-extra.addon.efi "$work/extra.addon.efi"
vm addon "TPM 10: an add-on more (PCR 12): the recovery key unlocks the disk, no new enrollment" --tpm "$tpm" \
  --persist --poweroff --chat "$ask=>$key" --chat-then-login --command "$running" \
  --command "${notagain}this boot measured an add-on\"" --command "$nocache" || fail=1
addon remove nyra-test-extra.addon.efi
vm no-addon "TPM 11: without that add-on, the disk unlocks by itself" --tpm "$tpm" --persist --poweroff \
  --command "$running" || fail=1
! asked no-addon || { echo "::error::the boot without the extra add-on asked for the disk"; fail=1; }
check "the enrollment, unchanged by rows 7 to 11" "$before" "$(policy)"

# Without the test console add-on (it is measured into PCR 12, which stops a new enrollment) there is
# no login: the recovery key is typed at the prompt, the guest must power off on the power button
# (only a booted system does), and the result is read offline.
addon remove nyra-test-console.addon.efi
blind() { # blind NAME TITLE ARGS...
  local name="$1" title="$2"
  shift 2
  python3 -B tools/vm/vm-boot.py --secure-boot "$work/vars.fd" --keep-vars --disk "$work/disk.raw" --persist \
    --blind --timeout 300 --log "$logs/serial-encryption-tpm-$name.log" --summary "$summary" \
    --title "$title" "$@"
}
# Without the add-on PCR 12 is what a machine measures, no longer the enrolled value.
before="$(policy)"
blind clean "TPM 12: without the test add-on (PCR 12): the recovery key typed, the disk enrolled again" \
  --tpm "$tpm" --chat "$ask=>$key" || fail=1
check "the enrollment without the add-on" new "$(if [ "$(policy)" != "$before" ]; then echo new; else echo same; fi)"
blind clean-after "TPM 13: then the disk unlocks by itself (nothing typed)" --tpm "$tpm" || fail=1
# A firmware update of the Secure Boot database: PCR 7 changes, Secure Boot stays on.
virt-fw-vars --inplace "$work/vars.fd" --add-db 605dab50-e046-4300-abb6-3dd810dd8b23 "$work/local.crt"
before="$(policy)"
blind pcr7 "TPM 14: a new Secure Boot database (PCR 7): the recovery key typed, the disk enrolled again" \
  --tpm "$tpm" --chat "$ask=>$key" || fail=1
check "the enrollment after the new database" new "$(if [ "$(policy)" != "$before" ]; then echo new; else echo same; fi)"
blind pcr7-after "TPM 15: then the disk unlocks by itself (nothing typed)" --tpm "$tpm" || fail=1
# A cleared or replaced TPM: a new one, whose storage root key never sealed anything.
sudo rm -rf "$tpm" && mkdir -p "$tpm"
before="$(policy)"
blind new-tpm "TPM 16: a new TPM: the recovery key typed, the disk enrolled again" \
  --tpm "$tpm" --chat "$ask=>$key" || fail=1
check "the enrollment with the new TPM" new "$(if [ "$(policy)" != "$before" ]; then echo new; else echo same; fi)"
blind new-tpm-after "TPM 17: then the disk unlocks by itself (nothing typed)" --tpm "$tpm" || fail=1
lines="$(journal)"
printf '%s\n' "$lines"
check "\"Could not extend PCR/NvPCR\" in the disk's journal (rows 1 to 17)" 0 "$(printf '%s\n' "$lines" | grep -c 'Could not extend' || true)"
check "re-enrollments in the disk's journal (rows 12, 14, 16)" 3 "$(printf '%s\n' "$lines" | grep -c 'enrolled with the TPM again, after the TPM refused' || true)"
expect_slots "at the end" "systemd-recovery tpm2:pubkey-pcrs=11,ref=initrd,pcrs=7+12"

# A disk set up with a password, on this machine with its TPM and Secure Boot, whose header someone
# changed while it was off: a copy of the TPM2 enrollment of the disk above, pointing at its password
# key slot. LUKS2 tokens are not authenticated, so the header cannot say whether a disk is enrolled
# for the TPM; the record inside the encrypted root does, and this disk has none. Typing the password
# must not enroll it, nor remove any key slot.
pw="$work/pw"
mkdir -m 0700 "$pw" "$pw/secrets"
python3 -I -c 'import secrets, string; print("".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(20)), end="")' \
  > "$pw/secrets/password"
tools/vm/install-encrypted.sh "$image" "$pw" "$pw/secrets"
dd if="$work/disk.raw" of="$work/header" bs=512 skip="$root_start" count=32768 status=none
sudo podman run --rm --network none -v "$work/header:/header:ro" "$image" \
  cryptsetup luksDump --dump-json-metadata /header | python3 -I -c '
import json, sys
t = [t for t in json.load(sys.stdin)["tokens"].values() if t["type"] == "systemd-tpm2"][0]
t["keyslots"] = ["0"]
print(json.dumps(t))' > "$pw/secrets/forged.json"
loop="$(sudo losetup -P --show -f "$pw/disk.raw")"
for _ in $(seq 50); do [ -b "${loop}p2" ] && break; udevadm settle --timeout=10 || true; sleep 0.2; done
sudo podman run --rm --privileged --network none -v /dev:/dev -v "$pw/secrets:/secrets:ro" "$image" \
  cryptsetup token import --json-file /secrets/forged.json "${loop}p2"
pwslots() { # the password disk's key slots and tokens, from its header
  sudo podman run --rm --privileged --network none -v /dev:/dev "$image" cryptsetup luksDump --dump-json-metadata "${loop}p2" |
    python3 -I -c 'import json, sys; h = json.load(sys.stdin); print(sorted(h["keyslots"]), sorted((t["type"], t["keyslots"][0]) for t in h["tokens"].values()))'
}
before="$(pwslots)"
sudo mount "$(tools/vm/esp-of.sh "$loop")" "$mnt"
sudo mkdir -p "$mnt/loader/addons"
sudo cp "$work/console.addon.efi" "$mnt/loader/addons/nyra-test-console.addon.efi"
sudo umount "$mnt" && sudo losetup -d "$loop" && loop=""
vm forged "TPM 18: a password disk with a forged TPM2 token, on a machine with a TPM and Secure Boot: not enrolled" \
  --tpm "$tpm" --disk "$pw/disk.raw" --persist --poweroff \
  --chat "$ask=>$(cat "$pw/secrets/password")" --chat-then-login --command "$running" \
  --command "! journalctl -b -o cat -u nyra-tpm-enroll.service | grep nyra-tpm-enroll: && echo 'nyra-tpm-enroll: nothing done' && test ! -e /var/lib/nyra/tpm2-slots" || fail=1
loop="$(sudo losetup -P --show -f "$pw/disk.raw")"
for _ in $(seq 50); do [ -b "${loop}p2" ] && break; udevadm settle --timeout=10 || true; sleep 0.2; done
check "the password disk's key slots and tokens after that boot" "$before" "$(pwslots)"
sudo losetup -d "$loop" && loop=""
sudo rm -rf "$pw"

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
