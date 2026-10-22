#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: Titanic T10, an encrypted disk without a TPM never locks its user out (docs/BOOT.md, "Disk
# encryption"). The image is installed on an encrypted root with a password and a recovery key, as
# the installer does it (tools/vm/install-encrypted.sh, which adds the password with the installer's
# own steps and header check); the VM has no TPM. Then:
#   - the LUKS2 header, read offline: the format, one password key slot (argon2id, 256 MiB of memory
#     or more), one recovery key slot with its token, discards allowed, no other token;
#   - the password unlocks the disk in the initrd, without anything on the command line: the root is
#     the LUKS2 volume the initrd found by its partition type, the ESP is mounted at /boot (first boot,
#     written to the disk);
#   - unencrypted swap, /var/tmp and /srv partitions added to the disk are not used (the image policy on
#     the sealed command line), the ESP still is; the control: gpt-auto run by hand without the policy
#     would make a swap unit;
#   - the recovery key unlocks it in place of the password;
#   - a wrong password is asked again, and the recovery key typed 120 s later still unlocks it;
#   - three wrong passwords: asked again (systemd-cryptsetup would give up), and the password unlocks it;
#   - no root partition (its type changed on a copy): emergency mode after 90 s, through
#     nyra-root-wait.service, then a reboot;
#   - the first administrator, as the installer leaves it (docs/BOOT.md, "The first administrator"): the
#     record is in the encrypted volume; the first boot makes the account in the group sudo with a
#     usable password, root stays locked, nobody has an empty password, the record is gone, the host
#     name is nyra, nyra-first-admin.service and systemd-firstboot succeeded, and the account is still
#     there after the later boots; the administrator's password opens the account (checked offline,
#     with the image's own unix_chkpwd on the disk's /etc, so it is never typed on the console);
#   - none of the three secrets (the password, the recovery key, the administrator's password) is
#     anywhere in the serial logs, in the unencrypted part of the disk (ESP, LUKS2 header) or in the
#     decrypted root file system (the journal of the first boot included).
# The passphrase prompt is answered on the serial console (vm-boot.py). Secrets stay in a 0700
# directory under WORKDIR and are deleted at the end, with the disk.
#   tools/vm/encryption.sh IMAGE WORKDIR LOGDIR SUMMARY
set -euo pipefail

image="$1" work="$2/encryption" logs="$3" summary="$4"
mkdir -p "$work"
secrets="$work/secrets"
mkdir -m 0700 "$secrets"
trap 'sudo rm -rf "$secrets" "$work/disk.raw" "$work/header" "$work/header.json" "$work/disk-noroot.raw"' EXIT

# Letters and digits only: the initrd reads the keyboard as US, whatever the user's layout.
password="$(python3 -I -c 'import secrets, string; print("".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(20)))')"
printf %s "$password" > "$secrets/password"
# The administrator's: printable ASCII with a space and symbols (the installer takes 12 to 64 of them).
admin_password="$(python3 -I -c 'import secrets, string; print("".join(secrets.choice(string.ascii_letters + string.digits + " _-.,;:!?@#%&*()+=") for _ in range(24)), end="")')"
printf %s "$admin_password" > "$secrets/admin-password"
start=$SECONDS
tools/vm/install-encrypted.sh "$image" "$work" "$secrets"
key="$(cat "$secrets/recovery-key")"
printf '%s\n%s\n%s\n' "$password" "$key" "$admin_password" > "$secrets/patterns"
{
  echo "## Disk encryption without a TPM (Titanic T10)"
  echo
  echo "Installed on LUKS2 with a password and a recovery key (tools/vm/install-encrypted.sh), $((SECONDS - start)) s; no TPM in the VM."
  echo
} >> "$summary"

# The partition table and the LUKS2 header, offline.
root_start="$(sfdisk -J "$work/disk.raw" | python3 -I -c '
import json, sys
p = json.load(sys.stdin)["partitiontable"]["partitions"]
types = [x["type"].upper() for x in p]
assert types == ["C12A7328-F81F-11D2-BA4B-00A0C93EC93B", "4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709"], types
print(p[1]["start"])')"
dd if="$work/disk.raw" of="$work/header" bs=512 skip="$root_start" count=32768 status=none
sudo podman run --rm --network none -v "$work/header:/header:ro" "$image" \
  cryptsetup luksDump --dump-json-metadata /header | sudo tee "$work/header.json" >/dev/null
