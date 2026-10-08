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

KVM is mandatory: accel=kvm, no fallback to emulation.
"""
import argparse
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


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--disk", required=True, help="qcow2 image; never written (QEMU snapshot mode)")
    p.add_argument("--timeout", type=int, default=300, help="seconds to reach the login prompt")
    p.add_argument("--command", action="append", default=[], help="command to run as root in the guest")
    p.add_argument("--log", required=True, help="serial console log file")
    p.add_argument("--summary", required=True, help="Markdown report is appended here")
    p.add_argument("--title", default="VM boot")
    a = p.parse_args()

    password = secrets.token_urlsafe(12)
    tmp = tempfile.mkdtemp()
    shutil.copyfile(OVMF_VARS, f"{tmp}/vars.fd")
    cmd = ["qemu-system-x86_64", "-machine", "q35,accel=kvm", "-cpu", "host", "-smp", "2", "-m", "2048",
           "-nodefaults", "-display", "none", "-monitor", "none", "-serial", "stdio",
           "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF_CODE}",
           "-drive", f"if=pflash,format=raw,file={tmp}/vars.fd",
           "-drive", f"file={a.disk},format=qcow2,if=virtio,snapshot=on",
           "-nic", "user,model=virtio-net-pci", "-device", "virtio-rng-pci",
           "-smbios", "type=11,value=io.systemd.credential:firstboot.timezone=UTC"]
    print("+ " + " ".join(cmd), flush=True)
    cmd += ["-smbios", f"type=11,value=io.systemd.credential:passwd.plaintext-password.root={password}"]

    ok, rows, outputs = True, [], []
    with open(a.log, "wb") as log:
        t0 = time.monotonic()
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        con = Console(proc, log)
        try:
            if not con.wait_for(rb"login: ", a.timeout):
                if proc.poll() is not None:
                    raise RuntimeError(f"QEMU exited with code {proc.returncode} after "
                                       f"{time.monotonic() - t0:.1f} s, before the login prompt")
                raise RuntimeError(f"no login prompt within {a.timeout} s")
            rows.append(("QEMU start to login prompt", f"{time.monotonic() - t0:.1f} s"))
            start = len(con.buf)
            con.type("root\r")
            if con.wait_for(rb"Password: ", 10, start):
                start = len(con.buf)
                con.type(password + "\r")
            if not con.wait_for(rb"# ", 60, start):
                raise RuntimeError("no root shell after logging in on the console")
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
    print(f"vm-boot: {'passed' if ok else 'FAILED'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
