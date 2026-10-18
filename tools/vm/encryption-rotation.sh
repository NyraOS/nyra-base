#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: Titanic T10, the rotation of the TPM policy key in a VM (docs/BOOT.md, "Rotating the policy
# key"; docs/SIGNING.md, "The PCR policy key"). Test versions of IMAGE, each with its own UKI built as
# ci/build-image.sh builds it (ci/ukify.sh), its PCR 11 policy signed with a policy key and the UKI
# signed for Secure Boot, and the next policy key in /usr:
#   rot-a   signed with A, next key B (installed)
#   rot-b1  signed with B, next key C, a health check that always fails (never confirmed good)
#   rot-b2  signed with B, next key C
#   rot-d   signed with D, next key E (a machine that missed the rotation to C)
# All keys are made here and their private halves deleted once the versions are built: policy keys
# A to E, and one Secure Boot key (a MOK) for the UKIs and the test console add-on. The versions are
# served by a throwaway registry on the runner (the VM reaches it as 10.0.2.2). The disk is installed
# for a TPM (swtpm) with rot-a, as tools/vm/install-encrypted.sh does it, then:
#   1. rot-a's first boot unlocks by itself; its initrd enrolls A and B (the record: A, B); switch to
#      rot-b1;
#   2. rot-b1 unlocks by itself (B), and its initrd enrolls C (the record: A, B, C); never confirmed
#      good, so A stays; bootc rollback;
#   3. the fallback to rot-a unlocks by itself (A); confirmed good, it removes nothing (C is newer);
#      switch to rot-b2;
#   4. rot-b2 unlocks by itself, nothing to enroll; confirmed good: A's enrollment removed, A retired
#      in the record; bootc rollback;
#   5. rot-a, after that confirmation, without the test console add-on (PCR 12 as a machine measures
#      it, so only the retired key stops a new enrollment), no login: the disk asks for its recovery
#      key, which unlocks it; not enrolled again, because A was retired (read in the journal at the end);
#   5b. with the add-on back, the same with a login: switch to rot-d;
#   6. without the add-on again, no login: rot-d asks for the recovery key once, and its initrd
#      enrolls the disk again for D and E;
#   7. then rot-d unlocks by itself.
# Read offline at the end: the recovery key slot and two TPM2 enrollments, the record (A retired, D and
# E) and the units' lines in the disk's journal.
# With "pin", on a disk of its own: rot-a's first boot asks for a PIN (tpm-pin) and its second boot (1b)
# enrolls A and B with it; every boot that unlocks with the TPM types it, rot-b1's initrd enrolls C
# with the PIN typed in that boot (no prompt of its own), and rot-d, after the recovery key, asks for
# a new PIN, which unlocks the next boot. Every enrollment in the record has a PIN.
#   tools/vm/encryption-rotation.sh IMAGE WORKDIR LOGDIR SUMMARY [pin]
set -euo pipefail

mode="${5:-}" sfx=""
[ "$mode" != pin ] || sfx="-pin"
image="$1" work="$2/encryption-rotation$sfx" logs="$3" summary="$4"
# swtpm's state under LOGDIR (RUNNER_TEMP): Ubuntu's AppArmor profile for swtpm allows no other place.
tpm="$logs/encryption-rotation$sfx-state"
secrets="$work/secrets" keys="$work/keys" ctx="$work/context"
mnt="$work/esp"
loop=""
mkdir -p "$work" "$tpm" "$mnt" "$ctx"
mkdir -m 0700 "$secrets" "$keys"
trap 'sudo umount -q "$mnt" 2>/dev/null || true; [ -z "$loop" ] || sudo losetup -d "$loop" || true; sudo podman rm -f nyra-test-registry >/dev/null 2>&1 || true; for v in rot-a rot-b1 rot-b2 rot-d; do sudo podman rmi -f "localhost/nyra-test:$v" "localhost/nyra-test:$v-rootfs" >/dev/null 2>&1 || true; done; sudo rm -rf "$secrets" "$keys" "$tpm" "$work"' EXIT

start=$SECONDS
# --- keys and versions -----------------------------------------------------------------------------
for k in A B C D E; do
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$keys/$k.key" 2>/dev/null
  openssl pkey -in "$keys/$k.key" -pubout -out "$keys/$k.pem"
done
openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=Nyra CI rotation test key" \
  -keyout "$keys/sb.key" -out "$work/sb.crt" 2>/dev/null
fp() { sha256sum < "$keys/$1.pem" | cut -c1-64; } # a key's identity, as nyra-tpm-enroll computes it
fa="$(fp A)" fb="$(fp B)" fc="$(fp C)" fd="$(fp D)" fe="$(fp E)"

