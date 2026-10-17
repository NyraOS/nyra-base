#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: Titanic T10, the TPM2 PIN (docs/BOOT.md, "Disk encryption"). Its own disk, installed for a
# TPM as in tools/vm/encryption-tpm.sh (a recovery key and a temporary TPM2 enrollment, swtpm, Secure
# Boot with the image's UKI certificate as a MOK), the test console add-on on the ESP. Then:
#   1. the first boot unlocks by itself and is enrolled without a PIN; tpm-pin refuses a PIN that is
#      not 6 to 20 digits and asks for one (a request only root can read);
#   2. the next boot unlocks by itself (no PIN yet) and its initrd enrolls the disk with that PIN, then
#      removes the request; read offline: the recovery key slot and two TPM2 enrollments with a PIN;
#   3. a wrong PIN, then the right one: unlocked, the recovery key never asked;
#   4. an empty PIN: the recovery key is asked, and unlocks the disk; not enrolled again (the add-on
#      is measured into PCR 12), the enrollment unchanged;
#   5. wrong PINs until the TPM locks itself (swtpm: 3 failures): the recovery key is asked, and
#      unlocks the disk;
#   6. while it is locked, the right PIN is refused too, and the recovery key unlocks the disk; then the
#      TPM's state from before row 3 comes back (as a TPM that recovered with time);
#   7. another PIN asked for, applied at the next boot (the old PIN typed); 8. no PIN asked for, applied
#      at the next boot (the PIN typed); read offline: two TPM2 enrollments without a PIN; 9. a PIN
#      again, applied at the next boot (nothing typed);
#   10-13. without the test console add-on (PCR 12 as a machine measures it), no login: PCR 12 no
#      longer the enrolled one (10) and a new TPM (12): the PIN typed, then the recovery key, then the
#      initrd asks for a new PIN (12: a wrong one first) and enrolls the disk with it; the next boot
#      (11, 13) unlocks with the new PIN, the recovery key never asked;
#   14. the disk's journal: the PINs applied, the two re-enrollments with a PIN; read offline: two TPM2
#      enrollments with a PIN;
#   15. the recovery key and the PINs typed only at prompts (rows 10 to 13) are nowhere in the serial
#      logs, in the unencrypted part of the disk or in the decrypted root file system.
# The PINs typed in the commands (rows 1, 6, 7, 8) are in the serial logs: they are test PINs.
#   tools/vm/encryption-pin.sh IMAGE UKI_CERT WORKDIR LOGDIR SUMMARY
set -euo pipefail

image="$1" uki_cert="$2" work="$3/encryption-pin" logs="$4" summary="$5"
# swtpm's state under LOGDIR (RUNNER_TEMP): Ubuntu's AppArmor profile for swtpm allows no other place.
tpm="$logs/encryption-pin-state" saved="$logs/encryption-pin-saved"
secrets="$work/secrets"
mnt="$work/esp"
loop=""
mkdir -p "$work" "$tpm" "$mnt"
mkdir -m 0700 "$secrets"
trap 'sudo umount -q "$mnt" 2>/dev/null || true; [ -z "$loop" ] || sudo losetup -d "$loop" || true; sudo rm -rf "$secrets" "$tpm" "$saved" "$work"' EXIT

start=$SECONDS
tools/vm/install-encrypted.sh "$image" "$work" "$secrets" "$tpm"
key="$(cat "$secrets/recovery-key")"
# Five PINs and a wrong one, 20 random digits each (nothing else on the console looks like them).
pins=()
for _ in 1 2 3 4 5 6; do pins+=("$(python3 -I -c 'import secrets; print("".join(secrets.choice("0123456789") for _ in range(20)))')"); done
pin1="${pins[0]}" pin2="${pins[1]}" pin3="${pins[2]}" pin4="${pins[3]}" pin5="${pins[4]}" wrong="${pins[5]}"
printf '%s\n' "$key" "$pin4" "$pin5" > "$secrets/patterns"
{
  echo "## Disk encryption with a TPM and a PIN (Titanic T10)"
  echo
  echo "Installed on LUKS2 with a recovery key and a temporary TPM2 enrollment (tools/vm/install-encrypted.sh), $((SECONDS - start)) s; swtpm, Secure Boot on."
  echo
} >> "$summary"

