#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: the first administrator's record and the list of reserved names, made the way the installer
# makes them (docs/BOOT.md, "The first administrator"), with the image's own tools in the container
# runtime of the runner. What it checks:
#   - reserved-names.sh makes the file reserved-names of a release tree from the image: one name per line,
#     with root, the image's accounts and groups, sudo, and the names its sysusers.d files declare;
#   - admin-record gives NAME:HASH, a yescrypt hash, in a file of mode 0600 that only the caller's root
#     reads, from a password on the standard input;
#   - it refuses (exit 4, no file) a name of the system (root, an account, a group, a name of sysusers.d,
#     all taken from that list), a name the installer does not take, and a password that is too short, too
#     long, not printable ASCII or empty;
#   - the password is in no process's arguments while the steps run (the search is shown to find a string
#     that was put on a command line), in no output, no file of the record's directory, and not in the
#     journal or what podman keeps of the containers (shown to find a string that was put there).
#   tools/install/test-admin-record.sh IMAGE WORKDIR
set -euo pipefail

image="$1" work="$2"
as_root=sudo
secrets="$work/admin-record-test"
. tools/install/lib.sh
export image secrets as_root
sampler=""
trap '[ -z "$sampler" ] || kill "$sampler" 2>/dev/null || true; sudo podman rm -f nyra-log-control > /dev/null 2>&1 || true; sudo rm -rf "$secrets" "$work/admin-record-tree"' EXIT
fail() {
  echo "::error::$*" >&2
  exit 1
}
mkdir -m 0700 "$secrets"

# The list, as the release tree carries it.
mkdir "$work/admin-record-tree"
PODMAN="sudo podman" tools/install/reserved-names.sh "$image" "$work/admin-record-tree"
names="$work/admin-record-tree/reserved-names"
for n in root daemon nobody sudo systemd-network users; do
  grep -qx "$n" "$names" || fail "reserved-names has not $n"
done
! grep -qx maria "$names" || fail "reserved-names has maria"
[ "$(wc -l < "$names")" -ge 20 ] || fail "reserved-names has $(wc -l < "$names") names: too few for an image"
echo "reserved-names: $(wc -l < "$names") names, with root, daemon, nobody, sudo, systemd-network"

# record NAME PASSWORD: admin-record in the container; the password on the standard input.
record() {
  rm -f "$secrets/first-admin"
  printf '%s\n' "$2" | in_image -i --log-driver=none -- admin-record "$1" /secrets/first-admin > "$secrets/out" 2>&1
}
password="$(python3 -I -c 'import secrets; print("".join(secrets.choice("abcXYZ0123 _-.,;:!?@#%&*()+=") for _ in range(24)), end="")')"
printf '%s\n' "$password" > "$secrets/pattern"

# The searches find what was put where they look.
marker="nyra-admin-record-control-$(head -c 16 /dev/urandom | base64 | tr -dc a-z0-9)"
sudo podman run --name nyra-log-control --pull=never --log-driver=k8s-file "$image" echo "$marker" > /dev/null
printf '%s\n' "$marker" > "$secrets/marker"
leaked() { # leaked FILE: a line of FILE is in the journal or in what podman keeps of the containers
  sudo journalctl --sync || true
  sudo journalctl -b --no-pager | grep -qF -f "$1" && return 0
  sudo grep -rqF -f "$1" /var/lib/containers/storage/overlay-containers && return 0
  return 1
}
leaked "$secrets/marker" || fail "the search for a leaked password does not find a logged string"
sudo podman rm nyra-log-control > /dev/null
sample() { ( while :; do ps -eww -o args=; sleep 0.02; done > "$1" ) & sampler=$!; }
stop_sampling() { kill "$sampler"; wait "$sampler" 2> /dev/null || true; sampler=""; }
sample "$secrets/control-ps"
sleep 0.3
bash -c 'sleep 1; :' control "$marker" &
control=$!
sleep 0.5
stop_sampling
wait "$control"
grep -qF -- "$marker" "$secrets/control-ps" || fail "the search in the processes' arguments does not find a string given on a command line"
echo "control: the searches find a string that was logged and one that was put on a command line"

# The good record, while the processes' arguments are sampled.
sample "$secrets/ps"
sleep 0.3
record maria "$password" || { cat "$secrets/out"; fail "admin-record of a good name and password"; }
stop_sampling
[ "$(sudo stat -c '%a %U' "$secrets/first-admin")" = "600 root" ] || fail "the record is not 0600 and root's"
line="$(sudo cat "$secrets/first-admin")"
[[ "$line" =~ ^maria:\$y\$[./A-Za-z0-9]+\$[./A-Za-z0-9]+\$[./A-Za-z0-9]{43}$ ]] || fail "the record is not maria and a yescrypt hash"
echo "admin-record: maria and a yescrypt hash, in a file of mode 0600"

# The refusals: exit 4 and no file.
refused() { # refused WHAT NAME PASSWORD
  local status=0
  record "$2" "$3" || status=$?
  [ "$status" = 4 ] || fail "$1: exit $status, not 4 ($(tail -n 3 "$secrets/out" | tr '\n' ' '))"
  ! sudo test -e "$secrets/first-admin" || fail "$1: a record was made"
  echo "refused (exit 4): $1"
}
refused "the name root" root "$password"
refused "the name of an account (daemon)" daemon "$password"
refused "the name of a group (sudo)" sudo "$password"
refused "a name of sysusers.d (systemd-network)" systemd-network "$password"
refused "an upper case name" Maria "$password"
refused "a name with a dot" ma.ria "$password"
refused "a password of 11 characters" maria abcdefghijk
refused "a password of 65 characters" maria "$(printf 'a%.0s' $(seq 65))"
refused "a password that is not ASCII" maria "caf$(printf '\303\251')caf$(printf '\303\251')cafe"
refused "a password with a tab" maria $'abcdefgh\tijkl'
refused "an empty password" maria ''
for f in "$secrets/out" "$secrets/ps"; do
  ! sudo grep -qF -f "$secrets/pattern" "$f" || fail "the password is in $(basename "$f")"
done
! leaked "$secrets/pattern" || fail "the password is in the journal or in what podman keeps of the containers"
echo "the password: in no process's arguments, no output, no log of the runner or the containers"
