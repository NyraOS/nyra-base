# SPDX-License-Identifier: GPL-3.0-or-later
# Only the sign jobs of image.yml (sign, sign-arm64) are in the environment sign, and only they and the
# release-sign jobs have id-token (run by ci/precheck.sh; python3 -I ci/check-sign-jobs.py, from the
# repository root).
import sys, yaml
workflow = yaml.safe_load(open(".github/workflows/image.yml"))
jobs = workflow["jobs"]
errors = []
def err(msg):
    print(f"::error::image.yml: {msg}")
    errors.append(msg)
def env_name(job):
    env = job.get("environment")
    return env.get("name") if isinstance(env, dict) else env
def may_get_token(perms):
    # write-all, read-all and the like are not mappings: counted as granting it.
    return not isinstance(perms, dict) or perms.get("id-token") == "write"
if not isinstance(workflow.get("permissions"), dict) or "id-token" in workflow["permissions"]:
    err("the workflow-level permissions must be a mapping without id-token")
for name, job in jobs.items():
    if "uses" in job:
        err(f"{name} must not call a reusable workflow")
    env = env_name(job)
    if env is not None and "$" + "{{" in str(env):
        err(f"{name}: the environment name must not be an expression")
    if name in ("sign", "sign-arm64"):
        if env != "sign":
            err(f"{name} must have exactly environment: sign")
    elif str(env).strip().lower() == "sign":
        err(f"only the sign jobs may have environment: sign, not {name}")
    if name in ("release-sign", "release-sign-arm64") and "environment" in job:
        err(f"{name} must have no environment")
    perms = job.get("permissions")
    if name in ("sign", "sign-arm64", "release-sign", "release-sign-arm64"):
        if not isinstance(perms, dict) or perms.get("id-token") != "write":
            err(f"{name} must have id-token: write")
    elif perms is not None and may_get_token(perms):
        err(f"{name}: permissions must be a mapping without id-token: write")
sys.exit(1 if errors else 0)