cat > "$work/kernel-from-uki.py" <<'EOF'
import sys
import pefile
pe = pefile.PE(sys.argv[1])
for s in pe.sections:
    name = {b".linux": "vmlinuz", b".initrd": "initramfs.img"}.get(s.Name.rstrip(b"\0"))
    if name:
        with open(f"{sys.argv[2]}/{name}", "wb") as f:
            f.write(s.get_data()[:s.Misc_VirtualSize])
EOF
unhealthy="RUN printf '%s\\n' '[Unit]' 'Description=Test only: a health check that always fails' \\
      'Before=boot-complete.target' '[Service]' 'Type=oneshot' 'ExecStart=/usr/bin/false' \\
      > /usr/lib/systemd/system/nyra-test-unhealthy.service && \\
    ln -s ../nyra-test-unhealthy.service /usr/lib/systemd/system/boot-complete.target.requires/"
version() { # version NAME POLICY_KEY NEXT_KEY [unhealthy]
  local name="$1" pcr="$2" next="$3" d="$work/$1" f b
  cp "$keys/$next.pem" "$ctx/next-$name.pem"
  { echo "FROM $image"; echo "RUN rm -rf /boot/EFI"
    echo "COPY next-$name.pem /usr/lib/nyra/secureboot/tpm2-pcr-public-key-next.pem"
    echo "RUN echo $name > /usr/lib/nyra-test-version"
    [ "${4:-}" != unhealthy ] || echo "$unhealthy"
  } | sudo podman build -q -t "localhost/nyra-test:$name-rootfs" -f - "$ctx" >/dev/null
  mkdir -p "$d/pcr" "$d/unsigned" "$d/policy" "$d/signed"
  cp "$keys/$pcr.pem" "$d/pcr/tpm2-pcr-public-key.pem"
  # The UKI as step 2 of ci/build-image.sh makes it, with the kernel and initramfs of IMAGE's UKI.
  sudo podman run --rm --network none --tmpfs /tmp --tmpfs /var/tmp --tmpfs /kernel \
    --mount "type=image,source=localhost/nyra-test:$name-rootfs,target=/target" \
    -v "$work/kernel-from-uki.py:/kernel-from-uki.py:ro" -v "$PWD/ci/ukify.sh:/ukify.sh:ro" \
    -v "$d/pcr:/pcr:ro" -v "$d/unsigned:/out" "$image" \
    sh -c 'u="$(ls /boot/EFI/Linux/*.efi)" && k="$(basename "$u" .efi)" && mkdir -p "/kernel/$k" &&
      python3 /kernel-from-uki.py "$u" "/kernel/$k" && sh /ukify.sh' >/dev/null
  sudo chown -R "$(id -u):$(id -g)" "$d"
  f="$(ls "$d"/unsigned/*.efi)" && b="${f##*/}"
  # Step 3: the PCR 11 policy signed with the version's policy key, then the UKI for Secure Boot.
  python3 -I tools/signing/uki-check.py "$f" ci/uki-cmdline.txt
  python3 -I tools/signing/pcr-policy.py sign "$f" "$keys/$pcr.key" > "$d/pcr/pcrsig.json"
  sudo podman run --rm --network none --tmpfs /tmp --tmpfs /var/tmp -v "$d/unsigned:/in:ro" \
    -v "$d/pcr:/pcr:ro" -v "$d/policy:/out" "$image" \
    ukify build --join-pcrsig "/in/$b" --pcrsig @/pcr/pcrsig.json --output "/out/$b" >/dev/null
  sudo chown -R "$(id -u):$(id -g)" "$d"
  python3 -I tools/signing/pcr-policy.py check "$d/policy/$b" "$keys/$pcr.pem"
  sbsign --key "$keys/sb.key" --cert "$work/sb.crt" --output "$d/signed/$b" "$d/policy/$b" >/dev/null
  printf 'FROM localhost/nyra-test:%s-rootfs\nCOPY --from=uki . /boot/EFI/Linux/\n' "$name" |
    sudo podman build -q -t "localhost/nyra-test:$name" --build-context uki="$d/signed" -f - "$ctx" >/dev/null
}
version rot-a A B
version rot-b1 B C unhealthy
version rot-b2 B C
version rot-d D E
tools/vm/test-addon.sh "$image" "$work/console.addon.efi" systemd.import_credentials=yes "$keys/sb.key" "$work/sb.crt"
rm -f "$keys"/*.key

sudo podman rm -f nyra-test-registry >/dev/null 2>&1 || true
tools/signing/local-registry.sh "$work"
for v in rot-b1 rot-b2 rot-d; do
  sudo podman push -q --tls-verify=false "localhost/nyra-test:$v" "docker://other.test/nyra-test:$v"
done

tools/vm/install-encrypted.sh localhost/nyra-test:rot-a "$work" "$secrets" "$tpm"
key="$(cat "$secrets/recovery-key")"
printf '%s\n' "$key" > "$secrets/patterns"
{
  echo "## Rotation of the TPM policy key${sfx:+ with a PIN} (Titanic T10)"
  echo
  echo "Four test versions (policy keys A to E), built, pushed and installed (rot-a, for a TPM) in $((SECONDS - start)) s; swtpm, Secure Boot on."
  echo
} >> "$summary"
virt-fw-vars --input /usr/share/OVMF/OVMF_VARS_4M.ms.fd --output "$work/vars.fd" \
  --add-mok 605dab50-e046-4300-abb6-3dd810dd8b23 "$work/sb.crt"
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

root_start="$(sfdisk -J "$work/disk.raw" | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["partitiontable"]["partitions"][1]["start"])')"
header() { # the LUKS2 header's JSON metadata
  dd if="$work/disk.raw" of="$work/header" bs=512 skip="$root_start" count=32768 status=none
  sudo podman run --rm --network none -v "$work/header:/header:ro" "$image" \
    cryptsetup luksDump --dump-json-metadata /header
}
fail=0
check() { # check WHAT EXPECTED GOT
  local mark=OK
  if [ "$2" != "$3" ]; then mark=WRONG; fail=1; fi
  echo "encryption-rotation: $1: expected $2, got $3 [$mark]"
  printf '| %s | `%s` | %s |\n' "$1" "$3" "$mark" >> "$summary"
}
{ echo "| Check | Result | |"; echo "|---|---|---|"; } >> "$summary"

ask="Please enter (passphrase or )?recovery key for disk [^\r\n:]*:"
pinask="Please enter TPM2 PIN:"
either="($pinask|$ask)"
# The PINs: 20 random digits each (nothing else on the console looks like them).
pin1="$(python3 -I -c 'import secrets; print("".join(secrets.choice("0123456789") for _ in range(20)))')"
pin2="$(python3 -I -c 'import secrets; print("".join(secrets.choice("0123456789") for _ in range(20)))')"
# What a boot that unlocks with the TPM types (nothing without a PIN), and the record's mark.
unlock=() m=""
if [ "$mode" = pin ]; then unlock=(--chat "$pinask=>$pin1" --chat-then-login); m=" pin"; fi
# The PIN typed only at prompts (rows 6 and 7) must be nowhere either; the first one is in a command.
[ "$mode" != pin ] || printf '%s\n' "$pin2" >> "$secrets/patterns"
running='s="$(systemctl is-system-running --wait)"; echo "system: $s"; systemctl --no-pager --failed; test "$s" = running'
unhealthy_boot='s="$(systemctl is-system-running --wait)"; echo "system: $s"; test "$s" = degraded && ! systemctl is-active --quiet boot-complete.target'
enrolled='journalctl -b -o cat -u nyra-tpm-enroll.service | grep nyra-tpm-enroll:'
retired='journalctl -b -o cat -u nyra-tpm-retire.service | grep nyra-tpm-retire:'
# nyra-tpm-retire.service ran in this boot (systemd's own line about it).
retire_ran='journalctl -b -o cat -u nyra-tpm-retire.service | grep "^Finished nyra-tpm-retire.service"'
is() { echo "test \"\$(cat /usr/lib/nyra-test-version)\" = $1 && echo 'version: $1'"; }
# The record's enrollments, as their keys' identities in order, and its retired keys.
# With a PIN (once it is enrolled), every enrollment has one; without, none.
record() {
  local pins="! grep -Eq '^[0-9]+ [0-9a-f]+ pin\$' \$r"
  [ -z "$m" ] || pins="! grep -Eq '^[0-9]+ [0-9a-f]+\$' \$r"
  echo "r=/var/lib/nyra/tpm2-slots; cat \$r; test \"\$(sed -n 's/^[0-9][0-9]* \([0-9a-f]*\).*/\1/p' \$r | tr '\n' ' ')\" = \"$1\" && test \"\$(sed -n 's/^retired //p' \$r | tr '\n' ' ')\" = \"$2\" && $pins"
}
switch() { echo "bootc switch --quiet 10.0.2.2/nyra-test:$1 && ls /boot/loader/entries.staged"; }
registry='mkdir -p /etc/containers/registries.conf.d && printf "[[registry]]\nlocation = \"10.0.2.2\"\ninsecure = true\n" > /etc/containers/registries.conf.d/99-ci-test.conf'
vm() { # vm NAME TITLE ARGS...
  local name="$1" title="$2"
  shift 2
  python3 -B tools/vm/vm-boot.py --secure-boot "$work/vars.fd" --keep-vars --disk "$work/disk.raw" \
    --tpm "$tpm" --persist --poweroff --autologin --timeout 240 \
    --log "$logs/serial-encryption-rotation$sfx-$name.log" --summary "$summary" --title "$title" "$@"
}
blind() { # blind NAME TITLE ARGS...
  local name="$1" title="$2"
  shift 2
  python3 -B tools/vm/vm-boot.py --secure-boot "$work/vars.fd" --keep-vars --disk "$work/disk.raw" \
    --tpm "$tpm" --persist --blind --timeout 300 \
    --log "$logs/serial-encryption-rotation$sfx-$name.log" --summary "$summary" --title "$title" "$@"
}
asked() { # asked NAME: did the console of that boot ask for the disk?
  python3 -B tools/vm/vm-boot.py --on-console "Please enter (passphrase or )?recovery key for disk" "$logs/serial-encryption-rotation$sfx-$1.log"
}
by_itself() { ! asked "$1" || { echo "::error::$1 asked for the disk"; fail=1; }; }

