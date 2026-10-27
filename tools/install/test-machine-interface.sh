#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Offline test of the machine interface of the installer (tools/install/nyra-install.sh check | disks |
# install | mok-import, docs/INSTALL-INTERFACE.md), without root, a registry or a VM. The scripts run from
# copies of the files they read, on a terminal made by tools/install/pty-run.py, with stand-ins for what
# they call on the machine: lsblk (a fixture), mokutil, sfdisk, podman (the steps of in-image.sh), the
# verified pull and the rest. The paths the script reads from the machine (/sys/firmware/efi,
# /proc/meminfo, /dev/tpmrm0, /run/...) are assignments at the top of the copies, changed here and
# nowhere else. A disk is a file: the stand-in sfdisk overwrites its first KiB, so a change to it shows
# in a hash, and a refusal shows that the hash did not move. It checks that:
#   - check and disks give the JSON the text installer reads (one object, one array; nothing else on stdout);
#   - an installation emits its events in order, with the exit status and disk_changed of every failure
#     (10 and false before the first write, 11 and true after), and the step that failed;
#   - a wrong confirmation, a disk that is in use, the disk it started from, a read-only or too small one,
#     a machine without Secure Boot, a TPM or the memory, answers that are not complete: refused, and the
#     disk is not touched;
#   - the recovery key is shown and the installer waits for an Enter pressed after it (not one typed
#     before, not the end of the input), then clears the screen and its scroll-back, in both modes;
#     nothing is typed back and nothing is checked against the disk;
#   - the recovery key and the one-time password of the Secure Boot key (made by the script, from the
#     alphabet of machine.sh, and given to mokutil as a hash in a file) go to the terminal after the line
#     go, and to no event, log or file; the password is shown only after mokutil took the import, and the
#     installer waits for Enter after it; no password is in an argument, in the environment, in ps or
#     anywhere under the work directory; the terminal mode refuses what it always refused.
#   tools/install/test-machine-interface.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
command -v jq > /dev/null || { echo "test-machine-interface: jq is not installed"; exit 77; }

t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT
fail() {
  echo "::error::$*" >&2
  exit 1
}

digest=sha256:$(printf 'a%.0s' $(seq 64))
commit=$(printf 'c%.0s' $(seq 40))
version=2026.10.7
# What the stand-in prints as the recovery key, and the passwords no file may hold.
key=ccccdddd-eeeeffff-gggghhhh-iiiijjjj-kkkkllll-nnnnrrrr-ttttuuuu-vvvvbbbb
admin_pw='Sentinel-admin-pw-4711'
disk_pw='Sentinel-disk-pw-4711'
fingerprint="$(grep -Eo '([0-9A-F]{2}:){31}[0-9A-F]{2}' docs/SIGNING.md)"

# --- the stand-ins ---------------------------------------------------------------------------------
mkdir "$t/bin" "$t/efi"
echo 'MemTotal:        8388608 kB' > "$t/meminfo"
printf '%s\n' 'SecureBoot enabled' > "$t/sb-state"
dd if=/dev/urandom of="$t/disk" bs=1M count=2 status=none
cat > "$t/bin/id" << 'EOF2'
#!/bin/sh
echo 0
EOF2
cat > "$t/bin/uname" << 'EOF2'
#!/bin/sh
echo "${FAKE_ARCH:-x86_64}"
EOF2
cat > "$t/bin/findmnt" << 'EOF2'
#!/bin/sh
echo tmpfs
EOF2
cat > "$t/bin/udevadm" << 'EOF2'
#!/bin/sh
exit 0
EOF2
cat > "$t/bin/systemd-detect-virt" << 'EOF2'
#!/bin/sh
exit "${VIRT_RC:-1}"
EOF2
cat > "$t/bin/lsblk" << 'EOF2'
#!/bin/sh
case " $* " in
  *" -J "*) cat "$FIXTURE" ;;
  *" -dnro TYPE "*) echo disk ;;
  *"-nro TYPE"*) printf 'disk\npart\npart\n' ;;
esac
EOF2
cat > "$t/bin/mokutil" << 'EOF2'
#!/bin/sh
echo "mokutil $*" >> "$CALLS"
case "$1" in
  --sb-state) cat "$SB_STATE"; [ -s "$SB_STATE" ] ;;
  --test-key)
    # As the firmware's variables: a key that is queued (MokNew) answers 1 like one that is enrolled;
    # TESTKEY_RC=1 is an enrolled one, which a revoke does not change.
    [ -z "${TESTKEY_RC:-}" ] || exit "$TESTKEY_RC"
    [ ! -e "$MOK_QUEUED" ] || exit 1
    exit 0
    ;;
  --revoke-import) rm -f "$MOK_QUEUED" ;;
  --import)
    # The script gives the hash of the one-time password in a file (--hash-file): never a prompt, which
    # needs a terminal and a typed password. What is kept: the mode and the line of the file (a hash, not
    # the password), and what the process and its surroundings hold, to look for the password.
    hash_file=""
    while [ $# -gt 0 ]; do
      [ "$1" != --hash-file ] || hash_file="$2"
      shift
    done
    [ -f "$hash_file" ] || exit 2
    echo "$(stat -c %a "$hash_file") $(cat "$hash_file")" > "$MOK_SEEN"
    env >> "$ENVLOG"
    "$PSOWN" >> "$PROCLOG"
    # A request that is queued already is refused, as mokutil does.
    [ ! -e "$MOK_QUEUED" ] || exit 1
    [ "${IMPORT_RC:-0}" != 0 ] || : > "$MOK_QUEUED"
    exit "${IMPORT_RC:-0}"
    ;;
esac
EOF2
# Writes to the disk: its first KiB. What the process that called it holds is recorded, to look for passwords.
cat > "$t/bin/sfdisk" << 'EOF2'
#!/bin/sh
echo "sfdisk $*" >> "$CALLS"
cat > "$DISKFILE.sfdisk"
{ tr '\0' ' ' < "/proc/$PPID/cmdline"; echo; tr '\0' '\n' < "/proc/$PPID/environ"; "$PSOWN"; } >> "$PROCLOG"
dd if=/dev/zero of="$DISKFILE" bs=1k count=1 conv=notrunc status=none
EOF2
cat > "$t/bin/podman" << 'EOF2'
#!/bin/bash
echo "podman $*" >> "$CALLS"
env >> "$ENVLOG"
"$PSOWN" >> "$PROCLOG"
args=("$@")
step="" host_secrets=""
for i in "${!args[@]}"; do
  [ "${args[$i]}" = /nyra-install/in-image.sh ] && { step="${args[$((i + 1))]}"; step_args=("${args[@]:$((i + 2))}"); }
  case "${args[$i]}" in *:/secrets) host_secrets="${args[$i]%:/secrets}" ;; esac
done
if [ -z "$step" ]; then
  cat "$IMAGE_CERT"
  exit 0
fi
[ "$step" != "$FAIL_STEP" ] || exit 1
case "$step" in
  recovery-show) echo "RECOVERY-KEY: $(cat "$KEYFILE")" ;;
  luks-json) cat "$LUKS_JSON" ;;
  password-memory) exit "${PWMEM_RC:-0}" ;;
  password-add)
    # The password is a file of the secrets, only its bytes, mode 0600, named as the last argument: the
    # stand-in keeps its mode and a hash (never the password), and checks that it is the one asked for.
    [ "${step_args[2]}" = /secrets/password ] || exit 1
    got="$(sha256sum < "$host_secrets/password" | cut -c1-64)"
    [ "$got" = "$DISK_PW_SHA" ] || exit 1
    echo "$(stat -c %a "$host_secrets/password") $got" > "$PW_SEEN"
    exit "${PWADD_RC:-0}"
    ;;
  admin-record)
    # The record of the first administrator: the password is on the standard input, the name and the file
    # are arguments. Only a hash of the password is kept, to see that it came through the standard input.
    IFS= read -r pw
    printf '%s' "$pw" | sha256sum | cut -c1-64 > "$ADMIN_STDIN"
    printf '%s:$y$j9T$stand-in$%s\n' "${step_args[0]}" "$(printf '%s' "$pw" | sha256sum | cut -c1-43)" > "$host_secrets/${step_args[1]#/secrets/}"
    ;;
  install-system)
    # The record must be there, made before the disk was touched, and named as the last argument.
    # (The terminal mode makes no administrator: CLI_MODE.)
    [ -n "${CLI_MODE:-}" ] || { [ "${step_args[5]:-}" = /secrets/first-admin ] && [ -s "$host_secrets/first-admin" ]; } || exit 1
    # The disk's password file is deleted as soon as password-add is done: not there for the later steps.
    [ ! -e "$host_secrets/password" ] || exit 1
    [ -n "${CLI_MODE:-}" ] || cp "$host_secrets/first-admin" "$ADMIN_PLACED"
    ;;
esac
EOF2
# openssl makes the hash of the one-time password: what it is given (arguments, environment, the processes
# around it) is recorded like the others', then the real one runs.
cat > "$t/bin/openssl" << EOF2
#!/bin/sh
echo "openssl \$*" >> "\$CALLS"
env >> "\$ENVLOG"
"\$PSOWN" >> "\$PROCLOG"
exec $(command -v openssl) "\$@"
EOF2
chmod +x "$t/bin/"*
cat > "$t/luks.json" << 'EOF2'
{"tokens":{"0":{"type":"systemd-recovery","keyslots":["1"]},"1":{"type":"systemd-tpm2","keyslots":["2"],"tpm2-pcrs":[]}},
 "keyslots":{"1":{},"2":{}}}
EOF2
# The header of a disk with a password: the recovery key (key slot 2, with its token) and the password
# (key slot 1, no token, argon2id with 1 GiB).
cat > "$t/luks-password.json" << 'EOF2'
{"tokens":{"0":{"type":"systemd-recovery","keyslots":["2"]}},
 "keyslots":{"1":{"type":"luks2","key_size":64,"kdf":{"type":"argon2id","memory":1048576,"time":4}},"2":{"type":"luks2","key_size":64}}}
