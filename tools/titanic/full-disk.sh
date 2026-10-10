#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only (titanic.yml): Titanic T6, a full disk (docs/TITANIC.md). On a copy-on-write copy of the
# installed test disk, updated with plain `bootc switch` to test versions of IMAGE (each with its own
# 16 MiB that do not compress and its own UKI, served by a throwaway registry on the runner that the
# VM reaches as 10.0.2.2, no signatures, as in tools/titanic/power-cuts.sh):
#   1  the root file system (where /var lives, next to the composefs store) filled to the last
#      block: the update fails with "No space left on device", nothing is staged, the system still
#      runs; clean shutdown with the disk still full
#   2  boots with the disk full: running, the health checks pass
#   3  the root file system freed and the ESP filled: the update fails, nothing staged; the ESP
#      freed: v1 staged
#   4+ v1 ... vN: each boots, then the next one is staged. The space the system takes (the composefs
#      store and the deployments' state in /sysroot, the ESP) is measured at every boot: from the
#      third update on it must not grow (old versions are removed), so it stays the same after any
#      number of updates.
#   tools/titanic/full-disk.sh IMAGE IMAGE_DIGEST DISK.qcow2 WORKDIR LOGDIR SUMMARY UPDATES
set -euo pipefail

image="$1" old="$2" disk="$3" work="$4" logs="$5" summary="$6" updates="$7"
fd="$work/full-disk"
mkdir -p "$fd/context"

# --- the test versions (as in tools/titanic/power-cuts.sh: their own UKI, unsigned) -----------------
cat > "$fd/kernel-from-uki.py" <<'EOF'
import sys
import pefile
pe = pefile.PE(sys.argv[1])
for s in pe.sections:
    name = {b".linux": "vmlinuz", b".initrd": "initramfs.img"}.get(s.Name.rstrip(b"\0"))
    if name:
        with open(f"{sys.argv[2]}/{name}", "wb") as f:
            f.write(s.get_data()[:s.Misc_VirtualSize])
EOF
tools/signing/local-registry.sh "$fd"
declare -A digest
for ((v = 1; v <= updates; v++)); do
  printf 'FROM %s\nRUN rm -rf /boot/EFI\nRUN head -c 16777216 /dev/urandom > /usr/lib/nyra-test-payload\n' "$image" |
    sudo podman build -q -t "localhost/nyra-test:v$v-rootfs" -f - "$fd/context" >/dev/null
  rm -rf "$fd/uki" && mkdir -p "$fd/uki"
  sudo podman run --rm --network none --tmpfs /tmp --tmpfs /var/tmp \
    --mount "type=image,source=localhost/nyra-test:v$v-rootfs,target=/target" \
    -v "$fd/kernel-from-uki.py:/kernel-from-uki.py:ro" -v "$fd/uki:/out" "$image" \
    sh -c 'u="$(ls /boot/EFI/Linux/*.efi)" && k="$(basename "$u" .efi)" && mkdir -p "/tmp/kernel/$k" &&
      python3 /kernel-from-uki.py "$u" "/tmp/kernel/$k" &&
      bootc container ukify --rootfs /target --kernel-dir "/tmp/kernel/$k" -- --output "/out/$k.efi"' >/dev/null
  printf 'FROM localhost/nyra-test:v%s-rootfs\nCOPY --from=uki . /boot/EFI/Linux/\n' "$v" |
    sudo podman build -q -t "localhost/nyra-test:v$v" --build-context uki="$fd/uki" -f - "$fd/context" >/dev/null
  sudo podman push -q --tls-verify=false --digestfile "$fd/v$v.digest" "localhost/nyra-test:v$v" "docker://other.test/nyra-test:v$v"
  sudo chown "$(id -u):$(id -g)" "$fd/v$v.digest"
  digest[$v]="$(cat "$fd/v$v.digest")"
  [[ "${digest[$v]}" =~ ^sha256:[0-9a-f]{64}$ ]]
  sudo podman rmi -f "localhost/nyra-test:v$v" "localhost/nyra-test:v$v-rootfs" >/dev/null
done

