#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""CI only: the guest side of tools/vm/ssh-2fa.sh, run as root in a test VM (docs/DEFAULTS.md, "SSH").

Every login goes to the guest's own SSH server on 127.0.0.1, from the source address 127.0.0.SOURCE
(lo has all of 127.0.0.0/8), so the failures of one case do not count against the next one in
sshd's penalties (PerSourcePenalties counts per address). The password and the code are typed by
SSH_ASKPASS (SSH_ASKPASS_REQUIRE=force), which records each prompt it answers.

  ssh-2fa-guest.py enable USER
      runs `2fa enable USER` as an administrator does, and answers its question with the code of the
      secret it shows (kept in /run/nyra-test/USER.secret)
  ssh-2fa-guest.py accept|refuse ssh USER SOURCE PASSWORD fresh|last|none|DIGITS [VERDICT: REASON]
      a password login (keyboard-interactive through PAM): the code typed is the code of a step later
      than any handed out for USER before (fresh, waiting for the next step when needed), the code
      handed out last (last), nothing (none) or DIGITS. With VERDICT: REASON, the journal must also
      have the line pam_nyra_totp.so wrote for this login, "VERDICT for user USER from 127.0.0.SOURCE:
      REASON" (REASON a regular expression), so the case failed or passed for its own reason.
  ssh-2fa-guest.py accept|refuse key USER SOURCE
      a login with the test key alone (no password, no keyboard-interactive)
  ssh-2fa-guest.py penalty USER SOURCE PASSWORD
      password logins without a code from SOURCE until sshd drops the connection before any prompt
      (at most 15)
  ssh-2fa-guest.py login USER PASSWORD
      a console login: login(1) on a new pseudo-terminal, as agetty starts it, with the password;
      then `id -un` in the user's shell

"accept" passes when the login ran a command as USER; "refuse" when sshd answered "Permission
denied": a refusal of the login, not a connection that failed. Exit status 0 when it passes.
"""
import base64
import hashlib
import hmac
import os
import pty
import re
import select
import struct
import subprocess
import sys
import time

DIR = "/run/nyra-test"
KEY = f"{DIR}/id_ed25519"
ASKPASS = f"""#!/bin/sh
echo "$1" >> {DIR}/prompts
case "$1" in
  *Password:*) cat {DIR}/password ;;
  *"Verification code:"*) cat {DIR}/code ;;
  *) exit 1 ;;
