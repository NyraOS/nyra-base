#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The ISO jobs of image.yml for a pull request (docs/ISO.md, "Two modes").

iso and iso-install wait for `sign` and use what it makes, but only in release mode (a build on main).
iso-pr and iso-install-pr are the same jobs for a pull request, which start without waiting for the tests
and for `sign`. They can only be the same jobs if their steps are the same text (the YAML anchors), and
they can only start early if nothing of `sign` is in their needs or steps. Checked here:
- iso-pr and iso-install-pr have the steps of iso and iso-install, and do not need `sign`, and nothing
  in their steps reads `needs.sign`;
- iso never runs on a pull request and iso-pr only on one (iso-install and iso-install-pr follow their
  ISO job), so that a pull request has exactly one ISO and one install test and a push on main has no early ISO;
- no job other than the four reads `needs.iso-pr` or `needs.iso-install-pr`.

  check-iso-jobs.py [FILE]   (.github/workflows/image.yml by default)
  check-iso-jobs.py --self-test
"""
import copy
import re
import sys

import yaml

PAIRS = [("iso", "iso-pr"), ("iso-install", "iso-install-pr")]


def problems(workflow):
    jobs = workflow["jobs"]
    out = []
    for main, pr in PAIRS:
        if main not in jobs or pr not in jobs:
            out.append(f"{main} or {pr} is missing")
            continue
        if jobs[main].get("steps") != jobs[pr].get("steps"):
            out.append(f"{pr} does not have the steps of {main}")
        text = yaml.dump(jobs[pr].get("steps"))
        if re.search(r"needs\.sign\b", text):
            out.append(f"the steps of {pr} read needs.sign")
        needs = jobs[pr].get("needs", [])
        needs = [needs] if isinstance(needs, str) else needs
        if "sign" in needs:
            out.append(f"{pr} needs sign")
        # iso-install-pr is only ever started by iso-pr, which runs on a pull request only.
        if main == "iso" and "github.event_name == 'pull_request'" not in jobs[pr].get("if", ""):
            out.append(f"{pr} does not run only on a pull request")
        if main == "iso-install" and "iso-pr" not in needs:
            out.append("iso-install-pr does not need iso-pr")
        # iso-install is skipped on a pull request because iso is: it needs iso.
        if main == "iso" and "github.event_name != 'pull_request'" not in jobs[main].get("if", ""):
            out.append("iso runs on a pull request")
        if main == "iso-install" and "iso" not in jobs[main].get("needs", []):
            out.append("iso-install does not need iso")
    for name, job in jobs.items():
        if name in ("iso-install-pr",):
            continue
        needs = job.get("needs", [])
        needs = [needs] if isinstance(needs, str) else needs
        if "iso-pr" in needs or "iso-install-pr" in needs:
            out.append(f"{name} needs a pull request ISO job")
    return out


def self_test():
    base = yaml.safe_load("""
jobs:
  sign: {steps: []}
  iso:
    needs: [build, sign]
    if: ${{ github.event_name != 'pull_request' }}
    steps: &s [{run: a}]
  iso-pr:
    needs: [build]
    if: ${{ github.event_name == 'pull_request' }}
    steps: *s
  iso-install:
    needs: [build, iso]
    steps: &t [{run: b}]
  iso-install-pr:
    needs: [build, iso-pr]
    if: ${{ github.event_name == 'pull_request' }}
    steps: *t
""")
    cases = []

    def case(name, change, expected):
        w = copy.deepcopy(base)
        change(w["jobs"])
        cases.append((name, problems(w), expected))

    case("as it is", lambda j: None, False)
    case("pr steps differ", lambda j: j["iso-pr"].update(steps=[{"run": "other"}]), True)
    case("pr needs sign", lambda j: j["iso-pr"].update(needs=["build", "sign"]), True)
    case("pr steps read sign", lambda j: (j["iso"].update(steps=[{"run": "${{ needs.sign.result }}"}]),
                                          j["iso-pr"].update(steps=[{"run": "${{ needs.sign.result }}"}])), True)
    case("iso runs on a pull request", lambda j: j["iso"].update({"if": "${{ true }}"}), True)
    case("install-pr after iso", lambda j: j["iso-install-pr"].update(needs=["build", "iso"]), True)
    case("iso-pr runs everywhere", lambda j: j["iso-pr"].update({"if": "${{ true }}"}), True)
    case("a job needs iso-pr", lambda j: j["sign"].update(needs=["iso-pr"]), True)
    case("iso-pr missing", lambda j: j.pop("iso-pr"), True)
    case("iso-install without iso", lambda j: j["iso-install"].update(needs=["build"]), True)
    failed = 0
    for name, found, expected in cases:
        ok = bool(found) == expected
        print(f"{'ok  ' if ok else 'FAIL'} {name}{': ' + '; '.join(found) if found else ''}")
        failed += not ok
    return 1 if failed else 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    path = sys.argv[1] if len(sys.argv) > 1 else ".github/workflows/image.yml"
    found = problems(yaml.safe_load(open(path)))
    for f in found:
        print(f"::error::{f}")
    if not found:
        print("the ISO jobs of a pull request are the ISO jobs of a release, without sign")
    sys.exit(1 if found else 0)
