#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Boot a disk image headless with QEMU + KVM (UEFI) and check that it comes up.

The guest serial console is QEMU's stdio. Boot is complete when the console
shows a login prompt. Then the script logs in as root on the console and runs
the given commands; each must exit 0. A fresh image gets a random root password
and a time zone as systemd credentials, so systemd-firstboot does not stop to
ask for them. The time from QEMU
start to the login prompt and the command outputs are appended as Markdown to
--summary (for example $GITHUB_STEP_SUMMARY).

--secure-boot boots the Secure Boot firmware with a copy of the given variable store;
with --keep-vars the store itself is used, so firmware variables written in the guest
(boot entries, BootOrder) are there for the next run.
--refused PATTERN expects the opposite of a boot: PATTERN shows up on the
console and no system starts (no "Linux version" from a kernel with console=ttyS0,
no login prompt from the getty that a credential puts on ttyS0).
--marker PATTERN, with --marker-expected yes|no, does not log in: it waits until
the console shows that the system reached multi-user.target, waits 20 s more,
and checks whether PATTERN was printed (by a unit, for example).
--credential NAME=TEXT passes one more systemd credential over SMBIOS. The
sealed command line does not import them (docs/BOOT.md); the test disks carry an
add-on that does (tools/vm/test-addon.sh).
--smbios STRING passes one more SMBIOS OEM string (type 11) as it is, for example
io.systemd.stub.kernel-cmdline-extra=..., which systemd-stub reads itself.
--persist writes to the disk (otherwise QEMU snapshot mode), --poweroff ends
with a clean shutdown, so several runs can follow one system across reboots.
The shutdown must take less than 60 s (a unit that ignores its stop signal is
killed only after systemd's 90 s stop timeout) and unmount every file system.
--power-cut-at REGEX kills QEMU (a power cut) as soon as REGEX shows up on the
console, during the boot or during a command; the commands before it must pass.
--chat 'EXPECT=>SEND' (repeatable) replaces the login: wait for the regular
expression EXPECT, type SEND and Enter (SEND "@ctrl-d": Control-D alone), in order;
then a root shell prompt must follow (for a boot that asks for something else than
a login, like recovery).
With --chat-then-login a login prompt follows instead (the guest reboots after the
chat, for example), and the script logs in there as usual.
--rtc BASE starts the guest's hardware clock at BASE (QEMU -rtc base=, for example
2099-01-01T00:00:00) instead of the host's time.
--boots N logs in only after the Nth kernel start, for a guest that reboots by
itself first. A command written "@reboot CMD" is typed without waiting for its
result, then the script logs in again at the next login prompt (a soft reboot).
Every kernel start ("Linux version" on the console) must be expected: one for the boot (N with
--boots N), at most one more after a --chat-then-login chat and for each "@reboot" command (a
soft reboot starts none). Any other fails the run at once: with the image's rd.emergency=reboot,
an emergency in the initrd reboots silently, and the next boot could pass the check.

A boot that ends in emergency mode (in the initrd too) prints what udev saw of the disk
first (a drop-in passed as a credential), the size of LoaderDevicePartUUID and what a new
probe of each disk finds now, and the script fails there without waiting for the timeout.
A failed boot names its serial log in the output, so the job log leads to the whole console.