if [ "$mode" != pin ]; then
  vm a "Rotation 1: rot-a's first boot unlocks by itself and enrolls A and B" \
    --command "$(is rot-a)" --command "$running" --command "$enrolled | grep 'enrolled with the TPM'" \
    --command "$(record "$fa $fb " "")" --command "$registry" --command "$(switch rot-b1)" || fail=1
  by_itself a
else
  m="" # not yet
  vm a "Rotation 1: rot-a's first boot unlocks by itself and enrolls A and B; a PIN asked for" \
    --command "$(is rot-a)" --command "$running" --command "$enrolled | grep 'enrolled with the TPM'" \
    --command "$(record "$fa $fb " "")" --command "echo $pin1 | /usr/lib/nyra/boot/tpm-pin set" || fail=1
  by_itself a
  m=" pin"
  vm a-pin "Rotation 1b: rot-a unlocks by itself, and its initrd enrolls A and B with the PIN" \
    --command "$(is rot-a)" --command "$running" --command "$enrolled | grep 'with the new PIN'" \
    --command "$(record "$fa $fb " "")" --command "$registry" --command "$(switch rot-b1)" || fail=1
  by_itself a-pin
fi
vm b1 "Rotation 2: rot-b1 (signed with B) unlocks by itself, enrolls C; not confirmed good, A stays" \
  "${unlock[@]}" --command "$(is rot-b1)" --command "$unhealthy_boot" --command "$enrolled | grep 'enrolled the next policy key'" \
  --command "! $retired && echo 'nothing removed'" \
  --command "$(record "$fa $fb $fc " "")" --command 'bootc rollback' || fail=1
