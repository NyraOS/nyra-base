#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Release jobs unpack no cache. In .github/workflows/image.yml and in every local action its jobs use
(and the local actions those use), every step that uses a cache action other than its save (`uses`
with "/cache" in it, in any case) must only look the cache up in a release: `with:` has
`lookup-only: ${{ env.RELEASE == 'true' }}` or `lookup-only: true`. The one exception is the job
bootc-reproducible: `permissions: {}`, no secrets (no `secrets` in it, in any case), no `container:`
or `services:`, and no step but cache restores and `run` steps (so no checkout and no artifact upload).
Other actions must not restore a cache of their own either: no `cache:` or `cache-from:` in `with:`,
and `cache: false` for actions/setup-go and `package-manager-cache: false` for actions/setup-node,
which cache by default. Not followed, so refused: a job that calls a reusable workflow (`uses:` on the
job) and an action of this repository named by its remote reference instead of `./`. YAML merge keys
(`<<`) are refused in every workflow and in those local actions: PyYAML merges them, GitHub does not
read them the same way. A cache entry is not trusted: unpacking one can write any file the job can
write. This guards against mistakes, not against whoever can change the workflows; a cache restored
by hand in a `run` step is not looked for.

  check-release-cache.py [REPO]   (the current directory by default)
  check-release-cache.py --self-test
"""
import glob
import json
import os
import sys
import tempfile

import yaml

LOOKUP = ("${{ env.RELEASE == 'true' }}", True)
EXCEPTION = "bootc-reproducible"
THIS_REPO = "nyraos/nyra-base/"
OFF = (None, False, "false", "")


class Loader(yaml.SafeLoader):
    """PyYAML's safe loader, refusing merge keys (`<<`)."""

    def flatten_mapping(self, node):
        for key, _ in node.value:
            if key.tag == "tag:yaml.org,2002:merge":
                raise yaml.MarkedYAMLError(problem="YAML merge key `<<`, GitHub does not merge it",
                                           problem_mark=key.start_mark)
        super().flatten_mapping(node)


def load(path):
    with open(path) as f:
        return yaml.load(f, Loader=Loader)


def is_restore(uses):
    return "/cache" in uses.lower() and "/cache/save@" not in uses.lower()


def external_cache(uses, w):
    uses = uses.lower()
    return (w.get("cache") not in OFF or w.get("cache-from") not in OFF
            or ("/setup-go@" in uses and w.get("cache") not in (False, "false"))
            or ("/setup-node@" in uses and w.get("package-manager-cache") not in (False, "false")))


def steps_problems(repo, steps, where, seen):
    found = []
    for n, step in enumerate(steps or []):
        uses = str(step.get("uses", ""))
        w = step.get("with") or {}
        if is_restore(uses) and w.get("lookup-only") not in LOOKUP:
            found.append(f"{where}, step {n + 1}: {uses} without `lookup-only` for releases in `with:`")
        elif uses and external_cache(uses, w):
            found.append(f"{where}, step {n + 1}: {uses} restores a cache of its own (see `with:`)")
        if uses.lower().startswith(THIS_REPO):
            found.append(f"{where}, step {n + 1}: {uses}: name this repository's actions by `./` path")
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
            action = load(os.path.join(path, name))
            return steps_problems(repo, (action.get("runs") or {}).get("steps"), uses, seen)
    return [f"{uses}: no action.yml"]


def check(repo):
    try:
        return check_jobs(repo)
    except yaml.MarkedYAMLError as e:
        return [" ".join(str(e).split())]


def check_jobs(repo):
    for path in sorted(glob.glob(os.path.join(repo, ".github/workflows/*.y*ml"))):
        load(path)
    workflow = load(os.path.join(repo, ".github/workflows/image.yml"))
    found, seen = [], set()
    for name, job in workflow["jobs"].items():
        steps = job.get("steps") or []
        if "uses" in job:
            found.append(f"image.yml job {name} calls the workflow {job['uses']}, which is not checked")
            continue
        if name != EXCEPTION:
            found += steps_problems(repo, steps, f"image.yml job {name}", seen)
            continue
        others = [s.get("uses") for s in steps if "run" not in s and not is_restore(str(s.get("uses", "")))]
        if (job.get("permissions") != {} or "secrets" in json.dumps(job).lower() or others
                or "container" in job or "services" in job):
            found.append(f"image.yml job {name} restores a cache, so it must have `permissions: {{}}`, no "
                         f"secrets, no container or services and only cache restores and run steps "
                         f"(other steps: {others})")
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
      - uses: actions/setup-go@abc
        with: {go-version: '1.24', cache: false}
      - uses: actions/setup-node@abc
        with: {package-manager-cache: false}
      - uses: actions/setup-python@abc
        with: {python-version: '3.13'}
      - uses: docker/build-push-action@abc
        with: {push: false}
      - run: cat <<<"$x"
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
        good.replace("echo compare", "echo ${{ secrets['TOKEN'] }}"),
        good.replace("echo compare", "echo ${{ toJSON(secrets) }}"),
        good.replace("echo compare", "echo ${{ SECRETS.TOKEN }}"),
        good.replace("    permissions: {}\n", "    permissions: {}\n    container: debian\n"),
        good.replace("    permissions: {}\n", "    permissions: {}\n    services: {db: {image: debian}}\n"),
        good.replace("go-version: '1.24', cache: false", "go-version: '1.24'"),
        good.replace("{package-manager-cache: false}", "{package-manager-cache: true}"),
        good.replace("{python-version: '3.13'}", "{python-version: '3.13', cache: pip}"),
        good.replace("{push: false}", "{push: false, cache-from: type=gha}"),
        good.replace("./.github/actions/a/b", "NyraOS/nyra-base/.github/actions/a/b@abc"),
        good.replace("  bootc-reproducible:\n",
                     "  other:\n    uses: ./.github/workflows/x.yml\n  bootc-reproducible:\n"),
        good.replace("  bootc-reproducible:\n    needs: build\n",
                     "  bootc-reproducible:\n    needs: build\n    uses: ./.github/workflows/x.yml\n"),
        good.replace("  build:\n    steps:", "  build:\n    <<: {runs-on: ubuntu-24.04}\n    steps:"),
    ]
    with tempfile.TemporaryDirectory() as t:
        os.makedirs(os.path.join(t, ".github/workflows"))
        os.makedirs(os.path.join(t, ".github/actions/a/b"))

        def run(workflow, act, other="on: push\n"):
            with open(os.path.join(t, ".github/workflows/image.yml"), "w") as f:
                f.write(workflow)
            with open(os.path.join(t, ".github/workflows/other.yml"), "w") as f:
                f.write(other)
            with open(os.path.join(t, ".github/actions/a/b/action.yml"), "w") as f:
                f.write(act)
            return check(t)

        assert run(good, action) == [], run(good, action)
        assert run(good, bad_action), "a local action's restore without lookup-only passed"
        merge = "x: &x {a: 1}\ny:\n  <<: *x\n"
        assert "merge key" in str(run(good, action, merge)), "a merge key in another workflow passed"
        assert "merge key" in str(run(good, action + merge)), "a merge key in a local action passed"
        missing = good.replace("./.github/actions/a/b", "./.github/actions/none")
        assert any("no action.yml" in p for p in run(missing, action)), "a missing local action passed"
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
