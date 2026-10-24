#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""CI only: installs Nyra OS from the installer ISO onto an empty virtual disk, by the keys a person
presses (docs/ISO.md): QEMU with UEFI, Secure Boot with the Microsoft keys and a TPM, the serial console
as the installer's terminal, and an emulated screen (screen.py) to see which screen is shown.

It goes through the seven screens, with the disk unlocked by the TPM or by a password, makes the first
administrator, writes the recovery key down from the screen where the installer hands the terminal over
(the key is in the text next to the QR code that systemd-cryptenroll draws: the serial console shows
both), presses Enter to say it is written down (nothing is typed back), and does the same for the
one-time password that the installer makes for the Secure Boot key (read from the console, checked
against the alphabet, never written to a file; nothing stands in for MokManager's typing). Then it
checks that the Machine Owner Key was requested (MokNew in the firmware variables, with the Nyra
certificate) and that the recovery key and the one-time password were on the console once. The disk
(WORKDIR/disk.raw), the TPM's state (--tpm-dir) and the secrets (WORKDIR/secrets, mode 0700: the disk
password and the recovery key of a throwaway disk) stay for tools/iso/installed-test.sh, which boots the
installed system.

    tools/iso/install-test.py ISO WORKDIR LOG SUMMARY --unlock password|tpm --tpm-dir DIR [--memory MiB]
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time

import isovm

ENTER, DOWN, TAB, BACKSPACE = b"\r", b"\x1b[B", b"\t", b"\x7f"
KEY = re.compile(r"(?:[cbdefghijklnrtuv]{8}-){7}[cbdefghijklnrtuv]{8}")
# On every error screen of the installer, and on no other.
FAILED = "Details: d · Log:"
ADMIN, ADMIN_PASSWORD = "maria", "Maria-test-2026"
DISK_PASSWORD = "Disk-test-2026"
# The one-time password of the Secure Boot key: 10 of the 32 characters of tools/install/machine.sh, shown in
# two groups of 5 with a dash.
ONE_TIME = r"\b([a-km-np-z2-9]{5}-[a-km-np-z2-9]{5})\b"


