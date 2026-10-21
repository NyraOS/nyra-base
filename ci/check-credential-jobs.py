#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Which jobs may hold a signing credential (docs/SIGNING.md, "Who can sign"), checked on every
workflow in .github/workflows. The identity providers check `workflow_ref`, which for a called
workflow names the caller, so a job of any workflow image.yml calls could otherwise get the KMS and
keyless-signing tokens. Refused:
- `id-token: write` (a job's, the workflow's, `write-all`, or permissions that are not a mapping)
  anywhere but the jobs `release-sign`, `release-sign-arm64` and `sign` of image.yml (the arm64
  release signs its UKI with the same KMS keys in a job of its own, on x86_64, so that the x86_64
  release never waits for the arm64 build, docs/ARM64.md);
- an environment `sign` (any case, spaces ignored) or an environment name with an expression in it,
  anywhere but image.yml's `sign`;
- a job that calls a reusable workflow (`uses:`) without exactly `permissions: {contents: read}`
  (missing permissions inherit the workflow's, so they count as wrong), with any `secrets:` key,
  and `secrets: inherit` anywhere.
This guards against mistakes, not against whoever can change the workflows.

  check-credential-jobs.py [REPO]   (the current directory by default)
  check-credential-jobs.py --self-test
"""
import copy
import glob
import os
import sys

import yaml

CAN_SIGN = {("image.yml", "release-sign"), ("image.yml", "release-sign-arm64"),
            ("image.yml", "sign")}
IN_ENVIRONMENT_SIGN = ("image.yml", "sign")
READ_ONLY = {"contents": "read"}
# The nightly Titanic run calls image.yml, and GitHub refuses the call unless it allows what image.yml's
# jobs declare, id-token included; image.yml's sign jobs never run then (docs/SIGNING.md). Exactly these
# permissions, for this one call, until image.yml no longer needs them.
TITANIC_CALL = ("titanic.yml", "image")
TITANIC_CALL_USES = "./.github/workflows/image.yml"
TITANIC_CALL_PERMISSIONS = {"contents": "read", "actions": "read", "id-token": "write"}


def gives_token(permissions):
    # write-all, read-all and the like are not mappings: counted as granting it.
    return permissions is not None and (
        not isinstance(permissions, dict) or str(permissions.get("id-token", "none")).lower() != "none")


def environment_name(job):
    env = job.get("environment")
    name = env.get("name") if isinstance(env, dict) else env
    return str(name).strip().lower() if name is not None else None


def check_workflow(name, workflow):
    found = []
    if gives_token(workflow.get("permissions")):
        found.append(f"{name}: the workflow-level permissions must be a mapping without id-token")
    for job_name, job in (workflow.get("jobs") or {}).items():
        where = f"{name} job {job_name}"
        key = (name, job_name)
        titanic_call = key == TITANIC_CALL and job.get("uses") == TITANIC_CALL_USES
        allowed = TITANIC_CALL_PERMISSIONS if titanic_call else READ_ONLY
        if key not in CAN_SIGN and not titanic_call and gives_token(job.get("permissions")):
            found.append(f"{where}: only image.yml's release-sign, release-sign-arm64 and sign may have "
                         "id-token: write")
        environment = environment_name(job)
        if environment is not None and "${{" in environment:
            found.append(f"{where}: the environment name has an expression in it")
        elif environment == "sign" and key != IN_ENVIRONMENT_SIGN:
            found.append(f"{where}: only image.yml's `sign` may use the environment `sign`")
        if "uses" in job and job.get("permissions") != allowed:
            found.append(f"{where}: a job calling a reusable workflow must have exactly "
                         "`permissions: {contents: read}`")
        if "uses" in job and "secrets" in job:
            found.append(f"{where}: a job calling a reusable workflow must not pass `secrets:`")
        if str(job.get("secrets", "")).strip().lower() == "inherit":
            found.append(f"{where}: `secrets: inherit` is not allowed")
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

    def broken(change, name="image.yml"):
        workflow = copy.deepcopy(good)
        change(workflow)
        return check_workflow(name, workflow)

    def job(name, key, value):
        return lambda w: w["jobs"][name].__setitem__(key, value)

    def call(w):
        w["jobs"]["caller"] = {"uses": "./.github/workflows/arm64.yml",
                               "permissions": {"contents": "read"}}

    def call_with(key, value):
        def change(w):
            call(w)
            w["jobs"]["caller"][key] = value
        return change

    def call_without_permissions(w):
        call(w)
        del w["jobs"]["caller"]["permissions"]

    assert broken(call) == [], "refused: a read-only reusable workflow call"
    cases = {
        "id-token in build": job("build", "permissions", {"contents": "read", "id-token": "write"}),
        "write-all in build": job("build", "permissions", "write-all"),
        "read-all in build": job("build", "permissions", "read-all"),
        "id-token in publish": job("publish", "permissions", {"contents": "read", "id-token": "write"}),
        "id-token in build-arm64": job("build-arm64", "permissions", {"contents": "read", "id-token": "write"}),
        "id-token in release-image-arm64": job("release-image-arm64", "permissions",
                                               {"contents": "read", "id-token": "write"}),
        "write-all in boot-arm64": job("boot-arm64", "permissions", "write-all"),
        "environment sign in release-sign-arm64": job("release-sign-arm64", "environment", "sign"),
        "id-token at workflow level": lambda w: w.__setitem__("permissions", {"id-token": "write"}),
        "write-all at workflow level": lambda w: w.__setitem__("permissions", "write-all"),
        "environment sign in build": job("build", "environment", "sign"),
        "environment Sign in release-sign": job("release-sign", "environment", " Sign "),
        "environment name: sign in publish": job("publish", "environment", {"name": "SIGN"}),
        "environment expression in build": job("build", "environment", {"name": "${{ vars.ENV }}"}),
        "environment expression in sign": job("sign", "environment", "${{ 'sign' }}"),
        "call without permissions": call_without_permissions,
        "call with write permissions": call_with("permissions", {"contents": "write"}),
        "call with extra permissions": call_with("permissions", {"contents": "read", "actions": "read"}),
        "call with id-token": call_with("permissions", {"contents": "read", "id-token": "write"}),
        "call with write-all": call_with("permissions", "write-all"),
        "call of another repository's workflow": lambda w: w["jobs"].__setitem__(
            "caller", {"uses": "other/repo/.github/workflows/x.yml@main"}),
        "call inheriting secrets": call_with("secrets", "inherit"),
        "call passing secrets": call_with("secrets", {"TOKEN": "${{ secrets.TOKEN }}"}),
        "call with empty secrets": call_with("secrets", None),
        "build inheriting secrets": job("build", "secrets", "inherit"),
    }
    for what, change in cases.items():
        assert broken(change), f"accepted: {what}"
    # The exemptions are image.yml's jobs only.
    assert broken(lambda w: w["jobs"].__setitem__("image", {
        "uses": "./.github/workflows/image.yml", "permissions": TITANIC_CALL_PERMISSIONS})), \
        "accepted: the Titanic call's permissions in image.yml"
    titanic_call = {"uses": "./.github/workflows/image.yml", "permissions": TITANIC_CALL_PERMISSIONS}
    assert check_workflow("titanic.yml", {"jobs": {"image": titanic_call}}) == []
    other_call = {**titanic_call, "uses": "./.github/workflows/arm64.yml"}
    assert check_workflow("titanic.yml", {"jobs": {"image": other_call}}), \
        "accepted: another workflow"
    titanic_call["permissions"] = {**TITANIC_CALL_PERMISSIONS, "packages": "write"}
    assert check_workflow("titanic.yml", {"jobs": {"image": titanic_call}}), "accepted: more permissions"
    assert len(check_workflow("other.yml", good)) >= 4, "accepted: the exemptions in another workflow"
    # The exemption is by job name: a job named like the arm64 signer in another workflow is refused.
    arm64_signer = {"permissions": {"contents": "read", "id-token": "write"}}
    assert check_workflow("arm64.yml", {"jobs": {"release-sign-arm64": arm64_signer}}), \
        "accepted: release-sign-arm64 in arm64.yml"
    print("check-credential-jobs.py self-test: ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        sys.exit(0)
    problems = check(sys.argv[1] if len(sys.argv) > 1 else ".")
    for p in problems:
        print(f"::error::{p}")
    sys.exit(1 if problems else 0)
