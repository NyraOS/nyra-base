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
#   - the recovery key and the password of mokutil go to the terminal after the line go, and to no event,
#     log or file; no password is in an argument, in the environment, in ps or anywhere under the work
#     directory; the terminal mode refuses what it always refused.
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
  *"-nro TYPE"*) printf 'disk\npart\npart\n' ;;
esac
EOF2
cat > "$t/bin/mokutil" << 'EOF2'
#!/bin/sh
echo "mokutil $*" >> "$CALLS"
case "$1" in
  --sb-state) cat "$SB_STATE"; [ -s "$SB_STATE" ] ;;
  --test-key) exit "${TESTKEY_RC:-0}" ;;
  --import) exit "${IMPORT_RC:-0}" ;;
esac
EOF2
# Writes to the disk: its first KiB. What the process that called it holds is recorded, to look for passwords.
cat > "$t/bin/sfdisk" << 'EOF2'
#!/bin/sh
echo "sfdisk $*" >> "$CALLS"
cat > /dev/null
{ tr '\0' ' ' < "/proc/$PPID/cmdline"; echo; tr '\0' '\n' < "/proc/$PPID/environ"; ps -eww -o args=; } >> "$PROCLOG"
dd if=/dev/zero of="$DISKFILE" bs=1k count=1 conv=notrunc status=none
EOF2
cat > "$t/bin/podman" << 'EOF2'
#!/bin/bash
echo "podman $*" >> "$CALLS"
env >> "$ENVLOG"
ps -eww -o args= >> "$PROCLOG"
args=("$@")
step=""
for i in "${!args[@]}"; do
  [ "${args[$i]}" = /nyra-install/in-image.sh ] && step="${args[$((i + 1))]}"
done
if [ -z "$step" ]; then
  cat "$IMAGE_CERT"
  exit 0
fi
[ "$step" != "$FAIL_STEP" ] || exit 1
case "$step" in
  recovery-show) echo "RECOVERY-KEY: $(cat "$KEYFILE")" ;;
  recovery-check)
    printf 'Enter passphrase for the key slot: '
    read -r got
    [ "$got" = "$(cat "$KEYFILE")" ]
    ;;
  luks-json) cat "$LUKS_JSON" ;;
esac
EOF2
chmod +x "$t/bin/"*
cat > "$t/luks.json" << 'EOF2'
{"tokens":{"0":{"type":"systemd-recovery","keyslots":["1"]},"1":{"type":"systemd-tpm2","keyslots":["2"],"tpm2-pcrs":[]}},
 "keyslots":{"1":{},"2":{}}}
