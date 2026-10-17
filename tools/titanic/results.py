#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The Titanic battery's results (docs/TITANIC.md), one per test T1-T15, from the jobs of a
titanic.yml run as the GitHub API lists them (`gh api .../actions/runs/ID/attempts/N/jobs`).

A test passes only if every workflow step that runs it succeeded. A test that covers only part of
its scenarios gives "partial" at best; one with no step yet gives "not-implemented". A step that
failed, was skipped or does not exist (renamed in the workflow: rename it here too) fails the test.

  results.py JOBS.json RUN_URL SEED OUT.json SUMMARY.md   (the commit comes from GITHUB_SHA)
  results.py --self-test
"""
import datetime
import json
import os
import sys

# Steps as (job, step name); jobs of image.yml run through titanic.yml's "image" job.
BOOT = ("install-boot", "Boot the installed disk with KVM")
TAMPERED = ("install-boot", "Tampered composefs object (Titanic T1)")
POLICY = ("build", "Test the signature policy (docs/SIGNING.md)")
DEFAULTS = ("install-boot", "Secure defaults (docs/DEFAULTS.md)")
TPM_UNLOCK = ("install-boot", "TPM2 disk-unlock policy (docs/BOOT.md)")
ENCRYPTION = ("install-boot", "Disk encryption without a TPM, Titanic T10 (docs/BOOT.md)")
ENCRYPTION_TPM = ("install-boot", "Disk encryption with a TPM, Titanic T10 (docs/BOOT.md)")
ROTATION = ("install-boot", "Rotation of the TPM policy key, Titanic T10 (docs/BOOT.md)")
ENCRYPTION_PIN = ("install-boot", "Disk encryption with a TPM PIN, Titanic T10 (docs/BOOT.md)")
ROTATION_PIN = ("install-boot", "Rotation of the TPM policy key with a PIN, Titanic T10 (docs/BOOT.md)")
SECURE_BOOT = ("install-boot", "Secure Boot chain (docs/BOOT.md)")
PROTECTION = ("install-boot", "Boot protection (docs/BOOT.md)")
COUNTING = ("install-boot", "Boot counting across updates (docs/BOOT.md)")
UPDATES = ("install-boot", "Updates across real versions, Titanic T2-T5, T9 (docs/UPDATES.md)")
SOFT_REBOOT_NETWORK = ("install-boot", "Network across soft reboots (docs/UPDATES.md)")
CHANNELS = ("install-boot", "Version jumps and channels, Titanic T11 (docs/UPDATES.md)")
POWER_CUTS = ("power-cuts", "Power cuts at random moments (Titanic T2)")
FULL_DISK = ("stress", "Full disk and the space across updates (Titanic T6)")
EXTREME_LOAD = ("stress", "An update under extreme load (Titanic T13)")
HOSTILE_ROOT = ("stress", "Hostile root (Titanic T12)")
BROKEN_CONFIG = ("stress", "Configuration broken by the user (Titanic T8)")

# id: (name, coverage "full" | "partial" | None, steps, note)
TESTS = {
    "T1": ("Immutability", "full", [BOOT, TAMPERED, POLICY, SECURE_BOOT],
           "Writes to /usr refused; a composefs object changed on the disk gives a read error, through "
           "/usr and directly; images and UKIs with a wrong signature refused."),
    "T2": ("Power cuts", "full", [POWER_CUTS, UPDATES],
           "Power cuts at random moments (seed in this file) during the download, staging, "
           "finalization and first boot; nyra-updated stages the update again after cuts at fixed and "
           "at random moments."),
    "T3": ("Broken version", "partial", [COUNTING, UPDATES, SOFT_REBOOT_NETWORK],
           "A version whose health check fails falls back within 3 boots and is not offered again; "
           "a good version whose health check fails because of settings broken after it was staged "
           "falls back too, but is not marked failed (the older version fails as well) and boots "
           "counted once the settings are repaired; "
           "the network comes up after every soft reboot and full boot of an update (20 rounds); a version "
           "whose kernel panics (no usable initramfs) reboots by itself and falls back the same way. "
           "Not yet: no graphical session, dead network."),
    "T4": ("Signatures and versions", "full", [POLICY, SECURE_BOOT, UPDATES],
           "Unsigned and wrongly signed images and channel sheets, downgrades and replays refused; "
           "signed retractions applied."),
    "T5": ("Hostile network", "full", [UPDATES],
           "Registry down, corrupted layer, captive portal, spoofed server, a DNS answer for another "
           "host, a 50 kbit/s link and a registry that stalls mid-pull: refused or stopped at the time "
           "limit, nothing staged, staged later."),
    "T6": ("Full disk", "partial", [FULL_DISK],
           "The root file system full: the update fails and says why, nothing staged, the system boots "
           "and runs, AppArmor loaded without its cache; the ESP full: the same; the space the system takes stays the same across updates "
           "(8 in a row). Not yet: the desktop and its message (no graphical session yet)."),
    "T7": ("Attacked boot", "full", [PROTECTION, SECURE_BOOT, TPM_UNLOCK],
           "EFI variables reset, boot order changed, boot files deleted, cut or corrupted, ESP full: "
           "boots through the fallback path and repairs itself. The signed PCR 11 policy releases the "
           "disk key only in the initrd (main profile, enter-initrd): not on the running system, not "
           "in the recovery or reset profile, not with an add-on measured into PCR 12, not for a "
           "signature replayed to another phase, and not without the policy reference (swtpm)."),
    "T8": ("Configuration broken by the user", "full", [BROKEN_CONFIG],
           "With Secure Boot on: /etc/fstab (a line that is not a mount, a disk that is not "
           "connected), /etc/passwd (the system accounts deleted), the network settings and "
           "/etc/systemd/system (emptied, services masked), each broken on its own: the system boots to "
           "a login prompt, and Restore earlier settings with the copy of /etc from before repairs it; "
           "all of it at once: Recovery opens for the administrator without the system accounts, and "
           "the copy from before repairs it; all of it broken again, then Reset settings: the broken "
           "files are the image's, the file in /home is the same, the user logs in with their password, "
           "the network and the basic services work."),
    "T9": ("Wrong clock", "full", [UPDATES],
           "Hardware clock in 2099, 1970 and 2035: chronyd corrects it through NTS by itself and the "
           "update works. With the NTS servers spoofed: the clock stays wrong, no unauthenticated NTP "
           "request is sent, the update server's certificate and unsigned images are refused."),
    "T10": ("Disk encryption", "partial", [ENCRYPTION, ENCRYPTION_TPM, ENCRYPTION_PIN, ROTATION, ROTATION_PIN],
            "Without a TPM: the password and the recovery key unlock the disk in the initrd (found by its "
            "partition type), a wrong password is asked again, the recovery key typed 120 s later and "
            "the password after three wrong ones (asked again) still unlock it. With a TPM and Secure "
            "Boot: the first boot unlocks by itself and its initrd enrolls the disk with the signed PCR "
            "11 policy and PCR 7 and 12, the next boots unlock by themselves, without the TPM the "
            "recovery key unlocks it; a TPM that stops answering before leave-initrd forces a reboot; after "
            "the TPM refused (a new Secure Boot database, a new TPM, a different PCR 12) the recovery key "
            "unlocks it and the disk is enrolled again, never with Secure Boot off or an add-on measured, "
            "nor a password disk with a forged TPM2 token; "
            "the recovery profile asks for the disk. With a PIN: asked for from the running system and "
            "enrolled at the next boot, changed and removed the same way; a wrong PIN is asked again; an "
            "empty one, and a TPM locked by wrong ones (the right PIN refused too), lead to the recovery "
            "key, which unlocks the disk; after the TPM refused (PCR 12, a new TPM) a new PIN is chosen "
            "in the initrd and unlocks the next boot. The policy key's rotation across test versions, "
            "without and with a PIN: the next key enrolled in advance (with the PIN typed), the old one "
            "removed once the rotated release is confirmed good (a fallback before that unlocks by "
            "itself, after it asks for the recovery key), a machine that missed a rotation asks once and "
            "is enrolled again (with a new PIN). No root partition: emergency mode after 90 s. No secret "
            "in the logs, the ESP, the LUKS2 header or the root file system. Not yet: updates through "
            "nyra-updated; the first boot without a TPM or with Secure Boot off is checked by hand only."),
    "T11": ("Version jumps and channels", "full", [CHANNELS],
            "A jump over several versions goes straight to the newest, the retracted one between never "
            "boots; a sheet with an untrusted key, an older sequence or a retracted version refused, "
            "and a retraction below the floor the jump raised. A version that changes the sheet key, "
            "the default channel or the repository installs, boots and follows its new configuration. "
            "The channel chosen with set-channel wins over the image and survives a rollback; another "
            "channel's sheet and an unknown channel refused; beta to stable goes back to stable's "
            "older version only with a sheet issued after the change, once, never below the floor, staged "
            "afresh with today's settings even when it is the rollback deployment."),
    "T12": ("Hostile root", "full", [HOSTILE_ROOT],
            "As root with Secure Boot on: apt, apt-get and dpkg -i cannot change /usr and say what to "
            "use instead (the Store, Distrobox); dpkg itself fails with a read-only file system (the "
            "same package installs under a writable root, where dpkg's queries find it); "
            "an unsigned copy of an in-tree module is refused (the signed copy loads), "
            "and the lockdown cannot be lowered; after rm -rf --no-preserve-root / and a power cut, "
            "/usr and the ESP are unchanged, and the Reset settings entry brings the system back "
            "without a first-boot question, root locked."),
    "T13": ("Extreme load", "full", [EXTREME_LOAD],
            "An update while 8 busy loops run on 2 vCPUs, less than 200 MiB of memory is free and the "
            "disk is written without a pause: staged exactly or failed with nothing staged; the next "
            "boot runs, the update completes."),
    "T14": ("Media removed", None, [], "Needs removable media support, which does not exist yet."),
    "T15": ("Secure defaults", "full", [DEFAULTS, SECURE_BOOT, UPDATES, TPM_UNLOCK],
            "Secure Boot with a MOK, lockdown, AppArmor, firewall, listening sockets, running units and "
            "the signature policy checked after installation and again after updates. The TPM unlock "
            "policy releases the key only in the initrd (swtpm), and the image ships no NvPCR "
            "definitions (/usr/lib/nvpcr absent)."),
}


def evaluate(jobs, run_url):
    """{id: {name, result, note, run_url}} from the API's job list."""
    seen = {}
    for job in jobs:
        # A job of a called workflow is named "<caller job> / <job>".
        for step in job.get("steps") or []:
            seen[(job["name"].split(" / ")[-1], step["name"])] = step.get("conclusion") or step.get("status")
    out = {}
    for tid, (name, coverage, steps, note) in TESTS.items():
        if coverage is None:
            result = "not-implemented"
        else:
            bad = [f"{s} ({seen.get((j, s), 'not found')})" for j, s in steps if seen.get((j, s)) != "success"]
            result = "fail" if bad else "pass" if coverage == "full" else "partial"
            if bad:
                note = f"{note} Did not pass: {'; '.join(bad)}."
        out[tid] = {"name": name, "result": result, "note": note, "run_url": run_url}
    return out


