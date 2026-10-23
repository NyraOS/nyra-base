#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: runs a command on a terminal, as the owner sees it in the installer, and writes what the
# terminal showed to a file. The command's exit status is this script's.
# If the environment variable ANSWER is set, it is typed (with a newline) at every passphrase
# prompt (cryptsetup asks again after a wrong one, up to three times); it goes through the
# environment, not an argument.
# If the environment variable REPLIES is set (a JSON list of [REGEX, TEXT] pairs), TEXT and a
# newline are typed whenever what the terminal showed since the last answer matches REGEX ("Press
# Enter" prompts, a confirmation); a TEXT that is null types Ctrl-D (the end of the input) instead.
# If PRETYPE is set, that many newlines are typed at once, before the command has run: input
# waiting at the terminal before any prompt, as a key held down or type-ahead leaves it.
# The command gets TIMEOUT seconds (default 60); after that it is killed, this script says so and
# exits with 124, so a prompt nobody answers fails one test case instead of hanging the step.
#   tools/install/pty-run.py TRANSCRIPT COMMAND...
import os
import json
import pty
import re
import select
import signal
import sys
import time

transcript, command = sys.argv[1], sys.argv[2:]
answer = os.environ.pop("ANSWER", None)
replies = json.loads(os.environ.pop("REPLIES", "[]"))
pretype = int(os.environ.pop("PRETYPE", "0"))
deadline = time.monotonic() + int(os.environ.get("TIMEOUT", "60"))
pid, fd = pty.fork()
if pid == 0:
    os.execvp(command[0], command)
if pretype:
    os.write(fd, b"\n" * pretype)
shown = b""
unanswered = b""  # what the terminal showed since the last answer
timed_out = False
while True:
    if time.monotonic() > deadline:
        timed_out = True
        os.killpg(pid, signal.SIGKILL)  # the child is the session leader: it and what it started
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
    for regex, text in replies:
        if re.search(regex.encode(), unanswered):
            os.write(fd, b"\x04" if text is None else text.encode() + b"\n")
            unanswered = b""
            break
with open(transcript, "wb") as f:
    f.write(shown)
_, status = os.waitpid(pid, 0)
if timed_out:
    print(f"pty-run: {command[0]} still running after the timeout, killed", file=sys.stderr)
    sys.exit(124)
sys.exit(os.waitstatus_to_exitcode(status))
