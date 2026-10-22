#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Offline test of the first administrator (docs/BOOT.md, "The first administrator"), without a VM: the
# real files/usr/lib/nyra/first-admin and the real admin-record step of tools/install/in-image.sh run in
# a mount namespace, chrooted into a directory that has an /etc of its own (a few system accounts, a
# group sudo, the host's login.defs, no password anywhere) and the host's /usr, so useradd, chpasswd,
# systemd-firstboot and stat are the real ones. Needs root with any user and group IDs (sudo, or podman
# unshare). What it checks:
#   a. admin-record: a good name and password give NAME:HASH, a yescrypt hash that the password opens
#      (unix_chkpwd) and another does not, mode 0600; a name that is not one the installer takes, a name
#      of the system, and a password that is too short, too long, not printable ASCII or empty are
#      refused (exit 4) and write nothing; the password is in no process's arguments while it runs
#      (the search is shown to find a string given on a command line), in no output, and the throwaway
#      account stays in the container's /etc, not in the file;
#   b. first-admin: the account exists in the group sudo with the hash of the file and a home directory,
#      root is as it was (locked), nobody has an empty password, the file is gone, the fixed defaults
#      (en_US.UTF-8, the US keyboard, UTC, the host name nyra) are set, settings that were already there
#      are kept, and the password opens the account;
#   c. first-admin refuses, and removes the file, and still sets the defaults: a file with another mode,
#      owner or link count, a link, a directory, a directory only root can write to, a file of two lines,
#      without its end of line, with a carriage return, with a NUL byte or too long, an empty, locked
#      ("!", "*") or other kind of hash (SHA-512, a yescrypt hash cut short), a name that is not one the
#      installer takes, root, an account, a group, a name that sysusers.d declares, and an account that
#      exists already (the file used twice);
#   d. reserved-names: the names of this image, one per line, only names an administrator could choose;
#   e. the refusals of c that one check alone is responsible for are proven: the same file run through a
#      copy of first-admin without that check (or with it loosened) makes the account, which the case
#      would see: the mode, owner and link count, the kind of file, the directory, the end of the line
#      and the NUL byte, the kind of hash, and the names that sysusers.d declares. The others (a second
#      line, a carriage return, a long file, a name that useradd refuses by itself) have a second
#      defence, in the program or in the check next to it.
#   tools/vm/test-first-admin.sh
set -euo pipefail

# The roots below bind the host's /usr: they live in a mount namespace of their own, which takes its
# mounts with it when the test ends, and they are removed only by the shell outside it, after that. (A
# bind mount is on the host's device: rm --one-file-system would walk into /usr.)
if [ "${NYRA_TEST_NS:-}" != 1 ]; then
  [ "$(id -u)" = 0 ] || { echo "test-first-admin: needs root (sudo, or podman unshare)" >&2; exit 77; }
  work="$(mktemp -d)"
  trap 'rm -rf --one-file-system "$work"' EXIT
  unshare -m env NYRA_TEST_NS=1 NYRA_TEST_DIR="$work" "$(readlink -f "$0")" && exit 0 || exit $?
fi
cd "$(dirname "$0")/../.."
[ "$(readlink /proc/self/ns/mnt)" != "$(readlink "/proc/$PPID/ns/mnt" 2> /dev/null || echo unknown)" ] \
  || { echo "test-first-admin: NYRA_TEST_NS=1 outside a mount namespace of its own" >&2; exit 1; }
mount --make-rprivate /
for tool in useradd chpasswd systemd-firstboot unix_chkpwd stat; do
  command -v "$tool" > /dev/null || [ -x "/usr/sbin/$tool" ] || { echo "test-first-admin: no $tool"; exit 77; }
done

chpasswd --help 2>&1 | grep -q YESCRYPT || { echo "test-first-admin: this chpasswd has no yescrypt"; exit 77; }

t="$(readlink -f "$NYRA_TEST_DIR")"
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

script="$PWD/files/usr/lib/nyra/first-admin"
inimage="$PWD/tools/install/in-image.sh"
pw='Sentinel-pw 4711 x'
name=maria
n_roots=0

