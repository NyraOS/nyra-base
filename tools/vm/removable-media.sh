#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: Titanic T14, removable media pulled out (docs/TITANIC.md, docs/DEFAULTS.md "Removable
# media"). On a copy-on-write copy of the installed test disk, with USB sticks on a USB controller
# that QEMU plugs in and pulls out (vm-boot.py --qemu, --qmp):
#   1  two sticks with a FAT file system, one with an ext4 and an exFAT partition, and one with
#      squashfs; nothing mounts them by itself. The squashfs one is refused, and so is squashfs asked
#      for by name on a FAT stick (its module is not even loaded). One FAT stick goes into the list of
#      trusted media (also as a last line without a newline; a list others can write is ignored).
#      udisksctl mounts both: nosuid and nodev, noexec on the other one only (exec, suid and dev
#      refused); the ext4 and the exFAT partitions mount like the untrusted one, and take a file; a
#      program runs from the trusted one only; udisks2 runs with its hardening. The other FAT stick
#      is pulled out while it is written without a pause: the writer stops, sync returns, the mount
#      goes away, the system runs. Plugged in again, it is not mounted until asked, and mounts. A
#      user in an active session may mount a stick, but not set up a file as a loop device (polkit
#      asks for an administrator, nobody can answer). Clean shutdown with the trusted stick still
#      mounted.
#   2  a stick (repaired with fsck.vfat after boot 1) mounted and written while an update (plain
#      `bootc switch` to a test version, as in tools/titanic/extreme-load.sh) runs, pulled out during
#      it, while a write runs: the writer stops by itself, the update is staged exactly; clean
#      shutdown, which finalizes it.
#   3  a boot with a stick that carries an ESP, a root, a swap and a /home partition (their
#      Discoverable Partitions types) and with the FAT stick: the test version runs; root and ESP
#      come from the boot disk, no swap, nothing mounted from the sticks.
#   4-6  the same stick pulled out 3, 6 and 10 s after QEMU starts (firmware, the kernel and its
#      initrd, the system's start): each boot reaches the login prompt, nothing waits for the stick,
#      clean shutdown.
# Every boot ends with a clean shutdown, which fails on a file system left mounted or a shutdown
# longer than 60 s (vm-boot.py --poweroff).
#   tools/vm/removable-media.sh IMAGE DISK.qcow2 WORKDIR LOGDIR SUMMARY
set -euo pipefail

image="$1" disk="$2" work="$3" logs="$4" summary="$5"
media="$work/removable-media"
mkdir -p "$media/context" "$media/uki"

# --- the sticks, made with the image's own tools ----------------------------------------------------
# GPT, 1 MiB alignment; each file system is made in a file of its own and copied into place.
cat > "$media/sticks.sh" <<'EOF'
set -euo pipefail
cd /w
part() { # part STICK START_MIB SIZE_MIB MKFS...
  local stick="$1" start="$2" size="$3"
  shift 3
  truncate -s "${size}M" p.img
  "$@" p.img >/dev/null
  dd if=p.img of="$stick" bs=1M seek="$start" conv=notrunc status=none
  rm p.img
}
data=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
for s in untrusted:T14UNTRUST trusted:T14TRUSTED; do
  truncate -s 256M "${s%:*}.raw"
  printf 'label: gpt\nstart=2048, size=%s, type=%s\n' $((200 * 2048)) "$data" | sfdisk -q "${s%:*}.raw"
  part "${s%:*}.raw" 1 200 mkfs.vfat -n "${s#*:}"
