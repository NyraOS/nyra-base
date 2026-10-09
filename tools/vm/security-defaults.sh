#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: the secure defaults of an installed system (NyraOS T15, docs/DEFAULTS.md), checked in
# one boot of the installed test disk (QEMU snapshot mode, the disk is not changed):
# AppArmor on with profiles in enforce mode, kernel lockdown "integrity", the inbound firewall
# (default deny, proven with a connection from a network namespace), only declared listening
# sockets, the signature policy in place and owned by root, unused filesystems not autoloaded.
#   tools/vm/security-defaults.sh DISK.qcow2 LOGDIR SUMMARY
set -euo pipefail

disk="$1" logs="$2" summary="$3"

# Every listening socket after boot must match one line: "<proto> <local address:port> <process>".
# resolved's stub listens on loopback only (LLMNR and mDNS are off); networkd's DHCP clients bind
# their client ports. Anything new needs a reason and a line here.
read -r -d '' allowed <<'EOF' || true
(udp|tcp) 127\.0\.0\.5[34](%lo)?:53 systemd-resolve
udp [^ ]+:68 systemd-network
udp [^ ]+:546 systemd-network
EOF
listening='l="$(ss -Htulnp | awk '"'"'{p=$7; sub(/^users:\(\("/,"",p); sub(/".*/,"",p); print $1" "$5" "p}'"'"')"; echo "$l"; u="$(echo "$l" | grep -vxE "^$|'"${allowed//$'\n'/|}"'" || true)"; test -z "$u" || { echo "undeclared listening sockets: $u"; false; }'

# Inbound default deny, proven from outside the host's own addresses: a veth pair into a network
# namespace, a listener on the host side, a TCP connection from the namespace must time out; with
# an explicit accept rule the same connection works (so the drop was the firewall, not routing).
firewall_probe='ip netns add probe && ip link add v0 type veth peer name v1 netns probe && ip addr add 192.0.2.1/24 dev v0 && ip link set v0 up && ip -n probe addr add 192.0.2.2/24 dev v1 && ip -n probe link set v1 up && { python3 -m http.server 8080 --bind 192.0.2.1 >/dev/null 2>&1 & } && sleep 2 && ss -Htln "sport = :8080" | grep -q . && ! ip netns exec probe timeout 3 bash -c "echo > /dev/tcp/192.0.2.1/8080" && echo "inbound tcp/8080 from the probe namespace: dropped" && nft insert rule inet nyra input iifname v0 tcp dport 8080 accept && ip netns exec probe timeout 3 bash -c "echo > /dev/tcp/192.0.2.1/8080" && echo "with an explicit accept rule: connected"'

# Unused filesystems are blacklisted (no autoload on mount); what people plug in still mounts.
filesystems='modprobe --showconfig | grep -x "blacklist f2fs" && ! modprobe --showconfig | grep -xE "blacklist (vfat|exfat|ntfs3|ext4|btrfs|xfs|udf|isofs|hfsplus|squashfs|erofs|overlay)" && truncate -s 64M /tmp/fs.img && ! mount -o loop -t f2fs /tmp/fs.img /mnt && ! grep -qw f2fs /proc/filesystems && echo "f2fs: not autoloaded" && mkfs.vfat /tmp/fs.img >/dev/null && mount -o loop /tmp/fs.img /mnt && findmnt /mnt && umount /mnt'

python3 -B tools/vm/vm-boot.py --autologin --disk "$disk" --timeout 240 \
  --log "$logs/serial-security-defaults.log" --summary "$summary" --title "Secure defaults (T15)" \
  --command 's="$(systemctl is-system-running --wait)"; echo "system: $s"; systemctl --no-pager --failed; test "$s" = running' \
  --command 'cat /sys/kernel/security/lsm; echo; test "$(cat /sys/module/apparmor/parameters/enabled)" = Y && systemctl is-active apparmor.service && p=/sys/kernel/security/apparmor/profiles && echo "profiles: $(wc -l < $p), enforce: $(grep -c "(enforce)" $p)" && grep -q "(enforce)" $p' \
  --command 'cat /sys/kernel/security/lockdown; grep -q "\[integrity\]" /sys/kernel/security/lockdown' \
  --command 'systemctl is-active nyra-firewall.service && nft list chain inet nyra input && nft list chain inet nyra input | grep -q "policy drop"' \
  --command "$listening" \
  --command "$firewall_probe" \
  --command 'p="$(readlink -f /etc/containers/policy.json)"; echo "$p"; test "$p" = /usr/lib/nyra/containers/policy.json && stat -c "%U:%G %a" "$p" && test "$(stat -c "%U:%G" "$p")" = root:root && test "$(( 0$(stat -c %a "$p") & 022 ))" = 0 && grep -q sigstoreSigned "$p"' \
  --command "$filesystems"