EOF2
# The disks, as lsblk -J -b prints them.
cat > "$t/disks.json" << 'EOF2'
{"blockdevices": [
 {"name":"loop0","path":"/dev/loop0","type":"loop","size":100000,"model":null,"ro":true,"rm":false,"fstype":null,"label":null,"parttype":null,"mountpoints":["/snap/x"]},
 {"name":"sr0","path":"/dev/sr0","type":"rom","size":1000000000,"model":"DVD","ro":false,"rm":true,"fstype":null,"label":null,"parttype":null,"mountpoints":[]},
 {"name":"zram0","path":"/dev/zram0","type":"disk","size":4000000000,"model":null,"ro":false,"rm":false,"fstype":"swap","label":null,"parttype":null,"mountpoints":["[SWAP]"]},
 {"name":"sda","path":"/dev/sda","type":"disk","size":500107862016,"model":"Samsung SSD 870 EVO","serial":"S5H2NJ0N","wwn":"0x5002538f","ptuuid":"6f3c1d2e-0000-4000-8000-000000000001","ro":false,"rm":false,"fstype":null,"label":null,"parttype":null,"mountpoints":[],
  "children":[
   {"name":"sda1","path":"/dev/sda1","type":"part","size":272629760,"model":null,"ro":false,"rm":false,"fstype":"vfat","label":null,"parttype":"c12a7328-f81f-11d2-ba4b-00a0c93ec93b","mountpoints":[]},
   {"name":"sda2","path":"/dev/sda2","type":"part","size":16777216,"model":null,"ro":false,"rm":false,"fstype":null,"label":null,"parttype":"e3c9e316-0b5c-4db8-817d-f92df00215ae","mountpoints":[]},
   {"name":"sda3","path":"/dev/sda3","type":"part","size":499000000000,"model":null,"ro":false,"rm":false,"fstype":"ntfs","label":"Windows (C:)","parttype":"EBD0A0A2-B9E5-4433-87C0-68B6B72699C7","mountpoints":[null]}]},
 {"name":"nvme0n1","path":"/dev/nvme0n1","type":"disk","size":1000204886016,"model":"WD \"Black\" SN850  ","ro":false,"rm":false,"fstype":null,"label":null,"parttype":null,"mountpoints":[]},
 {"name":"sdb","path":"/dev/sdb","type":"disk","size":31000000000,"model":"USB DISK 3.0","ro":false,"rm":true,"fstype":null,"label":null,"parttype":null,"mountpoints":[],
  "children":[{"name":"sdb1","path":"/dev/sdb1","type":"part","size":30000000000,"model":null,"ro":false,"rm":true,"fstype":"iso9660","label":"NYRA-ISO","parttype":null,"mountpoints":["/run/live/medium"]}]},
 {"name":"sdc","path":"/dev/sdc","type":"disk","size":256000000000,"model":"Data","ro":false,"rm":false,"fstype":null,"label":null,"parttype":null,"mountpoints":[],
  "children":[{"name":"sdc1","path":"/dev/sdc1","type":"part","size":250000000000,"model":null,"ro":false,"rm":false,"fstype":"ext4","label":null,"parttype":null,"mountpoints":["/mnt"]}]},
 {"name":"sdd","path":"/dev/sdd","type":"disk","size":256000000000,"model":"Locked","ro":true,"rm":false,"fstype":null,"label":null,"parttype":null,"mountpoints":[]},
 {"name":"sde","path":"/dev/sde","type":"disk","size":16000000000,"model":"Small","ro":false,"rm":false,"fstype":null,"label":null,"parttype":null,"mountpoints":[]},
 {"name":"sdf","path":"/dev/sdf","type":"disk","size":256000000000,"model":"Swap","ro":false,"rm":false,"fstype":null,"label":null,"parttype":null,"mountpoints":[],
  "children":[{"name":"sdf1","path":"/dev/sdf1","type":"part","size":8000000000,"model":null,"ro":false,"rm":false,"fstype":"swap","label":null,"parttype":null,"mountpoints":["[SWAP]"]}]}
]}
EOF2
# The disk of the installations: eligible, and the file that stands for it.
cat > "$t/one-disk.json" << 'EOF2'
{"blockdevices": [{"name":"vda","path":"/dev/vda","type":"disk","size":64000000000,"model":"QEMU HARDDISK","ro":false,"rm":false,"fstype":null,"label":null,"parttype":null,"mountpoints":[]}]}
EOF2

# The arguments of the processes of this test, to look for a password: not those of the whole machine.
# A busy machine runs other jobs (a second run of this test, an agent's grep) whose command lines hold
# the same fixed strings as the searches here, and "ps -e" showed them as a leak, now and then. The
# processes below this shell are the ones the installer and the stand-ins start.
cat > "$t/ps-own" << 'EOF2'
#!/bin/sh
ps -eww -o pid=,ppid=,args= | awk -v root="$TEST_ROOT" '
  { pid = $1; par[pid] = $2; sub(/^ *[0-9]+ +[0-9]+ ?/, ""); args[pid] = $0; order[++n] = pid }
  END {
    for (i = 1; i <= n; i++)
      for (p = order[i]; p + 0 > 1; p = par[p])
        if (p == root) { print args[order[i]]; break }
  }'
EOF2
chmod +x "$t/ps-own"
printf '%s' "$key" > "$t/key.txt"
export TEST_ROOT=$$ PSOWN="$t/ps-own"
export CALLS="$t/calls.log" ENVLOG="$t/env.log" PROCLOG="$t/proc.log" DISKFILE="$t/disk" KEYFILE="$t/key.txt"
export SB_STATE="$t/sb-state" LUKS_JSON="$t/luks.json" FIXTURE="$t/one-disk.json" IMAGE_CERT="$t/image.crt"
export ADMIN_STDIN="$t/admin-stdin" ADMIN_PLACED="$t/admin-placed" PW_SEEN="$t/pw-seen" MOK_SEEN="$t/mok-seen" MOK_QUEUED="$t/mok-queued"
DISK_PW_SHA="$(printf '%s' "$disk_pw" | sha256sum | cut -c1-64)"
export DISK_PW_SHA
: > "$CALLS"
: > "$ENVLOG"
: > "$PROCLOG"
# The control: the list sees a process of this test that holds a string on its command line, and not one of
# another job (setsid -f leaves the tree), so that the search finds a real leak and a stranger is no leak.
bash -c 'sleep 3; :' ps-own-control own-argument-4711 &
own=$!
setsid -f bash -c 'sleep 3; :' ps-own-control foreign-argument-4711
sleep 0.5
seen="$("$PSOWN")"
kill "$own"
wait "$own" 2> /dev/null || true
pkill -f foreign-argument-4711 || true
grep -qF own-argument-4711 <<< "$seen" || fail "the list of the processes of the test does not show a process of the test"
! grep -qF foreign-argument-4711 <<< "$seen" || fail "the list of the processes of the test shows a process of another job"
echo "control: the list of processes holds those of the test and none of other jobs"

# --- the trees ---------------------------------------------------------------------------------------
# set_line FILE OLD NEW: replaces the line OLD, which must be there exactly once, by NEW.
set_line() {
  [ "$(grep -cxF -- "$2" "$1")" = 1 ] || fail "$1 does not have exactly one line: $2"
  sed -i "s|^$(printf '%s' "$2" | sed 's/[][\.*^$|]/\\&/g')\$|$3|" "$1"
  grep -qxF -- "$3" "$1" || fail "$1: the line was not replaced: $3"
}
# tree NAME [TPM_GLOB]: a release tree, the files the scripts read with the machine moved under $t.
tree() {
  local d="$t/$1"
  mkdir -p "$d"
  git ls-files -z tools/install files/usr/lib/nyra/containers files/usr/lib/nyra/secureboot docs/SIGNING.md \
    | tar --null -T - -cf - | tar -xf - -C "$d"
  printf 'version=%s\ndigest=%s\ncommit=%s\narchitecture=amd64\n' "$version" "$digest" "$commit" > "$d/RELEASE"
  set_line "$d/tools/install/nyra-install.sh" 'secrets=/run/nyra-install' "secrets=$t/secrets"
  set_line "$d/tools/install/nyra-install.sh" 'storage_dir=/var/lib/containers' "storage_dir=$t/containers"
  set_line "$d/tools/install/machine.sh" 'efi_dir=/sys/firmware/efi' "efi_dir=$t/efi"
  set_line "$d/tools/install/machine.sh" 'meminfo=/proc/meminfo' "meminfo=$t/meminfo"
  set_line "$d/tools/install/machine.sh" "tpm_glob='/dev/tpmrm*'" "tpm_glob='${2:-/dev/null}'"
  set_line "$d/tools/install/machine.sh" 'tpm_dev=/dev/tpmrm0' 'tpm_dev=/dev/null'
  set_line "$d/tools/install/machine.sh" 'log_dir=/run/nyra-installer' "log_dir=$t/log"
  # The pull is not under test here (tools/install/test-verified-pull.sh): it prints an image ID.
  cat > "$d/tools/install/verified-pull.sh" << 'EOF2'
#!/bin/bash
echo "verified-pull $*" >> "$CALLS"
[ -z "${PULL_FAILS:-}" ] || exit 2
# While the image is pulled, another disk takes the name.
[ -z "${PULL_SWAPS:-}" ] || sed 's|QEMU HARDDISK|OTHER DISK|; s|64000000000|128000000000|' "$FIXTURE" > "$FIXTURE.new" && mv "$FIXTURE.new" "$FIXTURE"
# While the image is pulled, something mounts the disk.
[ -z "${PULL_MOUNTS:-}" ] || sed 's|"mountpoints":\[\]|"mountpoints":["/mnt"]|' "$FIXTURE" > "$FIXTURE.new" && mv "$FIXTURE.new" "$FIXTURE"
printf 'b%.0s' $(seq 64)
echo
EOF2
  chmod +x "$d/tools/install/verified-pull.sh"
}
tree ok
tree notpm /nonexistent/tpm*
cp "$t/ok/files/usr/lib/nyra/secureboot/nyra.crt" "$t/image.crt"
export PATH="$t/bin:$PATH"