header="$(python3 -I - "$work/header.json" <<'EOF'
import json, sys
h = json.load(open(sys.argv[1]))
seg = h["segments"]["0"]
assert seg["encryption"] == "aes-xts-plain64" and seg["sector_size"] == 4096, seg
slots = h["keyslots"]
assert all(s["key_size"] == 64 for s in slots.values()), slots
tokens = list(h["tokens"].values())
assert [t["type"] for t in tokens] == ["systemd-recovery"], tokens
recovery = tokens[0]["keyslots"]
password = [k for k in slots if k not in recovery]
assert len(recovery) == 1 and len(password) == 1, slots
kdf = slots[password[0]]["kdf"]
assert kdf["type"] == "argon2id" and kdf["memory"] >= 262144 and kdf["time"] >= 1, kdf
assert "allow-discards" in h["config"].get("flags", []), h["config"]
print(f"LUKS2, aes-xts-plain64 (512-bit key), 4096-byte sectors, discards allowed; key slot "
      f"{password[0]}: password (argon2id, {kdf['memory'] // 1024} MiB), key slot {recovery[0]}: recovery key (systemd-recovery "
      f"token); no other token")
EOF
)"
echo "encryption: $header"
printf '| Check | Result |\n|---|---|\n| Partitions | ESP, root (Discoverable Partitions root type, LUKS2) |\n| Header | %s |\n\n' "$header" >> "$summary"

tools/vm/test-console.sh "$image" "$work/disk.raw" "$work"
ask="Please enter passphrase or recovery key for disk [^\r\n:]*:"
running='s="$(systemctl is-system-running --wait)"; echo "system: $s"; systemctl --no-pager --failed; test "$s" = running'
# chk COMMAND: the command for the guest, traced (set -x in a subshell), so a failure shows what failed.
chk() { printf '( set -x; %s )' "$1"; }
defaults='h="$(cat /etc/hostname)"; l="$(cat /etc/locale.conf 2>&1)"; echo "host name: [$h]; /etc/locale.conf: [$l]; /etc/localtime: $(readlink /etc/localtime)"; test "$h" = nyra && echo "$l" | grep -qx LANG=en_US.UTF-8 && cmp /etc/localtime /usr/share/zoneinfo/UTC && echo "the fixed defaults are set"'
boot() { # boot NAME TITLE ARGS...: vm-boot.py on the encrypted disk
  local name="$1" title="$2"
  shift 2
  python3 -B tools/vm/vm-boot.py --autologin --disk "$work/disk.raw" --timeout 240 \
    --log "$logs/serial-encryption-$name.log" --summary "$summary" --title "$title" "$@"
}
fail=0
boot password "Encrypted disk: the password (first boot)" --persist --poweroff \
  --chat "$ask=>$password" --chat-then-login \
  --command "$running" \
  --command 'findmnt -no SOURCE /sysroot && s="$(cryptsetup status root)" && echo "$s" && echo "$s" | grep -Eq "type: +LUKS2" && echo "$s" | grep -Eq "flags: +discards" && test "$(findmnt -no SOURCE /sysroot)" = /dev/mapper/root' \
  --command 'findmnt -n -t vfat /boot' \
  --command "$(chk 'id maria && id -nG maria | tr " " "\n" | grep -qx sudo && passwd -S maria | grep -q " P " && passwd -S root | grep -q " L " && test "$(stat -c %U /var/home/maria)" = maria && echo "the administrator: an account in sudo with a password and a home; root locked"')" \
  --command "$(chk '! cut -d: -f2 /etc/shadow | grep -qx "" && test ! -e /var/lib/nyra/first-admin && echo "nobody has an empty password; the record is gone"')" \
  --command "$(chk "$defaults")" \
  --command "$(chk 'for u in nyra-first-admin systemd-firstboot; do echo "$u: $(systemctl show -P ActiveState $u.service), $(systemctl show -P Result $u.service)"; test "$(systemctl show -P ActiveState $u.service)" = active && test "$(systemctl show -P Result $u.service)" = success; done; a=$(systemctl show -P ExecMainExitTimestampMonotonic nyra-first-admin.service); b=$(systemctl show -P ExecMainStartTimestampMonotonic systemd-firstboot.service); echo "the account was made at $a us, systemd-firstboot started at $b us"; test "$a" -gt 0 && test "$a" -le "$b"; journalctl -b -u nyra-first-admin.service -o cat --no-pager')" \
  || fail=1