# root DIR: a root file system in DIR for one case: the host's /usr, an /etc with a few accounts.
mkroot() {
  local r slug
  slug="$(printf '%s' "$1" | tr -c 'A-Za-z0-9_-' _)"
  r="$t/$((++n_roots))-$slug"
  mkdir -p "$r"/{etc/default,etc/skel,var/lib/nyra,usr,dev,proc,tmp,run,nyra-install}
  for l in bin lib lib64 sbin; do ln -s "usr/$l" "$r/$l"; done
  mount --bind /usr "$r/usr"
  # systemd-firstboot reads the kernel command line (the host's, here).
  mount --rbind /proc "$r/proc"
  for d in null urandom; do : > "$r/dev/$d" && mount --bind "/dev/$d" "$r/dev/$d"; done
  printf 'root:x:0:0:root:/root:/bin/bash\ndaemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin\nnobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin\n' > "$r/etc/passwd"
  printf 'root:*:20000:0:99999:7:::\ndaemon:*:20000:0:99999:7:::\nnobody:*:20000:0:99999:7:::\n' > "$r/etc/shadow"
  printf 'root:x:0:\ndaemon:x:1:\nsudo:x:27:\nusers:x:100:\nnogroup:x:65534:\n' > "$r/etc/group"
  printf 'root:*::\ndaemon:*::\nsudo:*::\nusers:*::\nnogroup:*::\n' > "$r/etc/gshadow"
  : > "$r/etc/subuid"
  : > "$r/etc/subgid"
  chmod 0640 "$r/etc/shadow" "$r/etc/gshadow"
  printf 'passwd: files\ngroup: files\nshadow: files\n' > "$r/etc/nsswitch.conf"
  cp /etc/login.defs "$r/etc/login.defs"
  # HOME as the image has it (Containerfile): /var/home.
  printf 'GROUP=100\nHOME=/var/home\nINACTIVE=-1\nEXPIRE=\nSHELL=/bin/sh\nSKEL=/etc/skel\nCREATE_MAIL_SPOOL=no\n' > "$r/etc/default/useradd"
  cp "$script" "$r/script"
  for m in "$t"/mutant-*; do [ ! -e "$m" ] || cp "$m" "$r/"; done
  cp "$inimage" "$r/nyra-install/in-image.sh"
  sed -i "s|^first_admin=.*|first_admin=/script|" "$r/nyra-install/in-image.sh"
  root="$r"
}
# in_root CMD...: a command in the root, with nothing from the environment but a path.
in_root() { chroot "$root" /usr/bin/env -i PATH=/usr/sbin:/usr/bin "$@"; }
# the line of a file of the root, or nothing
shadow() { grep "^$1:" "$root/etc/shadow" || true; }

