#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154 # facts and limits: read by nyra-install.sh; die, checkout, answers_fd, ...: set there
# Sourced by tools/install/nyra-install.sh: what it learns about the machine, and the parts of the
# machine interface (docs/INSTALL-INTERFACE.md) that are not the installation itself: the facts and the
# disks as JSON, the answers, and the handoff of the terminal.

# Where the facts come from, and the limits. Assigned here and never taken from the environment.
protocol=1
min_memory_gib=6 # what the installer needs; the live system keeps the image in RAM
min_disk_gb=32
efi_dir=/sys/firmware/efi
meminfo=/proc/meminfo
tpm_glob='/dev/tpmrm*'
tpm_dev=/dev/tpmrm0
log_dir=/run/nyra-installer
# The certificate and the fingerprint of the people who make the releases, from the tree.
cert_file="files/usr/lib/nyra/secureboot/nyra.crt"

# --- the machine ---------------------------------------------------------------------------------

# machine_facts: sets uefi, sb_read, secure_boot, shim_checks, tpm, virt (true or false), sb_state
# (what mokutil said) and mem_tenths (the memory in tenths of a GiB: 80 is 8.0 GiB).
machine_facts() {
  local tpms key value mem_kb=""
  if [ -d "$efi_dir" ]; then uefi=true; else uefi=false; fi
  sb_read=false secure_boot=false shim_checks=false
  if sb_state="$(mokutil --sb-state 2>&1)"; then
    sb_read=true
    # Not in setup mode: a machine in setup mode accepts any key.
    if grep -qx 'SecureBoot enabled' <<< "$sb_state" && ! grep -qi 'setup mode' <<< "$sb_state"; then
      secure_boot=true
    fi
    # MokSBState: with it set, shim loads anything, signed or not.
    if ! grep -qi 'validation is disabled' <<< "$sb_state"; then shim_checks=true; fi
  fi
  # shellcheck disable=SC2206 # the glob is the point: how many TPM devices there are
  tpms=($tpm_glob)
  if [ "${#tpms[@]}" = 1 ] && [ "${tpms[0]}" = "$tpm_dev" ] && [ -c "$tpm_dev" ]; then tpm=true; else tpm=false; fi
  if systemd-detect-virt --vm -q; then virt=true; else virt=false; fi
  while read -r key value _; do
    if [ "$key" = "MemTotal:" ]; then
      mem_kb="$value"
      break
    fi
  done < "$meminfo"
  [[ "$mem_kb" =~ ^[0-9]+$ ]] || die "cannot read the memory from $meminfo"
  mem_tenths=$((mem_kb * 10 / 1048576))
}

# require_tpm, require_secure_boot: the refusals of the machine (after machine_facts).
require_tpm() {
  [ "$tpm" = true ] \
    || die "needs exactly one TPM2 (/dev/tpmrm0); a machine without one is not installed by this script"
}
require_secure_boot() {
  [ "$sb_read" = true ] || die "cannot read the Secure Boot state: not booted in UEFI mode?"
  [ "$secure_boot" = true ] || die "Secure Boot must be on and not in setup mode: $sb_state"
  [ "$shim_checks" = true ] || die "shim validation is off (MokSBState): $sb_state"
}

# signing_fingerprint: the one SHA-256 fingerprint of docs/SIGNING.md.
signing_fingerprint() {
  local expected
  expected="$(grep -Eo '([0-9A-F]{2}:){31}[0-9A-F]{2}' "$checkout/docs/SIGNING.md")"
  [ "$(wc -l <<< "$expected")" = 1 ] || die "docs/SIGNING.md does not hold exactly one SHA-256 fingerprint"
  echo "$expected"
}

# mok_fingerprint CERT: sets fingerprint (all 32 bytes), and dies unless it is the one of docs/SIGNING.md.
mok_fingerprint() {
  local expected
  fingerprint="$(openssl x509 -noout -fingerprint -sha256 -in "$1")" || die "cannot read the certificate"
  fingerprint="${fingerprint#*=}"
  expected="$(signing_fingerprint)"
  [ "$fingerprint" = "$expected" ] \
    || die "the certificate has the fingerprint $fingerprint, not the one of docs/SIGNING.md: $expected; do not import it"
}

# reserved_names: the names the system uses, as a JSON array, from the file reserved-names at the root
# of the tree, one per line. No file is an empty list; a file that cannot be read is fatal. check
# prints this list and install checks the administrator against it: one reading for both.
reserved_names() {
  local file="$checkout/reserved-names"
  [ -e "$file" ] || [ -L "$file" ] || { echo '[]'; return 0; }
  [ -f "$file" ] && [ ! -L "$file" ] || die "reserved-names is not a regular file"
  jq -Rn '[inputs | select(length > 0)]' < "$file" || die "cannot read reserved-names"
}

# --- the JSON of check and disks -----------------------------------------------------------------