# Partitions someone adds to the disk while it is off: unencrypted swap, /var/tmp and /srv (their
# Discoverable Partitions types). The image policy on the sealed command line has the running system
# ignore them; without it, gpt-auto would swap to and mount them (the control: the generator run by
# hand with a command line without the policy).
truncate -s +192M "$work/disk.raw"
sfdisk -q --relocate gpt-bak-std "$work/disk.raw"
sfdisk -q --append "$work/disk.raw" <<'EOF'
size=48MiB, type=0657FD6D-A4AB-43C4-84E5-0933C84B4F4F, name="swap"
size=48MiB, type=7EC6F557-3BC5-4ACA-B293-16EF5DF639D1, name="var-tmp"
size=48MiB, type=3B8F8425-20E0-4F3B-907F-1A25A76F98E8, name="srv"
EOF
loop="$(sudo losetup -P --show -f "$work/disk.raw")"
for _ in $(seq 50); do [ -b "${loop}p5" ] && break; udevadm settle --timeout=10 || true; sleep 0.2; done
sudo mkswap -q "${loop}p3" && sudo mkfs.ext4 -q "${loop}p4" && sudo mkfs.ext4 -q "${loop}p5"
sudo losetup -d "$loop"
# The units gpt-auto would make now, as a list (GEN_ENV: an environment for it).
gen='d="$(mktemp -d)" && env $GEN_ENV /usr/lib/systemd/system-generators/systemd-gpt-auto-generator "$d" "$d" "$d" && find "$d" -name "*.swap" -o -name "var-tmp.mount" -o -name "srv.mount" -o -name "boot.mount" | sed "s|.*/||" | sort | tr "\n" " "'
boot added "Encrypted disk: unencrypted partitions added to the disk are not used" \
  --chat "$ask=>$password" --chat-then-login \
  --command 's="$(swapon --show=NAME --noheadings)"; echo "swap: ${s:-none}"; ! echo "$s" | grep -q "^/dev/vd"' \
  --command 'm="$(findmnt -rn -o SOURCE,TARGET | grep -E "^/dev/vda[345] " || true)"; echo "mounted from the added partitions: ${m:-none}"; test -z "$m"' \
  --command 'findmnt -n -t vfat /boot' \
  --command "GEN_ENV=; u=\"\$($gen)\"; echo \"units with the sealed command line: \$u\"; echo \"\$u\" | grep -q boot.mount && ! echo \"\$u\" | grep -qE '\\.swap|var-tmp|srv'" \
  --command "GEN_ENV=SYSTEMD_PROC_CMDLINE=rw; u=\"\$($gen)\"; echo \"control, without the image policy: \$u\"; echo \"\$u\" | grep -q '\\.swap'" \
  || fail=1
boot recovery-key "Encrypted disk: the recovery key" \
  --chat "$ask=>$key" --chat-then-login --command "$running" \
  --command "$(chk 'id -nG maria | tr " " "\n" | grep -qx sudo && test ! -e /var/lib/nyra/first-admin && echo "the administrator is still there; nothing was made again"')" || fail=1
boot later "Encrypted disk: a wrong password, then the recovery key 120 s later" \
  --chat "$ask=>wrong-$password" --chat "$ask=>@sleep 120 $key" --chat-then-login --command "$running" || fail=1
boot three-wrong "Encrypted disk: three wrong passwords, then asked again, without a restart" \
  --chat "$ask=>wrong1" --chat "$ask=>wrong2" --chat "$ask=>wrong3" --chat "$ask=>$password" --chat-then-login \
  --command "$running" || fail=1
# No root partition at all (its type changed on a copy of the disk): the initrd waits for an encrypted
# root without a limit, so nyra-root-wait.service is what still ends the boot after 90 s, in emergency
# mode, which reboots.
cp --sparse=always "$work/disk.raw" "$work/disk-noroot.raw"
sfdisk -q --part-type "$work/disk-noroot.raw" 2 0FC63DAF-8483-4772-8E79-3D69D8477DE4
python3 -B tools/vm/vm-boot.py --disk "$work/disk-noroot.raw" --timeout 240 --expect-reboot \
  --log "$logs/serial-encryption-noroot.log" --summary "$summary" \
  --title "No root partition: emergency mode after 90 s (nyra-root-wait), which reboots" || fail=1
rm "$work/disk-noroot.raw"
if ! python3 -B tools/vm/vm-boot.py --on-console "nyra-root-wait: no root partition" "$logs/serial-encryption-noroot.log" ||
   ! python3 -B tools/vm/vm-boot.py --on-console "@@ emergency: diagnostics" "$logs/serial-encryption-noroot.log"; then
  echo "::error::no root partition: nyra-root-wait's message or the emergency mode is missing"
  fail=1