KVM is mandatory: accel=kvm, no fallback to emulation.
"""
import argparse
import base64
import os
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import threading
import time

OVMF_CODE = "/usr/share/OVMF/OVMF_CODE_4M.fd"
OVMF_VARS = "/usr/share/OVMF/OVMF_VARS_4M.fd"
OVMF_CODE_SECBOOT = "/usr/share/OVMF/OVMF_CODE_4M.secboot.fd"
AUTOLOGIN = ("[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin root --noreset --noclear "
             "--keep-baud 115200,57600,38400,9600 - ${TERM}\n")
# A boot that ends in emergency mode prints what the disk looks like to udev first: the root account
# is locked, so there is no shell to ask afterwards. The initrd gets it too (it imports the
# credentials), where a missing /dev/gpt-auto-root ends in its emergency mode. The unit's main
# command resets the console, which drops what the serial port has not sent yet: the diagnostics
# wait a moment at the end, or their last lines (and the end marker) can be lost.
EMERGENCY = ("[Service]\nEnvironment=SYSTEMD_PAGER=cat SYSTEMD_LOG_LEVEL=info\nExecStartPre=-/bin/sh -c '"
             "echo \"@@ emergency: diagnostics\"; "
             "for d in /dev/vd*; do echo \"== $$d\"; udevadm info -q property \"$$d\"; done; "
             "ls -l /dev/gpt-auto-root* /dev/disk/by-partuuid; "
             "v=/sys/firmware/efi/efivars/LoaderDevicePartUUID-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f; ls -l $$v; cat $$v; echo; "
             "for d in /sys/block/vd*; do echo \"== $$d probed again now\"; udevadm test-builtin blkid $$d 2>/dev/null; done; "
             "journalctl -b -o short-monotonic --no-pager -u systemd-udevd.service; "
             "echo \"@@ end of diagnostics\"; sleep 3'\n")
# Kernel messages can land in the middle of another line on the console, colour codes included:
# "Reached target \x1b[0;1;39mmulti-user.target\x1b[0[    9.85] clocksource: ...\r\nm - Multi-User System."
KERNEL_LINE = re.compile(rb"\[ *\d+\.\d+\] [^\r\n]*[\r\n]+")
ANSI = re.compile(rb"\x1b\[[0-9;?]*[A-Za-z]")
# The kernel's own line, after its timestamp: not `cat /proc/version` or a typed command.
KERNEL_START = re.compile(rb"\] Linux version \d")


def clean(buf):
    """The console without kernel messages and colour codes, for matching whole status lines."""
    return ANSI.sub(b"", KERNEL_LINE.sub(b"", buf))


class Console:
    """Guest serial console: everything QEMU prints, plus a way to type."""

    def __init__(self, proc, log, cut_at=None, kernels=1):
        self.proc, self.log, self.cut_at = proc, log, cut_at
        self.kernels = kernels  # kernel starts expected so far; one more is an unexpected reboot
        self.buf = b""
        self.cut = None  # seconds after start when QEMU was killed by --power-cut-at
        self.t0 = time.monotonic()
        self.lock = threading.Lock()
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        while chunk := self.proc.stdout.read(65536):  # unbuffered: one read, whatever is there
            with self.lock:
                self.buf += chunk
            self.log.write(chunk)
            self.log.flush()
            if self.cut_at and self.cut is None and re.search(self.cut_at, self.buf):
                self.proc.kill()
                self.cut = time.monotonic() - self.t0

    def wait_for(self, pattern, timeout, start=0, cleaned=False):
        """Wait for `pattern` after offset `start` (in clean(buf) with `cleaned`, whose offsets
        differ); None on timeout or if QEMU exits. An unexpected kernel start before it raises."""
        deadline = time.monotonic() + timeout
        while True:
            exited = self.proc.poll() is not None
            if exited:  # one last look, at everything QEMU printed before it exited
                self.reader.join(5)
            with self.lock:
                buf = self.buf
            m = re.search(pattern, clean(buf[start:]) if cleaned else buf[start:])
            self.check_kernels(buf, start + m.start() if m and not cleaned else len(buf))
            if m or exited or time.monotonic() >= deadline:
                return m
            time.sleep(0.2)

    def check_kernels(self, buf, end):
        """No more kernel starts in buf[:end] than expected."""
        n = len(KERNEL_START.findall(buf, 0, end))
        if n > self.kernels:
            raise RuntimeError(f"unexpected reboot: kernel start {n} on the console, {self.kernels} expected")

    def type(self, text):
        try:
            self.proc.stdin.write(text.encode())
            self.proc.stdin.flush()
        except BrokenPipeError:
            self.proc.wait()
            raise RuntimeError(f"QEMU exited with code {self.proc.returncode} after "
                               f"{time.monotonic() - self.t0:.1f} s, before the input could be typed") from None


def refused(con, pattern, timeout):
    """PATTERN shows up on the console, and no system has started 60 s later: no kernel message
    (only with console=ttyS0) and no login prompt (the getty on ttyS0 comes from a credential)."""
    m = con.wait_for(pattern.encode(), timeout)
    if not m:
        raise RuntimeError(f"no {pattern!r} on the console within {timeout} s")
    if con.wait_for(rb"Linux version|login: ", 60, m.end()):
        raise RuntimeError("a system started")
    return f"`{m.group().decode(errors='replace')}`, no system started within 60 s"


def marker(con, pattern, expected, timeout):
    """multi-user.target is reached, 20 s pass, and PATTERN was printed or not, as expected."""
    m = con.wait_for(rb"Reached target multi-user\.target|@@ emergency: diagnostics", timeout, cleaned=True)
    if m and m.group() != b"Reached target multi-user.target":
        con.wait_for(rb"@@ end of diagnostics", 300)
        raise RuntimeError("the boot ended in emergency mode (diagnostics in the serial log)")
    if not m:
        raise RuntimeError(f"multi-user.target not reached within {timeout} s")
    time.sleep(20)
    with con.lock:
        buf = con.buf
    con.check_kernels(buf, len(buf))
    seen = any(re.search(pattern.encode(), b) for b in (buf, clean(buf)))
    if seen != expected:
        raise RuntimeError(f"{pattern!r} {'not ' if expected else ''}on the console")
    return f"`{pattern}` {'printed' if seen else 'not printed'}, as expected"


def login(con, a, password, start):
    """Wait for a login prompt after offset `start` and log in as root on the console."""
    if a.chat:
        chat, a.chat = a.chat, []  # the chat happens once, at the first login
        for step in chat:
            expect, _, send = step.partition("=>")
            m = con.wait_for(expect.encode(), a.timeout, start)
            if not m:
                raise RuntimeError(f"no {expect!r} on the console within {a.timeout} s")
            start += m.end()
            con.type("\x04" if send == "@ctrl-d" else send + "\r")
        if not a.chat_then_login:
            if not con.wait_for(rb"# ", 60, start):
                raise RuntimeError("no root shell after the chat")
            return
        con.kernels += 1  # the guest may reboot after the chat
    m = con.wait_for(rb"login: |@@ emergency: diagnostics", a.timeout, start)
    if m and m.group() != b"login: ":
        con.wait_for(rb"@@ end of diagnostics", 300, start)
        raise RuntimeError("the boot ended in emergency mode (diagnostics in the serial log)")
    if not m:
        if con.proc.poll() is not None:
            raise RuntimeError(f"QEMU exited with code {con.proc.returncode} after "
                               f"{time.monotonic() - con.t0:.1f} s, before the login prompt")
        raise RuntimeError(f"no login prompt within {a.timeout} s")
    # A reboot that was allowed but did not happen (a soft reboot, a chat without one) is not
    # allowed any more.
    con.kernels = len(KERNEL_START.findall(con.buf, 0, start + m.start()))
    # From the end of the prompt, not the end of the buffer: with autologin the
    # shell prompt can already be there.
    start += m.end()
    if not a.autologin:
        con.type("root\r")
        if con.wait_for(rb"Password: ", 10, start):
            start = len(con.buf)
            con.type(password + "\r")
    if not con.wait_for(rb"# ", 60, start):
        raise RuntimeError("no root shell after logging in on the console")


def poweroff_problem(console, seconds):
    """What was wrong with a clean shutdown, from its console output and duration; None if nothing."""
    if seconds > 60:
        return f"power-off took {seconds:.0f} s: a unit waited for its stop timeout (90 s)"
    m = re.search(rb"Failed unmounting [^\r\n]*", clean(console))
    if m:
        return f"the shutdown failed to unmount a file system: {m.group().decode(errors='replace')}"
    return None


def login_and_run(con, a, password, rows, outputs):
    """Log in as root (after the --boots-th kernel start) and run the commands."""
    start = 0
    for n in range(a.boots if a.boots > 1 else 0):
        m = con.wait_for(KERNEL_START, a.timeout, start)
        if not m:
            raise RuntimeError(f"kernel start {n + 1} of {a.boots} not seen within {a.timeout} s")
        start += m.end()
    login(con, a, password, start)
    rows.append(("QEMU start to login prompt", f"{time.monotonic() - con.t0:.1f} s"))
    for i, c in enumerate(a.command):
        start = len(con.buf)
        if c.startswith("@reboot "):
            con.kernels += 1
            con.type(c[len("@reboot "):] + "\r")
            login(con, a, password, start)
            outputs.append((c, 0, f"logged in again {time.monotonic() - con.t0:.1f} s after QEMU start"))
            continue
        # The quotes keep the echoed command line from matching the markers.
        con.type(f"echo @@S''TART{i}@@; {c}; echo @@E''XIT{i}=$?@@\r")
        m = con.wait_for(rf"(?s)@@START{i}@@(.*)@@EXIT{i}=(\d+)@@".encode(), 300, start)
        if not m:
            if con.cut is not None:
                return
            raise RuntimeError(f"no result from: {c}")
        out = re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]|\r", b"", m.group(1)).decode(errors="replace").strip()
        outputs.append((c, int(m.group(2)), out))


def self_test():
    """The console line that split in CI, and lines that must not count."""
    split = (b"[\x1b[0;32m  OK  \x1b[0m] Reached target \x1b[0;1;39mmulti-user.target\x1b[0"
             b"[    9.857548] clocksource: Watchdog remote CPU 1 read timed out\r\nm - Multi-User System.\r\n")
    whole = b"[\x1b[0;32m  OK  \x1b[0m] Reached target \x1b[0;1;39mmulti-user.target\x1b[0m - Multi-User System.\r\r\n"
    target = rb"Reached target multi-user\.target"
    assert re.search(target, clean(split)) and re.search(target, clean(whole))
    assert not re.search(target, clean(b"Created symlink /etc/systemd/system/multi-user.target.wants/x.service\r\n"))
    assert clean(b"[  OK  ] Started x.\r\n[    2.61] systemd[1]: y\r\n") == b"[  OK  ] Started x.\r\n"

    def run(*console, alive=True, **opts):
        """login_and_run on a console that a process prints in place of QEMU: the first part at once,
        each next one after a line is typed (ended by Enter, \\r); then it waits for input (alive)
        or exits. "passed" or the error."""
        a = argparse.Namespace(chat=[], chat_then_login=False, autologin=True, timeout=5, boots=1, command=[])
        vars(a).update(opts)
        sh = ('printf %s "$1"; shift; for s; do IFS= read -r -d "$(printf "\\r")" _; printf %s "$s"; done'
              + ("; exec cat >/dev/null" if alive else ""))
        proc = subprocess.Popen(["bash", "-c", sh, "bash", *console], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                bufsize=0)
        try:
            login_and_run(Console(proc, open(os.devnull, "wb"), kernels=max(a.boots, 1)), a, "", [], [])
            return "passed"
        except RuntimeError as e:
            return str(e)
        finally:
            proc.kill()
            proc.wait()

    # Expected kernel starts pass, one more fails: a reboot before the login prompt, after the
    # --boots N expected ones, or after a chat that should not reboot (or a second one after it).
    boot = "[    0.000000] Linux version 6.16.9+deb14-amd64 (debian-kernel@lists.debian.org)\r\n"
    shell = "localhost login: root (automatic login)\r\n\r\nroot@localhost:~# "
    ask = "Type RESET to reset: "
    reset = {"chat": [ask + "=>RESET"], "chat_then_login": True}
    assert run(boot + shell) == "passed"
    assert run(boot + boot + shell).startswith("unexpected reboot: kernel start 2 on the console, 1 expected")
    assert run(boot * 4 + shell, boots=4) == "passed"
    assert run(boot * 5 + shell, boots=4).startswith("unexpected reboot: kernel start 5")
    assert run(boot + ask + boot + shell, **reset) == "passed"
    assert run(boot + ask + shell, **reset) == "passed"
    assert run(boot + ask + boot + boot + shell, **reset).startswith("unexpected reboot: kernel start 3")
    assert run(boot + ask + boot + shell, chat=[ask + "=>no"]).startswith("unexpected reboot: kernel start 2")
    # The kernel starts allowed but not used (a soft @reboot, a chat without a reboot) end at the
    # next login prompt: a reboot during the next command fails. A full @reboot passes.
    def result(i, out=""):
        return f"@@START{i}@@\r\n{out}@@EXIT{i}=0@@\r\n# "

    soft = {"command": ["@reboot soft", "true"]}
    assert run(boot + shell, shell, result(1), **soft) == "passed"
    assert run(boot + shell, shell, boot + result(1), **soft).startswith("unexpected reboot: kernel start 2")
    assert run(boot + shell, boot + shell, result(1), **soft) == "passed"
    assert run(boot + shell, boot + boot + shell, result(1), **soft).startswith("unexpected reboot: kernel start 3")
    no = {"chat": [ask + "=>no"], "chat_then_login": True, "command": ["true"]}
    assert run(boot + ask, shell, boot + result(0), **no).startswith("unexpected reboot: kernel start 2")
    # The kernel's banner printed by a command is not a kernel start.
    version = "Linux version 6.16.9+deb14-amd64 (debian-kernel@lists.debian.org)\r\n"
    assert run(boot + shell, result(0, version), result(1), command=["cat /proc/version", "true"]) == "passed"
    # A login prompt that QEMU printed just before it exited: a clear error, not a BrokenPipeError.
    assert run(boot + shell, alive=False, command=["true"]).startswith("QEMU exited with code 0")

    # A shutdown that left a file system mounted, or waited for a stop timeout.
    failed = (b"[\x1b[0;1;31mFAILED\x1b[0m] Failed unmounting \x1b[0;1;39mvar.mount\x1b[0m - /var.\r\r\n"
              b"[  OK  ] Reached target \x1b[0;1;39mumount.target\x1b[0m - Unmount All Filesystems.\r\r\n")
    assert poweroff_problem(failed, 3) == ("the shutdown failed to unmount a file system: "
                                           "Failed unmounting var.mount - /var.")
    assert poweroff_problem(b"[  OK  ] Unmounted var.mount - /var.\r\r\n", 3) is None
    assert poweroff_problem(b"", 92).startswith("power-off took 92 s")
    print("vm-boot.py: self-test passed")


def main():
    if sys.argv[1:] == ["--self-test"]:
        return self_test()
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--disk", required=True, help="qcow2 (or .raw) image; not written unless --persist")
    p.add_argument("--persist", action="store_true", help="write to the disk instead of a snapshot")
    p.add_argument("--secure-boot", metavar="VARS", help="Secure Boot firmware with this variable store")
    p.add_argument("--keep-vars", action="store_true", help="write to the --secure-boot store instead of a copy")
    p.add_argument("--refused", metavar="PATTERN", help="expect the boot to be refused with PATTERN")
    p.add_argument("--poweroff", action="store_true", help="shut the guest down cleanly after the commands")
    p.add_argument("--timeout", type=int, default=300, help="seconds to reach the login prompt")
    p.add_argument("--command", action="append", default=[], help="command to run as root in the guest")
    p.add_argument("--log", required=True, help="serial console log file")
    p.add_argument("--summary", required=True, help="Markdown report is appended here")
    p.add_argument("--title", default="VM boot")
    p.add_argument("--autologin", action="store_true", help="root login on the console without a password")
    p.add_argument("--marker", metavar="PATTERN", help="no login: check PATTERN on the console after boot")
    p.add_argument("--marker-expected", choices=["yes", "no"], default="yes")
    p.add_argument("--credential", action="append", default=[], metavar="NAME=TEXT",
                   help="one more systemd credential over SMBIOS")
    p.add_argument("--smbios", action="append", default=[], metavar="STRING",
                   help="one more SMBIOS OEM string (type 11), as it is")
    p.add_argument("--power-cut-at", metavar="REGEX", help="kill QEMU as soon as REGEX shows up on the console")
    p.add_argument("--rtc", metavar="BASE", help="the guest's hardware clock starts at BASE (QEMU -rtc base=)")
    p.add_argument("--boots", type=int, default=1, help="log in after this many kernel starts")
    p.add_argument("--chat", action="append", default=[], metavar="EXPECT=>SEND",
                   help="instead of the login: wait for EXPECT, type SEND (repeatable)")
    p.add_argument("--chat-then-login", action="store_true", help="after the chat, log in at the next login prompt")
    a = p.parse_args()
    if a.keep_vars and not a.secure_boot:
        p.error("--keep-vars needs --secure-boot")

    password = secrets.token_urlsafe(12)
    tmp = tempfile.mkdtemp()
    vars_fd = a.secure_boot if a.keep_vars else f"{tmp}/vars.fd"
    if not a.keep_vars:
        shutil.copyfile(a.secure_boot or OVMF_VARS, vars_fd)
    # The Secure Boot firmware keeps its variables in SMM, out of reach of the guest OS.
    machine = ["q35,smm=on,accel=kvm", "-global", "driver=cfi.pflash01,property=secure,value=on"] \
        if a.secure_boot else ["q35,accel=kvm"]
    disk = f"file={a.disk},format={'raw' if a.disk.endswith('.raw') else 'qcow2'},if=virtio"
    cmd = ["qemu-system-x86_64", "-machine", *machine, "-cpu", "host", "-smp", "2", "-m", "2048",
           "-nodefaults", "-display", "none", "-monitor", "none", "-serial", "stdio",
           "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF_CODE_SECBOOT if a.secure_boot else OVMF_CODE}",
           "-drive", f"if=pflash,format=raw,file={vars_fd}",
           "-drive", disk if a.persist else disk + ",snapshot=on",
           "-nic", "user,model=virtio-net-pci", "-device", "virtio-rng-pci",
           "-smbios", "type=11,value=io.systemd.credential:firstboot.timezone=UTC",
           # A getty on the serial console without console=ttyS0, which a sealed UKI cannot get.
           "-smbios", "type=11,value=io.systemd.credential:getty.ttys.serial=ttyS0"]
    cmd += ["-smbios", "type=11,value=io.systemd.credential.binary:systemd.unit-dropin.emergency.service="
            + base64.b64encode(EMERGENCY.encode()).decode()]
    if a.rtc:
        cmd += ["-rtc", f"base={a.rtc}"]
    if a.autologin:
        cmd += ["-smbios", "type=11,value=io.systemd.credential.binary:systemd.unit-dropin.serial-getty@ttyS0.service="
                + base64.b64encode(AUTOLOGIN.encode()).decode()]
    for c in a.credential:
        name, _, text = c.partition("=")
        cmd += ["-smbios", f"type=11,value=io.systemd.credential.binary:{name}="
                + base64.b64encode(text.encode()).decode()]
    for string in a.smbios:
        cmd += ["-smbios", "type=11,value=" + string.replace(",", ",,")]
    print("+ " + " ".join(cmd), flush=True)
    if not a.autologin:
        cmd += ["-smbios", f"type=11,value=io.systemd.credential:passwd.plaintext-password.root={password}"]

    ok, rows, outputs = True, [], []
    with open(a.log, "wb") as log:
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0)
        con = Console(proc, log, a.power_cut_at and a.power_cut_at.encode(), max(a.boots, 1))
        try:
            if a.refused:
                rows.append(("Boot refused", refused(con, a.refused, a.timeout)))
            elif a.marker:
                rows.append(("Console", marker(con, a.marker, a.marker_expected == "yes", a.timeout)))
            else:
                login_and_run(con, a, password, rows, outputs)
                ok = all(rc == 0 for _, rc, _ in outputs)
                if a.power_cut_at:
                    try:  # the pattern can arrive with the last command's result
                        proc.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        pass
                    if con.cut is None:
                        raise RuntimeError(f"no {a.power_cut_at!r} on the console: no power cut")
                    rows.append(("Power cut", f"QEMU killed at {a.power_cut_at!r}, {con.cut:.1f} s after start"))
                elif ok and a.poweroff:
                    start, t = len(con.buf), time.monotonic()
                    con.type("systemctl poweroff\r")
                    try:
                        proc.wait(timeout=180)
                    except subprocess.TimeoutExpired:
                        raise RuntimeError("no power-off within 180 s") from None
                    took = time.monotonic() - t
                    con.reader.join(5)
                    problem = poweroff_problem(con.buf[start:], took)
                    if problem:
                        raise RuntimeError(problem)
                    rows.append(("Power-off", f"clean, in {took:.1f} s, QEMU exited with code {proc.returncode}"))
        except RuntimeError as e:
            if con.cut is not None and a.power_cut_at:
                ok = all(rc == 0 for _, rc, _ in outputs)
                rows.append(("Power cut", f"QEMU killed at {a.power_cut_at!r}, {con.cut:.1f} s after start"))
            else:
                ok = False
                rows.append(("Error", str(e)))
        finally:
            proc.kill()
            proc.wait()
            shutil.rmtree(tmp)

    with open(a.summary, "a") as f:
        f.write(f"### {a.title}: {'passed' if ok else 'FAILED'}\n\n| Check | Result |\n|---|---|\n")
        f.writelines(f"| {k} | {v} |\n" for k, v in rows)
        f.writelines(f"\n`{c}` (exit {rc})\n```\n{out}\n```\n" for c, rc, out in outputs)
    for k, v in rows:
        print(f"vm-boot: {k}: {v}")
    for c, rc, out in outputs:
        print(f"vm-boot: [{rc}] {c}\n{out}")
    if not ok:
        tail = re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]|\r", b"", con.buf).decode(errors="replace").splitlines()[-40:]
        print("vm-boot: last lines of the serial console:\n" + "\n".join(tail))
        print(f"vm-boot: {a.title}: the whole serial console is in {os.path.basename(a.log)} (the job's serial log artifact)")
    print(f"vm-boot: {'passed' if ok else 'FAILED'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
