#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: the installer's disk password (docs/BOOT.md, "Disk encryption"), made the way
# tools/install/in-image.sh makes it: a random key of the installation as key slot 0, the password
# from a file as key slot 1 (argon2id, 256 MiB of memory or more), the recovery key, then key slot 0
# removed. What it checks, on a disk of its own, with the steps that tools/vm/install-encrypted.sh and
# the installer run:
#   - passwords that are too short, too long, not printable ASCII, with a tab or a newline, or empty
#     are refused and the disk is as it was; a good one, with spaces and symbols, is accepted;
#   - the password unlocks key slot 1 and a wrong one, and the key of the installation, do not; a removal
#     of key slot 0 with the wrong key refuses and changes nothing; after the removal, the key of the
#     installation unlocks nothing;
#   - the header of the finished disk passes check_luks_header_password, and each change of it that the
#     check is for (little memory, another KDF, a third key slot, a TPM2 token, ...) does not;
#   - the memory threshold: password-memory refuses (exit 3) when cryptsetup's benchmark settles on less
#     than 256 MiB (a stand-in cryptsetup in the container);
#   - the password, the key of the installation and the recovery key are in no process's arguments while
#     the steps run, in no journal or container log, and not in the unencrypted start of the disk (the
#     LUKS2 header), as tools/install/test-recovery-key.sh searches for the recovery key. Each search is
#     shown to find a string that was put where it looks.
#   tools/install/test-password.sh IMAGE WORKDIR
set -euo pipefail

image="$1" work="$2"
as_root=sudo
secrets="$work/password-test"
. tools/install/lib.sh
export image secrets as_root
disk="$work/password-test.raw" loop="" sampler=""
trap '[ -z "$sampler" ] || kill "$sampler" 2>/dev/null || true; [ -z "$loop" ] || sudo losetup -d "$loop" || true; sudo podman rm -f nyra-log-control > /dev/null 2>&1 || true; rm -rf "$secrets" "$disk"' EXIT

fail() {
  echo "::error::$*" >&2
  exit 1
}
# step_fails CODE DESCRIPTION STEP ARG...: the step exits with CODE (with any code but 0 if CODE is "any").
step_fails() {
  local want="$1" what="$2" status=0
  shift 2
  in_image -- "$@" > /dev/null 2> "$secrets/err" || status=$?
  if [ "$want" = any ]; then
    [ "$status" != 0 ] || fail "$what: not refused"
  else
    [ "$status" = "$want" ] || fail "$what: exit $status, not $want ($(tail -n 3 "$secrets/err" | tr '\n' ' '))"
  fi
  echo "refused (exit $status): $what"
}
# slots: the key slots of the disk, from its header.
slots() { in_image -- luks-json "$loop" | jq -c '.keyslots | keys'; }
# on_terminal ANSWER STEP ARG...: a step as the installer runs it for the owner, ANSWER typed at its
# passphrase prompt (pty-run.py). A step that hangs (exit 124) fails the test.
on_terminal() {
  local answer="$1" status=0
  shift
  ANSWER="$answer" python3 tools/install/pty-run.py "$secrets/typed" \
    bash -c '. tools/install/lib.sh; in_image -it --log-driver=none -- "$@"' _ "$@" || status=$?
  [ "$status" != 124 ] || fail "$1 hung on the terminal"
  return "$status"
}
# leaked FILE: succeeds if a line of FILE (the strings are never on a command line) is in the journal or
# in what podman keeps of the containers.
leaked() {
  sudo journalctl --sync || true
  sudo journalctl -b --no-pager | grep -qF -f "$1" && return 0
  sudo grep -rqF -f "$1" /var/lib/containers/storage/overlay-containers && return 0
  return 1
}
# sample FILE: every process's arguments, every 50 ms, into FILE, until the sampler is killed.
sample() {
  ( while :; do ps -eo args=; sleep 0.05; done > "$1" ) &
  sampler=$!
}
stop_sampling() {
  kill "$sampler"
  wait "$sampler" 2> /dev/null || true
  sampler=""
}

mkdir -m 0700 "$secrets"
( umask 077; head -c 32 /dev/urandom | base64 -w0 > "$secrets/install-key" )
# Printable ASCII with spaces and symbols; the other one is a wrong guess.
password="$(python3 -I -c 'import secrets; print("".join(secrets.choice("abcXYZ0123 _-.,;:!?@#%&*()+=") for _ in range(24)), end="")')"
wrong="${password}x"
printf %s "$password" > "$secrets/password"
printf '%s\n' "$password" > "$secrets/password-pattern"
truncate -s 3G "$disk"
partition_disk "$disk"
loop="$(sudo losetup -P --show -f "$disk")"
for _ in $(seq 50); do [ -b "${loop}p2" ] && break; udevadm settle --timeout=10 || true; sleep 0.2; done
[ -b "${loop}p2" ] || fail "no partitions on $loop after 10 s"

