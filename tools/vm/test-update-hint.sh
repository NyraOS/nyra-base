#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Offline test of the message after a login (files/usr/lib/nyra/profile.d/update-hint.sh, docs/UPDATES.md,
# "After a hard reset"), without root or a VM. The real script is sourced by bash and by dash from a copy
# whose paths (the file of nyra-updated, the kernel's boot identifier, os-release, id) point into a work
# directory, in a shell on a terminal made here. It checks that the message is shown to an administrator
# when a version newer than the running one was prepared in an earlier boot, and is never shown, and never
# leaves an error or a variable behind, otherwise: a standard user, a version staged in this boot, applied or older, a
# file that is not a version (also one that tries to run a command), a missing file, a shell that is not
# interactive, and an interactive shell whose output is not a terminal.
#   tools/vm/test-update-hint.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
src=files/usr/lib/nyra/profile.d/update-hint.sh

sed -e "s#/var/lib/nyra-updated/staged-version#$work/staged-version#" \
  -e "s#/proc/sys/kernel/random/boot_id#$work/boot_id#" \
  -e "s#/usr/lib/os-release#$work/os-release#" \
  -e "s#/usr/bin/id#$work/bin/id#" "$src" >"$work/hint.sh"
code="$(grep -v '^[[:space:]]*#' "$work/hint.sh")"
[ "$(grep -c "$work" <<<"$code")" = 4 ] && ! grep -qE '/var/lib/nyra-updated|/proc/sys/kernel/random|/usr/lib/os-release|/usr/bin/id' <<<"$code" ||
  { echo "FAIL: the copy of $src was not made as expected"; exit 1; }
printf '#!/bin/sh\nif [ -e %s/sudo ]; then echo "tester sudo"; else echo tester; fi\n' "$work" >"$work/bin/id"
chmod +x "$work/bin/id"

# reset: the machine after a hard reset, with an administrator; each case changes what it needs.
reset() {
  touch "$work/sudo"
  echo f3c1-new >"$work/boot_id"
  printf '2026.10.5\nb7d2-old\n' >"$work/staged-version"
  echo 'IMAGE_VERSION=2026.10.1' >"$work/os-release"
}

# shell SHELL MODE: sources the copy in SHELL; MODE: tty (interactive, on a terminal), pipe (interactive,
# output into a pipe), command (not interactive, on a terminal). What it printed is in $work/out; after
# the script a line says which variables and functions it left behind.
shell() {
  python3 -I -c '
import os, pty, select, subprocess, sys, time
shell, mode, hint = sys.argv[1:4]
check = "echo \"left:[${flag-}${want-}${running-}${k-}${y-}${line-}${staged_boot-}${boot-}]\"; type nyra_update_hint >/dev/null 2>&1 && echo \"left: function\"; exit"
script = f". {hint}\n{check}\n"
if mode == "pipe":
    pid, fd = pty.fork()
    if pid == 0:
        subprocess.run(["stty", "-echo"])
        # Input on the terminal, output and errors into a pipe.
        r, w = os.pipe()
        child = subprocess.Popen([shell, "-i"], stdin=0, stdout=w, stderr=w, env={**os.environ, "PS1": ""})
        os.close(w)
        out = os.read(r, 65536)
        child.wait()
        sys.stdout.write(out.decode()) ; sys.stdout.flush()
        os._exit(0)
    time.sleep(0.5)
    os.write(fd, script.encode())
else:
    argv = [shell, "-c", script] if mode == "command" else [shell, "-i"]
    pid, fd = pty.fork()
    if pid == 0:
        subprocess.run(["stty", "-echo"])  # what is typed is not echoed back into the output
        os.environ["PS1"] = ""
        os.execvp(shell, argv)
    if mode == "tty":
        time.sleep(0.5)
        os.write(fd, script.encode())
out = b""
end = time.time() + 20
while time.time() < end:
    if select.select([fd], [], [], 0.5)[0]:
        try:
            data = os.read(fd, 4096)
        except OSError:
            break
        if not data:
            break
        out += data
os.waitpid(pid, 0)
open(sys.argv[4], "wb").write(out)
' "$1" "$2" "$work/hint.sh" "$work/out.raw"
  tr -d '\r' <"$work/out.raw" >"$work/out"
}
expect() { # expect DESCRIPTION CONDITION...
  local what="$1"
  shift
  if "$@"; then echo "ok   $what"; else echo "FAIL $what"; echo "--- output:"; cat "$work/out"; exit 1; fi
}
shows() { grep -qF -- "$1" "$work/out"; }
silent() { # nothing of the script reaches the terminal: no message, no error
  ! grep -qE 'Version |nyra update|No such file|not found|line [0-9]|syntax|rror|denied' "$work/out"
}
clean() { shows 'left:[]' && ! shows 'left: function'; }
message="Version 2026.10.5 was prepared, but the update was not finished."
again='Run `nyra update` to prepare it again; nothing is downloaded again.'

