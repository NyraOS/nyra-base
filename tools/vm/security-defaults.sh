#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: the secure defaults of an installed system (docs/DEFAULTS.md), checked in
# one boot of the installed test disk (QEMU snapshot mode, the disk is not changed):
# AppArmor on with profiles in enforce mode, kernel lockdown "integrity", the inbound firewall
# (default deny, proven with a connection from a network namespace), only declared listening
# sockets, only declared running services, timers and sockets (the units blocked in the
# Containerfile stay inactive), the signature policy in place and owned by root, unused
# filesystems not autoloaded, the ESP read-only at /boot, no kernel audit lines on the console
# (with a control) while the journal keeps them. Containers follow the same inbound default deny
# (tools/vm/container-ports-guest.sh): a rootful published port (IPv4 and IPv6) is reachable on the
# machine and not from the network, and a container still reaches out.
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
# user@ come from the console login. ntpd-rs keeps the clock right (NTS, outbound only).
# nyra-etc-copy.timer makes the daily copy of /etc (docs/BOOT.md, "Restore earlier settings").
# Anything new needs a reason and a line here, or a block in the Containerfile.
read -r -d '' units_allowed <<'EOF' || true
dbus\.(service|socket)
ntpd-rs\.service
systemd-(journald|logind|networkd|resolved|udevd|userdbd|hostnamed)\.service
systemd-[a-z0-9-]+\.socket
(serial-)?getty@[a-zA-Z0-9]+\.service
user@[0-9]+\.service
(fstrim|systemd-tmpfiles-clean|nyra-updated|nyra-etc-copy)\.timer
EOF
units='s="$(systemctl list-units --type=service,timer,socket --state=running,waiting,listening --no-legend --plain)" && test -n "$s" && u="$(echo "$s" | awk "{print \$1}")" && echo "$u" && x="$(echo "$u" | grep -vxE "'"${units_allowed//$'\n'/|}"'" || true)" && { test -z "$x" || { echo "undeclared units: $x"; false; }; }'
# The units blocked in the Containerfile ("no purpose in the base") are all exactly "inactive"
# (an error from systemctl, "active" or "failed" all count against it).
blocked='b="$(grep -l "no purpose in the base" /usr/lib/systemd/system/*.d/10-nyra.conf | sed "s|.*/\([^/]*\)\.d/10-nyra.conf|\1|")"; echo $b; a=; for u in $b; do st="$(systemctl is-active "$u")"; test "$st" = inactive || { echo "$u: ${st:-error}"; a=1; }; done; test "$(echo "$b" | wc -l)" -ge 33 && test -z "$a"'

# Kernel messages on the console (docs/DEFAULTS.md): the guest prints @@CONSOLE-QUIET@@, restarts
# systemd-timedated (a unit start and BPF program loads, each an audit record), prints
# @@CONSOLE-LOUD@@, raises the console threshold for the control, restarts it again and prints
# @@CONSOLE-END@@. The quotes keep the typed command line from matching the markers.
# console_noise LOG FROM TO prints how many kernel audit lines (and summaries of their rate limit)
# the console shows from one marker to the next.
console_noise() {
  sed -n "/@@CONSOLE-$2@@/,/@@CONSOLE-$3@@/p" "$1" | grep -a -c -E '\] (audit: type=|kauditd_printk_skb)' || true
}
console='echo @@CONSOLE'"''"'-QUIET@@ && cat /proc/consoles && cat /proc/sys/kernel/printk && test "$(awk "{print \$1}" /proc/sys/kernel/printk)" = 4 && sleep 6 && t="$(date +%s)" && systemctl restart systemd-timedated.service && sleep 5 && a="$(journalctl -b --no-pager --since "@$t" _TRANSPORT=audit)" && echo "$a" | grep -m1 "unit=systemd-timedated" && echo "$a" | grep -m1 "op=LOAD" && journalctl -k -b --no-pager --since "@$t" | grep -m1 "audit: type=" && echo "the audit records are in the journal" && echo @@CONSOLE'"''"'-LOUD@@ && echo 7 > /proc/sys/kernel/printk && sleep 6 && systemctl restart systemd-timedated.service && sleep 5 && echo 4 > /proc/sys/kernel/printk && echo @@CONSOLE'"''"'-END@@'