# --- running ---------------------------------------------------------------------------------------
sh_ok() { # sh_ok NAME TREE ARGS...: runs a subcommand with no terminal; sets rc, out, err
  local tree="$1"
  shift
  "$t/$tree/tools/install/nyra-install.sh" "$@" > "$t/out" 2> "$t/err" < /dev/null && rc=0 || rc=$?
  out="$(cat "$t/out")" err="$(cat "$t/err")"
}
# answers DEVICE CONFIRM UNLOCK: the line of answers, then one go for every handoff.
answers() {
  jq -nc --arg device "$1" --arg confirm "$2" --arg unlock "$3" --arg apw "$admin_pw" --arg dpw "$disk_pw" \
    '{device: $device, confirm: $confirm, unlock: $unlock, admin_name: "maria", admin_password: $apw}
     + (if $unlock == "password" then {disk_password: $dpw} else {} end)' > "$t/answers.in"
  printf 'go\ngo\n' >> "$t/answers.in"
}
reset_run() {
  rm -rf "$t/log" "$t/secrets" "$t/containers"
  # The firmware's request for the key stays between two runs only if the test says so.
  [ -n "${keep_queue:-}" ] || rm -f "$MOK_QUEUED"
  : > "$t/events"
  : > "$CALLS"
  : > "$t/transcript"
  cp "$t/answers.in" "$t/answers"
}
# What the terminal is told when it shows the prompt after the recovery key and the one after the
# one-time password: Enter. replies (a JSON list, see pty-run.py), pretype (newlines typed before
# anything) and run_timeout (seconds) change a run.
key_prompt='Press Enter when you have written it down: $'
mok_prompt='Press Enter when you have written the password down: $'
enter_reply="[[\"$key_prompt\", \"\"], [\"$mok_prompt\", \"\"]]"
# run TREE SUBCOMMAND: on a terminal, events on descriptor 3 and answers on 4. Sets rc, events, transcript.
# The shell around the script is the text installer: it keeps the terminal open (the script itself uses it
# only for the handoffs) and gives the script its status.
run() {
  local tree="$1"
  shift
  reset_run
  if [ -n "${PRELOG:-}" ]; then
    mkdir -p "$t/log"
    : > "$t/log/install.log"
    chmod 0644 "$t/log/install.log"
  fi
  REPLIES="${replies:-$enter_reply}" PRETYPE="${pretype:-0}" TIMEOUT="${run_timeout:-60}" python3 -I tools/install/pty-run.py "$t/transcript" \
    bash -c '"$@"; exit $?' _ "$t/$tree/tools/install/nyra-install.sh" "$@" --events-fd 3 --answers-fd 4 \
    3> "$t/events" 4< "$t/answers" && rc=0 || rc=$?
  events="$(cat "$t/events")"
}
# cleared_after_key: the last run's terminal shows the recovery key, and after it the sequence that
# clears the screen and its scroll-back.
cleared_after_key() { cleared_after "$key"; }
# cleared_after TEXT: the same for any text.
cleared_after() {
  local text
  text="$(tr -d '\r' < "$t/transcript")"
  [[ "$text" == *"$1"* && "${text#*"$1"}" == *$'\033[3J'* ]]
}
# mok_shown: the one-time passwords the last run showed on the terminal, as they are typed (without the
# dash), one per line. The script shows it on a line of its own.
mok_shown() {
  tr -d '\r' < "$t/transcript" | sed -n 's/^    \([a-z2-9]\{5\}\)-\([a-z2-9]\{5\}\)$/\1\2/p'
}
# mok_leaks PASSWORD: the files under $t that hold the password, with or without its dash, other than the
# terminal's transcript (where it is shown, by design).
mok_leaks() {
  grep -rlF -e "$1" -e "${1:0:5}-${1:5}" "$t" --exclude=transcript --exclude=test-*.sh 2> /dev/null || true
}
disk_hash() { head -c 1048576 "$t/disk" | sha256sum; }
fresh_disk() { dd if=/dev/urandom of="$t/disk" bs=1k count=1 conv=notrunc status=none; }
called() { grep -q -- "$1" "$CALLS"; }
install_events='{"event":"step","id":"verify","state":"start"}
{"event":"step","id":"verify","state":"done"}
{"event":"step","id":"prepare","state":"start"}
{"event":"disk-changed"}
{"event":"step","id":"prepare","state":"done"}
{"event":"step","id":"install","state":"start"}
{"event":"step","id":"install","state":"done"}
{"event":"step","id":"protect","state":"start"}
{"event":"handoff","id":"recovery-key"}
{"event":"handoff-end"}
{"event":"step","id":"protect","state":"done"}
{"event":"step","id":"final","state":"start"}
{"event":"handoff","id":"mok-password"}
{"event":"handoff-end"}
{"event":"step","id":"final","state":"done"}
{"event":"done"}'
# Nothing was written: the disk is as it was, no step of the installation ran, and the keys are gone.
untouched() { # untouched HASH
  [ "$(disk_hash)" = "$1" ] || fail "the disk was written to"
  ! called '^sfdisk' || fail "sfdisk ran"
  ! called '^podman' || fail "a container ran"
  [ ! -e "$t/secrets" ] || fail "the keys of the installation are still there"
}
# The same, but the image's container ran (the record of the administrator is made from it before the disk).
untouched_but_podman() { # untouched_but_podman HASH
  [ "$(disk_hash)" = "$1" ] || fail "the disk was written to"
  ! called '^sfdisk' || fail "sfdisk ran"
  [ ! -e "$t/secrets" ] || fail "the keys of the installation are still there"
}
# refused_install MESSAGE_IN_LOG [ID]: the run that just ended failed before any write, as the text installer
# is told: the event fail with the id, disk_changed false, status 10; the reason is in the log.
refused_install() {
  [ "$rc" = 10 ] || fail "status $rc, not 10 ($1)"
  [ "$(tail -n 1 <<< "$events")" = "{\"event\":\"fail\",\"id\":\"${2:-verify}\",\"disk_changed\":false}" ] \
    || { printf '%s\n' "$events"; fail "not the event fail ${2:-verify} without a change ($1)"; }
  ! grep -q '"disk-changed"' <<< "$events" || fail "disk-changed before a refusal ($1)"
  grep -qF -- "$1" "$t/log/install.log" || { cat "$t/log/install.log"; fail "the log does not say: $1"; }
  echo "refused as expected: $1"
}
# no_secrets_anywhere_quiet: succeeds if a password is somewhere it must not be (for the control of the search).
no_secrets_anywhere_quiet() {
  grep -rlF -e Sentinel- "$t" --exclude=answers --exclude=answers.in --exclude=test-*.sh > /dev/null 2>&1
}
no_secrets_anywhere() {
  # The answers are where the passwords are put by the caller; nowhere else.
  if grep -rlF -e Sentinel- "$t" --exclude=answers --exclude=answers.in --exclude=test-*.sh 2> /dev/null | grep .; then
    fail "a password is in a file, in an argument, in the environment or in ps (the files above)"
  fi
}

# --- check -------------------------------------------------------------------------------------------
sh_ok ok check
[ "$rc" = 0 ] || { printf '%s\n' "$err"; fail "check failed ($rc)"; }
[ -z "$err" ] || fail "check wrote on stderr: $err"
jq -e --arg version "$version" --arg digest "$digest" --arg commit "$commit" --arg fp "$fingerprint" '
  . == {protocol: 1, arch: "x86_64", uefi: true, secure_boot: true, shim_checks: true, tpm: true,
        mem_tenths: 80, mem_need_gib: 6, virt: false,
        release: {version: $version, commit: $commit, digest: $digest,
                  signer: "nyra-image-signer@nyra-signing-3076.iam.gserviceaccount.com",
                  cert_name: "Nyra OS Secure Boot 2026", fingerprint: $fp},
        reserved: []}' <<< "$out" > /dev/null || { printf '%s\n' "$out"; fail "check is not the object the text installer reads"; }
echo "check gives one JSON object and nothing else"
printf 'root\ndaemon\n\nnyra\n' > "$t/ok/reserved-names"
sh_ok ok check
[ "$(jq -c .reserved <<< "$out")" = '["root","daemon","nyra"]' ] || fail "the reserved names of the tree: $out"
rm "$t/ok/reserved-names"
echo "the names of the system come from the tree"
# What the machine is: a BIOS, no Secure Boot, setup mode, shim validation off, no TPM, a VM, little memory.
check_is() { # check_is TREE 'jq filter' MESSAGE
  sh_ok "$1" check
  [ "$rc" = 0 ] || { printf '%s\n' "$err"; fail "check failed ($rc): $3"; }
  jq -e "$2" <<< "$out" > /dev/null || { printf '%s\n' "$out"; fail "check: $3"; }
  echo "check: $3"
}
rmdir "$t/efi"
check_is ok '.uefi == false' "not started in UEFI mode"
mkdir "$t/efi"
printf '%s\n%s\n' 'SecureBoot disabled' 'Platform is in Setup Mode' > "$t/sb-state"
check_is ok '.secure_boot == false and .shim_checks == true' "Secure Boot is off"
printf '%s\n%s\n' 'SecureBoot enabled' 'Platform is in Setup Mode' > "$t/sb-state"
check_is ok '.secure_boot == false' "Secure Boot on, in setup mode"
printf '%s\n%s\n' 'SecureBoot enabled' 'SecureBoot validation is disabled in shim' > "$t/sb-state"
check_is ok '.secure_boot == true and .shim_checks == false' "the shim checks are off"
: > "$t/sb-state"
check_is ok '.uefi == true and .secure_boot == false and .shim_checks == false' "mokutil cannot read the state"
printf '%s\n' 'SecureBoot enabled' > "$t/sb-state"
check_is notpm '.tpm == false and .secure_boot == true' "no TPM"
echo 'MemTotal:        4194304 kB' > "$t/meminfo"
check_is ok '.mem_tenths == 40' "4 GiB of memory"
echo 'MemTotal:        8388608 kB' > "$t/meminfo"
VIRT_RC=0 check_is ok '.virt == true' "a virtual machine"
FAKE_ARCH=aarch64 sh_ok ok check
[ "$rc" = 1 ] && grep -qF 'RELEASE is not for arm64' <<< "$err" || fail "an amd64 tree on aarch64: $rc $err"
echo "check: the tree of the other architecture is refused"
# A tree that is not right gives no JSON at all.
tree badfp
sed -i 's/6F:3E:51:F4/6F:3E:51:F5/' "$t/badfp/docs/SIGNING.md"
sh_ok badfp check
[ "$rc" = 1 ] && [ -z "$out" ] && grep -qF 'not the one of docs/SIGNING.md' <<< "$err" || fail "check of a tree whose fingerprint is not SIGNING.md's: $rc $out $err"
tree gitcheckout
rm "$t/gitcheckout/RELEASE"
sh_ok gitcheckout check
[ "$rc" = 1 ] && [ -z "$out" ] && grep -qF 'no RELEASE' <<< "$err" || fail "check of a tree without RELEASE: $rc $out $err"
sh_ok ok check extra
[ "$rc" = 1 ] && grep -qF usage <<< "$err" || fail "check takes no argument: $rc $err"
echo "check: a tree that is not a release tree, or whose fingerprint is not the signed one, gives no JSON"

