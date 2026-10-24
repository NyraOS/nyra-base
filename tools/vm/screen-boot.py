#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""CI only (tools/vm/arm64-display.sh, docs/ARM64.md): boots an installed aarch64 disk with a screen and
a keyboard, as a person's virtual machine in UTM on Apple Silicon has them, and watches the screen.

QEMU's virt machine with edk2 (AAVMF) and Secure Boot, a virtio GPU, a USB keyboard on an xHCI
controller, a virtio console (the firmware's and systemd-stub's view of it is what makes the kernel's last
console= the screen, tty0), a serial port and a virtio disk. No test console add-on, no credentials: the
sealed command line as a person's machine runs it. Every --shot-every seconds the screen is saved
(QMP screendump, a PNG) and read with tesseract. When the text asks for a passphrase, the password is
typed on the keyboard (QMP send-key), and the power button is pressed until the guest powers itself off,
which only a system that is up does (the initrd does not answer it). The test passes when the prompt was
on the screen and the password opened the disk.

  --blind-after SECONDS  type the password after that time even if no prompt was read from the screen, to
                         tell "the screen is dead" from "the disk cannot be unlocked"
  --stop-on-reboot       end the run when the firmware starts a boot entry for the second time (the
                         initrd gave up and restarted the machine)

The disk counts as unlocked only if all of this happened: the password was typed after the prompt was
read from the screen, a login prompt was read from the screen after that (a running system), the power
button was pressed, and QEMU ended by itself with status 0 (the guest powered off). A password typed
blind (no prompt was read) is a diagnosis, never a pass. It can land on a login prompt and be echoed
there, so from then on the screens are read but neither kept nor printed, and the password is blanked in
the serial log.

The files go to OUT: NAME-<seconds>.png for each new screen (none after a blind typing), NAME-serial.log, NAME.json. The result is
printed as lines that start with "SCREEN-TEST NAME:" and appended as a Markdown table to --summary.
Exit status: 0 passed, 1 failed (the text of the failure is in the lines above).
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time

CODE = "/usr/share/AAVMF/AAVMF_CODE.secboot.fd"
ASKS = re.compile(r"passphrase|recovery key|enter password|password for", re.I)
INACTIVE = re.compile(r"not active", re.I)
LOGIN = re.compile(r"login:", re.I)
BOOTS = re.compile(r"BdsDxe: starting Boot")


HIDDEN = "(not kept: the password was typed blind)"


class QemuExited(Exception):
    """QEMU ended while a QMP command was on its way."""


class Qmp:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX)
        for _ in range(100):
            try:
                self.sock.connect(path)
                break
            except OSError:
                time.sleep(0.1)
        else:
            raise SystemExit(f"screen-boot: no QMP socket {path}")
        self.file = self.sock.makefile("rw")
        self.file.readline()
        self.execute("qmp_capabilities")

    def execute(self, name, **arguments):
        try:
            self.file.write(json.dumps({"execute": name, "arguments": arguments}) + "\n")
            self.file.flush()
        except OSError as e:
            raise QemuExited(name) from e
        while True:
            line = self.file.readline()
            if line == "":
                raise QemuExited(name)
            answer = json.loads(line)
            if "return" in answer:
                return answer["return"]
            if "error" in answer:
                raise RuntimeError(f"{name}: {answer['error']}")

    def type(self, text):
        for ch in text + "\n":
            key = "ret" if ch == "\n" else ch.lower()
            keys = [{"type": "qcode", "data": key}]
            if ch.isupper():
                keys.insert(0, {"type": "qcode", "data": "shift"})
            self.execute("send-key", keys=keys, **{"hold-time": 60})
            time.sleep(0.4)


def ocr(png):
    out = subprocess.run(["tesseract", png, "stdout", "--psm", "6"], capture_output=True, text=True)
    return " ".join(out.stdout.split())


def size(png):
    with open(png, "rb") as f:
        head = f.read(24)
    return struct.unpack(">II", head[16:24])


