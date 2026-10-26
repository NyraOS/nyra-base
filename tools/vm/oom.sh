#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: running out of memory (docs/DEFAULTS.md, "Running out of memory"). One boot of the
# installed test disk (QEMU snapshot mode, the disk is not changed; 2 vCPUs and 2 GiB, like every test
# VM here). In the guest, as root:
#   1  the setup: zram swap of half the RAM compressed with zstd, the kernel settings for it,
#      systemd-oomd enabled and watching the user's manager.
#   2  a program of the user's manager that takes memory without end (incompressible, about 50 MiB
#      a second), next to a small one that only sleeps. systemd-oomd must close the first one
#      because of memory pressure, the second one must live, and the system must still answer and be
#      `running`. The kernel's own out-of-memory killer must not have been needed.
#   tools/vm/oom.sh DISK.qcow2 LOGDIR SUMMARY
set -euo pipefail

disk="$1" logs="$2" summary="$3"

setup='test "$(systemctl is-enabled systemd-oomd.service)" = enabled && systemctl is-active systemd-oomd.service && ram="$(awk "/MemTotal/ {print \$2}" /proc/meminfo)" && swap="$(awk "\$1 == \"/dev/zram0\" {print \$3}" /proc/swaps)" && prio="$(awk "\$1 == \"/dev/zram0\" {print \$5}" /proc/swaps)" && echo "RAM $ram KiB, zram swap $swap KiB, priority $prio" && test -n "$swap" && test "$prio" = 100 && test "$swap" -gt $((ram * 45 / 100)) && test "$swap" -le $((ram / 2 + 1024)) && cat /sys/block/zram0/comp_algorithm && grep -q "\[zstd\]" /sys/block/zram0/comp_algorithm && test "$(sysctl -n vm.swappiness)" = 180 && test "$(sysctl -n vm.page-cluster)" = 0 && o="$(oomctl)" && echo "$o" && echo "$o" | grep -q "user@0.service"'

# 50 MiB of random bytes a second: slow enough that systemd-oomd (20 s of pressure) acts before the
# kernel has to.
hog='import time; b = []; [(b.append(__import__("os").urandom(1 << 20)), time.sleep(0.02)) for _ in iter(int, 1)]'
um='--machine=0@.host --user'
start="systemd-run $um --unit=nyra-oom-bystander --collect sleep 3600 && systemd-run $um --unit=nyra-oom-hog --collect python3 -c '$hog' && sleep 2 && systemctl $um is-active nyra-oom-bystander nyra-oom-hog"
# Up to 5 minutes for the hog to be gone.
drain='for i in $(seq 100); do systemctl '"$um"' is-active -q nyra-oom-hog || break; sleep 3; done; free -m; systemctl '"$um"' is-active nyra-oom-hog; test "$(systemctl '"$um"' is-active nyra-oom-hog)" != active'
after='journalctl -b --no-pager -u systemd-oomd | tail -5; journalctl -b --no-pager -u systemd-oomd | grep -E "Killed .*nyra-oom-hog.* due to memory pressure" && ! journalctl -k -b --no-pager | grep -i "out of memory" && systemctl '"$um"' is-active nyra-oom-bystander && s="$(systemctl is-system-running --wait)" && echo "system: $s" && test "$s" = running && echo "systemd-oomd closed the program that took the memory; the other one and the system are alive"'

python3 -B tools/vm/vm-boot.py --autologin --disk "$disk" --timeout 400 \
  --log "$logs/serial-oom.log" --summary "$summary" --title "Running out of memory" \
  --command 's="$(systemctl is-system-running --wait)"; echo "system: $s"; systemctl --no-pager --failed; test "$s" = running' \
  --command "$setup" \
  --command "$start" \
  --command "$drain" \
  --command "$after"
