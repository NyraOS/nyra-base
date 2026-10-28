#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""CI only: the guest side of tools/vm/editor.sh, run as root in a test VM (docs/DEFAULTS.md,
"Terminal editor").

  editor-guest.py edit USER FILE
      as USER (root: as it is), the command `editor FILE` on a new pseudo-terminal of 24 x 80, as a
      person types it: FILE holds "first line"; the editor shows it, "added " is typed at the start,
      ^O and Enter write the file, ^X ends the editor. Passes when the editor ended with status 0, FILE
      is "added first line" with its owner and mode unchanged, and no lock file is left
  editor-guest.py login USER PASSWORD
      a console login: login(1) on a new pseudo-terminal, as agetty starts it, with the password;
      passes when the login shell has EDITOR and VISUAL set to "editor"

Exit status 0 when it passes. What the terminal showed is printed, without escape sequences.
"""
import fcntl
import os
import pty
import pwd
import re
import select
import struct
import sys
import termios
import time


class Pty:
    """A program on a new pseudo-terminal; `out` is everything it wrote so far."""

    def __init__(self, child):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            try:
                fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
                child()
            finally:
                os._exit(127)
        self.out = b""

    def until(self, pattern, timeout=30, wait_for_login=False):
        end = time.monotonic() + timeout
        while not re.search(pattern, self.out) and time.monotonic() < end:
            if select.select([self.fd], [], [], 1)[0]:
                try:
                    chunk = os.read(self.fd, 4096)
                except OSError:
                    # login(1) calls vhangup() and opens the terminal again; for a moment nothing has
                    # the slave side open, and reading the master fails (EIO) although login is alive.
                    if wait_for_login:
                        time.sleep(0.05)
                        continue
                    break
                if not chunk:
                    break
                self.out += chunk
        return re.search(pattern, self.out) is not None

    def type(self, data):
        time.sleep(0.3)
        os.write(self.fd, data)

    def end(self, timeout=10):
        """The exit status, or None when the program is still running after `timeout` (then killed)."""
        self.until(rb"(?!)", timeout=0.5)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                os.close(self.fd)
                return os.waitstatus_to_exitcode(status)
            self.until(rb"(?!)", timeout=0.5)
        os.kill(self.pid, 9)
        os.waitpid(self.pid, 0)
        os.close(self.fd)
        return None

    def text(self):
        """What the terminal showed, as lines: a cursor movement to a line starts a new line, the other
        escape sequences go. Among them systemd's OSC 3008 context marks, which the shell writes before
        every prompt and before a command's output, on the same line."""
        text = re.sub(r"\x1b\[[0-9;]*H", "\n", self.out.decode(errors="replace"))
        text = re.sub(r"\x1b\][^\x07\x1b]*(\x07|\x1b\\)", "", text)
        text = re.sub(r"\x1b(\[[0-?]*[ -/]*[@-~]|[()][0-9A-Za-z]|[=>78])", "", text).replace("\r", "\n")
        return [line.rstrip() for line in text.splitlines()]

    def show(self):
        print("\n".join("  " + line for line in self.text() if line.strip()))


def edit(user, path):
    with open(path, "w") as f:
        f.write("first line\n")
    account = pwd.getpwnam(user)
    os.chown(path, account.pw_uid, account.pw_gid)
    os.chmod(path, 0o640)
    before = os.stat(path)

    def child():
        if os.getuid() != account.pw_uid:
            os.initgroups(user, account.pw_gid)
            os.setgid(account.pw_gid)
            os.setuid(account.pw_uid)
        env = dict(os.environ, HOME=account.pw_dir, USER=user, LOGNAME=user, TERM="xterm")
        os.execvpe("editor", ["editor", path], env)

    p = Pty(child)
    ok = p.until(rb"first line")
    if ok:
        p.type(b"added ")
        ok = p.until(rb"added ")
    if ok:
        p.type(b"\x0f")  # ^O
        ok = p.until(rb"Write to File: ")
    if ok:
        p.type(b"\r")
        ok = p.until(rb"Wrote 1 line")
    if ok:
        p.type(b"\x18")  # ^X
    status = p.end()
    p.show()
    with open(path) as f:
        text = f.read()
    after = os.stat(path)
    print(f"editor as {user}: exit status {status}; {path}: {text!r}, "
          f"owner {after.st_uid}:{after.st_gid}, mode {after.st_mode & 0o7777:o}")
    same = (after.st_uid, after.st_gid, after.st_mode) == (before.st_uid, before.st_gid, before.st_mode)
    lock = os.path.join(os.path.dirname(path), "." + os.path.basename(path) + ".swp")
    if os.path.exists(lock):
        print(f"the editor left its lock file {lock}")
    return 0 if ok and status == 0 and text == "added first line\n" and same and not os.path.exists(lock) else 1


def login(user, password):
    p = Pty(lambda: os.execv("/bin/login", ["login", user]))
    ok = p.until(rb"Password: ?$", wait_for_login=True)
    if ok:
        p.type(password.encode() + b"\n")
        ok = p.until(rb"[$#] $")
    if ok:
        p.type(b'echo "ENV-$(id -un) EDITOR=$EDITOR VISUAL=$VISUAL -"; exit\n')
        p.until(rb"ENV-[a-z]+ [^\r\n]* -\r?\n")
    p.end()
    p.show()
    # The whole line, as the shell printed it (not the command typed, which has "$(id -un)").
    return 0 if f"ENV-{user} EDITOR=editor VISUAL=editor -" in p.text() else 1


def main(argv):
    if argv[:1] == ["edit"] and len(argv) == 3:
        return edit(argv[1], argv[2])
    if argv[:1] == ["login"] and len(argv) == 3:
        return login(argv[1], argv[2])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
