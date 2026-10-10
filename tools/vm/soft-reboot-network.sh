#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: the network across soft reboots and the full boots after them, ROUNDS times on one
# installed test disk (docs/UPDATES.md). Each round is one VM session:
#   full boot (the version the last round soft-rebooted into, first counted boot): network up
#   bootc switch --soft-reboot=required --apply to a new test version: network up again
#   clean shutdown
# The test versions differ only in a marker file; a throwaway registry on the runner serves them as
# 10.0.2.2 (QEMU user networking). On a failure the guest prints systemd-networkd's journal (debug
# level, set on the test disk) and the link state.
#   tools/vm/soft-reboot-network.sh IMAGE DISK.qcow2 WORKDIR LOGDIR SUMMARY [ROUNDS]
set -euo pipefail

image="$1" disk="$2" work="$3" logs="$4" summary="$5" rounds="${6:-2}"
[[ "$rounds" =~ ^[1-9][0-9]?$ ]] || { echo "ROUNDS must be 1-99, not '$rounds'" >&2; exit 2; }
s="$work/soft-reboot-network"
mkdir -p "$s/context"

# Test versions with their own UKI, as in tools/vm/boot-counting.sh.
cat >"$s/kernel-from-uki.py" <<'EOF'
import sys
import pefile
pe = pefile.PE(sys.argv[1])
for s in pe.sections:
    name = {b".linux": "vmlinuz", b".initrd": "initramfs.img"}.get(s.Name.rstrip(b"\0"))
    if name:
        with open(f"{sys.argv[2]}/{name}", "wb") as f:
            f.write(s.get_data()[:s.Misc_VirtualSize])
EOF
for i in $(seq "$rounds"); do
  printf 'FROM %s\nRUN rm -rf /boot/EFI && echo round-%s > /usr/lib/nyra-test-version\n' "$image" "$i" |
    sudo podman build -q -t "localhost/nyra-test:r$i-rootfs" -f - "$s/context" >/dev/null
  mkdir -p "$s/r$i-uki"
  sudo podman run --rm --network none --tmpfs /tmp --tmpfs /var/tmp \
    --mount "type=image,source=localhost/nyra-test:r$i-rootfs,target=/target" \
    -v "$s/kernel-from-uki.py:/kernel-from-uki.py:ro" -v "$s/r$i-uki:/out" "$image" \
    sh -c 'u="$(ls /boot/EFI/Linux/*.efi)" && k="$(basename "$u" .efi)" && mkdir -p "/tmp/kernel/$k" &&
      python3 /kernel-from-uki.py "$u" "/tmp/kernel/$k" &&
      bootc container ukify --rootfs /target --kernel-dir "/tmp/kernel/$k" -- --output "/out/$k.efi"' >/dev/null
  printf 'FROM localhost/nyra-test:r%s-rootfs\nCOPY --from=uki . /boot/EFI/Linux/\n' "$i" |
    sudo podman build -q -t "localhost/nyra-test:r$i" --build-context uki="$s/r$i-uki" -f - "$s/context" >/dev/null
done

sudo podman rm -f nyra-test-registry >/dev/null 2>&1 || true
tools/signing/local-registry.sh "$s"
for i in $(seq "$rounds"); do
  sudo podman push -q --tls-verify=false "localhost/nyra-test:r$i" "docker://other.test/nyra-test:r$i"
done

cp "$disk" "$s/disk.qcow2"
vm() { # vm ROUND TITLE --command ...
  python3 -B tools/vm/vm-boot.py --autologin --persist --poweroff --disk "$s/disk.qcow2" --timeout 240 \
    --log "$logs/serial-soft-reboot-network-$1.log" --summary "$summary" \
    --title "Network across soft reboots, round $1 of $rounds: $2" "${@:3}"
}
# The system is running (systemd-networkd-wait-online passed) and the registry answers; otherwise
# networkd's view of it, for the log.
net='s="$(systemctl is-system-running --wait)"; echo "system: $s"; if test "$s" = running && systemctl is-active --quiet systemd-networkd-wait-online.service && curl -fsS -o /dev/null --max-time 10 http://10.0.2.2/v2/; then echo "network: up"; else systemctl --no-pager --failed; networkctl status --all --no-pager; ip -br address; journalctl -b -u systemd-networkd -u systemd-networkd-wait-online -o short-monotonic --no-pager | tail -150; false; fi'
setup='mkdir -p /etc/containers/registries.conf.d /etc/systemd/system/systemd-networkd.service.d && printf "[[registry]]\nlocation = \"10.0.2.2\"\ninsecure = true\n" > /etc/containers/registries.conf.d/99-ci-test.conf && printf "[Service]\nEnvironment=SYSTEMD_LOG_LEVEL=debug\n" > /etc/systemd/system/systemd-networkd.service.d/50-ci-debug.conf'

for i in $(seq "$rounds"); do
  extra=()
  [ "$i" != 1 ] || extra=(--command "$setup")
  vm "$i" "full boot, then a soft reboot into r$i" \
    "${extra[@]}" \
    --command "$net" \
    --command "@reboot bootc switch --quiet --soft-reboot=required --apply 10.0.2.2/nyra-test:r$i" \
    --command "grep -x round-$i /usr/lib/nyra-test-version && $net"
done
