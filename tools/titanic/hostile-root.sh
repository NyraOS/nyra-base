#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only (titanic.yml): Titanic T12, a hostile root (docs/TITANIC.md). One system on a copy of the
# installed test disk, with Secure Boot on (the image's UKI certificate enrolled as a MOK) and one
# firmware variable store for all boots, as in tools/vm/reset-settings.sh:
#   1  apt and dpkg, with /usr checked against a checksum taken before them (every path with its
#      type, mode, owner, size and link target, and every file's content): apt, apt-get, dpkg -i and
#      dpkg --install of a package with a file in /usr/bin fail and say what to use instead (the
#      Store, Distrobox), and the file is not there. Debian's dpkg itself (/usr/lib/nyra/dpkg),
#      past that message, fails with "Read-only file system". Control: the same package installs
#      under a writable --root, and dpkg's queries (-l, -L, -S, --status) find it there.
#      An unsigned kernel module: the signature of an in-tree module (dummy) is cut off, and insmod
#      of that copy is refused by the kernel's signature check. Control: the same copy with its
#      signature loads. Root cannot lower the lockdown ("none" refused); raising it
#      works (control).
#   2  rm -rf --no-preserve-root /: /usr and the ESP have the same checksums after it (the ESP:
#      every path and every file's content, so that a partial delete, which the next boot would
#      repair, still fails), and EFI/BOOT/BOOTX64.EFI is still the image's shim; control: what rm
#      could reach is gone (markers in /etc and /var). The "Nyra OS Reset settings" entry is picked
#      for the next boot first (bootctl set-oneshot, as a user would in the boot menu); then sync
#      and a power cut (rm leaves no working shutdown). The ESP as rm left it goes into the summary.
#   3  the next boot: the Reset settings entry. /etc is empty, so the boot counts as a first boot,
#      but systemd-firstboot asks nothing (it does not run on the reset entry): the first question is
#      the reset's. RESET; the system restarts by itself into the normal boot: running, /usr the same
#      as before rm, /etc the image's (root, locked, and the signature policy link), Secure Boot and
#      the lockdown on, the "Nyra OS" firmware entry back. The console of both boots shows no
#      first-boot question, and apparmor.service finished in the reset boot (the image's profiles
#      from /usr).
# The setup (the disk copy, the variable store with the MOKs, the test console add-on) is
# tools/titanic/secure-boot-system.sh. Every boot runs even if one before it failed; the step fails
# if any did.
#   tools/titanic/hostile-root.sh IMAGE DISK.qcow2 UKI_CERT WORKDIR LOGDIR SUMMARY
set -euo pipefail

image="$1" disk="$2" uki_cert="$3" work="$4" logs="$5" summary="$6"
# shellcheck source=tools/titanic/secure-boot-system.sh
. tools/titanic/secure-boot-system.sh "$image" "$disk" "$uki_cert" "$work/hostile-root" "$summary"

# --- guest commands ---------------------------------------------------------------------------------
# As in tools/titanic/secure-boot-system.sh: each ends with the status of its whole check, and no "!"
# right before a word inside double quotes.
# Every path under /usr with its type, mode, owner, size and link target, and the content of every
# file: two checksums, printed as "nyra-usr: <16 hex>-<16 hex>" (the host reads it from the log).
usrsum='u="$(find /usr -xdev -printf "%y %m %U %G %s %p %l\n" | LC_ALL=C sort | sha256sum | cut -c1-16)-$(find /usr -xdev -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16)" && echo "nyra""-usr: $u"'

# The same for the ESP, mounted read-only at /boot: "ESP: <16 hex>-<16 hex>".
espsum='e="$(find /boot -xdev -printf "%y %m %U %G %s %p %l\n" | LC_ALL=C sort | sha256sum | cut -c1-16)-$(find /boot -xdev -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16)" && echo "ESP: $e"'
fallback='cmp /boot/EFI/BOOT/BOOTX64.EFI /usr/lib/shim/shimx64.efi.signed && echo "EFI/BOOT/BOOTX64.EFI is the image'"'"'s shim"'

