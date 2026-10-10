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
POLICY = ("build", "Test the signature policy (docs/SIGNING.md)")
DEFAULTS = ("install-boot", "Secure defaults (docs/DEFAULTS.md)")
SECURE_BOOT = ("install-boot", "Secure Boot chain (docs/BOOT.md)")
PROTECTION = ("install-boot", "Boot protection (docs/BOOT.md)")
COUNTING = ("install-boot", "Boot counting across updates (docs/BOOT.md)")
UPDATES = ("install-boot", "Updates across real versions, Titanic T2-T5 (docs/UPDATES.md)")
SOFT_REBOOT_NETWORK = ("install-boot", "Network across soft reboots (docs/UPDATES.md)")
POWER_CUTS = ("power-cuts", "Power cuts at random moments (Titanic T2)")

# id: (name, coverage "full" | "partial" | None, steps, note)
TESTS = {
    "T1": ("Immutability", "partial", [BOOT, POLICY, SECURE_BOOT],
           "Writes to /usr refused; images and UKIs with a wrong signature refused. "
           "Not yet: a modified composefs object on disk must give a read error."),
    "T2": ("Power cuts", "full", [POWER_CUTS, UPDATES],
           "Power cuts at random moments (seed in this file) during the download, staging, "
           "finalization and first boot; nyra-updated stages the update again after cuts at fixed moments."),
    "T3": ("Broken version", "partial", [COUNTING, UPDATES, SOFT_REBOOT_NETWORK],
           "A version whose health check fails falls back within 3 boots and is not offered again; "
           "the network comes up after every soft reboot and full boot of an update (20 rounds). "
           "Not yet: kernel panic, initramfs without the disk driver, no graphical session, dead network."),
    "T4": ("Signatures and versions", "full", [POLICY, SECURE_BOOT, UPDATES],
           "Unsigned and wrongly signed images and channel sheets, downgrades and replays refused; "
           "signed retractions applied."),
    "T5": ("Hostile network", "partial", [UPDATES],
           "Registry down, corrupted layer, captive portal and spoofed server refused. "
           "Not yet: a 50 kbit/s link, a server that stalls mid-download, spoofed DNS answers."),
    "T6": ("Full disk", None, [], "Not written yet."),
    "T7": ("Attacked boot", "full", [PROTECTION, SECURE_BOOT],
           "EFI variables reset, boot order changed, boot files deleted, cut or corrupted, ESP full: "
           "boots through the fallback path and repairs itself."),
    "T8": ("Configuration broken by the user", None, [],
           "Needs the system settings reset, which does not exist yet."),
    "T9": ("Wrong clock", None, [], "Not written yet."),
    "T10": ("Disk encryption", None, [], "Disk encryption does not exist yet."),
    "T11": ("Version jumps", None, [], "Needs published versions and channels; not written yet."),
    "T12": ("Hostile root", None, [],
            "Not written yet (a read-only /usr is checked under T1)."),
    "T13": ("Extreme load", None, [], "Not written yet."),
    "T14": ("Media removed", None, [], "Needs removable media support, which does not exist yet."),
    "T15": ("Secure defaults", "partial", [DEFAULTS, SECURE_BOOT],
            "Secure Boot with a MOK, lockdown, AppArmor, firewall, listening sockets, running units and "
            "the signature policy checked after installation. Not yet: after an update."),
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
    every = [{"name": f"image / {j}" if j != "power-cuts" else j, "steps": [{"name": s, "conclusion": "success"}]}
             for j, s in {BOOT, POLICY, DEFAULTS, SECURE_BOOT, PROTECTION, COUNTING, UPDATES, SOFT_REBOOT_NETWORK,
                          POWER_CUTS}]
    r = evaluate(every, "u")
    assert [r[t]["result"] for t in ("T1", "T2", "T4", "T6", "T7", "T15")] == \
        ["partial", "pass", "pass", "not-implemented", "pass", "partial"], r
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
