#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: boots without a network (docs/DEFAULTS.md, "Without a network"), on the installed test
# disk in QEMU snapshot mode (the disk is not changed). Two boots:
#   1. the cable unplugged from the start (vm-boot.py --no-carrier: the NIC's link down before the
#      CPU starts): the system is running, no unit failed, nothing waited for the network
#      (systemd-networkd-wait-online never started) and graphical.target came within 60 s; an
#      update check started then waits for the network for longer than wait-online's 2 minutes,
#      and nothing fails
#   2. with the network: nothing waited for it at boot either; with the link taken down, an update
#      check waits; once the link is up again, the check runs within 90 s and succeeds
# Each guest command must end with the status of its whole check (vm-boot.py reads only the last
# status), so checks are joined with &&.
#   tools/vm/no-network.sh DISK.qcow2 LOGDIR SUMMARY
set -euo pipefail

disk="$1" logs="$2" summary="$3"

# The system is running, no unit failed, and nothing pulled in network-online.target at boot.
boot='{ s="$(systemctl is-system-running --wait)"; echo "system: $s"; systemctl --no-pager --failed; w="$(systemctl is-active systemd-networkd-wait-online.service network-online.target | sort -u)"; echo "systemd-networkd-wait-online.service, network-online.target: $w"; t="$(systemctl show -P ActiveEnterTimestampMonotonic graphical.target)"; echo "graphical.target $((t / 1000000)) s after the kernel started"; test "$s" = running && test "$w" = inactive && test "$t" -gt 0 && test "$t" -lt 60000000; }'
online='busctl get-property org.freedesktop.network1 /org/freedesktop/network1 org.freedesktop.network1.Manager OnlineState'
# An update check started now waits for the network: nyra-updated.service has not started, its
# start job waits, nyra-updated-wait-online.service is still waiting, and nothing failed.
waiting='{ j="$(systemctl list-jobs --no-legend --no-pager nyra-updated.service)"; echo "job: $j"; w="$(systemctl is-active nyra-updated-wait-online.service)"; echo "nyra-updated-wait-online.service: $w, memory $(systemctl show -P MemoryCurrent nyra-updated-wait-online.service) bytes"; s="$(systemctl is-system-running)"; echo "system: $s"; systemctl --no-pager --failed; test "$(systemctl show -P ExecMainStartTimestampMonotonic nyra-updated.service)" = 0 && echo "$j" | grep -qw start && test "$w" = activating && test "$s" = running; }'

python3 -B tools/vm/vm-boot.py --autologin --disk "$disk" --timeout 240 --no-carrier \
  --log "$logs/serial-no-network-unplugged.log" --summary "$summary" \
  --title "Without a network: the cable unplugged from the start" \
  --command "networkctl list --no-legend --no-pager && networkctl list --no-legend --no-pager | grep -qw no-carrier && $online && $online | grep -q offline" \
  --command "$boot" \
  --command "systemctl start --no-block nyra-updated.service && echo 'waiting 150 s, past the 2 minutes of systemd-networkd-wait-online' && sleep 150 && $waiting"

# The link down and up from inside the guest: vm-boot.py cannot plug the cable in during a run.
link='d="$(ip -o link show | awk -F": " "\$2 != \"lo\" { print \$2; exit }")"'
until_state='{ for _ in $(seq 60); do '"$online"' | grep -q "$want" && break; sleep 1; done; '"$online"' | grep -q "$want"; }'
ran='{ for i in $(seq 90); do test "$(systemctl show -P ExecMainStartTimestampMonotonic nyra-updated.service)" != 0 && test "$(systemctl show -P ActiveState nyra-updated.service)" = inactive && break; sleep 1; done; echo "the check ended about $i s after the link came up"; systemctl show -p Result -p ExecMainStatus nyra-updated.service; cat /var/lib/nyra-updated/last-check.json; echo; s="$(systemctl is-system-running)"; echo "system: $s"; systemctl --no-pager --failed; test "$(systemctl show -P ActiveState nyra-updated.service)" = inactive && test "$(systemctl show -P Result nyra-updated.service)" = success && test "$s" = running; }'

python3 -B tools/vm/vm-boot.py --autologin --disk "$disk" --timeout 240 \
  --log "$logs/serial-no-network-back.log" --summary "$summary" \
  --title "Without a network: the link down, then back" \
  --command "$boot" \
  --command "$link && echo \"link: \$d\" && ip link set dev \"\$d\" down && want=offline && $until_state && systemctl start --no-block nyra-updated.service && sleep 10 && $waiting" \
  --command "$link && ip link set dev \"\$d\" up && want='\"online\"' && $until_state && $ran"
