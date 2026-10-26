#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""No workflow calls another workflow of this repository, except titanic.yml's one call of image.yml.

The `changes` job of image.yml lets a change to any workflow file but image.yml and arm64.yml skip the
image build and its tests, because such a workflow runs by itself and image.yml does not call it. A job
that calls a reusable workflow (`uses: ./.github/workflows/x.yml`, or the same repository by name,
`OWNER/REPO/.github/workflows/x.yml@ref`) would break that. The files are parsed as YAML, so quotes, a
quoted key, a value on the next line and a block scalar are all seen: any `uses` value anywhere in a
workflow that contains `.github/workflows/` is refused, except the one call of titanic.yml's job `image`.

  check-workflow-calls.py [REPO]   (the current directory by default)
  check-workflow-calls.py --self-test
"""
import glob
import os
import sys

import yaml

ALLOWED = ("titanic.yml", "image", "./.github/workflows/image.yml")


def uses_values(node, path=()):
    """Every (path, value) of a `uses` key in the parsed YAML, at any depth."""
    if isinstance(node, dict):
        for key, value in node.items():
            if str(key).strip().lower() == "uses":
                yield path, value
            yield from uses_values(value, path + (str(key),))
    elif isinstance(node, list):
        for i, value in enumerate(node):
            yield from uses_values(value, path + (str(i),))


def problems(texts):
    """texts: {file name: YAML text}. The refused calls, as strings."""
    found = []
    for name, text in sorted(texts.items()):
        try:
            workflow = yaml.safe_load(text)
        except yaml.YAMLError as e:
            found.append(f"{name}: not valid YAML ({e})")
            continue
        for path, value in uses_values(workflow):
            where = f"{name} {'/'.join(path)}"
            if not isinstance(value, str):
                found.append(f"{where}: `uses` is not a string")
            elif ".github/workflows/" in value.lower().replace("\\", "/"):
                job = path[1] if len(path) == 2 and path[0] == "jobs" else None
                if (name, job, value) != ALLOWED:
                    found.append(f"{where}: calls the workflow {value!r}")
    return found


def self_test():
    call = "jobs:\n  a:\n    {form}\n"
    titanic = "jobs:\n  image:\n    uses: ./.github/workflows/image.yml\n"
    cases = [
        ("plain", {"x.yml": call.format(form="uses: ./.github/workflows/y.yml")}, True),
        ("double quoted", {"x.yml": call.format(form='uses: "./.github/workflows/y.yml"')}, True),
        ("single quoted", {"x.yml": call.format(form="uses: './.github/workflows/y.yml'")}, True),
        ("quoted key", {"x.yml": call.format(form='"uses": ./.github/workflows/y.yml')}, True),
        ("value on the next line", {"x.yml": "jobs:\n  a:\n    uses:\n      ./.github/workflows/y.yml\n"}, True),
        ("folded block", {"x.yml": "jobs:\n  a:\n    uses: >-\n      ./.github/workflows/y.yml\n"}, True),
        ("literal block", {"x.yml": "jobs:\n  a:\n    uses: |\n      ./.github/workflows/y.yml\n"}, True),
        ("same repository by name", {"x.yml": call.format(form="uses: NyraOS/nyra-base/.github/workflows/y.yml@main")}, True),
        ("upper case path", {"x.yml": call.format(form="uses: ./.GitHub/Workflows/y.yml")}, True),
        ("a step", {"x.yml": "jobs:\n  a:\n    steps:\n      - uses: ./.github/workflows/y.yml\n"}, True),
        ("a flow mapping", {"x.yml": "jobs: {a: {uses: ./.github/workflows/y.yml}}\n"}, True),
        ("not a string", {"x.yml": "jobs:\n  a:\n    uses: [./.github/workflows/y.yml]\n"}, True),
        ("not YAML", {"x.yml": "jobs: [\n"}, True),
        ("titanic calls image.yml", {"titanic.yml": titanic}, False),
        ("titanic's call, quoted (the same value)", {"titanic.yml": 'jobs:\n  image:\n    uses: "./.github/workflows/image.yml"\n'}, False),
        ("titanic calls another workflow", {"titanic.yml": titanic.replace("image.yml", "arm64.yml")}, True),
        ("titanic calls image.yml twice", {"titanic.yml": titanic + "  again:\n    uses: ./.github/workflows/image.yml\n"}, True),
        ("another file calls image.yml", {"x.yml": call.format(form="uses: ./.github/workflows/image.yml")}, True),
        ("titanic calls it from another job", {"titanic.yml": titanic.replace("  image:", "  other:")}, True),
        ("an action, no workflow", {"x.yml": "jobs:\n  a:\n    steps:\n      - uses: actions/checkout@v4\n      - uses: ./.github/actions/x\n"}, False),
        ("no uses", {"x.yml": "jobs:\n  a:\n    steps: [{run: echo}]\n"}, False),
    ]
    failed = 0
    for name, texts, expected in cases:
        found = problems(texts)
        ok = bool(found) == expected
        print(f"{'ok  ' if ok else 'FAIL'} {name}{': ' + '; '.join(found) if found else ''}")
        failed += not ok
    return 1 if failed else 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    files = sorted(glob.glob(os.path.join(root, ".github/workflows/*.y*ml")))
    if not files:
        sys.exit("check-workflow-calls.py: no workflow files found")
    found = problems({os.path.basename(f): open(f).read() for f in files})
    for f in found:
        print(f"::error::{f}")
    if not found:
        print("no workflow calls another one but titanic.yml's call of image.yml")
    sys.exit(1 if found else 0)