# The LUKS2 header, read offline: the key slots and tokens, as "TYPE:what" words.
root_start="$(sfdisk -J "$work/disk.raw" | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["partitiontable"]["partitions"][1]["start"])')"
header() { # the LUKS2 header's JSON metadata
  dd if="$work/disk.raw" of="$work/header" bs=512 skip="$root_start" count=32768 status=none
  sudo podman run --rm --network none -v "$work/header:/header:ro" "$image" \
    cryptsetup luksDump --dump-json-metadata /header
}
slots() {
  header | python3 -I -c '
import json, sys
h = json.load(sys.stdin)
out, used = [], set()
for t in h["tokens"].values():
    used.update(t["keyslots"])
    if t["type"] == "systemd-tpm2" and t["tpm2-policy-hash"] == "0" * 64:
        out.append("tpm2:temporary")
    elif t["type"] == "systemd-tpm2":
        out.append("tpm2:pubkey-pcrs=%s,ref=%s,pcrs=%s%s" % (
            "+".join(map(str, t.get("tpm2_pubkey_pcrs", []))), t.get("tpm2_pubkey_ref", "none"),
            "+".join(map(str, t.get("tpm2-pcrs", []))), ",pin" if t.get("tpm2-pin") else ""))
    else:
        out.append(t["type"])
out += ["slot-without-token"] * len(set(h["keyslots"]) - used)
print(" ".join(sorted(out)))'
}
policy() { # the TPM2 enrollments (their sealed blobs and policies), from the header
  header | python3 -I -c '
import json, sys
import hashlib
print(" ".join(hashlib.sha256((t["tpm2-blob"] + t["tpm2-policy-hash"]).encode()).hexdigest()[:16]
               for t in json.load(sys.stdin)["tokens"].values() if t["type"] == "systemd-tpm2"))'
}
fail=0
check() { # check WHAT EXPECTED GOT
  local mark=OK
  if [ "$2" != "$3" ]; then mark=WRONG; fail=1; fi
  echo "encryption-pin: $1: expected $2, got $3 [$mark]"
  printf '| %s | `%s` | %s |\n' "$1" "$3" "$mark" >> "$summary"
}
{ echo "| Check | Result | |"; echo "|---|---|---|"; } >> "$summary"
enrolled="tpm2:pubkey-pcrs=11,ref=initrd,pcrs=7+12"
check "Key slots after the installation" "systemd-recovery tpm2:temporary" "$(slots)"

# Secure Boot: Microsoft keys, the UKI certificate and the add-on key as MOKs; the add-on, signed.
openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=Nyra CI add-on test key" \
  -keyout "$secrets/local.key" -out "$work/local.crt" 2>/dev/null
tools/vm/test-addon.sh "$image" "$work/console.addon.efi" systemd.import_credentials=yes "$secrets/local.key" "$work/local.crt"
virt-fw-vars --input /usr/share/OVMF/OVMF_VARS_4M.ms.fd --output "$work/vars.fd" \
  --add-mok 605dab50-e046-4300-abb6-3dd810dd8b23 "$uki_cert" \
  --add-mok 605dab50-e046-4300-abb6-3dd810dd8b23 "$work/local.crt"
esp() { # esp add|remove: the test console add-on on the ESP (loader/addons)
  loop="$(sudo losetup -P --show -f "$work/disk.raw")"
  sudo mount "$(tools/vm/esp-of.sh "$loop")" "$mnt"
  if [ "$1" = add ]; then
    sudo mkdir -p "$mnt/loader/addons"
    sudo cp "$work/console.addon.efi" "$mnt/loader/addons/nyra-test-console.addon.efi"
  else
    sudo rm "$mnt/loader/addons/nyra-test-console.addon.efi"
  fi
  sudo umount "$mnt" && sudo losetup -d "$loop" && loop=""
}
esp add

# The prompts: systemd-cryptsetup's for the PIN and for the disk, nyra-tpm-enroll's for a new PIN.
pinask="Please enter TPM2 PIN:"
ask="Please enter (passphrase or )?recovery key for disk [^\r\n]*:"
either="($pinask|$ask)"
choose="Choose a TPM2 PIN for the disk"
again="Type the same PIN again:"
running='s="$(systemctl is-system-running --wait)"; echo "system: $s"; systemctl --no-pager --failed; test "$s" = running'
log='journalctl -b -o cat -u nyra-tpm-enroll.service | grep nyra-tpm-enroll:'
tpmpin=/usr/lib/nyra/boot/tpm-pin
status() { echo "test \"\$($tpmpin status | tr '\n' ' ')\" = \"$1 \" && echo 'tpm-pin status: $1'"; }
locked='journalctl -b -o cat -u systemd-cryptsetup@root.service | grep "dictionary attack lock-out"'
# The PIN and the typed key are gone from /run and the kernel's cache once the system runs.
gone='test ! -e /run/nyra-tpm-pin && ! keyctl search @u user tpm2-pin && ! keyctl search @u user cryptsetup && echo "no PIN or key left"'
vm() { # vm NAME TITLE ARGS...
  local name="$1" title="$2"
  shift 2
  python3 -B tools/vm/vm-boot.py --secure-boot "$work/vars.fd" --keep-vars --disk "$work/disk.raw" \
    --tpm "$tpm" --persist --poweroff --autologin --timeout 240 \
    --log "$logs/serial-encryption-pin-$name.log" --summary "$summary" --title "$title" "$@"
}
blind() { # blind NAME TITLE ARGS...
  local name="$1" title="$2"
  shift 2
  python3 -B tools/vm/vm-boot.py --secure-boot "$work/vars.fd" --keep-vars --disk "$work/disk.raw" \
    --tpm "$tpm" --persist --blind --timeout 300 \
    --log "$logs/serial-encryption-pin-$name.log" --summary "$summary" --title "$title" "$@"
}
asked() { # asked NAME: did the console of that boot ask for the disk's recovery key?
  grep -q -a -E "Please enter (passphrase or )?recovery key for disk" "$logs/serial-encryption-pin-$1.log"
}
pinasked() { grep -q -a -F "$pinask" "$logs/serial-encryption-pin-$1.log"; }

