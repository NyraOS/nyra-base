#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Offline test of which copies of /etc a run removes (files/usr/lib/nyra/etc-copy to-remove; docs/BOOT.md,
# "Restore earlier settings"), with the clock right, far ahead, behind, corrected after being ahead,
# and after a month off. Needs GNU date and mawk; touches no file.
#   tools/vm/test-etc-copy.sh
set -euo pipefail

etc_copy=files/usr/lib/nyra/etc-copy
fail=0
at() { date -u -d "@$(($(date -u -d "$1" +%s) - $2 * 86400))" +%Y-%m-%dT%H:%M:%SZ; } # at DATE DAYS-BEFORE
real=2026-10-16T03:00:00Z
# 21 daily copies of the last 21 days, and 5 from 31-35 days before the last one.
recent="$(for d in $(seq 0 20); do echo "$(at $real "$d")-daily"; done)"
older="$(for d in $(seq 31 35); do echo "$(at $real "$d")-update"; done)"
check() { # check TITLE NOW NEW SYNCED EXPECTED, the names on stdin
  local got
  got="$(sh "$etc_copy" to-remove "$2" "$3" "$4" | sort)"
  if [ "$got" = "$(printf '%s' "$5" | sort)" ]; then
    echo "ok: $1"
  else
    echo "FAIL: $1"; echo "  expected: $(printf '%s' "$5" | tr '\n' ' ')"; echo "  got: $(echo "$got" | tr '\n' ' ')"
    fail=1
  fi
}

new=2026-10-16T03:00:05Z
printf '%s\n%s\n%s\n.lock\n.new-x\n' "$recent" "$older" "$new-daily" |
  check "right clock: only the copies older than 30 days" "$new" "$new-daily" yes "$older"

new=2099-06-01T00:00:00Z
printf '%s\n%s\n%s\n' "$recent" "$older" "$new-daily" |
  check "clock in 2099, not synchronised: the same, none of the last 30 days" "$new" "$new-daily" no "$older"

new=2020-01-01T00:00:00Z
printf '%s\n%s\n%s\n' "$recent" "$older" "$new-daily" |
  check "clock behind every copy, not synchronised: nothing" "$new" "$new-daily" no ""

new=2026-10-17T03:00:00Z
printf '%s\n%s\n%s\n%s\n' "$recent" "$older" "2099-06-01T00:00:00Z-daily" "$new-daily" |
  check "clock right again and synchronised: the copy dated 2099 goes too" "$new" "$new-daily" yes \
    "$(printf '%s\n%s' "$older" "2099-06-01T00:00:00Z-daily")"

printf '%s\n%s\n%s\n' "$recent" "2099-06-01T00:00:00Z-daily" "$new-daily" |
  check "a copy dated 2099 while not synchronised: kept" "$new" "$new-daily" no ""

new=2026-12-01T00:00:00Z
printf '%s\n%s\n' "$recent" "$new-daily" |
  check "after a month and a half off: the copies from before stay" "$new" "$new-daily" yes ""

printf '%s\n%s\n%s\n' "$(at $real 100)-daily" "$(at $real 101)-daily" "$new-daily" |
  check "fewer than four copies: none goes" "$new" "$new-daily" yes ""

exit "$fail"
