#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Offline test of /usr/lib/nyra/health/network (docs/UPDATES.md, "The network"), without a VM: a copy
# of the script with its paths moved into a temporary directory and its time limits shortened (60 s
# and 20 s to 3 s and 1 s), and stand-ins for networkctl (the links of $LINKS), systemctl
# (boot-complete.target active unless $UNHEALTHY, SoftRebootsCount $SOFT, the failed health checks
# $OTHER_FAILED) and sync (logs whether the new record is there when it runs). The VM test
# (tools/vm/network-health.sh) covers the real system.
#   tools/vm/test-network-health.sh
set -euo pipefail

t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT
mkdir "$t/bin" "$t/var"
cat >"$t/bin/networkctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$LINKS" | sed '/^$/d'
EOF
cat >"$t/bin/systemctl" <<'EOF'
#!/bin/sh
case "$*" in
  "is-active --quiet boot-complete.target") [ -z "${UNHEALTHY:-}" ] ;;
  "show -P SoftRebootsCount") echo "${SOFT:-0}" ;;
  "list-units --state=failed --plain --no-legend nyra-health-*") echo "${OTHER_FAILED:-}" ;;
  *) exit 1 ;;
esac
EOF
cat >"$t/bin/sync" <<EOF
#!/bin/sh
test -s "$t/var/network-links.new" && echo "sync: the new record is written" >>"$t/sync.log"
EOF
chmod +x "$t/bin/"*
sed -e "s#^dir=/var/lib/nyra-updated\$#dir=$t/var#" \
  -e "s#/sys/firmware/efi/efivars/LoaderBootCountPath-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f#$t/counted#" \
  -e 's/^wait=60 /wait=3 /' -e 's/^grace=20 /grace=1 /' \
  "$(dirname "$0")/../../files/usr/lib/nyra/health/network" >"$t/network"
chmod +x "$t/network"
grep -q "^dir=$t/var\$" "$t/network" && grep -q '^wait=3 ' "$t/network" && grep -q '^grace=1 ' "$t/network" &&
  grep -qF "$t/counted" "$t/network" || { echo "the script's paths or limits moved: update this test"; exit 1; }
export PATH="$t/bin:$PATH"

links() { # links NAME:OPERATIONAL:SETUP...: what networkctl list prints
  local l i=1
  for l in "lo:carrier:unmanaged" "$@"; do
    IFS=: read -r name oper setup <<<"$l"
    printf '%3d %s ether %s %s\n' "$i" "$name" "$oper" "$setup"
    i=$((i + 1))
  done
}
record() { tr '\n' ' ' 2>/dev/null <"$t/var/network-links" | sed 's/ $//'; }
fails=0
check() { # check TITLE EXPECTED_EXIT EXPECTED_OUTPUT_PATTERN [env ...]: run the check
  local title="$1" want="$2" pattern="$3" out rc=0
  shift 3
  out="$(env "$@" "$t/network" 2>&1)" || rc=$?
  if [ "$rc" = "$want" ] && grep -qE -- "$pattern" <<<"$out"; then
    echo "ok: $title (exit $rc: ${out//$'\n'/ | })"
  else
    echo "FAILED: $title: exit $rc, want $want; output: $out"
    fails=$((fails + 1))
  fi
}
expect_record() { # expect_record TITLE "NAMES"
  if [ "$(record)" = "$2" ]; then echo "ok: $1 (record: $2)"; else
    echo "FAILED: $1: record '$(record)', want '$2'"
    fails=$((fails + 1))
  fi
}
up="$(links enp1s0:routable:configured)"

# The record.
UNHEALTHY=1 LINKS="$up" "$t/network" record
expect_record "nothing recorded on an unhealthy boot" ""
LINKS="$(links enp1s0:routable:configured podman0:routable:unmanaged)" "$t/network" record
expect_record "only the links networkd configured" "enp1s0"
grep -q 'the new record is written' "$t/sync.log" && ! test -e "$t/var/network-links.new" &&
  echo "ok: synced before the rename" || { echo "FAILED: no sync before the rename"; fails=$((fails + 1)); }
LINKS="$(links enp1s0:no-carrier:configuring)" "$t/network" record
expect_record "kept while offline" "enp1s0"

# Not on trial: nothing judged.
check "a normal boot" 0 '^$' LINKS="$(links enp1s0:degraded:configured)"
touch "$t/counted"
check "a soft reboot (LoaderBootCountPath from the last full boot)" 0 '^$' SOFT=1 LINKS="$(links enp1s0:degraded:configured)"

# On trial.
check "trial: an address" 0 'a routable address as before: enp1s0' LINKS="$up"
check "trial: no cable" 0 'not judged: enp1s0' LINKS="$(links enp1s0:no-carrier:configuring)"
check "trial: no such link" 0 'not judged: enp1s0' LINKS="$(links)"
check "trial: waiting for authentication" 0 'not judged: enp1s0' LINKS="$(links enp1s0:dormant:configuring)"
check "trial: networkctl lists nothing" 0 '^<4>networkctl listed no links' LINKS=""
test ! -e "$t/var/network-failed" || { echo "FAILED: a marker without a failure"; fails=$((fails + 1)); }
test ! -e "$t/var/network-fallback" && echo "ok: a trial boot that passes asks for no retry" ||
  { echo "FAILED: network-fallback on a trial boot"; fails=$((fails + 1)); }