# --- a. admin-record -------------------------------------------------------------------------------
mkroot rec
rec_root="$root"
rec() { # rec NAME PASSWORD-INPUT: sets rc and out; the password is the standard input as given
  printf '%s' "$2" | in_root bash /nyra-install/in-image.sh admin-record "$1" /out > "$t/out" 2>&1 && rc=0 || rc=$?
  out="$(cat "$t/out")"
}
: > "$root/out"
# The sampler: every process's arguments, 20 ms apart, until it is killed. The control shows it sees one.
sample() { ( while :; do ps -eww -o args=; sleep 0.02; done > "$1" ) & sampler=$!; }
sample "$t/ps-control"
sleep 0.3
bash -c 'sleep 1; :' control "$pw" &
control=$!
sleep 0.5
kill "$sampler"; wait "$sampler" 2> /dev/null || true
wait "$control"
grep -qF -- "$pw" "$t/ps-control" || fail "the search in the processes' arguments does not find a string on a command line"
echo "control: the search finds a password given on a command line"
sample "$t/ps"
sleep 0.3
rec "$name" "$pw
"
kill "$sampler"; wait "$sampler" 2> /dev/null || true
[ "$rc" = 0 ] || { echo "$out"; fail "admin-record of a good name and password: $rc"; }
! grep -qF -- "$pw" "$t/ps" || fail "the password was in a process's arguments"
! grep -qF -- "$pw" "$t/out" || fail "the password was in the output of admin-record"
record="$(cat "$root/out")"
[[ "$record" =~ ^maria:\$y\$[./A-Za-z0-9]+\$[./A-Za-z0-9]+\$[./A-Za-z0-9]{43}$ ]] || fail "the record is not NAME:yescrypt-hash: $record"
[ "$(stat -c %a "$root/out")" = 600 ] || fail "the record is not 0600"
! grep -qF -- "$pw" "$root/out" || fail "the password is in the record"
echo "admin-record: NAME:HASH, yescrypt, mode 0600, the password in no process's arguments, output or file"
# The password opens the hash and another does not (the PAM helper, as root, on an account made from it).
mkroot chk
printf '%s\n' "$record" > "$root/var/lib/nyra/first-admin"
chmod 0600 "$root/var/lib/nyra/first-admin"
in_root bash /script || fail "first-admin refused the record that admin-record made"
opens() { printf '%s\0' "$1" | in_root /usr/sbin/unix_chkpwd "$name" nullok > /dev/null 2>&1; }
opens "$pw" || fail "the password does not open the account made from the record"
! opens "${pw}x" || fail "a wrong password opens the account"
! opens "" || fail "an empty password opens the account"
echo "admin-record: the password opens the account made from its record, a wrong or empty one does not"
# (The name of the password rules' cases is one that does not exist in the root: with maria there, a
# password rule that is missing or loose would still be refused, for the name.)
refused_rec() { # refused_rec WHAT NAME PASSWORD: exit 4 and no record
  root="$rec_root"
  : > "$root/out"
  rec "$2" "$3"
  [ "$rc" = 4 ] || { echo "$out"; fail "admin-record, $1: exit $rc, not 4"; }
  [ ! -s "$root/out" ] || fail "admin-record, $1: wrote a record"
  [ -z "$3" ] || ! grep -qF -- "$3" "$t/out" || fail "admin-record, $1: the password is in the output"
  echo "admin-record refuses: $1"
}
refused_rec "a short password" carol "short pw 1"
refused_rec "a long password" carol "$(printf 'a%.0s' $(seq 65))"
refused_rec "a password that is not ASCII" carol "Sentinel-pässword-4711"
refused_rec "a password with a tab" carol $'Sentinel\t-pw-4711-x'
refused_rec "an empty password" carol ""
refused_rec "a password equal to the name" carol-carol-12 carol-carol-12
refused_rec "an uppercase name" "Maria" "$pw"
refused_rec "a name with a dot" "ma.ria" "$pw"
refused_rec "a name that starts with a digit" "1maria" "$pw"
refused_rec "a name of 33 characters" "a$(printf 'b%.0s' $(seq 32))" "$pw"
refused_rec "the name root" root "$pw"
refused_rec "the name of an account" daemon "$pw"
refused_rec "the name of a group" sudo "$pw"
refused_rec "a name declared by sysusers.d" systemd-network "$pw"
mkroot rec3
: > "$root/out"
rec "$name" "$(printf 'a%.0s' $(seq 64))"
[ "$rc" = 0 ] || fail "a password of 64 characters is refused ($rc)"
rec "x" "$(printf 'a%.0s' $(seq 12))"
[ "$rc" = 0 ] || fail "a password of 12 characters and a name of one letter are refused ($rc)"
echo "admin-record: 12 and 64 characters are taken"

# --- b. first-admin, a good file --------------------------------------------------------------------
# setup NAME: a root with the record of a good administrator as the installer leaves it.
setup() {
  mkroot "$1"
  printf '%s\n' "${2:-$record}" > "$root/var/lib/nyra/first-admin"
  chmod 0600 "$root/var/lib/nyra/first-admin"
}
run() { # run [SCRIPT]: first-admin in the root; sets rc, out
  in_root bash "${1:-/script}" > "$t/out" 2>&1 && rc=0 || rc=$?
  out="$(cat "$t/out")"
}
setup good
root_before="$(shadow root)"
run
[ "$rc" = 0 ] || { echo "$out"; fail "first-admin of a good file: $rc"; }
[ "$(shadow "$name" | cut -d: -f2)" = "${record#*:}" ] || fail "the hash of the account is not the file's"
[[ "$(grep "^$name:" "$root/etc/passwd")" =~ ^maria:x:(1[0-9]{3}):(1[0-9]{3}):[^:]*:/var/home/maria:/bin/bash$ ]] \
  || fail "the account is not a regular user with its home in /var/home: $(grep "^$name:" "$root/etc/passwd")"
