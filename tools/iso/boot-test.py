#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""CI only: boots the installer ISO in QEMU (UEFI, Secure Boot with the Microsoft keys, a TPM, an empty
disk) and checks what a person sees and what the session is (docs/ISO.md):

  - the installer's first screen appears on the serial console, and no login prompt does;
  - from its menu, "Open a shell" gives a shell as root; in it: Secure Boot is on, only the loopback
    interface exists and only the registry on 127.0.0.1 listens, nothing is running to log in with, the
    release tree is read-only and root's, `check` and `disks` answer, the empty disk is offered and the
    medium the ISO was started from is not (as a CD and as a USB stick), and the image on the ISO passes
    the verified pull with the policy of the release tree, offline;
  - with --decoy, a second USB stick is attached before the ISO: labelled NYRA-ISO, with a /boot/vmlinuz and
    a release tree of its own, which name another release. The session must use the ISO it booted from
    only: its kernel, its release tree and its registry, not the decoy's;
  - with --refusal, the ISO has been altered (one byte of the image's layer in the registry store, or a
    RELEASE that names another digest): in the shell, the verified pull must be refused and leave no image;
  - leaving the shell goes back to the installer's menu, not to a prompt;
  - the memory the session uses, and the time to the first screen, go to the summary.

    tools/iso/boot-test.py ISO WORKDIR LOG SUMMARY [--medium cd|usb] [--memory MiB] [--pull] [--decoy]
                               [--refusal layer|digest]
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time

import isovm

MENU_DOWN = b"\x1b[B"


def volume_label(iso):
    """The volume identifier of an ISO 9660 image: 32 bytes at offset 40 of the primary volume descriptor
    (the 17th sector), padded with spaces."""
    with open(iso, "rb") as f:
        f.seek(16 * 2048)
        pvd = f.read(2048)
    if pvd[1:6] != b"CD001":
        raise SystemExit(f"{iso} has no ISO 9660 volume descriptor")
    return pvd[40:72].decode("ascii").rstrip()


class Done(Exception):
    pass


def refusal(sh, check, kind):
    """The pull of the image on an altered ISO is refused for the reason that was made, and nothing is left
    in the storage. A registry or a tool that fails is not a refusal: the messages of verified-pull.sh tell
    the cases apart."""
    status, out = sh("cat /usr/lib/nyra/release/RELEASE")
    release = dict(line.split("=", 1) for line in out.splitlines() if "=" in line)
    storage = "/var/lib/containers/storage"
    status, out = sh(f"r=$(/usr/lib/nyra/release/tools/install/verified-pull.sh nyra-base {release['version']} {release['digest']} {storage} 2>&1); "
                     'rc=$?; echo "$r" | tail -n 6; echo "pull-status=$rc"', 900)
    m = re.search(r"pull-status=(\d+)", out)
    code = m.group(1) if m else None
    if kind == "digest":
        # verified-pull.sh: the pull worked and the image is not the release's (exit 2).
        ok = code == "2" and re.search(r"nyra-base:[0-9.]+ is sha256:[0-9a-f]{64}, not sha256:f{64}", out) is not None
        what = "another digest in RELEASE: refused as not the release (exit 2, the tag's digest is not the one asked)"
    else:
        # The layer's bytes are not the ones its digest names: skopeo stops the copy (exit 1, "cannot pull")
        # with "Digest did not match", and the reason is the content, not the registry (connection, missing
        # manifest or blob).
        infrastructure = re.search(r"connection refused|no such host|manifest unknown|blob unknown|not found|timeout|name unknown", out, re.I)
        ok = (code == "1" and "cannot pull" in out and infrastructure is None
              and re.search(r"Digest did not match, expected sha256:[0-9a-f]{64}, got sha256:[0-9a-f]{64}", out) is not None)
        what = "an altered layer: refused for its content (exit 1, the blob's digest is not the one in the manifest)"
    check(f"the pull from the ISO with {what}", ok and "are accepted by the policy" not in out, out.replace("\n", " ")[-400:])
    # podman itself must answer, and there is no image.
    status, out = sh(f"podman --root {storage} images -q > /tmp/images 2> /tmp/images.err; rc=$?; echo \"podman=$rc images=$(wc -l < /tmp/images) errors=$(wc -c < /tmp/images.err)\"")
    check("podman answers and no image is left in the storage", out == "podman=0 images=0 errors=0", out)