by_itself b1
vm a-fallback "Rotation 3: the fallback to rot-a unlocks by itself; confirmed good, it keeps the newer C" \
  "${unlock[@]}" --command "$(is rot-a)" --command "$running" --command "$retire_ran" \
  --command "! $enrolled && ! $retired && echo 'nothing enrolled or removed'" \
  --command "$(record "$fa $fb $fc " "")" --command "$(switch rot-b2)" || fail=1
by_itself a-fallback
vm b2 "Rotation 4: rot-b2 unlocks by itself; confirmed good, A's enrollment removed" \
  "${unlock[@]}" --command "$(is rot-b2)" --command "$running" --command "! $enrolled && echo 'nothing enrolled'" \
  --command "$retired | grep 'removed the enrollments of retired policy keys'" \
  --command "$(record "$fb $fc " "$fa ")" --command 'bootc rollback' || fail=1
by_itself b2
# With a PIN, it is asked first (for the enrollments of B and C, which do not apply), then the
# recovery key; the second answer goes to whichever prompt comes (an empty recovery key is asked again).
chat=(--chat "$ask=>$key")
[ "$mode" != pin ] || chat=(--chat "$pinask=>$pin1" --chat "$either=>" --chat "$ask=>$key")
# Without the test console add-on: PCR 12 as a machine measures it, so only the retired key stops a
# new enrollment.
esp remove
blind a-retired "Rotation 5: rot-a after the confirmation, without the add-on: the recovery key, not enrolled again" \
  "${chat[@]}" || fail=1
