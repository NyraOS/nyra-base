#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Release jobs unpack no cache. In .github/workflows/image.yml and in every local action its jobs use
(and the local actions those use), every step that uses a cache action other than its save (`uses`
with "/cache" in it, in any case) must only look the cache up in a release: `with:` has
`lookup-only: ${{ env.RELEASE == 'true' }}` or `lookup-only: true`. The one exception is the job
bootc-reproducible: `permissions: {}`, no secrets, and no step but cache restores and `run` steps (so
no checkout and no artifact upload). A cache entry is not trusted: unpacking one can write any file
the job can write. This guards against mistakes, not against whoever can change the workflows.

  check-release-cache.py [REPO]   (the current directory by default)
  check-release-cache.py --self-test
"""
import json
import os
import sys
import tempfile

import yaml

LOOKUP = ("${{ env.RELEASE == 'true' }}", True)
EXCEPTION = "bootc-reproducible"


def is_restore(uses):
    return "/cache" in uses.lower() and "/cache/save@" not in uses.lower()


def steps_problems(repo, steps, where, seen):
    found = []
    for n, step in enumerate(steps or []):
        uses = str(step.get("uses", ""))
        if is_restore(uses) and (step.get("with") or {}).get("lookup-only") not in LOOKUP:
            found.append(f"{where}, step {n + 1}: {uses} without `lookup-only` for releases in `with:`")
        if uses.startswith("./"):
            found += action_problems(repo, uses, seen)
    return found


def action_problems(repo, uses, seen):
    path = os.path.normpath(os.path.join(repo, uses))
    if path in seen:
        return []
    seen.add(path)
    for name in ("action.yml", "action.yaml"):
        if os.path.exists(os.path.join(path, name)):
            with open(os.path.join(path, name)) as f:
                action = yaml.safe_load(f)
            return steps_problems(repo, (action.get("runs") or {}).get("steps"), uses, seen)
    return [f"{uses}: no action.yml"]


def check(repo):
    with open(os.path.join(repo, ".github/workflows/image.yml")) as f:
        workflow = yaml.safe_load(f)
    found, seen = [], set()
    for name, job in workflow["jobs"].items():
        steps = job.get("steps") or []
        if name != EXCEPTION:
            found += steps_problems(repo, steps, f"image.yml job {name}", seen)
            continue
        others = [s.get("uses") for s in steps if "run" not in s and not is_restore(str(s.get("uses", "")))]
        if job.get("permissions") != {} or "secrets." in json.dumps(job) or others:
            found.append(f"image.yml job {name} restores a cache, so it must have `permissions: {{}}`, no "
                         f"secrets and only cache restores and run steps (other steps: {others})")
    return found


def self_test():
    good = """
jobs:
  build:
    steps:
      - uses: actions/checkout@abc
      - name: Restore
        uses: actions/cache/restore@abc # v6
        with:
          lookup-only: ${{ env.RELEASE == 'true' }}
          path: x
      - uses: actions/cache/save@abc
        with: {path: x}
      - uses: ./.github/actions/a/b
  bootc-reproducible:
    needs: build
    permissions: {}
    steps:
      - uses: actions/cache/restore@abc
        with:
          path: x
      - run: echo compare
"""
    action = "runs:\n  using: composite\n  steps:\n    - uses: actions/cache@abc\n      with: {lookup-only: true}\n"
    bad_action = action.replace("lookup-only: true", "path: x")
    bad = [
        good.replace("          lookup-only: ${{ env.RELEASE == 'true' }}\n", ""),
        good.replace("lookup-only: ${{ env.RELEASE == 'true' }}", "lookup-only: false"),
        good.replace("uses: actions/cache/save@abc", "uses: Actions/Cache@abc"),
        good.replace("      - uses: actions/cache/save@abc\n        with: {path: x}\n",
                     "      - {uses: actions/cache/restore@abc, with: {path: x}}\n"),
        good.replace("        with:\n          lookup-only: ${{ env.RELEASE == 'true' }}\n",
                     "        env:\n          lookup-only: true\n        with:\n"),
        good.replace("    permissions: {}\n", ""),
        good.replace("      - run: echo compare\n", "      - uses: actions/checkout@abc\n"),
        good.replace("      - run: echo compare\n", "      - uses: actions/upload-artifact@abc\n"),
        good.replace("echo compare", "echo ${{ secrets.TOKEN }}"),
    ]
    with tempfile.TemporaryDirectory() as t:
        os.makedirs(os.path.join(t, ".github/workflows"))
        os.makedirs(os.path.join(t, ".github/actions/a/b"))

        def run(workflow, act):
            with open(os.path.join(t, ".github/workflows/image.yml"), "w") as f:
                f.write(workflow)
            with open(os.path.join(t, ".github/actions/a/b/action.yml"), "w") as f:
                f.write(act)
            return check(t)

        assert run(good, action) == [], run(good, action)
        assert run(good, bad_action), "a local action's restore without lookup-only passed"
        for text in bad:
            assert run(text, action), text
    print("check-release-cache.py self-test: ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        sys.exit(0)
    problems = check(sys.argv[1] if len(sys.argv) > 1 else ".")
    for p in problems:
        print(f"::error::{p}")
    sys.exit(1 if problems else 0)
