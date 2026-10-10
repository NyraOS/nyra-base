#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: boot counting across real updates, on a copy of the installed test disk (docs/BOOT.md).
# Two test versions of IMAGE are served by a throwaway registry on the runner, which the VM reaches
# as 10.0.2.2 (QEMU user networking):
# - unhealthy: a unit required by boot-complete.target fails, so the boot is never marked good;
# - healthy: only a marker file differs (a new composefs digest, so a new deployment).
# The VM follows one system through six boots:
#   1. installed version: switch to unhealthy (nyra-boot-counter gives it "+3" at shutdown)
#   2-4. unhealthy, tries 1-3: "+2-1", "+1-2", "+0-3", never blessed
#   5. systemd-boot falls back to the installed version by itself; switch to healthy
#   6. healthy, first try: boot-complete.target reached, systemd-bless-boot drops the counter
#   tools/vm/boot-counting.sh IMAGE IMAGE_DIGEST DISK.qcow2 WORKDIR LOGDIR SUMMARY
set -euo pipefail

image="$1" image_digest="$2" disk="$3" work="$4" logs="$5" summary="$6"
bc="$work/boot-counting"
mkdir -p "$bc/context"

# A test version is IMAGE plus one change, so its composefs digest differs and its UKI must be
# rebuilt (docs/BOOT.md): from the committed root filesystem, with the kernel and initramfs taken
# out of IMAGE's UKI. Unsigned: these boots run without Secure Boot.
cat > "$bc/kernel-from-uki.py" <<'EOF'
import sys
import pefile
pe = pefile.PE(sys.argv[1])
for s in pe.sections:
    name = {b".linux": "vmlinuz", b".initrd": "initramfs.img"}.get(s.Name.rstrip(b"\0"))
    if name:
        with open(f"{sys.argv[2]}/{name}", "wb") as f:
            f.write(s.get_data()[:s.Misc_VirtualSize])
EOF
test_version() { # test_version TAG: the change comes on stdin, as Containerfile RUN lines
  local t="$1"
  { echo "FROM $image"; echo "RUN rm -rf /boot/EFI"; cat; } | sudo podman build -q -t "localhost/nyra-test:$t-rootfs" -f - "$bc/context"
  mkdir -p "$bc/$t-uki"
  sudo podman run --rm --network none --tmpfs /tmp --tmpfs /var/tmp \
    --mount "type=image,source=localhost/nyra-test:$t-rootfs,target=/target" \
    -v "$bc/kernel-from-uki.py:/kernel-from-uki.py:ro" -v "$bc/$t-uki:/out" "$image" \
    sh -c 'u="$(ls /boot/EFI/Linux/*.efi)" && k="$(basename "$u" .efi)" && mkdir -p "/tmp/kernel/$k" &&
      python3 /kernel-from-uki.py "$u" "/tmp/kernel/$k" &&
      bootc container ukify --rootfs /target --kernel-dir "/tmp/kernel/$k" -- --output "/out/$k.efi"'
  printf 'FROM localhost/nyra-test:%s-rootfs\nCOPY --from=uki . /boot/EFI/Linux/\n' "$t" |
    sudo podman build -q -t "localhost/nyra-test:$t" --build-context uki="$bc/$t-uki" -f - "$bc/context"
}
test_version unhealthy <<'EOF'
RUN printf '%s\n' '[Unit]' 'Description=Test only: a health check that always fails' \
      'Before=boot-complete.target' '[Service]' 'Type=oneshot' 'ExecStart=/usr/bin/false' \
      > /usr/lib/systemd/system/nyra-test-unhealthy.service && \
    mkdir -p /usr/lib/systemd/system/boot-complete.target.requires && \
    ln -s ../nyra-test-unhealthy.service /usr/lib/systemd/system/boot-complete.target.requires/
EOF
test_version healthy <<'EOF'
RUN echo healthy > /usr/lib/nyra-test-version
EOF
tools/signing/local-registry.sh "$bc"
for t in unhealthy healthy; do
  sudo podman push -q --tls-verify=false --digestfile "$bc/$t.digest" \
    "localhost/nyra-test:$t" "docker://other.test/nyra-test:$t"
done
unhealthy="$(cat "$bc/unhealthy.digest")" healthy="$(cat "$bc/healthy.digest")"
[[ "$unhealthy" =~ ^sha256:[0-9a-f]{64}$ && "$healthy" =~ ^sha256:[0-9a-f]{64}$ ]]

cp "$disk" "$bc/disk.qcow2"
n=0
vm() {
  n=$((n + 1))
  python3 -B tools/vm/vm-boot.py --autologin --persist --poweroff --disk "$bc/disk.qcow2" --timeout 240 \
    --log "$logs/serial-boot-counting-$n.log" --summary "$summary" --title "Boot counting, boot $n: $1" "${@:2}"
}
booted() { # guest command: the booted image is $1
  echo 'd="$(bootc status --booted --format json | grep -o "\"imageDigest\":\"[^\"]*\"" | cut -d\" -f4)"; echo "booted imageDigest: $d"; test "$d" = '"$1"
}
entries='ls /boot/loader/entries'
running='s="$(systemctl is-system-running --wait)"; echo "system: $s"; systemctl --no-pager --failed; test "$s" = running'
unhealthy_boot='s="$(systemctl is-system-running --wait)"; echo "system: $s"; systemctl --no-pager --failed; test "$s" = degraded && systemctl is-failed --quiet nyra-test-unhealthy.service && ! systemctl is-active --quiet boot-complete.target && ! systemctl is-active --quiet systemd-bless-boot.service'

vm "installed version, switch to the unhealthy one" \
  --command "$(booted "$image_digest")" \
  --command "$running" \
  --command 'cat /boot/loader/loader.conf; grep -qx "editor no" /boot/loader/loader.conf' \
  --command 'mkdir -p /etc/containers/registries.conf.d && printf "[[registry]]\nlocation = \"10.0.2.2\"\ninsecure = true\n" > /etc/containers/registries.conf.d/99-ci-test.conf' \
  --command 'bootc switch --quiet 10.0.2.2/nyra-test:unhealthy && ls /boot/loader/entries.staged'

for try in 1 2 3; do
  vm "unhealthy version, try $try of 3" \
    --command "$(booted "$unhealthy")" \
    --command "$entries; ls /boot/loader/entries/*+$((3 - try))-$try.conf" \
    --command "$unhealthy_boot"
done

vm "systemd-boot fell back to the installed version, switch to the healthy one" \
  --command "$(booted "$image_digest")" \
  --command "$entries; ls /boot/loader/entries/*+0-3.conf" \
  --command "$running" \
  --command 'bootc switch --quiet 10.0.2.2/nyra-test:healthy && ls /boot/loader/entries.staged'

vm "healthy version, first try, blessed" \
  --command "$(booted "$healthy")" \
  --command "$running" \
  --command 'journalctl -b -u systemd-bless-boot --no-pager -o cat; systemctl is-active --quiet systemd-bless-boot.service' \
  --command "$entries; test \"\$(ls /boot/loader/entries/bootc_*.conf | wc -l)\" = 2 && ! ls /boot/loader/entries/bootc_*.conf | grep -F + && test -f /boot/loader/entries/nyra-recovery.CONF && test -f /boot/loader/entries/nyra-reset.CONF"
