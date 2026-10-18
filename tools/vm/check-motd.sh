#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: checks what the root autologin on the serial console printed in a serial log saved by
# vm-boot.py: from agetty's "(automatic login)" line to the shell prompt (or the first command
# the test sends) there must be exactly the
# message of the day (/usr/lib/motd), nothing of Debian's (its warranty text, the uname line).
# Blank lines and a "Last login" line are not part of it.
# --self-test runs this on two inline copies of a real login (Debian's message and ours).
#   tools/vm/check-motd.sh SERIAL.log
#   tools/vm/check-motd.sh --self-test
set -euo pipefail

expected=$'Welcome to Nyra OS.\nHelp and news: https://nyraos.com'

# What was printed between the autologin line and the shell prompt. The log holds carriage
# returns, CSI colour/mode codes and OSC marks of systemd's shell integration; the prompt shares
# its line with such a mark, so the end is the first line with "root@" or the test's first command.
printed_at_login() {
  tr -d '\r' < "$1" |
    sed -E -e 's/\x1b\][^\x07\x1b]*(\x07|\x1b\\)//g' -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' |
    awk '/\(automatic login\)/ { on = 1; next } on && /root@|@@S(\x27\x27)?TART/ { exit } on' |
    grep -v -e '^$' -e '^Last login' || true
}

check() {
  local printed
  printed="$(printed_at_login "$1")"
  echo "printed at the login:"
  echo "$printed"
  [ "$printed" = "$expected" ]
}

if [ "${1:-}" = --self-test ]; then
  t="$(mktemp -d)"
  trap 'rm -rf "$t"' EXIT
  # A login from CI; ESC and BEL are spelled out so that the fixture stays readable.
  login() { # login MOTD-LINES...
    {
      printf '%s\n' 'localhost login: root (automatic login)' ''
      printf '%s\n' "$@"
      printf '%s\n' '{ESC}]3008;start=1;type=session{ESC}\{ESC}]3008;start=2;type=shell{ESC}\{ESC}[?2004hroot@localhost:~# [    9.99] evm: overlay not supported' \
        "echo @@S''TART0@@; echo @@E''XIT0=\$?@@" '{ESC}[?2004l{ESC}]3008;start=3;type=command{ESC}\@@START0@@' '@@EXIT0=0@@'
    } | sed -e 's/{ESC}/\x1b/g' -e 's/$/\r/'
  }
  login '' 'Linux localhost 7.2.11 #1 SMP Debian 7.2.11-1 (2026-10-15) x86_64' '' \
    'The programs included with the Debian GNU/Linux system are free software;' \
    'Debian GNU/Linux comes with ABSOLUTELY NO WARRANTY, to the extent' \
    'permitted by applicable law.' > "$t/debian.log"
  login 'Welcome to Nyra OS.' 'Help and news: https://nyraos.com' > "$t/nyra.log"
  fail=0
  check "$t/debian.log" > /dev/null && { echo "FAILED: Debian's message was accepted"; fail=1; } || echo "ok: Debian's message is rejected"
  check "$t/nyra.log" > /dev/null && echo "ok: the Nyra OS message is accepted" || { echo "FAILED: the Nyra OS message was rejected"; fail=1; }
  exit "$fail"
fi

if ! check "$1"; then
  echo "check-motd: the login must print exactly:" >&2
  echo "$expected" >&2
  exit 1
fi
echo "the login shows the Nyra OS message and nothing of Debian's"
