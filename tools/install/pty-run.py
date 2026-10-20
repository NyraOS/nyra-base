#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: runs a command on a terminal, as the owner sees it in the installer, and writes what the
# terminal showed to a file. The command's exit status is this script's.
# If the environment variable ANSWER is set, it is typed (with a newline) at every passphrase
# prompt (cryptsetup asks again after a wrong one, up to three times); it goes through the
# environment, not an argument.
# The command gets TIMEOUT seconds (default 60); after that it is killed, this script says so and
# exits with 124, so a prompt nobody answers fails one test case instead of hanging the step.
#   tools/install/pty-run.py TRANSCRIPT COMMAND...
import os
import pty
import re
import select
import signal
import sys
import time

transcript, command = sys.argv[1], sys.argv[2:]
answer = os.environ.pop("ANSWER", None)
deadline = time.monotonic() + int(os.environ.get("TIMEOUT", "60"))
pid, fd = pty.fork()
if pid == 0:
    os.execvp(command[0], command)
shown = b""
unanswered = b""  # what the terminal showed since the last answer
timed_out = False
while True:
    if time.monotonic() > deadline:
        timed_out = True
        os.kill(pid, signal.SIGKILL)
        break
    ready, _, _ = select.select([fd], [], [], 1)
    if ready:
        try:
            data = os.read(fd, 4096)
        except OSError:  # the child closed the terminal
            break
        if not data:
            break
        shown += data
        unanswered += data
    if answer is not None and re.search(rb"passphrase[^\n]*: $", unanswered):
        os.write(fd, answer.encode() + b"\n")
        unanswered = b""
with open(transcript, "wb") as f:
    f.write(shown)
_, status = os.waitpid(pid, 0)
if timed_out:
    print(f"pty-run: {command[0]} still running after the timeout, killed", file=sys.stderr)
    sys.exit(124)
sys.exit(os.waitstatus_to_exitcode(status))
