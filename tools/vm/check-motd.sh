#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: checks what the root autologin on the serial console printed in a serial log saved by
# vm-boot.py: from agetty's "(automatic login)" line to the shell prompt there must be exactly the
# message of the day (/usr/lib/motd), nothing of Debian's (its warranty text, the uname line).
# Blank lines and a "Last login" line are not part of it.
#   tools/vm/check-motd.sh SERIAL.log
set -euo pipefail

log="$1"
expected=$'Welcome to Nyra OS.\nHelp and news: https://nyraos.com'
# The console log holds colour codes and carriage returns.
printed="$(sed -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' -e 's/\r$//' "$log" |
  awk '/\(automatic login\)/ { on = 1; next } on && /# ?$/ { exit } on' |
  grep -v -e '^$' -e '^Last login' || true)"
echo "printed at the login:"
echo "$printed"
if [ "$printed" != "$expected" ]; then
  echo "check-motd: the login must print exactly:" >&2
  echo "$expected" >&2
  exit 1
fi
echo "the login shows the Nyra OS message and nothing of Debian's"
