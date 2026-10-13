#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# FILE, downloaded from this run's artifacts, must be the file its producing job made: its sha256 is
# the one that job reported as a job output. An artifact of the run can be replaced by another job
# of the run; a finished job's outputs cannot. FILE's directory, empty before the download, must hold
# nothing else.
#   ci/check-artifact.sh FILE SHA256
#   ci/check-artifact.sh --self-test
set -euo pipefail

check() {
  if ! [[ "$2" =~ ^[0-9a-f]{64}$ ]]; then
    echo "::error::$1: no sha256 from the job that made it ('$2')"
    return 1
  fi
  local got others
  others="$(find "$(dirname "$1")" -mindepth 1 -maxdepth 1 ! -name "$(basename "$1")" -printf '%f ')"
  if [ -n "$others" ]; then
    echo "::error::$(dirname "$1") holds more than $(basename "$1"): $others"
    return 1
  fi
  got="$(sha256sum < "$1" | cut -d' ' -f1)"
  if [ "$got" != "$2" ]; then
    echo "::error::$1 is not the file its job made: sha256 $got, reported $2"
    return 1
  fi
  echo "$1: sha256 $got, as its job reported"
}

if [ "${1:-}" = --self-test ]; then
  d="$(mktemp -d)"
  trap 'rm -rf "$d"' EXIT
  echo image > "$d/image.tar"
  good="$(sha256sum < "$d/image.tar" | cut -d' ' -f1)"
  check "$d/image.tar" "$good" >/dev/null
  # Another hash, one differing only in its last character, none, not a hash.
  last="${good:63}"; [ "$last" = 0 ] && other=1 || other=0
  for wrong in "$(printf '0%.0s' {1..64})" "${good:0:63}$other" "" "not-a-hash"; do
    if check "$d/image.tar" "$wrong" >/dev/null; then echo "self-test: accepted '$wrong'"; exit 1; fi
  done
  # Anything else in the directory: a hidden file, a directory.
  for extra in .hidden sub; do
    if [ "$extra" = sub ]; then mkdir "$d/$extra"; else touch "$d/$extra"; fi
    if check "$d/image.tar" "$good" >/dev/null; then echo "self-test: accepted $extra next to the file"; exit 1; fi
    rm -rf "${d:?}/$extra"
  done
  check "$d/image.tar" "$good" >/dev/null
  echo "check-artifact.sh self-test: ok"
  exit 0
fi
check "$1" "$2"