EOF2
# The disks, as lsblk -J -b prints them.
cat > "$t/disks.json" << 'EOF2'
{"blockdevices": [
 {"name":"loop0","path":"/dev/loop0","type":"loop","size":100000,"model":null,"ro":true,"rm":false,"fstype":null,"label":null,"parttype":null,"mountpoints":["/snap/x"]},
 {"name":"sr0","path":"/dev/sr0","type":"rom","size":1000000000,"model":"DVD","ro":false,"rm":true,"fstype":null,"label":null,"parttype":null,"mountpoints":[]},
 {"name":"sda","path":"/dev/sda","type":"disk","size":500107862016,"model":"Samsung SSD 870 EVO","ro":false,"rm":false,"fstype":null,"label":null,"parttype":null,"mountpoints":[],
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

printf '%s' "$key" > "$t/key.txt"
export CALLS="$t/calls.log" ENVLOG="$t/env.log" PROCLOG="$t/proc.log" DISKFILE="$t/disk" KEYFILE="$t/key.txt"
export SB_STATE="$t/sb-state" LUKS_JSON="$t/luks.json" FIXTURE="$t/one-disk.json" IMAGE_CERT="$t/image.crt"
: > "$CALLS"
: > "$ENVLOG"
: > "$PROCLOG"

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
  : > "$t/events"
  : > "$CALLS"
  : > "$t/transcript"
  cp "$t/answers.in" "$t/answers"
}
# run TREE SUBCOMMAND: on a terminal, events on descriptor 3 and answers on 4. Sets rc, events, transcript.
# The shell around the script is the text installer: it keeps the terminal open (the script itself uses it
# only for the handoffs) and gives the script its status.
run() {
  local tree="$1"
  shift
  reset_run
  ANSWER="$key" TIMEOUT=60 python3 -I tools/install/pty-run.py "$t/transcript" \
    bash -c '"$@"; exit $?' _ "$t/$tree/tools/install/nyra-install.sh" "$@" --events-fd 3 --answers-fd 4 \
    3> "$t/events" 4< "$t/answers" && rc=0 || rc=$?
  events="$(cat "$t/events")"
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
  .[0] == {name: "sda", path: "/dev/sda", bytes: 500107862016, model: "Samsung SSD 870 EVO", removable: false,
           eligible: true, reason: null, parts: [
    {label: "", fs: "vfat", bytes: 272629760, microsoft: false},
    {label: "", fs: "", bytes: 16777216, microsoft: true},
    {label: "Windows (C:)", fs: "ntfs", bytes: 499000000000, microsoft: true}]}
  and .[1].model == "WD \"Black\" SN850" and .[1].parts == []
  and .[2].removable == true and .[2].parts == [{label: "NYRA-ISO", fs: "iso9660", bytes: 30000000000, microsoft: false}]' \
  <<< "$out" > /dev/null || { printf '%s\n' "$out"; fail "disks: a disk is not as the text installer reads it"; }
echo "disks: eligible or not and why, the partitions, quotes in a model, no loop device or optical drive"

# --- install, the whole way --------------------------------------------------------------------------
answers /dev/vda /dev/vda tpm
before="$(disk_hash)"
run ok install
[ "$rc" = 0 ] || { printf '%s\n' "$events"; cat "$t/transcript" "$t/log/install.log"; fail "install failed ($rc)"; }
[ "$events" = "$install_events" ] || { printf '%s\n' "$events"; fail "the events of an installation are not in the order of the text installer"; }
[ "$(disk_hash)" != "$before" ] || fail "the stand-in disk was not written to: the test would not see a write"
called '^verified-pull ' || fail "no pull"
[ "$(grep -c '^sfdisk' "$CALLS")" = 1 ] || fail "sfdisk did not run exactly once"
for s in format install-system recovery-show recovery-check tpm-enroll wipe-install-key esp-sync; do
  called "/nyra-install/in-image.sh $s" || fail "the step $s did not run"
done
called '^mokutil --import ' || fail "no import of the key"
[ ! -e "$t/secrets" ] || fail "the key of the installation is still there"
tr -d '\r' < "$t/transcript" | grep -qF "RECOVERY-KEY: $key" || fail "the recovery key was not shown on the terminal"
tr -d '\r' < "$t/transcript" | grep -qF "$fingerprint" || fail "the fingerprint was not shown on the terminal"
echo "install: the events in order, the disk written, the key and the fingerprint on the terminal"
# What must not hold the recovery key or a password.
if grep -rlF "$key" "$t" --exclude=transcript --exclude=key.txt --exclude=answers.in --exclude=answers --exclude=test-*.sh 2> /dev/null | grep .; then
  fail "the recovery key is in a file, event or log (the files above)"
fi
grep -qF 'nyra-install: done' "$t/log/install.log" || fail "the log does not end the installation"
[ "$(stat -c %a "$t/log/install.log")" = 600 ] || fail "the log is not 0600"
no_secrets_anywhere
echo "install: the recovery key is in no file, event or log; no password is in an argument, the environment, ps or the log"

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
answers /dev/vda /dev/vda password
refuse "unlocking the disk with a password is not supported yet"
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
echo "install: the disk is looked at again after the pull"
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
bad_answers "unlock by something else" '.unlock = "pin"'
bad_answers "a short administrator password" '.admin_password = "short"'
bad_answers "a long administrator password" '.admin_password = ("a" * 65)'
bad_answers "a character that is not ASCII" '.admin_password = "Sentinel-pässword-4711"'
bad_answers "a newline in a password" '.admin_password = "Sentinel-admin-pw\n-4711"'
bad_answers "a device that is not a path" '.device = "vda" | .confirm = "vda"'
bad_answers "a device with a newline" '.device = "/dev/vda\n" | .confirm = "/dev/vda\n"'
bad_answers "the name root" '.admin_name = "root"'
bad_answers "an uppercase name" '.admin_name = "Maria"'
bad_answers "a name with a newline" '.admin_name = "maria\n"'
bad_answers "a number for a password" '.admin_password = 123456789012'
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
failing format write
failing install-system write
failing tpm-enroll protect
failing wipe-install-key protect
failing esp-sync protect
# The header is not as it must be: a second TPM2 enrollment.
cp "$t/luks.json" "$t/luks.good"
jq -c '.tokens["2"] = .tokens["1"] | .keyslots["3"] = {}' "$t/luks.good" > "$t/luks.json"
failing none protect
cp "$t/luks.good" "$t/luks.json"
IMPORT_RC=1 failing none mok
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
TESTKEY_RC=1 run ok mok-import
[ "$rc" = 0 ] && ! called '^mokutil --import ' || fail "mok-import of a key already enrolled: $rc"
IMPORT_RC=1 run ok mok-import
[ "$rc" = 10 ] && [ "$(tail -n 1 <<< "$events")" = '{"event":"fail","id":"mok","disk_changed":false}' ] || fail "mok-import that fails: $rc $events"
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
