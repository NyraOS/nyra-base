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
SECURE_BOOT = ("install-boot", "Secure Boot chain (docs/BOOT.md)")
PROTECTION = ("install-boot", "Boot protection (docs/BOOT.md)")
COUNTING = ("install-boot", "Boot counting across updates (docs/BOOT.md)")
UPDATES = ("install-boot", "Updates across real versions, Titanic T2-T5, T9 (docs/UPDATES.md)")
SOFT_REBOOT_NETWORK = ("install-boot", "Network across soft reboots (docs/UPDATES.md)")
POWER_CUTS = ("power-cuts", "Power cuts at random moments (Titanic T2)")
FULL_DISK = ("full-disk", "Full disk and the space across updates (Titanic T6)")

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
           "and runs; the ESP full: the same; the space the system takes stays the same across updates "
           "(8 in a row). Not yet: the desktop and its message (no graphical session yet)."),
    "T7": ("Attacked boot", "full", [PROTECTION, SECURE_BOOT],
           "EFI variables reset, boot order changed, boot files deleted, cut or corrupted, ESP full: "
           "boots through the fallback path and repairs itself."),
    "T8": ("Configuration broken by the user", None, [],
           "Needs the system settings reset, which does not exist yet."),
    "T9": ("Wrong clock", "partial", [UPDATES],
           "Hardware clock in 2099, 1970 and 2035: boots; the update server's certificate refused, "
           "nothing staged; unsigned images refused; with the clock set right updates work. Not yet: "
           "the image has no time synchronization, so only a person can set the clock right."),
    "T10": ("Disk encryption", None, [], "Disk encryption does not exist yet."),
    "T11": ("Version jumps", None, [], "Needs published versions and channels; not written yet."),
    "T12": ("Hostile root", None, [],
            "Not written yet (a read-only /usr is checked under T1)."),
    "T13": ("Extreme load", None, [], "Not written yet."),
    "T14": ("Media removed", None, [], "Needs removable media support, which does not exist yet."),
    "T15": ("Secure defaults", "full", [DEFAULTS, SECURE_BOOT, UPDATES],
            "Secure Boot with a MOK, lockdown, AppArmor, firewall, listening sockets, running units and "
            "the signature policy checked after installation and again after updates."),
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
    every = [{"name": f"image / {j}" if j not in ("power-cuts", "full-disk") else j, "steps": [{"name": s, "conclusion": "success"}]}
             for j, s in {BOOT, TAMPERED, POLICY, DEFAULTS, SECURE_BOOT, PROTECTION, COUNTING, UPDATES,
                          SOFT_REBOOT_NETWORK, POWER_CUTS, FULL_DISK}]
    r = evaluate(every, "u")
    assert [r[t]["result"] for t in ("T1", "T2", "T4", "T5", "T6", "T7", "T9", "T12", "T15")] == \
        ["pass", "pass", "pass", "pass", "partial", "pass", "partial", "not-implemented", "pass"], r
    assert len(r) == 15 and all(v["run_url"] == "u" for v in r.values())
    failed = [dict(j, steps=[dict(j["steps"][0], conclusion="failure")]) if j["name"] == "power-cuts" else j
              for j in every]
    r = evaluate(failed, "u")
    assert r["T2"]["result"] == "fail" and "(failure)" in r["T2"]["note"] and r["T4"]["result"] == "pass", r
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
