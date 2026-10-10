#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only (titanic.yml): Titanic T2, power cuts at random moments of an update (docs/TITANIC.md).
# Each round starts from a fresh copy-on-write copy of the installed test disk and updates it with
# plain `bootc switch` to a test version of IMAGE (16 MiB more, served by a throwaway registry on the
# runner that the VM reaches as 10.0.2.2, no signatures, as in tools/vm/boot-counting.sh). QEMU is
# killed (a power cut) a random time after the start of one phase:
#   download   the switch, with the registry throttled to 2 Mbit/s (the pull takes over a minute)
#   staging    the switch at full speed (pull, deployment, staged boot entries)
#   finalize   `systemctl reboot` right after the switch (bootc-finalize-staged swaps the entries in)
#   firstboot  QEMU start of the first boot after a clean shutdown with the version staged
# A cut that lands after its phase (the switch done, the next boot started) is a moment too. Then the
# next boot must reach a running system on the old or the new version, and the update must complete:
# switched again if the old version booted, then one reboot into the new version, running.
# The phases take turns; the moments come from SEED (bash's RANDOM) and are printed before the first
# round, so a failing round can be run again with the same seed.
#   tools/titanic/power-cuts.sh IMAGE IMAGE_DIGEST DISK.qcow2 WORKDIR LOGDIR SUMMARY CUTS SEED
set -euo pipefail

image="$1" old="$2" disk="$3" work="$4" logs="$5" summary="$6" cuts="$7" seed="$8"
pc="$work/power-cuts"
mkdir -p "$pc/context"
trap 'sudo tc qdisc del dev lo root 2>/dev/null || true' EXIT

# --- the plan ---------------------------------------------------------------------------------------
phases=(download staging finalize firstboot)
windows=(600 40 30 300) # tenths of a second after the start of the phase (measured in CI: the switch at
# full speed takes about 4 s, the shutdown with the swap about 3 s)
RANDOM="$seed"
plan=()
for ((i = 0; i < cuts; i++)); do
  t=$((RANDOM % windows[i % 4]))
  plan+=("${phases[i % 4]} $((t / 10)).$((t % 10))")
done
echo "power cuts: seed $seed, $cuts rounds"
for ((i = 0; i < cuts; i++)); do echo "  round $((i + 1)): ${plan[i]} s"; done

# --- the test version (as in tools/vm/boot-counting.sh: its own UKI, unsigned) ----------------------
cat > "$pc/kernel-from-uki.py" <<'EOF'
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
  sudo podman build -q -t localhost/nyra-test:power-rootfs -f - "$pc/context" >/dev/null
mkdir -p "$pc/uki"
sudo podman run --rm --network none --tmpfs /tmp --tmpfs /var/tmp \
  --mount "type=image,source=localhost/nyra-test:power-rootfs,target=/target" \
  -v "$pc/kernel-from-uki.py:/kernel-from-uki.py:ro" -v "$pc/uki:/out" "$image" \
  sh -c 'u="$(ls /boot/EFI/Linux/*.efi)" && k="$(basename "$u" .efi)" && mkdir -p "/tmp/kernel/$k" &&
    python3 /kernel-from-uki.py "$u" "/tmp/kernel/$k" &&
    bootc container ukify --rootfs /target --kernel-dir "/tmp/kernel/$k" -- --output "/out/$k.efi"' >/dev/null
printf 'FROM localhost/nyra-test:power-rootfs\nCOPY --from=uki . /boot/EFI/Linux/\n' |
  sudo podman build -q -t localhost/nyra-test:power --build-context uki="$pc/uki" -f - "$pc/context" >/dev/null
tools/signing/local-registry.sh "$pc"
sudo podman push -q --tls-verify=false --digestfile "$pc/new.digest" localhost/nyra-test:power docker://other.test/nyra-test:power
sudo chown "$(id -u):$(id -g)" "$pc/new.digest"
new="$(cat "$pc/new.digest")"
[[ "$new" =~ ^sha256:[0-9a-f]{64}$ ]]
echo "old version: $old, new version: $new"

# --- guest commands ---------------------------------------------------------------------------------
reg='mkdir -p /etc/containers/registries.conf.d && printf "[[registry]]\nlocation = \"10.0.2.2\"\ninsecure = true\n" > /etc/containers/registries.conf.d/99-ci-test.conf && sync'
# bootc waits forever for a registry that stops answering (docs/LESSONS.md).
switch='timeout 600 bootc switch --quiet 10.0.2.2/nyra-test:power'
booted='d="$(bootc status --booted --format json | grep -o "\"imageDigest\":\"[^\"]*\"" | cut -d\" -f4)"; echo "booted imageDigest: $d"'
running='s="$(systemctl is-system-running --wait)"; echo "system: $s"; systemctl --no-pager --failed; test "$s" = running'

