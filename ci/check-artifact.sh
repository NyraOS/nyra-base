#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# FILE, downloaded from this run's artifacts, must be the file its producing job made: its sha256 is
# the one that job reported as a job output. An artifact of the run can be replaced by another job
# of the run; a finished job's outputs cannot.
#   ci/check-artifact.sh FILE SHA256
#   ci/check-artifact.sh --self-test
set -euo pipefail

check() {
  if ! [[ "$2" =~ ^[0-9a-f]{64}$ ]]; then
    echo "::error::$1: no sha256 from the job that made it ('$2')"
    return 1
  fi
  local got
  got="$(sha256sum < "$1" | cut -d' ' -f1)"
  if [ "$got" != "$2" ]; then
    echo "::error::$1 is not the file its job made: sha256 $got, reported $2"
    return 1
  fi
  echo "$1: sha256 $got, as its job reported"
}

if [ "${1:-}" = --self-test ]; then
  t="$(mktemp)"
  trap 'rm -f "$t"' EXIT
  echo image > "$t"
  check "$t" "$(sha256sum < "$t" | cut -d' ' -f1)" >/dev/null
  for wrong in "$(printf '0%.0s' {1..64})" "" "not-a-hash"; do
    if check "$t" "$wrong" >/dev/null; then echo "self-test: accepted '$wrong'"; exit 1; fi
  done
  echo "check-artifact.sh self-test: ok"
  exit 0
fi
check "$1" "$2"
