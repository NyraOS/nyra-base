#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: the installer's recovery key (docs/INSTALL.md), made and shown the way
# tools/install/nyra-install.sh does it: on a terminal, from the image's container with no log
# (in_image -it --log-driver=none, tools/install/lib.sh). The installer does not check the key (the
# user only writes it down); this test checks that what is shown is the recovery key.
#   - the key is shown once, and after the run it is not in the journal, in a container's log or in
#     what podman keeps of the containers (a container run with a log shows that this search finds one);
#   - the key shown opens the key slot of the recovery key; a wrong one, and the key of the
#     installation, do not.
#   tools/install/test-recovery-key.sh IMAGE WORKDIR
set -euo pipefail

image="$1" work="$2"
as_root=sudo
secrets="$work/recovery-key-test"
. tools/install/lib.sh
export image secrets as_root
disk="$work/recovery-key-test.raw" loop="" key="" slot=""
trap '[ -z "$loop" ] || sudo losetup -d "$loop" || true; sudo podman rm -f nyra-log-control > /dev/null 2>&1 || true; rm -rf "$secrets" "$disk"' EXIT

pattern='([cbdefghijklnrtuv]{8}-){7}[cbdefghijklnrtuv]{8}'
fail() {
  echo "::error::$*" >&2
  exit 1
}
# on_terminal TRANSCRIPT STEP ARG...: a step as the installer runs it for the owner. A step that
# hangs (pty-run.py exits 124) fails the test, it does not count as a refused key. ANSWER, if set,
# is typed at every passphrase prompt, as cryptsetup asks up to three times.
on_terminal() {
  local transcript="$1" status=0
  shift
  python3 tools/install/pty-run.py "$transcript" \
    bash -c '. tools/install/lib.sh; in_image -it --log-driver=none -- "$@"' _ "$@" || status=$?
  [ "$status" != 124 ] || fail "$1 hung on the terminal (transcript, last lines: $(tail -c 300 "$transcript" | tr -c '[:print:]' ' '))"
  return "$status"
}
# shown KEY_VARIABLE: the recovery key on the terminal, once, and the one key slot it opened.
shown() {
  on_terminal "$secrets/shown" recovery-show "$loop" /secrets/install-key
  [ "$(grep -Eoc "$pattern" "$secrets/shown")" = 1 ] || fail "the recovery key was not shown exactly once"
  printf -v "$1" %s "$(grep -Eo "$pattern" "$secrets/shown")"
  slot="$(in_image -- luks-json "$loop" | recovery_slot)" || fail "no recovery key slot"
}
# leaked KEY: succeeds if the key is in the journal or in what podman keeps of the containers.
leaked() {
  sudo journalctl --sync || true
  sudo journalctl -b --no-pager | grep -qF -- "$1" && return 0
  sudo grep -rqF -- "$1" /var/lib/containers/storage/overlay-containers && return 0
  return 1
}

mkdir -m 0700 "$secrets"
( umask 077; head -c 32 /dev/urandom | base64 -w0 > "$secrets/install-key" )
truncate -s 3G "$disk"
partition_disk "$disk"
loop="$(sudo losetup -P --show -f "$disk")"
for _ in $(seq 50); do [ -b "${loop}p2" ] && break; udevadm settle --timeout=10 || true; sleep 0.2; done
[ -b "${loop}p2" ] || fail "no partitions on $loop after 10 s"
in_image -- format "$loop" /secrets/install-key

# The search finds a key that was logged: a container with the log driver the installer turns off.
marker="nyra-log-control-$(head -c 16 /dev/urandom | base64 | tr -dc a-z0-9)"
sudo podman run --name nyra-log-control --pull=never --log-driver=k8s-file "$image" echo "$marker" > /dev/null
leaked "$marker" || fail "the search for a leaked key does not find a logged string"
sudo podman rm nyra-log-control > /dev/null
# And one that went to the journal, the other place a key could leak to.
journal_marker="nyra-journal-control-$(head -c 16 /dev/urandom | base64 | tr -dc a-z0-9)"
sudo podman run --rm --pull=never --log-driver=journald "$image" echo "$journal_marker" > /dev/null
leaked "$journal_marker" || fail "the search for a leaked key does not find a string in the journal"

shown key
ANSWER="$key" on_terminal "$secrets/typed" recovery-check "$loop" "$slot" || fail "the recovery key shown was refused"
echo "the recovery key shown opens the recovery key slot"
ANSWER="$(rev <<< "$key")" on_terminal "$secrets/typed" recovery-check "$loop" "$slot" \
  && fail "a wrong key was accepted"
ANSWER="$(cat "$secrets/install-key")" on_terminal "$secrets/typed" recovery-check "$loop" "$slot" \
  && fail "the key of the installation was accepted as the recovery key"
echo "a wrong key and the key of the installation are refused"

leaked "$key" && fail "the recovery key is in the journal or in a container's log"
echo "the recovery key is in no log"
