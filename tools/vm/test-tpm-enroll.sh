#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Offline test of /usr/lib/nyra/boot/tpm-enroll and tpm-retire (docs/BOOT.md, "Disk encryption"),
# without a VM, a TPM or a disk. The real scripts, unchanged, run in a mount namespace, chrooted into a
# directory where the paths they use are stand-ins (/dev/gpt-auto-root-luks, /dev/tpmrm0, the Secure
# Boot variables, PCR 12, /.extra, /sysroot, /var, /run) and /usr is the host's, with stand-ins for
# cryptsetup, systemd-cryptenroll and keyctl first on PATH that keep the key slots in a file and log
# what they are asked to do. Policy keys are stand-in PEM files: A signed the booted UKI, B is the next.
#   a. a symbolic link on the path of the enrollments' record (inside the root's /var, which belongs
#      to the running system) stops tpm-enroll: nothing is written outside that /var, on the first
#      boot as after a refusal, and no key slot is removed;
#   b. after a refusal, the key slot that the typed key opens (here the recovery key's) is never
#      removed, even when the record lists it; the other listed slot is, and the disk is enrolled for
#      A and B again;
#   c. a boot that unlocked with the TPM on a disk enrolled only for A, with B as the image's next key
#      (the release after a rotation): B is enrolled, nothing removed;
#   d. after a refusal, on a version whose key (C) was retired: not enrolled again, nothing removed;
#   e. tpm-retire, on a version signed with B whose next key is C: the enrollment of A is removed and A
#      recorded as retired; and nothing at all when the record has no enrollment for B; on a fallback
#      to A (next key B) confirmed good, the newer enrollment for C stays.
# Checks a, b, d and e are proven: the same case run on a copy of the script without the check it
# relies on must fail. The namespace: unshare -rm (a user namespace) where allowed, else sudo unshare -m.
#   tools/vm/test-tpm-enroll.sh
set -euo pipefail

if [ "${NYRA_TEST_NS:-}" != 1 ]; then
  self="$(readlink -f "$0")"
  if unshare -rm sh -c 'd="$(mktemp -d)" && mount -t tmpfs t "$d" && umount "$d" && rmdir "$d"' 2>/dev/null; then
    exec unshare -rm env NYRA_TEST_NS=1 "$self"
  fi
  exec sudo -n unshare -m env NYRA_TEST_NS=1 "$self"
fi
mount --make-rprivate /
boot="$(dirname "$0")/../../files/usr/lib/nyra/boot"
t="$(readlink -f "$(mktemp -d)")"
# Every root has the host's /usr and /dev/null bound in (read-only): unmount them before anything is
# removed, and never remove across file systems.
cleanup() {
  grep -o " $t/[^ ]*" /proc/self/mounts | sort -r | while read -r m; do umount -l "$m"; done
  rm -rf --one-file-system "$t"
}
trap cleanup EXIT
mkdir "$t/bin"

# Stand-ins (copied to /stubs in each root). State in /state of the root ($T): slots ("N type" per
# line), header.json, recovery-key, cache; log: calls.
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
key="$(printf '%s\n' "$@" | sed -n 's/^--tpm2-public-key=//p')"
case "$*" in
  *--tpm2-device*)
    n=$(( $(sort -n "$T/slots" | tail -1 | cut -d' ' -f1) + 1 ))
    w=""
    case "$*" in *--wipe-slot=tpm2*) w=", wipe tpm2" ;; esac
    echo "enroll $(cat "$key")$w" >> "$T/calls"
    echo "$n tpm2" >> "$T/slots" ;;
  --wipe-slot=*)
    w="${1#--wipe-slot=}"; echo "wipe $w" >> "$T/calls"
    for n in ${w//,/ }; do sed -i "/^$n /d" "$T/slots"; done ;;
  *) echo "SLOT TYPE"; sed 's/^/   /' "$T/slots" ;;
esac
EOF
cat > "$t/bin/keyctl" <<'EOF'
#!/bin/bash
case "$1" in
  search) [ -e "$T/cache" ] && echo 77 ;;
  pipe) printf '%s\0' "$(cat "$T/cache")" ;;
  invalidate) rm -f "$T/cache"; echo "invalidate" >> "$T/calls" ;;