check "trial: carrier, no address" 1 'no routable address after 3 s.*enp1s0 \(degraded configured\)' LINKS="$(links enp1s0:degraded:configured)"
test -e "$t/var/network-failed" && echo "ok: the next boot judges too" || { echo "FAILED: no marker"; fails=$((fails + 1)); }
test "$(stat -c %a "$t/var/network-failed")" = 600 && echo "ok: the marker is root's alone" ||
  { echo "FAILED: the marker is not 0600 (the state directory can be entered by everybody)"; fails=$((fails + 1)); }
check "trial: not managed any more" 1 'enp1s0 \(off unmanaged\)' LINKS="$(links enp1s0:off:unmanaged)"
rm "$t/counted"
check "after the fallback: an address" 0 'a routable address as before' LINKS="$up"
test ! -e "$t/var/network-failed" && echo "ok: marker gone" || { echo "FAILED: marker left"; fails=$((fails + 1)); }
test -e "$t/var/network-fallback" && echo "ok: the fallback was the network check's alone (nyra-updated tries again)" ||
  { echo "FAILED: no network-fallback"; fails=$((fails + 1)); }
test "$(stat -c %a "$t/var/network-fallback")" = 600 && echo "ok: network-fallback is root's alone" ||
  { echo "FAILED: network-fallback is not 0600"; fails=$((fails + 1)); }
rm "$t/var/network-fallback"
check "after the fallback, without the marker" 0 '^$' LINKS="$(links enp1s0:degraded:configured)"
touch "$t/counted"
check "trial fails again" 1 'no routable address' LINKS="$(links enp1s0:degraded:configured)"
rm "$t/counted"
check "after the fallback: no address either (the network or the settings)" 1 'no routable address' LINKS="$(links enp1s0:degraded:configured)"
test ! -e "$t/var/network-failed" && echo "ok: only a trial boot leaves a marker" || { echo "FAILED: marker off trial"; fails=$((fails + 1)); }
test ! -e "$t/var/network-fallback" && echo "ok: no retry when the older version gets no address either" ||
  { echo "FAILED: network-fallback without an address"; fails=$((fails + 1)); }
# Nothing judged after the fallback passes too: at most one more try, simpler than telling apart.
touch "$t/counted"
check "trial fails once more" 1 'no routable address' LINKS="$(links enp1s0:degraded:configured)"
rm "$t/counted"
check "after the fallback: no cable" 0 'not judged: enp1s0' LINKS="$(links enp1s0:no-carrier:configuring)"
test -e "$t/var/network-fallback" && echo "ok: nothing judged after the fallback: one more try" ||
  { echo "FAILED: no network-fallback when nothing is judged"; fails=$((fails + 1)); }
rm "$t/var/network-fallback"
touch "$t/counted"
check "trial: no address, and another health check failed" 1 'no routable address' OTHER_FAILED="nyra-health-bootc.service loaded failed failed" LINKS="$(links enp1s0:degraded:configured)"
test ! -e "$t/var/network-failed" && echo "ok: not the network check's alone: the next boot is not judged, no retry" ||
  { echo "FAILED: marker although another check failed"; fails=$((fails + 1)); }

# The settings change a recorded link: bridged (enslaved), and no longer managed. Until the next
# update check the record still judges it; after it, it does not.
bridged="$(links enp1s0:enslaved:configured br0:routable:configured)"
check "bridged, before the next check" 1 'enp1s0 \(enslaved configured\)' LINKS="$bridged"
LINKS="$bridged" "$t/network" record
expect_record "the bridge replaces the port" "br0"
check "trial: the port bridged" 0 'a routable address as before: br0' LINKS="$bridged"
LINKS="$(links enp1s0:routable:configured enp2s0:routable:configured)" "$t/network" record
expect_record "two ports" "enp1s0 enp2s0"
unmanaged="$(links enp1s0:routable:configured enp2s0:degraded:unmanaged)"
check "one port no longer managed, before the next check" 1 'enp2s0 \(degraded unmanaged\)' LINKS="$unmanaged"
LINKS="$unmanaged" "$t/network" record
expect_record "the unmanaged port left out" "enp1s0"
check "trial: the other port unmanaged" 0 'a routable address as before: enp1s0$' LINKS="$unmanaged"
rm -f "$t/var/network-links"
check "trial: nothing recorded yet" 0 'nothing to compare' LINKS="$(links enp1s0:degraded:configured)"

[ "$fails" = 0 ] && echo "test-network-health.sh: passed" || { echo "test-network-health.sh: $fails failed"; exit 1; }