in_root id -nG "$name" | tr ' ' '\n' | grep -qx sudo || fail "the account is not in the group sudo"
# (shadow 4.13, Ubuntu's, prints "useradd: warning: chown on /var/home/maria failed" in this root and
# still gives the home to the account, which is what is checked.)
[ "$(stat -c %u "$root/var/home/$name")" = "${BASH_REMATCH[1]}" ] || fail "the home directory is not the account's"
[ ! -e "$root/var/lib/nyra/first-admin" ] || fail "the file is still there"
[ "$(shadow root)" = "$root_before" ] && [[ "$root_before" =~ ^root:\* ]] || fail "root is not as it was, locked"
! cut -d: -f2 "$root/etc/shadow" | grep -qx '' || fail "an account has an empty password"
[ "$(cat "$root/etc/hostname")" = nyra ] || fail "the host name is not nyra"
grep -qx 'LANG=en_US.UTF-8' "$root/etc/locale.conf" || fail "the locale is not en_US.UTF-8"
# The keymap is written only where the keymap us is installed (the host's /usr, here).
if [ -e "$root/etc/vconsole.conf" ]; then
  grep -qx 'KEYMAP=us' "$root/etc/vconsole.conf" || fail "the keyboard is not US"
else
  grep -q 'no keymap us' "$t/out" || fail "no keymap installed, and first-admin does not say so"
fi
# What the system reads is /etc/localtime, a link into the tz database; the database's layout is the
# host's (the link may name UTC or Etc/UTC), so the file it leads to is compared with the database's UTC.
[ -L "$root/etc/localtime" ] && [[ "$(readlink "$root/etc/localtime")" == */UTC ]] \
  && in_root cmp /etc/localtime /usr/share/zoneinfo/UTC || fail "the time zone is not UTC"
opens "$pw" || fail "the password does not open the account"
! grep -qF -- "$pw" "$t/out" || fail "the password is in the output"
echo "first-admin: the account in sudo with the file's hash and a home, root locked, no empty password, the file gone, the fixed defaults set, the password opens it"
# A second run, with the file made again: the account exists, nothing changes.
before="$(shadow "$name")"
printf '%s\n' "$record" > "$root/var/lib/nyra/first-admin"
chmod 0600 "$root/var/lib/nyra/first-admin"
run
[ "$rc" != 0 ] && [ ! -e "$root/var/lib/nyra/first-admin" ] && [ "$(shadow "$name")" = "$before" ] \
  && [ "$(grep -c "^$name:" "$root/etc/passwd")" = 1 ] || fail "an account that exists was made again or the file stayed ($rc)"
echo "first-admin: a file for an account that exists is refused and removed, the account is as it was"
# Settings that were there are kept.
setup kept
echo mine > "$root/etc/hostname"
printf 'LANG=de_DE.UTF-8\n' > "$root/etc/locale.conf"
ln -s ../usr/share/zoneinfo/Europe/Bucharest "$root/etc/localtime"
run
[ "$rc" = 0 ] && [ "$(cat "$root/etc/hostname")" = mine ] && grep -qx 'LANG=de_DE.UTF-8' "$root/etc/locale.conf" \
  && [ "$(readlink "$root/etc/localtime")" = ../usr/share/zoneinfo/Europe/Bucharest ] || fail "settings that were there were overwritten"
echo "first-admin: a host name, locale and time zone that were set are kept"
# Names with the other characters the installer takes.
for n in a x-y_z0 abcdefghijklmnopqrstuvwxyz012345; do
  rec_name="$n:${record#*:}"
  setup "n-$n" "$rec_name"
  run
  [ "$rc" = 0 ] && [ -n "$(shadow "$n")" ] || { echo "$out"; fail "the name $n is refused ($rc)"; }
done
echo "first-admin: a name of one letter, with - and _ and digits, of 32 characters"

