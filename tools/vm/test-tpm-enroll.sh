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
#      A and B again (the record without an empty line, here and in k);
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
#      PIN leaves /run and the cache; a request that is not 6 to 20 digits (letters, 5 or 21 digits)
#      enrolls nothing and is removed;
#   g. after a refusal on a disk with a PIN: the user chooses a new one (one too short and one with
#      letters first), the disk is enrolled with it, never without a PIN; without a choice, nothing
#      changes;
#   h. tpm-pin: only 6 to 20 digits, a request only root can read, and only on a disk with a record;
#   i. a run cut off between removing slots and writing the record (a power cut): tpm-retire and the
#      re-enrollment leave out the slots that are gone; and when the record cannot be written (a full
#      /var), tpm-retire removes nothing;
#   j. the image's list of retired keys: such a key is never enrolled again (after a refusal) or as
#      the next key, and tpm-retire removes its enrollment and marks it retired (also a key never
#      enrolled); old enrollments are removed only from slots the header has as TPM2 enrollments,
#      never the recovery key's or another kind of key's, even when the record lists them;
#   k. the installer's empty record, on a disk whose first boot found no TPM or Secure Boot off (the
#      temporary enrollment removed, nothing enrolled): the recovery key typed with the TPM and Secure
#      Boot back enrolls A and B, and no key slot is removed;
#   l. a TPM2 token without any policy added to the header (it cannot be authenticated) is not taken
#      for the first boot unless the record is the installer's empty one: on an enrolled disk (unlocked
#      by the TPM, or with the recovery key typed), on a disk set up with a password (no record) and on
#      a disk with a PIN, nothing is enrolled without the record's rules (never without the PIN), no
#      key slot is removed and the record keeps its retired keys;
#   m. the first boot: A and B enrolled, the temporary enrollment removed, the record lists A and B;
#   n. a power cut (the script killed) as an enrollment run removes key slots, after enrolling: at the
#      first boot and for a PIN asked for, the record already lists every new enrollment; the next
#      boot removes what the run left (the temporary enrollment, the enrollments without the PIN), so
#      the disk no longer opens without the PIN it asked for;
#   o. the PIN of the current key's enrollment, not of another one the record lists (a removal that
#      failed): the next key enrolled without a PIN on a disk whose current key has none;
#   p. tpm-retire says nothing on a disk not enrolled yet (the installer's empty record);
#   q. a PIN request longer than 32 bytes (a valid first line, then more) is refused;
#   r. a header that cannot be listed changes nothing: at the first boot the temporary enrollment
#      stays in the record (or the record stays the installer's) until a boot removes it, and it is
#      never said to be gone while the header still has it; a PIN asked for keeps the old
#      enrollments in the record;
#   s. a power cut between the current key's new enrollment and the next key's (a PIN asked for,
#      another PIN, a re-enrollment without a PIN): the next boot enrolls the next key as the current
#      one is, and removes its old enrollment in the same boot;
#   t. slot numbers used again (LUKS2 takes the lowest free one) and slots the header has as another
#      kind of key: never removed, and forgotten by the record only when gone or listed again;
#   u. tpm-retire: the same for a slot number used again, and a header that cannot be listed;
#   v. a missed rotation on a disk with a PIN (no enrollment of the current key): a new PIN is chosen.
# Checks a, b, d, e, f, g, i (but the full /var), j, l, n to v and the PIN of c are proven: the same
# case run on a copy of the script without the check it relies on must fail. The namespace: unshare -rm (a user namespace) where
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
# policy); removing a slot that is not there fails. A new enrollment takes the lowest free slot, as
# in LUKS2. The header's token without any policy (header.json) is slot 0's: it goes when a slot 0
# without a key is removed. Power cuts (the script's whole process group killed): with $T/cut, when
# slots are removed; with $T/cut-b, when B is about to be enrolled. The listings of the slots whose
# numbers (counted from 1) are in $T/listfail fail.
key="$(printf '%s\n' "$@" | sed -n 's/^--tpm2-public-key=//p')"
case "$*" in
  *--tpm2-device*)
    n=0; while grep -q "^$n " "$T/slots"; do n=$((n + 1)); done
    k="$(cat "$key")" line="enroll $(cat "$key")" mark=""
    if [ -e "$T/cut-b" ] && [ "$k" = KEY-B ]; then echo "power cut" >> "$T/calls"; kill -KILL 0; fi
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
    [ ! -e "$T/cut" ] || { echo "power cut" >> "$T/calls"; kill -KILL 0; }
    # Removing a slot that is not there fails, as with systemd-cryptenroll.
    for n in ${w//,/ }; do
      grep -q "^$n " "$T/slots" || exit 1
      if [ "$n" = 0 ] && grep -qx "0 tpm2" "$T/slots"; then printf '{"tokens":{}}\n' > "$T/header.json"; fi
      sed -i "/^$n /d" "$T/slots"
    done ;;
  *)
    c=$(( $(cat "$T/listn" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$T/listn"
    ! grep -qx "$c" "$T/listfail" 2>/dev/null || exit 1
    echo "SLOT TYPE"; sed 's/^/   /' "$T/slots" ;;
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
  # A session of its own: a power cut kills its process group, never the test's.
  setsid -w chroot "$d/root" /usr/bin/env -i PATH=/stubs:/usr/bin:/usr/sbin T=/state /bin/sh /script "$@" \
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
  # The first boot: the installer's empty record (behind the link).
  if [ "$2" = first ]; then : > "$out/nyra/tpm2-slots"; else printf '0 %s\n' "$(fp KEY-A)" > "$out/nyra/tpm2-slots"; fi
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
  # Slot 3 (another kind of key) is still there: the record keeps listing it (never removed).
  [ "$(cat "$d/root/$record")" = "3 $(fp KEY-Y)
0 $(fp KEY-A)
2 $(fp KEY-B)" ] || { echo "the record is not slot 3 and the two new slots: $(cat "$d/root/$record")"; return; }
  ! grep -qx '' "$d/root/$record" || { echo "an empty line in the record"; return; }
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
    # Slot 1 is still there (as the recovery key): the record keeps listing it.
    [ "$(cat "$r")" = "1 $(fp KEY-A)
2 $(fp KEY-B)
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
  # B takes the lowest free slot: 0 once A's old enrollment with a PIN was replaced.
  local b=4
  [ "$2" != change ] || b=0
  [ "$(cat "$r")" = "${gone}3 $(fp KEY-A)$mark
$b $(fp KEY-B)$mark" ] || { echo "the record: $(cat "$r")"; return; }
  [ ! -e "$d/root/sysroot/var/lib/nyra/tpm2-pin-request" ] || { echo "the request left"; return; }
  [ ! -e "$d/root/run/nyra-tpm-pin" ] || { echo "the PIN left in /run"; return; }
  [ "$2" = new ] || grep -qx 'invalidate pin' "$st/calls" || { echo "the PIN left in the cache"; return; }
  [ "$(grep -c . "$st/slots")" = 3 ] || { echo "the key slots: $(cat "$st/slots")"; return; }
  echo ok
}
# f. A request that is not 6 to 20 digits, on a disk without a PIN: nothing enrolled, the request
# removed.
case_bad_request() { # case_bad_request SCRIPT REQUEST
  local d
  d="$(mktemp -d -p "$t")"
  setup "$d" tpm
  local st="$d/root/state" r="$d/root/$record" req="$d/root/sysroot/var/lib/nyra/tpm2-pin-request"
  mkdir -p "$d/root/sysroot/var/lib/nyra"
  printf '0 tpm2 KEY-A\n1 recovery\n2 tpm2 KEY-B\n' > "$st/slots"
  printf '0 %s\n2 %s\n' "$(fp KEY-A)" "$(fp KEY-B)" > "$r"
  local before
  before="$(cat "$r")"
  echo "$2" > "$req"
  run "$1" "$d"
  grep -q '^\(wipe\|enroll\)' "$st/calls" && { echo "enrolled with the request '$2': $(cat "$st/calls")"; return; }
  [ "$(cat "$r")" = "$before" ] || { echo "the record changed: $(cat "$r")"; return; }
  [ ! -e "$req" ] || { echo "the request left"; return; }
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
    printf '12345\n1357a135\n13579135\n13579135\n' > "$st/answers" # too short, then letters first
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
0 $(fp KEY-B) pin" ] || { echo "the record: $(cat "$r")"; return; }
  [ "$(grep -c '^ask' "$st/calls")" = 4 ] || { echo "asked $(grep -c '^ask' "$st/calls") times"; return; }
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
# k. Only the recovery key's slot, the installer's empty record, the recovery key typed.
case_empty() { # case_empty SCRIPT: "ok" or what went wrong
  local d
  d="$(mktemp -d -p "$t")"
  setup "$d" typed
  local st="$d/root/state"
  printf '1 recovery\n' > "$st/slots"
  printf '{"tokens":{"0":{"type":"systemd-recovery"}}}\n' > "$st/header.json"
  mkdir -p "$d/root/sysroot/var/lib/nyra" && : > "$d/root/$record"
  run "$1" "$d"
  grep -q '^wipe' "$st/calls" && { echo "a key slot removed: $(cat "$st/calls")"; return; }
  grep -qx 'enroll KEY-A' "$st/calls" && grep -qx 'enroll KEY-B' "$st/calls" ||
    { echo "not enrolled for A and B: $(cat "$st/calls") $(cat "$d/out")"; return; }
  [ "$(grep -c '^[0-9]' "$d/root/$record")" = 2 ] || { echo "the record is not the two new slots: $(cat "$d/root/$record")"; return; }
  ! grep -qx '' "$d/root/$record" || { echo "an empty line in the record"; return; }
  grep -q '^invalidate' "$st/calls" || { echo "the typed key left in the cache"; return; }
  echo ok
}
# l. A token without any policy (the stand-in header's) on a disk that is not at its first boot.
case_fake() { # case_fake SCRIPT enrolled|typed|password|pin: "ok" or what went wrong
  local d
  d="$(mktemp -d -p "$t")"
  setup "$d" first
  local st="$d/root/state" before=""
  mkdir -p "$d/root/sysroot/var/lib/nyra"
  case "$2" in
    enrolled|typed)
      # Enrolled for A and B, C retired; the forged token claims the recovery key's slot (1).
      printf '0 tpm2 KEY-A\n1 recovery\n2 tpm2 KEY-B\n' > "$st/slots"
      printf '0 %s\n2 %s\nretired %s\n' "$(fp KEY-A)" "$(fp KEY-B)" "$(fp KEY-C)" > "$d/root/$record"
      [ "$2" != typed ] || printf '%s\0' "$(cat "$st/recovery-key")" > "$st/cache" ;;
    password) # a password (slot 0, typed), the recovery key; no record
      printf '0 password\n1 recovery\n' > "$st/slots"
      rm -rf "$d/root/sysroot/var/lib/nyra"
      printf '%s\0' typed-password > "$st/cache" ;;
    pin) # enrolled for A and B with a PIN, the PIN typed in this boot
      printf '0 tpm2 KEY-A 24681357\n1 recovery\n2 tpm2 KEY-B 24681357\n' > "$st/slots"
      printf '0 %s pin\n2 %s pin\n' "$(fp KEY-A)" "$(fp KEY-B)" > "$d/root/$record"
      printf '%s\0' 24681357 > "$st/pincache" ;;
  esac
  [ ! -f "$d/root/$record" ] || before="$(cat "$d/root/$record")"
  run "$1" "$d"
  if [ "$2" = typed ]; then
    # Enrolled again as after any refusal: the record's old slots go, never the recovery key's.
    if grep -Eq '^wipe (.*,)?1(,|$)|wipe tpm2' "$st/calls"; then echo "the recovery key's slot removed: $(cat "$st/calls")"; return; fi
    grep -qx 'enroll KEY-A' "$st/calls" || { echo "not enrolled again: $(cat "$st/calls") $(cat "$d/out")"; return; }
  elif grep -q wipe "$st/calls"; then
    echo "a key slot removed: $(cat "$st/calls")"; return
  elif grep -q '^enroll' "$st/calls"; then
    echo "enrolled through the forged token: $(cat "$st/calls")"; return
  fi
  if [ "$2" = password ]; then
    [ ! -e "$d/root/$record" ] || { echo "a record made on a disk with a password"; return; }
  elif [ "$2" != typed ] && [ "$(cat "$d/root/$record")" != "$before" ]; then
    echo "the record changed: $(cat "$d/root/$record")"; return
  fi
  [ "$2" != typed ] || grep -qx "retired $(fp KEY-C)" "$d/root/$record" || { echo "the retired key lost: $(cat "$d/root/$record")"; return; }
  grep -q 'without any policy.*ignored' "$d/out" || { echo "not logged: $(cat "$d/out")"; return; }
  echo ok
}

# m. The first boot: the temporary enrollment (slot 0, no policy) and the installer's empty record.
# n. With "cut": a power cut as the temporary enrollment is removed, then the next boot.
case_first() { # case_first SCRIPT [cut]: "ok" or what went wrong
  local d
  d="$(mktemp -d -p "$t")"
  setup "$d" first
  local st="$d/root/state" r="$d/root/$record"
  mkdir -p "$d/root/sysroot/var/lib/nyra" && : > "$r"
  local ab
  ab="2 $(fp KEY-A)
3 $(fp KEY-B)"
  if [ "${2:-}" = cut ]; then
    touch "$st/cut"
    run "$1" "$d"
    grep -qx 'power cut' "$st/calls" || { echo "no power cut: $(cat "$st/calls") $(cat "$d/out")"; return; }
    [ "$(grep -v " $(printf '%064d' 0)\$" "$r")" = "$ab" ] ||
      { echo "the record after the power cut does not list the new enrollments: $(cat "$r")"; return; }
    rm "$st/cut" && : > "$st/calls"
    run "$1" "$d" # the next boot (the header still has the token without any policy)
    [ "$(cat "$st/calls")" = "wipe 0" ] || { echo "the next boot: $(cat "$st/calls") $(cat "$d/out")"; return; }
  else
    run "$1" "$d"
    [ "$(cat "$st/calls")" = "enroll KEY-A
enroll KEY-B
wipe 0" ] || { echo "not A and B enrolled, then the temporary enrollment removed: $(cat "$st/calls") $(cat "$d/out")"; return; }
    grep -q '^nyra-tpm-enroll: enrolled with the TPM (.*temporary enrollment removed$' "$d/out" || { echo "not logged: $(cat "$d/out")"; return; }
  fi
  [ "$(cat "$r")" = "$ab" ] || { echo "the record: $(cat "$r")"; return; }
  [ "$(cat "$st/slots")" = "1 recovery
2 tpm2 KEY-A
3 tpm2 KEY-B" ] || { echo "the key slots: $(cat "$st/slots")"; return; }
  echo ok
}
# n. A PIN asked for on a disk without one, and a power cut as the old enrollments are removed; then
# the next boot (unlocked by the TPM: the old enrollments still open the disk).
case_cut_request() { # case_cut_request SCRIPT: "ok" or what went wrong
  local d
  d="$(mktemp -d -p "$t")"
  setup "$d" tpm
  local st="$d/root/state" r="$d/root/$record"
  mkdir -p "$d/root/sysroot/var/lib/nyra"
  printf '0 tpm2 KEY-A\n1 recovery\n2 tpm2 KEY-B\n' > "$st/slots"
  printf '0 %s\n2 %s\n' "$(fp KEY-A)" "$(fp KEY-B)" > "$r"
  echo 24681357 > "$d/root/sysroot/var/lib/nyra/tpm2-pin-request"
  touch "$st/cut"
  run "$1" "$d"
  grep -qx 'power cut' "$st/calls" || { echo "no power cut: $(cat "$st/calls") $(cat "$d/out")"; return; }
  grep -qx "3 $(fp KEY-A) pin" "$r" && grep -qx "4 $(fp KEY-B) pin" "$r" ||
    { echo "the record after the power cut does not list the new enrollments: $(cat "$r")"; return; }
  rm "$st/cut" && : > "$st/calls"
  run "$1" "$d"
  [ "$(cat "$st/calls")" = "wipe 0,2" ] || { echo "the next boot: $(cat "$st/calls") $(cat "$d/out")"; return; }
  [ "$(cat "$r")" = "3 $(fp KEY-A) pin
4 $(fp KEY-B) pin" ] || { echo "the record: $(cat "$r")"; return; }
  echo ok
}
# o. Enrolled for A without a PIN, and the record still lists an enrollment of Z with a PIN (its
# removal failed); unlocked by the TPM, nothing typed; the image's next key is B.
case_other_pin() { # case_other_pin SCRIPT: "ok" or what went wrong
  local d
  d="$(mktemp -d -p "$t")"
  setup "$d" tpm
  local st="$d/root/state" r="$d/root/$record"
  mkdir -p "$d/root/sysroot/var/lib/nyra"
  printf '0 tpm2 KEY-A\n1 recovery\n3 tpm2 KEY-Z 11223344\n' > "$st/slots"
  printf '0 %s\n3 %s pin\n' "$(fp KEY-A)" "$(fp KEY-Z)" > "$r"
  run "$1" "$d"
  [ "$(cat "$st/calls")" = "enroll KEY-B" ] || { echo "B not enrolled without a PIN: $(cat "$st/calls") $(cat "$d/out")"; return; }
  [ "$(cat "$r")" = "0 $(fp KEY-A)
3 $(fp KEY-Z) pin
2 $(fp KEY-B)" ] || { echo "the record: $(cat "$r")"; return; }
  echo ok
}
# p. tpm-retire on a disk whose first boot enrolled nothing (the installer's empty record).
case_retire_unpaired() { # case_retire_unpaired SCRIPT: "ok" or what went wrong
  local d
  d="$(mktemp -d -p "$t")"
  setup "$d" tpm
  local st="$d/root/state" r="$d/root/var/lib/nyra/tpm2-slots"
  printf '%s\n%s\n' "$(fp KEY-A)" "$(fp KEY-B)" > "$d/root/run/nyra-tpm2-keep"
  : > "$r"
  run "$1" "$d"
  [ ! -s "$d/out" ] || { echo "said: $(cat "$d/out")"; return; }
  [ ! -s "$st/calls" ] && [ ! -s "$r" ] || { echo "changed: $(cat "$st/calls") $(cat "$r")"; return; }
  echo ok
}

# r. The header cannot be listed at the first boot: when the temporary enrollment is listed for the
# record (the 1st listing), or when it is removed (the 6th and 7th); then the next boot.
case_first_list() { # case_first_list SCRIPT 1|6: "ok" or what went wrong
  local d
  d="$(mktemp -d -p "$t")"
  setup "$d" first
  local st="$d/root/state" r="$d/root/$record"
  mkdir -p "$d/root/sysroot/var/lib/nyra" && : > "$r"
  if [ "$2" = 1 ]; then echo 1; else printf '6\n7\n'; fi > "$st/listfail"
  run "$1" "$d"
  ! grep -q 'temporary enrollment removed' "$d/out" || { echo "said removed: $(cat "$d/out")"; return; }
  grep -qx '0 tpm2' "$st/slots" || { echo "the temporary enrollment is gone: $(cat "$st/slots")"; return; }
  if [ "$2" = 1 ]; then
    [ ! -s "$r" ] || { echo "the record is no longer the installer's: $(cat "$r")"; return; }
    grep -q '^enroll' "$st/calls" && { echo "enrolled: $(cat "$st/calls")"; return; }
  else
    grep -qx "0 $(printf '%064d' 0)" "$r" || { echo "the record no longer lists the temporary enrollment: $(cat "$r")"; return; }
  fi
  rm "$st/listfail" "$st/listn" && : > "$st/calls"
  run "$1" "$d" # the next boot
  grep -qx 'wipe 0' "$st/calls" || { echo "the next boot: $(cat "$st/calls") $(cat "$d/out")"; return; }
  ! grep -q '^[0-9]* tpm2$' "$st/slots" || { echo "the key slots: $(cat "$st/slots")"; return; }
  echo ok
}
# r. The header lists the temporary enrollment's token at slot 0, which it labels as something else:
# the first boot removes the slot it has as TPM2 (2), and never says the temporary one is gone.
case_first_label() { # case_first_label SCRIPT: "ok" or what went wrong
  local d
  d="$(mktemp -d -p "$t")"
  setup "$d" first
  local st="$d/root/state" r="$d/root/$record"
  mkdir -p "$d/root/sysroot/var/lib/nyra" && : > "$r"
  printf '0 fido2\n1 recovery\n2 tpm2\n' > "$st/slots"
  run "$1" "$d"
  grep -q 'the temporary enrollment could not be removed' "$d/out" || { echo "said: $(cat "$d/out")"; return; }
  echo ok
}
# r. A PIN asked for on a disk without one, and the header cannot be listed when the old enrollments
# are removed (the 5th and 6th listings): they stay in the record, and the next boot removes them.
case_request_list() { # case_request_list SCRIPT: "ok" or what went wrong
  local d
  d="$(mktemp -d -p "$t")"
  setup "$d" tpm
  local st="$d/root/state" r="$d/root/$record"
  mkdir -p "$d/root/sysroot/var/lib/nyra"
  printf '0 tpm2 KEY-A\n1 recovery\n2 tpm2 KEY-B\n' > "$st/slots"
  printf '0 %s\n2 %s\n' "$(fp KEY-A)" "$(fp KEY-B)" > "$r"
  echo 24681357 > "$d/root/sysroot/var/lib/nyra/tpm2-pin-request"
  printf '5\n6\n' > "$st/listfail"
  run "$1" "$d"
  grep -q '^wipe' "$st/calls" && { echo "removed: $(cat "$st/calls")"; return; }
  grep -qx "0 $(fp KEY-A)" "$r" && grep -qx "2 $(fp KEY-B)" "$r" ||
    { echo "the record forgot the enrollments without the PIN: $(cat "$r")"; return; }
  rm "$st/listfail" "$st/listn" && : > "$st/calls"
  printf '24681357\0' > "$st/pincache"
  run "$1" "$d"
  [ "$(grep -v '^invalidate' "$st/calls")" = "wipe 0,2" ] || { echo "the next boot: $(cat "$st/calls") $(cat "$d/out")"; return; }
  echo ok
}
# s. A power cut between the current key's new enrollment and the next key's: a PIN asked for on a
# disk without one (set), another PIN (change), the re-enrollment without a PIN after a refusal
# (again). The next boot (unlocked by the TPM, the new PIN typed) enrolls the next key as the
# current one is, then removes its old enrollment, in the same boot.
case_cut_between() { # case_cut_between SCRIPT set|change|again: "ok" or what went wrong
  local d
  d="$(mktemp -d -p "$t")"
  setup "$d" "$([ "$2" = again ] && echo typed || echo tpm)"
  local st="$d/root/state" r="$d/root/$record" pin=24681357 calls
  mkdir -p "$d/root/sysroot/var/lib/nyra"
  case "$2" in
    set)
      printf '0 tpm2 KEY-A\n1 recovery\n2 tpm2 KEY-B\n' > "$st/slots"
      printf '0 %s\n2 %s\n' "$(fp KEY-A)" "$(fp KEY-B)" > "$r"
      echo "$pin" > "$d/root/sysroot/var/lib/nyra/tpm2-pin-request"
      calls="wipe 0
enroll KEY-B pin=$pin unlock-pin=$pin
wipe 2" ;;
    change)
      printf '0 tpm2 KEY-A 11112222\n1 recovery\n2 tpm2 KEY-B 11112222\n' > "$st/slots"
      printf '0 %s pin\n2 %s pin\n' "$(fp KEY-A)" "$(fp KEY-B)" > "$r"
      printf '11112222\0' > "$st/pincache"
      echo "$pin" > "$d/root/sysroot/var/lib/nyra/tpm2-pin-request"
      calls="enroll KEY-B pin=$pin unlock-pin=$pin" ;;
    again) # the TPM refused (its enrollments are of other keys now); no PIN
      printf '0 tpm2 KEY-X\n1 recovery\n2 tpm2 KEY-Y\n' > "$st/slots"
      printf '0 %s\n2 %s\n' "$(fp KEY-A)" "$(fp KEY-B)" > "$r"
      pin="" calls="enroll KEY-B" ;;
  esac
  touch "$st/cut-b"
  run "$1" "$d"
  grep -qx 'power cut' "$st/calls" || { echo "no power cut: $(cat "$st/calls") $(cat "$d/out")"; return; }
  rm "$st/cut-b" "$st/cache" 2>/dev/null; : > "$st/calls"
  [ -z "$pin" ] || printf '%s\0' "$pin" > "$st/pincache"
  run "$1" "$d" # the next boot
  [ "$(grep -v '^invalidate' "$st/calls")" = "$calls" ] || { echo "the next boot: $(cat "$st/calls") $(cat "$d/out")"; return; }
  local m=""
  [ -z "$pin" ] || m=" pin"
  [ "$(grep -v '^retired ' "$r" | sed 's/^[0-9]* //')" = "$(fp KEY-A)$m
$(fp KEY-B)$m" ] || { echo "the record: $(cat "$r")"; return; }
  [ "$(grep -c ' tpm2 ' "$st/slots")" = 2 ] && [ "$(grep -c " tpm2 KEY-[AB]${pin:+ $pin}\$" "$st/slots")" = 2 ] ||
    { echo "the key slots: $(cat "$st/slots")"; return; }
  echo ok
}
# t. Key slot numbers used again (LUKS2 takes the lowest free one) and slots the header has as
# something else, in the record that a run cut off left: nothing removed that a later line lists or
# that is not a TPM2 enrollment, and the record forgets only what is gone or listed again.
case_tidy() { # case_tidy SCRIPT reuse|reuse-other|other|other-zero: "ok" or what went wrong
  local d
  d="$(mktemp -d -p "$t")"
  setup "$d" tpm
  local st="$d/root/state" r="$d/root/$record" before after
  mkdir -p "$d/root/sysroot/var/lib/nyra"
  printf '0 tpm2 KEY-A\n1 recovery\n2 tpm2 KEY-B\n' > "$st/slots"
  case "$2" in
    reuse) # a re-enrollment without a PIN cut off before its last write: 0 A, 2 B wiped, then new
      before="$(printf '0 %s\n2 %s\n0 %s\n2 %s\n' "$(fp KEY-A)" "$(fp KEY-B)" "$(fp KEY-A)" "$(fp KEY-B)")"
      after="$(printf '0 %s\n2 %s\n' "$(fp KEY-A)" "$(fp KEY-B)")" ;;
    reuse-other) # slot 0 was B's, then A's; B again in slot 2
      before="$(printf '0 %s\n0 %s\n2 %s\n' "$(fp KEY-B)" "$(fp KEY-A)" "$(fp KEY-B)")"
      after="$(printf '0 %s\n2 %s\n' "$(fp KEY-A)" "$(fp KEY-B)")" ;;
    other) # slot 0 is now a password, and A is enrolled again later
      printf '0 password\n1 recovery\n3 tpm2 KEY-A\n4 tpm2 KEY-B\n' > "$st/slots"
      before="$(printf '0 %s\n3 %s\n4 %s\n' "$(fp KEY-A)" "$(fp KEY-A)" "$(fp KEY-B)")"
      after="$before" ;;
    other-zero) # the temporary enrollment listed at the recovery key's slot
      printf '1 recovery\n3 tpm2 KEY-A\n4 tpm2 KEY-B\n' > "$st/slots"
      before="$(printf '1 %064d\n3 %s\n4 %s\n' 0 "$(fp KEY-A)" "$(fp KEY-B)")"
      after="$before" ;;
  esac
  printf '%s\n' "$before" > "$r"
  run "$1" "$d"
  grep -q '^wipe' "$st/calls" && { echo "removed: $(cat "$st/calls")"; return; }
  [ "$(cat "$r")" = "$after" ] || { echo "the record: $(cat "$r")"; return; }
  echo ok
}
# u. tpm-retire: the old key's slot number used again further down (A's slot 0, now C's), and a
# header that cannot be listed: nothing removed, and the record forgets nothing it did not remove.
case_retire_slots() { # case_retire_slots SCRIPT reuse|list: "ok" or what went wrong
  local d
  d="$(mktemp -d -p "$t")"
  setup "$d" tpm
  local st="$d/root/state" r="$d/root/var/lib/nyra/tpm2-slots"
  printf '%s\n%s\n' "$(fp KEY-B)" "$(fp KEY-C)" > "$d/root/run/nyra-tpm2-keep"
  printf '0 tpm2\n1 tpm2\n3 recovery\n' > "$st/slots"
  if [ "$2" = reuse ]; then
    printf '0 %s\n1 %s\n0 %s\n' "$(fp KEY-A)" "$(fp KEY-B)" "$(fp KEY-C)" > "$r"
  else
    printf '0 %s\n1 %s\n' "$(fp KEY-A)" "$(fp KEY-B)" > "$r"
    echo 1 > "$st/listfail"
  fi
  local before
  before="$(cat "$r")"
  run "$1" "$d"
  grep -q '^wipe' "$st/calls" && { echo "removed: $(cat "$st/calls")"; return; }
  if [ "$2" = reuse ]; then
    [ "$(cat "$r")" = "1 $(fp KEY-B)
0 $(fp KEY-C)
retired $(fp KEY-A)" ] || { echo "the record: $(cat "$r")"; return; }
  else
    [ "$(cat "$r")" = "$before" ] || { echo "the record changed: $(cat "$r")"; return; }
  fi
  echo ok
}
# v. A missed rotation on a disk with a PIN: the recovery key typed on version C, the record without
# C (only A and B, with a PIN): a new PIN is chosen, as on any disk with one.
case_missed_pin() { # case_missed_pin SCRIPT: "ok" or what went wrong
  local d
  d="$(mktemp -d -p "$t")"
  setup "$d" typed KEY-C
  local st="$d/root/state" r="$d/root/$record"
  mkdir -p "$d/root/sysroot/var/lib/nyra"
  printf '0 tpm2 KEY-A 11223344\n1 recovery\n2 tpm2 KEY-B 11223344\n' > "$st/slots"
  printf '0 %s pin\n2 %s pin\n' "$(fp KEY-A)" "$(fp KEY-B)" > "$r"
  printf '13579135\n13579135\n' > "$st/answers"
  run "$1" "$d"
  [ "$(grep '^enroll' "$st/calls")" = "enroll KEY-C pin=13579135
enroll KEY-B pin=13579135" ] || { echo "not enrolled with a new PIN: $(cat "$st/calls") $(cat "$d/out")"; return; }
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
check "a PIN request with letters" ok "$(case_bad_request "$enroll" 24a81357)"
check "a PIN request of 5 digits" ok "$(case_bad_request "$enroll" 24681)"
check "a PIN request of 21 digits" ok "$(case_bad_request "$enroll" 123456789012345678901)"
check "a new PIN chosen after a refusal" ok "$(case_again_pin "$enroll" chosen)"
check "no PIN chosen after a refusal: nothing changes" ok "$(case_again_pin "$enroll" not-chosen)"
check "tpm-pin" ok "$(case_cmd "$boot/tpm-pin")"
check "the installer's empty record, the recovery key typed" ok "$(case_empty "$enroll")"
check "a forged token without any policy, on an enrolled disk" ok "$(case_fake "$enroll" enrolled)"
check "a forged token without any policy, on an enrolled disk, the recovery key typed" ok "$(case_fake "$enroll" typed)"
check "a forged token without any policy, on a disk with a password" ok "$(case_fake "$enroll" password)"
check "a forged token without any policy, on a disk with a PIN" ok "$(case_fake "$enroll" pin)"
check "the first boot" ok "$(case_first "$enroll")"
check "a power cut at the first boot, then the next boot" ok "$(case_first "$enroll" cut)"
check "a power cut as a PIN asked for is applied, then the next boot" ok "$(case_cut_request "$enroll")"
check "the current key's PIN, not another enrollment's" ok "$(case_other_pin "$enroll")"
check "tpm-retire on a disk not enrolled yet" ok "$(case_retire_unpaired "$retire")"
check "the header not listed for the first boot's record" ok "$(case_first_list "$enroll" 1)"
check "the header not listed as the temporary enrollment is removed" ok "$(case_first_list "$enroll" 6)"
check "the temporary enrollment's slot labelled otherwise" ok "$(case_first_label "$enroll")"
check "the header not listed as a PIN asked for removes the old enrollments" ok "$(case_request_list "$enroll")"
check "a power cut between the two enrollments of a PIN asked for" ok "$(case_cut_between "$enroll" set)"
check "a power cut between the two enrollments of another PIN" ok "$(case_cut_between "$enroll" change)"
check "a power cut between the two enrollments after a refusal" ok "$(case_cut_between "$enroll" again)"
check "slot numbers used again" ok "$(case_tidy "$enroll" reuse)"
check "a slot number used again by another key" ok "$(case_tidy "$enroll" reuse-other)"
check "a replaced enrollment's slot, now another kind of key" ok "$(case_tidy "$enroll" other)"
check "the temporary enrollment listed at a slot of another kind" ok "$(case_tidy "$enroll" other-zero)"
check "tpm-retire and a slot number used again" ok "$(case_retire_slots "$retire" reuse)"
check "tpm-retire with the header not listed" ok "$(case_retire_slots "$retire" list)"
check "a missed rotation on a disk with a PIN" ok "$(case_missed_pin "$enroll")"
check "a PIN request longer than 32 bytes" ok "$(case_bad_request "$enroll" "$(printf '24681357\n%040d' 0)")"

# The same cases without the checks they rely on must fail.
mutant no-inroot "$enroll" 's/inroot && //g'
check "without the path check, first boot" fails "$(case_link "$t/no-inroot" first)"
check "without the path check, after a refusal" fails "$(case_link "$t/no-inroot" typed)"
mutant no-empty-record "$enroll" 's/^  if inroot \&\& \[ -f "\$record" \] \&\& \[ ! -s "\$record" \]; then$/  if true; then/'
check "without the empty record check, an enrolled disk" fails "$(case_fake "$t/no-empty-record" enrolled)"
check "without the empty record check, the recovery key typed" fails "$(case_fake "$t/no-empty-record" typed)"
check "without the empty record check, a disk with a password" fails "$(case_fake "$t/no-empty-record" password)"
check "without the empty record check, a disk with a PIN" fails "$(case_fake "$t/no-empty-record" pin)"
mutant no-opened "$enroll" 's/ | grep -vxF "\$opened"//'
check "without excluding the typed key's slot" fails "$(case_slot "$t/no-opened")"
mutant no-retired "$enroll" 's/^elif banned "\$curfp"; then$/elif false; then/'
check "without the retired-key check" fails "$(case_retired "$t/no-retired")"
mutant no-list "$enroll" 's/^  retired "\$1" || { .*$/  retired "$1"/'
check "without the image's list of retired keys" fails "$(case_retired "$t/no-list" listed)"
check "without the image's list, the next key" fails "$(case_next "$t/no-list" listed)"
mutant no-retire-list "$retire" 's/^listed="\$(grep .*$/listed=""/'
check "tpm-retire without the image's list" fails "$(case_retire "$t/no-retire-list" listed)"
mutant no-retire-type "$retire" 's/^    elif printf .%s\\n. "\$tpm2" | grep -qx "\$s"; then$/    elif true; then/'
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
mutant no-tpm2-slots "$enroll" 's/ | grep -xF "\${t2:--}" |/ |/'
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
mutant no-request-digits "$enroll" 's/^      \*\[!0-9\]\*|"") log/      "") log/'
check "without the request's digits check" fails "$(case_bad_request "$t/no-request-digits" 24a81357)"
mutant no-request-min "$enroll" 's/\[ "\${#want}" -lt 6 \]/[ "${#want}" -lt 5 ]/'
check "without the request's 6 digits minimum" fails "$(case_bad_request "$t/no-request-min" 24681)"
mutant no-request-max "$enroll" 's/\[ "\${#want}" -gt 20 \]/[ "${#want}" -gt 21 ]/'
check "without the request's 20 digits maximum" fails "$(case_bad_request "$t/no-request-max" 123456789012345678901)"
mutant no-choose-digits "$enroll" '/^    case "\$p" in /d'
check "without the digits check at the PIN prompt" fails "$(case_again_pin "$t/no-choose-digits" chosen)"
mutant no-early-record "$enroll" 's/^  if ! remember "\$(cat "\$record")" "\$before" .*; then$/  if false; then/'
check "without the record written at each enrollment, a power cut at the first boot" fails "$(case_first "$t/no-early-record" cut)"
check "without the record written at each enrollment, a power cut for a PIN" fails "$(case_cut_request "$t/no-early-record")"
mutant no-before "$enroll" 's/^  elif before="\$(printf .*" &&$/  elif before="" \&\&/'
check "without the temporary enrollment in the record, a power cut at the first boot" fails "$(case_first "$t/no-before" cut)"
mutant no-tidy "$enroll" 's/^if inroot 2>\/dev\/null && \[ -f "\$record" \]; then tidy .*$/:/'
check "without removing what a power cut left, at the first boot" fails "$(case_first "$t/no-tidy" cut)"
check "without removing what a power cut left, for a PIN" fails "$(case_cut_request "$t/no-tidy")"
mutant any-pin "$enroll" 's/^haspin() .*$/haspin() { grep -Eq "^[0-9]+ [0-9a-f]+ pin\$" "$record"; }/'
check "with the PIN of any enrollment in the record" fails "$(case_other_pin "$t/any-pin")"
mutant no-retire-quiet "$retire" "s/^elif grep -q '^\\[0-9\\]' \"\\\$record\"; then .*\$/else/"
check "tpm-retire, said on a disk not enrolled yet" fails "$(case_retire_unpaired "$t/no-retire-quiet")"
mutant open-listing "$enroll" '/^  printf .%s\\n. "\$l" | sed .* | grep -q . || return 1$/d; s/^  l="\$(systemd-cryptenroll "\$dev")" || return 1$/  l="$(systemd-cryptenroll "$dev")" || true/; s/^  \[ -n "\$l" \] && printf/  printf/'
check "with a listing that fails taken for no slots, at the removal" fails "$(case_first_list "$t/open-listing" 6)"
mutant no-before-check "$enroll" 's/^  if ! before="\$(tpm2slots)" || \[ -z "\$before" \]; then$/  if false; then/'
check "without the first boot's listing check" fails "$(case_first_list "$t/no-before-check" 1)"
mutant no-notemp "$enroll" 's/^    if tidy && notemp; then$/    if tidy; then/'
check "without checking that the temporary enrollment is gone" fails "$(case_first_label "$t/no-notemp")"
mutant replace-forgets "$enroll" 's/ "\$(present "\${spare:--}" \$newslots)"//'
check "with the record forgetting what a PIN asked for did not remove" fails "$(case_request_list "$t/replace-forgets")"
mutant next-only-missing "$enroll" 's/{ \[ -z "\$nl" \] || \[ "\$nl" -lt "\${cl:-0}" \]; }/[ -z "$nl" ]/'
check "without the next key enrolled again after the current one, set" fails "$(case_cut_between "$t/next-only-missing" set)"
check "without the next key enrolled again after the current one, change" fails "$(case_cut_between "$t/next-only-missing" change)"
check "without the next key enrolled again after the current one, again" fails "$(case_cut_between "$t/next-only-missing" again)"
mutant no-next-tidy "$enroll" '/^    tidy || log "could not remove the replaced enrollments"$/d'
check "without the next key's old enrollment removed in the same boot" fails "$(case_cut_between "$t/no-next-tidy" set)"
mutant no-later-guard "$enroll" 's/^    if printf .%s\\n. "\$later" | grep -q "^\$s "; then$/    if false; then/'
check "without keeping slot numbers used again" fails "$(case_tidy "$t/no-later-guard" reuse)"
check "without keeping slot numbers used again, another key" fails "$(case_tidy "$t/no-later-guard" reuse-other)"
mutant no-tidy-type "$enroll" 's/^    elif printf .%s\\n. "\$t2" | grep -qx "\$s"; then$/    elif true; then/'
check "without the slot type check of the replaced enrollments" fails "$(case_tidy "$t/no-tidy-type" other)"
check "without the slot type check of the temporary enrollment" fails "$(case_tidy "$t/no-tidy-type" other-zero)"
mutant tidy-forgets "$enroll" 's/^    elif ! printf .%s\\n. "\$all" | grep -qx "\$s"; then$/    else/'
check "with the record forgetting a slot that is there" fails "$(case_tidy "$t/tidy-forgets" other)"
mutant no-retire-reuse "$retire" 's/^    if sed "1,\${n}d" "\$record" | grep -q "^\$s "; then$/    if false; then/'
check "tpm-retire without keeping slot numbers used again" fails "$(case_retire_slots "$t/no-retire-reuse" reuse)"
mutant open-retire-listing "$retire" 's/^    \[ -n "\$all" \] || { log "the key slots could not be listed"; exit 1; }$/    true/'
check "tpm-retire with a listing that fails taken for no slots" fails "$(case_retire_slots "$t/open-retire-listing" list)"
mutant no-haspin-fallback "$enroll" "s/ || grep -E '\^\[0-9\]+ ' \"\\\$record\"; }/; }/"
check "without the disk's latest enrollment when the current key has none" fails "$(case_missed_pin "$t/no-haspin-fallback")"
mutant empty-lines "$enroll" "s/ | sed '\\/^\\\$\\/d' > \"\\\$record.new\"/ > \"\\\$record.new\"/"
check "with empty lines in the record, after a refusal" fails "$(case_slot "$t/empty-lines")"
check "with empty lines in the record, the installer's empty record" fails "$(case_empty "$t/empty-lines")"
mutant no-request-size "$enroll" 's/head -c 32 "\$request"/sed -n 1p "$request"/'
check "without the request's size limit" fails "$(case_bad_request "$t/no-request-size" "$(printf '24681357\n%040d' 0)")"

[ "$fail" = 0 ] && echo "test-tpm-enroll: passed"
exit "$fail"