def make_decoy(directory):
    """An ISO image that a naive installer could take for the ISO it booted from: the label NYRA-ISO, a
    /boot/vmlinuz and a release tree that names another release."""
    os.makedirs(os.path.join(directory, "boot"), exist_ok=True)
    os.makedirs(os.path.join(directory, "release"), exist_ok=True)
    with open(os.path.join(directory, "boot", "vmlinuz"), "wb") as f:
        f.write(b"not a kernel\n")
    with open(os.path.join(directory, "release", "RELEASE"), "w") as f:
        f.write("version=1999.1.1\ndigest=sha256:" + "0" * 64 + "\ncommit=" + "0" * 40 + "\narchitecture=amd64\n")
    image = directory + ".iso"
    subprocess.run(["xorriso", "-as", "mkisofs", "-quiet", "-r", "-V", "NYRA-ISO", "-o", image, directory], check=True,
                   stderr=subprocess.DEVNULL)
    return image


def main():
    p = argparse.ArgumentParser()
    p.add_argument("iso")
    p.add_argument("work")
    p.add_argument("log")
    p.add_argument("summary")
    p.add_argument("--medium", choices=["cd", "usb"], default="cd")
    p.add_argument("--memory", type=int, default=8192, help="MiB")
    p.add_argument("--pull", action="store_true", help="also run the verified pull of the image on the ISO")
    p.add_argument("--refusal", choices=["layer", "digest"], help="the ISO is altered; the pull must be refused")
    p.add_argument("--decoy", action="store_true", help="attach a second medium that looks like an installer, first")
    p.add_argument("--timeout", type=int, default=600, help="seconds to the first screen")
    a = p.parse_args()

    decoy = None
    if a.decoy:
        decoy = make_decoy(os.path.join(a.work, "decoy"))
    vm = isovm.Vm(a.iso, a.work, a.log, medium=a.medium, memory=a.memory, decoy=decoy)
    rows = []  # (what, result) for the summary
    failed = []

    def check(what, ok, detail=""):
        print(f"{'ok  ' if ok else 'FAIL'} {what}" + (f": {detail}" if detail else ""), flush=True)
        rows.append((what, "ok" if ok else "FAILED", detail))
        if not ok:
            failed.append(what)

    def sh(command, timeout=60):
        status, out = vm.run(command, timeout)
        print(f"$ {command}\n{out}\n[{status}]", flush=True)
        return status, out

    try:
        vm.start()
        # --- the first screen ---------------------------------------------------------------------
        vm.expect(r"GNU GRUB", 120)
        t_grub = vm.seconds()
        # GRUB at its own prompt means it did not find its menu: no use in waiting for a screen.
        if vm.expect(r"Welcome to Nyra OS\.|grub> ", a.timeout).group(0) == "grub> ":
            raise isovm.Timeout("GRUB stopped at its prompt\n" + vm.text()[-1000:])
        t_screen = vm.seconds()
        check("the installer's first screen is on the serial console", True, f"{t_screen:.0f} s after QEMU started, GRUB at {t_grub:.0f} s")
        vm.expect(r"Install Nyra OS.*Register the Secure Boot key again.*Open a shell", 10)
        check("no login prompt on the console", "login:" not in vm.text())

        # --- a shell, from the menu (Down, Down, Enter) -----------------------------------------------
        n = vm.mark()
        vm.send(MENU_DOWN * 2 + b"\r")
        vm.expect(r"temporary system in memory", 20, since=n)
        time.sleep(1)
        # Without line editing, the terminal echoes each command once and does not redraw it.
        vm.send("exec bash --norc --noprofile --noediting -i\n")
        time.sleep(1)
        sh("stty cols 400 rows 50; PS1=''; echo shell")

        if a.refusal:
            refusal(sh, check, a.refusal)
            raise Done

        status, out = sh("id -u; mokutil --sb-state")
        check("Secure Boot is on in the session", status == 0 and out.splitlines()[0] == "0" and "SecureBoot enabled" in out, out.replace("\n", " "))
        status, out = sh("ls /sys/class/net")
        check("only the loopback interface exists", out.split() == ["lo"], out.replace("\n", " "))
        status, out = sh("awk 'NR > 1 && $4 == \"0A\" {print $2}' /proc/net/tcp /proc/net/tcp6")
        check("the only listener is the registry on 127.0.0.1:80", out.split() == ["0100007F:0050"], out.replace("\n", " "))
        status, out = sh("systemctl list-units --type=service --state=active --no-legend 'getty*' 'serial-getty*' 'console-getty*' 'sshd*' 'ssh*' | wc -l")
        check("no getty and no ssh server is running", out == "0", out)
        status, out = sh("systemctl --failed --no-legend --plain | cut -d' ' -f1")
        check("no failed unit", out == "", out.replace("\n", " "))
        status, out = sh("sysctl -n kernel.unprivileged_bpf_disabled")
        check("unprivileged bpf() is off", out in ("1", "2"), out)
        status, out = sh("ps -eo uid=,comm= | awk '$1 != 0 {print $2}' | sort -u")
        check("only the registry runs as a user other than root", out == "docker-registry", out.replace("\n", " "))
        status, out = sh("grep -rl pam_namespace /etc/pam.d /usr/lib/pam.d 2> /dev/null | wc -l")
        check("no PAM configuration names pam_namespace", out == "0", out)
        status, out = sh("systemctl is-enabled getty@tty1.service autovt@tty2.service serial-getty@ttyS0.service console-getty.service emergency.service rescue.service; true")
        check("the login prompts and the emergency and rescue shells are masked", out.split() == ["masked"] * 6, out.replace("\n", " "))
        status, out = sh("getent shadow root | cut -d: -f2; getent passwd root | cut -d: -f2")
        check("root has no password", all(line in ("*", "!", "x") for line in out.split()), out.replace("\n", " "))

        status, out = sh("findmnt -no OPTIONS /usr/lib/nyra/release; touch /usr/lib/nyra/release/x 2>&1; stat -c '%U:%G' /usr/lib/nyra/release/tools/install/nyra-install.sh /usr/lib/nyra/release/RELEASE")
        check("the release tree is read-only and root's", "ro," in out and "Read-only file system" in out and out.count("root:root") == 2, out.replace("\n", " "))
        status, out = sh("findmnt -no SOURCE /run/iso | xargs blkid -s LABEL -o value")
        label = volume_label(a.iso)
        check("the medium mounted is the one of this build, by its own label", re.fullmatch(r"NYRA-ISO-[0-9a-f]{16}", label) is not None and out == label, f"{out}, the ISO's is {label}")
        status, out = sh("cat /usr/lib/nyra/release/RELEASE")
        release = dict(line.split("=", 1) for line in out.splitlines() if "=" in line)
        check("RELEASE names the version, digest, commit and architecture", set(release) == {"version", "digest", "commit", "architecture"}, out.replace("\n", " "))
        status, out = sh("exec 3<>/dev/tcp/127.0.0.1/80; printf 'GET /v2/ HTTP/1.0\\r\\n\\r\\n' >&3; head -n 1 <&3")
        check("the registry answers on 127.0.0.1", " 200 " in out, out)

        # --- the facts and the disks, as the installer reads them ------------------------------------
        status, out = sh("/usr/lib/nyra/release/tools/install/nyra-install.sh check", 120)
        facts = json.loads(out) if status == 0 else {}
        check("check: UEFI, Secure Boot, shim validation and the TPM are seen", all(facts.get(k) is True for k in ("uefi", "secure_boot", "shim_checks", "tpm")), out.replace("\n", " ")[:300])
        check("check: the release is the one on the ISO", facts.get("release", {}).get("digest") == release.get("digest"))
        if a.decoy:
            status, out = sh("blkid -L NYRA-ISO; head -n 3 /usr/lib/nyra/release/RELEASE; cat /proc/cmdline")
            check("with a second medium labelled NYRA-ISO attached, the session has this ISO's release",
                  "/dev/sd" in out and "version=1999.1.1" not in out and f"digest={release.get('digest')}" in out, out.replace("\n", " "))
        status, out = sh("/usr/lib/nyra/release/tools/install/nyra-install.sh disks", 60)
        disks = json.loads(out) if status == 0 else []
        paths = {d["path"]: d for d in disks}
        if a.medium == "cd":
            check("disks: the empty disk is offered, and the CD is not a disk", list(paths) == ["/dev/vda"] and paths["/dev/vda"]["eligible"], out.replace("\n", " ")[:300])
        else:
            booted = [d for d in disks if d["reason"] == "booted" and not d["eligible"]]
            check("disks: the empty disk is offered; the USB stick the ISO is on is 'booted'",
                  len([d for d in disks if d["eligible"]]) == 1 and len(booted) == (2 if a.decoy else 1)
                  and not any(d["path"] == "/dev/vda" for d in booted),
                  out.replace("\n", " ")[:300])

        # --- memory ---------------------------------------------------------------------------------
        status, out = sh("awk '/^(MemTotal|MemFree|MemAvailable|Shmem|Cached):/ {printf \"%s %d MiB, \", $1, $2/1024}' /proc/meminfo; echo; ps -o rss=,args= -C nyra-installer")
        mem_idle = out.splitlines()[0]
        rss = [int(line.split()[0]) for line in out.splitlines()[1:] if line.split()]
        check("each installer instance is under 15 MiB resident", bool(rss) and max(rss) < 15 * 1024, f"{rss} KiB")

        mem_pull = ""
        if a.pull:
            t = time.monotonic()
            cmd = (f"/usr/lib/nyra/release/tools/install/verified-pull.sh nyra-base {release['version']} {release['digest']} "
                   "/var/lib/containers/storage 2>&1 | tail -n 3")
            status, out = sh(cmd, 1800)
            seconds = time.monotonic() - t
            status2, out2 = sh("awk '/^(MemTotal|MemFree|MemAvailable|Shmem):/ {printf \"%s %d MiB, \", $1, $2/1024}' /proc/meminfo; df -m --output=used /var/lib/containers | tail -n 1")
            check("the image on the ISO passes the verified pull, offline", status == 0 and "are accepted by the policy" in out, f"{seconds:.0f} s")
            mem_pull = out2.replace("\n", ", used storage (MiB): ")
        n = vm.mark()
        vm.send("exit\n")
        try:
            vm.expect(r"Welcome to Nyra OS\.", 30, since=n)
            check("leaving the shell goes back to the installer's menu", True)
        except isovm.Timeout:
            check("leaving the shell goes back to the installer's menu", False, vm.text(n)[-300:])
        medium = "USB stick" if a.medium == "usb" else "CD"
        with open(a.summary, "a") as f:
            f.write(f"## Installer ISO boot ({medium}, {a.memory} MiB, {vm.accel})\n\n| | |\n|---|---|\n")
            f.write(f"| ISO | {os.path.getsize(a.iso) / 2**20:.0f} MiB |\n")
            f.write(f"| First screen | {t_screen:.0f} s after QEMU started (GRUB at {t_grub:.0f} s) |\n")
            f.write(f"| Memory, idle | {mem_idle} |\n")
            if mem_pull:
                f.write(f"| Memory, after the pull | {mem_pull} |\n")
            f.write(f"| Installer instance, resident | {rss} KiB |\n\n")
            f.write("| Check | Result |\n|---|---|\n")
            for what, result, detail in rows:
                f.write(f"| {what} | {result} |\n")
            f.write("\n")
    except Done:
        pass
    except isovm.Timeout as e:
        print(f"FAIL {e}", flush=True)
        failed.append("timeout")
    finally:
        vm.stop()
    if a.refusal:
        with open(a.summary, "a") as f:
            f.write(f"## Installer ISO, altered ({a.refusal})\n\n| Check | Result |\n|---|---|\n")
            for what, result, detail in rows:
                f.write(f"| {what} | {result} |\n")
            f.write("\n")
    if failed:
        print("failed: " + "; ".join(failed), flush=True)
        sys.exit(1)


main()
