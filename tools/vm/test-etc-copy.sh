#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Offline test of files/usr/lib/nyra/etc-copy (docs/BOOT.md, "Restore earlier settings"). Exits
# non-zero when any case fails.
#   1. Which copies of /etc a run removes (to-remove): the clock right, far ahead, behind, corrected
#      after being ahead, a month off, the three newest kept, and the 30-day boundary.
#   2. A copy and its restore (make, apply), on small trees in a temporary directory: an old image's
#      /etc, the user's /etc made from it (a file edited; others with another mode, owner, ACL or
#      extended attribute; a file and a directory removed; a directory turned into a file and a file
#      into a directory; a link pointed elsewhere; a new setgid directory; a new file in a directory
#      of the image; a name with a space and a newline; the image's link to a directory outside
#      turned into a directory with the same file and one of the user's), and a newer image's /etc (a
#      default changed, one added, two directories turned into links to directories outside it, the
#      edited file into a link to a file outside it). The copy holds only
#      what differs and lists what was removed; laid over the newer image, it gives that image's
#      defaults plus exactly the user's changes, with every owner, mode, ACL and extended attribute,
#      and writes nothing outside through those links. A copy of an unchanged /etc gives the newer
#      image as it is, and a copy with the image's /etc as /etc itself is refused. A list of what was
#      removed that names links with a trailing slash removes nothing through them.
#      Each check of etc-copy is proven: the same case run on a copy of the script without it fails.
#      Needs root, with any user and group IDs (sudo, or podman unshare), and python3 (to set and read
#      an ACL and extended attributes).
#   tools/vm/test-etc-copy.sh   (ETC_COPY=PATH tests another copy of the script)
set -euo pipefail

etc_copy="${ETC_COPY:-files/usr/lib/nyra/etc-copy}"
fail=0
at() { date -u -d "@$(($(date -u -d "$1" +%s) - $2))" +%Y-%m-%dT%H:%M:%SZ; } # at DATE SECONDS-BEFORE
day=86400
real=2026-10-16T03:00:00Z
# 21 daily copies of the last 21 days, and 5 from 31-35 days before the last one.
recent="$(for d in $(seq 0 20); do echo "$(at $real $((d * day)))-daily"; done)"
older="$(for d in $(seq 31 35); do echo "$(at $real $((d * day)))-update"; done)"
# check TITLE NOW NEW SYNCED EXPECTED NAMES: what a run removes, of NAMES (one per line), is EXPECTED.
check() {
  local got want
  got="$(printf '%s\n' "$6" | sh "$etc_copy" to-remove "$2" "$3" "$4" | sort)"
  want="$(printf '%s' "$5" | sort)"
  if [ "$got" = "$want" ]; then
    echo "ok: $1"
  else
    echo "FAIL: $1"
    echo "  expected: $(echo "$want" | tr '\n' ' ')"
    echo "  got: $(echo "$got" | tr '\n' ' ')"
    fail=1
  fi
}

new=2026-10-16T03:00:05Z
check "right clock: only the copies older than 30 days" "$new" "$new-daily" yes "$older" \
  "$(printf '%s\n%s\n%s\n.lock\n.new-x' "$recent" "$older" "$new-daily")"

new=2099-06-01T00:00:00Z
check "clock in 2099, not synchronised: the same, none of the last 30 days" "$new" "$new-daily" no "$older" \
  "$(printf '%s\n%s\n%s' "$recent" "$older" "$new-daily")"

new=2020-01-01T00:00:00Z
check "clock behind every copy, not synchronised: nothing" "$new" "$new-daily" no "" \
  "$(printf '%s\n%s\n%s' "$recent" "$older" "$new-daily")"

new=2026-10-17T03:00:00Z
check "clock right again and synchronised: the copy dated 2099 goes too" "$new" "$new-daily" yes \
  "$(printf '%s\n%s' "$older" "2099-06-01T00:00:00Z-daily")" \
  "$(printf '%s\n%s\n%s\n%s' "$recent" "$older" "2099-06-01T00:00:00Z-daily" "$new-daily")"