for sh in bash dash; do
  reset
  shell "$sh" tty
  expect "$sh: an administrator is told which version, and what to do" shows "$message"
  expect "$sh: the second line" shows "$again"
  expect "$sh: it leaves no variable and no function in the shell" clean

  echo 'IMAGE_VERSION="2026.10.1"' >"$work/os-release"
  shell "$sh" tty
  expect "$sh: a quoted version in os-release" shows "$message"

  reset; rm "$work/sudo"
  shell "$sh" tty
  expect "$sh: not an administrator: silent" silent
  expect "$sh: not an administrator: nothing left" clean

  reset; printf '2026.10.5\nf3c1-new\n' >"$work/staged-version"
  shell "$sh" tty
  expect "$sh: staged in this boot (still staged): silent" silent
  reset; printf '2026.10.5\n' >"$work/staged-version"
  shell "$sh" tty
  expect "$sh: no boot identifier in the file: silent" silent
  reset; rm "$work/boot_id"
  shell "$sh" tty
  expect "$sh: no boot identifier of this boot: silent" silent
  reset; printf '2026.10.5\nb7d2-old' >"$work/staged-version"
  shell "$sh" tty
  expect "$sh: no newline at the end of the file: shown" shows "$message"

  for running in 2026.10.5 2026.10.6 2026.11.1 2027.1.1; do
    reset; echo "IMAGE_VERSION=$running" >"$work/os-release"
    shell "$sh" tty
    expect "$sh: running $running, prepared 2026.10.5: silent" silent
  done
  reset; echo IMAGE_VERSION=2026.9.20 >"$work/os-release"
  shell "$sh" tty
  expect "$sh: numbers, not text (2026.9.20 < 2026.10.5)" shows "$message"
  reset; printf '2026.10.100\nb7d2-old\n' >"$work/staged-version"; echo IMAGE_VERSION=2026.10.99 >"$work/os-release"
  shell "$sh" tty
  expect "$sh: numbers, not text (2026.10.99 < 2026.10.100)" shows 'Version 2026.10.100 was prepared'

  reset; rm "$work/staged-version"
  shell "$sh" tty
  expect "$sh: no file: silent" silent
  reset; rm "$work/os-release"
  shell "$sh" tty
  expect "$sh: no os-release: silent" silent
  reset; echo 'NAME=x' >"$work/os-release"
  shell "$sh" tty
  expect "$sh: no version in os-release: silent" silent
  reset; chmod 000 "$work/staged-version"
  shell "$sh" tty
  expect "$sh: an unreadable file: silent" silent
  chmod 644 "$work/staged-version"

  for bad in '' 'stable' '2026.10' '2026.10.5.1' '2026.010.5' '2026.10.05' '026.10.5' '99999999999999999999.1.1' \
    '2026.10.5 x' '2026.10.5;touch pwned' '$(touch pwned)' '`touch pwned`' '2026.10.9999999' '2026.10.-5'; do
    reset; printf '%s\nb7d2-old\n' "$bad" >"$work/staged-version"
    (cd "$work" && shell "$sh" tty)
    expect "$sh: '$bad' is no version: silent" silent
    [ ! -e "$work/pwned" ] || { echo "FAIL $sh: '$bad' ran a command"; exit 1; }
  done
  reset; printf '2026.10.5\n$(touch pwned)\n' >"$work/staged-version"
  printf '$(touch pwned)\n' >"$work/boot_id"
  (cd "$work" && shell "$sh" tty)
  [ ! -e "$work/pwned" ] || { echo "FAIL $sh: a second line ran a command"; exit 1; }
  echo "ok   $sh: nothing in the file is run"

  reset
  shell "$sh" command
  expect "$sh: not interactive (sh -c): silent" silent
  shell "$sh" pipe
  expect "$sh: output is not a terminal: silent" silent
done
echo "test-update-hint: all passed"