done
# The partition types systemd-gpt-auto-generator uses on the boot disk: ESP, root (x86-64), swap, /home.
truncate -s 512M system.raw
sfdisk -q system.raw <<PARTS
label: gpt
start=$((1 * 2048)), size=$((64 * 2048)), type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
start=$((65 * 2048)), size=$((160 * 2048)), type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709
start=$((225 * 2048)), size=$((64 * 2048)), type=0657FD6D-A4AB-43C4-84E5-0933C84B4F4F
start=$((289 * 2048)), size=$((64 * 2048)), type=933AC7E1-2EB4-4F13-B844-0E14E2AEF915
PARTS
mkdir -p root/etc && echo "a root partition on a USB stick" > root/etc/nyra-t14-stick
part system.raw 1 64 mkfs.vfat -n T14ESP
part system.raw 65 160 mkfs.ext4 -q -F -L t14-root -d root
part system.raw 225 64 mkswap -L t14-swap
part system.raw 289 64 mkfs.ext4 -q -F -L t14-home
rm -r root
# ext4 here; the exFAT partition after it is made on the runner (the image has no mkfs.exfat).
truncate -s 130M fs.raw
printf 'label: gpt\nstart=2048, size=%s, type=%s\nstart=%s, size=%s, type=%s\n' \
  $((64 * 2048)) "$data" $((65 * 2048)) $((64 * 2048)) "$data" | sfdisk -q fs.raw
