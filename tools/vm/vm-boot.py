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
Password requests (a disk's passphrase in the initrd) are answered on the serial
console, where --chat can type them.
Prompts (--chat, --refused, the login and shell prompts) are matched on the console without
kernel messages and colour codes: a kernel message can land in the middle of a prompt. The
console triggers (--power-cut-at, --tpm-fail-at, --qmp, --marker), mostly lines from a unit or a
command but sometimes a kernel message itself ("Linux version"), match on the console as it is or
without kernel messages, and so do the command results.
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
expression EXPECT, wait a second, type SEND and Enter (SEND "@ctrl-d": Control-D alone;
SEND "@sleep N TEXT": wait N seconds more, then type TEXT), in order;
then a root shell prompt must follow (for a boot that asks for something else than
a login, like recovery).
With --chat-then-login a login prompt follows instead (the guest reboots after the
chat, for example), and the script logs in there as usual.
--blind boots without a login, as a machine without the test console add-on (whose measurement
would change PCR 12): it answers the --chat steps (a passphrase prompt on the serial console), then
presses the power button every 10 s and passes when the guest powers itself off within --timeout
seconds, which only a booted system does.
--tpm DIR gives the VM a TPM 2.0 (swtpm, CRB interface) whose state is kept in DIR, so it
persists across runs like a machine's TPM; swtpm is started here and ends with QEMU.
--tpm-fail-at REGEX kills swtpm as soon as REGEX shows up on the console (a TPM that stops answering).
--expect-reboot expects the guest to reboot (the kernel's "Restarting system") before any login
prompt, within --timeout seconds.
--no-carrier boots with the network cable unplugged: the NIC is there, but its link is down from
the start (QEMU starts paused, set_link through QMP, then runs).
--qemu ARG (repeatable) adds ARG to the QEMU command line as it is (a USB controller and a stick).
--qmp 'WHEN=>COMMAND' (repeatable) sends COMMAND (QMP, JSON) to QEMU once, WHEN seconds after QEMU
starts ("12s") or as soon as the regular expression WHEN shows up on the console, like
--power-cut-at: a stick pulled out ({"execute":"device_del",...}) or plugged in again. A command
that was not sent before the end of the run, or that QEMU answers with an error, fails the run.
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

KVM is mandatory: accel=kvm, no fallback to emulation. On an aarch64 host the guest is aarch64
(docs/ARM64.md): QEMU's virt machine with edk2 (AAVMF), the serial console on ttyAMA0, no TPM
(--tpm is refused), and KVM when the host has it, otherwise emulation (TCG), where the devices the
boot waits for get systemd's 90 s instead of the image's 10 s (see TCG_DEVICES).
"""
import argparse
import base64
import json
import os
import platform
import re
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

OVMF_CODE = "/usr/share/OVMF/OVMF_CODE_4M.fd"
OVMF_VARS = "/usr/share/OVMF/OVMF_VARS_4M.fd"
OVMF_CODE_SECBOOT = "/usr/share/OVMF/OVMF_CODE_4M.secboot.fd"
SERIAL = "ttyS0"
# aarch64: Ubuntu's AAVMF_CODE.fd is the build without Secure Boot; no SMM on ARM.
ARM64 = platform.machine() == "aarch64"
if ARM64:
    OVMF_CODE = "/usr/share/AAVMF/AAVMF_CODE.fd"
    OVMF_CODE_SECBOOT = "/usr/share/AAVMF/AAVMF_CODE.secboot.fd"
    OVMF_VARS = "/usr/share/AAVMF/AAVMF_VARS.fd"
    SERIAL = "ttyAMA0"
# Emulated (TCG), the running system's 10 s wait for a device (the image's dev-.device.d/10-nyra.conf)
# is over before udev has even started, so the serial console and the ESP time out, and with them the
# getty and the ESP mount. These get systemd's 90 s back, in a drop-in that sorts after the image's.
# Not every dev-*.device: in the initrd that drop-in would also replace the root's own wait (no limit).
TCG_DEVICES = ("dev-disk-.device", f"dev-{SERIAL}.device")
TCG_DEVICE_TIMEOUT = "[Unit]\nJobRunningTimeoutSec=90s\n"
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
# Password requests (the disk's passphrase or recovery key in the initrd) go to /dev/console, which is
# not the serial port: the sealed command line has no console=ttyS0. The agent answers on ttyS0 instead,
# in the initrd too (it imports the credentials), so a test can type the passphrase there.
ASK_PASSWORD = ("[Service]\nExecStart=\n"
                f"ExecStart=systemd-tty-ask-password-agent --watch --console=/dev/{SERIAL}\n")
# Kernel messages can land in the middle of another line on the console, colour codes included:
# "Reached target \x1b[0;1;39mmulti-user.target\x1b[0[    9.85] clocksource: ...\r\nm - Multi-User System."
KERNEL_LINE = re.compile(rb"\[ *\d+\.\d+\] [^\r\n]*[\r\n]+")
ANSI = re.compile(rb"\x1b\[[0-9;?]*[A-Za-z]")
# The kernel's own line, after its timestamp: not `cat /proc/version` or a typed command.
KERNEL_START = re.compile(rb"\] Linux version \d")


def clean(buf):
    """The console without kernel messages and colour codes, for matching whole status lines."""
    return ANSI.sub(b"", KERNEL_LINE.sub(b"", buf))


def on_console(pattern, buf):
    """PATTERN on the console as it is (a kernel message itself, for example) or without kernel
    messages and colour codes (which can split a line printed by the system)."""
    return re.search(pattern, buf) or re.search(pattern, clean(buf))


def raw_offset(buf, offset):
    """The offset in buf of `offset` in clean(buf): the kernel messages and colour codes that clean()
    removed before it are counted back in, one step at a time, the last step first."""
    for removed, text in ((ANSI, KERNEL_LINE.sub(b"", buf)), (KERNEL_LINE, buf)):
        for m in removed.finditer(text):
            if m.start() < offset:
                offset += m.end() - m.start()
    return offset


def qmp_now(path, *commands):
    """Send QMP commands (dicts) to QEMU's QMP socket, in order; each must succeed."""
    with socket.socket(socket.AF_UNIX) as s:
        for _ in range(50):
            try:
                s.connect(path)
                break
            except OSError:
                time.sleep(0.2)
        else:
            raise RuntimeError(f"no QMP socket at {path}")
        s.settimeout(10)
        f = s.makefile("rwb", buffering=0)
        f.readline()  # the greeting
        for c in ({"execute": "qmp_capabilities"}, *commands):
            f.write(json.dumps(c).encode() + b"\n")
            while "return" not in (r := json.loads(f.readline())):
                if "error" in r:
                    raise RuntimeError(f"QMP {c}: {r['error']}")


def qmp_send(path, command):
    """Send one QMP command (JSON text) to QEMU's QMP socket; QEMU's answer to it."""
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(10)
        s.connect(path)
        f = s.makefile("rwb", buffering=0)
        f.readline()  # the greeting
        for c in ('{"execute": "qmp_capabilities"}', command):
            f.write(c.encode() + b"\n")
            while "return" not in (r := json.loads(f.readline())) and "error" not in r:
                pass  # an event
        return r


class Qmp:
    """The --qmp commands: each sent once, at its time or console pattern, from a thread of its own."""

    def __init__(self, path, specs, t0):
        self.path, self.specs, self.t0, self.lock = path, specs, t0, threading.Lock()
        self.pending, self.done, self.threads = [], [], []
        for spec in specs:
            when, _, command = spec.partition("=>")
            json.loads(command)  # a typo fails at once
            if re.fullmatch(r"\d+(\.\d+)?s", when):
                t = threading.Timer(float(when[:-1]), self.send, (spec, command))
                t.daemon = True
                self.threads.append(t)
            else:
                self.pending.append((re.compile(when.encode()), spec, command))

    def start(self):
        for t in self.threads:
            t.start()

    def check(self, buf):
        """Send the commands whose pattern is now on the console."""
        for item in [p for p in self.pending if on_console(p[0], buf)]:
            self.pending.remove(item)
            t = threading.Thread(target=self.send, args=item[1:], daemon=True)
            self.threads.append(t)
            t.start()

    def send(self, spec, command):
        at = time.monotonic() - self.t0
        try:
            answer = json.dumps(qmp_send(self.path, command))
        except (OSError, ValueError) as e:
            answer = f"error: {e}"
        with self.lock:
            self.done.append((spec, at, answer))

    def results(self):
        """Rows for the summary, and whether every command was sent and answered without an error."""
        for t in self.threads:
            if isinstance(t, threading.Timer):
                t.cancel()  # not due yet: never sent
            if t.is_alive():
                t.join(15)
        with self.lock:
            done = list(self.done)
        sent = {spec for spec, _, _ in done}
        rows = [("QMP", f"`{spec}` at {at:.1f} s: `{answer}`") for spec, at, answer in done]
        missing = [spec for spec in self.specs if spec not in sent]
        rows += [("QMP", f"`{spec}`: never sent") for spec in missing]
        ok = not missing and all('"return"' in answer for _, _, answer in done)
        return rows, ok


class Console:
    """Guest serial console: everything QEMU prints, plus a way to type."""

    def __init__(self, proc, log, cut_at=None, kernels=1, tpm_fail=None, qmp=None):
        self.proc, self.log, self.cut_at, self.qmp = proc, log, cut_at, qmp
        self.tpm_fail = tpm_fail  # (REGEX, swtpm process): --tpm-fail-at
        self.tpm_failed = None  # seconds after start when swtpm was killed
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
            if self.cut_at and self.cut is None and on_console(self.cut_at, self.buf):
                self.proc.kill()
                self.cut = time.monotonic() - self.t0
            if self.tpm_fail and self.tpm_failed is None and on_console(self.tpm_fail[0], self.buf):
                self.tpm_fail[1].kill()
                self.tpm_failed = time.monotonic() - self.t0
            if self.qmp:
                self.qmp.check(self.buf)

    def wait_for(self, pattern, timeout, start=0, cleaned=False):
        """Wait for `pattern` after offset `start` (in clean(buf[start:]) with `cleaned`, whose offsets
        raw_offset() maps back); None on timeout or if QEMU exits. An unexpected kernel start before it
        raises."""
        deadline = time.monotonic() + timeout
        while True:
            exited = self.proc.poll() is not None
            if exited:  # one last look, at everything QEMU printed before it exited
                self.reader.join(5)
            with self.lock:
                buf = self.buf
            m = re.search(pattern, clean(buf[start:]) if cleaned else buf[start:])
            end = len(buf)
            if m:
                end = start + (raw_offset(buf[start:], m.end()) if cleaned else m.start())
            self.check_kernels(buf, end)
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
    (only with console=ttyS0) and no login prompt (the getty on ttyS0 comes from a credential).
    PATTERN and the login prompt are matched without kernel messages too, which can split them."""
    m = con.wait_for(pattern.encode(), timeout, cleaned=True)
    if not m:
        raise RuntimeError(f"no {pattern!r} on the console within {timeout} s")
    end = raw_offset(con.buf, m.end())
    if con.wait_for(rb"Linux version|login: ", 60, end) or con.wait_for(rb"login: ", 0, end, cleaned=True):
        raise RuntimeError("a system started")
    return f"`{m.group().decode(errors='replace')}`, no system started within 60 s"


def expect_reboot(con, timeout):
    """The guest reboots (the kernel's "Restarting system") without reaching a login prompt; with
    --tpm-fail-at, after the TPM failed."""
    m = con.wait_for(rb"reboot: Restarting system", timeout)
    if con.tpm_fail and con.tpm_failed is None:
        raise RuntimeError("the TPM was never made to fail (--tpm-fail-at did not match)")
    with con.lock:
        before = con.buf[:m.start()] if m else con.buf
    if b"login: " in clean(before):
        raise RuntimeError("a login prompt came before the reboot")
    if not m:
        raise RuntimeError(f"no reboot within {timeout} s of the start")
    failed = f"TPM failed {con.tpm_failed:.1f} s after the start; " if con.tpm_failed is not None else ""
    return f"{failed}rebooted {time.monotonic() - con.t0:.1f} s after the start, no login prompt"


def marker(con, pattern, expected, timeout):
    """multi-user.target is reached, 20 s pass, and PATTERN was printed or not, as expected."""
    m = con.wait_for(rb"Reached target multi-user\.target|@@ emergency: diagnostics", timeout, cleaned=True)
    if m and m.group() != b"Reached target multi-user.target":
        con.wait_for(rb"@@ end of diagnostics", 300, cleaned=True)
        raise RuntimeError("the boot ended in emergency mode (diagnostics in the serial log)")
    if not m:
        raise RuntimeError(f"multi-user.target not reached within {timeout} s")
    time.sleep(20)
    with con.lock:
        buf = con.buf
    con.check_kernels(buf, len(buf))
    seen = bool(on_console(pattern.encode(), buf))
    if seen != expected:
        raise RuntimeError(f"{pattern!r} {'not ' if expected else ''}on the console")
    return f"`{pattern}` {'printed' if seen else 'not printed'}, as expected"


def login(con, a, password, start):
    """Wait for a login prompt after offset `start` and log in as root on the console. Prompts are
    matched without kernel messages, which can land in the middle of one."""
    if a.chat:
        chat, a.chat = a.chat, []  # the chat happens once, at the first login
        for step in chat:
            expect, _, send = step.partition("=>")
            m = con.wait_for(expect.encode(), a.timeout, start, cleaned=True)
            if not m:
                raise RuntimeError(f"no {expect!r} on the console within {a.timeout} s")
            start += raw_offset(con.buf[start:], m.end())
            # A second after the prompt, as a person would type: systemd-ask-password prints its
            # prompt before it turns echo off, so input that arrives at once could be echoed.
            time.sleep(1)
            if send.startswith("@sleep "):
                seconds, _, send = send[len("@sleep "):].partition(" ")
                time.sleep(int(seconds))
            con.type("\x04" if send == "@ctrl-d" else send + "\r")
        if not a.chat_then_login:
            if not con.wait_for(rb"# ", 60, start, cleaned=True):
                raise RuntimeError("no root shell after the chat")
            return
        con.kernels += 1  # the guest may reboot after the chat
    m = con.wait_for(rb"login: |@@ emergency: diagnostics", a.timeout, start, cleaned=True)
    if m and m.group() != b"login: ":
        con.wait_for(rb"@@ end of diagnostics", 300, start, cleaned=True)
        raise RuntimeError("the boot ended in emergency mode (diagnostics in the serial log)")
    if not m:
        if con.proc.poll() is not None:
            raise RuntimeError(f"QEMU exited with code {con.proc.returncode} after "
                               f"{time.monotonic() - con.t0:.1f} s, before the login prompt")
        raise RuntimeError(f"no login prompt within {a.timeout} s")
    # From the end of the prompt, not the end of the buffer: with autologin the
    # shell prompt can already be there.
    start += raw_offset(con.buf[start:], m.end())
    # A reboot that was allowed but did not happen (a soft reboot, a chat without one) is not
    # allowed any more.
    con.kernels = len(KERNEL_START.findall(con.buf, 0, start))
    if not a.autologin:
        con.type("root\r")
        if con.wait_for(rb"Password: ", 10, start, cleaned=True):
            start = len(con.buf)
            con.type(password + "\r")
    if not con.wait_for(rb"# ", 60, start, cleaned=True):
        raise RuntimeError("no root shell after logging in on the console")


def blind(con, monitor, chat, timeout):
    """No login: answer the --chat steps on the console (a passphrase prompt), then press the power
    button every 10 s until the guest powers off, within `timeout` seconds of the start."""
    s = socket.socket(socket.AF_UNIX)
    for _ in range(50):
        try:
            s.connect(monitor)
            break
        except OSError:
            time.sleep(0.2)
    start, answered = 0, ""
    for step in chat:
        expect, _, send = step.partition("=>")
        m = con.wait_for(expect.encode(), timeout, start, cleaned=True)
        if not m:
            raise RuntimeError(f"no {expect!r} on the console within {timeout} s")
        start += raw_offset(con.buf[start:], m.end())
        time.sleep(1)  # as in login(): input that arrives with the prompt could be echoed
        con.type(send + "\r")
        answered = f"{len(chat)} prompt(s) answered, "
    while con.proc.poll() is None and time.monotonic() - con.t0 < timeout:
        s.sendall(b"system_powerdown\n")
        try:
            con.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass
    if con.proc.poll() is None:
        raise RuntimeError(f"{answered}the guest did not power off on the power button within {timeout} s: "
                           "it did not boot")
    return f"{answered}powered off on the power button {time.monotonic() - con.t0:.0f} s after the start"


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
        result = rf"(?s)@@START{i}@@(.*)@@EXIT{i}=(\d+)@@".encode()
        m = con.wait_for(result, 300, start, cleaned=True)
        if m:  # the output as printed (dmesg lines included), unless a kernel message split a marker
            m = re.search(result, con.buf[start:]) or m
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
    # A disk's prompt split the same way (--refused).
    prompt = (b"Please enter rec[    4.007221] clocksource: Watchdog remote CPU 1 read timed out\r\n"
              b"overy key for disk root: ")
    assert re.search(rb"Please enter (passphrase or )?recovery key for disk [^\r\n]*:", clean(prompt))

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
    assert run(boot + ask + shell, chat=[ask + "=>@sleep 1 RESET"], chat_then_login=True) == "passed"
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
    # --expect-reboot, and --tpm-fail-at: a process that sleeps stands in for swtpm.
    def reboot(console, fail_at=None):
        proc = subprocess.Popen(["bash", "-c", 'printf %s "$1"; exec sleep 30', "bash", console],
                                stdout=subprocess.PIPE, bufsize=0)
        tpm = subprocess.Popen(["sleep", "30"]) if fail_at else None
        try:
            con = Console(proc, open(os.devnull, "wb"), tpm_fail=(fail_at, tpm) if tpm else None)
            return expect_reboot(con, 2)
        except RuntimeError as e:
            return str(e)
        finally:
            for x in (proc, tpm):
                if x:
                    x.kill()
                    x.wait()

    restart = "[   9.01] reboot: Restarting system\r\n"
    unlocked = "[  OK  ] Finished systemd-cryptsetup@root.service - Cryptography Setup for root.\r\n"
    assert reboot(boot + restart).startswith("rebooted ")
    assert reboot(boot + shell + restart) == "a login prompt came before the reboot"
    assert reboot(boot).startswith("no reboot within 2 s")
    assert reboot(boot + unlocked + restart, rb"Finished .{0,80}Cryptography Setup for root\.").startswith("TPM failed ")
    assert reboot(boot + restart, rb"Cryptography Setup for root").startswith("the TPM was never made to fail")

    # Every prompt matched with a kernel message in the middle of it.
    kmsg = "[    4.007221] clocksource: Watchdog remote CPU 1 read timed out\r\n"
    # Where the match ends on the console itself: after the prompt, before what follows it.
    m = re.search(target, clean(split))
    assert split[raw_offset(split, m.end()):].startswith(b"\x1b[0[    9.857548] clocksource")
    assert raw_offset(prompt + b"x", len(clean(prompt))) == len(prompt)
    # The login prompt (with the autologin shell prompt already after it), the kernel starts
    # counted up to it, the password and shell prompts, the --chat prompts, the emergency markers.
    login_split = "localhost lo" + kmsg + "gin: root (automatic login)\r\n\r\nroot@localhost:~# "
    assert run(boot + login_split) == "passed"
    assert run(boot + boot + login_split).startswith("unexpected reboot: kernel start 2")
    assert run(boot + "localhost login: ", "Pass" + kmsg + "word: ", "\r\nroot@localhost:~#" + kmsg + " ",
               autologin=False) == "passed"
    ask_split = "Type RESET" + kmsg + " to reset: "
    assert run(boot + ask_split, ask_split, boot + login_split,
               chat=[ask + "=>no", ask + "=>RESET"], chat_then_login=True) == "passed"
    assert run(boot + ask_split, "root@localhost:~#" + kmsg + " ", chat=[ask + "=>x"]) == "passed"
    emergency = "@@ emergency: diag" + kmsg + "nostics\r\n@@ end of diag" + kmsg + "nostics\r\n"
    assert run(boot + emergency) == "the boot ended in emergency mode (diagnostics in the serial log)"
    # --expect-reboot: a login prompt before the reboot.
    assert reboot(boot + login_split + restart) == "a login prompt came before the reboot"
    # A command's result markers.
    assert run(boot + shell, "@@START0@@\r\n@@EX" + kmsg + "IT0=0@@\r\n# ", command=["true"]) == "passed"
    # Triggers printed by a unit or a command: --tpm-fail-at (a status line), --power-cut-at.
    unlocked_split = ("[  OK  ] Finished systemd-cryptsetup@root.service - Cryptography Se" + kmsg
                      + "tup for root.\r\n")
    assert reboot(boot + unlocked_split + restart,
                  rb"Finished .{0,80}Cryptography Setup for root\.").startswith("TPM failed ")
    proc = subprocess.Popen(["bash", "-c", 'printf %s "$1"; exec sleep 30', "bash", "POW" + kmsg + "ERCUT\r\n"],
                            stdout=subprocess.PIPE, bufsize=0)
    con = Console(proc, open(os.devnull, "wb"), rb"POWERCUT")
    try:
        proc.wait(timeout=5)  # killed at the pattern
    finally:
        proc.kill()
    assert con.cut is not None

    def ends(console, check, *args, answered=False):
        """check(Console, *args) on a console that a process prints, then exits (after a line is typed,
        with `answered`). The result or the error."""
        sh = 'printf %s "$1"' + ('; IFS= read -r -d "$(printf "\\r")" _' if answered else "")
        proc = subprocess.Popen(["bash", "-c", sh, "bash", console], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                bufsize=0)
        try:
            return check(Console(proc, open(os.devnull, "wb")), *args)
        except RuntimeError as e:
            return str(e)
        finally:
            proc.kill()
            proc.wait()

    # --refused: the prompt, then no system (a kernel start before it is not one), or a login prompt.
    ask_disk, disk_split = "Please enter (passphrase or )?recovery key for disk [^\r\n:]*:", prompt.decode()
    assert ends(boot + disk_split, refused, ask_disk, 2).endswith("no system started within 60 s")
    assert ends(disk_split + boot, refused, ask_disk, 2) == "a system started"
    assert ends(disk_split + "\r\n" + login_split, refused, ask_disk, 2) == "a system started"
    # --blind: the passphrase prompt is answered, then the guest powers off (the process exits).
    with tempfile.TemporaryDirectory() as tmp:
        monitor = socket.socket(socket.AF_UNIX)
        monitor.bind(f"{tmp}/monitor")
        monitor.listen()
        assert ends(boot + disk_split, blind, f"{tmp}/monitor", [ask_disk + "=>key"], 5,
                    answered=True).startswith("1 prompt(s) answered")
        monitor.close()
    # The console of a CI run whose chat timed out: kernel lines inside the prompt and right after
    # its colon.
    ata = "[    3.32{}] ata{}: SATA link down (SStatus 0 SControl 300)\r\n"
    ci = ("Please enter rec" + ata.format("7335", 1) + "overy key for disk root:" + ata.format("9089", 2)
          + " (press TAB for no echo) " + ata.format("0746", 3)
          + "[   81.748225] clocksource: Watchdog remote CPU 1 read timed out\r\n")
    assert run(boot + ci, boot + shell, chat=[ask_disk + "=>key"], chat_then_login=True) == "passed"
    assert ends(boot + ci, refused, ask_disk, 2).endswith("no system started within 60 s")

    # --qmp: a command at its time, one at its console pattern, one whose pattern never comes, and
    # QEMU's error answer, with a stand-in for QEMU's QMP socket.
    tmp = tempfile.mkdtemp()
    server = socket.socket(socket.AF_UNIX)
    server.bind(f"{tmp}/qmp.sock")
    server.listen()

    def serve():
        while True:
            c, _ = server.accept()
            with c, c.makefile("rwb", buffering=0) as f:
                f.write(b'{"QMP": {}}\r\n')
                while line := f.readline():
                    bad = b"nonsense" in line
                    f.write(b'{"event": "X"}\r\n' + (b'{"error": {}}' if bad else b'{"return": {}}') + b"\r\n")

    threading.Thread(target=serve, daemon=True).start()
    good = ['0.2s=>{"execute": "device_del"}', '@@UN''PLUG@@=>{"execute": "device_add"}']
    q = Qmp(f"{tmp}/qmp.sock", good, time.monotonic())
    q.start()
    q.check(b"echo @@UN''PLUG@@")
    assert not q.done
    q.check(b"@@UNPLUG@@\r\n")
    time.sleep(0.5)
    rows, ok = q.results()
    assert ok and len(rows) == 2 and all('{"return": {}}' in v for _, v in rows), rows
    q = Qmp(f"{tmp}/qmp.sock", good + ['60s=>{"execute": "x"}', 'never=>{"execute": "y"}'], time.monotonic())
    q.start()
    q.check(b"@@UNPLUG@@")
    time.sleep(0.5)
    rows, ok = q.results()
    assert not ok and sum("never sent" in v for _, v in rows) == 2, rows
    q = Qmp(f"{tmp}/qmp.sock", ['0s=>{"execute": "nonsense"}'], time.monotonic())
    q.start()
    time.sleep(0.3)
    assert not q.results()[1]
    # A pattern split by a kernel message.
    q = Qmp(f"{tmp}/qmp.sock", good[1:], time.monotonic())
    q.check(b"@@UNPL" + kmsg.encode() + b"UG@@\r\n")
    time.sleep(0.5)
    assert q.results()[1]
    server.close()
    shutil.rmtree(tmp)
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
    p.add_argument("--blind", action="store_true", help="no console: the guest must power off on the power button")
    p.add_argument("--marker-expected", choices=["yes", "no"], default="yes")
    p.add_argument("--credential", action="append", default=[], metavar="NAME=TEXT",
                   help="one more systemd credential over SMBIOS")
    p.add_argument("--smbios", action="append", default=[], metavar="STRING",
                   help="one more SMBIOS OEM string (type 11), as it is")
    p.add_argument("--power-cut-at", metavar="REGEX", help="kill QEMU as soon as REGEX shows up on the console")
    p.add_argument("--tpm", metavar="DIR", help="a TPM 2.0 (swtpm) with its state in DIR")
    p.add_argument("--tpm-fail-at", metavar="REGEX", help="with --tpm: kill swtpm when REGEX shows up")
    p.add_argument("--expect-reboot", action="store_true", help="expect a reboot before any login prompt")
    p.add_argument("--no-carrier", action="store_true", help="the NIC's link down from the start (no cable)")
    p.add_argument("--qemu", action="append", default=[], metavar="ARG", help="one more QEMU argument, as it is")
    p.add_argument("--qmp", action="append", default=[], metavar="WHEN=>COMMAND",
                   help="send a QMP command WHEN seconds (\"12s\") after QEMU starts or at a console pattern")
    p.add_argument("--rtc", metavar="BASE", help="the guest's hardware clock starts at BASE (QEMU -rtc base=)")
    p.add_argument("--boots", type=int, default=1, help="log in after this many kernel starts")
    p.add_argument("--chat", action="append", default=[], metavar="EXPECT=>SEND",
                   help="instead of the login: wait for EXPECT, type SEND (repeatable)")
    p.add_argument("--chat-then-login", action="store_true", help="after the chat, log in at the next login prompt")
    a = p.parse_args()
    if a.keep_vars and not a.secure_boot:
        p.error("--keep-vars needs --secure-boot")
    if a.tpm_fail_at and not a.tpm:
        p.error("--tpm-fail-at needs --tpm")
    # QEMU's virt machine has only TIS TPMs (tpm-tis-device, tpm-tis-i2c); Debian's arm64 kernel has
    # neither driver (only CRB, built in), so the guest would see no TPM and wait for it.
    if ARM64 and a.tpm:
        p.error("--tpm: no TPM on aarch64 (Debian's arm64 kernel has no driver for QEMU virt's TPMs)")

    password = secrets.token_urlsafe(12)
    tmp = tempfile.mkdtemp()
    vars_fd = a.secure_boot if a.keep_vars else f"{tmp}/vars.fd"
    if not a.keep_vars:
        shutil.copyfile(a.secure_boot or OVMF_VARS, vars_fd)
    # The Secure Boot firmware keeps its variables in SMM, out of reach of the guest OS.
    machine = ["q35,smm=on,accel=kvm", "-global", "driver=cfi.pflash01,property=secure,value=on"] \
        if a.secure_boot else ["q35,accel=kvm"]
    qemu, cpu = "qemu-system-x86_64", "host"
    if ARM64:
        accel = "kvm" if os.access("/dev/kvm", os.R_OK | os.W_OK) else "tcg"
        qemu, machine = "qemu-system-aarch64", [f"virt,gic-version=max,accel={accel}"]
        cpu = "host" if accel == "kvm" else "max,pauth-impdef=on"  # the fast pointer authentication
    disk = f"file={a.disk},format={'raw' if a.disk.endswith('.raw') else 'qcow2'},if=virtio"
    cmd = [qemu, "-machine", *machine, "-cpu", cpu, "-smp", "2", "-m", "2048",
           "-nodefaults", "-display", "none", "-serial", "stdio",
           "-monitor", f"unix:{tmp}/monitor,server,nowait" if a.blind else "none",
           "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF_CODE_SECBOOT if a.secure_boot else OVMF_CODE}",
           "-drive", f"if=pflash,format=raw,file={vars_fd}",
           "-drive", disk if a.persist else disk + ",snapshot=on",
           "-nic", "user,id=net0,model=virtio-net-pci", "-device", "virtio-rng-pci",
           "-smbios", "type=11,value=io.systemd.credential:firstboot.timezone=UTC",
           # A getty on the serial console without console=ttyS0, which a sealed UKI cannot get.
           "-smbios", f"type=11,value=io.systemd.credential:getty.ttys.serial={SERIAL}"]
    cmd += ["-smbios", "type=11,value=io.systemd.credential.binary:systemd.unit-dropin.emergency.service="
            + base64.b64encode(EMERGENCY.encode()).decode()]
    cmd += ["-smbios", "type=11,value=io.systemd.credential.binary:systemd.unit-dropin.systemd-ask-password-console.service="
            + base64.b64encode(ASK_PASSWORD.encode()).decode()]
    if ARM64 and accel == "tcg":
        for unit in TCG_DEVICES:
            cmd += ["-smbios", f"type=11,value=io.systemd.credential.binary:systemd.unit-dropin.{unit}~20-emulated="
                    + base64.b64encode(TCG_DEVICE_TIMEOUT.encode()).decode()]
    if a.rtc:
        cmd += ["-rtc", f"base={a.rtc}"]
    if a.no_carrier:
        cmd += ["-S"]
    swtpm = None
    if a.tpm:
        sock = f"{tmp}/swtpm.sock"
        swtpm = subprocess.Popen(["swtpm", "socket", "--tpm2", "--tpmstate", f"dir={a.tpm}",
                                  "--ctrl", f"type=unixio,path={sock}", "--terminate"])
        for _ in range(50):
            if os.path.exists(sock) or swtpm.poll() is not None:
                break
            time.sleep(0.2)
        if not os.path.exists(sock):
            raise SystemExit(f"vm-boot: swtpm did not start (state in {a.tpm})")
        cmd += ["-chardev", f"socket,id=chrtpm,path={sock}", "-tpmdev", "emulator,id=tpm0,chardev=chrtpm",
                "-device", "tpm-crb,tpmdev=tpm0"]
    qmp = Qmp(f"{tmp}/qmp.sock", a.qmp, 0) if a.qmp else None
    if qmp or a.no_carrier:
        cmd += ["-qmp", f"unix:{tmp}/qmp.sock,server=on,wait=off"]
    cmd += a.qemu
    if a.autologin:
        cmd += ["-smbios", f"type=11,value=io.systemd.credential.binary:systemd.unit-dropin.serial-getty@{SERIAL}.service="
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
        con = Console(proc, log, a.power_cut_at and a.power_cut_at.encode(), max(a.boots, 1),
                      (a.tpm_fail_at.encode(), swtpm) if a.tpm_fail_at and swtpm else None, qmp)
        if qmp:
            qmp.t0 = con.t0
            qmp.start()
        try:
            if a.no_carrier:
                qmp_now(f"{tmp}/qmp.sock", {"execute": "set_link", "arguments": {"name": "net0", "up": False}},
                    {"execute": "cont"})
                rows.append(("Network", "no carrier: the NIC's link down from the start"))
            if a.expect_reboot:
                rows.append(("Reboot", expect_reboot(con, a.timeout)))
            elif a.blind:
                rows.append(("Blind boot", blind(con, f"{tmp}/monitor", a.chat, a.timeout)))
            elif a.refused:
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
            if qmp:  # before QEMU goes: a command due now is still answered
                qmp_rows, qmp_ok = qmp.results()
                rows += qmp_rows
                ok = ok and qmp_ok
            proc.kill()
            proc.wait()
            if swtpm:  # it ends by itself once QEMU is gone (--terminate), after writing its state
                try:
                    swtpm.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    swtpm.kill()
                    swtpm.wait()
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