if [ "${1:-}" = --self-test ]; then
  t="$(mktemp -d)"
  trap 'rm -rf "$t"' EXIT
  for i in $(seq -w 1 33); do
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
  check 1 "blocked: one in the middle active" "$blocked" ACTIVE=u16.service
  check 1 "blocked: the last one active" "$blocked" ACTIVE=u33.service
  check 1 "blocked: systemctl fails" "$blocked" FAIL=1
  rm -r "$t/u33.service.d"
  check 1 "blocked: only 32 units blocked" "$blocked"
  # The console of a run: the typed command line and the journal lines the guest prints are not
  # kernel lines on the console.
  typed='root@localhost:~# echo @@CONSOLE'"''"'-QUIET@@ && ... grep -m1 "audit: type=" && echo @@CONSOLE'"''"'-LOUD@@'
  noise=$'[   18.595741] audit: type=1334 audit(1792301761.207:222): prog-id=78 op=LOAD\r'
  printf '%s\n' "$typed" '@@CONSOLE-QUIET@@' \
    'Oct 18 09:56:01 localhost kernel: audit: type=1334 audit(1792301761.207:222): prog-id=78 op=LOAD' '@@CONSOLE-LOUD@@' "$noise" \
    '[   24.1] kauditd_printk_skb: 3 callbacks suppressed' '@@CONSOLE-END@@' "$noise" > "$t/quiet.log"
  printf '%s\n' '@@CONSOLE-QUIET@@' '[   19.0] kauditd_printk_skb: 391 callbacks suppressed' '@@CONSOLE-LOUD@@' \
    '@@CONSOLE-END@@' > "$t/suppressed.log"
  printf '%s\n' '@@CONSOLE-QUIET@@' "$noise" '@@CONSOLE-LOUD@@' '@@CONSOLE-END@@' > "$t/audit.log"
  for c in "quiet.log QUIET LOUD 0" "quiet.log LOUD END 2" "suppressed.log QUIET LOUD 1" "audit.log QUIET LOUD 1" \
    "audit.log LOUD END 0"; do
    set -- $c
    got="$(console_noise "$t/$1" "$2" "$3")"
    if [ "$got" = "$4" ]; then echo "ok: console: $c"; else echo "FAILED: console: $c (got $got)"; fail=1; fi
  done
  exit "$fail"
fi
disk="$1" logs="$2" summary="$3"