# --- guest commands ---------------------------------------------------------------------------------
reg='mkdir -p /etc/containers/registries.conf.d && printf "[[registry]]\nlocation = \"10.0.2.2\"\ninsecure = true\n" > /etc/containers/registries.conf.d/99-ci-test.conf && sync'
# bootc waits forever for a registry that stops answering (docs/LESSONS.md).
switch() { echo "timeout 600 bootc switch --quiet 10.0.2.2/nyra-test:v$1"; }
booted() { echo "{ d=\"\$(bootc status --booted --format json | grep -o '\"imageDigest\":\"[^\"]*\"' | cut -d'\"' -f4)\"; echo \"booted: \$d\"; test \"\$d\" = $1; }"; }
staged='{ s="$(bootc status --format json)"; s="${s##*"\"staged\":"}"; echo "staged: ${s:0:80}"; ! printf %s "$s" | grep -q imageDigest; }'
running='{ s="$(systemctl is-system-running --wait)"; echo "system: $s"; systemctl --no-pager --failed; test "$s" = running && systemctl is-active boot-complete.target; }'
# fill DIR: the file system of DIR full: what users may take at once, then what root may take too,
# until a write fails (ext4 keeps a few clusters even root cannot take). full DIR: one more block
# cannot be written there.
fill='full() { ! dd if=/dev/zero of="$1/nyra-probe" bs=4k count=1 conv=fsync status=none 2>/dev/null; r=$?; rm -f "$1/nyra-probe"; return $r; }; fill() { f="$(stat -f -c "%a %S" "$1")" && fallocate -l $(( ${f% *} * ${f#* } )) "$1/nyra-fill"; { dd if=/dev/zero of="$1/nyra-fill-rest" bs=4k status=none 2>/dev/null; sync; df -k "$1"; full "$1"; }; }'
# The update fails on the full disk and says why; nothing is staged; bootc still answers.
refused() { echo "out=\"\$($(switch "$1") 2>&1)\"; rc=\$?; echo \"\$out\" | tail -5; test \$rc != 0 && echo \"\$out\" | grep -q 'No space left on device' && $staged"; }
# The space the system takes, in KiB: the composefs store and the deployments' state, and the ESP.
space='echo "nyra""-space: $(du -sk /sysroot/composefs /sysroot/state/deploy | awk "{s += \$1} END {print s}") $(du -sk /boot/ | cut -f1)"'

ov="$fd/disk.qcow2"
qemu-img create -q -f qcow2 -F qcow2 -b "$disk" "$ov"
vm() { # vm N TITLE [vm-boot.py options and --command ...]
  python3 -B tools/vm/vm-boot.py --autologin --persist --poweroff --disk "$ov" --timeout 240 \
    --log "$logs/serial-full-disk-$1.log" --summary "$summary" --title "Full disk $1: $2" "${@:3}"
}

# The first three boots report a failure and go on, so the updates below run (and measure) anyway.
fail=0
vm 1 "the root file system full: the update fails, nothing staged" \
  --command "$running" \
  --command "$reg && $fill && fill /var" \
  --command "$(refused 1)" \
  --command "$running && $(booted "$old")" || fail=1

# A failed boot ends without a clean shutdown (vm-boot.py), so v1 is staged in the next one.
vm 2 "boots with the disk full" \
  --command "$fill && full /var && echo 'the disk is still full' && $(booted "$old") && $running" || fail=1

vm 3 "the ESP full: the update fails, nothing staged; the ESP freed: v1 staged" \
  --command "$fill && rm /var/nyra-fill /var/nyra-fill-rest && fill /boot" \
  --command "$(refused 1); r=\$?; rm -f /boot/nyra-fill /boot/nyra-fill-rest; test \$r = 0" \
  --command "$(switch 1) && ls /boot/loader/entries.staged" || fail=1

for ((v = 1; v <= updates; v++)); do
  next=()
  if [ "$v" -lt "$updates" ]; then next=(--command "$(switch $((v + 1))) && ls /boot/loader/entries.staged"); fi
  vm $((v + 3)) "v$v boots${next:+, v$((v + 1)) staged}" \
    --command "$(booted "${digest[$v]}") && $running" \
    --command "$space" \
    "${next[@]}"
done

# From the third update on, the space must not grow: a version removed for every version added.
mapfile -t sizes < <(for ((v = 1; v <= updates; v++)); do
  grep -ao 'nyra-space: [0-9]* [0-9]*' "$logs/serial-full-disk-$((v + 3)).log" | tail -1 | cut -d' ' -f2-
done)
{
  echo "### Full disk: the space the system takes after each update"
  echo
  echo "| Update | composefs store and state (KiB) | ESP (KiB) |"
  echo "|---|---|---|"
  for ((v = 1; v <= updates; v++)); do echo "| v$v | ${sizes[v - 1]% *} | ${sizes[v - 1]#* } |"; done
  echo
} >> "$summary"
printf '%s\n' "${sizes[@]}"
[ "${#sizes[@]}" = "$updates" ]
read -r base_root base_esp <<<"${sizes[2]}"
for ((v = 4; v <= updates; v++)); do
  read -r root esp <<<"${sizes[v - 1]}"
  # 1 MiB of slack for metadata (directories, the image's config); one version is 16 MiB more.
  if [ "$root" -gt $((base_root + 1024)) ] || [ "$esp" -gt $((base_esp + 1024)) ]; then
    echo "::error::the system takes more space after update $v ($root KiB, ESP $esp KiB) than after update 3 ($base_root KiB, ESP $base_esp KiB)"
    fail=1
  fi
done
exit "$fail"