# What apt, apt-get and an install with dpkg print instead (/usr/lib/nyra/no-apt), in "$o".
says='echo "$o" | grep -q "Install apps from the Store (Flatpak)" && echo "$o" | grep -q "use apt in a Distrobox container: distrobox create, then distrobox enter"'
apt='f=0; for c in apt apt-get; do o="$($c install -y hello 2>&1)"; r=$?; echo "$c install: exit $r: $o"; test $r != 0 && '"$says"' || f=1; done; test $f = 0'
# A package with one file in /usr/bin.
deb='p=/var/tmp/nyra-t12-pkg && rm -rf $p && mkdir -p $p/DEBIAN $p/usr/bin && printf "Package: nyra-t12-test\nVersion: 1\nArchitecture: all\nMaintainer: Nyra OS CI\nDescription: Titanic T12 test package\n" > $p/DEBIAN/control && echo installed > $p/usr/bin/nyra-t12-test && dpkg-deb --root-owner-group -b $p /var/tmp/nyra-t12.deb && dpkg-deb -c /var/tmp/nyra-t12.deb'
dpkg='f=0; for a in -i --install; do o="$(dpkg $a /var/tmp/nyra-t12.deb 2>&1)"; r=$?; echo "dpkg $a: exit $r: $o"; test $r != 0 && '"$says"' || f=1; done; test $f = 0 && test ! -e /usr/bin/nyra-t12-test'
# Debian's dpkg, past the message. The image has no dpkg database; dpkg makes an empty one in
# /var/lib/dpkg and gets as far as /usr.
dpkg_real='o="$(/usr/lib/nyra/dpkg -i /var/tmp/nyra-t12.deb 2>&1)"; r=$?; echo "/usr/lib/nyra/dpkg -i: exit $r: $o"; test $r != 0 && echo "$o" | grep -q "Read-only file system" && test ! -e /usr/bin/nyra-t12-test'
dpkg_control='d=/var/tmp/nyra-t12-root && mkdir -p $d/var/lib/dpkg && /usr/lib/nyra/dpkg --root=$d -i /var/tmp/nyra-t12.deb && test -f $d/usr/bin/nyra-t12-test && echo "the same package installs under $d (control)"'
# dpkg's queries, through /usr/bin/dpkg, on that package.
dpkg_query='d=/var/tmp/nyra-t12-root && dpkg --root=$d -l nyra-t12-test | grep -E "^ii +nyra-t12-test " && dpkg --root=$d -L nyra-t12-test | grep -x /usr/bin/nyra-t12-test && dpkg --root=$d -S /usr/bin/nyra-t12-test | grep -x "nyra-t12-test: /usr/bin/nyra-t12-test" && dpkg --root=$d --status nyra-t12-test | grep -x "Status: install ok installed" && echo "dpkg -l, -L, -S and --status work"'

# The module's signature (appended: the signature, struct module_signature of 12 bytes ending with
# the signature's length, the marker) cut off; both copies uncompressed.
strip="$(base64 -w0 <<'EOF'
import lzma, subprocess, sys
src, signed, unsigned = sys.argv[1:]
if src.endswith(".xz"):
    data = lzma.open(src).read()
elif src.endswith(".zst"):
    data = subprocess.run(["zstd", "-dcq", src], check=True, capture_output=True).stdout
else:
    data = open(src, "rb").read()
marker = b"~Module signature appended~\n"
assert data.startswith(b"\x7fELF") and data.endswith(marker), "not a signed module"
n = int.from_bytes(data[-len(marker) - 4:-len(marker)], "big")
open(signed, "wb").write(data)
open(unsigned, "wb").write(data[:-len(marker) - 12 - n])
print(f"{src}: {len(data)} bytes, signature of {n} bytes cut off")
EOF
)"
module="m=\"\$(modinfo -n dummy)\" && echo \"\$m\" && ! grep -q '^dummy ' /proc/modules && echo $strip | base64 -d > /var/tmp/strip-sig.py && python3 /var/tmp/strip-sig.py \"\$m\" /var/tmp/dummy-signed.ko /var/tmp/dummy-unsigned.ko"
# Refused by the kernel's signature check: with Secure Boot it enforces module signatures ("Key was
# rejected by service"); with the lockdown alone it would be "Operation not permitted". Either way the
# kernel says why; a broken file would give "Invalid module format" instead.
unsigned='o="$(insmod /var/tmp/dummy-unsigned.ko 2>&1)"; r=$?; echo "insmod of the unsigned copy: exit $r: $o"; k="$(dmesg | grep -E "Loading of unsigned module is rejected|unsigned module loading is restricted" | tail -1)"; echo "kernel: $k"; test $r != 0 && test -n "$k" && echo "$o" | grep -Eq "Key was rejected by service|Operation not permitted" && ! grep -q "^dummy " /proc/modules'
signed='insmod /var/tmp/dummy-signed.ko && grep "^dummy " /proc/modules && rmmod dummy && echo "the signed copy loads (control)"'
lockdown='echo none > /sys/kernel/security/lockdown; r=$?; cat /sys/kernel/security/lockdown; test $r != 0 && grep -q "\[integrity\]" /sys/kernel/security/lockdown && echo confidentiality > /sys/kernel/security/lockdown && grep -q "\[confidentiality\]" /sys/kernel/security/lockdown && echo "lowering refused, raising works (control)"'

answer='Type RESET to reset, anything else or Control-D to boot normally: '
fail=0