# check_json: the machine and the release, as one JSON object (docs/INSTALL-INTERFACE.md). Needs
# machine_facts and tree_identify.
check_json() {
  local cert="$checkout/$cert_file" signer cert_name reserved
  mok_fingerprint "$cert"
  signer="$(jq -er '[.. | .subjectEmail? // empty] | if length == 1 then .[0] else empty end' \
    "$checkout/files/usr/lib/nyra/containers/policy.json")" || die "the policy does not name exactly one signer"
  cert_name="$(openssl x509 -noout -subject -nameopt multiline -in "$cert" | sed -n 's/^ *commonName *= //p')"
  [ -n "$cert_name" ] || die "the certificate has no common name"
  reserved="$(reserved_names)"
  jq -n --argjson protocol "$protocol" --arg arch "$(uname -m)" \
    --argjson uefi "$uefi" --argjson secure_boot "$secure_boot" --argjson shim_checks "$shim_checks" \
    --argjson tpm "$tpm" --argjson mem_tenths "$mem_tenths" --argjson mem_need_gib "$min_memory_gib" \
    --argjson virt "$virt" --arg version "$version" --arg commit "$tree_commit" --arg digest "$digest" \
    --arg signer "$signer" --arg cert_name "$cert_name" --arg fingerprint "$fingerprint" \
    --argjson reserved "$reserved" '{
      protocol: $protocol, arch: $arch, uefi: $uefi, secure_boot: $secure_boot, shim_checks: $shim_checks,
      tpm: $tpm, mem_tenths: $mem_tenths, mem_need_gib: $mem_need_gib, virt: $virt,
      release: {version: $version, commit: $commit, digest: $digest, signer: $signer,
                cert_name: $cert_name, fingerprint: $fingerprint},
      reserved: $reserved}'
}