class Watch:
    """Looks at the screen, types the password, presses the power button; keeps what happened."""

    def __init__(self, a, qemu, qmp, password, serial):
        self.a, self.qemu, self.qmp, self.password, self.serial = a, qemu, qmp, password, serial
        self.t0 = time.monotonic()
        self.seen = {"prompt": None, "login": None, "typed": None, "off": None, "reboot": None}
        self.shots, self.last_hash, self.last_text = [], None, ""
        self.blind = self.pressed = False
        self.next_shot = self.next_power = 0
        self.exit_status = None  # QEMU's own, when it ended by itself (not killed by this script)

    def now(self):
        return time.monotonic() - self.t0

    def run(self):
        try:
            while self.now() < self.a.timeout and not self.ended() and not self.restarted():
                self.look()
                self.type_when_ready()
                self.press_power()
                time.sleep(1)
        except QemuExited:
            # QEMU ended between the poll and a QMP command: the same as a poll that sees it.
            self.qemu.wait(timeout=30)
            self.ended()

    def ended(self):
        if self.qemu.poll() is None:
            return False
        self.exit_status = self.qemu.returncode
        self.seen["off"] = self.now()
        return True

    def restarted(self):
        if len(BOOTS.findall(open(self.serial, errors="replace").read())) < 2 or self.seen["reboot"]:
            return False
        self.seen["reboot"] = self.now()
        print(f"SCREEN-TEST {self.a.name}: the firmware started a boot entry a second time at "
              f"{self.now():.0f} s: the machine restarted by itself", flush=True)
        return self.a.stop_on_reboot

    def look(self):
        t = self.now()
        if t < self.next_shot:
            return
        self.next_shot = t + self.a.shot_every
        png = f"{self.a.out}/{self.a.name}-{int(t):04d}.png"
        self.qmp.execute("screendump", filename=png, format="png")
        digest = hashlib.sha256(open(png, "rb").read()).hexdigest()
        if digest == self.last_hash:
            os.remove(png)
            return
        self.last_hash = digest
        text, dimensions = ocr(png), size(png)
        # After a blind typing the password may be on the screen (echoed at a login prompt): the text is
        # read for the checks below and then dropped, with the picture.
        if self.blind:
            os.remove(png)
        self.last_text = HIDDEN if self.blind else text
        self.shots.append((int(t), dimensions, self.last_text))
        print(f"screen at {t:.0f} s, {dimensions[0]}x{dimensions[1]}: {self.last_text[:300]!r}", flush=True)
        if self.seen["typed"]:
            if LOGIN.search(text) and not self.seen["login"]:
                self.seen["login"] = t
        elif ASKS.search(text) and not INACTIVE.search(text) and not self.seen["prompt"]:
            self.seen["prompt"] = t
            print(f"SCREEN-TEST {self.a.name}: the password prompt is on the screen at {t:.0f} s", flush=True)

    def type_when_ready(self):
        t, a = self.now(), self.a
        if self.seen["typed"]:
            return
        if not (self.seen["prompt"] and t >= self.seen["prompt"] + 3 or a.blind_after and t >= a.blind_after):
            return
        self.blind = not self.seen["prompt"]
        self.seen["typed"] = t
        print(f"SCREEN-TEST {a.name}: typing the password on the keyboard at {t:.0f} s"
              + (" (blind: no prompt was read from the screen)" if self.blind else ""), flush=True)
        self.qmp.type(self.password)
        self.next_power = self.now() + 90

    def press_power(self):
        if self.seen["typed"] and self.now() >= self.next_power:
            self.pressed = True  # before the command: QEMU may end while it is on its way
            self.qmp.execute("system_powerdown")
            self.next_power = self.now() + 20


def start_qemu(a, tmp, serial):
    vars_fd = f"{tmp}/vars.fd"
    shutil.copyfile(a.vars, vars_fd)
    kvm = os.access("/dev/kvm", os.R_OK | os.W_OK)
    cmd = ["qemu-system-aarch64", "-machine", f"virt,gic-version=max,accel={'kvm' if kvm else 'tcg'}",
           "-cpu", "host" if kvm else "max,pauth-impdef=on", "-smp", "2", "-m", "4096",
           "-nodefaults", "-display", "none", "-monitor", "none", "-serial", f"file:{serial}",
           "-qmp", f"unix:{tmp}/qmp.sock,server=on,wait=off",
           "-drive", f"if=pflash,format=raw,readonly=on,file={CODE}",
           "-drive", f"if=pflash,format=raw,file={vars_fd}",
           "-drive", f"file={a.disk},format=raw,if=virtio,snapshot=on",
           "-nic", "user,model=virtio-net-pci", "-device", "virtio-rng-pci",
           # UTM's: a virtio GPU, a USB keyboard on an xHCI controller, a virtio console.
           "-device", "virtio-gpu-pci", "-device", "qemu-xhci", "-device", "usb-kbd",
           "-device", "virtio-serial-pci", "-chardev", "null,id=hvc", "-device", "virtconsole,chardev=hvc"]
    print("+ " + " ".join(cmd), flush=True)
    return subprocess.Popen(cmd)