# --- c. first-admin refuses -------------------------------------------------------------------------
good_hash="${record#*:}"
after_refusal() { # after_refusal WHAT: refused, the file gone, no new account, the defaults set
  [ "$rc" != 0 ] || { echo "$out"; fail "$1: not refused"; }
  [ ! -e "$root/var/lib/nyra/first-admin" ] && [ ! -L "$root/var/lib/nyra/first-admin" ] || fail "$1: the file is still there"
  [ "$(wc -l < "$root/etc/passwd")" = 3 ] && [ "$(wc -l < "$root/etc/shadow")" = 3 ] || fail "$1: an account was made"
  [ ! -e "$root/var/home" ] || [ -z "$(ls -A "$root/var/home")" ] || fail "$1: a home directory was made"
  [ "$(cat "$root/etc/hostname")" = nyra ] || fail "$1: the defaults were not set"
}
# refuse WHAT PREPARATION: a root with a good file, then PREPARATION (a function) changes it; first-admin,
# and with MUTANT (a copy of the script without a check, if given) the same case must make the account.
refuse() {
  local what="$1" prep="$2" mutant="${3:-}"
  setup "r-$what"
  "$prep"
  run
  after_refusal "$what"
  echo "first-admin refuses: $what"
  if [ -n "$mutant" ]; then
    setup "m-$what"
    "$prep"
    run "/mutant-$mutant"
    [ "$rc" = 0 ] && [ "$(wc -l < "$root/etc/passwd")" = 4 ] \
      || { echo "$out"; fail "$what: the script without the check '$mutant' still refuses: the case proves nothing"; }
  fi
}
f() { echo "$root/var/lib/nyra/first-admin"; }
# The copies of the script without one check (or with a check made loose), in every root made after this.
# A sed that changes nothing is an error.
mutant() { # mutant NAME SED-EXPRESSION...
  local n="$1" args=() e
  shift
  for e in "$@"; do args+=(-e "$e"); done
  sed "${args[@]}" "$script" > "$t/mutant-$n"
  ! cmp -s "$script" "$t/mutant-$n" || fail "the mutant $n is the script"
}
mutant mode '/^read -ra lsl/,/is not owned by root, mode 0600, with one link"$/d'
mutant file '/\[ -f "\$file" \] && \[ ! -L "\$file" \]/d' '/^read -ra lsl/,/is not owned by root, mode 0600, with one link"$/d' '/is not exactly one line/d'
mutant dir "/is not root.s alone/d"
mutant lines '/is not exactly one line/d'
mutant regexloose "s/^re=.*/re='^([a-z][a-z0-9_-]{0,31}):(.*)\$'/"
mutant reserved '/^if grep -qxF -- "\$name" <<< "\$names"; then/,/^fi$/d'

