#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: the secure defaults of an installed system (docs/DEFAULTS.md), checked in
# one boot of the installed test disk (QEMU snapshot mode, the disk is not changed):
# AppArmor on with profiles in enforce mode, kernel lockdown "integrity", the inbound firewall
# (default deny, proven with a connection from a network namespace), only declared listening
# sockets, only declared running services, timers and sockets (the units blocked in the
# Containerfile stay inactive), the signature policy in place and owned by root, unused
# filesystems not autoloaded.
# Each guest command must end with the status of its whole check: vm-boot.py reads only the last
# status and the guest shell has no set -e or pipefail, so checks are joined with && and loops set
# a flag. --self-test runs the parsing-heavy commands against stubs, without a VM (shellcheck job).
#   tools/vm/security-defaults.sh DISK.qcow2 LOGDIR SUMMARY
#   tools/vm/security-defaults.sh --self-test
set -euo pipefail

# Every listening socket after boot must match one line: "<proto> <local address:port> <process>".
# resolved's stub listens on loopback only (LLMNR and mDNS are off); networkd's DHCP clients bind
# their client ports. Anything new needs a reason and a line here.
read -r -d '' allowed <<'EOF' || true
(udp|tcp) 127\.0\.0\.5[34](%lo)?:53 systemd-resolve
udp [^ ]+:68 systemd-network
udp [^ ]+:546 systemd-network
EOF
listening='s="$(ss -Htulnp)" && test -n "$s" && l="$(echo "$s" | awk '"'"'{p=$7; sub(/^users:\(\("/,"",p); sub(/".*/,"",p); print $1" "$5" "p}'"'"')" && echo "$l" && u="$(echo "$l" | grep -vxE "'"${allowed//$'\n'/|}"'" || true)" && { test -z "$u" || { echo "undeclared listening sockets: $u"; false; }; }'

# Every running service, waiting timer and listening socket unit must match this list. Network
# sockets are checked above; systemd's own sockets are local (AF_UNIX, varlink), and userdbd and
# hostnamed are started through them on demand (user lookups at login, hostname queries). getty and
# user@ come from the console login. Anything new needs a reason and a line here, or a block in
# the Containerfile.
read -r -d '' units_allowed <<'EOF' || true
dbus\.(service|socket)
systemd-(journald|logind|networkd|resolved|udevd|userdbd|hostnamed)\.service
systemd-[a-z0-9-]+\.socket
(serial-)?getty@[a-zA-Z0-9]+\.service
user@[0-9]+\.service
(fstrim|systemd-tmpfiles-clean)\.timer
EOF
units='s="$(systemctl list-units --type=service,timer,socket --state=running,waiting,listening --no-legend --plain)" && test -n "$s" && u="$(echo "$s" | awk "{print \$1}")" && echo "$u" && x="$(echo "$u" | grep -vxE "'"${units_allowed//$'\n'/|}"'" || true)" && { test -z "$x" || { echo "undeclared units: $x"; false; }; }'
# The units blocked in the Containerfile ("no purpose in the base") are all exactly "inactive"
# (an error from systemctl, "active" or "failed" all count against it).
blocked='b="$(grep -l "no purpose in the base" /usr/lib/systemd/system/*.d/10-nyra.conf | sed "s|.*/\([^/]*\)\.d/10-nyra.conf|\1|")"; echo $b; a=; for u in $b; do st="$(systemctl is-active "$u")"; test "$st" = inactive || { echo "$u: ${st:-error}"; a=1; }; done; test "$(echo "$b" | wc -l)" -ge 13 && test -z "$a"'