# The searches find what was put where they look: a string given to a container with a log, and one
# given on a command line.
marker="nyra-password-control-$(head -c 16 /dev/urandom | base64 | tr -dc a-z0-9)"
sudo podman run --name nyra-log-control --pull=never --log-driver=k8s-file "$image" echo "$marker" > /dev/null
printf '%s\n' "$marker" > "$secrets/marker"
leaked "$secrets/marker" || fail "the search for a leaked password does not find a logged string"
sudo podman rm nyra-log-control > /dev/null
sample "$secrets/control-ps"
sleep 1
python3 -I -c "import time; time.sleep(3)" "$marker" &
sleep 1
stop_sampling
grep -qF -- "$marker" "$secrets/control-ps" || fail "the search in the processes' arguments does not find a string given on a command line"

in_image -- format "$loop" /secrets/install-key
[ "$(slots)" = '["0"]' ] || fail "a new disk has key slots $(slots), not only 0"

# The memory threshold: this machine's own benchmark passes, and a stand-in cryptsetup, first in the
# container's PATH, is refused: its benchmark is that of a machine with little memory (password-memory
# exits 3), and it makes a key slot with 64 MiB (password-add removes the slot again and exits 3).
in_image -- password-memory
stub="$secrets/cryptsetup-stand-in"
cat > "$stub" <<'STUB'
#!/bin/bash
if [ "$1" = benchmark ]; then
  echo "argon2id      1 iterations, 100000 memory, 2 parallel threads (CPUs) for 256-bit key (requested 2000 ms time)"
  exit 0
fi
args=()
for a in "$@"; do
  [ "$a" = 1048576 ] && a=65536
  args+=("$a")
done
# The real one: the next cryptsetup in the PATH, without this directory.
PATH="${PATH#/nyra-stand-in:}"
exec cryptsetup "${args[@]}"
STUB
chmod 0755 "$stub"
# Not under /usr/local: in an image that keeps /usr/local elsewhere there is nothing to mount on.
stand_in=(-v "$stub:/nyra-stand-in/cryptsetup:ro" -e PATH=/nyra-stand-in:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin)
status=0
in_image "${stand_in[@]}" -- password-memory > /dev/null 2> "$secrets/err" || status=$?
[ "$status" = 3 ] || fail "password-memory with a benchmark of 100000 KiB: exit $status, not 3 ($(tail -n 3 "$secrets/err" | tr '\n' ' '))"
echo "refused (exit 3): a machine whose benchmark settles on 100000 KiB"
status=0
in_image "${stand_in[@]}" -- password-add "$loop" /secrets/install-key /secrets/password > /dev/null 2> "$secrets/err" || status=$?
[ "$status" = 3 ] || fail "password-add with a key slot of 64 MiB: exit $status, not 3 ($(tail -n 3 "$secrets/err" | tr '\n' ' '))"
[ "$(slots)" = '["0"]' ] || fail "password-add left $(slots) after a key slot of 64 MiB"
echo "refused (exit 3), the key slot removed again: a password slot made with 64 MiB"

# Passwords that are refused leave the disk as it was.
bad() { # bad DESCRIPTION PRINTF_ARGUMENT...: a password file made by printf
  local what="$1"
  shift
  printf "$@" > "$secrets/bad"
  step_fails 4 "$what" password-add "$loop" /secrets/install-key /secrets/bad
  [ "$(slots)" = '["0"]' ] || fail "$what: the disk changed"
}
bad "11 characters" %s abcdefghijk
bad "65 characters" %s "$(printf 'a%.0s' $(seq 65))"
bad "not ASCII" %s "caf$(printf '\303\251')caf$(printf '\303\251')cafe"
bad "a tab" 'abcdefgh\tijkl'
bad "a newline at the end" 'abcdefghijkl\n'
bad "empty" ''
rm "$secrets/bad"