# disks_json: the whole disks of this machine as a JSON array, each with eligible and, if it is not,
# the reason: booted (an ISO image is on it), in_use (something is mounted or swapped), read_only,
# too_small (with min_gb). The first reason in that order. A disk is a block device of type disk;
# loop devices, optical drives and zram do not appear. serial, wwn and ptuuid (the GUID of the
# partition table) say which disk it is, for chosen_disk. Used by install too: the same answer twice.
disks_json() {
  lsblk -J -b -o NAME,PATH,TYPE,SIZE,MODEL,SERIAL,WWN,PTUUID,RO,RM,FSTYPE,LABEL,PARTTYPE,MOUNTPOINTS \
    | jq --argjson min "$min_disk_gb" '
      def yes: . == true or . == 1 or . == "1";
      def nodes: ., (.children[]? | nodes);
      ["e3c9e316-0b5c-4db8-817d-f92df00215ae", "ebd0a0a2-b9e5-4433-87c0-68b6b72699c7"] as $microsoft
      | [.blockdevices[] | select(.type == "disk" and (.name | startswith("zram") | not))
        | . as $d
        | [$d | nodes] as $all
        | (if any($all[]; .fstype == "iso9660" or ((.label // "") | startswith("NYRA-ISO"))) then "booted"
           elif any($all[]; [(.mountpoints // [])[] | select(. != null)] | length > 0) then "in_use"
           elif ($d.ro | yes) then "read_only"
           elif ($d.size | tonumber) < $min * 1000000000 then "too_small"
           else null end) as $reason
        | {name: $d.name, path: $d.path, bytes: ($d.size | tonumber),
           model: (($d.model // "") | gsub("^\\s+|\\s+$"; "")), serial: ($d.serial // null),
           wwn: ($d.wwn // null), ptuuid: ($d.ptuuid // null), removable: ($d.rm | yes),
           parts: [($d.children // [])[] | select(.type == "part")
             | {label: (.label // ""), fs: (.fstype // ""), bytes: (.size | tonumber),
                microsoft: ((.parttype // "") | ascii_downcase | IN($microsoft[]))}],
           eligible: ($reason == null), reason: $reason}
          + (if $reason == "too_small" then {min_gb: $min} else {} end)]' \
    || die "cannot list the disks"
}

# --- the events and the answers (install, mok-import) --------------------------------------------

# emit JSON: one event, one line, on the events descriptor. A reader that went away is not a reason to
# stop in the middle of a write to the disk.
emit() {
  [ -z "$events_fd" ] || printf '%s\n' "$1" >&"$events_fd" || true
}

# step ID: a step of the installation starts. A failure while it runs is reported with the id of
# the failure that goes with it (fail_id): the machine, the answers and the image are verify; the
# partitions and the image are write.
step() {
  case "$1" in
    verify) fail_id="verify" ;;
    prepare | install) fail_id="write" ;;
    protect) fail_id="protect" ;;
    final) fail_id="mok" ;;
  esac
  emit "{\"event\":\"step\",\"id\":\"$1\",\"state\":\"start\"}"
}
# step_end ID: the step is done.
step_end() {
  emit "{\"event\":\"step\",\"id\":\"$1\",\"state\":\"done\"}"
}

# read_answers: the one line of answers from the answers descriptor, at most 4096 characters, parsed
# once. One jq run reads the line as a stream and gives the verdict and the fields together: exactly
# one JSON value, an object with exactly the fields of the protocol, none twice (jq itself keeps the
# last of a repeated key and judges only the last of several values), strings that match their
# patterns. The passwords are checked too (12 to 64 printable ASCII characters). The result is put in
# a_device, a_confirm, a_unlock and a_admin_name; nothing uses the passwords yet, so they are not
# kept. The line is never an argument, never in the environment, never in the log; jq's own errors,
# which can quote a value, go nowhere. \A and \z: in jq's regular expressions $ also matches before a
# final newline.
read_answers() {
  local line out fields
  IFS= read -r -n 4097 -u "$answers_fd" line || die "no answers"
  [ "${#line}" -le 4096 ] || die "the answers are longer than 4096 characters"
  out="$(printf '%s' "$line" | jq -nr --stream '
    def text($re): type == "string" and test($re);
    [inputs] as $events
    | [fromstream($events[])] as $values
    | $values[0] as $a
    | ((["admin_name", "admin_password", "confirm", "device", "unlock"]
        + (if $a.unlock == "password" then ["disk_password"] else [] end)) | sort) as $keys
    | if ($values | length) == 1 and ($a | type) == "object"
        # The leaves at depth 1 are the fields as written: a key twice is one field more than the object has.
        and ([$events[] | select(length == 2 and (.[0] | length) == 1)] | length) == ($a | length)
        and ($a | keys) == $keys
        and ($a.unlock == "tpm" or $a.unlock == "password")
        and ($a.device | text("\\A/dev/[A-Za-z0-9._-]{1,32}\\z"))
        and ($a.confirm | text("\\A/dev/[A-Za-z0-9._-]{1,32}\\z"))
        and ($a.admin_name | text("\\A[a-z][a-z0-9_-]{0,31}\\z")) and $a.admin_name != "root"
        and ($a.admin_password | text("\\A[ -~]{12,64}\\z"))
        and (if $a.unlock == "password" then ($a.disk_password | text("\\A[ -~]{12,64}\\z")) else true end)
      then "ok", $a.device, $a.confirm, $a.unlock, $a.admin_name
      else "no" end' 2> /dev/null)" || out=no
  line=""
  mapfile -t fields <<< "$out"
  [ "${fields[0]:-}" = ok ] && [ "${#fields[@]}" = 5 ] || die "the answers are not the answers of protocol $protocol"
  a_device="${fields[1]}" a_confirm="${fields[2]}" a_unlock="${fields[3]}" a_admin_name="${fields[4]}"
}

# chosen_disk: dies unless a_device is a whole disk of this machine that can be installed on, and the
# owner typed its path (a_confirm) to say so. The first time, the whole entry of the disk is kept
# (disk_entry); every later time it must be identical, so that it is still the disk the owner was shown,
# not another one that took its name. Nothing has been written yet.
chosen_disk() {
  local disk reason
  disk="$(disks_json | jq -c --arg path "$a_device" '.[] | select(.path == $path)')"
  [ -n "$disk" ] || die "$a_device is not a whole disk of this machine"
  reason="$(jq -r '.reason // empty' <<< "$disk")"
  [ -z "$reason" ] || die "$a_device cannot be installed on: $reason"
  [ "$a_confirm" = "$a_device" ] || die "not confirmed"
  if [ -z "$disk_entry" ]; then
    disk_entry="$disk"
  elif [ "$disk" != "$disk_entry" ]; then
    die "$a_device is not the disk that was chosen: it changed"
  fi
}

# tty_ready: dies unless /dev/tty can be opened and this process is in the foreground process group
# of that terminal, which the handoffs need. Looked at before the first write, not at the handoff.
tty_ready() {
  local stat
  { : < /dev/tty > /dev/tty; } 2> /dev/null || die "there is no terminal to hand over"
  stat="$(< /proc/self/stat)"
  # After the name of the command: state, parent, process group, session, terminal, foreground group.
  # shellcheck disable=SC2086 # the fields are numbers and letters
  set -- ${stat##*) }
  [ "$3" = "$6" ] || die "this process is not in the foreground process group of the terminal"
}

# --- the terminal --------------------------------------------------------------------------------

# handoff ID COMMAND...: runs COMMAND on the terminal, which the installer lets go of for the time of
# it, and nowhere else. The recovery key is shown and the one-time password of mokutil is typed there:
# neither passes through a pipe of this script or through its log. Waits for the line go.
handoff() {
  local id="$1" line
  shift
  tty_ready
  emit "{\"event\":\"handoff\",\"id\":\"$id\"}"
  IFS= read -r -u "$answers_fd" line || die "the answers ended before the handoff"
  [ "$line" = go ] || die "expected go to start the handoff"
  handoff_open=1
  "$@" < /dev/tty > /dev/tty 2>&1
  # What was shown, the scroll-back included, goes.
  printf '\033[H\033[2J\033[3J' > /dev/tty
  handoff_open=""
  emit '{"event":"handoff-end"}'
}
