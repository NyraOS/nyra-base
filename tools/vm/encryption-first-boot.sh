#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: Titanic T10, the first boot of a disk installed for a TPM that does not find the TPM, or
# finds Secure Boot off (docs/BOOT.md, "Disk encryption"), as when the firmware settings change
# between the installation and the first boot. Each case on its own disk and TPM (swtpm), installed
# for that TPM as tools/vm/encryption-tpm.sh does it (a recovery key, a temporary TPM2 enrollment
# without any policy and an empty record of the enrollments inside the encrypted root), the test
# console add-on (signed with a key made here, a MOK) on the ESP until the TPM and Secure Boot are back.
#   no-tpm  1. the first boot, Secure Boot on, without the TPM: the disk asks for its recovery key,
#              which unlocks it; nothing is enrolled ("no TPM"), the temporary enrollment is removed,
#              the typed key is no longer in the kernel's cache, no unit failed; read offline: only the
#              recovery key slot;
#   sb-off  1. the first boot, with the TPM, Secure Boot off: it unlocks through the temporary
#              enrollment (it has no policy, docs/BOOT.md, "Known limits"); nothing is enrolled
#              ("Secure Boot is off"), the temporary enrollment is removed; read offline: only the
#              recovery key slot;
#           1b. the next boot, still with Secure Boot off: the disk asks for its recovery key, which
#              unlocks it; not enrolled ("Secure Boot is off"), the key not in the cache; only the
#              recovery key slot;
# then, in both cases, without the test console add-on (PCR 12 as a machine measures it), no login:
#   2. the TPM and Secure Boot back: the disk asks for its recovery key once, and its initrd enrolls
#      it (read offline: the recovery key slot and the two TPM2 enrollments of a first boot);
#   3. the next boot unlocks by itself (nothing typed);
#   4. read offline: the record (two enrollments) and the lines of nyra-tpm-enroll in the disk's
#      journal; the recovery key nowhere in the serial logs, in the unencrypted part of the disk or in
#      the decrypted root file system.
#   tools/vm/encryption-first-boot.sh IMAGE UKI_CERT WORKDIR LOGDIR SUMMARY
set -euo pipefail

image="$1" uki_cert="$2" top="$3/encryption-first-boot" logs="$4" summary="$5"
mkdir -p "$top"
loop="" mnt="$top/esp"
mkdir -p "$mnt"
trap 'sudo umount -q "$mnt" 2>/dev/null || true; [ -z "$loop" ] || sudo losetup -d "$loop" || true; sudo rm -rf "$top" "$logs"/encryption-first-boot-*-state' EXIT

# Secure Boot: Microsoft keys, the UKI certificate and the add-on key as MOKs; the add-on, signed.
keys="$top/keys"
mkdir -m 0700 "$keys"
openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=Nyra CI add-on test key" \
  -keyout "$keys/local.key" -out "$top/local.crt" 2>/dev/null
tools/vm/test-addon.sh "$image" "$top/console.addon.efi" systemd.import_credentials=yes "$keys/local.key" "$top/local.crt"
rm -rf "$keys"

ask="Please enter (passphrase or )?recovery key for disk [^\r\n:]*:"
running='s="$(systemctl is-system-running --wait)"; echo "system: $s"; systemctl --no-pager --failed; test "$s" = running'
# Units that failed in this boot, the initrd included (systemctl --failed sees only the running system).
nofail='f="$(journalctl -b -o cat | grep -E "Failed to start|failed with result" || true)"; echo "${f:-no unit failed in this boot, the initrd included}"; test -z "$f"'
said='journalctl -b -o cat -u nyra-tpm-enroll.service | grep -F'
nocache='! keyctl search @u user cryptsetup && echo "the typed key is not in the kernel cache"'
empty='test -f /var/lib/nyra/tpm2-slots && test ! -s /var/lib/nyra/tpm2-slots && echo "the record: there, empty"'
fail=0
{ echo "## The first boot without a TPM or with Secure Boot off (Titanic T10)"; echo; } >> "$summary"