vm first "PIN 1: the first boot unlocks by itself; tpm-pin asks for a PIN" \
  --command "$running" --command "$log | grep -q 'enrolled with the TPM'" --command "$(status "pin no")" \
  --command "r=refused; for p in 12345 123456789012345678901 12a4567 ''; do echo \"\$p\" | $tpmpin set && r=accepted; done; test \$r = refused && test ! -e /var/lib/nyra/tpm2-pin-request && echo 'refused: 5 digits, 21, a letter, empty'" \
  --command "echo $pin1 | $tpmpin set && test \"\$(stat -c '%a %U' /var/lib/nyra/tpm2-pin-request)\" = '600 root'" \
  --command "$(status "pin no requested pin")" || fail=1
vm pin-set "PIN 2: the next boot unlocks by itself, and its initrd enrolls the disk with the PIN" \
  --command "$running" --command "$log | grep 'with the new PIN'" --command "test ! -e /var/lib/nyra/tpm2-pin-request" \
  --command "$(status "pin yes")" --command "$gone" || fail=1
! asked pin-set && ! pinasked pin-set || { echo "::error::the boot that enrolls the PIN asked for something"; fail=1; }
check "Key slots with the PIN" "systemd-recovery $enrolled,pin $enrolled,pin" "$(slots)"
before="$(policy)"
sudo rm -rf "$saved" && sudo cp -a "$tpm" "$saved"
vm wrong "PIN 3: a wrong PIN, then the right one: unlocked" \
  --chat "$pinask=>$wrong" --chat "$pinask=>$pin1" --chat-then-login --command "$running" --command "$gone" || fail=1
! asked wrong || { echo "::error::the recovery key was asked after a wrong PIN"; fail=1; }
# An empty PIN goes to the recovery key; the PIN is asked once per TPM2 enrollment that may need it,
# so the second answer goes to whichever prompt comes (an empty recovery key is asked again).
vm empty "PIN 4: an empty PIN: the recovery key unlocks the disk, not enrolled again (the add-on)" \
  --chat "$pinask=>" --chat "$either=>" --chat "$ask=>$key" --chat-then-login --command "$running" \
  --command "$log | grep 'not enrolled with the TPM again: this boot measured an add-on'" --command "$gone" || fail=1
check "The enrollment, unchanged by rows 3 and 4" "$before" "$(policy)"
# From the TPM's state before row 3 (no failure counted): three wrong PINs lock it, the fourth is
# refused at once. The fourth answer goes to whichever prompt comes.
sudo rm -rf "$tpm" && sudo cp -a "$saved" "$tpm"
vm lockout "PIN 5: wrong PINs until the TPM locks itself: the recovery key unlocks the disk" \
  --chat "$pinask=>$wrong" --chat "$pinask=>$wrong" --chat "$pinask=>$wrong" --chat "$either=>$wrong" \
  --chat "$ask=>$key" --chat-then-login --command "$running" --command "$locked" || fail=1
vm locked "PIN 6: while the TPM is locked, the right PIN is refused and the recovery key unlocks the disk" \
  --chat "$pinask=>$pin1" --chat "$either=>" --chat "$ask=>$key" --chat-then-login --command "$running" \
  --command "$locked" --command "echo $pin2 | $tpmpin set" || fail=1
check "The enrollment, unchanged by rows 5 and 6" "$before" "$(policy)"
sudo rm -rf "$tpm" && sudo cp -a "$saved" "$tpm"
vm change "PIN 7: another PIN, applied with the old one typed" \
  --chat "$pinask=>$pin1" --chat-then-login --command "$running" --command "$log | grep 'with the new PIN'" \
  --command "$(status "pin yes")" --command "$gone" --command "$tpmpin remove" || fail=1