part fs.raw 1 64 mkfs.ext4 -q -F -L t14-ext4
EOF
sudo podman run --rm --network none -v "$media:/w" "$image" bash /w/sticks.sh
sudo chown "$(id -u):$(id -g)" "$media"/*.raw
# A stick with a file system Nyra does not mount (squashfs, on the whole stick), made on the runner.
command -v mksquashfs >/dev/null || sudo apt-get install -y -q --no-install-recommends squashfs-tools >/dev/null
mkdir -p "$media/foreign"
echo "a squashfs stick" > "$media/foreign/readme"
mksquashfs "$media/foreign" "$media/foreign.raw" -quiet -noappend
truncate -s 4M "$media/foreign.raw"
command -v mkfs.exfat >/dev/null || sudo apt-get install -y -q --no-install-recommends exfatprogs >/dev/null
truncate -s 64M "$media/exfat.img"
mkfs.exfat -L T14EXFAT "$media/exfat.img" >/dev/null
dd if="$media/exfat.img" of="$media/fs.raw" bs=1M seek=65 conv=notrunc status=none
rm "$media/exfat.img"

xhci=(--qemu=-device "--qemu=qemu-xhci,id=xhci")
stick() { # stick NAME SERIAL: vm-boot.py options that plug in NAME.raw at QEMU's start
  printf '%s\n' --qemu=-blockdev "--qemu=driver=file,filename=$media/$1.raw,node-name=$1-file" \
    --qemu=-blockdev "--qemu=driver=raw,file=$1-file,node-name=$1" \
    --qemu=-device "--qemu=usb-storage,bus=xhci.0,drive=$1,id=$1,serial=$2,removable=on"
}
mapfile -t untrusted < <(stick untrusted T14UNTRUSTED)
mapfile -t trusted < <(stick trusted T14TRUSTED)
mapfile -t system < <(stick system T14SYSTEM)
mapfile -t foreign < <(stick foreign T14FOREIGN)
mapfile -t fs < <(stick fs T14FS)
unplug() { echo "{\"execute\": \"device_del\", \"arguments\": {\"id\": \"$1\"}}"; }
plug() { echo "{\"execute\": \"device_add\", \"arguments\": {\"driver\": \"usb-storage\", \"bus\": \"xhci.0\", \"drive\": \"$1\", \"id\": \"$1\", \"serial\": \"$2\", \"removable\": true}}"; }

# --- the test version (as in tools/titanic/extreme-load.sh: its own UKI, unsigned) -----------------
cat > "$media/kernel-from-uki.py" <<'EOF'
import sys
import pefile
pe = pefile.PE(sys.argv[1])
for s in pe.sections:
    name = {b".linux": "vmlinuz", b".initrd": "initramfs.img"}.get(s.Name.rstrip(b"\0"))
    if name:
        with open(f"{sys.argv[2]}/{name}", "wb") as f:
            f.write(s.get_data()[:s.Misc_VirtualSize])
EOF
printf 'FROM %s\nRUN rm -rf /boot/EFI\nRUN head -c 16777216 /dev/urandom > /usr/lib/nyra-test-payload\n' "$image" |
  sudo podman build -q -t localhost/nyra-test:removable-rootfs -f - "$media/context" >/dev/null
sudo podman run --rm --network none --tmpfs /tmp --tmpfs /var/tmp \
  --mount "type=image,source=localhost/nyra-test:removable-rootfs,target=/target" \
  -v "$media/kernel-from-uki.py:/kernel-from-uki.py:ro" -v "$media/uki:/out" "$image" \
  sh -c 'u="$(ls /boot/EFI/Linux/*.efi)" && k="$(basename "$u" .efi)" && mkdir -p "/tmp/kernel/$k" &&
    python3 /kernel-from-uki.py "$u" "/tmp/kernel/$k" &&
    bootc container ukify --rootfs /target --kernel-dir "/tmp/kernel/$k" -- --output "/out/$k.efi"' >/dev/null
printf 'FROM localhost/nyra-test:removable-rootfs\nCOPY --from=uki . /boot/EFI/Linux/\n' |
  sudo podman build -q -t localhost/nyra-test:removable --build-context uki="$media/uki" -f - "$media/context" >/dev/null
sudo podman rm -f nyra-test-registry >/dev/null 2>&1 || true # the one of an earlier step
# The next steps start a registry of the same name: this one goes, whatever happens here.
trap 'sudo podman rm -f nyra-test-registry >/dev/null 2>&1 || true' EXIT
tools/signing/local-registry.sh "$media"
sudo podman push -q --tls-verify=false --digestfile "$media/new.digest" localhost/nyra-test:removable \
  docker://other.test/nyra-test:removable
sudo chown "$(id -u):$(id -g)" "$media/new.digest"
new="$(cat "$media/new.digest")"
[[ "$new" =~ ^sha256:[0-9a-f]{64}$ ]]
echo "the test version: $new"

# --- guest commands ---------------------------------------------------------------------------------
# Each command ends with the status of its whole check (vm-boot.py reads only that). Variables set
# in one command are there in the next ones of the same boot: they run in one shell.
running='s="$(systemctl is-system-running --wait)"; echo "system: $s"; systemctl --no-pager --failed; test "$s" = running'
U=/dev/disk/by-label/T14UNTRUST T=/dev/disk/by-label/T14TRUSTED
# What the VM sees of the sticks; nothing from them is mounted or swapped to, and udisks2 has not
# even started: nothing mounts a stick before a user asks.
sticks='lsblk -o NAME,TRAN,RM,SIZE,PARTTYPENAME,FSTYPE,LABEL,MOUNTPOINTS; m="$(findmnt -rn -o SOURCE,TARGET | grep "^/dev/sd" || true)"; echo "mounted from the sticks: ${m:-nothing}"; w="$(swapon --show --noheadings)"; echo "swap: ${w:-none}"; test -z "$m" && test -z "$w" && ! systemctl -q is-active udisks2.service && echo "udisks2: not running"'
# squashfs: not a file system to udisks2 (usage "nyra-refused"), so not mounted; asked for by name on
# the FAT stick, it is not mounted either, since its module does not load.
foreign_fs='d="$(ls /dev/disk/by-id/usb-*T14FOREIGN* | head -1)" && udevadm info -q property --property=ID_FS_TYPE --property=ID_FS_USAGE "$d" && test "$(udevadm info -q property --property=ID_FS_USAGE --value "$d")" = nyra-refused && { udisksctl mount -b "$d" 2>&1 || true; } && ! findmnt --source "$d" >/dev/null && { udisksctl mount -b '"$U"' -t squashfs 2>&1 || true; } && ! findmnt --source '"$U"' >/dev/null && ! grep -qw squashfs /proc/filesystems && echo "squashfs: not mounted, by its type or by name, and its module not loaded"'
# The trusted stick into the list; udev applies the list (NYRA_MEDIA_TRUSTED), but only while
# nobody else can write it.
trust='u="$(lsblk -no UUID '"$T"')" && s="$(udevadm info -q property --property=ID_SERIAL --value '"$T"')" && echo "trusted: $u $s" && mkdir -p /etc/nyra && echo "$u $s" > /etc/nyra/trusted-media && t() { udevadm trigger --action=change --settle "$1" && udevadm info -q property --property=NYRA_MEDIA_TRUSTED --value "$1"; } && test "$(t '"$T"')" = 1 && test "$(t '"$U"')" = 0 && printf "# no newline at the end\n%s %s" "$u" "$s" > /etc/nyra/trusted-media && test "$(t '"$T"')" = 1 && echo "a last line without a newline: read" && chmod 666 /etc/nyra/trusted-media && test "$(t '"$T"')" = 0 && echo "the list writable by others: ignored" && chmod 644 /etc/nyra/trusted-media && test "$(t '"$T"')" = 1 && echo "the list owned by root, 0644: the trusted stick is trusted, the other one not"'
# exec, suid and dev cannot be asked for; then both mounted, with their options.
mount2='a=; for o in exec suid dev; do e="$(udisksctl mount -b '"$U"' -o "$o" 2>&1)"; echo "$e"; echo "$e" | grep -q "not allowed" || a=1; done; has() { echo "$1" | tr , "\n" | grep -qx "$2"; } && test -z "$a" && ! findmnt --source '"$U"' >/dev/null && udisksctl mount -b '"$U"' && udisksctl mount -b '"$T"' && mu="$(findmnt -rno TARGET --source '"$U"')" && mt="$(findmnt -rno TARGET --source '"$T"')" && ou="$(findmnt -rno OPTIONS --source '"$U"')" && ot="$(findmnt -rno OPTIONS --source '"$T"')" && echo "untrusted: $mu $ou" && echo "trusted: $mt $ot" && has "$ou" nosuid && has "$ou" nodev && has "$ou" noexec && has "$ot" nosuid && has "$ot" nodev && ! has "$ot" noexec'
# udisks2 runs with Nyra's hardening (udisks2.service.d/10-nyra.conf).
hardening='p="$(systemctl show -P RestrictAddressFamilies udisks2.service)"; n="$(systemctl show -P NoNewPrivileges udisks2.service)"; echo "udisks2: RestrictAddressFamilies=$p NoNewPrivileges=$n"; systemctl -q is-active udisks2.service && test "$p" = "AF_NETLINK AF_UNIX" && test "$n" = yes'
# The other file systems the udev rule lets through: ext4 and exFAT mount like the untrusted FAT
# stick (nosuid, nodev, noexec) and take a file.
other_fs='f=; for d in /dev/disk/by-label/t14-ext4:ext4 /dev/disk/by-label/T14EXFAT:exfat; do udisksctl mount -b "${d%:*}" && o="$(findmnt -rno TARGET,FSTYPE,OPTIONS --source "${d%:*}")" && echo "$o" && set -- $o && test "$2" = "${d#*:}" && for x in nosuid nodev noexec; do echo "$3" | tr , "\n" | grep -qx "$x" || f=1; done && echo t14 > "$1/t14" && udisksctl unmount -b "${d%:*}" || f=1; done; test -z "$f" && echo "ext4 and exFAT: mounted nosuid,nodev,noexec, written, unmounted"'
# A program on each (FAT shows .exe files as executable): it runs from the trusted stick only.
run='cp /usr/bin/true "$mu/true.exe" && cp /usr/bin/true "$mt/true.exe" && "$mt/true.exe" && echo "from the trusted stick: runs" && e="$("$mu/true.exe" 2>&1)"; echo "from the other one: $e"; echo "$e" | grep -q "Permission denied"'
# Written without a pause (32 MiB at a time, each flushed) until the stick is pulled out; 2 minutes
# at most. Then the writer has stopped, sync returns, the mount is gone, the other stick still works.
write_unplug='echo "writing to $mu"; timeout 120 sh -c "while dd if=/dev/zero of=\"\$1/t14-write\" bs=1M count=32 conv=fsync status=none; do :; done" sh "$mu" & w=$!; sleep 2; echo "@@UNPLUG""-WRITE@@"; wait $w; rc=$?; echo "writer: exit $rc"; test $rc = 0'
gone='for i in $(seq 30); do test -e '"$U"' || break; sleep 1; done; ! test -e '"$U"' && echo "the stick is gone" && timeout 60 sync && echo "sync: returned" && for i in $(seq 30); do findmnt "$mu" >/dev/null || break; sleep 1; done; findmnt "$mu"; ! findmnt "$mu" >/dev/null && echo "its mount is gone" && ls "$mt" && journalctl -k -b --no-pager | grep -iE "disconnect|I/O error" | tail -5; '"$running"
replug='echo "@@REPLUG""-1@@"; for i in $(seq 30); do test -e '"$U"' && break; sleep 1; done; test -e '"$U"' && udevadm settle && sleep 5 && ! findmnt --source '"$U"' && echo "plugged in again: not mounted" && udisksctl mount -b '"$U"' && findmnt -rno TARGET,OPTIONS --source '"$U"' && findmnt -rno OPTIONS --source '"$U"' | tr , "\n" | grep -qx noexec && udisksctl unmount -b '"$U"''
# A user in an active local session on seat0, as on a real machine: an autologin on a free virtual
# console (tty5, a getty drop-in in /run), made the foreground console (loginctl activate); the
# user's manager has a session of its own (class "manager"), so the test takes the one on tty5. polkit
# counts a session as local only when it has a seat. As root, pkcheck asks polkit about that
# session: it may mount a stick, but a file becomes a loop device or a disk is changed only
# with an administrator (49-nyra.toml). The process asked about is the user's shell (its .profile
# writes its PID; the session's leader, login, runs as root, which polkit allows everything,
# 10-root.toml). In the session itself (its .profile, once it is active), udisksctl loop-setup is
# refused, since nobody can give that password. nyra-polkit (docs/DEFAULTS.md, "polkit") is the one
# that answers, it read every rule file of the image and none is broken (it would deny everything),
# and no directory of JavaScript rules exists.
session_profile='echo $$ > /var/tmp/t14-session.pid
while [ ! -e /var/tmp/t14-go ]; do sleep 1; done
udisksctl loop-setup --read-only --no-user-interaction -f /var/tmp/t14-loop.img > /var/tmp/t14-session.out 2>&1
echo "udisksctl: $?" >> /var/tmp/t14-session.out
exec sleep 600'
autologin='[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin t14user --noclear - $TERM'
loop='id t14user >/dev/null 2>&1 || useradd -m t14user; rm -f /var/tmp/t14-go /var/tmp/t14-session.out /var/tmp/t14-session.pid; truncate -s 16M /var/tmp/t14-loop.img && mkfs.vfat /var/tmp/t14-loop.img >/dev/null && chmod 644 /var/tmp/t14-loop.img && h="$(getent passwd t14user | cut -d: -f6)" && echo '"$(printf %q "$session_profile")"' > "$h/.profile" && mkdir -p /run/systemd/system/getty@tty5.service.d && echo '"$(printf %q "$autologin")"' > /run/systemd/system/getty@tty5.service.d/autologin.conf && systemctl daemon-reload && systemctl start getty@tty5.service && s=""; for i in $(seq 30); do for x in $(loginctl show-user t14user -p Sessions --value 2>/dev/null); do test "$(loginctl show-session "$x" -p TTY --value)" = tty5 && s="$s $x"; done; test -n "$s" && break; sleep 1; done; s="${s# }"; echo "sessions of t14user: $(loginctl show-user t14user -p Sessions --value); on tty5: ${s:-none}"; case "$s" in "" | *" "*) echo "expected exactly one session on tty5"; s=none ;; esac; loginctl activate "$s"; for i in $(seq 10); do test "$(loginctl show-session "$s" -p Active --value)" = yes && break; sleep 1; done; v="$(loginctl show-session "$s" -p Seat -p TTY -p Active -p Remote -p Leader)"; echo "$v"; for i in $(seq 30); do test -s /var/tmp/t14-session.pid && break; sleep 1; done; l="$(cat /var/tmp/t14-session.pid)"; u="$(ps -o user= -p "$l")"; echo "the session'"'"'s shell: $l, user $u"; r=""; for a in filesystem-mount loop-setup modify-device; do pkcheck --action-id "org.freedesktop.udisks2.$a" --process "$l"; r="$r $a=$?"; done; echo "polkit:$r"; touch /var/tmp/t14-go; for i in $(seq 30); do grep -q "^udisksctl:" /var/tmp/t14-session.out 2>/dev/null && break; sleep 1; done; cat /var/tmp/t14-session.out; j="$(journalctl -b -u nyra-polkit.service -o cat --no-pager)"; echo "$j" | tail -12; o="$(busctl status org.freedesktop.PolicyKit1 | grep -E "^(Comm|Unit)=")"; echo "$o"; k=; for f in /usr/share/nyra-polkit/rules.d/*.toml; do echo "$j" | grep -qxF "read $f" || { echo "not read: $f"; k=1; }; done; for d in /etc/polkit-1/rules.d /usr/share/polkit-1/rules.d; do test -e "$d" && { echo "a directory of JavaScript rules: $d"; k=1; }; done; systemctl stop getty@tty5.service; rm -r /run/systemd/system/getty@tty5.service.d; systemctl daemon-reload; test "$s" != none && test "$u" = t14user && echo "$v" | grep -qx "Seat=seat0" && echo "$v" | grep -qx "Active=yes" && echo "$v" | grep -qx "Remote=no" && test "$r" = " filesystem-mount=0 loop-setup=2 modify-device=2" && grep -qx "udisksctl: 1" /var/tmp/t14-session.out && grep -qi "not authorized" /var/tmp/t14-session.out && ! losetup -j /var/tmp/t14-loop.img | grep -q . && echo "$o" | grep -qx "Comm=nyra-polkitd" && echo "$o" | grep -qx "Unit=nyra-polkit.service" && test -z "$k" && ! echo "$j" | grep -q "every check is denied" && echo "a user on seat0: mounts allowed, loop-setup and modify-device need an administrator"'
reg='mkdir -p /etc/containers/registries.conf.d && printf "[[registry]]\nlocation = \"10.0.2.2\"\ninsecure = true\n" > /etc/containers/registries.conf.d/99-ci-test.conf && sync'
digest() { # digest booted|staged: sets d to that deployment's image digest, or "none" (as in tools/vm/updates-guest.sh)
  local get='s="$(bootc status --format json)"; s="${s##*"\"staged\":"}";'
  if [ "$1" = booted ]; then get='s="$(bootc status --booted --format json)";'; fi
  echo "{ $get"' d="$(printf %s "$s" | grep -o "\"imageDigest\":\"[^\"]*\"" | head -1 | cut -d\" -f4)"; d="${d:-none}"; echo "'"$1"': $d"; }'
}
# The update while the stick is written, pulled out half a second after the switch starts. The
# stick comes from boot 1, where it was pulled out while written: fsck.vfat repairs it first, or a
# FAT error there can make it read-only and stop the writer before the pull. The pull comes only
# once the writer has written 1 MiB and while a dd runs. Then the writer must stop by itself, as in
# boot 1; 120 s at most, so that a writer that hangs fails here, with its state (wchan, kernel stack,
# the blocked tasks), before vm-boot.py stops waiting (300 s).
stuck='echo "the writer still runs $((SECONDS - ws)) s after it started"; grep -E "^(Dirty|Writeback):" /proc/meminfo; findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS "$mu" || echo "nothing mounted at $mu"; for x in $(pgrep -x dd); do ps -o pid,stat,wchan:32,cmd -p "$x"; cat "/proc/$x/stack"; done; dmesg | tail -n 20; echo w > /proc/sysrq-trigger'
update_unplug='fsck.vfat -a -w '"$U"'; echo "fsck.vfat: exit $?"; udisksctl mount -b '"$U"' && mu="$(findmnt -rno TARGET --source '"$U"')" && echo "writing to $mu"; ws=$SECONDS; timeout 120 sh -c "while dd if=/dev/zero of=\"\$1/t14-update\" bs=1M count=32 conv=fsync status=none; do :; done" sh "$mu" & w=$!; n=0; for i in $(seq 100); do n="$(stat -c %s "$mu/t14-update" 2>/dev/null || echo 0)"; test "$n" -ge 1048576 && break; sleep 0.1; done; echo "written before the update: $n bytes"; timeout 240 bootc switch --quiet 10.0.2.2/nyra-test:removable > /tmp/switch.log 2>&1 & b=$!; sleep 0.5; p=; for i in $(seq 20); do p="$(pgrep -x dd)" && break; sleep 0.05; done; echo "dd running: ${p:-none}"; kill -0 $b && echo "bootc switch: running" && test "$n" -ge 1048576 && test -n "$p" && echo "@@UNPLUG""-UPDATE@@"; r=$?; wait $b; rc=$?; cat /tmp/switch.log; echo "bootc switch: exit $rc"; while kill -0 $w 2>/dev/null && test $((SECONDS - ws)) -lt 110; do sleep 1; done; kill -0 $w 2>/dev/null && { '"$stuck"'; }; wait $w; wrc=$?; echo "writer: exit $wrc"; test -n "$mu" && test $r = 0 && test $rc = 0 && test $wrc = 0 && echo "the writer stopped by itself" && '"$(digest staged)"' && test "$d" = '"$new"
# A boot with sticks: root and the ESP from the boot disk (vda), as /dev/gpt-auto-root.
boot_disk='r="$(findmnt -rno SOURCE /sysroot)"; b="$(findmnt -rno SOURCE /boot)"; a="$(readlink -f /dev/gpt-auto-root)"; echo "root: $r, ESP: $b, gpt-auto-root: $a"; case "$r $b $a" in "/dev/vda"*" /dev/vda"*" /dev/vda"*) echo "all on the boot disk" ;; *) false ;; esac'
# The stick is gone, nothing waits for it.
after_boot='for i in $(seq 30); do test -e /dev/disk/by-label/T14ESP || break; sleep 1; done; ! test -e /dev/disk/by-label/T14ESP && echo "the stick is gone" && j="$(systemctl list-jobs --no-legend)"; echo "jobs: ${j:-none}"; test -z "$j" && { journalctl -k -b -o short-monotonic --no-pager | grep -m1 -i "USB disconnect" || echo "no USB disconnect in the kernel log: pulled out before the kernel started"; } && systemd-analyze'

ov="$media/disk.qcow2"
qemu-img create -q -f qcow2 -F qcow2 -b "$disk" "$ov"
vm() { # vm N TITLE [vm-boot.py options and --command ...]
  python3 -B tools/vm/vm-boot.py --autologin --persist --poweroff --disk "$ov" --timeout 240 \
    --log "$logs/serial-removable-media-$1.log" --summary "$summary" --title "Removable media $1: $2" "${@:3}"
}

vm 1 "trusted, untrusted and refused sticks, one pulled out during a write, plugged in again" \
  "${xhci[@]}" "${untrusted[@]}" "${trusted[@]}" "${foreign[@]}" "${fs[@]}" \
  --qmp "@@UNPLUG-WRITE@@=>$(unplug untrusted)" --qmp "@@REPLUG-1@@=>$(plug untrusted T14UNTRUSTED)" \
  --command "$running" --command "$sticks" --command "$foreign_fs" --command "$trust" --command "$mount2" \
  --command "$other_fs" --command "$hardening" --command "$run" --command "$write_unplug" --command "$gone" \
  --command "$replug" --command "$loop"

vm 2 "pulled out during an update" "${xhci[@]}" "${untrusted[@]}" \
  --qmp "@@UNPLUG-UPDATE@@=>$(unplug untrusted)" \
  --command "$running && $reg" --command "$update_unplug" --command "$running"

vm 3 "a stick with ESP, root, swap and /home partitions at boot" "${xhci[@]}" "${system[@]}" "${untrusted[@]}" \
  --command "$(digest booted) && test \$d = $new" --command "$running" --command "$sticks" \
  --command 't="$(lsblk -dno PARTTYPE /dev/disk/by-label/T14ESP /dev/disk/by-label/t14-root /dev/disk/by-label/t14-swap /dev/disk/by-label/t14-home | tr "\n" " ")"; echo "the stick'"'"'s partition types: $t"; test "$t" = "c12a7328-f81f-11d2-ba4b-00a0c93ec93b 4f68bce3-e8cd-4db1-96e7-fbcaf984b709 0657fd6d-a4ab-43c4-84e5-0933c84b4f4f 933ac7e1-2eb4-4f13-b844-0e14e2aef915 "' \
  --command "$boot_disk"

n=4
for t in 3 6 10; do
  vm "$n" "the stick with system partitions pulled out ${t} s after QEMU starts" "${xhci[@]}" "${system[@]}" \
    --qmp "${t}s=>$(unplug system)" --command "$running" --command "$after_boot" --command "$boot_disk"
  n=$((n + 1))
done

rm -f "$ov" "$media"/*.raw