# --- disks -------------------------------------------------------------------------------------------
FIXTURE="$t/disks.json" sh_ok ok disks
[ "$rc" = 0 ] && [ -z "$err" ] || fail "disks failed ($rc): $err"
summary="$(jq -r '.[] | "\(.name) \(.eligible) \(.reason) \(.min_gb // "-")"' <<< "$out")"
want='sda true null -
nvme0n1 true null -
sdb false booted -
sdc false in_use -
sdd false read_only -
sde false too_small 32
sdf false in_use -'
[ "$summary" = "$want" ] || { printf '%s\n' "$summary"; fail "disks: not the disks that can be chosen and why"; }
jq -e '
  .[0] == {name: "sda", path: "/dev/sda", bytes: 500107862016, model: "Samsung SSD 870 EVO",
           serial: "S5H2NJ0N", wwn: "0x5002538f", ptuuid: "6f3c1d2e-0000-4000-8000-000000000001", removable: false,
           eligible: true, reason: null, parts: [
    {label: "", fs: "vfat", bytes: 272629760, microsoft: false},
    {label: "", fs: "", bytes: 16777216, microsoft: true},
    {label: "Windows (C:)", fs: "ntfs", bytes: 499000000000, microsoft: true}]}
  and .[1].model == "WD \"Black\" SN850" and .[1].parts == [] and .[1].serial == null
  and .[2].removable == true and .[2].parts == [{label: "NYRA-ISO", fs: "iso9660", bytes: 30000000000, microsoft: false}]' \
  <<< "$out" > /dev/null || { printf '%s\n' "$out"; fail "disks: a disk is not as the text installer reads it"; }
echo "disks: eligible or not and why, the partitions, which disk it is, quotes in a model, no loop device, optical drive or zram"

# --- the one-time password of the Secure Boot key: alphabet, length, groups ----------------------------
# 400 passwords from the script's own function: 10 characters of the 32 of the alphabet (50 bits), none that
# looks like another, none repeated, every character of the alphabet seen.
passwords="$(bash -c 'set -euo pipefail; die() { echo "$*" >&2; exit 1; }; . tools/install/machine.sh
  for _ in $(seq 400); do mok_password; echo "$mok_pw"; done')"
[ "$(wc -l <<< "$passwords")" = 400 ] || fail "mok_password: not 400 passwords"
[ "$(grep -cE '^[a-km-np-z2-9]{10}$' <<< "$passwords")" = 400 ] || fail "mok_password: a password is not 10 characters of the alphabet"
[ "$(sort -u <<< "$passwords" | wc -l)" = 400 ] || fail "mok_password: a password came twice"
[ "$(fold -w1 <<< "$passwords" | sort -u | wc -l)" = 32 ] || fail "mok_password: not every character of the 32 was seen"
! grep -q '[01loO]' <<< "$passwords" || fail "mok_password: a character that looks like another"
[ "$(bash -c 'set -euo pipefail; . tools/install/machine.sh; mok_pw=abcdefghjk; mok_grouped')" = abcde-fghjk ] || fail "mok_grouped: not groups of 5"
if bash -xc 'die() { echo "$*" >&2; exit 1; }; . tools/install/machine.sh; mok_password; echo "$mok_pw"' > "$t/xtrace.out" 2> "$t/xtrace.err"; then
  fail "mok_password ran with xtrace on"
fi
! grep -qE '^[a-km-np-z2-9]{10}$' "$t/xtrace.out" || fail "mok_password gave a password with xtrace on"
echo "mok_password: refuses to run with xtrace on"
echo "mok_password: 10 characters of 32 (50 bits), lowercase letters and digits, none that looks like another; mok_grouped: abcde-fghjk"

# --- install, the whole way --------------------------------------------------------------------------
answers /dev/vda /dev/vda tpm
before="$(disk_hash)"
run ok install
[ "$rc" = 0 ] || { printf '%s\n' "$events"; cat "$t/transcript" "$t/log/install.log"; fail "install failed ($rc)"; }
[ "$events" = "$install_events" ] || { printf '%s\n' "$events"; fail "the events of an installation are not in the order of the text installer"; }
[ "$(disk_hash)" != "$before" ] || fail "the stand-in disk was not written to: the test would not see a write"
called '^verified-pull ' || fail "no pull"
[ "$(grep -c '^sfdisk' "$CALLS")" = 1 ] || fail "sfdisk did not run exactly once"
for s in admin-record format install-system recovery-show tpm-enroll wipe-install-key esp-sync; do
  called "/nyra-install/in-image.sh $s" || fail "the step $s did not run"
done
called '^mokutil --import ' || fail "no import of the key"
[ ! -e "$t/secrets" ] || fail "the key of the installation is still there"
tr -d '\r' < "$t/transcript" | grep -qF "RECOVERY-KEY: $key" || fail "the recovery key was not shown on the terminal"
tr -d '\r' < "$t/transcript" | grep -qF "$fingerprint" || fail "the fingerprint was not shown on the terminal"
cleared_after_key || fail "the screen and its scroll-back were not cleared after the recovery key"
grep -E '^podman .*--log-driver=none .*in-image.sh recovery-show ' "$CALLS" > /dev/null \
  || fail "recovery-show did not run with --log-driver=none: its output would be in a log"
tr -d '\r' < "$t/transcript" | grep -qF 'Press Enter when you have written it down: ' || fail "the terminal did not ask for Enter after the recovery key"
! called 'in-image.sh recovery-check' && ! called 'in-image.sh recovery-wipe' || fail "the recovery key was checked against the disk"
echo "install: the events in order, the disk written, the key and the fingerprint on the terminal"
# The one-time password of the Secure Boot key: made by the script, shown once on the terminal (after the
# import was taken, with the words that say how to type it) and cleared after Enter; mokutil got its hash
# in a 0600 file, which is the hash of that password; the password is nowhere else.
[ "$(mok_shown | wc -l)" = 1 ] || fail "the one-time password was not shown exactly once"
mokpw="$(mok_shown)"
tr -d '\r' < "$t/transcript" | grep -qF 'Type it on the blue screen without the dash, with Caps Lock off: 10 lowercase letters and digits.' \
  || fail "the terminal does not say how to type the one-time password"
tr -d '\r' < "$t/transcript" | grep -qF 'Press Enter when you have written the password down: ' || fail "the terminal did not ask for Enter after the one-time password"
cleared_after "${mokpw:0:5}-${mokpw:5}" || fail "the screen and its scroll-back were not cleared after the one-time password"
read -r mode hash < "$MOK_SEEN"
salt="$(cut -d'$' -f3 <<< "$hash")"
[ "$mode" = 600 ] || fail "mokutil got its hash file with the mode $mode, not 600"
[ "$(printf '%s\n' "$mokpw" | openssl passwd -6 -stdin -salt "$salt")" = "$hash" ] \
  || fail "the hash file is not the SHA-512 crypt hash of the password that was shown (without the dash)"
called '^mokutil --import .* --hash-file ' || fail "mokutil --import was not given a hash file"
[ -z "$(mok_leaks "$mokpw")" ] || { mok_leaks "$mokpw"; fail "the one-time password is in a file, an event or the log (the files above)"; }
! grep -qF -e "$mokpw" -e "${mokpw:0:5}-${mokpw:5}" "$CALLS" "$ENVLOG" "$PROCLOG" || fail "the one-time password is in an argument, the environment or ps"
grep -q '^openssl passwd -6 -stdin$' "$CALLS" || fail "the hash was not made by openssl with the password on its standard input (the wrapper did not see the call)"
[ ! -e "$t/secrets" ] || fail "the hash file of the one-time password is still there"
echo "install: the one-time password is made by the script, shown once after the import, cleared after Enter; mokutil got its hash in a 0600 file, never the password"
# The control: a copy that writes the one-time password to the log is found by the search.
tree leaky_mok
sed -i 's|^  mok_pw=""$|  echo "$mok_pw" >\&"$logfd"; mok_pw=""|' "$t/leaky_mok/tools/install/nyra-install.sh"
grep -qF 'echo "$mok_pw" >&"$logfd"' "$t/leaky_mok/tools/install/nyra-install.sh" || fail "the leaky copy for the one-time password is not leaky"
run leaky_mok install
[ -n "$(mok_leaks "$(mok_shown)")" ] || fail "the control of the search for the one-time password: the leak was not found"
echo "control: a one-time password written to the log is found by the search"
# The same for the hash step: a copy that gives openssl the password as an argument is found, through the
# openssl wrapper (the mokutil stand-in sees only the file, after openssl has exited).
tree leaky_openssl
sed -i 's#printf .%s\\n. "$mok_pw" | openssl passwd -6 -stdin > "$hash"#openssl passwd -6 "$mok_pw" > "$hash"#' "$t/leaky_openssl/tools/install/nyra-install.sh"
grep -qF 'openssl passwd -6 "$mok_pw" > "$hash"' "$t/leaky_openssl/tools/install/nyra-install.sh" || fail "the leaky copy for openssl is not leaky"
run leaky_openssl install
grep -qF -e "$(mok_shown)" "$CALLS" || fail "the control of the search for the one-time password in openssl's arguments: the leak was not found"
echo "control: a one-time password given to openssl as an argument is found by the search"
answers /dev/vda /dev/vda tpm
# The root partition has the type of the machine's architecture: systemd-gpt-auto in the initrd ignores
# the other architectures' root types and the machine would never find its root. An architecture without
# a type is refused before sfdisk runs.
x86_root=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709
arm_root=B921B045-1DF0-41C3-AF44-4C6F280D3FAE
grep -qF "type=$x86_root" "$DISKFILE.sfdisk" && ! grep -qF "$arm_root" "$DISKFILE.sfdisk" || fail "the installation on x86_64 did not partition with the x86-64 root type"
partitions() { # partitions ARCH: what partition_disk gives sfdisk on that architecture
  rm -f "$DISKFILE.sfdisk"
  (PATH="$t/bin:$PATH" FAKE_ARCH="$1" CALLS=/dev/null bash -c '. tools/install/lib.sh; partition_disk "$1"' _ "$DISKFILE")
}
partitions aarch64 || fail "partition_disk failed on aarch64"
grep -qF "type=$arm_root" "$DISKFILE.sfdisk" && ! grep -qF "$x86_root" "$DISKFILE.sfdisk" || fail "on aarch64 the root partition does not have the aarch64 type"
if partitions riscv64 2> "$t/riscv.err"; then fail "partition_disk took an architecture without a root type"; fi
[ ! -e "$DISKFILE.sfdisk" ] && grep -qF 'riscv64' "$t/riscv.err" || fail "an unknown architecture reached sfdisk or was refused without saying which"
echo "partition_disk: the root partition has the x86-64 or the aarch64 type by architecture, any other is refused before the disk is touched"
# What must not hold the recovery key or a password.
if grep -rlF "$key" "$t" --exclude=transcript --exclude=key.txt --exclude=answers.in --exclude=answers --exclude=test-*.sh 2> /dev/null | grep .; then
  fail "the recovery key is in a file, event or log (the files above)"
fi
grep -qF 'nyra-install: done' "$t/log/install.log" || fail "the log does not end the installation"
[ "$(stat -c %a "$t/log/install.log")" = 600 ] || fail "the log is not 0600"
no_secrets_anywhere
echo "install: the recovery key is in no file, event or log; no password is in an argument, the environment, ps or the log"
# The first administrator: the record is made by the image from the password on its standard input,
# before the disk is touched, and the record goes to install-system.
called "/nyra-install/in-image.sh admin-record maria /secrets/first-admin" || fail "the record of the administrator was not asked for with the name and the file"
[ "$(cat "$ADMIN_STDIN")" = "$(printf '%s' "$admin_pw" | sha256sum | cut -c1-64)" ] \
  || fail "the administrator's password did not reach the image on its standard input"
grep -q '^maria:\$y\$' "$ADMIN_PLACED" || fail "the record was not given to install-system"
[ "$(grep -n 'admin-record' "$CALLS" | head -n 1 | cut -d: -f1)" -lt "$(grep -n '^sfdisk' "$CALLS" | head -n 1 | cut -d: -f1)" ] \
  || fail "the record was made after the disk was written to"
[ "$(grep -n 'admin-record' "$CALLS" | head -n 1 | cut -d: -f1)" -lt "$(grep -n 'in-image.sh install-system' "$CALLS" | head -n 1 | cut -d: -f1)" ] \
  || fail "the record was made after the system was installed"
! grep -F -e "$admin_pw" "$CALLS" "$ENVLOG" "$PROCLOG" > /dev/null || fail "the administrator's password is in an argument, the environment or ps"
echo "install: the administrator's record is made from the password on the standard input before the disk is touched, and goes to the new system"
# The control of that search: a copy that gives the password to the container as an environment variable
# is found (the password is then in the arguments of podman), so the search above does see a leak.
tree leaky
sed -i 's|in_image -i --log-driver=none -- admin-record|in_image -i --log-driver=none -e "PW=$a_admin_password" -- admin-record|' "$t/leaky/tools/install/nyra-install.sh"
grep -qF 'in_image -i --log-driver=none -e "PW=$a_admin_password" -- admin-record' "$t/leaky/tools/install/nyra-install.sh" || fail "the leaky copy is not leaky"
run leaky install
[ "$rc" = 0 ] && grep -qF -e "$admin_pw" "$CALLS" || fail "the control of the search for the password: a leak was not found"
echo "control: a password given to the container as an argument is found by the search"
: > "$ENVLOG"
: > "$PROCLOG"
answers /dev/vda /dev/vda tpm

# --- the wait for Enter after the recovery key ---------------------------------------------------
# The key is on the screen until the user presses Enter, and only an Enter pressed after it goes on:
# nothing later runs and the handoff does not end before. At the end of the input the script stops,
# with the screen cleared. Enters typed before the prompt are thrown away.
# waits WHAT: the last run is still at the prompt, killed by the timeout; the key was shown.
waits() {
  [ "$rc" = 124 ] || { cat "$t/transcript"; fail "$1: the installer went on (status $rc)"; }
  tr -d '\r' < "$t/transcript" | grep -qF "$key" || fail "$1: the key was not shown"
  tr -d '\r' < "$t/transcript" | grep -qF 'Press Enter when you have written it down: ' || fail "$1: no prompt"
  ! grep -qF handoff-end <<< "$events" || fail "$1: the handoff ended"
  ! called 'in-image.sh tpm-enroll' || fail "$1: the TPM was enrolled before Enter"
}
answers /dev/vda /dev/vda tpm
replies='[]' run_timeout=8 run ok install
waits "no Enter"
echo "recovery key: without Enter the installer stays at the prompt, the handoff open, nothing after it"
answers /dev/vda /dev/vda tpm
replies='[]' pretype=3 run_timeout=8 run ok install
waits "Enters typed before the prompt"
echo "recovery key: Enters typed before the prompt do not skip it"
answers /dev/vda /dev/vda tpm
pretype=3 run ok install
[ "$rc" = 0 ] && [ "$events" = "$install_events" ] || fail "Enters typed before the prompt and one after: status $rc"
cleared_after_key || fail "Enters typed before the prompt: the screen was not cleared after the key"
echo "recovery key: an Enter after the prompt goes on, whatever was typed before it"
answers /dev/vda /dev/vda tpm
replies='[["Press Enter when you have written it down: $", null]]' run ok install
[ "$rc" = 11 ] && [ "$(tail -n 1 <<< "$events")" = '{"event":"fail","id":"protect","disk_changed":true}' ] \
  || fail "the end of the input at the prompt: status $rc, $events"
! grep -qF handoff-end <<< "$events" && ! called 'in-image.sh tpm-enroll' || fail "the end of the input: the installer went on"
cleared_after_key || fail "the end of the input: the screen was not cleared"
echo "recovery key: the end of the input at the prompt is a failure, nothing after it, the screen cleared"
# The wording is right for a disk with a password too.
answers /dev/vda /dev/vda password
LUKS_JSON="$t/luks-password.json" run notpm install
tr -d '\r' < "$t/transcript" | grep -qF 'only way in if you forget the password.' || fail "the text for a password disk"
answers /dev/vda /dev/vda tpm
run ok install
tr -d '\r' < "$t/transcript" | grep -qF 'only way in if the TPM refuses the disk.' || fail "the text for a TPM disk"
echo "recovery key: the text says why, for a TPM and for a password"
# The same wait for Enter after the one-time password: it stays on the screen until Enter, only an Enter
# pressed after it goes on (not Enters typed at the recovery key's prompt), and the end of the input is a
# failure of the Secure Boot step with the screen cleared.
key_reply="[\"$key_prompt\", \"\"]"
answers /dev/vda /dev/vda tpm
replies="[$key_reply]" run_timeout=8 run ok install
[ "$rc" = 124 ] && [ "$(mok_shown | wc -l)" = 1 ] && called '^mokutil --import ' || { cat "$t/transcript"; fail "no Enter after the one-time password: status $rc"; }
[ "$(tail -n 1 <<< "$events")" = '{"event":"handoff","id":"mok-password"}' ] || fail "no Enter after the one-time password: the handoff ended"
echo "one-time password: without Enter the installer stays at the prompt, the handoff open"
answers /dev/vda /dev/vda tpm
replies="[[\"$key_prompt\", \"\\n\\n\\n\"]]" run_timeout=8 run ok install
[ "$rc" = 124 ] && [ "$(mok_shown | wc -l)" = 1 ] && called 'in-image.sh esp-sync' || { cat "$t/transcript"; fail "Enters typed before the one-time password skipped its prompt: status $rc"; }
! grep -qxF '{"event":"done"}' <<< "$events" || fail "Enters typed before the one-time password: the installer went on"
echo "one-time password: Enters typed before the prompt do not skip it"
answers /dev/vda /dev/vda tpm
replies="[$key_reply, [\"$mok_prompt\", null]]" run ok install
[ "$rc" = 11 ] && [ "$(tail -n 1 <<< "$events")" = '{"event":"fail","id":"mok","disk_changed":true}' ] || fail "the end of the input at the one-time password: status $rc, $events"
mokpw="$(mok_shown)"
cleared_after "${mokpw:0:5}-${mokpw:5}" || fail "the end of the input: the screen was not cleared after the one-time password"
[ -z "$(mok_leaks "$mokpw")" ] || fail "the one-time password is in a file after a stop at its prompt"
echo "one-time password: the end of the input at the prompt is a failure of the Secure Boot step, the screen cleared"
answers /dev/vda /dev/vda tpm
# The terminal mode: the same, from the confirmation of the disk to the end.
tree cli
set_line "$t/cli/tools/install/nyra-install.sh" '  [ -b "$device" ] || die "$device is not a block device"' '  true'
cli_run() { # cli_run: the whole terminal mode on a terminal; sets rc and transcript
  reset_run
  CLI_MODE=1 REPLIES="${replies:-$cli_replies}" PRETYPE="${pretype:-0}" TIMEOUT="${run_timeout:-60}" python3 -I tools/install/pty-run.py "$t/transcript" \
    "$t/cli/tools/install/nyra-install.sh" /dev/vda "$version" "$digest" && rc=0 || rc=$?
}
cli_replies='[["Type its path to go on: $", "/dev/vda"], ["Press Enter [^\n]*: $", ""]]'
fresh_disk
cli_run
[ "$rc" = 0 ] || { cat "$t/transcript"; fail "the terminal mode failed ($rc)"; }
called 'in-image.sh tpm-enroll' && called '^mokutil --import ' || fail "the terminal mode did not finish"
cleared_after_key || fail "the terminal mode: the screen and its scroll-back were not cleared after the recovery key"
text="$(tr -d '\r' < "$t/transcript")"
[[ "${text#*"$key"}" != *"$key"* ]] || fail "the terminal mode: the key is shown twice"
echo "terminal mode: the key is shown, Enter goes on, the screen and its scroll-back are cleared"
[ "$(mok_shown | wc -l)" = 1 ] && cleared_after "$(mok_shown | sed 's/^\(.....\)/\1-/')" || fail "the terminal mode: the one-time password was not shown once and cleared"
echo "terminal mode: the one-time password is shown once and cleared after Enter"
# Three Enters typed with the answer to the confirmation wait for the prompt, as type-ahead does.
cli_replies='[["Type its path to go on: $", "/dev/vda\n\n\n"]]'
run_timeout=8 cli_run
[ "$rc" = 124 ] && ! called 'in-image.sh tpm-enroll' || fail "the terminal mode: went on without an Enter after the key ($rc)"
echo "terminal mode: Enters typed before the prompt do not skip it"
cli_replies='[["Type its path to go on: $", "/dev/vda"], ["Press Enter when you have written it down: $", null]]'
cli_run
[ "$rc" != 0 ] && ! called 'in-image.sh tpm-enroll' || fail "the terminal mode: the end of the input did not stop it ($rc)"
cleared_after_key || fail "the terminal mode: after the end of the input the screen was not cleared"
echo "terminal mode: the end of the input at the prompt stops it with the screen cleared"
answers /dev/vda /dev/vda tpm

# --- install with a password, on a machine without a TPM ----------------------------------------------
# The disk opens with the password from the answers: no TPM is needed (this is the notpm tree), Secure Boot is.
# The steps of the password, not those of the TPM; the password is a file of the secrets that password-add
# reads and the script deletes, and is nowhere else.
answers /dev/vda /dev/vda password
fresh_disk
before="$(disk_hash)"
rm -f "$PW_SEEN"
LUKS_JSON="$t/luks-password.json" run notpm install
[ "$rc" = 0 ] || { printf '%s\n' "$events"; cat "$t/transcript" "$t/log/install.log"; fail "install with a password failed ($rc)"; }
[ "$events" = "$install_events" ] || { printf '%s\n' "$events"; fail "the events of an installation with a password are not those of the text installer"; }
[ "$(disk_hash)" != "$before" ] || fail "the stand-in disk was not written to"
for s in admin-record password-memory format password-add install-system recovery-show wipe-install-slot esp-sync; do
  called "/nyra-install/in-image.sh $s" || fail "the step $s did not run (password)"
done
! called 'in-image.sh tpm-enroll' && ! called 'in-image.sh wipe-install-key' || fail "a step of the TPM ran for a disk with a password"
line() { grep -n -- "$1" "$CALLS" | head -n 1 | cut -d: -f1; }
[ "$(line 'in-image.sh password-memory')" -lt "$(line '^sfdisk')" ] || fail "the memory of the key derivation was asked after the disk was written to"
[ "$(line 'in-image.sh format')" -lt "$(line 'in-image.sh password-add')" ] && [ "$(line 'in-image.sh password-add')" -lt "$(line 'in-image.sh install-system')" ] \
  || fail "password-add is not between format and install-system"
[ "$(line 'in-image.sh install-system')" -lt "$(line 'in-image.sh wipe-install-slot')" ] || fail "the key of the installation was wiped before the system was installed"
# install-system gets no "tpm": the empty word between the key and the reference.
grep -q 'in-image.sh install-system /dev/vda /secrets/install-key  updates.nyraos.com/nyra-base:' "$CALLS" || fail "install-system was told to enroll a TPM for a disk with a password"
[ "$(cat "$PW_SEEN")" = "600 $DISK_PW_SHA" ] || fail "password-add did not read the password as a 0600 file (got: $(cat "$PW_SEEN" 2> /dev/null))"
[ ! -e "$t/secrets" ] || fail "the keys of the installation, the password file included, are still there"
tr -d '\r' < "$t/transcript" | grep -qF "RECOVERY-KEY: $key" || fail "the recovery key was not shown on the terminal (password)"
! tr -d '\r' < "$t/transcript" | grep -qF -e "$disk_pw" || fail "the disk password was shown on the terminal"
! grep -F -e "$disk_pw" "$CALLS" "$ENVLOG" "$PROCLOG" "$t/events" "$t/log/install.log" > /dev/null || fail "the disk password is in an argument, the environment, ps, an event or the log"
no_secrets_anywhere
echo "install with a password: no TPM needed, the steps of the password in order, the password only as a 0600 file that is deleted, in no argument, environment, ps, event, log or terminal"
# The control: a copy that writes the password to the log is found by the search.
tree leaky_pw
sed -i 's|^  a_disk_password=""$|  echo "$a_disk_password" >\&"$logfd"; a_disk_password=""|' "$t/leaky_pw/tools/install/nyra-install.sh"
grep -qF 'echo "$a_disk_password" >&"$logfd"' "$t/leaky_pw/tools/install/nyra-install.sh" || fail "the leaky copy for the disk password is not leaky"
LUKS_JSON="$t/luks-password.json" run leaky_pw install
grep -qF -e "$disk_pw" "$t/log/install.log" || fail "the control of the search for the disk password: the leak was not there"
no_secrets_anywhere_quiet || fail "the control of the search for the disk password: a leak was not found"
echo "control: a disk password written to the log is found by the search"
: > "$ENVLOG"
: > "$PROCLOG"
answers /dev/vda /dev/vda tpm

# --- install, refused: nothing is written ------------------------------------------------------------
refuse() { # refuse MESSAGE [ID]: with the answers and the machine as set, the installation is refused
  local hash
  hash="$(disk_hash)"
  run "${tree:-ok}" install
  refused_install "$@"
  untouched "$hash"
  no_secrets_anywhere
}
tree=ok
answers /dev/vda /dev/vdb tpm
refuse "not confirmed"
answers /dev/vda /dev/vda1 tpm
refuse "not confirmed"
answers /dev/vda "/dev/VDA" tpm
refuse "not confirmed"
answers /dev/nothing /dev/nothing tpm
refuse "/dev/nothing is not a whole disk of this machine"
answers /dev/vda1 /dev/vda1 tpm
refuse "/dev/vda1 is not a whole disk of this machine"
export FIXTURE="$t/disks.json"
for pair in sdb:booted sdc:in_use sdd:read_only sde:too_small sdf:in_use; do
  answers "/dev/${pair%%:*}" "/dev/${pair%%:*}" tpm
  refuse "/dev/${pair%%:*} cannot be installed on: ${pair##*:}"
done
answers /dev/sda /dev/nvme0n1 tpm
refuse "not confirmed"
export FIXTURE="$t/one-disk.json"
# A password disk on a machine that cannot derive the key with 256 MiB: refused before anything is written.
answers /dev/vda /dev/vda password
hash="$(disk_hash)"
PWMEM_RC=3 run notpm install
refused_install "this machine cannot derive a disk key from a password with at least 256 MiB of memory"
untouched_but_podman "$hash"
! called 'in-image.sh format' || fail "a disk was formatted although the key derivation is too cheap"
no_secrets_anywhere
# Secure Boot is needed for a password too, on a machine that has no TPM.
tree=notpm
printf '%s\n' 'SecureBoot disabled' > "$t/sb-state"
refuse "Secure Boot must be on and not in setup mode"
printf '%s\n' 'SecureBoot enabled' > "$t/sb-state"
tree=ok
answers /dev/vda /dev/vda tpm
echo 'MemTotal:        4194304 kB' > "$t/meminfo"
refuse "this machine has 4.0 GiB of memory; the installer needs 6 GiB" memory
echo 'MemTotal:        8388608 kB' > "$t/meminfo"
printf '%s\n' 'SecureBoot disabled' > "$t/sb-state"
refuse "Secure Boot must be on and not in setup mode"
printf '%s\n%s\n' 'SecureBoot enabled' 'SecureBoot validation is disabled in shim' > "$t/sb-state"
refuse "shim validation is off (MokSBState)"
printf '%s\n' 'SecureBoot enabled' > "$t/sb-state"
rmdir "$t/efi"
refuse "not booted in UEFI mode"
mkdir "$t/efi"
tree=notpm
refuse "needs exactly one TPM2"
tree=ok
printf 'maria\n' > "$t/ok/reserved-names"
refuse "the administrator name is a name of the system"
rm "$t/ok/reserved-names"
# The pull refuses the image: nothing was changed, and the pull is where it stopped.
hash="$(disk_hash)"
PULL_FAILS=1 run ok install
refused_install "" verify
called '^verified-pull ' && ! called '^sfdisk' || fail "the pull is refused: the disk is not to be touched"
[ "$(disk_hash)" = "$hash" ] || fail "the disk was written to after a refused pull"
echo "install: a refused pull stops before the disk"
# The disk is in use by the time the image is pulled: looked at again before the first write.
answers /dev/vda /dev/vda tpm
hash="$(disk_hash)"
cp "$t/one-disk.json" "$t/one-disk.good"
PULL_MOUNTS=1 run ok install
refused_install "/dev/vda cannot be installed on: in_use"
called '^verified-pull ' && ! called '^sfdisk' || fail "a disk that was mounted during the pull was written to"
[ "$(disk_hash)" = "$hash" ] || fail "the disk was written to after being mounted"
cp "$t/one-disk.good" "$t/one-disk.json"
# Another disk (another model and size) has the name by the time the image is pulled.
PULL_SWAPS=1 run ok install
refused_install "/dev/vda is not the disk that was chosen: it changed"
called '^verified-pull ' && ! called '^sfdisk' || fail "a disk that was swapped during the pull was written to"
[ "$(disk_hash)" = "$hash" ] || fail "another disk was written to"
cp "$t/one-disk.good" "$t/one-disk.json"
echo "install: the disk is looked at again after the pull, and must be the same one"
# Answers that are not what protocol 1 says. The log says so and holds none of what was sent.
bad_answers() { # bad_answers NAME JQ_EDIT: the good answers, changed
  answers /dev/vda /dev/vda tpm
  { head -n 1 "$t/answers.in" | jq -c "$2"; printf 'go\ngo\n'; } > "$t/answers.bad"
  mv "$t/answers.bad" "$t/answers.in"
  refuse "the answers are not the answers of protocol 1"
  echo "  ($1)"
}
bad_answers "an unknown field" '. + {extra: 1}'
bad_answers "no confirmation" 'del(.confirm)'
bad_answers "a password for the disk with the TPM" '. + {disk_password: "Another-password-1"}'
bad_answers "no password for the disk with a password" '.unlock = "password"'
bad_answers "a short disk password" '.unlock = "password" | .disk_password = "short"'
bad_answers "an empty disk password" '.unlock = "password" | .disk_password = ""'
bad_answers "a long disk password" '.unlock = "password" | .disk_password = ("a" * 65)'
bad_answers "a newline in a disk password" '.unlock = "password" | .disk_password = "Sentinel-disk-pw\n-4711"'
bad_answers "a disk password that is not ASCII" '.unlock = "password" | .disk_password = "Sentinel-pässword-4711"'
bad_answers "a number for a disk password" '.unlock = "password" | .disk_password = 123456789012'
bad_answers "unlock by something else" '.unlock = "pin"'
bad_answers "a short administrator password" '.admin_password = "short"'
bad_answers "a long administrator password" '.admin_password = ("a" * 65)'
bad_answers "a password equal to the name" '.admin_name = "password-is-name1" | .admin_password = "password-is-name1"'
bad_answers "a character that is not ASCII" '.admin_password = "Sentinel-pässword-4711"'
bad_answers "a newline in a password" '.admin_password = "Sentinel-admin-pw\n-4711"'
bad_answers "a device that is not a path" '.device = "vda" | .confirm = "vda"'
bad_answers "a device with a newline" '.device = "/dev/vda\n" | .confirm = "/dev/vda\n"'
bad_answers "the name root" '.admin_name = "root"'
bad_answers "an uppercase name" '.admin_name = "Maria"'
bad_answers "a name with a newline" '.admin_name = "maria\n"'
bad_answers "a number for a password" '.admin_password = 123456789012'
# The line as text: what jq alone would take, and the protocol does not.
raw_answers() { # raw_answers NAME TEXT [MESSAGE]
  printf '%s\ngo\ngo\n' "$2" > "$t/answers.in"
  refuse "${3:-the answers are not the answers of protocol 1}"
  echo "  ($1)"
}
answers /dev/vda /dev/vda tpm
good="$(head -n 1 "$t/answers.in")"
raw_answers "a value before the object" "1 $good"
raw_answers "a string before the object" "\"x\" $good"
raw_answers "the object twice" "$good $good"
raw_answers "an empty object after" "$good {}"
raw_answers "garbage after" "${good}x"
raw_answers "a brace after" "$good}"
raw_answers "a key twice, the last one right" "{\"device\":\"/dev/nothing\",${good#\{}"
raw_answers "a key twice, the first one right" "${good%\}},\"confirm\":\"/dev/nothing\"}"
raw_answers "an array" "[$good]"
raw_answers "a device that is too long" "${good/\/dev\/vda/\/dev\/$(printf 'v%.0s' $(seq 40))}"
raw_answers "a line of more than 4096 characters" "${good%\}}$(printf ' %.0s' $(seq 4200))}" "the answers are longer than 4096 characters"
echo '{"device":' > "$t/answers.in"
refuse "the answers are not the answers of protocol 1"
: > "$t/answers.in"
refuse "no answers"
echo "  (JSON that does not end, and no line)"

# --- install, failing on the way ----------------------------------------------------------------------
answers /dev/vda /dev/vda tpm
failing() { # failing STEP ID MESSAGE: a step of the image fails after the disk is changed
  local hash
  fresh_disk
  hash="$(disk_hash)"
  FAIL_STEP="$1" run ok install
  [ "$rc" = 11 ] || { printf '%s\n' "$events"; fail "status $rc, not 11 ($1)"; }
  [ "$(tail -n 1 <<< "$events")" = "{\"event\":\"fail\",\"id\":\"$2\",\"disk_changed\":true}" ] \
    || { printf '%s\n' "$events"; fail "the event fail of $1 is not $2 with a change"; }
  [ "$(grep -c '"disk-changed"' <<< "$events")" = 1 ] || fail "disk-changed not exactly once ($1)"
  [ "$(disk_hash)" != "$hash" ] || fail "the disk was not changed ($1)"
  [ ! -e "$t/secrets" ] || fail "the key of the installation survived ($1)"
  if [ "$2" != mok ]; then
    # The disk is not finished: the volume is closed, and the log says it must be installed again.
    grep -qF "failed after /dev/vda was changed" "$t/log/install.log" || fail "the log does not say the disk was changed ($1)"
    called 'close-root' || fail "the volume was not closed ($1)"
  fi
  no_secrets_anywhere
  echo "a failure of $1 is $2, with a change, status 11"
}
# The record of the administrator is asked for before the disk is touched: a failure there changes nothing.
hash="$(disk_hash)"
FAIL_STEP=admin-record run ok install
refused_install "cannot make the record of the administrator maria"
untouched_but_podman "$hash"
! called '^sfdisk' && ! called 'install-system' || fail "a failed record did not stop the installation before the disk"
no_secrets_anywhere
echo "a failure of admin-record is verify, without a change, status 10"
failing format write
failing install-system write
failing tpm-enroll protect
failing wipe-install-key protect
failing esp-sync protect
# The same for a disk with a password: the steps of the password fail after the disk is changed (a password that
# password-add refuses, the key of the installation that cannot be wiped, a header that is not the one expected).
answers /dev/vda /dev/vda password
failing_password() { # failing_password NAME ID: a step fails with a password disk
  local hash
  fresh_disk
  hash="$(disk_hash)"
  LUKS_JSON="${LUKS:-$t/luks-password.json}" run notpm install
  [ "$rc" = 11 ] || { printf '%s\n' "$events"; fail "status $rc, not 11 ($1)"; }
  [ "$(tail -n 1 <<< "$events")" = "{\"event\":\"fail\",\"id\":\"$2\",\"disk_changed\":true}" ] || { printf '%s\n' "$events"; fail "the event fail of $1 is not $2 with a change"; }
  [ ! -e "$t/secrets" ] || fail "the keys, the password file included, survived ($1)"
  called 'close-root' || fail "the volume was not closed ($1)"
  no_secrets_anywhere
  echo "a failure of $1 (password) is $2, with a change, status 11"
}
PWADD_RC=4 failing_password password-add write
FAIL_STEP=password-add failing_password "password-add (a stand-in that fails)" write
FAIL_STEP=wipe-install-slot failing_password wipe-install-slot protect
LUKS="$t/luks.json" failing_password "a TPM header on a disk with a password" protect
grep -qF 'the LUKS header is not the recovery key and one password slot' "$t/log/install.log" || fail "the log does not say what is wrong with the header"
# A second password slot is refused too.
jq -c '.keyslots["3"] = .keyslots["1"]' "$t/luks-password.json" > "$t/luks-two.json"
LUKS="$t/luks-two.json" failing_password "a second password slot" protect
answers /dev/vda /dev/vda tpm
# The header is not as it must be: a second TPM2 enrollment.
cp "$t/luks.json" "$t/luks.good"
jq -c '.tokens["2"] = .tokens["1"] | .keyslots["3"] = {}' "$t/luks.good" > "$t/luks.json"
failing none protect
cp "$t/luks.good" "$t/luks.json"
IMPORT_RC=1 failing none mok
[ -z "$(mok_shown)" ] || fail "a one-time password was shown although mokutil failed to import"
# The key of the image is not the tree's.
echo "not a certificate" > "$t/image.crt"
failing none mok
cp "$t/ok/files/usr/lib/nyra/secureboot/nyra.crt" "$t/image.crt"
# No go: the terminal is not handed over, and the key is not shown.
printf '%s\n' "$(head -n 1 "$t/answers.in")" > "$t/answers.nogo"
cp "$t/answers.nogo" "$t/answers.in"
run ok install
[ "$rc" = 11 ] && [ "$(tail -n 1 <<< "$events")" = '{"event":"fail","id":"protect","disk_changed":true}' ] || fail "no go: status $rc, $events"
! tr -d '\r' < "$t/transcript" | grep -qF "$key" || fail "the recovery key was shown without go"
! called 'recovery-show' || fail "the recovery key was made before go"
grep -qF 'the answers ended before the handoff' "$t/log/install.log" || fail "no go: the log does not say"
echo "a handoff without go: no key on the terminal"
answers /dev/vda /dev/vda tpm
printf '%s\n' "$(head -n 1 "$t/answers.in")" 'stop' > "$t/answers.nogo"
cp "$t/answers.nogo" "$t/answers.in"
run ok install
[ "$rc" = 11 ] && ! called 'recovery-show' || fail "something else than go: status $rc"
echo "a handoff with something else than go: no key on the terminal"

# --- before the first write: the terminal, the list of names, the log -----------------------------------
# No terminal to hand the key over to: found before anything is written, not at the handoff.
answers /dev/vda /dev/vda tpm
reset_run
hash="$(disk_hash)"
setsid -w "$t/ok/tools/install/nyra-install.sh" install --events-fd 3 --answers-fd 4 3> "$t/events" 4< "$t/answers" \
  > /dev/null 2>&1 < /dev/null && rc=0 || rc=$?
events="$(cat "$t/events")"
refused_install "there is no terminal to hand over"
untouched "$hash"
echo "install: no terminal is found before the disk is touched"
# A list of names that cannot be read is not an empty list.
mkdir "$t/ok/reserved-names"
sh_ok ok check
[ "$rc" = 1 ] && [ -z "$out" ] && grep -qF 'reserved-names is not a regular file' <<< "$err" || fail "check with a directory as the list of names: $rc $out $err"
run ok install
refused_install "reserved-names is not a regular file"
rmdir "$t/ok/reserved-names"
printf 'maria\r\n' > "$t/ok/reserved-names"
sh_ok ok check
[ "$(jq -c .reserved <<< "$out")" = '["maria\r"]' ] || fail "check reads the names of the system differently: $out"
run ok install
[ "$rc" = 0 ] || fail "install reads the names of the system differently from check ($rc)"
rm "$t/ok/reserved-names"
echo "the list of names: unreadable is fatal, and check and install read the lines the same way"
# A log that was there already is made private.
PRELOG=1 run ok install
[ "$rc" = 0 ] && [ "$(stat -c %a "$t/log/install.log")" = 600 ] || fail "an old log is not private ($(stat -c %a "$t/log/install.log"))"
echo "the log is private even if it was there before"

# --- mok-import --------------------------------------------------------------------------------------
# No answers: the only line it reads is go.
printf 'go\n' > "$t/answers.in"
run ok mok-import
[ "$rc" = 0 ] || { printf '%s\n' "$events"; fail "mok-import failed ($rc)"; }
[ "$events" = '{"event":"handoff","id":"mok-password"}
{"event":"handoff-end"}
{"event":"done"}' ] || { printf '%s\n' "$events"; fail "mok-import: the events"; }
called '^mokutil --import ' && ! called '^podman' && ! called '^verified-pull' && ! called '^sfdisk' || fail "mok-import did more or less than the import"
tr -d '\r' < "$t/transcript" | grep -qF "$fingerprint" || fail "mok-import: the fingerprint was not shown"
echo "mok-import: the handoff, the import, nothing else"
# A new password every time, shown once, with its hash given to mokutil and nowhere else.
[ "$(mok_shown | wc -l)" = 1 ] || fail "mok-import: the one-time password was not shown exactly once"
mokpw="$(mok_shown)"
read -r _ hash < "$MOK_SEEN"
[ "$(printf '%s\n' "$mokpw" | openssl passwd -6 -stdin -salt "$(cut -d'$' -f3 <<< "$hash")")" = "$hash" ] || fail "mok-import: the hash is not the one of the password that was shown"
[ -z "$(mok_leaks "$mokpw")" ] || fail "mok-import: the one-time password is in a file, an event or the log"
run ok mok-import
[ "$rc" = 0 ] && [ "$(mok_shown | wc -l)" = 1 ] && [ "$(mok_shown)" != "$mokpw" ] || fail "mok-import run again: the password is not new"
echo "mok-import: the one-time password is new each time, shown once, its hash given to mokutil, nowhere else"
# A run that stopped before the password was written down leaves the request queued with a password
# nobody knows. Trying again must revoke it and queue the key again with a new password, say so, and show
# it: not "already requested" with nothing to type in MokManager.
answers /dev/vda /dev/vda tpm
replies="[$key_reply, [\"$mok_prompt\", null]]" run ok install
[ "$rc" = 11 ] && [ -e "$MOK_QUEUED" ] || fail "the stop at the one-time password's prompt left no queued request: status $rc"
lost="$(mok_shown)"
printf 'go\n' > "$t/answers.in"
keep_queue=1 run ok mok-import
[ "$rc" = 0 ] || { cat "$t/transcript"; fail "mok-import after a lost password failed ($rc)"; }
called '^mokutil --revoke-import' && called '^mokutil --import ' || fail "mok-import after a lost password did not revoke and queue the key again"
[ "$(line '^mokutil --revoke-import')" -lt "$(line '^mokutil --import ')" ] || fail "the import came before the revoke"
[ "$(mok_shown | wc -l)" = 1 ] && [ "$(mok_shown)" != "$lost" ] && [[ "$(mok_shown)" =~ ^[a-km-np-z2-9]{10}$ ]] || fail "no new one-time password after a lost one"
mokpw="$(mok_shown)"
tr -d '\r' < "$t/transcript" | grep -qF 'An earlier request to register this key was replaced: only the password below works now.' || fail "the screen does not say that the earlier request was replaced"
read -r _ hash < "$MOK_SEEN"
[ "$(printf '%s\n' "$mokpw" | openssl passwd -6 -stdin -salt "$(cut -d'$' -f3 <<< "$hash")")" = "$hash" ] || fail "after a lost password: the hash is not the one of the new password"
[ -e "$MOK_QUEUED" ] || fail "the key is not queued again"
[ -z "$(mok_leaks "$lost")" ] && [ -z "$(mok_leaks "$mokpw")" ] || fail "a one-time password is in a file after a retry"
echo "mok-import: a request left by a run that stopped is revoked and made again with a new password, which is shown, and the screen says so"
TESTKEY_RC=1 run ok mok-import
[ "$rc" = 0 ] && ! called '^mokutil --import ' && [ -z "$(mok_shown)" ] || fail "mok-import of a key already enrolled: $rc"
tr -d '\r' < "$t/transcript" | grep -qF 'already enrolled' || fail "mok-import of a key already enrolled: the screen does not say so"
IMPORT_RC=1 run ok mok-import
[ "$rc" = 10 ] && [ "$(tail -n 1 <<< "$events")" = '{"event":"fail","id":"mok","disk_changed":false}' ] || fail "mok-import that fails: $rc $events"
[ -z "$(mok_shown)" ] || fail "mok-import that fails showed a one-time password"
TESTKEY_RC=2 run ok mok-import
[ "$rc" = 10 ] && [ "$(tail -n 1 <<< "$events")" = '{"event":"fail","id":"mok","disk_changed":false}' ] || fail "mok-import, mokutil --test-key fails: $rc $events"
run badfp mok-import
[ "$rc" = 10 ] && ! grep -q handoff <<< "$events" && ! called '^mokutil --import' || fail "mok-import with another fingerprint: $rc $events"
echo "mok-import: already enrolled is no failure; a failure is mok, without a change, status 10; another fingerprint stops before the handoff"

# --- the descriptors ---------------------------------------------------------------------------------
for args in "install" "install --events-fd 3" "install --events-fd 3 --answers-fd 3" "install --events-fd 2 --answers-fd 4" \
  "install --events-fd 3 --answers-fd 9" "install --events-fd x --answers-fd 4" "install --answers-fd 4 --events-fd 3" \
  "install --events-fd 5 --answers-fd 6" "disks extra"; do
  reset_run
  # shellcheck disable=SC2086 # the words are the point
  "$t/ok/tools/install/nyra-install.sh" $args 3> "$t/events" 4< "$t/answers" > "$t/out" 2> "$t/err" < /dev/null && rc=0 || rc=$?
  [ "$rc" = 1 ] || fail "'$args' was not refused as usage (status $rc)"
done
echo "the descriptors: anything but two different open ones from 3 to 8 is a usage error"
untouched "$(disk_hash)"

# --- the terminal mode is what it was ----------------------------------------------------------------
cli() { # cli TREE: the terminal mode on a terminal, with the arguments of today
  reset_run
  python3 -I tools/install/pty-run.py "$t/transcript" "$t/$1/tools/install/nyra-install.sh" /dev/vda "$version" "$digest" \
    && rc=0 || rc=$?
  out="$(tr -d '\r' < "$t/transcript")"
}
cli notpm
[ "$rc" = 1 ] && grep -qF 'nyra-install: needs exactly one TPM2 (/dev/tpmrm0); a machine without one is not installed by this script' <<< "$out" \
  || fail "the terminal mode, no TPM: $rc $out"
printf '%s\n' 'SecureBoot disabled' > "$t/sb-state"
cli ok
[ "$rc" = 1 ] && grep -qF 'nyra-install: Secure Boot must be on and not in setup mode: SecureBoot disabled' <<< "$out" || fail "the terminal mode, no Secure Boot: $rc $out"
printf '%s\n%s\n' 'SecureBoot enabled' 'SecureBoot validation is disabled in shim' > "$t/sb-state"
cli ok
[ "$rc" = 1 ] && grep -qF 'nyra-install: shim validation is off (MokSBState)' <<< "$out" || fail "the terminal mode, shim: $rc $out"
: > "$t/sb-state"
cli ok
[ "$rc" = 1 ] && grep -qF 'nyra-install: cannot read the Secure Boot state: not booted in UEFI mode?' <<< "$out" || fail "the terminal mode, no state: $rc $out"
printf '%s\n' 'SecureBoot enabled' > "$t/sb-state"
cli ok
# A device that is no block device: the terminal mode checks the device itself, not through lsblk.
[ "$rc" = 1 ] && grep -qF 'nyra-install: /dev/vda is not a block device' <<< "$out" || fail "the terminal mode, a device: $rc $out"
! called '^sfdisk' || fail "the terminal mode wrote"
echo "the terminal mode refuses what it refused: no TPM, no Secure Boot, the shim, the state, a device that is no disk"
echo "ok"