prep_mode() { chmod 0644 "$(f)"; }
refuse "a file of mode 0644" prep_mode mode
prep_mode2() { chmod 0660 "$(f)"; }
refuse "a file of mode 0660" prep_mode2 mode
prep_exec() { chmod 0700 "$(f)"; }
refuse "a file of mode 0700" prep_exec mode
prep_owner() { chown 1:1 "$(f)"; }
refuse "a file of another owner" prep_owner mode
prep_link2() { ln "$(f)" "$root/var/lib/nyra/other"; }
refuse "a file with two links" prep_link2 mode
prep_symlink() { mv "$(f)" "$root/var/lib/nyra/real"; ln -s real "$(f)"; }
refuse "a link to a good file" prep_symlink file
prep_dir() { rm "$(f)"; mkdir "$(f)"; }
setup "r-dir"
prep_dir
run
[ "$rc" != 0 ] && [ -d "$(f)" ] && [ "$(wc -l < "$root/etc/passwd")" = 3 ] || fail "a directory in place of the file: made an account or not refused"
echo "first-admin refuses: a directory in place of the file"
prep_dirw() { chmod 0777 "$root/var/lib/nyra"; }
refuse "a directory that anyone can write to" prep_dirw dir
prep_dirg() { chmod 0775 "$root/var/lib/nyra"; }
refuse "a directory that its group can write to" prep_dirg dir
prep_dirowner() { chown 1:1 "$root/var/lib/nyra"; }
refuse "a directory of another owner" prep_dirowner dir
prep_two() { printf '%s\nsecond:%s\n' "$record" "$good_hash" > "$(f)"; }
refuse "a file of two lines" prep_two
prep_noeol() { printf '%s' "$record" > "$(f)"; }
refuse "a file without the end of its line" prep_noeol lines
prep_crlf() { printf '%s\r\n' "$record" > "$(f)"; }
refuse "a line that ends with a carriage return" prep_crlf
prep_nul() { { printf '%s' "$record"; printf '\0\n'; } > "$(f)"; }
refuse "a NUL byte" prep_nul lines
prep_long() { printf '%s:%s%s\n' "$name" "$good_hash" "$(printf 'a%.0s' $(seq 300))" > "$(f)"; }
refuse "a file of more than 256 bytes" prep_long
prep_empty() { printf '%s:\n' "$name" > "$(f)"; }
refuse "an empty hash" prep_empty regexloose
prep_bang() { printf '%s:!\n' "$name" > "$(f)"; }
refuse "a locked hash (!)" prep_bang regexloose
prep_star() { printf '%s:*\n' "$name" > "$(f)"; }
refuse "a locked hash (*)" prep_star regexloose
prep_sha() { printf '%s:$6$saltsalt$%s\n' "$name" "$(printf 'A%.0s' $(seq 86))" > "$(f)"; }
refuse "a SHA-512 hash" prep_sha regexloose
prep_short() { printf '%s:%s\n' "$name" "${good_hash%?}" > "$(f)"; }
refuse "a yescrypt hash cut short" prep_short regexloose
prep_nohash() { printf '%s\n' "$name" > "$(f)"; }
refuse "a name without a hash" prep_nohash
prep_badchar() { printf '%s:%s\n' "$name" "${good_hash%?}:" > "$(f)"; }
refuse "a hash with a colon" prep_badchar
prep_upper() { printf 'Maria:%s\n' "$good_hash" > "$(f)"; }
refuse "an uppercase name" prep_upper
prep_digit() { printf '1maria:%s\n' "$good_hash" > "$(f)"; }
refuse "a name that starts with a digit" prep_digit
prep_root() { printf 'root:%s\n' "$good_hash" > "$(f)"; }
refuse "the name root" prep_root
prep_daemon() { printf 'daemon:%s\n' "$good_hash" > "$(f)"; }
refuse "the name of an account" prep_daemon
prep_group() { printf 'sudo:%s\n' "$good_hash" > "$(f)"; }
refuse "the name of a group" prep_group
prep_sysusers() { printf 'systemd-network:%s\n' "$good_hash" > "$(f)"; }
refuse "a name that sysusers.d declares" prep_sysusers reserved
prep_missing() { rm "$(f)"; }
setup "r-missing"
prep_missing
run
after_refusal "no file"
echo "first-admin refuses: no file (and the defaults are set)"
setup "r-arg"
in_root bash /script extra > "$t/out" 2>&1 && rc=0 || rc=$?
[ "$rc" = 2 ] || fail "an argument: $rc"
echo "first-admin refuses: an argument"

# --- d. reserved-names ------------------------------------------------------------------------------
setup names
in_root bash /script reserved-names > "$t/names" 2> "$t/err" || fail "reserved-names failed"
[ ! -s "$t/err" ] || fail "reserved-names wrote on stderr"
[ ! -e "$root/etc/hostname" ] && [ -e "$root/var/lib/nyra/first-admin" ] || fail "reserved-names changed the system"
for n in root daemon nobody sudo users nogroup systemd-network; do
  grep -qx "$n" "$t/names" || fail "reserved-names has not $n"
done
! grep -vqE '^[a-z][a-z0-9_-]{0,31}$' "$t/names" || fail "reserved-names has a line that no administrator could choose"
[ "$(LC_ALL=C sort -u "$t/names")" = "$(cat "$t/names")" ] || fail "reserved-names is not sorted, without repeats"
echo "reserved-names: the accounts, groups and sysusers.d names of the root, sorted, one per line, nothing else"
echo "ok"