vm --poweroff --log "$logs/serial-hostile-root-1.log" \
  --title "Hostile root 1: apt and dpkg cannot change /usr and say what to use instead; an unsigned module is refused" \
  --command "$running" \
  --command "$secure" \
  --command "$usrsum && u0=\"\$u\"" \
  --command "$apt" \
  --command "$deb" \
  --command "$dpkg" \
  --command "$dpkg_real" \
  --command "$dpkg_control" \
  --command "$dpkg_query" \
  --command "$module" \
  --command "$unsigned" \
  --command "$signed" \
  --command "$usrsum && test \"\$u\" = \"\$u0\" && echo '/usr unchanged'" \
  --command "$lockdown" || fail=1

vm --log "$logs/serial-hostile-root-2.log" --power-cut-at 'nyra-t12: power cut' \
  --title "Hostile root 2: rm -rf --no-preserve-root /; /usr unchanged" \
  --command "$running" \
  --command 'echo t12 > /etc/nyra-t12-marker && echo t12 > /var/nyra-t12-marker && bootctl set-oneshot nyra-reset.CONF && echo "next boot: Reset settings (as picked in the boot menu)"' \
  --command "$usrsum && u0=\"\$u\"" \
  --command "$espsum && e0=\"\$e\" && $fallback" \
  --command 'findmnt -rn -o TARGET,FSTYPE,OPTIONS | grep -Ev "^/(proc|sys|dev)/"; ls -A /boot; efibootmgr; true' \
  --command 'time rm -rf --no-preserve-root / 2>&1 | tail -n 5; echo "rm: exit ${PIPESTATUS[0]}"' \
  --command "$usrsum && findmnt -T /usr -no FSTYPE,OPTIONS && test \"\$u\" = \"\$u0\" && echo '/usr unchanged'" \
  --command "$espsum && findmnt -T /boot -no FSTYPE,OPTIONS && test \"\$e\" = \"\$e0\" && echo 'the ESP unchanged' && $fallback" \
  --command 'timeout 20 ls -A /boot; timeout 20 efibootmgr; echo "left in /etc: $(ls -A /etc | wc -l), in /var: $(ls -A /var | wc -l)"; test ! -e /etc/nyra-t12-marker && test ! -e /var/nyra-t12-marker && echo "rm removed what it could reach (control)"' \
  --command 'sync && echo "nyra-t12: power"" cut"' || fail=1

# What rm left on the ESP.
esp ro
{
  echo "### Hostile root: the ESP after rm -rf /"
  echo
  echo '```'
  sudo find "$mnt" -mindepth 1 -maxdepth 3 -printf '%P\n' | LC_ALL=C sort | head -40 || true
  echo '```'
  echo
} >> "$summary"
unesp

u0="$(grep -ao 'nyra-usr: [0-9a-f]*-[0-9a-f]*' "$logs/serial-hostile-root-2.log" | head -1 | cut -d' ' -f2 || true)"
echo "/usr before rm: ${u0:-not found}"

vm --poweroff --log "$logs/serial-hostile-root-3.log" --chat "$answer=>RESET" \
  --chat-then-login --title "Hostile root 3: Reset settings from the boot menu, then the normal boot" \
  --command "$running" \
  --command "$usrsum && test \"\$u\" = '$u0' && echo '/usr unchanged'" \
  --command 'grep "^root:" /etc/passwd && readlink /etc/containers/policy.json && test "$(readlink /etc/containers/policy.json)" = /usr/lib/nyra/containers/policy.json && echo "/etc is the image'"'"'s"' \
  --command "grep '^root:' /etc/shadow | cut -d: -f1,2 && grep -q '^root:[!*]' /etc/shadow && ! grep -q '^root:!unprovisioned:' /etc/shadow && echo 'root is locked'" \
  --command "$secure" \
  --command 'efibootmgr; efibootmgr | grep -q "Nyra OS"' || fail=1
# A first-boot question would stop the boot before the reset's (the chat above then times out);
# this names it. When systemd-firstboot runs, the console shows "Initial Setup..." (starting) and
# "Initial Setup." (finished), and "Please enter the new ..." for each question (systemd 262); a
# skipped unit is at most "Initial Setup skipped, ...".
if grep -aE 'Initial Setup\.|Please enter the new' "$logs/serial-hostile-root-3.log"; then
  echo "hostile root 3: systemd-firstboot ran or asked a question"
  fail=1
fi
# AppArmor in the reset boot, with /etc empty: the profiles of the image from /usr. Up to the reset
# question, the console must show apparmor.service finished and never failed.
reset_boot="$(sed -n '1,/Type RESET to reset/p' "$logs/serial-hostile-root-3.log")"
if ! grep -aq 'Finished.*apparmor\.service' <<<"$reset_boot" || grep -a 'Failed to start.*apparmor\.service' <<<"$reset_boot"; then
  echo "hostile root 3: AppArmor did not start in the reset boot"
  fail=1
fi

exit "$fail"