# The guest script of the container port checks, typed in pieces the console takes (as in updates.sh).
ports_script=/var/tmp/container-ports-guest.sh
b64="$(base64 -w0 <tools/vm/container-ports-guest.sh)"
ports=(--command ": > $ports_script.b64")
for ((i = 0; i < ${#b64}; i += 1500)); do
  ports+=(--command "printf %s ${b64:i:1500} >> $ports_script.b64")
done
ports+=(--command "base64 -d $ports_script.b64 > $ports_script && bash $ports_script")

# Authenticated time: no systemd-timesyncd and no chrony; ntp-daemon (ntpd-rs) runs as its dynamic
# user (the unit's UID, in systemd's dynamic range 61184-65519; ps shows no name for it) with
# CAP_SYS_TIME only (bit 25), no new privileges, under its seccomp filter and its AppArmor profile
# in enforce mode, with no AppArmor denial in this boot, and with our configuration of exactly
# four NTS sources; every source it has is NTS (synchronization itself is checked in
# tools/vm/updates.sh, T9). Its systemd exposure is at most chronyd-restricted's (1.9).
# systemd-timedated reports that service as the NTP service, and turning automatic time on
# (timedatectl set-ntp true, the desktop's switch) keeps exactly that one.
time_client='! systemctl cat systemd-timesyncd.service >/dev/null 2>&1 && ! systemctl cat chrony.service >/dev/null 2>&1 && systemctl is-active ntpd-rs.service && p="$(systemctl show -P MainPID ntpd-rs.service)" && ps -o uid=,args= -p "$p" && u="$(ps -o uid= -p "$p" | tr -d " ")" && test "$u" = "$(systemctl show -P UID ntpd-rs.service)" && test "$u" -ge 61184 && test "$u" -le 65519 && test "$(ps -o args= -p "$p")" = "/usr/bin/ntp-daemon --config /usr/lib/nyra/ntpd-rs/ntp.toml" && grep -e "^Cap" -e "^NoNewPrivs" -e "^Seccomp:" "/proc/$p/status" && test "$(awk "/^CapEff/ {print \$2}" "/proc/$p/status")" = 0000000002000000 && grep -q "^NoNewPrivs:[[:space:]]*1$" "/proc/$p/status" && grep -q "^Seccomp:[[:space:]]*2$" "/proc/$p/status" && cat "/proc/$p/attr/apparmor/current" && test "$(cat "/proc/$p/attr/apparmor/current")" = "ntp-daemon (enforce)" && ! journalctl -b -o cat --no-pager | grep -F "apparmor=\"DENIED\"" | grep -F "profile=\"ntp-daemon\"" && c=/usr/lib/nyra/ntpd-rs/ntp.toml && test "$(grep -c "^mode = " "$c")" = 4 && test "$(grep -c "^mode = \"nts\"$" "$c")" = 4 && s="$(ntp-ctl -c "$c" status)" && echo "$s" && ! echo "$s" | sed -n "/^Sources:/,\$p" | grep -v "^Sources:" | grep "^[^[:space:]]" | grep -vF "[NTS]" && e="$(systemd-analyze security --no-pager ntpd-rs.service | tail -1)" && echo "$e" && echo "$e" | awk "{for (i = 1; i < NF; i++) if (\$i ~ /^[0-9.]+$/) x = \$i} END {exit !(x != \"\" && x <= 1.9)}"'
time_switch='timedatectl show -p NTP && test "$(timedatectl show -p NTP --value)" = yes && timedatectl set-ntp true && sleep 3 && systemctl is-active ntpd-rs.service && test "$(systemctl is-enabled ntpd-rs.service)" = enabled && test "$(ps -o uid= -p "$(systemctl show -P MainPID ntpd-rs.service)" | tr -d " ")" = "$(systemctl show -P UID ntpd-rs.service)" && echo "set-ntp true: ntpd-rs only"'

# Inbound default deny, proven from outside the host's own addresses: a veth pair into a network
# namespace, a listener on the host side, a TCP connection from the namespace must time out; with
# an explicit accept rule the same connection works (so the drop was the firewall, not routing).
firewall_probe='ip netns add probe && ip link add v0 type veth peer name v1 netns probe && ip addr add 192.0.2.1/24 dev v0 && ip link set v0 up && ip -n probe addr add 192.0.2.2/24 dev v1 && ip -n probe link set v1 up && { python3 -m http.server 8080 --bind 192.0.2.1 >/dev/null 2>&1 & } && sleep 2 && ss -Htln "sport = :8080" | grep -q . && ! ip netns exec probe timeout 3 bash -c "echo > /dev/tcp/192.0.2.1/8080" && echo "inbound tcp/8080 from the probe namespace: dropped" && nft insert rule inet nyra input iifname v0 tcp dport 8080 accept && ip netns exec probe timeout 3 bash -c "echo > /dev/tcp/192.0.2.1/8080" && echo "with an explicit accept rule: connected"'

# Unused filesystems are blacklisted (no autoload on mount); what people plug in still mounts.
filesystems='modprobe --showconfig | grep -x "blacklist f2fs" && modprobe --showconfig | grep -x "blacklist hfsplus" && modprobe --showconfig | grep -x "blacklist squashfs" && ! modprobe --showconfig | grep -xE "blacklist (vfat|exfat|ntfs|ext4|btrfs|xfs|udf|isofs|erofs|overlay)" && truncate -s 64M /tmp/fs.img && ! mount -o loop -t f2fs /tmp/fs.img /mnt && ! grep -qw f2fs /proc/filesystems && echo "f2fs: not autoloaded" && mkfs.vfat /tmp/fs.img >/dev/null && mount -o loop /tmp/fs.img /mnt && findmnt /mnt && umount /mnt'

# The ESP: the only FAT mount, read-only at /boot, and a write there fails (only esp-writable makes
# it writable, in a mount namespace of its own).
esp='m="$(findmnt -rn -t vfat -o TARGET,OPTIONS)"; echo "$m"; e="$(touch /boot/nyra-probe 2>&1)"; echo "touch: $e"; test "$(echo "$m" | wc -l)" = 1 && test "${m%% *}" = /boot && echo "${m#* }" | tr , "\n" | grep -qx ro && test -f /boot/EFI/BOOT/BOOTX64.EFI && echo "$e" | grep -q "Read-only file system" && test ! -e /boot/nyra-probe && echo "the ESP is read-only at /boot"'

# Rust components (docs/DEFAULTS.md): su is sudo-rs's, setuid root, and there is no sudo; the zlib
# that programs load is zlib-rs; the core utilities are uutils'.
rust='su --version 2>&1 | grep "^su-rs " && test "$(stat -c "%a %U" /usr/bin/su)" = "4755 root" && ! command -v sudo && echo "su: sudo-rs, setuid root; no sudo" && grep -aq zlib-rs "$(readlink -f /usr/lib/x86_64-linux-gnu/libz.so.1)" && echo "libz.so.1: zlib-rs" && ls --version | head -1 && ls --version | grep -q "(uutils coreutils)"'

fail=0
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
  "${ports[@]}" \
  --command 'p="$(readlink -f /etc/containers/policy.json)"; echo "$p"; test "$p" = /usr/lib/nyra/containers/policy.json && stat -c "%U:%G %a" "$p" && test "$(stat -c "%U:%G" "$p")" = root:root && test "$(( 0$(stat -c %a "$p") & 022 ))" = 0 && grep -q sigstoreSigned "$p"' \
  --command "$filesystems" \
  --command "$time_client" \
  --command "$time_switch" \
  --command "$esp" \
  --command "$rust" \
  --command "$console" || fail=1

# The console threshold (docs/DEFAULTS.md): no kernel audit line on the console while it holds, and
# some once it is raised (the control: the same restart does print them, so their absence counts).
# Without the end marker the guest command failed, and vm-boot.py has reported it.
log="$logs/serial-security-defaults.log"
quiet="$(console_noise "$log" QUIET LOUD)" loud="$(console_noise "$log" LOUD END)"
echo "kernel audit lines on the console: $quiet with the image's threshold, $loud with it raised"
if grep -aq '@@CONSOLE-END@@' "$log" && { [ "$quiet" != 0 ] || [ "$loud" = 0 ]; }; then
  echo "::error::kernel audit lines on the console: $quiet with the image's threshold (want 0), $loud with it raised (want some)"
  fail=1
fi
exit "$fail"
