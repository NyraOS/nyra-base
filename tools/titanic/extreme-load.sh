#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only (titanic.yml): Titanic T13, an update under extreme load (docs/TITANIC.md). On a
# copy-on-write copy of the installed test disk, updated with plain `bootc switch` to a test version
# of IMAGE (16 MiB of its own and its own UKI, served by a throwaway registry on the runner that the
# VM reaches as 10.0.2.2, no signatures, as in tools/titanic/power-cuts.sh):
#   1  load: 8 busy loops on 2 vCPUs, memory taken until less than 200 MiB is available (the
#      out-of-memory killer may stop anything, bootc too), and the disk written and flushed without
#      a pause; the load is checked before the update (load average, available memory). Then the
#      update: it either succeeds with exactly the test version staged, or fails with nothing staged.
#      The load is stopped; clean shutdown.
#   2  the next boot: the old version or the test version, running; the update completes without
#      load (switched again if it had failed), one reboot into the test version, running.
# The VM has 2 vCPUs and 2 GiB, like every test VM here.
#   tools/titanic/extreme-load.sh IMAGE IMAGE_DIGEST DISK.qcow2 WORKDIR LOGDIR SUMMARY
set -euo pipefail

image="$1" old="$2" disk="$3" work="$4" logs="$5" summary="$6"
el="$work/extreme-load"
mkdir -p "$el/context" "$el/uki"

# --- the test version (as in tools/titanic/power-cuts.sh: its own UKI, unsigned) -------------------
cat > "$el/kernel-from-uki.py" <<'EOF'
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
  sudo podman build -q -t localhost/nyra-test:load-rootfs -f - "$el/context" >/dev/null
sudo podman run --rm --network none --tmpfs /tmp --tmpfs /var/tmp \
  --mount "type=image,source=localhost/nyra-test:load-rootfs,target=/target" \
  -v "$el/kernel-from-uki.py:/kernel-from-uki.py:ro" -v "$el/uki:/out" "$image" \
  sh -c 'u="$(ls /boot/EFI/Linux/*.efi)" && k="$(basename "$u" .efi)" && mkdir -p "/tmp/kernel/$k" &&
    python3 /kernel-from-uki.py "$u" "/tmp/kernel/$k" &&
    bootc container ukify --rootfs /target --kernel-dir "/tmp/kernel/$k" -- --output "/out/$k.efi"' >/dev/null
printf 'FROM localhost/nyra-test:load-rootfs\nCOPY --from=uki . /boot/EFI/Linux/\n' |
  sudo podman build -q -t localhost/nyra-test:load --build-context uki="$el/uki" -f - "$el/context" >/dev/null
sudo podman rm -f nyra-test-registry >/dev/null 2>&1 || true # the one of tools/titanic/full-disk.sh
tools/signing/local-registry.sh "$el"
sudo podman push -q --tls-verify=false --digestfile "$el/new.digest" localhost/nyra-test:load docker://other.test/nyra-test:load
sudo chown "$(id -u):$(id -g)" "$el/new.digest"
new="$(cat "$el/new.digest")"
[[ "$new" =~ ^sha256:[0-9a-f]{64}$ ]]
echo "old version: $old, new version: $new"

# --- guest commands ---------------------------------------------------------------------------------
reg='mkdir -p /etc/containers/registries.conf.d && printf "[[registry]]\nlocation = \"10.0.2.2\"\ninsecure = true\n" > /etc/containers/registries.conf.d/99-ci-test.conf && sync'
# bootc waits forever for a registry that stops answering (docs/LESSONS.md).
switch='timeout 900 bootc switch --quiet 10.0.2.2/nyra-test:load'
digest() { # digest booted|staged: sets d to that deployment's image digest, or "none" (as in tools/vm/updates-guest.sh)
  local get='s="$(bootc status --format json)"; s="${s##*"\"staged\":"}";'
  if [ "$1" = booted ]; then get='s="$(bootc status --booted --format json)";'; fi
  echo "{ $get"' d="$(printf %s "$s" | grep -o "\"imageDigest\":\"[^\"]*\"" | head -1 | cut -d\" -f4)"; d="${d:-none}"; echo "'"$1"': $d"; }'
}
running='{ s="$(systemctl is-system-running --wait)"; echo "system: $s"; systemctl --no-pager --failed; test "$s" = running; }'
# The load, in units of its own so it can be stopped: 8 busy loops, memory taken and written until
# less than 200 MiB is available, and 256 MiB written and flushed again and again; a minute for the
# load average to rise.
load='systemd-run -q --unit=nyra-load-cpu sh -c "for i in 1 2 3 4 5 6 7 8; do (while :; do :; done) & done; wait" && systemd-run -q --unit=nyra-load-mem python3 -c "import time; m = int(open(\"/proc/meminfo\").read().split(\"MemAvailable:\")[1].split()[0]) * 1024; b = bytearray(b\"1\") * (m - 200 * 2**20); time.sleep(3600)" && systemd-run -q --unit=nyra-load-io sh -c "while :; do dd if=/dev/zero of=/var/tmp/nyra-load bs=1M count=256 conv=fsync status=none; done" && sleep 60'
# The load is there: load average above 3 (2 vCPUs), less than 300 MiB available.
loaded='l="$(cut -d" " -f1 /proc/loadavg)"; m="$(awk "/MemAvailable/ {print int(\$2 / 1024)}" /proc/meminfo)"; echo "load average $l, $m MiB available"; systemctl is-active nyra-load-cpu nyra-load-io; test "${l%%.*}" -ge 3 && test "$m" -lt 300'
stop='systemctl stop nyra-load-cpu nyra-load-mem nyra-load-io; systemctl reset-failed; rm -f /var/tmp/nyra-load; journalctl -k -b --no-pager | grep -i "out of memory" || echo "no out-of-memory kill"'

ov="$el/disk.qcow2"
qemu-img create -q -f qcow2 -F qcow2 -b "$disk" "$ov"
vm() { # vm N TITLE [vm-boot.py options and --command ...]
  python3 -B tools/vm/vm-boot.py --autologin --persist --disk "$ov" --timeout 240 \
    --log "$logs/serial-extreme-load-$1.log" --summary "$summary" --title "Extreme load $1: $2" "${@:3}"
}

vm 1 "the update under load: staged exactly, or failed with nothing staged" --poweroff \
  --command "$running && $reg" \
  --command "$load && $loaded" \
  --command "start=\$SECONDS; $switch; rc=\$?; echo \"bootc switch: exit \$rc after \$((SECONDS - start)) s\"; $(digest staged) && { test \$rc = 0 && test \$d = $new || { test \$rc != 0 && test \$d = none; }; }" \
  --command "$loaded; $stop"

vm 2 "the next boot runs; the update completes without load" --poweroff \
  --command "$(digest booted) && { test \$d = $old || test \$d = $new; }" \
  --command "$running" \
  --command "$(digest booted) && { test \$d = $new || { $switch && $(digest staged) && test \$d = $new; }; }" \
  --command '@reboot systemctl reboot' \
  --command "$(digest booted) && test \$d = $new" \
  --command "$running"