fi

# Neither secret anywhere outside the user's head: the serial logs and this summary, the unencrypted
# start of the disk (the ESP and the LUKS2 header), the decrypted root file system.
found=""
for f in "$logs"/serial-encryption-*.log "$summary"; do
  if grep -q -a -F -f "$secrets/patterns" "$f"; then found+=" $(basename "$f")"; fi
done
# grep -c reads to the end: with -q, head would end on SIGPIPE, which pipefail counts as a failure.
n="$(head -c $(((root_start + 32768) * 512)) "$work/disk.raw" | grep -c -a -F -f "$secrets/patterns" || true)"
[ "$n" = 0 ] || found+=" the unencrypted part of the disk"
loop="$(sudo losetup -P --show -f "$work/disk.raw")"
for _ in $(seq 50); do [ -b "${loop}p2" ] && break; udevadm settle --timeout=10 || true; sleep 0.2; done
inside="$(timeout 600 sudo podman run --rm -i --privileged --network none -e DM_DISABLE_UDEV=1 -v /dev:/dev -v "$secrets:/secrets:ro" "$image" \
  bash -s "${loop}p2" <<'EOF'
set -euo pipefail
cryptsetup open --readonly --key-file /secrets/password "$1" nyra-check-root
trap 'umount -q /target 2>/dev/null || true; cryptsetup close nyra-check-root' EXIT
mkdir -p /target && mount -o ro,noload /dev/mapper/nyra-check-root /target
test -n "$(find /target/state -name '*.journal' -print -quit)"
grep -r -l -a -F -f /secrets/patterns /target | sed 's|^/target|the root file system: |' || true
EOF
)" || inside="the root file system could not be checked"
sudo losetup -d "$loop"
found+="${inside:+ $inside}"
if [ -n "$found" ]; then
  echo "::error::The password, the recovery key or the administrator's password was found in:$found"
  printf '| Secrets | **found in:%s** |\n\n' "$found" >> "$summary"
  fail=1
else
  echo "encryption: none of the three secrets in the serial logs, the unencrypted part of the disk or the root file system"
  printf '| Secrets | neither the password, nor the recovery key, nor the administrator'"'"'s password in the serial logs, the ESP and LUKS2 header, or the decrypted root file system (the journal included) |\n\n' >> "$summary"
fi

# The administrator's password opens the account that the first boot made, on the disk's own /etc, with
# the image's unix_chkpwd (the disk's account files are bound over the container's); a wrong password and
# an empty one do not.
loop="$(sudo losetup -P --show -f "$work/disk.raw")"
for _ in $(seq 50); do [ -b "${loop}p2" ] && break; udevadm settle --timeout=10 || true; sleep 0.2; done
if admin="$(timeout 600 sudo podman run --rm -i --privileged --network none -e DM_DISABLE_UDEV=1 -v /dev:/dev -v "$secrets:/secrets:ro" "$image" \
  bash -s "${loop}p2" <<'EOF'
set -euo pipefail
cryptsetup open --readonly --key-file /secrets/password "$1" nyra-check-root
trap 'umount -q /etc/passwd /etc/shadow 2>/dev/null || true; umount -q /target 2>/dev/null || true; cryptsetup close nyra-check-root' EXIT
mkdir -p /target && mount -o ro,noload /dev/mapper/nyra-check-root /target
set -- /target/state/deploy/*/etc
test "$#" = 1
test ! -e /target/state/os/default/var/lib/nyra/first-admin
mount --bind "$1/passwd" /etc/passwd && mount --bind "$1/shadow" /etc/shadow
# unix_chkpwd reads one password, NUL-terminated, from the standard input.
{ cat /secrets/admin-password; printf '\0'; } | /usr/sbin/unix_chkpwd maria nullok
! { cat /secrets/admin-password; printf 'x\0'; } | /usr/sbin/unix_chkpwd maria nullok
! printf '\0' | /usr/sbin/unix_chkpwd maria nullok
echo "the administrator's password opens the account on the disk; a wrong one and an empty one do not"
EOF
)"; then
  echo "encryption: $admin"
  printf '| Administrator | %s |\n\n' "$admin" >> "$summary"
else
  echo "::error::The administrator's password does not open the account on the disk (or the record is still there)"
  fail=1
fi
sudo losetup -d "$loop"
exit "$fail"
