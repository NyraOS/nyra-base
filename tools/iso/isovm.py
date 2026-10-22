# SPDX-License-Identifier: GPL-3.0-or-later
"""CI only: a QEMU virtual machine that boots the installer ISO (UEFI, Secure Boot with the Microsoft
keys, a TPM 2.0 from swtpm on x86_64, none on aarch64), and its serial console as the installer's own
terminal: the text that the installer or a shell prints, and the keys a person would press.

x86_64 is the q35 machine with OVMF; aarch64 is QEMU's virt machine with edk2 (AAVMF), whose serial
port is the PL011 one, ttyAMA0 (docs/ISO.md). Without KVM (GitHub's arm64 runners have none) the guest is
emulated (TCG) and every wait is `scale` times longer.

The console is a socket of QEMU's (every byte is also in the log file, which the job uploads). A
program that draws on a terminal first asks it how big it is, with the escape sequence ESC [ 6 n
(the installer does, on a serial port, which has no window size); the console answers it as a
terminal of 80 columns and 24 rows would. What is looked for is the text without escape sequences.
"""
import os
import re
import select
import shutil
import socket
import subprocess
import tempfile
import time

# Per architecture: the QEMU command, the firmware (code with Secure Boot, and variables with the Microsoft
# keys enrolled), the serial console of the guest, and whether a TPM can be given (QEMU's virt machine has
# only TIS TPMs, which Debian's arm64 kernel has no driver for: docs/ARM64.md).
ARCHES = {
    "amd64": {"qemu": "qemu-system-x86_64", "code": "/usr/share/OVMF/OVMF_CODE_4M.secboot.fd",
              "vars": "/usr/share/OVMF/OVMF_VARS_4M.ms.fd", "serial": "ttyS0", "tpm": True, "bootindex": ""},
    "arm64": {"qemu": "qemu-system-aarch64", "code": "/usr/share/AAVMF/AAVMF_CODE.secboot.fd",
              "vars": "/usr/share/AAVMF/AAVMF_VARS.ms.fd", "serial": "ttyAMA0", "tpm": False,
              # The firmware boots the ISO, not whatever else it finds first.
              "bootindex": ",bootindex=0"},
}
# How much longer every wait is without KVM.
TCG_SCALE = 5
# Control sequences (CSI, OSC, two-character ones) and the bytes that only move the cursor.
ESCAPES = re.compile(rb"\x1b\[[0-9;?<=>]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[()][0-9A-Za-z]|\x1b[=>78cDEHMNOZ]|\x00")


class Timeout(Exception):
    pass


def plain(data: bytes) -> str:
    """The text of terminal output: no escape sequences, no carriage returns."""
    return ESCAPES.sub(b"", data).replace(b"\r", b"").decode("utf-8", "replace")


