#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Offline test of /usr/lib/nyra/boot/tpm-enroll, tpm-retire and tpm-pin (docs/BOOT.md, "Disk
# encryption"), without a VM, a TPM or a disk. The real scripts, unchanged, run in a mount namespace,
# chrooted into a directory where the paths they use are stand-ins (/dev/gpt-auto-root-luks,
# /dev/tpmrm0, the Secure Boot variables, PCR 12, /.extra, /sysroot, /var, /run) and /usr is the
# host's (through an overlay: what a case adds there, such as the image's list of retired keys, is
# never written to the host), with stand-ins for cryptsetup, systemd-cryptenroll, keyctl and systemd-ask-password first on
# PATH that keep the key slots in a file and log what they are asked to do. Policy keys are stand-in
# PEM files: A signed the booted UKI, B is the next.
#   a. a symbolic link on the path of the enrollments' record (inside the root's /var, which belongs
#      to the running system) stops tpm-enroll: nothing is written outside that /var, on the first
#      boot as after a refusal, and no key slot is removed;
#   b. after a refusal, the key slot that the typed key opens (here the recovery key's) is never
#      removed, even when the record lists it; the other listed slot is, and the disk is enrolled for
#      A and B again;
#   c. a boot that unlocked with the TPM on a disk enrolled only for A, with B as the image's next key
#      (the release after a rotation): B is enrolled, nothing removed; on a disk with a PIN, with the
#      PIN typed in this boot (the last one in the cache), and not at all without it;
#   d. after a refusal, on a version whose key (C) was retired: not enrolled again, nothing removed;
#   e. tpm-retire, on a version signed with B whose next key is C: the enrollment of A is removed and A
#      recorded as retired (also with a PIN); and nothing at all when the record has no enrollment for B;
#      on a fallback to A (next key B) confirmed good, the newer enrollment for C stays;
#   f. a PIN asked for from the running system (tpm-pin): a new one on a disk without, none on a disk
#      with one (unlocked with the PIN typed in this boot), another one (systemd-cryptenroll replaces
#      the old enrollments itself, and no slot that is gone is removed); the request is removed, the
#      PIN leaves /run and the cache;
#   g. after a refusal on a disk with a PIN: the user chooses a new one (a wrong one first), the disk is
#      enrolled with it, never without a PIN; without a choice, nothing changes;
#   h. tpm-pin: only 6 to 20 digits, a request only root can read, and only on a disk with a record;
#   i. a run cut off between removing slots and writing the record (a power cut): tpm-retire and the
#      re-enrollment leave out the slots that are gone; and when the record cannot be written (a full
#      /var), tpm-retire removes nothing;
#   j. the image's list of retired keys: such a key is never enrolled again (after a refusal) or as
#      the next key, and tpm-retire removes its enrollment and marks it retired (also a key never
#      enrolled); old enrollments are removed only from slots the header has as TPM2 enrollments,
#      never the recovery key's or another kind of key's, even when the record lists them.
# Checks a, b, d, e, f, g, i (but the full /var), j and the PIN of c are proven: the same case run on a copy of the script
# without the check it relies on must fail. The namespace: unshare -rm (a user namespace) where
# allowed, else sudo unshare -m; NYRA_TEST_NS=1 is refused outside a namespace of its own.
#   tools/vm/test-tpm-enroll.sh
set -euo pipefail

if [ "${NYRA_TEST_NS:-}" != 1 ]; then
  self="$(readlink -f "$0")"
  if unshare -rm sh -c 'd="$(mktemp -d)" && mount -t tmpfs t "$d" && umount "$d" && rmdir "$d"' 2>/dev/null; then
    exec unshare -rm env NYRA_TEST_NS=1 "$self"
  fi
  exec sudo -n unshare -m env NYRA_TEST_NS=1 "$self"
fi
# Only in a mount namespace of its own (one that differs from the parent's): mounts and removals
# below must never reach the host's.
[ "$(readlink /proc/self/ns/mnt)" != "$(readlink "/proc/$PPID/ns/mnt" 2>/dev/null || echo unknown)" ] ||
  { echo "test-tpm-enroll: NYRA_TEST_NS=1 outside a mount namespace of its own" >&2; exit 1; }
mount --make-rprivate /
boot="$(dirname "$0")/../../files/usr/lib/nyra/boot"
t="$(readlink -f "$(mktemp -d)")"
# Every root has the host's /usr (an overlay) and /dev/null bound in: unmount them before anything is
# removed, and never remove across file systems.
cleanup() {
  grep -o " $t/[^ ]*" /proc/self/mounts | sort -r | while read -r m; do umount -l "$m"; done
  rm -rf --one-file-system "$t"
}
trap cleanup EXIT
mkdir "$t/bin"