vm remove "PIN 8: no PIN, applied with the PIN typed" \
  --chat "$pinask=>$pin2" --chat-then-login --command "$running" --command "$log | grep 'without a PIN'" \
  --command "$(status "pin no")" --command "$gone" --command "echo $pin3 | $tpmpin set" || fail=1
check "Key slots without the PIN" "systemd-recovery $enrolled $enrolled" "$(slots)"
vm set-again "PIN 9: a PIN again, applied in a boot that unlocked by itself" \
  --command "$running" --command "$log | grep 'with the new PIN'" --command "$(status "pin yes")" || fail=1
! asked set-again && ! pinasked set-again || { echo "::error::the boot without a PIN asked for something"; fail=1; }

# Without the test console add-on: PCR 12 is no longer the enrolled one.
esp remove
before="$(policy)"
blind clean "PIN 10: PCR 12 changed: the PIN, then the recovery key, then a new PIN chosen in the initrd" \
  --chat "$pinask=>$pin3" --chat "$ask=>$key" --chat "$choose=>$pin4" --chat "$again=>$pin4" || fail=1
check "The enrollment after PCR 12 changed" new "$(if [ "$(policy)" != "$before" ]; then echo new; else echo same; fi)"
blind clean-after "PIN 11: then the new PIN unlocks the disk" --chat "$pinask=>$pin4" || fail=1
! asked clean-after || { echo "::error::the recovery key was asked with the new PIN"; fail=1; }
# A cleared or replaced TPM: a new one.
sudo rm -rf "$tpm" && mkdir -p "$tpm"
before="$(policy)"
blind new-tpm "PIN 12: a new TPM: the PIN, the recovery key, a PIN that is too short, then a new PIN" \
  --chat "$pinask=>$pin4" --chat "$ask=>$key" --chat "$choose=>12345" --chat "$choose=>$pin5" \
  --chat "$again=>$pin5" || fail=1
check "The enrollment with the new TPM" new "$(if [ "$(policy)" != "$before" ]; then echo new; else echo same; fi)"
blind new-tpm-after "PIN 13: then the new PIN unlocks the disk" --chat "$pinask=>$pin5" || fail=1
! asked new-tpm-after || { echo "::error::the recovery key was asked with the new PIN"; fail=1; }

# The disk's journal (all boots), read with the recovery key.
loop="$(sudo losetup -P --show -f "$work/disk.raw")"
for _ in $(seq 50); do [ -b "${loop}p2" ] && break; udevadm settle --timeout=10 || true; sleep 0.2; done
lines="$(timeout 600 sudo podman run --rm -i --privileged --network none -e DM_DISABLE_UDEV=1 -v /dev:/dev -v "$secrets:/secrets:ro" "$image" \
  bash -s "${loop}p2" <<'EOF' || true
set -euo pipefail
cryptsetup open --readonly --key-file /secrets/recovery-key "$1" nyra-check-root
trap 'umount -q /target 2>/dev/null || true; cryptsetup close nyra-check-root' EXIT
mkdir -p /target && mount -o ro,noload /dev/mapper/nyra-check-root /target
journalctl --directory="$(dirname "$(find /target/state -name 'system.journal' -print -quit)")" -o cat \
  -u nyra-tpm-enroll.service --no-pager | grep nyra-tpm-enroll:
EOF
)"
sudo losetup -d "$loop" && loop=""
printf '%s\n' "$lines"
check "PINs applied in the disk's journal (rows 2, 7, 9)" 3 "$(printf '%s\n' "$lines" | grep -c 'enrolled with the TPM with the new PIN' || true)"
check "Re-enrollments with a PIN in the disk's journal (rows 10, 12)" 2 "$(printf '%s\n' "$lines" | grep -c 'enrolled with the TPM again, with a PIN' || true)"
check "Key slots at the end" "systemd-recovery $enrolled,pin $enrolled,pin" "$(slots)"

# The recovery key and the PINs typed only at prompts nowhere outside the user's hands (grep -c reads
# to the end: with -q, head would end on SIGPIPE, which pipefail counts as a failure).
found=""
for f in "$logs"/serial-encryption-pin-*.log "$summary"; do
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
  echo "::error::The recovery key or a PIN was found in:$found"
  printf '| Recovery key and PINs | **found in:%s** | WRONG |\n\n' "$found" >> "$summary"
  fail=1
else
  printf '| Recovery key and PINs typed at prompts | not in the serial logs, the ESP and LUKS2 header, or the decrypted root file system | OK |\n\n' >> "$summary"
fi
exit "$fail"