first_boot() { # first_boot no-tpm|sb-off
  local mode="$1" work="$top/$1" tpm="$logs/encryption-first-boot-$1-state" secrets key root_start
  secrets="$work/secrets"
  mkdir -p "$work" "$tpm"
  mkdir -m 0700 "$secrets"
  tools/vm/install-encrypted.sh "$image" "$work" "$secrets" "$tpm"
  key="$(cat "$secrets/recovery-key")"
  printf '%s\n' "$key" > "$secrets/patterns"
  root_start="$(sfdisk -J "$work/disk.raw" | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["partitiontable"]["partitions"][1]["start"])')"
  virt-fw-vars --input /usr/share/OVMF/OVMF_VARS_4M.ms.fd --output "$work/vars.fd" \
    --add-mok 605dab50-e046-4300-abb6-3dd810dd8b23 "$uki_cert" \
    --add-mok 605dab50-e046-4300-abb6-3dd810dd8b23 "$top/local.crt"
  addon() { # addon add|remove: the test console add-on on the ESP (loader/addons)
    loop="$(sudo losetup -P --show -f "$work/disk.raw")"
    sudo mount "$(tools/vm/esp-of.sh "$loop")" "$mnt"
    if [ "$1" = add ]; then
      sudo mkdir -p "$mnt/loader/addons"
      sudo cp "$top/console.addon.efi" "$mnt/loader/addons/nyra-test-console.addon.efi"
    else
      sudo rm "$mnt/loader/addons/nyra-test-console.addon.efi"
    fi
    sudo umount "$mnt" && sudo losetup -d "$loop" && loop=""
  }
  slots() { # the key slots and tokens of the LUKS2 header, read offline, as words
    dd if="$work/disk.raw" of="$work/header" bs=512 skip="$root_start" count=32768 status=none
    sudo podman run --rm --network none -v "$work/header:/header:ro" "$image" \
      cryptsetup luksDump --dump-json-metadata /header | python3 -I -c '
import json, sys
h = json.load(sys.stdin)
out, used = [], set()
for t in h["tokens"].values():
    used.update(t["keyslots"])
    if t["type"] == "systemd-tpm2":
        out.append("tpm2:temporary" if t["tpm2-policy-hash"] == "0" * 64 else "tpm2:pubkey-pcrs=%s,ref=%s,pcrs=%s" % (
            "+".join(map(str, t.get("tpm2_pubkey_pcrs", []))), t.get("tpm2_pubkey_ref", "none"),
            "+".join(map(str, t.get("tpm2-pcrs", [])))))
    else:
        out.append(t["type"])
out += ["slot-without-token"] * len(set(h["keyslots"]) - used)
print(" ".join(sorted(out)))'
  }
  check() { # check WHAT EXPECTED GOT
    local mark=OK
    if [ "$2" != "$3" ]; then mark=WRONG; fail=1; fi
    echo "encryption-first-boot ($mode): $1: expected $2, got $3 [$mark]"
    printf '| %s: %s | `%s` | %s |\n' "$mode" "$1" "$3" "$mark" >> "$summary"
  }
  vm() { # vm NAME TITLE ARGS...: a boot with the test console
    local name="$1" title="$2"
    shift 2
    python3 -B tools/vm/vm-boot.py --disk "$work/disk.raw" --persist --poweroff --autologin --timeout 240 \
      --log "$logs/serial-encryption-first-boot-$mode-$name.log" --summary "$summary" --title "$title" "$@"
  }
  blind() { # blind NAME TITLE ARGS...: Secure Boot and the TPM, without the test console
    local name="$1" title="$2"
    shift 2
    python3 -B tools/vm/vm-boot.py --secure-boot "$work/vars.fd" --keep-vars --tpm "$tpm" --disk "$work/disk.raw" \
      --persist --blind --timeout 300 --log "$logs/serial-encryption-first-boot-$mode-$name.log" \
      --summary "$summary" --title "$title" "$@"
  }
  asked() { python3 -B tools/vm/vm-boot.py --on-console "Please enter (passphrase or )?recovery key for disk" "$logs/serial-encryption-first-boot-$mode-$1.log"; }
  only='systemd-recovery'
  enrolled='systemd-recovery tpm2:pubkey-pcrs=11,ref=initrd,pcrs=7+12 tpm2:pubkey-pcrs=11,ref=initrd,pcrs=7+12'
  { echo "| Check | Result | |"; echo "|---|---|---|"; } >> "$summary"
  check "the key slots after the installation" "systemd-recovery tpm2:temporary" "$(slots)"
  addon add

  if [ "$mode" = no-tpm ]; then
    vm first "First boot without the TPM: the recovery key unlocks the disk, nothing enrolled" \
      --secure-boot "$work/vars.fd" --keep-vars --chat "$ask=>$key" --chat-then-login \
      --command "$running" --command "$nofail" --command "$nocache" --command "$empty" \
      --command "$said 'nyra-tpm-enroll: not enrolled with the TPM: no TPM;' && $said 'nyra-tpm-enroll: temporary enrollment removed'" || fail=1
    check "the key slots after the first boot" "$only" "$(slots)"
  else
    vm first "First boot with Secure Boot off: unlocked by the temporary enrollment, nothing enrolled" \
      --tpm "$tpm" --command "$running" --command "$empty" \
      --command "$said 'nyra-tpm-enroll: not enrolled with the TPM: Secure Boot is off;' && $said 'nyra-tpm-enroll: temporary enrollment removed'" || fail=1
    if asked first; then echo "::error::sb-off: the first boot asked for the disk (the temporary enrollment should unlock it)"; fail=1; fi
    check "the key slots after the first boot" "$only" "$(slots)"
    vm second "Secure Boot still off: the recovery key unlocks the disk, not enrolled" \
      --tpm "$tpm" --chat "$ask=>$key" --chat-then-login \
      --command "$running" --command "$nocache" --command "$empty" \
      --command "$said 'nyra-tpm-enroll: not enrolled with the TPM again: Secure Boot is off'" || fail=1
    check "the key slots after the second boot" "$only" "$(slots)"
  fi

  # PCR 12 as a machine measures it: no add-on, so the disk can be enrolled.
  addon remove
  blind back "The TPM and Secure Boot back: the recovery key once, the disk enrolled" --chat "$ask=>$key" || fail=1
  check "the key slots with the TPM and Secure Boot back" "$enrolled" "$(slots)"
  blind after "Then the disk unlocks by itself (nothing typed)" || fail=1
  if asked after; then echo "::error::$mode: the boot after the enrollment asked for the disk"; fail=1; fi
  check "the key slots at the end" "$enrolled" "$(slots)"

  # The record and nyra-tpm-enroll's lines in the disk's journal (all boots), read with the recovery
  # key, and the recovery key searched for inside the root.
  loop="$(sudo losetup -P --show -f "$work/disk.raw")"
  for _ in $(seq 50); do [ -b "${loop}p2" ] && break; udevadm settle --timeout=10 || true; sleep 0.2; done
  inside="$(timeout 600 sudo podman run --rm -i --privileged --network none -e DM_DISABLE_UDEV=1 -v /dev:/dev -v "$secrets:/secrets:ro" "$image" \
    bash -s "${loop}p2" <<'EOF' || true
set -euo pipefail
cryptsetup open --readonly --key-file /secrets/recovery-key "$1" nyra-check-root
trap 'umount -q /target 2>/dev/null || true; cryptsetup close nyra-check-root' EXIT
mkdir -p /target && mount -o ro,noload /dev/mapper/nyra-check-root /target
sed 's/^/record: /' /target/state/os/default/var/lib/nyra/tpm2-slots
journalctl --directory="$(dirname "$(find /target/state -name 'system.journal' -print -quit)")" -o cat \
  -u nyra-tpm-enroll.service --no-pager | grep '^nyra-tpm-enroll:'
grep -r -l -a -F -f /secrets/patterns /target | sed 's|^/target|key found in the root file system: |' || true
EOF
)"
  sudo losetup -d "$loop" && loop=""
  printf '%s\n' "$inside"
  check "enrollments in the record at the end" 2 "$(printf '%s\n' "$inside" | grep -c -E '^record: [0-9]+ [0-9a-f]{64}$' || true)"
  check "first enrollments in the disk's journal" 0 "$(printf '%s\n' "$inside" | grep -c '^nyra-tpm-enroll: enrolled with the TPM (' || true)"
  check "re-enrollments in the disk's journal" 1 "$(printf '%s\n' "$inside" | grep -c '^nyra-tpm-enroll: enrolled with the TPM again' || true)"
  if [ "$mode" = sb-off ]; then
    check "refusals with Secure Boot off in the disk's journal" 2 "$(printf '%s\n' "$inside" | grep -c 'not enrolled with the TPM\( again\)\?: Secure Boot is off' || true)"
  else
    check "refusals without the TPM in the disk's journal" 1 "$(printf '%s\n' "$inside" | grep -c 'not enrolled with the TPM: no TPM' || true)"
  fi

  # The recovery key nowhere outside the user's hands (grep -c reads to the end: with -q, head would
  # end on SIGPIPE, which pipefail counts as a failure).
  local found="" f n
  for f in "$logs"/serial-encryption-first-boot-"$mode"-*.log "$summary"; do
    if grep -q -a -F -f "$secrets/patterns" "$f"; then found+=" $(basename "$f")"; fi
  done
  n="$(head -c $(((root_start + 32768) * 512)) "$work/disk.raw" | grep -c -a -F -f "$secrets/patterns" || true)"
  [ "$n" = 0 ] || found+=" the unencrypted part of the disk"
  found+="$(printf '%s\n' "$inside" | sed -n 's/^key found in the root file system: / the root file system:/p' | tr -d '\n')"
  if ! printf '%s\n' "$inside" | grep -q '^record: '; then found+=" (the root file system could not be checked)"; fi
  if [ -n "$found" ]; then
    echo "::error::$mode: the recovery key was found in:$found"
    printf '| %s: recovery key | **found in:%s** | WRONG |\n\n' "$mode" "$found" >> "$summary"
    fail=1
  else
    printf '| %s: recovery key | not in the serial logs, the ESP and LUKS2 header, or the decrypted root file system | OK |\n\n' "$mode" >> "$summary"
  fi
  sudo rm -rf "$work" "$tpm"
}

first_boot no-tpm
first_boot sb-off
exit "$fail"