class Vm:
    """QEMU with the ISO and an empty disk. start() boots it; the console methods read and type."""

    def __init__(self, iso, work, log, *, arch="amd64", medium="cd", memory=8192, disk_gb=64, accel=None, tpm=True,
                 smp=2, disk=True, decoy=None, extra=()):
        self.iso, self.work, self.log = iso, work, log
        self.arch = ARCHES[arch]
        self.accel = accel or ("kvm" if os.access("/dev/kvm", os.R_OK | os.W_OK) else "tcg")
        self.scale = 1 if self.accel == "kvm" else TCG_SCALE
        # The emulated guest of an arm64 runner is slow: its four cores all run the guest.
        if arch == "arm64" and self.accel == "tcg" and smp == 2:
            smp = os.cpu_count() or 2
        self.medium, self.memory, self.disk_gb, self.smp, self.disk = medium, memory, disk_gb, smp, disk
        self.tpm = tpm and self.arch["tpm"]
        self.extra = list(extra)
        self.decoy = decoy  # a second medium, attached before the ISO: a file
        self.qemu = self.swtpm = self.sock = None
        self.raw = b""  # everything the console printed
        self.answered = 0  # how much of raw has been looked at for size questions
        self.started = None

    # --- starting and stopping ----------------------------------------------------------------------
    def start(self):
        os.makedirs(self.work, exist_ok=True)
        vars_fd = os.path.join(self.work, "vars.fd")
        shutil.copyfile(self.arch["vars"], vars_fd)
        self.vars_fd = vars_fd
        sock = os.path.join(self.work, "console.sock")
        for path in (sock,):
            if os.path.exists(path):
                os.unlink(path)
        cpu = "host" if self.accel == "kvm" else "max"
        if self.arch["qemu"] == "qemu-system-x86_64":
            # The Secure Boot variables are kept in SMM, out of reach of the guest.
            machine = ["-machine", f"q35,smm=on,accel={self.accel}", "-cpu", cpu,
                       "-global", "driver=cfi.pflash01,property=secure,value=on"]
        else:
            # ARM has no SMM: the guest can write the variable store (docs/ARM64.md, a limit of the machine).
            machine = ["-machine", f"virt,gic-version=max,accel={self.accel}",
                       "-cpu", "host" if self.accel == "kvm" else "max,pauth-impdef=on"]
        cmd = [self.arch["qemu"], *machine,
               "-smp", str(self.smp), "-m", str(self.memory), "-nodefaults", "-display", "none",
               "-drive", f"if=pflash,format=raw,readonly=on,file={self.arch['code']}",
               "-drive", f"if=pflash,format=raw,file={vars_fd}",
               "-chardev", f"socket,id=console,path={sock},server=on,wait=off,logfile={self.log}",
               "-serial", "chardev:console", "-device", "virtio-rng-pci", "-nic", "none",
               ]
        if self.decoy or self.medium == "usb":
            cmd += ["-device", "qemu-xhci,id=xhci"]
        if self.decoy:
            # Another medium that looks like an installer: a second USB stick, attached before the ISO.
            cmd += ["-drive", f"if=none,id=decoy,format=raw,readonly=on,file={self.decoy}",
                    "-device", "usb-storage,drive=decoy,bus=xhci.0,removable=on"]
        if self.medium == "usb":
            # The ISO as a USB stick (a disk, not a CD): the hybrid image boots from its own EFI partition.
            cmd += ["-drive", f"if=none,id=iso,format=raw,readonly=on,file={self.iso}",
                    "-device", "usb-storage,drive=iso,bus=xhci.0,removable=on" + self.arch["bootindex"]]
        elif self.arch["qemu"] == "qemu-system-x86_64":
            cmd += ["-drive", f"if=none,id=iso,format=raw,media=cdrom,readonly=on,file={self.iso}",
                    "-device", "ich9-ahci,id=ahci", "-device", "ide-cd,drive=iso,bus=ahci.0"]
        else:
            # A SCSI CD-ROM on virtio-scsi (the virt machine has no IDE); the firmware boots it first.
            cmd += ["-drive", f"if=none,id=iso,format=raw,media=cdrom,readonly=on,file={self.iso}",
                    "-device", "virtio-scsi-pci,id=scsi0", "-device", "scsi-cd,drive=iso,bus=scsi0.0" + self.arch["bootindex"]]
        if self.disk:
            self.disk_path = os.path.join(self.work, "disk.raw")
            with open(self.disk_path, "wb") as f:
                f.truncate(self.disk_gb << 30)
            cmd += ["-drive", f"if=none,id=disk,format=raw,file={self.disk_path}", "-device", "virtio-blk-pci,drive=disk"]
        if self.tpm:
            # Where Ubuntu's AppArmor profile of swtpm lets it work, as tools/vm/vm-boot.py has it: the state
            # in the runner's temporary directory, the control socket in /tmp. Not under the job's own
            # directory (/mnt/work), where swtpm gets "Could not open UnixIO socket: Permission denied".
            tpm_dir = tempfile.mkdtemp(prefix="iso-tpm-", dir=os.environ.get("RUNNER_TEMP") or None)
            tpm_sock = os.path.join(tempfile.mkdtemp(), "swtpm.sock")
            self.swtpm = subprocess.Popen(["swtpm", "socket", "--tpm2", "--tpmstate", f"dir={tpm_dir}",
                                           "--ctrl", f"type=unixio,path={tpm_sock}", "--terminate"])
            for _ in range(50):
                if os.path.exists(tpm_sock) or self.swtpm.poll() is not None:
                    break
                time.sleep(0.2)
            if not os.path.exists(tpm_sock):
                raise SystemExit("swtpm did not start")
            cmd += ["-chardev", f"socket,id=chrtpm,path={tpm_sock}", "-tpmdev", "emulator,id=tpm0,chardev=chrtpm",
                    "-device", "tpm-crb,tpmdev=tpm0"]
        cmd += self.extra
        print("+ " + " ".join(cmd), flush=True)
        self.started = time.monotonic()
        self.qemu = subprocess.Popen(cmd)
        for _ in range(100):
            if os.path.exists(sock) or self.qemu.poll() is not None:
                break
            time.sleep(0.1)
        if not os.path.exists(sock):
            raise SystemExit("QEMU did not start")
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.connect(sock)
        self.sock.setblocking(False)

    def stop(self):
        if self.sock:
            self.sock.close()
        if self.qemu and self.qemu.poll() is None:
            self.qemu.kill()
        if self.qemu:
            self.qemu.wait()
        if self.swtpm:
            try:
                self.swtpm.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.swtpm.kill()
                self.swtpm.wait()

    def seconds(self):
        return time.monotonic() - self.started

    # --- the console ---------------------------------------------------------------------------------
    def pump(self, wait=0.5):
        """Reads what the console printed, and answers the size questions in it."""
        ready, _, _ = select.select([self.sock], [], [], wait)
        if ready:
            try:
                data = self.sock.recv(65536)
            except BlockingIOError:
                data = b""
            self.raw += data
        # ESC [ 6 n: where is the cursor? The installer put it at the far corner (999;999) first.
        while True:
            i = self.raw.find(b"\x1b[6n", self.answered)
            if i < 0:
                break
            self.answered = i + 4
            self.sock.send(b"\x1b[24;80R")

    def mark(self):
        """A position in the console's output: expect(since=mark) looks only at what comes after it."""
        return len(self.raw)

    def text(self, since=0):
        return plain(self.raw[since:])

    def expect(self, pattern, timeout, since=0):
        """Waits until the text after SINCE matches PATTERN (a regular expression); returns the match."""
        regex = re.compile(pattern, re.S)
        end = time.monotonic() + timeout * self.scale
        while True:
            self.pump()
            m = regex.search(self.text(since))
            if m:
                return m
            if self.qemu.poll() is not None:
                self.pump(0.2)
                m = regex.search(self.text(since))
                if m:
                    return m
                raise Timeout(f"QEMU ended while waiting for {pattern!r}; the console ended with:\n{self.text()[-1500:]}")
            if time.monotonic() > end:
                raise Timeout(f"no {pattern!r} within {timeout * self.scale} s; the console ended with:\n{self.text()[-1500:]}")

    def send(self, data):
        self.sock.send(data if isinstance(data, bytes) else data.encode())

    def run(self, command, timeout=60):
        """Types COMMAND into the shell on the console and returns (exit status, output)."""
        n = self.mark()
        self.send(command + "; echo @@RC@@$?@@\n")
        m = self.expect(r"@@RC@@(\d+)@@", timeout, since=n)
        out = self.text(n)[: self.text(n).index(m.group(0))]
        # What the terminal echoed of the command is not its output.
        lines = [line for line in out.split("\n") if "@@RC@@$?@@" not in line]
        return int(m.group(1)), "\n".join(lines).strip()
