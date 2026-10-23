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

The files go to OUT: NAME-<seconds>.png for each new screen, NAME-serial.log, NAME.json. The result is
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
        self.file.write(json.dumps({"execute": name, "arguments": arguments}) + "\n")
        self.file.flush()
        while True:
            answer = json.loads(self.file.readline())
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
    qemu = subprocess.Popen(cmd)
    qmp = Qmp(f"{tmp}/qmp.sock")
    t0 = time.monotonic()
    shots, seen, last_hash = [], {"prompt": None, "login": None, "typed": None, "off": None, "reboot": None}, None
    last_text, blind, next_shot, next_power = "", False, 0, 0
    try:
        while time.monotonic() - t0 < a.timeout:
            t = time.monotonic() - t0
            if qemu.poll() is not None:
                seen["off"] = t
                break
            log = open(serial, errors="replace").read()
            if len(BOOTS.findall(log)) >= 2 and not seen["reboot"]:
                seen["reboot"] = t
                print(f"SCREEN-TEST {a.name}: the firmware started a boot entry a second time at {t:.0f} s: "
                      "the machine restarted by itself", flush=True)
                if a.stop_on_reboot:
                    break
            if t >= next_shot:
                next_shot = t + a.shot_every
                png = f"{a.out}/{a.name}-{int(t):04d}.png"
                qmp.execute("screendump", filename=png, format="png")
                digest = hashlib.sha256(open(png, "rb").read()).hexdigest()
                if digest == last_hash:
                    os.remove(png)
                else:
                    last_hash = digest
                    last_text = ocr(png)
                    shots.append((int(t), size(png), last_text))
                    print(f"screen at {t:.0f} s, {size(png)[0]}x{size(png)[1]}: {last_text[:300]!r}", flush=True)
                    if LOGIN.search(last_text) and not seen["login"]:
                        seen["login"] = t
                    if ASKS.search(last_text) and not INACTIVE.search(last_text) and not seen["prompt"]:
                        seen["prompt"] = t
                        print(f"SCREEN-TEST {a.name}: the password prompt is on the screen at {t:.0f} s", flush=True)
            if not seen["typed"] and (seen["prompt"] and t >= seen["prompt"] + 3
                                      or a.blind_after and t >= a.blind_after):
                blind = not seen["prompt"]
                seen["typed"] = t
                print(f"SCREEN-TEST {a.name}: typing the password on the keyboard at {t:.0f} s"
                      + (" (blind: no prompt was read from the screen)" if blind else ""), flush=True)
                qmp.type(password)
                next_power = time.monotonic() - t0 + 90
            if seen["typed"] and t >= next_power:
                qmp.execute("system_powerdown")
                next_power = t + 20
            time.sleep(1)
    finally:
        if qemu.poll() is None:
            qemu.kill()
        qemu.wait()
    seconds = time.monotonic() - t0
    shown = bool(seen["prompt"])
    unlocked = bool(seen["typed"] and seen["off"])
    ok = shown and unlocked
    result = {"name": a.name, "seconds": round(seconds), "prompt_on_screen": shown, "typed_blind": blind,
              "unlocked_and_powered_off": unlocked, "login_prompt_on_screen": bool(seen["login"]),
              "restarted_by_itself": bool(seen["reboot"]), "last_screen": last_text, "screens": shots}
    with open(f"{a.out}/{a.name}.json", "w") as f:
        json.dump(result, f, indent=1)
    print(f"SCREEN-TEST {a.name}: prompt on the screen: {'yes' if shown else 'NO'}; "
          f"password {'typed blind' if blind else 'typed after the prompt' if seen['typed'] else 'not typed'}; "
          f"unlocked (the guest powered off on the power button): {'yes' if unlocked else 'NO'}; "
          f"restarted by itself: {'yes' if seen['reboot'] else 'no'}; "
          f"last screen: {last_text[:200]!r}; {'PASSED' if ok else 'FAILED'}", flush=True)
    def at(key):
        return f"at {seen[key]:.0f} s" if seen[key] else "no"

    with open(a.summary, "a") as f:
        f.write(f"## Screen test: {a.name}\n\n| | |\n|---|---|\n"
                f"| Password prompt read from the screen | {at('prompt') if shown else '**no**'} |\n"
                f"| Password typed | {'blind, after ' + str(a.blind_after) + ' s' if blind else at('typed')} |\n"
                f"| Disk unlocked (guest powered off on the power button) | {'yes' if unlocked else '**no**'} |\n"
                f"| Restarted by itself | {at('reboot')} |\n"
                f"| Login prompt on the screen | {at('login')} |\n"
                f"| Last screen (OCR) | `{last_text[:200]}` |\n\n")
    shutil.rmtree(tmp, ignore_errors=True)
    sys.exit(0 if ok else 1)


main()
