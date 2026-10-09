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

--secure-boot boots the Secure Boot firmware with the given variable store.
--refused PATTERN expects the opposite of a boot: PATTERN shows up on the
console and no system starts (no "Linux version" from a kernel with console=ttyS0,
no login prompt from the getty that a credential puts on ttyS0).
--marker PATTERN, with --marker-expected yes|no, does not log in: it waits until
the console shows that the system reached multi-user.target, waits 20 s more,
and checks whether PATTERN was printed (by a unit, for example).
--credential NAME=TEXT passes one more systemd credential over SMBIOS. The
sealed command line does not import them (docs/BOOT.md); the test disks carry an
add-on that does (tools/vm/test-addon.sh).
--persist writes to the disk (otherwise QEMU snapshot mode), --poweroff ends
with a clean shutdown, so several runs can follow one system across reboots.

KVM is mandatory: accel=kvm, no fallback to emulation.
"""
import argparse
import base64
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


class Console:
    """Guest serial console: everything QEMU prints, plus a way to type."""

    def __init__(self, proc, log):
        self.proc, self.log = proc, log
        self.buf = b""
        self.lock = threading.Lock()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        while chunk := self.proc.stdout.read1(65536):
            with self.lock:
                self.buf += chunk
            self.log.write(chunk)
            self.log.flush()

    def wait_for(self, pattern, timeout, start=0):
        """Wait for `pattern` after offset `start`; None on timeout or if QEMU exits."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline and self.proc.poll() is None:
            with self.lock:
                buf = self.buf
            m = re.search(pattern, buf[start:])
            if m:
                return m
            time.sleep(0.2)
        return None

    def type(self, text):
        self.proc.stdin.write(text.encode())
        self.proc.stdin.flush()


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
    if not con.wait_for(rb"Reached target .*Multi-User System", timeout):
        raise RuntimeError(f"multi-user.target not reached within {timeout} s")
    time.sleep(20)
    with con.lock:
        seen = re.search(pattern.encode(), con.buf) is not None
    if seen != expected:
        raise RuntimeError(f"{pattern!r} {'not ' if expected else ''}on the console")
    return f"`{pattern}` {'printed' if seen else 'not printed'}, as expected"


def login_and_run(con, a, password, t0, rows, outputs):
    """Wait for the login prompt, log in as root and run the commands; True if all exit 0."""
    proc = con.proc
    m = con.wait_for(rb"login: ", a.timeout)
    if not m:
        if proc.poll() is not None:
            raise RuntimeError(f"QEMU exited with code {proc.returncode} after "
                               f"{time.monotonic() - t0:.1f} s, before the login prompt")
        raise RuntimeError(f"no login prompt within {a.timeout} s")
    rows.append(("QEMU start to login prompt", f"{time.monotonic() - t0:.1f} s"))
    # From the end of the prompt, not the end of the buffer: with autologin the
    # shell prompt can already be there.
    start = m.end()
    if not a.autologin:
        con.type("root\r")
        if con.wait_for(rb"Password: ", 10, start):
            start = len(con.buf)
            con.type(password + "\r")
    if not con.wait_for(rb"# ", 60, start):
        raise RuntimeError("no root shell after logging in on the console")
    ok = True
    for i, c in enumerate(a.command):
        start = len(con.buf)
        # The quotes keep the echoed command line from matching the markers.
        con.type(f"echo @@S''TART{i}@@; {c}; echo @@E''XIT{i}=$?@@\r")
        m = con.wait_for(rf"(?s)@@START{i}@@(.*)@@EXIT{i}=(\d+)@@".encode(), 300, start)
        if not m:
            raise RuntimeError(f"no result from: {c}")
        out = re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]|\r", b"", m.group(1)).decode(errors="replace").strip()
        outputs.append((c, int(m.group(2)), out))
        ok = ok and m.group(2) == b"0"
    return ok


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--disk", required=True, help="qcow2 (or .raw) image; not written unless --persist")
    p.add_argument("--persist", action="store_true", help="write to the disk instead of a snapshot")
    p.add_argument("--secure-boot", metavar="VARS", help="Secure Boot firmware with this variable store")
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
    a = p.parse_args()

    password = secrets.token_urlsafe(12)
    tmp = tempfile.mkdtemp()
    shutil.copyfile(a.secure_boot or OVMF_VARS, f"{tmp}/vars.fd")
    # The Secure Boot firmware keeps its variables in SMM, out of reach of the guest OS.
    machine = ["q35,smm=on,accel=kvm", "-global", "driver=cfi.pflash01,property=secure,value=on"] \
        if a.secure_boot else ["q35,accel=kvm"]
    disk = f"file={a.disk},format={'raw' if a.disk.endswith('.raw') else 'qcow2'},if=virtio"
    cmd = ["qemu-system-x86_64", "-machine", *machine, "-cpu", "host", "-smp", "2", "-m", "2048",
           "-nodefaults", "-display", "none", "-monitor", "none", "-serial", "stdio",
           "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF_CODE_SECBOOT if a.secure_boot else OVMF_CODE}",
           "-drive", f"if=pflash,format=raw,file={tmp}/vars.fd",
           "-drive", disk if a.persist else disk + ",snapshot=on",
           "-nic", "user,model=virtio-net-pci", "-device", "virtio-rng-pci",
           "-smbios", "type=11,value=io.systemd.credential:firstboot.timezone=UTC",
           # A getty on the serial console without console=ttyS0, which a sealed UKI cannot get.
           "-smbios", "type=11,value=io.systemd.credential:getty.ttys.serial=ttyS0"]
    if a.autologin:
        cmd += ["-smbios", "type=11,value=io.systemd.credential.binary:systemd.unit-dropin.serial-getty@ttyS0.service="
                + base64.b64encode(AUTOLOGIN.encode()).decode()]
    for c in a.credential:
        name, _, text = c.partition("=")
        cmd += ["-smbios", f"type=11,value=io.systemd.credential.binary:{name}="
                + base64.b64encode(text.encode()).decode()]
    print("+ " + " ".join(cmd), flush=True)
    if not a.autologin:
        cmd += ["-smbios", f"type=11,value=io.systemd.credential:passwd.plaintext-password.root={password}"]

    ok, rows, outputs = True, [], []
    with open(a.log, "wb") as log:
        t0 = time.monotonic()
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        con = Console(proc, log)
        try:
            if a.refused:
                rows.append(("Boot refused", refused(con, a.refused, a.timeout)))
            elif a.marker:
                rows.append(("Console", marker(con, a.marker, a.marker_expected == "yes", a.timeout)))
            else:
                ok = login_and_run(con, a, password, t0, rows, outputs)
                if ok and a.poweroff:
                    con.type("systemctl poweroff\r")
                    try:
                        proc.wait(timeout=180)
                    except subprocess.TimeoutExpired:
                        raise RuntimeError("no power-off within 180 s") from None
                    rows.append(("Power-off", f"clean, QEMU exited with code {proc.returncode}"))
        except RuntimeError as e:
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
    print(f"vm-boot: {'passed' if ok else 'FAILED'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