check "a copy dated 2099 while not synchronised: kept" "$new" "$new-daily" no "" \
  "$(printf '%s\n%s\n%s' "$recent" "2099-06-01T00:00:00Z-daily" "$new-daily")"

new=2026-12-01T00:00:00Z
check "after a month and a half off: the copies from before stay" "$new" "$new-daily" yes "" \
  "$(printf '%s\n%s' "$recent" "$new-daily")"

# The three newest stay, even 60 days older than the one before them; the fourth goes.
new=2026-10-16T03:00:05Z
check "the three newest stay" "$new" "$new-daily" yes "$(at $real $((61 * day)))-daily" \
  "$(printf '%s\n' "$new-daily" "$real-daily" "$(at $real $((60 * day)))-daily" "$(at $real $((61 * day)))-daily")"

# 30 days before the newest earlier copy ($real): a copy exactly then stays, one a second older goes.
check "the 30-day boundary" "$new" "$new-daily" yes "$(at $real $((30 * day + 1)))-update" \
  "$(printf '%s\n' "$new-daily" "$real-daily" "$(at $real $day)-daily" "$(at $real $((2 * day)))-daily" \
    "$(at $real $((30 * day)))-daily" "$(at $real $((30 * day + 1)))-update")"

# 2. A copy and its restore.
if [ "$(id -u)" != 0 ]; then
  echo "FAIL: a copy and its restore need root (sudo tools/vm/test-etc-copy.sh, or podman unshare)"
  exit 1
fi
t="$(readlink -f "$(mktemp -d)")"
trap 'rm -rf --one-file-system -- "$t"' EXIT
nl=$'name with a space and\na newline'

# listing DIR [meta]: every entry of DIR (DIR itself as "."), its name quoted, one per line, sorted;
# with meta, also its type, mode, owner, group, link target or content hash, and extended
# attributes (ACLs are one).
listing() {
  python3 -I - "$@" <<'EOF'
import hashlib, os, stat, sys
root, meta = sys.argv[1], len(sys.argv) > 2
paths = [root]
for d, dirs, files in os.walk(root):
    paths += [os.path.join(d, n) for n in dirs + files]
lines = []
for p in paths:
    st = os.lstat(p)
    line = repr(os.path.relpath(p, root))
    if meta:
        if stat.S_ISLNK(st.st_mode):
            what = "link " + os.readlink(p)
        elif stat.S_ISREG(st.st_mode):
            what = "file " + hashlib.sha256(open(p, "rb").read()).hexdigest()
        else:
            what = "dir" if stat.S_ISDIR(st.st_mode) else "other"
        x = sorted((n, os.getxattr(p, n, follow_symlinks=False).hex())
                   for n in os.listxattr(p, follow_symlinks=False))
        line += f" {what} {stat.S_IMODE(st.st_mode):o} {st.st_uid}:{st.st_gid} {x}"
    lines.append(line)
print("\n".join(sorted(lines)))
EOF
}
# names NAME...: as listing prints them.
names() { python3 -I -c 'import sys; print("\n".join(sorted(repr(a) for a in sys.argv[1:])))' "$@"; }
# removed COPY: the names in COPY/removed, as listing prints them.
removed() { python3 -I -c 'import sys; print("\n".join(sorted(repr(n.decode()) for n in open(sys.argv[1], "rb").read().split(b"\0") if n)))' "$1/removed"; }
# setmeta FILE: an ACL (user 1234 may read) and an extended attribute; xattr FILE: the attribute only.
setmeta() {
  python3 -I - "$@" <<'EOF'
import os, struct, sys
acl = struct.pack("<I", 2) + b"".join(struct.pack("<HHI", tag, perm, id) for tag, perm, id in
    [(1, 6, 0xffffffff), (2, 4, 1234), (4, 4, 0xffffffff), (0x10, 4, 0xffffffff), (0x20, 4, 0xffffffff)])
if sys.argv[1] == "acl":
    os.setxattr(sys.argv[2], "system.posix_acl_access", acl)
else:
    os.setxattr(sys.argv[2], "user.nyra", b"kept")
EOF
}

