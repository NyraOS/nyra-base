#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Release jobs unpack no cache: every cache restore (actions/cache, actions/cache/restore) in
.github/workflows/image.yml and in the local actions in .github/actions/ must only look the cache up
in a release: `lookup-only: ${{ env.RELEASE == 'true' }}` (or `lookup-only: true`). The one
exception is the job bootc-reproducible, which has no permissions and no checkout and only compares a
hash. A cache entry is not trusted: unpacking one can write any file the job can write.

  check-release-cache.py [REPO]   (the current directory by default)
  check-release-cache.py --self-test
"""
import glob
import os
import re
import sys

RESTORE = re.compile(r"""^\s*(-\s+)?uses:\s*["']?actions/cache(/restore)?@""")
LOOKUP = "lookup-only: ${{ env.RELEASE == 'true' }}"
EXCEPTION = "bootc-reproducible"


def problems(text, name):
    lines = text.splitlines()
    found, job = [], None
    for i, line in enumerate(lines):
        m = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if m:
            job = m.group(1)
        if not RESTORE.match(line):
            continue
        # The step: from its "- " line to the next line indented no deeper than that dash.
        start = i
        while not lines[start].lstrip().startswith("- "):
            start -= 1
        indent = len(lines[start]) - len(lines[start].lstrip())
        end = start + 1
        while end < len(lines) and (not lines[end].strip() or
                                    len(lines[end]) - len(lines[end].lstrip()) > indent):
            end += 1
        step = [s.strip() for s in lines[start:end]]
        if job == EXCEPTION:
            first = lines.index(f"  {EXCEPTION}:")
            last = next((j for j in range(first + 1, len(lines)) if re.match(r"^ {0,2}\S", lines[j])),
                        len(lines))
            body = [s.strip() for s in lines[first:last]]
            if "permissions: {}" not in body or any("actions/checkout@" in s for s in body):
                found.append(f"{name}:{i + 1}: job {EXCEPTION} restores a cache, so it must have "
                             "`permissions: {}` and no checkout")
        elif LOOKUP not in step and "lookup-only: true" not in step:
            found.append(f"{name}:{i + 1}: a cache restore (job {job}) without `{LOOKUP}`")
    return found


def check(repo):
    files = [os.path.join(repo, ".github/workflows/image.yml")]
    files += sorted(glob.glob(os.path.join(repo, ".github/actions/*/action.y*ml")))
    found = []
    for f in files:
        with open(f) as fh:
            found += problems(fh.read(), os.path.relpath(f, repo))
    return found


def self_test():
    good = """jobs:
  build:
    steps:
      - name: Restore
        uses: actions/cache/restore@abc # v6
        with:
          lookup-only: ${{ env.RELEASE == 'true' }}
          path: x
      - uses: actions/cache/save@abc
        with:
          path: x
  bootc-reproducible:
    needs: build
    permissions: {}
    steps:
      - uses: actions/cache/restore@abc
        with:
          path: x
"""
    assert problems(good, "good") == [], problems(good, "good")
    bad = [
        good.replace("          lookup-only: ${{ env.RELEASE == 'true' }}\n", ""),
        good.replace("lookup-only: ${{ env.RELEASE == 'true' }}", "lookup-only: false"),
        good.replace("uses: actions/cache/save@abc", "uses: 'actions/cache@abc'"),
        good.replace("    permissions: {}\n", ""),
        good.replace("    steps:\n      - uses: actions/cache/restore@abc\n        with:\n          path: x\n",
                     "    steps:\n      - uses: actions/checkout@abc\n      - uses: actions/cache/restore@abc\n"
                     "        with:\n          path: x\n"),
    ]
    for text in bad:
        assert problems(text, "bad"), text
    print("check-release-cache.py self-test: ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        sys.exit(0)
    found = check(sys.argv[1] if len(sys.argv) > 1 else ".")
    for p in found:
        print(f"::error::{p}")
    sys.exit(1 if found else 0)