if [ "${1:-}" = --self-test ]; then
  t="$(mktemp -d)"
  trap 'rm -rf "$t"' EXIT
  for i in $(seq -w 1 13); do
    mkdir -p "$t/u$i.service.d" && echo "# Nyra: no purpose in the base image" > "$t/u$i.service.d/10-nyra.conf"
  done
  ss() { [ -z "${FAIL:-}" ] || return 1
    printf '%s\n' 'udp UNCONN 0 0 127.0.0.53%lo:53 0.0.0.0:* users:(("systemd-resolve",pid=1,fd=1))' ${EXTRA:+"$EXTRA"}; }
  systemctl() { [ -z "${FAIL:-}" ] || return 1
    case "$1" in
      is-active) for u; do :; done # the last argument; like systemctl: prints unless --quiet, 3 if not active
        if [ "$u" = "${ACTIVE:-}" ]; then [ "$2" = --quiet ] || echo active
        else [ "$2" = --quiet ] || echo inactive; return 3; fi ;;
      *) printf '%s\n' 'dbus.service loaded active running D-Bus' 'fstrim.timer loaded active waiting x' ${EXTRA:+"$EXTRA"} ;;
    esac; }
  fail=0
  check() { # check WANT NAME COMMAND [VAR=value ...]
    local want="$1" name="$2" cmd="$3" got=0
    shift 3
    env "$@" bash -c "$(declare -f ss systemctl); ${cmd//\/usr\/lib\/systemd\/system/$t}" >/dev/null 2>&1 || got=$?
    if [ "$got" = "$want" ]; then echo "ok: $name"; else echo "FAILED: $name (exit $got, want $want)"; fail=1; fi
  }
  check 0 "listening: declared only" "$listening"
  check 1 "listening: undeclared sshd" "$listening" EXTRA='tcp LISTEN 0 5 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=9,fd=3))'
  check 1 "listening: ss fails" "$listening" FAIL=1
  check 0 "units: declared only" "$units"
  check 1 "units: undeclared podman.socket" "$units" EXTRA='podman.socket loaded active listening x'
  check 1 "units: systemctl fails" "$units" FAIL=1
  check 0 "blocked: all inactive" "$blocked"
  check 1 "blocked: the first one active" "$blocked" ACTIVE=u01.service
  check 1 "blocked: one in the middle active" "$blocked" ACTIVE=u07.service
  check 1 "blocked: the last one active" "$blocked" ACTIVE=u13.service
  check 1 "blocked: systemctl fails" "$blocked" FAIL=1
  rm -r "$t/u13.service.d"
  check 1 "blocked: only 12 units blocked" "$blocked"
  exit "$fail"
fi
disk="$1" logs="$2" summary="$3"

# Inbound default deny, proven from outside the host's own addresses: a veth pair into a network
# namespace, a listener on the host side, a TCP connection from the namespace must time out; with
# an explicit accept rule the same connection works (so the drop was the firewall, not routing).
firewall_probe='ip netns add probe && ip link add v0 type veth peer name v1 netns probe && ip addr add 192.0.2.1/24 dev v0 && ip link set v0 up && ip -n probe addr add 192.0.2.2/24 dev v1 && ip -n probe link set v1 up && { python3 -m http.server 8080 --bind 192.0.2.1 >/dev/null 2>&1 & } && sleep 2 && ss -Htln "sport = :8080" | grep -q . && ! ip netns exec probe timeout 3 bash -c "echo > /dev/tcp/192.0.2.1/8080" && echo "inbound tcp/8080 from the probe namespace: dropped" && nft insert rule inet nyra input iifname v0 tcp dport 8080 accept && ip netns exec probe timeout 3 bash -c "echo > /dev/tcp/192.0.2.1/8080" && echo "with an explicit accept rule: connected"'

# Unused filesystems are blacklisted (no autoload on mount); what people plug in still mounts.
filesystems='modprobe --showconfig | grep -x "blacklist f2fs" && ! modprobe --showconfig | grep -xE "blacklist (vfat|exfat|ntfs3|ext4|btrfs|xfs|udf|isofs|hfsplus|squashfs|erofs|overlay)" && truncate -s 64M /tmp/fs.img && ! mount -o loop -t f2fs /tmp/fs.img /mnt && ! grep -qw f2fs /proc/filesystems && echo "f2fs: not autoloaded" && mkfs.vfat /tmp/fs.img >/dev/null && mount -o loop /tmp/fs.img /mnt && findmnt /mnt && umount /mnt'

python3 -B tools/vm/vm-boot.py --autologin --disk "$disk" --timeout 240 \
  --log "$logs/serial-security-defaults.log" --summary "$summary" --title "Secure defaults" \
  --command 's="$(systemctl is-system-running --wait)"; echo "system: $s"; systemctl --no-pager --failed; test "$s" = running' \
  --command 'cat /sys/kernel/security/lsm; echo; test "$(cat /sys/module/apparmor/parameters/enabled)" = Y && systemctl is-active apparmor.service && p=/sys/kernel/security/apparmor/profiles && echo "profiles: $(wc -l < $p), enforce: $(grep -c "(enforce)" $p)" && grep -q "(enforce)" $p' \
  --command 'cat /sys/kernel/security/lockdown; grep -q "\[integrity\]" /sys/kernel/security/lockdown' \
  --command 'systemctl is-active nyra-firewall.service && nft list chain inet nyra input && nft list chain inet nyra input | grep -q "policy drop"' \
  --command "$listening" \
  --command "$units" \
  --command "$blocked" \
  --command "$firewall_probe" \
  --command 'p="$(readlink -f /etc/containers/policy.json)"; echo "$p"; test "$p" = /usr/lib/nyra/containers/policy.json && stat -c "%U:%G %a" "$p" && test "$(stat -c "%U:%G" "$p")" = root:root && test "$(( 0$(stat -c %a "$p") & 022 ))" = 0 && grep -q sigstoreSigned "$p"' \
  --command "$filesystems"