def write_results(a, w, ok, unlocked, shown):
    seen = w.seen
    result = {"name": a.name, "seconds": round(w.now()), "prompt_on_screen": shown, "typed_blind": w.blind,
              "unlocked": unlocked, "login_prompt_on_screen": bool(seen["login"]),
              "powered_off_on_the_button": w.pressed and w.exit_status == 0,
              "restarted_by_itself": bool(seen["reboot"]), "last_screen": w.last_text, "screens": w.shots}
    with open(f"{a.out}/{a.name}.json", "w") as f:
        json.dump(result, f, indent=1)
    how = "typed blind" if w.blind else "typed after the prompt" if seen["typed"] else "not typed"
    print(f"SCREEN-TEST {a.name}: prompt on the screen: {'yes' if shown else 'NO'}; password {how}; "
          f"unlocked (login prompt read, guest powered off on the power button): {'yes' if unlocked else 'NO'}; "
          f"restarted by itself: {'yes' if seen['reboot'] else 'no'}; "
          f"last screen: {w.last_text[:200]!r}; {'PASSED' if ok else 'FAILED'}", flush=True)

    def at(key):
        return f"at {seen[key]:.0f} s" if seen[key] else "no"

    with open(a.summary, "a") as f:
        f.write(f"## Screen test: {a.name}\n\n| | |\n|---|---|\n"
                f"| Password prompt read from the screen | {at('prompt') if shown else '**no**'} |\n"
                f"| Password typed | {'blind, after ' + str(a.blind_after) + ' s' if w.blind else at('typed')} |\n"
                f"| Login prompt read from the screen after that | {at('login')} |\n"
                f"| Guest powered off on the power button (QEMU status 0) | {'yes' if w.pressed and w.exit_status == 0 else '**no**'} |\n"
                f"| Disk unlocked (all of the above) | {'yes' if unlocked else '**no**'} |\n"
                f"| Restarted by itself | {at('reboot')} |\n"
                f"| Last screen (OCR) | `{w.last_text[:200]}` |\n\n")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--name", required=True)
    p.add_argument("--disk", required=True, help="raw disk image; QEMU's snapshot mode, never written")
    p.add_argument("--vars", required=True, help="AAVMF variable store (Secure Boot keys and the MOK); copied")
    p.add_argument("--out", required=True)
    p.add_argument("--summary", required=True)
    p.add_argument("--password-file", required=True)
    p.add_argument("--timeout", type=int, default=1200)
    p.add_argument("--shot-every", type=int, default=15)
    p.add_argument("--blind-after", type=int, default=0)
    p.add_argument("--stop-on-reboot", action="store_true")
    a = p.parse_args()
    if not shutil.which("tesseract"):
        raise SystemExit("screen-boot: tesseract is needed to read the screen")
    os.makedirs(a.out, exist_ok=True)
    password = open(a.password_file).read()
    tmp = tempfile.mkdtemp()
    serial = f"{a.out}/{a.name}-serial.log"
    qemu = start_qemu(a, tmp, serial)
    try:
        w = Watch(a, qemu, Qmp(f"{tmp}/qmp.sock"), password, serial)
        w.run()
    finally:
        if qemu.poll() is None:
            qemu.kill()
        qemu.wait()
    # A blind typing can echo the password into the serial log: it does not leave this script.
    log = open(serial, errors="replace").read()
    open(serial, "w").write(log.replace(password, "***"))
    shown = bool(w.seen["prompt"])
    unlocked = bool(shown and not w.blind and w.seen["login"] and w.pressed and w.exit_status == 0)
    ok = shown and unlocked
    write_results(a, w, ok, unlocked, shown)
    shutil.rmtree(tmp, ignore_errors=True)
    sys.exit(0 if ok else 1)


main()