esac
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
  mount --bind /usr "$d/root/usr" && mount -o remount,bind,ro "$d/root/usr"
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
  [ "$2" != typed ] || cp "$st/recovery-key" "$st/cache" # the user typed the recovery key
}
run() { # run SCRIPT DIR: the script at /script in DIR's root, with only the stand-ins' PATH
  cp "$1" "$2/root/script"
  chroot "$2/root" /usr/bin/env -i PATH=/stubs:/usr/bin:/usr/sbin T=/state /bin/sh /script \
    > "$2/out" 2>&1 || true
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
  printf '0 %s\n1 %s\n' "$(fp KEY-A)" "$(fp KEY-X)" > "$d/root/$record"
  run "$1" "$d"
  if grep -q '^wipe.*1' "$st/calls"; then echo "the typed key's slot removed: $(grep '^wipe' "$st/calls")"; return; fi
  grep -qx 'wipe 0' "$st/calls" || { echo "the old TPM slot not removed: $(cat "$st/calls") $(cat "$d/out")"; return; }
  grep -qx 'enroll KEY-A' "$st/calls" && grep -qx 'enroll KEY-B' "$st/calls" ||
    { echo "not enrolled again for A and B: $(cat "$st/calls") $(cat "$d/out")"; return; }
  [ "$(grep -c '^[0-9]' "$d/root/$record")" = 2 ] || { echo "the record is not the two new slots: $(cat "$d/root/$record")"; return; }
  echo ok
}
# c. Unlocked by the TPM (nothing typed), enrolled only for A; the image's next key is B.
case_next() { # case_next SCRIPT
  local d
  d="$(mktemp -d -p "$t")"
  setup "$d" tpm
  local st="$d/root/state"
  mkdir -p "$d/root/sysroot/var/lib/nyra"
  printf '0 %s\n' "$(fp KEY-A)" > "$d/root/$record"
  run "$1" "$d"
  grep -q '^wipe' "$st/calls" && { echo "a key slot removed: $(cat "$st/calls")"; return; }
  [ "$(cat "$st/calls")" = "enroll KEY-B" ] || { echo "B not enrolled alone: $(cat "$st/calls") $(cat "$d/out")"; return; }
  [ "$(cat "$d/root/$record")" = "0 $(fp KEY-A)
2 $(fp KEY-B)" ] || { echo "the record: $(cat "$d/root/$record")"; return; }
  [ "$(cat "$d/root/run/nyra-tpm2-keep")" = "$(fp KEY-A)
$(fp KEY-B)" ] || { echo "the keys kept: $(cat "$d/root/run/nyra-tpm2-keep")"; return; }
  echo ok
}
# d. A refusal on a version signed with C, which the record says was retired.
case_retired() { # case_retired SCRIPT
  local d
  d="$(mktemp -d -p "$t")"
  setup "$d" typed KEY-C
  local st="$d/root/state"
  mkdir -p "$d/root/sysroot/var/lib/nyra"
  printf '0 %s\nretired %s\n' "$(fp KEY-B)" "$(fp KEY-C)" > "$d/root/$record"
  run "$1" "$d"
  grep -q '^\(wipe\|enroll\)' "$st/calls" && { echo "enrolled again for a retired key: $(cat "$st/calls")"; return; }
  echo ok
}
# e. tpm-retire on a version signed with B, whose next key is C, and the record of A, B and C; or on
#    version A (next B) after a fallback.
case_retire() { # case_retire SCRIPT with-B|without-B|fallback
  local d
  d="$(mktemp -d -p "$t")"
  setup "$d" tpm
  local st="$d/root/state" r="$d/root/var/lib/nyra/tpm2-slots"
  printf '%s\n%s\n' "$(fp KEY-B)" "$(fp KEY-C)" > "$d/root/run/nyra-tpm2-keep"
  if [ "$2" = fallback ]; then
    printf '%s\n%s\n' "$(fp KEY-A)" "$(fp KEY-B)" > "$d/root/run/nyra-tpm2-keep"
    printf '0 %s\n1 %s\n2 %s\n' "$(fp KEY-A)" "$(fp KEY-B)" "$(fp KEY-C)" > "$r"
    run "$1" "$d"
    grep -q '^wipe' "$st/calls" && { echo "removed a newer enrollment: $(cat "$st/calls")"; return; }
    echo ok
    return
  fi
  if [ "$2" = with-B ]; then
    printf '0 %s\n1 %s\n2 %s\n' "$(fp KEY-A)" "$(fp KEY-B)" "$(fp KEY-C)" > "$r"
  else
    printf '0 %s\n2 %s\n' "$(fp KEY-A)" "$(fp KEY-C)" > "$r"
  fi
  run "$1" "$d"
  if [ "$2" = without-B ]; then
    grep -q '^wipe' "$st/calls" && { echo "removed with no enrollment for the booted key: $(cat "$st/calls")"; return; }
    echo ok
    return
  fi
  [ "$(cat "$st/calls")" = "wipe 0" ] || { echo "not A's slot alone removed: $(cat "$st/calls") $(cat "$d/out")"; return; }
  [ "$(cat "$r")" = "1 $(fp KEY-B)
2 $(fp KEY-C)
retired $(fp KEY-A)" ] || { echo "the record: $(cat "$r")"; return; }
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
check "a newer key's enrollment kept on a fallback" ok "$(case_retire "$retire" fallback)"

# The same cases without the checks they rely on must fail.
mutant no-inroot "$enroll" 's/inroot && //g'
check "without the path check, first boot" fails "$(case_link "$t/no-inroot" first)"
check "without the path check, after a refusal" fails "$(case_link "$t/no-inroot" typed)"
mutant no-opened "$enroll" 's/ | grep -vxF "\$opened"//'
check "without excluding the typed key's slot" fails "$(case_slot "$t/no-opened")"
mutant no-retired "$enroll" 's/^elif retired "\$curfp"; then$/elif false; then/'
check "without the retired-key check" fails "$(case_retired "$t/no-retired")"
mutant no-current "$retire" 's/^grep -q "^\[0-9\]\[0-9\]\* \$current\\\$" "\$record" || exit 0$/true/'
check "tpm-retire without the booted key's check" fails "$(case_retire "$t/no-current" without-B)"
mutant no-order "$retire" 's/^old="\$(sed -n .*$/old="$(grep "^[0-9][0-9]* " "$record" | grep -v -F -f "$keep" || true)"/'
check "tpm-retire without the order of the record" fails "$(case_retire "$t/no-order" fallback)"

[ "$fail" = 0 ] && echo "test-tpm-enroll: passed"
exit "$fail"