# Stand-ins (copied to /stubs in each root). State in /state of the root ($T): slots, header.json,
# recovery-key, cache (the typed key), pincache (the typed PINs), answers (to PIN prompts); log: calls.
cat > "$t/bin/cryptsetup" <<'EOF'
#!/bin/bash
case "$1" in
  luksDump) cat "$T/header.json" ;;
  open) # open --test-passphrase -v --key-file=- DEV: the recovery key opens slot 1
    [ "$(cat)" = "$(cat "$T/recovery-key")" ] && echo "Key slot 1 unlocked." >&2 ;;
  status) echo "  device:  /dev/vda2" ;;
  *) exit 1 ;;
esac
EOF
cat > "$t/bin/systemd-cryptenroll" <<'EOF'
#!/bin/bash
# Slots: "N tpm2 [KEY [PIN]]" or "N TYPE". Unlocking with the TPM needs an enrollment of the booted
# UKI's key (or one without a key: the temporary one) whose PIN, if any, is the credential's; with a
# PIN, an enrollment of the same key with a PIN is replaced (as systemd-cryptenroll does for the same
# policy); removing a slot that is not there fails.
key="$(printf '%s\n' "$@" | sed -n 's/^--tpm2-public-key=//p')"
case "$*" in
  *--tpm2-device*)
    n=$(( $(sort -n "$T/slots" | tail -1 | cut -d' ' -f1) + 1 ))
    k="$(cat "$key")" line="enroll $(cat "$key")" mark=""
    case "$*" in *--tpm2-with-pin=yes*) line+=" pin=$NEWPIN"; mark=" $NEWPIN" ;; esac
    case "$*" in *--unlock-tpm2-device*)
      c="${CREDENTIALS_DIRECTORY:-/none}/cryptenroll.tpm2-pin" pin=""
      [ ! -f "$c" ] || { pin="$(cat "$c")"; line+=" unlock-pin=$pin"; }
      cur="$(cat /.extra/tpm2-pcr-public-key.pem)"
      grep -Eqx "[0-9]+ tpm2( $cur)?|[0-9]+ tpm2 $cur ${pin:-none}" "$T/slots" ||
        { echo "$line: not unlocked" >> "$T/calls"; exit 1; } ;;
    esac
    case "$*" in *--wipe-slot=tpm2*) line+=", wipe tpm2" ;; esac
    echo "$line" >> "$T/calls"
    [ -z "$mark" ] || sed -i -E "/^[0-9]+ tpm2 $k [0-9]+\$/d" "$T/slots"
    echo "$n tpm2 $k$mark" >> "$T/slots" ;;
  --wipe-slot=*)
    w="${1#--wipe-slot=}"; echo "wipe $w" >> "$T/calls"
    # Removing a slot that is not there fails, as with systemd-cryptenroll.
    for n in ${w//,/ }; do grep -q "^$n " "$T/slots" || exit 1; sed -i "/^$n /d" "$T/slots"; done ;;
  *) echo "SLOT TYPE"; sed 's/^/   /' "$T/slots" ;;
esac
EOF
cat > "$t/bin/keyctl" <<'EOF'
#!/bin/bash
# The typed key ("cryptsetup", 77) and PINs ("tpm2-pin", 78), NUL-separated.
f() { if [ "$1" = 78 ] || [ "$1" = tpm2-pin ]; then echo "$T/pincache"; else echo "$T/cache"; fi; }
case "$1" in
  search) [ -e "$(f "$4")" ] && { [ "$4" = tpm2-pin ] && echo 78 || echo 77; } ;;
  pipe) cat "$(f "$2")" ;;
  invalidate) rm -f "$(f "$2")"; if [ "$2" = 78 ]; then echo "invalidate pin"; else echo "invalidate"; fi >> "$T/calls" ;;
