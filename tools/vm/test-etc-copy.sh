#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Offline test of which copies of /etc a run removes (files/usr/lib/nyra/etc-copy to-remove; docs/BOOT.md,
# "Restore earlier settings"): the clock right, far ahead, behind, corrected after being ahead, a month
# off, the three newest kept, and the 30-day boundary. Needs GNU date and mawk; touches no file. Exits
# non-zero when any case fails.
#   tools/vm/test-etc-copy.sh   (ETC_COPY=PATH tests another copy of the script)
set -euo pipefail

etc_copy="${ETC_COPY:-files/usr/lib/nyra/etc-copy}"
fail=0
at() { date -u -d "@$(($(date -u -d "$1" +%s) - $2))" +%Y-%m-%dT%H:%M:%SZ; } # at DATE SECONDS-BEFORE
day=86400
real=2026-10-16T03:00:00Z
# 21 daily copies of the last 21 days, and 5 from 31-35 days before the last one.
recent="$(for d in $(seq 0 20); do echo "$(at $real $((d * day)))-daily"; done)"
older="$(for d in $(seq 31 35); do echo "$(at $real $((d * day)))-update"; done)"
# check TITLE NOW NEW SYNCED EXPECTED NAMES: what a run removes, of NAMES (one per line), is EXPECTED.
check() {
  local got want
  got="$(printf '%s\n' "$6" | sh "$etc_copy" to-remove "$2" "$3" "$4" | sort)"
  want="$(printf '%s' "$5" | sort)"
  if [ "$got" = "$want" ]; then
    echo "ok: $1"
  else
    echo "FAIL: $1"
    echo "  expected: $(echo "$want" | tr '\n' ' ')"
    echo "  got: $(echo "$got" | tr '\n' ' ')"
    fail=1
  fi
}

new=2026-10-16T03:00:05Z
check "right clock: only the copies older than 30 days" "$new" "$new-daily" yes "$older" \
  "$(printf '%s\n%s\n%s\n.lock\n.new-x' "$recent" "$older" "$new-daily")"

new=2099-06-01T00:00:00Z
check "clock in 2099, not synchronised: the same, none of the last 30 days" "$new" "$new-daily" no "$older" \
  "$(printf '%s\n%s\n%s' "$recent" "$older" "$new-daily")"

new=2020-01-01T00:00:00Z
check "clock behind every copy, not synchronised: nothing" "$new" "$new-daily" no "" \
  "$(printf '%s\n%s\n%s' "$recent" "$older" "$new-daily")"

new=2026-10-17T03:00:00Z
check "clock right again and synchronised: the copy dated 2099 goes too" "$new" "$new-daily" yes \
  "$(printf '%s\n%s' "$older" "2099-06-01T00:00:00Z-daily")" \
  "$(printf '%s\n%s\n%s\n%s' "$recent" "$older" "2099-06-01T00:00:00Z-daily" "$new-daily")"

check "a copy dated 2099 while not synchronised: kept" "$new" "$new-daily" no "" \
  "$(printf '%s\n%s\n%s' "$recent" "2099-06-01T00:00:00Z-daily" "$new-daily")"

new=2026-12-01T00:00:00Z
check "after a month and a half off: the copies from before stay" "$new" "$new-daily" yes "" \
  "$(printf '%s\n%s' "$recent" "$new-daily")"

# The three newest stay, even 60 days older than the one before them; the fourth goes.
new=2026-10-16T03:00:05Z
check "the three newest stay" "$new" "$new-daily" yes "$(at $real $((61 * day)))-daily" \
  "$(printf '%s\n' "$new-daily" "$real-daily" "$(at $real $((60 * day)))-daily" "$(at $real $((61 * day)))-daily")"

# 30 days before the newest earlier copy ($real): a copy exactly then stays, one a second older goes.
check "the 30-day boundary" "$new" "$new-daily" yes "$(at $real $((30 * day + 1)))-update" \
  "$(printf '%s\n' "$new-daily" "$real-daily" "$(at $real $day)-daily" "$(at $real $((2 * day)))-daily" \
    "$(at $real $((30 * day)))-daily" "$(at $real $((30 * day + 1)))-update")"

exit "$fail"