# The trees, in $t/w: old (an older image's /etc), live (the user's /etc on it), new (a newer
# image's /etc), outside and outside2 (directories outside /etc that new links to), shared (a
# directory outside /etc that old and new link to, as to /usr/share).
build() {
  local w="$t/w"
  rm -rf --one-file-system -- "$w"
  mkdir -p "$w/old" "$w/outside" "$w/outside2" "$w/shared"
  echo kept > "$w/outside2/x"
  echo kept > "$w/outside/file"
  echo x > "$w/shared/x"
  (
    cd "$w/old"
    chmod 0755 .
    for f in keep edited mode owner acl xattr gone link-target; do echo "$f" > "$f.conf"; done
    mkdir gonedir dir2file ssh escape escape2 unchanged unchanged/deep
    echo a > gonedir/a
    echo i > dir2file/inner
    echo f > file2dir
    ln -s keep.conf link.conf
    echo cfg > ssh/ssh_config
    echo x > escape2/x
    echo u > unchanged/deep/file
    ln -s "$w/shared" linkdir
  )
  cp -a "$w/old" "$w/live"
  (
    cd "$w/live"
    echo user > edited.conf
    chmod 0600 mode.conf
    chown 1234:42 owner.conf
    setmeta acl acl.conf
    setmeta xattr xattr.conf
    rm gone.conf
    rm -r gonedir dir2file
    echo now-a-file > dir2file
    rm file2dir
    mkdir file2dir
    echo x > file2dir/x
    ln -sfn link-target.conf link.conf
    mkdir -m 2750 sgid
    chown 0:42 sgid
    echo s > sgid/f
    (umask 077 && echo key > ssh/user_key)
    echo u > escape/user.conf
    rm escape2/x
    echo n > "$nl"
    rm linkdir
    mkdir linkdir
    cp -a "$w/shared/x" linkdir/
    echo mine > linkdir/mine
  )
  cp -a "$w/old" "$w/new"
  (
    cd "$w/new"
    echo new-default > keep.conf
    echo added > added.conf
    rm -r escape escape2 edited.conf
    ln -s "$w/outside" escape
    ln -s "$w/outside2" escape2
    ln -s "$w/outside/file" edited.conf
  )
  # What the restore must give: new, with the user's changes.
  cp -a "$w/new" "$w/expect"
  (
    cd "$w/expect"
    for p in edited.conf mode.conf owner.conf acl.conf xattr.conf dir2file file2dir link.conf sgid ssh/user_key "$nl" linkdir; do
      rm -rf -- "$p"
      cp -a "$w/live/$p" "$p"
    done
    rm -r gone.conf gonedir escape
    mkdir escape
    chmod --reference="$w/live/escape" escape
    cp -a "$w/live/escape/user.conf" escape/
  )
}

# outside_before, outside_same: the directories outside /etc are as they were at outside_before.
outside_before() { for d in outside outside2 shared; do listing "$t/w/$d" meta > "$t/w/$d.before"; done; }
outside_same() { for d in outside outside2 shared; do diff "$t/w/$d.before" <(listing "$t/w/$d" meta) || return 1; done; }

