#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Does a change to .github/workflows/image.yml affect a pull request's build and tests?

The jobs release-sign, release-image, sign, publish, verify-published and the arm64 release jobs
(see MAIN_ONLY_JOBS) never run on pull requests. If two versions of the file differ only in the other keys of those jobs (compared as
parsed YAML), the pull request needs no image build for it. Their `if` and `needs` decide whether
a job runs on a pull request, so a change to either counts as an image change. Anything else counts as an image change: the other
jobs, the top-level keys (on, env, permissions, concurrency...), a job added, removed or renamed,
and any error reading either file.

  image-yml-change.py BASE HEAD   exit 0: only main-only jobs differ; exit 1: image change
  image-yml-change.py --self-test
"""
import sys

import yaml

MAIN_ONLY_JOBS = {"release-sign", "release-image", "sign", "publish", "verify-published",
                  "bootc-arm64", "build-arm64", "release-sign-arm64", "release-image-arm64", "boot-arm64",
                  "sign-arm64", "verify-signature-arm64", "publish-arm64", "verify-published-arm64"}


def without_ignored_keys(name, job):
    if name not in MAIN_ONLY_JOBS:
        return job
    return {key: job[key] for key in ("if", "needs") if key in job}


def affects_image(base_text, head_text):
    try:
        base, head = yaml.safe_load(base_text), yaml.safe_load(head_text)
        base_jobs, head_jobs = base.pop("jobs"), head.pop("jobs")
        if base != head or base_jobs.keys() != head_jobs.keys():
            return True
        return any(without_ignored_keys(name, base_jobs[name])
                   != without_ignored_keys(name, head_jobs[name])
                   for name in base_jobs)
    except Exception:
        return True


def self_test():
    template = """\
name: image
env:
  A: {env}
jobs:
  build:
    steps: [{{run: {build}}}]
  {sign}:
    steps: [{{run: {signing}}}]
"""

    def make(env="1", build="make", sign="sign", signing="old", extra=""):
        return template.format(env=env, build=build, sign=sign, signing=signing) + extra

    base = make()
    cases = [
        ("identical", base, False),
        ("only sign changed", make(signing="new"), False),
        ("sign if changed", make(extra="    if: github.event_name == 'pull_request'\n"), True),
        ("sign needs changed", make(extra="    needs: build\n"), True),
        ("build changed", make(build="other"), True),
        ("top-level env changed", make(env="2"), True),
        ("main-only job renamed", make(sign="publish"), True),
        ("job added", base + "  extra:\n    steps: []\n", True),
        ("job removed", base.split("  sign:")[0], True),
        ("parse error", "jobs: [", True),
        ("not a mapping", "- a\n", True),
    ]
    failed = 0
    for name, head, expected in cases:
        got = affects_image(base, head)
        print(f"{'ok  ' if got == expected else 'FAIL'} {name}")
        failed += got != expected
    # Every main-only job: a step change is no image change, a change of its `if` or `needs` is; a job
    # whose name only looks like one is an ordinary job, so any change to it is.
    for job in sorted(MAIN_ONLY_JOBS) + ["sign-arm64-x"]:
        ordinary = job not in MAIN_ONLY_JOBS
        job_base = make(sign=job)
        for what, head, expected in [
            ("step changed", make(sign=job, signing="new"), ordinary),
            ("if changed", make(sign=job, extra="    if: github.ref == 'refs/heads/main'\n"), True),
            ("needs changed", make(sign=job, extra="    needs: build\n"), True),
        ]:
            got = affects_image(job_base, head)
            print(f"{'ok  ' if got == expected else 'FAIL'} {job}: {what}")
            failed += got != expected
    if not affects_image("jobs: [", base):
        print("FAIL parse error in the base file")
        failed += 1
    return 1 if failed else 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    if len(sys.argv) != 3:
        sys.exit("usage: image-yml-change.py BASE HEAD | --self-test")
    try:
        texts = [open(path, encoding="utf-8").read() for path in sys.argv[1:]]
    except OSError:
        sys.exit(1)
    sys.exit(1 if affects_image(*texts) else 0)