esp add
vm a-retired-login "Rotation 5b: the same with the add-on, to switch to rot-d" \
  "${chat[@]}" --chat-then-login --command "$(is rot-a)" --command "$running" \
  --command "$enrolled | grep 'not enrolled with the TPM again'" --command "$(record "$fb $fc " "$fa ")" \
  --command "$(switch rot-d)" || fail=1
esp remove
[ "$mode" != pin ] || chat=(--chat "$pinask=>$pin1" --chat "$either=>" --chat "$ask=>$key"
  --chat "Choose a TPM2 PIN for the disk=>$pin2" --chat "Type the same PIN again:=>$pin2")
blind d "Rotation 6: rot-d (D, a missed rotation): the recovery key once, the disk enrolled for D and E" \
  "${chat[@]}" || fail=1
after=()
[ "$mode" != pin ] || after=(--chat "$pinask=>$pin2")
blind d-after "Rotation 7: then rot-d unlocks by itself" "${after[@]}" || fail=1
by_itself d-after

check "Key slots at the end" "1 systemd-recovery, 2 systemd-tpm2" \
  "$(header | python3 -I -c 'import json, sys, collections; c = collections.Counter(t["type"] for t in json.load(sys.stdin)["tokens"].values()); print(", ".join(f"{n} {t}" for t, n in sorted(c.items())))')"
# The record and the units' lines in the disk's journal (all boots), read with the recovery key.
loop="$(sudo losetup -P --show -f "$work/disk.raw")"
for _ in $(seq 50); do [ -b "${loop}p2" ] && break; udevadm settle --timeout=10 || true; sleep 0.2; done
inside="$(timeout 600 sudo podman run --rm -i --privileged --network none -e DM_DISABLE_UDEV=1 -v /dev:/dev -v "$secrets:/secrets:ro" "$image" \
  bash -s "${loop}p2" <<'EOF' || true
set -euo pipefail
cryptsetup open --readonly --key-file /secrets/recovery-key "$1" nyra-check-root
trap 'umount -q /target 2>/dev/null || true; cryptsetup close nyra-check-root' EXIT
mkdir -p /target && mount -o ro,noload /dev/mapper/nyra-check-root /target
sed 's/^/record: /' "$(find /target/state -path '*/var/lib/nyra/tpm2-slots' -print -quit)"
journalctl --directory="$(dirname "$(find /target/state -name 'system.journal' -print -quit)")" -o cat \
  -u nyra-tpm-enroll.service -u nyra-tpm-retire.service --no-pager | grep -E '^nyra-tpm-(enroll|retire):'
grep -r -l -a -F -f /secrets/patterns /target | sed 's|^/target|key found in the root file system: |' || true
EOF
)"
sudo losetup -d "$loop" && loop=""
printf '%s\n' "$inside"
check "The record at the end" "retired $fa|$fd$m|$fe$m" \
  "$(printf '%s\n' "$inside" | sed -n 's/^record: //p' | sed 's/^[0-9][0-9]* //' | tr '\n' '|' | sed 's/|$//')"
check "Next keys enrolled (row 2)" 1 "$(printf '%s\n' "$inside" | grep -c 'enrolled the next policy key' || true)"
check "Retirements (row 4)" 1 "$(printf '%s\n' "$inside" | grep -c 'removed the enrollments of retired policy keys' || true)"
check "Refusals for the retired key A (row 5)" 1 "$(printf '%s\n' "$inside" | grep -c 'not enrolled with the TPM again: the policy key of this version was retired' || true)"
check "Re-enrollments (row 6)" 1 "$(printf '%s\n' "$inside" | grep -c '^nyra-tpm-enroll: enrolled with the TPM again' || true)"

# The recovery key nowhere outside the user's hands.
found=""
for f in "$logs"/serial-encryption-rotation$sfx-*.log "$summary"; do
  if grep -q -a -F -f "$secrets/patterns" "$f"; then found+=" $(basename "$f")"; fi
done
n="$(head -c $(((root_start + 32768) * 512)) "$work/disk.raw" | grep -c -a -F -f "$secrets/patterns" || true)"
[ "$n" = 0 ] || found+=" the unencrypted part of the disk"
found+="$(printf '%s\n' "$inside" | sed -n 's/^key found in the root file system: / the root file system:/p' | tr -d '\n')"
if [ -n "$found" ]; then
  echo "::error::The recovery key was found in:$found"
  printf '| Recovery key | **found in:%s** | WRONG |\n\n' "$found" >> "$summary"
  fail=1
else
  printf '| Recovery key | not in the serial logs, the ESP and LUKS2 header, or the decrypted root file system | OK |\n\n' >> "$summary"
fi
exit "$fail"
