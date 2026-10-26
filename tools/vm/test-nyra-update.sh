#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Offline test of the waiting part of `nyra update` (files/usr/bin/nyra, docs/UPDATES.md, "Updating from a
# terminal as an administrator"), without root or a VM. The real script runs from a copy whose paths
# (PATH, the result and stage files, os-release) point into a work directory, on a terminal made here,
# with stand-ins for nyra-updated (the version on offer) and systemctl (a job that writes the stage and
# the result as the install does, or that ends without a result). It checks that:
#   - the stage and the time are shown, and a finished install is reported only from a result file
#     written during the run, for the version on offer;
#   - a failure shows the reason the program wrote; an older reason is never shown;
#   - a unit that ends without a result (a dependency failed, root stopped it) is "not installed",
#     status 1, whatever state the unit has;
#   - an empty answer of systemctl is waited through, not taken as the end;
#   - on a terminal of 30 columns no row of the live line is wider than the terminal;
#   - Ctrl+C stops the waiting and says the install goes on, status 130.
#   tools/vm/test-nyra-update.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
version=2026.10.2

# The copy of the script: only the places it reads from the machine change.
sed -e "s#^PATH=.*#PATH=$work/bin:/usr/bin:/bin#" \
  -e "s#^RESULT=.*#RESULT=$work/result#" \
  -e "s#^STAGE=.*#STAGE=$work/stage#" \
  -e "s#/usr/libexec/nyra-updated#$work/bin/nyra-updated#" \
  -e "s#/usr/lib/os-release#$work/os-release#" \
  -e 's#id -nG#echo sudo#' files/usr/bin/nyra >"$work/nyra"
[ "$(grep -c "$work" "$work/nyra")" = 5 ] && grep -q 'echo sudo' "$work/nyra" ||
  { echo "FAIL: the copy of files/usr/bin/nyra was not made as expected"; exit 1; }
echo IMAGE_VERSION=2026.10.1 >"$work/os-release"

printf '#!/bin/sh\necho %s\n' "$version" >"$work/bin/nyra-updated"
cat >"$work/bin/systemctl" <<EOS
#!/bin/sh
# SC_MODE: ok (stage at 1 s, result at 3 s), fail (a failed line at 3 s), dep (the job ends at 2 s, no result).
# SC_EMPTY=N: the first N answers of show are empty. State is in files next to this one.
d=$work
case "\$1" in
start)
  touch \$d/job
  case "\$SC_MODE" in
  dep) ( sleep 2; rm -f \$d/job ) >/dev/null 2>&1 & ;;
  *) ( sleep 1; printf 'Downloading and preparing the update' >\$d/stage; sleep 2
       case "\$SC_MODE" in
       ok) echo "staged $version" >\$d/result ;;
       fail) echo "failed $version The download did not finish." >\$d/result ;;
       esac
       rm -f \$d/job ) >/dev/null 2>&1 & ;;
  esac ;;
show)
  n=\$(cat \$d/count 2>/dev/null || echo 0); echo \$((n + 1)) >\$d/count
  [ "\$n" -ge "\${SC_EMPTY:-0}" ] || exit 1
  if [ -f \$d/job ]; then job=1; state=activating; else job=; state=inactive; fi
  case "\$*" in *--value*) echo \$state ;; *) echo "Job=\$job"; echo "ActiveState=\$state" ;; esac ;;
esac
EOS
chmod +x "$work/bin/nyra-updated" "$work/bin/systemctl"

# run MODE SECONDS [COLUMNS [CTRL_C_AT]]: the script on a terminal; the screen text (rows split at \r) is in $work/out,
# the exit status in $rc.
run() {
  rm -f "$work/job" "$work/count" "$work/stage" "$work/result"
  [ -z "${STALE:-}" ] || { echo "failed $version an older reason." >"$work/result"; touch -d '2 hours ago' "$work/result"; }
  rc="$(SC_MODE="$1" python3 -I -c '
import fcntl, os, pty, select, struct, sys, termios, time
seconds, columns, ctrl_c = float(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4])
pid, fd = pty.fork()
if pid == 0:
    os.execv("/bin/sh", ["sh", sys.argv[1], "update"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, columns, 0, 0))
start, out, sent, status = time.time(), b"", False, None
while time.time() - start < seconds:
    if select.select([fd], [], [], 0.2)[0]:
        try:
            data = os.read(fd, 4096)
        except OSError:
            status = os.waitpid(pid, 0)[1]
            break
        out += data
        if not sent and b"[y/N]" in out:
            os.write(fd, b"y\n")
            sent = True
    if ctrl_c and time.time() - start > ctrl_c:
        os.write(fd, b"\x03")
        ctrl_c = 0
if status is None:
    os.kill(pid, 9)
    os.waitpid(pid, 0)
    print("timeout")
    sys.exit(0)
open(sys.argv[5], "wb").write(out)
print(os.waitstatus_to_exitcode(status))
' "$work/nyra" "$2" "${3:-80}" "${4:-0}" "$work/raw")" || { echo "FAIL: the terminal driver"; exit 1; }
  # \r rows, without the clear-line sequence
  tr '\r' '\n' <"$work/raw" | sed 's/\x1b\[K//g' >"$work/out"
}
expect() { # expect DESCRIPTION CONDITION...: the condition holds
  local what="$1"
  shift
  if "$@"; then echo "ok   $what"; else echo "FAIL $what"; echo "--- status $rc, screen:"; cat "$work/out"; exit 1; fi
}
shows() { grep -qF -- "$1" "$work/out"; }
not_shows() { ! grep -qF -- "$1" "$work/out"; }
status_is() { [ "$rc" = "$1" ]; }

run ok 15
expect "a finished install: stage and time shown" shows 'Downloading and preparing the update... 0:0'
expect "a finished install: reported" shows "Installed version $version."
expect "a finished install: status 0" status_is 0

STALE=1 run fail 15
expect "a failure shows the reason of this run" shows "The update was not installed: The download did not finish."
expect "a failure: status 1" status_is 1
expect "a failure: no installed line" not_shows 'Installed version'

STALE=1 run dep 20
expect "a unit that ends without a result is not installed" shows 'The update was not installed.'
expect "no result: status 1" status_is 1
expect "no result: not reported as installed" not_shows 'Installed version'
expect "no result: an older reason is not shown" not_shows 'an older reason'

SC_EMPTY=3 run ok 20
expect "an empty answer of systemctl is waited through" shows "Installed version $version."
expect "an empty answer: the wait went on to the end" shows 'Downloading and preparing the update'

run ok 15 30
expect "30 columns: installed" shows "Installed version $version."
# The rows of the live line are the ones that are not a message of the script.
no_wide_row() { ! awk 'length($0) >= 30 && !/^(Preparing|Version|Restart|Do not|Installed)/ { found = 1 } END { exit !found }' "$work/out"; }
expect "30 columns: no row of the live line reaches the width" no_wide_row

run ok 15 80 2
expect "Ctrl+C: says the install goes on" shows 'The update keeps preparing in the background; run `nyra update` again to see it.'
expect "Ctrl+C: status 130" status_is 130
echo "test-nyra-update: all passed"
