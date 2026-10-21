#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The publish job's invariants (docs/SIGNING.md, "Publishing"), checked on every workflow in
.github/workflows. The R2 and Cloudflare secrets live only in the environment `publish`, and the
only job that uses that environment must not be able to sign:
- the job `publish` of image.yml exists, with `environment: publish` and exactly
  `permissions: {contents: read}` (so never `id-token`, never `actions: write`);
- `verify-published` has no environment and exactly `permissions: {contents: read}`;
- no job with `id-token: write` (its own or the workflow's) declares `environment: publish`;
- no environment named `publish` (any case, spaces around it ignored) anywhere else, and no
  environment name with an expression in it;
- nothing in a workflow, other than the job `publish` of image.yml, names a secret `R2_*` or
  `CLOUDFLARE_*`, reads the whole `secrets` context (`toJSON(secrets)`) or inherits the caller's
  secrets (`secrets: inherit`): the workflow's own `env`, `on.workflow_call.secrets` and every job.
This guards against mistakes, not against whoever can change the workflows.

  check-publish-job.py [REPO]   (the current directory by default)
  check-publish-job.py --self-test
"""
import copy
import glob
import os
import re
import sys

import yaml

EXPRESSION = re.compile(r"\$\{\{(.*?)\}\}", re.S)
NAMED_SECRET = re.compile(r"secrets\s*(\.\s*|\[\s*['\"])\s*(R2_|CLOUDFLARE_)", re.I)
# `secrets` as a whole (toJSON(secrets)), not `secrets.NAME` or `secrets['NAME']`.
WHOLE_SECRETS = re.compile(r"\bsecrets\b(?!\s*(\.|\[))", re.I)
READ_ONLY = {"contents": "read"}


def environment_name(job):
    env = job.get("environment")
    name = env.get("name") if isinstance(env, dict) else env
    return str(name).strip().lower() if name is not None else None


def strings(node):
    if isinstance(node, str):
        yield node
    elif isinstance(node, dict):
        for key, value in node.items():
            yield from strings(key)
            yield from strings(value)
    elif isinstance(node, list):
        for item in node:
            yield from strings(item)


def can_sign(permissions):
    return permissions == "write-all" or (
        isinstance(permissions, dict) and permissions.get("id-token") == "write")


def check_workflow(name, workflow):
    found = []
    jobs = workflow.get("jobs") or {}
    for job_name, job in jobs.items():
        where = f"{name} job {job_name}"
        permissions = job.get("permissions", workflow.get("permissions"))
        exempt = (name, job_name) == ("image.yml", "publish")
        environment = environment_name(job)
        if environment == "publish" and can_sign(permissions):
            found.append(f"{where}: `environment: publish` with `id-token: write`")
        if environment == "publish" and not exempt:
            found.append(f"{where}: only image.yml's `publish` may use the environment `publish`")
        if environment is not None and "${{" in environment:
            found.append(f"{where}: the environment name has an expression in it")
        if not exempt and str(job.get("secrets", "")).lower() == "inherit":
            found.append(f"{where}: inherits all secrets: only image.yml's `publish` may use these")
    # Everything but the exempt job: workflow-level env, on.workflow_call.secrets, every job.
    rest = {key: value for key, value in workflow.items() if key != "jobs"}
    rest["jobs"] = {job_name: job for job_name, job in jobs.items()
                    if (name, job_name) != ("image.yml", "publish")}
    text = " ".join(EXPRESSION.findall("\n".join(strings(rest))))
    if NAMED_SECRET.search(text):
        found.append(f"{name}: uses a secret named R2_* or CLOUDFLARE_*: only image.yml's `publish` may")
    if WHOLE_SECRETS.search(text):
        found.append(f"{name}: reads all secrets: only image.yml's `publish` may use these")
    if name == "image.yml":
        publish = jobs.get("publish")
        if publish is None:
            found.append("image.yml has no job `publish`")
        elif environment_name(publish) != "publish" or publish.get("permissions") != READ_ONLY:
            found.append("image.yml job publish must have `environment: publish` and exactly "
                         "`permissions: {contents: read}`")
        verify = jobs.get("verify-published")
        if verify is None:
            found.append("image.yml has no job `verify-published`")
        elif "environment" in verify or verify.get("permissions") != READ_ONLY:
            found.append("image.yml job verify-published must have no environment and exactly "
                         "`permissions: {contents: read}`")
    return found


def check(repo):
    found = []
    for path in sorted(glob.glob(os.path.join(repo, ".github/workflows/*.y*ml"))):
        with open(path) as f:
            found += check_workflow(os.path.basename(path), yaml.safe_load(f))
    return found


def self_test():
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, "../.github/workflows/image.yml")) as f:
        good = yaml.safe_load(f)
    assert check_workflow("image.yml", good) == [], check_workflow("image.yml", good)

    def broken(change):
        workflow = copy.deepcopy(good)
        change(workflow["jobs"])
        return check_workflow("image.yml", workflow)

    def put(job, key, value):
        return lambda jobs: jobs[job].__setitem__(key, value)

    def append_run(job, text):
        return lambda jobs: jobs[job]["steps"].append({"run": text})

    cases = {
        "publish with id-token": put("publish", "permissions", {"contents": "read", "id-token": "write"}),
        "publish with actions: write": put("publish", "permissions", {"contents": "read", "actions": "write"}),
        "publish without permissions": lambda jobs: jobs["publish"].pop("permissions"),
        "publish without environment": lambda jobs: jobs["publish"].pop("environment"),
        "publish in another environment": put("publish", "environment", "release"),
        "sign in environment publish": put("sign", "environment", "publish"),
        "release-sign in environment publish": put("release-sign", "environment", {"name": "Publish"}),
        "release-sign-arm64 in environment publish": put("release-sign-arm64", "environment", "publish"),
        "verify-published in an environment": put("verify-published", "environment", "publish"),
        "verify-published with write": put("verify-published", "permissions", {"contents": "write"}),
        "no verify-published": lambda jobs: jobs.pop("verify-published"),
        "no publish": lambda jobs: jobs.pop("publish"),
        "R2 secret in build": append_run("build", "echo ${{ secrets.R2_ACCESS_KEY_ID }}"),
        "R2 secret by index in sign": append_run("sign", "echo ${{ secrets['r2_secret_access_key'] }}"),
        "Cloudflare secret in release-image": append_run("release-image", "${{ SECRETS.CLOUDFLARE_KV_TOKEN }}"),
        "all secrets in verify-published": append_run("verify-published", "${{ toJSON(secrets) }}"),
        "inherited secrets": put("build", "secrets", "inherit"),
    }
    for what, change in cases.items():
        assert broken(change), f"accepted: {what}"
    # The exemption is image.yml's `publish` only, and the secret checks cover the whole document.
    assert check_workflow("other.yml", good), "accepted: a job `publish` in another workflow"
    for what, change in {
        "R2 secret in workflow env": lambda w: w.__setitem__("env", {"K": "${{ secrets.R2_ACCESS_KEY_ID }}"}),
        "all secrets in workflow env": lambda w: w.__setitem__("env", {"K": "${{ toJSON(secrets) }}"}),
        "R2 secret in workflow_call": lambda w: w.setdefault(True, {}).__setitem__(
            "workflow_call", {"secrets": {"x": {"default": "${{ secrets.R2_SECRET_ACCESS_KEY }}"}}}),
        "environment Publish in build": lambda w: w["jobs"]["build"].__setitem__("environment", " Publish "),
        "environment with an expression": lambda w: w["jobs"]["build"].__setitem__(
            "environment", {"name": "${{ vars.ENV }}"}),
    }.items():
        workflow = copy.deepcopy(good)
        change(workflow)
        assert check_workflow("image.yml", workflow), f"accepted: {what}"
    workflow = copy.deepcopy(good)
    workflow["permissions"] = {"id-token": "write"}
    del workflow["jobs"]["publish"]["permissions"]
    assert check_workflow("image.yml", workflow), "accepted: publish inheriting id-token: write"
    print("check-publish-job.py self-test: ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        sys.exit(0)
    problems = check(sys.argv[1] if len(sys.argv) > 1 else ".")
    for p in problems:
        print(f"::error::{p}")
    sys.exit(1 if problems else 0)