esac
EOF
cat > "$t/bin/systemd-ask-password" <<'EOF'
#!/bin/bash
# The answers, one per line, in order; none left: no answer (the prompt's timeout).
[ -s "$T/answers" ] || exit 1
sed -n 1p "$T/answers"; sed -i 1d "$T/answers"; echo "ask" >> "$T/calls"
EOF
chmod +x "$t/bin"/*
fp() { printf '%s\n' "$1" | sha256sum | cut -c1-64; } # a stand-in key's identity, as tpm-enroll computes it

setup() { # setup DIR CASE(first|typed|tpm) [CURRENT_KEY]: a root with Secure Boot on, a TPM, a clean
  # PCR 12, the booted UKI's key (A unless given) and the image's next key B
  local d="$1"
  mkdir -p "$d/root/dev" "$d/root/sys/firmware/efi/efivars" "$d/root/sys/class/tpm/tpm0/pcr-sha256" \
    "$d/root/.extra" "$d/root/sysroot/var" "$d/root/sysroot/usr/lib/nyra/secureboot" "$d/root/var/lib/nyra" \
    "$d/root/run" "$d/root/outside" "$d/root/usr" "$d/root/stubs" "$d/root/state" "$d/root/tmp"
  for l in bin lib lib64 sbin; do ln -s "usr/$l" "$d/root/$l"; done
  mkdir -p "$d/usr-upper" "$d/usr-work"
  mount -t overlay overlay -o "lowerdir=/usr,upperdir=$d/usr-upper,workdir=$d/usr-work" "$d/root/usr"
  : > "$d/root/dev/null" && mount --bind /dev/null "$d/root/dev/null"
  cp "$t/bin"/* "$d/root/stubs/"
  : > "$d/root/dev/gpt-auto-root-luks"
  : > "$d/root/dev/tpmrm0"
  printf '\x06\x00\x00\x00\x01' > "$d/root/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
  printf '\x06\x00\x00\x00\x00' > "$d/root/sys/firmware/efi/efivars/SetupMode-8be4df61-93ca-11d2-aa0d-00e098032b8c"
  echo 3345A4E7857AA5AE65E97702ADE84A3755FD6144724779536B5773128676C99C > "$d/root/sys/class/tpm/tpm0/pcr-sha256/12"
  echo "${3:-KEY-A}" > "$d/root/.extra/tpm2-pcr-public-key.pem"
  echo KEY-B > "$d/root/sysroot/usr/lib/nyra/secureboot/tpm2-pcr-public-key-next.pem"
  local st="$d/root/state"
  printf 'cbdefghi-jklnrtuv' > "$st/recovery-key"
  : > "$st/calls"
  printf '0 tpm2\n1 recovery\n' > "$st/slots"
  if [ "$2" = first ]; then
    printf '{"tokens":{"0":{"type":"systemd-tpm2","tpm2-policy-hash": "%064d"}}}\n' 0 > "$st/header.json"
  else
    printf '{"tokens":{"0":{"type":"systemd-tpm2","tpm2-policy-hash": "%s"}}}\n' "$(printf 'ab%.0s' $(seq 32))" > "$st/header.json"
  fi
  [ "$2" != typed ] || printf '%s\0' "$(cat "$st/recovery-key")" > "$st/cache" # the user typed the recovery key
}
run() { # run SCRIPT DIR [ARG...]: the script at /script in DIR's root, with only the stand-ins' PATH
  # and DIR/stdin (if any) as its input
  local d="$2"
  cp "$1" "$d/root/script"
  shift 2
  [ -f "$d/stdin" ] || : > "$d/stdin"
  chroot "$d/root" /usr/bin/env -i PATH=/stubs:/usr/bin:/usr/sbin T=/state /bin/sh /script "$@" \
    < "$d/stdin" > "$d/out" 2>&1 || true
}
record=sysroot/var/lib/nyra/tpm2-slots

# a. A symbolic link on the record's path: var/lib points outside the root's /var.
case_link() { # case_link SCRIPT first|typed: "ok" or what went wrong
  local d
  d="$(mktemp -d -p "$t")"
  setup "$d" "$2"
  local st="$d/root/state" out="$d/root/outside"
  mkdir -p "$out/nyra"
  [ "$2" = first ] || printf '0 %s\n' "$(fp KEY-A)" > "$out/nyra/tpm2-slots"
  ln -s /outside "$d/root/sysroot/var/lib"
  local before
  before="$(find "$out" -type f -exec md5sum {} + | sort)"
  run "$1" "$d"
  if [ "$(find "$out" -type f -exec md5sum {} + | sort)" != "$before" ]; then echo "written outside the root's /var"; return; fi
  if grep -q '^wipe' "$st/calls"; then echo "a key slot removed: $(grep '^wipe' "$st/calls")"; return; fi
  if [ "$2" = typed ] && grep -q '^enroll' "$st/calls"; then echo "enrolled again through a link"; return; fi
  [ "$2" = first ] || grep -q "^invalidate" "$st/calls" || { echo "the typed key left in the cache"; return; }
  echo ok
}
# b. The record lists the recovery key's slot (1), which the typed key opens, and the old TPM slot (0).
case_slot() { # case_slot SCRIPT: "ok" or what went wrong
  local d
  d="$(mktemp -d -p "$t")"
  setup "$d" typed
  local st="$d/root/state"
  mkdir -p "$d/root/sysroot/var/lib/nyra"
  # Slot 3 is another kind of key (a record left behind lists it): never removed either.
  # The header says slot 1 is a TPM2 enrollment too (tokens are not authenticated).
  printf '0 tpm2\n1 tpm2\n3 fido2\n' > "$st/slots"
  printf '0 %s\n1 %s\n3 %s\n' "$(fp KEY-A)" "$(fp KEY-X)" "$(fp KEY-Y)" > "$d/root/$record"
  run "$1" "$d"
  if grep -q '^wipe.*3' "$st/calls"; then echo "a slot that is not a TPM2 enrollment removed: $(grep '^wipe' "$st/calls")"; return; fi
  if grep -q '^wipe.*1' "$st/calls"; then echo "the typed key's slot removed: $(grep '^wipe' "$st/calls")"; return; fi
  grep -qx 'wipe 0' "$st/calls" || { echo "the old TPM slot not removed: $(cat "$st/calls") $(cat "$d/out")"; return; }
  grep -qx 'enroll KEY-A' "$st/calls" && grep -qx 'enroll KEY-B' "$st/calls" ||
    { echo "not enrolled again for A and B: $(cat "$st/calls") $(cat "$d/out")"; return; }
  [ "$(grep -c '^[0-9]' "$d/root/$record")" = 2 ] || { echo "the record is not the two new slots: $(cat "$d/root/$record")"; return; }
  echo ok
}
# c. Unlocked by the TPM (nothing typed), enrolled only for A; the image's next key is B.
case_next() { # case_next SCRIPT [listed]: with "listed", the image lists B as retired
  local d
  d="$(mktemp -d -p "$t")"
  setup "$d" tpm
  local st="$d/root/state"
  mkdir -p "$d/root/sysroot/var/lib/nyra"
  printf '0 %s\n' "$(fp KEY-A)" > "$d/root/$record"
  if [ "${2:-}" = listed ]; then
    fp KEY-B > "$d/root/sysroot/usr/lib/nyra/secureboot/tpm2-pcr-retired-keys"
    run "$1" "$d"
    grep -q '^\(wipe\|enroll\)' "$st/calls" && { echo "a key the image lists as retired enrolled: $(cat "$st/calls")"; return; }
    echo ok
    return
  fi
  run "$1" "$d"
  grep -q '^wipe' "$st/calls" && { echo "a key slot removed: $(cat "$st/calls")"; return; }
  [ "$(cat "$st/calls")" = "enroll KEY-B" ] || { echo "B not enrolled alone: $(cat "$st/calls") $(cat "$d/out")"; return; }
  [ "$(cat "$d/root/$record")" = "0 $(fp KEY-A)
2 $(fp KEY-B)" ] || { echo "the record: $(cat "$d/root/$record")"; return; }
  [ "$(cat "$d/root/run/nyra-tpm2-keep")" = "$(fp KEY-A)
$(fp KEY-B)" ] || { echo "the keys kept: $(cat "$d/root/run/nyra-tpm2-keep")"; return; }
  echo ok
}
# b, after a boot cut off before it wrote the record: the record lists slot 2, which is gone.
case_stale() { # case_stale SCRIPT
  local d
  d="$(mktemp -d -p "$t")"
  setup "$d" typed
  local st="$d/root/state"
  mkdir -p "$d/root/sysroot/var/lib/nyra"
  printf '0 %s\n2 %s\n' "$(fp KEY-A)" "$(fp KEY-B)" > "$d/root/$record"
  run "$1" "$d"
  [ "$(grep '^wipe' "$st/calls")" = "wipe 0" ] || { echo "removed: $(cat "$st/calls") $(cat "$d/out")"; return; }
  grep -qx 'enroll KEY-A' "$st/calls" && grep -qx 'enroll KEY-B' "$st/calls" ||
    { echo "not enrolled again: $(cat "$st/calls") $(cat "$d/out")"; return; }
  echo ok
}
# c, with a PIN: the disk enrolled for A with a PIN; two PINs typed in this boot, the second right.
case_next_pin() { # case_next_pin SCRIPT with-cache|without-cache
  local d
  d="$(mktemp -d -p "$t")"
  setup "$d" tpm
  local st="$d/root/state"
  mkdir -p "$d/root/sysroot/var/lib/nyra"
  printf '0 tpm2 KEY-A 2468013579\n1 recovery\n' > "$st/slots"
  printf '0 %s pin\n' "$(fp KEY-A)" > "$d/root/$record"
  [ "$2" = without-cache ] || printf '11111111\0002468013579\0' > "$st/pincache"
  run "$1" "$d"
  if [ "$2" = without-cache ]; then
    grep -q '^\(wipe\|enroll\)' "$st/calls" && { echo "enrolled without the PIN: $(cat "$st/calls")"; return; }
    echo ok
    return
  fi
  grep -qx 'enroll KEY-B pin=2468013579 unlock-pin=2468013579' "$st/calls" ||
    { echo "B not enrolled with the typed PIN: $(cat "$st/calls") $(cat "$d/out")"; return; }
  [ "$(cat "$d/root/$record")" = "0 $(fp KEY-A) pin
2 $(fp KEY-B) pin" ] || { echo "the record: $(cat "$d/root/$record")"; return; }
  [ ! -e "$d/root/run/nyra-tpm-pin" ] || { echo "the PIN left in /run"; return; }
  grep -qx 'invalidate pin' "$st/calls" || { echo "the PIN left in the cache"; return; }
  echo ok
}
# d. A refusal on a version signed with C, which the record says was retired.
case_retired() { # case_retired SCRIPT [listed]: with "listed", the image's list says so, not the record
  local d
  d="$(mktemp -d -p "$t")"
  setup "$d" typed KEY-C
  local st="$d/root/state"
  mkdir -p "$d/root/sysroot/var/lib/nyra"
  if [ "${2:-}" = listed ]; then
    printf '0 %s\n' "$(fp KEY-B)" > "$d/root/$record"
    printf '# retired\n%s\n' "$(fp KEY-C)" > "$d/root/sysroot/usr/lib/nyra/secureboot/tpm2-pcr-retired-keys"
  else
    printf '0 %s\nretired %s\n' "$(fp KEY-B)" "$(fp KEY-C)" > "$d/root/$record"
  fi
  run "$1" "$d"
  grep -q '^\(wipe\|enroll\)' "$st/calls" && { echo "enrolled again for a retired key: $(cat "$st/calls")"; return; }
  echo ok
}
# e. tpm-retire on a version signed with B, whose next key is C, and the record of A, B and C; or on
#    version A (next B) after a fallback.
case_retire() { # case_retire SCRIPT with-B|with-B-pin|without-B|fallback|interrupted|full|listed|not-tpm2
  local d
  d="$(mktemp -d -p "$t")"
  setup "$d" tpm
  local st="$d/root/state" r="$d/root/var/lib/nyra/tpm2-slots"
  printf '%s\n%s\n' "$(fp KEY-B)" "$(fp KEY-C)" > "$d/root/run/nyra-tpm2-keep"
  if [ "$2" = interrupted ] || [ "$2" = full ]; then
    printf '0 %s\n1 %s\n2 %s\n' "$(fp KEY-A)" "$(fp KEY-B)" "$(fp KEY-C)" > "$r"
    if [ "$2" = interrupted ]; then
      # A's slot (0) already removed by a run cut off before it wrote the record.
      printf '1 tpm2\n2 tpm2\n3 recovery\n' > "$st/slots"
    else
      mkdir "$r.new" # the new record cannot be written (as on a full /var)
    fi
    local before
    before="$(cat "$r")"
    run "$1" "$d"
    grep -q '^wipe' "$st/calls" && { echo "removed: $(cat "$st/calls") $(cat "$d/out")"; return; }
    if [ "$2" = full ]; then
      [ "$(cat "$r")" = "$before" ] || { echo "the record changed: $(cat "$r")"; return; }
    else
      [ "$(cat "$r")" = "1 $(fp KEY-B)
2 $(fp KEY-C)
retired $(fp KEY-A)" ] || { echo "the record: $(cat "$r") $(cat "$d/out")"; return; }
    fi
    echo ok
    return
  fi
  if [ "$2" = listed ]; then
    # On version A (next B) after a fallback; the image lists C (no longer trusted) and X (never
    # enrolled here) as retired.
    printf '%s\n%s\n' "$(fp KEY-A)" "$(fp KEY-B)" > "$d/root/run/nyra-tpm2-keep"
    printf '0 tpm2\n1 tpm2\n2 tpm2\n3 recovery\n' > "$st/slots"
    printf '0 %s\n1 %s\n2 %s pin\n' "$(fp KEY-A)" "$(fp KEY-B)" "$(fp KEY-C)" > "$r"
    mkdir -p "$d/usr-upper/lib/nyra/secureboot"
    printf '# retired\n%s\n%s\n' "$(fp KEY-C)" "$(fp KEY-X)" > "$d/usr-upper/lib/nyra/secureboot/tpm2-pcr-retired-keys"
    run "$1" "$d"
    [ "$(cat "$st/calls")" = "wipe 2" ] || { echo "not C's slot alone removed: $(cat "$st/calls") $(cat "$d/out")"; return; }
    [ "$(grep -v '^retired ' "$r")" = "0 $(fp KEY-A)
1 $(fp KEY-B)" ] && [ "$(grep '^retired ' "$r" | sort)" = "$(printf 'retired %s\n' "$(fp KEY-C)" "$(fp KEY-X)" | sort)" ] ||
      { echo "the record: $(cat "$r")"; return; }
    echo ok
    return
  fi
  if [ "$2" = not-tpm2 ]; then
    # The record lists A at slot 1, which the header has as the recovery key.
    printf '1 %s\n2 %s\n' "$(fp KEY-A)" "$(fp KEY-B)" > "$r"
    run "$1" "$d"
    grep -q '^wipe' "$st/calls" && { echo "a slot that is not a TPM2 enrollment removed: $(cat "$st/calls")"; return; }
    [ "$(cat "$r")" = "2 $(fp KEY-B)
retired $(fp KEY-A)" ] || { echo "the record: $(cat "$r")"; return; }
    echo ok
    return
  fi
  if [ "$2" = fallback ]; then
    printf '%s\n%s\n' "$(fp KEY-A)" "$(fp KEY-B)" > "$d/root/run/nyra-tpm2-keep"
    printf '0 %s\n1 %s\n2 %s\n' "$(fp KEY-A)" "$(fp KEY-B)" "$(fp KEY-C)" > "$r"
    printf '0 tpm2\n1 tpm2\n2 tpm2\n3 recovery\n' > "$st/slots"
    run "$1" "$d"
    grep -q '^wipe' "$st/calls" && { echo "removed a newer enrollment: $(cat "$st/calls")"; return; }
    echo ok
    return
  fi
  local m=""
  [ "$2" != with-B-pin ] || m=" pin"
  if [ "$2" != without-B ]; then
    printf '0 %s%s\n1 %s%s\n2 %s%s\n' "$(fp KEY-A)" "$m" "$(fp KEY-B)" "$m" "$(fp KEY-C)" "$m" > "$r"
  else
    printf '0 %s\n2 %s\n' "$(fp KEY-A)" "$(fp KEY-C)" > "$r"
  fi
  run "$1" "$d"
  if [ "$2" = without-B ]; then
    grep -q '^wipe' "$st/calls" && { echo "removed with no enrollment for the booted key: $(cat "$st/calls")"; return; }
    grep -q "no enrollment for this boot's policy key" "$d/out" || { echo "not logged: $(cat "$d/out")"; return; }
    echo ok
    return
  fi
  [ "$(cat "$st/calls")" = "wipe 0" ] || { echo "not A's slot alone removed: $(cat "$st/calls") $(cat "$d/out")"; return; }
  [ "$(cat "$r")" = "1 $(fp KEY-B)$m
2 $(fp KEY-C)$m
retired $(fp KEY-A)" ] || { echo "the record: $(cat "$r")"; return; }
  echo ok
}

# f. A PIN asked for from the running system, applied in a boot the TPM unlocked.
case_request() { # case_request SCRIPT new|none|change
  local d
  d="$(mktemp -d -p "$t")"
  setup "$d" tpm
  local st="$d/root/state" want=24681357 r="$d/root/$record"
  mkdir -p "$d/root/sysroot/var/lib/nyra"
  if [ "$2" = new ]; then
    printf '0 tpm2 KEY-A\n1 recovery\n2 tpm2 KEY-B\n' > "$st/slots"
    printf '0 %s\n2 %s\n' "$(fp KEY-A)" "$(fp KEY-B)" > "$r"
  else
    printf '0 tpm2 KEY-A 11223344\n1 recovery\n2 tpm2 KEY-B 11223344\n' > "$st/slots"
    printf '0 %s pin\n2 %s pin\nretired %s\n' "$(fp KEY-A)" "$(fp KEY-B)" "$(fp KEY-Z)" > "$r"
    printf '11223344\0' > "$st/pincache"
  fi
  [ "$2" != none ] || want=none
  [ "$2" != change ] || want=97531864
  echo "$want" > "$d/root/sysroot/var/lib/nyra/tpm2-pin-request"
  run "$1" "$d"
  # Unlocked with the PIN typed in this boot, then (for the next key) with the new PIN if there is one.
  local unlock="" unlock2="" mark=" pin" newpin=" pin=$want"
  case "$2" in
    new) unlock2=" unlock-pin=$want" ;;
    none) unlock=" unlock-pin=11223344" unlock2="$unlock" mark="" newpin="" ;;
    change) unlock=" unlock-pin=11223344" unlock2=" unlock-pin=$want" ;;
  esac
  [ "$(grep '^enroll' "$st/calls")" = "enroll KEY-A$newpin$unlock
enroll KEY-B$newpin$unlock2" ] || { echo "not enrolled for A and B as asked: $(cat "$st/calls") $(cat "$d/out")"; return; }
  # A new PIN replaces the enrollments with a PIN itself: nothing more to remove.
  local wiped="wipe 0,2"
  [ "$2" != change ] || wiped=""
  [ "$(grep '^wipe' "$st/calls" || true)" = "$wiped" ] || { echo "removed: $(grep '^wipe' "$st/calls") $(cat "$d/out")"; return; }
  local gone=""
  [ "$2" = new ] || gone="retired $(fp KEY-Z)
"
  [ "$(cat "$r")" = "${gone}3 $(fp KEY-A)$mark
4 $(fp KEY-B)$mark" ] || { echo "the record: $(cat "$r")"; return; }
  [ ! -e "$d/root/sysroot/var/lib/nyra/tpm2-pin-request" ] || { echo "the request left"; return; }
  [ ! -e "$d/root/run/nyra-tpm-pin" ] || { echo "the PIN left in /run"; return; }
  [ "$2" = new ] || grep -qx 'invalidate pin' "$st/calls" || { echo "the PIN left in the cache"; return; }
  [ "$(grep -c . "$st/slots")" = 3 ] || { echo "the key slots: $(cat "$st/slots")"; return; }
  echo ok
}
# g. A refusal on a disk with a PIN: the recovery key typed, a new PIN chosen at the prompt.
case_again_pin() { # case_again_pin SCRIPT chosen|not-chosen
  local d
  d="$(mktemp -d -p "$t")"
  setup "$d" typed
  local st="$d/root/state" r="$d/root/$record"
  mkdir -p "$d/root/sysroot/var/lib/nyra"
  # The header says slot 1, the recovery key's, is a TPM2 enrollment too (tokens are not authenticated).
  printf '0 tpm2 KEY-A 11223344\n1 tpm2\n2 tpm2 KEY-B 11223344\n' > "$st/slots"
  printf '0 %s pin\n1 %s pin\n2 %s pin\n' "$(fp KEY-A)" "$(fp KEY-X)" "$(fp KEY-B)" > "$r"
  if [ "$2" = chosen ]; then
    printf '12345\n13579135\n13579135\n' > "$st/answers" # too short first
  else
    printf '13579135\n13579130\n12345678\n12345670\n' > "$st/answers" # never the same twice
  fi
  local before
  before="$(cat "$r")"
  run "$1" "$d"
  grep -q '^wipe.*1' "$st/calls" && { echo "the typed key's slot removed: $(cat "$st/calls")"; return; }
  if [ "$2" = not-chosen ]; then
    grep -q '^\(wipe\|enroll\)' "$st/calls" && { echo "changed without a new PIN: $(cat "$st/calls")"; return; }
    [ "$(cat "$r")" = "$before" ] || { echo "the record changed: $(cat "$r")"; return; }
    echo ok
    return
  fi
  [ "$(grep '^enroll' "$st/calls")" = "enroll KEY-A pin=13579135
enroll KEY-B pin=13579135" ] || { echo "not enrolled with the chosen PIN: $(cat "$st/calls") $(cat "$d/out")"; return; }
  [ "$(cat "$r")" = "3 $(fp KEY-A) pin
4 $(fp KEY-B) pin" ] || { echo "the record: $(cat "$r")"; return; }
  [ "$(grep -c '^ask' "$st/calls")" = 3 ] || { echo "asked $(grep -c '^ask' "$st/calls") times"; return; }
  echo ok
}
# h. tpm-pin in the running system.
case_cmd() { # case_cmd SCRIPT: "ok" or what went wrong
  local d
  d="$(mktemp -d -p "$t")"
  setup "$d" tpm
  local req="$d/root/var/lib/nyra/tpm2-pin-request" bad
  run "$1" "$d" status
  grep -q "not unlocked with the TPM" "$d/out" || { echo "used without a record: $(cat "$d/out")"; return; }
  printf '0 %s\n' "$(fp KEY-A)" > "$d/root/var/lib/nyra/tpm2-slots"
  for bad in 12345 123456789012345678901 12a456 "" "123 456"; do
    printf '%s\n' "$bad" > "$d/stdin"
    run "$1" "$d" set
    [ ! -e "$req" ] || { echo "accepted the PIN '$bad'"; return; }
  done
  printf '24681357\n' > "$d/stdin"
  run "$1" "$d" set
  [ "$(cat "$req" 2>/dev/null)" = 24681357 ] || { echo "the request: $(cat "$d/out")"; return; }
  [ "$(stat -c %a "$req")" = 600 ] || { echo "the request can be read by others: $(stat -c %a "$req")"; return; }
  run "$1" "$d" status
  [ "$(cat "$d/out")" = "pin no
requested pin" ] || { echo "the status: $(cat "$d/out")"; return; }
  run "$1" "$d" remove
  [ "$(cat "$req")" = none ] || { echo "the removal: $(cat "$d/out")"; return; }
  echo ok
}

fail=0
check() { # check DESCRIPTION EXPECTED GOT
  local got=fails
  [ "$3" != ok ] || got=ok
  if [ "$2" = "$got" ]; then
    echo "test-tpm-enroll: $1: ${3} [OK]"
  else
    echo "test-tpm-enroll: $1: expected $2, got: $3 [WRONG]"; fail=1
  fi
}
mutant() { # mutant NAME SCRIPT SED: a copy of SCRIPT with SED applied, which must change it
  sed "$3" "$2" > "$t/$1"
  ! cmp -s "$2" "$t/$1" || { echo "test-tpm-enroll: the mutation $1 did not apply"; exit 1; }
}
enroll="$boot/tpm-enroll" retire="$boot/tpm-retire"
check "a symbolic link on the record's path, first boot" ok "$(case_link "$enroll" first)"
check "a symbolic link on the record's path, after a refusal" ok "$(case_link "$enroll" typed)"
check "the typed key's slot listed in the record" ok "$(case_slot "$enroll")"
check "the next key enrolled after a rotation" ok "$(case_next "$enroll")"
check "a retired key not enrolled again" ok "$(case_retired "$enroll")"
check "the old key's enrollment retired" ok "$(case_retire "$retire" with-B)"
check "nothing retired without an enrollment for the booted key" ok "$(case_retire "$retire" without-B)"
check "the keys the image lists as retired" ok "$(case_retire "$retire" listed)"
check "tpm-retire never removes a slot that is not a TPM2 enrollment" ok "$(case_retire "$retire" not-tpm2)"
check "a key the image lists as retired not enrolled again" ok "$(case_retired "$enroll" listed)"
check "a next key the image lists as retired not enrolled" ok "$(case_next "$enroll" listed)"
check "a newer key's enrollment kept on a fallback" ok "$(case_retire "$retire" fallback)"
check "tpm-retire after a run cut off before it wrote the record" ok "$(case_retire "$retire" interrupted)"
check "tpm-retire removes nothing when the record cannot be written" ok "$(case_retire "$retire" full)"
check "after a refusal, a slot the record lists but that is gone" ok "$(case_stale "$enroll")"
check "the old key's enrollment retired, with a PIN" ok "$(case_retire "$retire" with-B-pin)"
check "the next key enrolled with the PIN typed in this boot" ok "$(case_next_pin "$enroll" with-cache)"
check "the next key not enrolled without the PIN" ok "$(case_next_pin "$enroll" without-cache)"
check "a PIN asked for, on a disk without one" ok "$(case_request "$enroll" new)"
check "no PIN asked for, on a disk with one" ok "$(case_request "$enroll" none)"
check "another PIN asked for" ok "$(case_request "$enroll" change)"
check "a new PIN chosen after a refusal" ok "$(case_again_pin "$enroll" chosen)"
check "no PIN chosen after a refusal: nothing changes" ok "$(case_again_pin "$enroll" not-chosen)"
check "tpm-pin" ok "$(case_cmd "$boot/tpm-pin")"

# The same cases without the checks they rely on must fail.
mutant no-inroot "$enroll" 's/inroot && //g'
check "without the path check, first boot" fails "$(case_link "$t/no-inroot" first)"
check "without the path check, after a refusal" fails "$(case_link "$t/no-inroot" typed)"
mutant no-opened "$enroll" 's/ | grep -vxF "\$opened"//'
check "without excluding the typed key's slot" fails "$(case_slot "$t/no-opened")"
mutant no-retired "$enroll" 's/^elif banned "\$curfp"; then$/elif false; then/'
check "without the retired-key check" fails "$(case_retired "$t/no-retired")"
mutant no-list "$enroll" 's/^  retired "\$1" || { .*$/  retired "$1"/'
check "without the image's list of retired keys" fails "$(case_retired "$t/no-list" listed)"
check "without the image's list, the next key" fails "$(case_next "$t/no-list" listed)"
mutant no-retire-list "$retire" 's/^listed="\$(grep .*$/listed=""/'
check "tpm-retire without the image's list" fails "$(case_retire "$t/no-retire-list" listed)"
mutant no-retire-type "$retire" 's/ | grep -xF "\${tpm2:--}"//'
check "tpm-retire without the slot type check" fails "$(case_retire "$t/no-retire-type" not-tpm2)"
check "tpm-retire without leaving out the slots that are gone" fails "$(case_retire "$t/no-retire-type" interrupted)"
mutant no-current "$retire" 's/^if grep -Eq "^\[0-9\]+ \$current( pin)?\\\$" "\$record"; then$/if true; then/'
check "tpm-retire without the booted key's check" fails "$(case_retire "$t/no-current" without-B)"
mutant no-order "$retire" 's/^  old="\$(sed -n .*$/  old="$(grep "^[0-9][0-9]* " "$record" | grep -v -F -f "$keep" || true)"/'
check "tpm-retire without the order of the record" fails "$(case_retire "$t/no-order" fallback)"
mutant no-cred "$enroll" 's/CREDENTIALS_DIRECTORY="\$creds" enroll/enroll/'
check "without the typed PIN for the next key" fails "$(case_next_pin "$t/no-cred" with-cache)"
mutant no-request-rm "$enroll" 's/^    rm -f "\$request"$/    :/'
check "without removing the request" fails "$(case_request "$t/no-request-rm" new)"
mutant no-tpm2-slots "$enroll" 's/ | grep -xF "\$(tpm2slots)" |/ |/'
check "without the slot type check (slots that are gone)" fails "$(case_request "$t/no-tpm2-slots" change)"
check "without the slot type check (another kind of key)" fails "$(case_slot "$t/no-tpm2-slots")"
check "without leaving out the slots that are gone, after a refusal" fails "$(case_stale "$t/no-tpm2-slots")"
mutant no-haspin "$enroll" 's/^    if \[ -z "\$want" \] && haspin; then$/    if false; then/'
check "without the PIN kept after a refusal" fails "$(case_again_pin "$t/no-haspin" chosen)"
mutant no-spare "$enroll" 's/spare="\$opened" PASSWORD/spare="" PASSWORD/'
check "without sparing the typed key's slot, with a PIN" fails "$(case_again_pin "$t/no-spare" chosen)"
mutant no-forget-pin "$enroll" 's/^  \[ -z "\$pincache" \] || keyctl invalidate .*$/  :/'
check "without removing the PIN from the cache" fails "$(case_request "$t/no-forget-pin" none)"
mutant no-pin-digits "$boot/tpm-pin" 's/^    case "\$pin" in .*$/    :/'
check "tpm-pin without the digits check" fails "$(case_cmd "$t/no-pin-digits")"
mutant no-new-cred "$enroll" 's/^  if \[ -n "\${CREDENTIALS_DIRECTORY:-}" \] && \[ -n "\$newpin" \]; then$/  if false; then/'
check "without the new PIN to unlock for the next key" fails "$(case_request "$t/no-new-cred" change)"
mutant no-umask "$boot/tpm-pin" 's/^umask 077$/umask 022/'
check "tpm-pin without the umask" fails "$(case_cmd "$t/no-umask")"

[ "$fail" = 0 ] && echo "test-tpm-enroll: passed"
exit "$fail"
