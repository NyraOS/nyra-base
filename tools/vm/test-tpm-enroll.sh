#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Offline test of /usr/lib/nyra/boot/tpm-enroll (docs/BOOT.md, "Disk encryption"), without a VM, a TPM
# or a disk. The real script, unchanged, runs in a mount namespace, chrooted into a directory where the
# paths it uses are stand-ins (/dev/gpt-auto-root-luks, /dev/tpmrm0, the Secure Boot variables, PCR 12,
# /.extra, /sysroot) and /usr is the host's, with stand-ins for cryptsetup, systemd-cryptenroll and
# keyctl first on PATH that keep the key slots in a file and log what they are asked to do. Checks:
#   a. a symbolic link on the path of the enrollment's record (inside the root's /var, which belongs to
#      the running system) stops the script: nothing is written outside that /var, on the first boot
#      as after a refusal, and no key slot is removed;
#   b. after a refusal, the key slot that the typed key opens (here the recovery key's) is never
#      removed, even when the record lists it; the other listed slot is.
# Each check is proven: the same case run on a copy of the script without the check it relies on
# must fail. The namespace: unshare -rm (a user namespace) where allowed, else sudo unshare -m.
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
script="$(dirname "$0")/../../files/usr/lib/nyra/boot/tpm-enroll"
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
  *) exit 1 ;;
esac
EOF
cat > "$t/bin/systemd-cryptenroll" <<'EOF'
#!/bin/bash
case "$*" in
  *--wipe-slot=tpm2*--tpm2-device*|*--tpm2-device*--wipe-slot=tpm2*)
    echo "enroll, wipe tpm2" >> "$T/calls"; echo "2 tpm2" >> "$T/slots" ;;
  *--tpm2-device*)
    echo "enroll" >> "$T/calls"; echo "2 tpm2" >> "$T/slots" ;;
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

setup() { # setup DIR FIRST(yes|no): a fresh root with Secure Boot on, a TPM and a clean PCR 12; the
  # stand-ins' state (slots, header, recovery key, cache, calls) in DIR, which is /state in the root
  local d="$1"
  mkdir -p "$d/root/dev" "$d/root/sys/firmware/efi/efivars" "$d/root/sys/class/tpm/tpm0/pcr-sha256" \
    "$d/root/.extra" "$d/root/sysroot/state/os/default/var" "$d/root/outside" "$d/root/usr" "$d/root/stubs" \
    "$d/root/state" "$d/root/tmp"
  for l in bin lib lib64 sbin; do ln -s "usr/$l" "$d/root/$l"; done
  mount --bind /usr "$d/root/usr" && mount -o remount,bind,ro "$d/root/usr"
  : > "$d/root/dev/null" && mount --bind /dev/null "$d/root/dev/null"
  cp "$t/bin"/* "$d/root/stubs/"
  : > "$d/root/dev/gpt-auto-root-luks"
  : > "$d/root/dev/tpmrm0"
  printf '\x06\x00\x00\x00\x01' > "$d/root/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
  printf '\x06\x00\x00\x00\x00' > "$d/root/sys/firmware/efi/efivars/SetupMode-8be4df61-93ca-11d2-aa0d-00e098032b8c"
  echo 3345A4E7857AA5AE65E97702ADE84A3755FD6144724779536B5773128676C99C > "$d/root/sys/class/tpm/tpm0/pcr-sha256/12"
  local st="$d/root/state"
  printf 'cbdefghi-jklnrtuv' > "$st/recovery-key"
  : > "$st/calls"
  printf '0 tpm2\n1 recovery\n' > "$st/slots"
  if [ "$2" = yes ]; then
    printf '{"tokens":{"0":{"type":"systemd-tpm2","tpm2-policy-hash": "%064d"}}}\n' 0 > "$st/header.json"
  else
    printf '{"tokens":{"0":{"type":"systemd-tpm2","tpm2-policy-hash": "%s"}}}\n' "$(printf 'ab%.0s' $(seq 32))" > "$st/header.json"
    cp "$st/recovery-key" "$st/cache" # the user typed the recovery key
  fi
}
run() { # run SCRIPT DIR: the script at /tpm-enroll in DIR's root, with only the stand-ins' PATH
  cp "$1" "$2/root/tpm-enroll"
  chroot "$2/root" /usr/bin/env -i PATH=/stubs:/usr/bin:/usr/sbin T=/state /bin/sh /tpm-enroll \
    > "$2/out" 2>&1 || true
}

# a. A symbolic link on the record's path: var/lib points outside the root's /var.
case_link() { # case_link SCRIPT FIRST: "ok" or what went wrong
  local d
  d="$(mktemp -d -p "$t")"
  setup "$d" "$2"
  local st="$d/root/state" out="$d/root/outside"
  mkdir -p "$out/nyra"
  [ "$2" = yes ] || printf '0\n' > "$out/nyra/tpm2-slots"
  ln -s /outside "$d/root/sysroot/state/os/default/var/lib"
  local before
  before="$(find "$out" -type f -exec md5sum {} + | sort)"
  run "$1" "$d"
  if [ "$(find "$out" -type f -exec md5sum {} + | sort)" != "$before" ]; then echo "written outside the root's /var"; return; fi
  if grep -q '^wipe' "$st/calls"; then echo "a key slot removed: $(grep '^wipe' "$st/calls")"; return; fi
  if [ "$2" = no ] && grep -q '^enroll' "$st/calls"; then echo "enrolled again through a link"; return; fi
  [ "$2" = yes ] || grep -q "^invalidate" "$st/calls" || { echo "the typed key left in the cache"; return; }
  echo ok
}
# b. The record lists the recovery key's slot (1), which the typed key opens, and the old TPM slot (0).
case_slot() { # case_slot SCRIPT: "ok" or what went wrong
  local d
  d="$(mktemp -d -p "$t")"
  setup "$d" no
  local st="$d/root/state"
  mkdir -p "$d/root/sysroot/state/os/default/var/lib/nyra"
  printf '0\n1\n' > "$d/root/sysroot/state/os/default/var/lib/nyra/tpm2-slots"
  run "$1" "$d"
  if grep -q '^wipe.*1' "$st/calls"; then echo "the typed key's slot removed: $(grep '^wipe' "$st/calls")"; return; fi
  grep -qx 'wipe 0' "$st/calls" || { echo "the old TPM slot not removed: $(cat "$st/calls") $(cat "$d/out")"; return; }
  grep -qx 'enroll' "$st/calls" || { echo "not enrolled again: $(cat "$d/out")"; return; }
  [ "$(cat "$d/root/sysroot/state/os/default/var/lib/nyra/tpm2-slots")" = 2 ] || { echo "the record is not the new slot"; return; }
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
check "a symbolic link on the record's path, first boot" ok "$(case_link "$script" yes)"
check "a symbolic link on the record's path, after a refusal" ok "$(case_link "$script" no)"
check "the typed key's slot listed in the record" ok "$(case_slot "$script")"

# The same cases without the checks they rely on must fail.
sed 's/inroot && //g' "$script" > "$t/no-inroot"
check "without the path check, first boot" fails "$(case_link "$t/no-inroot" yes)"
check "without the path check, after a refusal" fails "$(case_link "$t/no-inroot" no)"
sed 's/grep -vxF "\$opened" "\$record"/cat "$record"/' "$script" > "$t/no-opened"
! cmp -s "$script" "$t/no-opened" || { echo "test-tpm-enroll: the mutation did not apply"; exit 1; }
check "without excluding the typed key's slot" fails "$(case_slot "$t/no-opened")"

[ "$fail" = 0 ] && echo "test-tpm-enroll: passed"
exit "$fail"