# scenario SCRIPT: the copy of live over old, laid over new; prints each check, fails if one does.
scenario() {
  local e="$1" w="$t/w" bad=0 got want
  build
  sh "$e" make "$w/old" "$w/live" "$w/copy" || { echo "FAIL: make"; return 1; }
  got="$(listing "$w/copy/etc")"
  want="$(names . acl.conf dir2file edited.conf escape escape/user.conf file2dir file2dir/x link.conf linkdir linkdir/mine \
    linkdir/x mode.conf "$nl" owner.conf sgid sgid/f ssh ssh/user_key xattr.conf)"
  if [ "$got" = "$want" ]; then echo "ok: the copy holds only what differs from the image"; else
    echo "FAIL: the copy holds only what differs from the image"; diff <(echo "$want") <(echo "$got") || true; bad=1; fi
  got="$(removed "$w/copy")"
  want="$(names gone.conf gonedir gonedir/a dir2file/inner escape2/x)"
  if [ "$got" = "$want" ]; then echo "ok: the copy lists what the user removed"; else
    echo "FAIL: the copy lists what the user removed"; diff <(echo "$want") <(echo "$got") || true; bad=1; fi
  outside_before
  if ! sh "$e" apply "$w/copy" "$w/new"; then echo "FAIL: apply"; return 1; fi
  if diff <(listing "$w/expect" meta) <(listing "$w/new" meta); then
    echo "ok: restored over a newer image: its defaults, the user's changes with their metadata, nothing removed comes back"
  else echo "FAIL: restored over a newer image"; bad=1; fi
  if outside_same; then
    echo "ok: nothing written or removed outside, through links in the newer image"
  else echo "FAIL: something written or removed outside, through links in the newer image"; bad=1; fi
  # A list of what was removed with the newer image's links to directories, ended by a slash.
  build
  mkdir -p "$w/copy4/etc"
  printf 'escape/\0escape2/\0linkdir/\0' > "$w/copy4/removed"
  outside_before
  if sh "$e" apply "$w/copy4" "$w/new" && outside_same; then
    echo "ok: a removed path with a trailing slash removes nothing through a link"
  else echo "FAIL: a removed path with a trailing slash removes something through a link"; bad=1; fi
  # An unchanged /etc: the copy gives the newer image as it is.
  build
  cp -a "$w/old" "$w/same"
  cp -a "$w/new" "$w/new-before"
  if sh "$e" make "$w/old" "$w/same" "$w/copy2" && test "$(listing "$w/copy2/etc")" = "'.'" && test ! -s "$w/copy2/removed" &&
    sh "$e" apply "$w/copy2" "$w/new" && diff <(listing "$w/new-before" meta) <(listing "$w/new" meta); then
    echo "ok: a copy of an unchanged /etc is empty and gives the newer image as it is"
  else echo "FAIL: a copy of an unchanged /etc"; bad=1; fi
  # The image's /etc not found (here: /etc itself): no copy.
  if ! sh "$e" make "$w/live" "$w/live" "$w/copy3" 2>/dev/null && test ! -e "$w/copy3"; then
    echo "ok: no copy when the image's /etc is /etc itself"
  else echo "FAIL: a copy made with /etc itself as the image's"; bad=1; fi
  return "$bad"
}

scenario "$etc_copy" || fail=1
# Each check, removed from a copy of the script: the scenario must fail.
while IFS='|' read -r what expr; do
  sed "$expr" "$etc_copy" > "$t/mutant"
  if cmp -s "$etc_copy" "$t/mutant"; then
    echo "FAIL: the change \"$what\" no longer applies to etc-copy"
    fail=1
  elif scenario "$t/mutant" > /dev/null 2>&1; then
    echo "FAIL: without $what, the scenario still passes"
    fail=1
  else
    echo "ok: without $what, the scenario fails"
  fi
done <<'EOF'
the comparison with the image (unchanged files kept)|s|^\t\t\t\trm -f -- "\$c/etc/\$p"$|\t\t\t\t:|
ACLs and extended attributes in the comparison|s/ --acls --xattrs \\$/ \\/;s/--xattrs-include='\*' //
the list of what was removed|s|printf '%s\\0' "\${p#./}"|:|
removing what the list names|/xargs -0 -r sh "\$self" unlink/d
the check of the directories on the way to a path in the image|\#realpath -e -- "\$i/\$d"#d
the refusal of a removed path ended by a slash|s#\*//\*) continue#//*) continue#
the check of the directories on the way to a removed path|s|if \[ "\$d" = . \] .*; then|if true; then|
clearing what the copy replaces|/find . -mindepth 1 -exec sh "\$self" clear/d
the check that the image's /etc is not /etc|s/ || \[ "\$(stat -L -c %d:%i -- "\$1")" = "\$(stat -L -c %d:%i -- "\$2")" \]//
EOF

exit "$fail"