# The good one, while the processes' arguments are sampled. The caller deletes the file at once.
sample "$secrets/ps"
in_image -- password-add "$loop" /secrets/install-key /secrets/password
rm "$secrets/password"
[ "$(slots)" = '["0","1"]' ] || fail "key slots after password-add: $(slots), not 0 and 1"
on_terminal "$password" recovery-check "$loop" 1 || fail "the password was refused at key slot 1"
on_terminal "$wrong" recovery-check "$loop" 1 && fail "a wrong password was accepted"
on_terminal "$(cat "$secrets/install-key")" recovery-check "$loop" 1 && fail "the key of the installation was accepted as the password"
echo "key slot 1 is the password: it unlocks, a wrong one and the key of the installation do not"

# The recovery key (to a file, for CI), then the removal of key slot 0, which refuses another key.
in_image -e NYRA_CI=1 -- recovery-to-file "$loop" /secrets/install-key
sudo chown "$(id -u):$(id -g)" "$secrets/recovery-key"
step_fails any "removing key slot 0 with the recovery key as the key of the installation" \
  wipe-install-slot "$loop" /secrets/recovery-key
[ "$(slots)" = '["0","1","2"]' ] || fail "key slots after the refused removal: $(slots)"
in_image -- wipe-install-slot "$loop" /secrets/install-key
[ "$(slots)" = '["1","2"]' ] || fail "key slots after wipe-install-slot: $(slots), not 1 and 2"
stop_sampling

# The header of the finished disk, and the changes of it that the check must refuse.
in_image -- luks-json "$loop" > "$secrets/header.json"
check_luks_header_password < "$secrets/header.json" || fail "the header check refused the finished disk: $(jq -c . "$secrets/header.json")"
jq -r '.keyslots["1"].kdf | "key slot 1: \(.type), \(.memory / 1024 | floor) MiB, \(.time) passes, \(.cpus) threads"' "$secrets/header.json"
refused() { # refused DESCRIPTION JQ_FILTER: the header with the filter applied is refused
  if jq -c "$2" "$secrets/header.json" | check_luks_header_password; then fail "the header check accepted: $1"; fi
  echo "refused by the header check: $1"
}
refused "256 MiB less one KiB of memory" '.keyslots["1"].kdf.memory = 262143'
refused "the memory as a string (jq: greater than any number)" '.keyslots["1"].kdf.memory = "1"'
refused "the key size as a string" '.keyslots["1"].key_size = "64"'
refused "the time cost as a string" '.keyslots["1"].kdf.time = "0"'
refused "no memory in the key derivation" 'del(.keyslots["1"].kdf.memory)'
refused "pbkdf2 for the password" '.keyslots["1"].kdf = {type: "pbkdf2", hash: "sha256", iterations: 1000, salt: "AAAA"}'
refused "argon2i for the password" '.keyslots["1"].kdf.type = "argon2i"'
refused "a third key slot" '.keyslots["3"] = .keyslots["1"]'
refused "the key of the installation still there" '.keyslots["0"] = .keyslots["1"]'
refused "a TPM2 token" '.tokens["9"] = {type: "systemd-tpm2", keyslots: ["1"]}'
refused "a second recovery token" '.tokens["9"] = {type: "systemd-recovery", keyslots: ["1"]}'
refused "no token" '.tokens = {}'
refused "the recovery token on the password's key slot" '.tokens |= map_values(.keyslots = ["1"])'
refused "a key of 256 bits" '.keyslots["1"].key_size = 32'

# The password nowhere it must not be: in no process's arguments while the steps ran, not in the
# journal or the containers' logs and configurations, not in the unencrypted start of the disk.
printf '%s\n%s\n%s\n' "$password" "$(cat "$secrets/install-key")" "$(cat "$secrets/recovery-key")" > "$secrets/patterns"
found=""
if grep -q -a -F -f "$secrets/patterns" "$secrets/ps"; then found+=" the arguments of a process"; fi
if leaked "$secrets/password-pattern"; then found+=" the journal or a container's log"; fi
root_start="$(sfdisk -J "$disk" | jq '.partitiontable.partitions[1].start')"
# grep -c reads to the end: with -q, head would end on SIGPIPE, which pipefail counts as a failure.
n="$(head -c $(((root_start + 32768) * 512)) "$disk" | grep -c -a -F -f "$secrets/patterns" || true)"
[ "$n" = 0 ] || found+=" the unencrypted part of the disk"
[ -z "$found" ] || fail "the password, the key of the installation or the recovery key was found in:$found"
# The search of the disk finds a string that is in it.
printf 'a line with %s in it\n' "$password" | grep -q -a -F -f "$secrets/patterns" || fail "the search of the disk does not find the password"
echo "the password, the key of the installation and the recovery key: in no process's arguments, in no log, not in the LUKS2 header"