esac
"""


def write(path, text, mode=0o600):
    with open(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode), "w") as f:
        f.write(text)


def totp(secret, step):
    """RFC 6238 with SHA1, 6 digits, 30 s steps (RFC 4226 truncation)."""
    mac = hmac.new(secret, struct.pack(">Q", step), hashlib.sha1).digest()
    o = mac[-1] & 0x0F
    return "%06d" % ((struct.unpack(">I", mac[o:o + 4])[0] & 0x7FFFFFFF) % 1000000)


def secret(user):
    text = open(f"{DIR}/{user}.secret").read().strip().upper()
    return base64.b32decode(text + "=" * (-len(text) % 8))


def fresh_code(user):
    """The code of the current step, once that step is later than any handed out for USER."""
    path = f"{DIR}/{user}.step"
    last = int(open(path).read()) if os.path.exists(path) else -1
    while int(time.time()) // 30 <= last:
        time.sleep(1)
    step = int(time.time()) // 30
    write(path, str(step))
    code = totp(secret(user), step)
    write(f"{DIR}/{user}.last", code)
    print(f"the code of step {step}")
    return code


def enable(user):
    p = subprocess.Popen(["2fa", "enable", user], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    while True:
        line = p.stdout.readline()
        if not line:
            sys.exit(f"2fa enable {user}: no secret shown")
        if line.startswith("Secret: "):
            write(f"{DIR}/{user}.secret", line[len("Secret: "):])
        if line.startswith("Link: "):
            break
    p.stdin.write(fresh_code(user) + "\n")
    p.stdin.close()
    rest = p.stdout.read()
    if p.wait() != 0 or f"Two-step authentication is on for {user}." not in rest:
        sys.exit(f"2fa enable {user} failed (exit {p.returncode})")
    print(f"2fa enable {user}: on, with {rest.count(chr(10) + '  ')} recovery codes")
    return 0


def ssh(user, source, *options):
    """One login from 127.0.0.SOURCE; (exit status, stdout, stderr, prompts answered)."""
    write(f"{DIR}/prompts", "")
    env = dict(os.environ, SSH_ASKPASS=f"{DIR}/askpass", SSH_ASKPASS_REQUIRE="force")
    cmd = ["ssh", "-b", f"127.0.0.{source}", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
           "-o", "ConnectTimeout=20", "-o", "NumberOfPasswordPrompts=1", *options,
           f"{user}@127.0.0.1", "echo SSH-OK-$(id -un)"]
    p = subprocess.run(cmd, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)
    prompts = [line.split(") ", 1)[-1] for line in open(f"{DIR}/prompts").read().splitlines()]
    print(f"ssh {user}@127.0.0.1 from 127.0.0.{source}: exit {p.returncode}, prompts {prompts}")
    for line in (p.stdout + p.stderr).splitlines():
        if line and "Warning: Permanently added" not in line:
            print(f"  {line}")
    return p.returncode, p.stdout, p.stderr, prompts


def outcome(user, result):
    code, out, err, _ = result
    if code == 0 and f"SSH-OK-{user}" in out:
        return "accept"
    if code == 255 and "Permission denied" in err:
        return "refuse"
    return "error"


def module_line(user, source, expected):
    """The line pam_nyra_totp.so logged for this login, within 10 s; None if there is none."""
    verdict, _, reason = expected.partition(": ")
    line = re.compile(rf"pam_nyra_totp\(sshd:auth\): {verdict} for user {re.escape(user)} "
                      rf"from 127\.0\.0\.{source}: (?:{reason})$", re.M)
    for _ in range(10):
        log = subprocess.run(["journalctl", "-b", "-o", "cat", "--no-pager", "SYSLOG_FACILITY=10"],
                             capture_output=True, text=True).stdout
        m = line.search(log)
        if m:
            return m.group(0)
        time.sleep(1)
    return None


def password_login(user, source, password, answer):
    write(f"{DIR}/password", password)
    code = {"fresh": lambda: fresh_code(user), "last": lambda: open(f"{DIR}/{user}.last").read(),
            "none": lambda: ""}.get(answer, lambda: answer)()
    write(f"{DIR}/code", code)
    return ssh(user, source, "-o", "PreferredAuthentications=keyboard-interactive", "-o", "PubkeyAuthentication=no")


def key_login(user, source):
    return ssh(user, source, "-i", KEY, "-o", "BatchMode=yes", "-o", "PreferredAuthentications=publickey",
               "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no")


def penalty(user, source, password):
    for n in range(1, 16):
        code, _, err, prompts = password_login(user, source, password, "none")
        if code == 255 and not prompts and "Permission denied" not in err:
            print(f"connection {n} from 127.0.0.{source} dropped before any prompt")
            return 0
        if code != 255 or "Permission denied" not in err:
            print("not a refusal")
            return 1
    print(f"sshd still answered 127.0.0.{source} after 15 failed logins")
    return 1


def console_login(user, password):
    pid, fd = pty.fork()
    if pid == 0:
        os.execv("/bin/login", ["login", user])
    out = b""

    def until(pattern, timeout=60, wait_for_login=False):
        nonlocal out
        end = time.monotonic() + timeout
        while not re.search(pattern, out) and time.monotonic() < end:
            if select.select([fd], [], [], 1)[0]:
                try:
                    chunk = os.read(fd, 4096)
                except OSError:
                    # login(1) calls vhangup() and opens the terminal again; for a moment nothing has
                    # the slave side open, and reading the master fails (EIO) although login is alive.
                    # Closing our side then would hang it up before it asks for the password.
                    if wait_for_login:
                        time.sleep(0.05)
                        continue
                    break
                if not chunk:
                    break
                out += chunk
        return re.search(pattern, out)

    ok = until(rb"Password: ?$", wait_for_login=True) is not None
    if ok:
        os.write(fd, password.encode() + b"\n")
        ok = until(rb"[$#] $") is not None
    if ok:
        os.write(fd, b"echo LOGIN-OK-$(id -un); exit\n")
        until(rb"LOGIN-OK-[a-z]+\r?\n")
        until(rb"(?!)", 10)  # the rest, up to the end of the session
    os.close(fd)
    os.waitpid(pid, 0)
    text = out.decode(errors="replace").replace("\r", "")
    print("\n".join("  " + line for line in text.splitlines() if line.strip()))
    return 0 if f"LOGIN-OK-{user}\n" in text else 1


def main(argv):
    os.makedirs(DIR, mode=0o700, exist_ok=True)
    write(f"{DIR}/askpass", ASKPASS, 0o700)
    if argv[0] == "enable":
        return enable(argv[1])
    if argv[0] == "login":
        return console_login(argv[1], argv[2])
    if argv[0] == "penalty":
        return penalty(argv[1], argv[2], argv[3])
    want, kind, user, source, *rest = argv
    expected = rest.pop(2) if kind == "ssh" and len(rest) == 3 else None
    result = password_login(user, source, *rest) if kind == "ssh" else key_login(user, source)
    got = outcome(user, result)
    # An accepted password login asked for the password, then the code; a key login asked nothing.
    asked = [p.strip() for p in result[3]]
    if got == "accept" and asked != (["Password:", "Verification code:"] if kind == "ssh" else []):
        got = f"accepted after the prompts {asked}"
    if expected:
        line = module_line(user, source, expected)
        print(f"the module's journal line: {line or 'none matching ' + repr(expected)}")
        if not line:
            got = f"{got}, without the module's line"
    print(f"expected: {want}; got: {got}")
    return 0 if got == want else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