throttle() { # the registry's answers (port 80) at 2 Mbit/s
  sudo tc qdisc add dev lo root handle 1: htb default 10
  sudo tc class add dev lo parent 1: classid 1:10 htb rate 10gbit
  sudo tc class add dev lo parent 1: classid 1:20 htb rate 2mbit ceil 2mbit
  sudo tc filter add dev lo parent 1: protocol ip prio 1 u32 match ip sport 80 0xffff flowid 1:20
}

# cut LOG MARKER DELAY [vm-boot.py options]: a boot of the round's disk, and QEMU killed DELAY s after
# MARKER shows up on the console (no MARKER: after QEMU starts). The guest commands end in a long
# sleep, so QEMU is still running when the moment comes; if it is not, the round fails.
cut() {
  local log="$1" marker="$2" delay="$3" pid t
  shift 3
  python3 -B tools/vm/vm-boot.py --autologin --persist --disk "$ov" --timeout 240 \
    --log "$log" --summary /dev/null --title "power cut" "$@" >"$pc/cut.out" 2>&1 &
  pid=$!
  if [ -n "$marker" ]; then
    for ((t = 0; t < 1500; t++)); do
      if grep -aqs "$marker" "$log" || ! kill -0 "$pid" 2>/dev/null; then break; fi
      sleep 0.2
    done
    if ! grep -aqs "$marker" "$log"; then
      wait "$pid" || true
      cat "$pc/cut.out"
      echo "no $marker on the console"
      return 1
    fi
  fi
  sleep "$delay"
  if ! pkill -KILL -f "^qemu-system-x86_64 .*file=$ov,"; then
    wait "$pid" || true
    cat "$pc/cut.out"
    echo "QEMU was not running at the moment of the cut"
    return 1
  fi
  wait "$pid" || true
}

# round N PHASE DELAY
round() {
  local n="$1" phase="$2" delay="$3" log="$logs/serial-power-cuts-$1.log" where
  ov="$pc/round.qcow2"
  rm -f "$ov"
  qemu-img create -q -f qcow2 -F qcow2 -b "$disk" "$ov" || return 1
  case "$phase" in
    download | staging)
      if [ "$phase" = download ]; then throttle; fi
      cut "$log" CUT-ARMED "$delay" --command "$reg" \
        --command "echo CUT''-ARMED; $switch; echo SWITCH''-END=\$?; sleep 600" || return 1
      if [ "$phase" = download ]; then sudo tc qdisc del dev lo root; fi
      where="during the switch"
      if grep -aq SWITCH-END "$log"; then where="after the switch ($(grep -ao 'SWITCH-END=[0-9]*' "$log" | head -1))"; fi
      ;;
    finalize)
      cut "$log" CUT-ARMED "$delay" --command "$reg" --command "$switch && ls /boot/loader/entries.staged" \
        --command 'echo CUT''-ARMED; systemctl reboot; sleep 600' || return 1
      where="during the shutdown"
      if [ "$(grep -ac 'Linux version' "$log")" -ge 2 ]; then where="during the next boot"; fi
      ;;
    firstboot)
      python3 -B tools/vm/vm-boot.py --autologin --persist --poweroff --disk "$ov" --timeout 240 \
        --log "$logs/serial-power-cuts-$n-staged.log" --summary "$summary" \
        --title "Power cut $n: the new version staged, clean shutdown" \
        --command "$reg" --command "$switch && ls /boot/loader/entries.staged" || return 1
      cut "$log" "" "$delay" --command 'sleep 600' || return 1
      where="before the login prompt"
      if grep -aq 'login: ' "$log"; then where="after the login prompt"; fi
      ;;
  esac
  echo "round $n: QEMU killed $delay s into $phase, $where"
  python3 -B tools/vm/vm-boot.py --autologin --persist --poweroff --disk "$ov" --timeout 240 \
    --log "$logs/serial-power-cuts-$n-after.log" --summary "$summary" \
    --title "Power cut $n: $delay s into $phase, $where; the next boot, then the update completes" \
    --command "$booted; test \"\$d\" = $old || test \"\$d\" = $new" \
    --command "$running" \
    --command "$booted; test \"\$d\" = $new || { $reg && $switch && ls /boot/loader/entries.staged; }" \
    --command '@reboot systemctl reboot' \
    --command "$booted; test \"\$d\" = $new" \
    --command "$running"
}

fail=0 passed=0
for ((i = 0; i < cuts; i++)); do
  read -r phase delay <<<"${plan[i]}"
  if round "$((i + 1))" "$phase" "$delay"; then
    passed=$((passed + 1))
  else
    fail=1
    echo "::error::power cut round $((i + 1)) failed ($phase, $delay s, seed $seed)"
  fi
  sudo tc qdisc del dev lo root 2>/dev/null || true
done
rm -f "$pc/round.qcow2"
{
  echo "### Power cuts at random moments: $passed of $cuts rounds passed"
  echo
  echo "Seed $seed. Rounds: $(printf '%s s, ' "${plan[@]}" | sed 's/, $//')."
  echo
} >> "$summary"
echo "power cuts: $passed of $cuts rounds passed (seed $seed)"
exit "$fail"