def main():
    p = argparse.ArgumentParser()
    p.add_argument("iso")
    p.add_argument("work")
    p.add_argument("log")
    p.add_argument("summary")
    p.add_argument("--unlock", choices=["password", "tpm"], required=True)
    p.add_argument("--tpm-dir", required=True)
    p.add_argument("--memory", type=int, default=8192)
    p.add_argument("--timeout", type=int, default=1800, help="seconds for the installation itself")
    a = p.parse_args()

    secrets = os.path.join(a.work, "secrets")
    os.makedirs(secrets, mode=0o700, exist_ok=True)
    vm = isovm.Vm(a.iso, a.work, a.log, memory=a.memory, tpm_dir=a.tpm_dir)
    rows, failed = [], []
    timings = {}

    def check(what, ok, detail=""):
        print(f"{'ok  ' if ok else 'FAIL'} {what}" + (f": {detail}" if detail else ""), flush=True)
        rows.append((what, "ok" if ok else "FAILED"))
        if not ok:
            failed.append(what)

    def key(*data):
        for d in data:
            vm.send(d)
            vm.settle()

    def type_into(text):
        vm.send(text.encode())
        vm.settle()

    def screen_title(title, timeout=120):
        vm.wait_screen(title, timeout, fail_on=(FAILED,), report=180 if timeout > 300 else 0)
        vm.settle()
        print(f"screen: {title}", flush=True)

    try:
        vm.start()
        vm.wait_screen("Welcome to Nyra OS.", 600)
        t0 = time.monotonic()
        key(ENTER)                                    # Install Nyra OS
        screen_title("1 of 7 · Version")
        vm.wait_screen("This computer is ready.", 120)
        check("screen 1: this computer is ready (UEFI, Secure Boot, TPM, memory)", True)
        key(ENTER)                                    # They match. Continue
        screen_title("2 of 7 · Disk")
        vm.wait_screen("vda", 30)
        key(ENTER)
        screen_title("3 of 7 · Disk encryption")
        if a.unlock == "password":
            key(DOWN, ENTER)
            screen_title("3 of 7 · Disk password")
            type_into(DISK_PASSWORD)
            key(TAB)
            type_into(DISK_PASSWORD)
            vm.press_until("Continue")
            with open(os.path.join(secrets, "disk-password"), "w") as f:
                f.write(DISK_PASSWORD)
            os.chmod(os.path.join(secrets, "disk-password"), 0o600)
            key(ENTER)
        else:
            key(ENTER)
        screen_title("4 of 7 · Administrator")
        vm.send(BACKSPACE * 40)
        vm.settle()
        type_into(ADMIN)
        key(TAB)
        type_into(ADMIN_PASSWORD)
        key(TAB)
        type_into(ADMIN_PASSWORD)
        vm.press_until("Continue")
        key(ENTER)
        screen_title("5 of 7 · Review")
        review = vm.screen.text()
        check("screen 5: the review names the disk, the unlock, the administrator and the release",
              "vda" in review and ADMIN in review
              and re.search(r"^\s*Unlock\s+" + ("This computer’s TPM" if a.unlock == "tpm" else "A password you choose") + r"\s*$", review, re.M), review.replace("\n", " | ")[:300])
        type_into("vda")
        vm.press_until("Erase vda and install")
        key(ENTER)

        # --- the installation, then the recovery key on the terminal the installer hands over -------
        screen_title("6 of 7 · Recovery key", a.timeout)
        timings["install"] = time.monotonic() - t0
        mark = vm.mark()
        key(ENTER)                                    # Show the recovery key
        m = vm.expect(KEY.pattern, 120, since=mark)
        recovery = m.group(0)
        path = os.path.join(secrets, "recovery-key")
        with open(path, "w") as f:
            f.write(recovery)
        os.chmod(path, 0o600)
        check("the recovery key is on the console, in text next to the QR code", True)
        vm.expect(r"Press Enter when you have written it down: ", 30, since=mark)
        time.sleep(1)
        vm.send("\r")                                 # "written it down"; nothing typed back
        screen_title("7 of 7 · Secure Boot key", 300)
        mark = vm.mark()
        key(ENTER)                                    # Show the one-time password
        m = vm.expect(ONE_TIME, 60, since=mark)
        one_time = m.group(1)                         # kept in memory only: no file, no log
        check("the one-time password is on the console, in two groups, made by the installer", True)
        vm.expect(r"Press Enter when you have written the password down: ", 30, since=mark)
        time.sleep(1)
        vm.send("\r")                                 # "written it down"; nothing typed
        screen_title("7 of 7 · Done", 120)
        timings["total"] = time.monotonic() - t0
        check("the installer ends on its Done screen", True, f"installation {timings['install']:.0f} s")
        time.sleep(2)
        vm.pump(1)
        console = vm.text()
        check("the recovery key was on the console once", console.count(recovery) == 1, f"{console.count(recovery)} times")
        check("the one-time password was on the console once", console.count(one_time) == 1 and one_time.replace("-", "") not in console,
              f"{console.count(one_time)} times")
        check("no password was echoed to the console", all(p not in console for p in (DISK_PASSWORD, ADMIN_PASSWORD)))
    except isovm.Timeout as e:
        print(f"FAIL {e}", flush=True)
        failed.append("timeout")
        if FAILED in vm.screen.text():
            # The details of an error screen are the lines of the installer's log.
            vm.send(b"d")
            vm.settle()
            print(f"The details of the error screen:\n{vm.screen.text()}", flush=True)
    finally:
        vm.stop()

    if not failed:
        # The Machine Owner Key request is in the firmware's variables, with the Nyra certificate.
        out = subprocess.run(["virt-fw-vars", "--input", vm.vars_fd, "--output-json", "/dev/stdout"], capture_output=True, text=True, check=True).stdout
        variables = json.loads(out)["variables"]
        mok = [v for v in variables if v["name"] == "MokNew"]
        cert = subprocess.run(["openssl", "x509", "-outform", "DER", "-in", "files/usr/lib/nyra/secureboot/nyra.crt"], capture_output=True, check=True).stdout
        check("the Machine Owner Key is requested (MokNew), with the Nyra certificate",
              len(mok) == 1 and cert.hex() in mok[0]["data"].lower(), f"{len(mok)} variable(s)")
    with open(a.summary, "a") as f:
        f.write(f"## Installation from the ISO ({a.unlock}, {a.memory} MiB, {vm.accel})\n\n")
        if timings:
            f.write(f"Installation (from the first key to the recovery key): {timings.get('install', 0):.0f} s\n\n")
        f.write("| Check | Result |\n|---|---|\n")
        for what, result in rows:
            f.write(f"| {what} | {result} |\n")
        f.write("\n")
    if failed:
        print("failed: " + "; ".join(failed), flush=True)
        sys.exit(1)


main()
