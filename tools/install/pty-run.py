#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: runs a command on a terminal, as the owner sees it in the installer, and writes what the
# terminal showed to a file. The command's exit status is this script's.
# If the environment variable ANSWER is set, it is typed (with a newline) at the first passphrase
# prompt; it goes through the environment, not an argument.
#   tools/install/pty-run.py TRANSCRIPT COMMAND...
import os
import pty
import re
import select
import sys

transcript, command = sys.argv[1], sys.argv[2:]
answer = os.environ.pop("ANSWER", None)
pid, fd = pty.fork()
if pid == 0:
    os.execvp(command[0], command)
shown = b""
while True:
    ready, _, _ = select.select([fd], [], [], 1)
    if ready:
        try:
            data = os.read(fd, 4096)
        except OSError:  # the child closed the terminal
            break
        if not data:
            break
        shown += data
    if answer is not None and re.search(rb"passphrase[^\n]*: $", shown):
        os.write(fd, answer.encode() + b"\n")
        answer = None
with open(transcript, "wb") as f:
    f.write(shown)
_, status = os.waitpid(pid, 0)
sys.exit(os.waitstatus_to_exitcode(status))