def self_test():
    every = [{"name": f"image / {j}" if j not in ("power-cuts", "stress") else j, "steps": [{"name": s, "conclusion": "success"}]}
             for j, s in {BOOT, TAMPERED, POLICY, DEFAULTS, SECURE_BOOT, PROTECTION, COUNTING, UPDATES,
                          SOFT_REBOOT_NETWORK, POWER_CUTS, FULL_DISK, EXTREME_LOAD, HOSTILE_ROOT, BROKEN_CONFIG, TPM_UNLOCK,
                          ENCRYPTION, ENCRYPTION_TPM, ENCRYPTION_PIN, ROTATION, ROTATION_PIN, CHANNELS}]
    r = evaluate(every, "u")
    assert [r[t]["result"] for t in ("T1", "T2", "T4", "T5", "T6", "T7", "T8", "T9", "T10", "T11", "T12", "T13", "T15")] == \
        ["pass", "pass", "pass", "pass", "partial", "pass", "pass", "pass", "partial", "pass", "pass", "pass", "pass"], r
    assert len(r) == 15 and all(v["run_url"] == "u" for v in r.values())
    failed = [dict(j, steps=[dict(j["steps"][0], conclusion="failure")]) if j["name"] == "power-cuts" else j
              for j in every]
    r = evaluate(failed, "u")
    assert r["T2"]["result"] == "fail" and "(failure)" in r["T2"]["note"] and r["T4"]["result"] == "pass", r
    # T8 and T12 are steps of the same job: one failing does not fail the other.
    failed = [dict(j, steps=[dict(j["steps"][0], conclusion="failure")]) if j["steps"][0]["name"] == BROKEN_CONFIG[1]
              else j for j in every]
    r = evaluate(failed, "u")
    assert r["T8"]["result"] == "fail" and "(failure)" in r["T8"]["note"] and r["T12"]["result"] == "pass", r
    r = evaluate([j for j in every if j["name"] != "image / build"], "u")
    assert r["T1"]["result"] == r["T4"]["result"] == "fail" and "(not found)" in r["T4"]["note"], r
    r = evaluate([dict(j, steps=[dict(j["steps"][0], conclusion="skipped")]) for j in every], "u")
    assert all(v["result"] in ("fail", "not-implemented") for v in r.values()), r
    print("results.py: self-test passed")


def main():
    if sys.argv[1:] == ["--self-test"]:
        return self_test()
    jobs_file, run_url, seed, out_file, summary = sys.argv[1:]
    with open(jobs_file) as f:
        tests = evaluate(json.load(f)["jobs"], run_url)
    doc = {"schema": 1, "date": datetime.datetime.now(datetime.timezone.utc).date().isoformat(),
           "commit": os.environ.get("GITHUB_SHA", ""), "run_url": run_url,
           "seed": int(seed) if seed.isdigit() else None, "tests": tests}
    with open(out_file, "w") as f:
        json.dump(doc, f, indent=2)
        f.write("\n")
    with open(summary, "a") as f:
        f.write(f"## Titanic battery, {doc['date']}\n\n| Test | Result | Note |\n|---|---|---|\n")
        f.writelines(f"| {t} {v['name']} | {v['result']} | {v['note']} |\n" for t, v in tests.items())
    for t, v in tests.items():
        print(f"{t:4} {v['result']:16} {v['name']}")


if __name__ == "__main__":
    main()
