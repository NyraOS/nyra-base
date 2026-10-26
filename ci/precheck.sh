#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The offline checks of the shellcheck workflow, and the secret scan, in one place: the workflow
# runs this script, so what runs on your machine before a push is what runs in CI. About 40 seconds.
#   ci/precheck.sh [--allow-skip] [--verbose] [--jobs N] [--only ID]...
#   ci/precheck.sh --list
# Run it from any directory of a checkout, before every push (tools/hooks/pre-push does it for you).
# It prints the output of the checks that fail or are skipped (all of it with --verbose, and in CI).
# It checks the working tree, so commit or stash what is not part of the push.
#
# A tool that is missing (shellcheck, actionlint, gitleaks) runs from a container image pinned by
# digest, in a podman store of its own (NYRA_PRECHECK_STORE, default ~/.cache/nyra-precheck, never the
# shared default store; it must be a directory of yours with mode 700, or the check is refused; remove it
# with `podman unshare rm -rf` on it). A check that cannot run at
# all is reported as SKIPPED and fails the run unless --allow-skip is given: it never passes silently.
# Exit status: 0 all passed (or skipped with --allow-skip), 1 a check failed, 2 a check was skipped.
# Under GitHub Actions (GITHUB_ACTIONS set) the tools of the runner are used and the secret scan is
# left to the secrets workflow.
#
# To add a check: one line at "THE LIST" below (and its function, if it is more than one command).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# A git hook runs with GIT_DIR and the like set: every git command here, in a temporary repository too,
# would act on the pushed repository. Find the repository from the directory instead.
# shellcheck disable=SC2046 # the names of the variables, one word each
unset $(git rev-parse --local-env-vars)

# Pinned: multi-arch index digests (the version is in the comment). The workflow installs the same
# actionlint version (checked below); gitleaks is the digest that .github/workflows/secrets.yml runs.
SHELLCHECK_VERSION=0.9.0 # the version preinstalled on ubuntu-24.04
SHELLCHECK_IMAGE=docker.io/koalaman/shellcheck@sha256:f35e8987b02760d4e76fc99a68ad5c42cc10bb32f3dd2143a3cf92f1e5446a45
ACTIONLINT_VERSION=1.7.12
JQ_IMAGE=ghcr.io/jqlang/jq@sha256:096b83865ad59b5b02841f103f83f45c51318394331bf1995e187ea3be937432 # jq 1.7.1, a static /jq
ACTIONLINT_IMAGE=docker.io/rhysd/actionlint@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667
STORE="${NYRA_PRECHECK_STORE:-${XDG_CACHE_HOME:-$HOME/.cache}/nyra-precheck}"
IN_CI="${GITHUB_ACTIONS:+1}"

SKIPPED=77 # what a check returns when it cannot run
skip() { echo "SKIPPED: $*"; return "$SKIPPED"; }

# store: podman with the store of its own. The store holds the images that the checks trust, so it is
# used only if it is a real directory of this user that nobody else can enter (not a link, mode 700);
# anyone else who made it first could have put other images under the pinned names.
store() {
  command -v podman >/dev/null || return 127
  if [ -L "$STORE" ]; then
    echo "precheck: $STORE is a symbolic link: refused" >&2
    return 1
  fi
  mkdir -p "$(dirname "$STORE")" && install -d -m 700 "$STORE" || return 1
  if [ "$(stat -c '%u %a' "$STORE")" != "$(id -u) 700" ] || [ -L "$STORE" ]; then
    echo "precheck: $STORE is not a directory of yours with mode 700: refused (remove it, or set NYRA_PRECHECK_STORE)" >&2
    return 1
  fi
  podman --root "$STORE/root" --runroot "$STORE/run" "$@"
}
# container IMAGE ARGS...: run IMAGE with the working tree mounted read-only at /repo, no network.
container() {
  local image="$1"
  shift
  store run --rm -i --network=none -v "$PWD:/repo:ro" -w /repo "$image" "$@"
}
# pull IMAGE: fetch it into the store of its own (needs the network, once).
pull() {
  store image exists "$1" || store pull -q "$1" >/dev/null
}

check_shellcheck() {
  local scripts
  mapfile -t scripts < <(git ls-files | while read -r f; do
    [ -f "$f" ] && head -n 1 "$f" | grep -qE '^#!(/usr)?/bin/(env )?(ba|da)?sh( |$)' && echo "$f"; done)
  if [ -n "$IN_CI" ]; then printf '%s\n' "${scripts[@]}"; else echo "${#scripts[@]} scripts"; fi
  if [ -n "$IN_CI" ] || shellcheck --version 2>/dev/null | grep -qx "version: $SHELLCHECK_VERSION"; then
    shellcheck --version
    shellcheck -S warning "${scripts[@]}"
  else
    pull "$SHELLCHECK_IMAGE" || { skip "shellcheck $SHELLCHECK_VERSION is not installed and its image is not available (apt install shellcheck, or podman and the network)"; return "$SKIPPED"; }
    container "$SHELLCHECK_IMAGE" --version
    container "$SHELLCHECK_IMAGE" -S warning "${scripts[@]}"
  fi
}

check_actionlint() {
  # The workflow installs the version that the image here runs.
  grep -q "ACTIONLINT_VERSION: $ACTIONLINT_VERSION\$" .github/workflows/shellcheck.yml ||
    { echo "ACTIONLINT_VERSION in shellcheck.yml is not $ACTIONLINT_VERSION (the image of this script)"; return 1; }
  if [ -n "$IN_CI" ] || actionlint -version 2>/dev/null | head -n 1 | grep -qx "$ACTIONLINT_VERSION"; then
    actionlint -shellcheck= -pyflakes=
  else
    pull "$ACTIONLINT_IMAGE" || { skip "actionlint $ACTIONLINT_VERSION is not installed and its image is not available (podman and the network)"; return "$SKIPPED"; }
    container "$ACTIONLINT_IMAGE" -shellcheck= -pyflakes=
  fi
}

# The test that needs root: in a user namespace (podman unshare), so that a script of the branch never
# runs as the real root on a developer's machine. On the CI runner, root is the runner's, with sudo.
# with_jq COMMAND...: the offline tests that need jq (preinstalled on the runner). Without one on this
# machine, the jq of the pinned image is used, from a temporary directory.
with_jq() {
  if ! command -v jq >/dev/null; then
    local bin c rc
    pull "$JQ_IMAGE" || { skip "jq is not installed and its image is not available (apt install jq, or podman and the network)"; return "$SKIPPED"; }
    bin="$(mktemp -d)" || return 1
    c="$(store create "$JQ_IMAGE")" && store cp "$c:/jq" "$bin/jq" >/dev/null && store rm "$c" >/dev/null || { rm -rf "$bin"; return 1; }
    PATH="$bin:$PATH" "$@" && rc=0 || rc=$?
    rm -rf "$bin"
    return "$rc"
  fi
  "$@"
}
check_machine_interface() { with_jq tools/install/test-machine-interface.sh; }
check_iso_manifest() { with_jq ci/iso-manifest.sh --self-test; }

check_etc_copy() {
  if [ -n "$IN_CI" ]; then
    sudo -n tools/vm/test-etc-copy.sh
  elif [ "$(id -u)" = 0 ]; then
    tools/vm/test-etc-copy.sh
  elif command -v podman >/dev/null; then
    store unshare tools/vm/test-etc-copy.sh
  else
    skip "needs a user namespace: install podman (podman unshare)"
    return "$SKIPPED"
  fi
}

# The first administrator's test runs the real useradd, chpasswd and systemd-firstboot in a root of its
# own, in a mount namespace: as root in a user namespace here (podman unshare), as the runner's root in CI.
check_first_admin() {
  if [ -n "$IN_CI" ]; then
    sudo -n tools/vm/test-first-admin.sh
  elif [ "$(id -u)" = 0 ]; then
    tools/vm/test-first-admin.sh
  elif command -v podman >/dev/null; then
    store unshare tools/vm/test-first-admin.sh
  else
    skip "needs a user namespace: install podman (podman unshare)"
    return "$SKIPPED"
  fi
}

check_engine_lint() {
  # The brackets keep this line from matching itself.
  if git grep -nE 'sbsign.*(--engin[e]| -[e]( |=|$)|pkcs1[1])' -- . ':!tools/signing/sign-uki.sh'; then
    echo "only tools/signing/sign-uki.sh may sign with an engine or a pkcs11 key" >&2
    return 1
  fi
}

# The secret scan of the commits that are not on origin/main yet (the secrets workflow scans every
# push in CI, with the same image: its digest is read from there).
# Every commit is scanned with its patch, so a secret added in one commit and removed in the next
# is found, as it stays in the history that is pushed. Whether there is anything to scan is decided
# by the commits, never by the difference of the trees.
gitleaks_image() {
  grep -oE 'ghcr\.io/gitleaks/gitleaks@sha256:[0-9a-f]{64}' .github/workflows/secrets.yml | head -n 1
}
# scan_commits DIR RANGE...: the patches of the commits of RANGE in the repository DIR, through gitleaks.
scan_commits() {
  git -C "$1" log -p --no-color --format=fuller "${@:2}" | container "$(gitleaks_image)" stdin --redact --no-banner -v
}
check_gitleaks() {
  local image range=()
  image="$(gitleaks_image)"
  [ -n "$image" ] || { echo "no gitleaks image digest in .github/workflows/secrets.yml"; return 1; }
  if base="$(git merge-base origin/main HEAD 2>/dev/null)"; then
    range=("$base..HEAD")
  else
    range=(HEAD) # no origin/main: all the history counts
  fi
  [ "$(git rev-list --count "${range[@]}")" != 0 ] || { echo "no commits to scan (${range[*]})"; return 0; }
  pull "$image" || { skip "gitleaks is not available (podman and the network)"; return "$SKIPPED"; }
  scan_commits . "${range[@]}"
}
# The control of the scan: a secret added in one commit and removed in the next must be found, and a
# repository without it must pass. Without this, a scan that finds nothing looks the same as one that works.
check_gitleaks_control() {
  local image repo status=0
  image="$(gitleaks_image)"
  pull "$image" || { skip "gitleaks is not available (podman and the network)"; return "$SKIPPED"; }
  repo="$(mktemp -d)"
  git -C "$repo" init -q
  [ "$(git -C "$repo" rev-parse --absolute-git-dir)" = "$(cd "$repo" && pwd -P)/.git" ] ||
    { echo "control: git does not work on the temporary repository $repo"; rm -rf "$repo"; return 1; }
  git -C "$repo" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m base
  printf '%s\n' 'key = 1' >"$repo/f"
  git -C "$repo" add f && git -C "$repo" -c user.name=t -c user.email=t@example.com commit -q -m clean
  scan_commits "$repo" HEAD >/dev/null 2>&1 || { echo "control: a repository without a secret was refused"; status=1; }
  # A private key block built here, so that no secret-like text is in this file.
  { printf -- '-----BEGIN %s KEY-----\n' 'RSA PRIVATE'; printf '%s\n' MIIEowIBAAKCAQEAyfakefakefakefakefakefakefakefakefakefakefake1 QwErTyUiOpAsDfGhJkLzXcVbNm0123456789qwertyuiopASDFGHJKLZXCVBNMabcd xK9mP2vL8nQ4tR7yU1wE5oI3aS6dF0gH2jK4lZ8xC9vB1nM3qW5eR7tY9uI0oP2a; printf -- '-----END %s KEY-----\n' 'RSA PRIVATE'; } >"$repo/f"
  git -C "$repo" -c user.name=t -c user.email=t@example.com commit -q -am secret
  printf '%s\n' 'key = 1' >"$repo/f"
  git -C "$repo" -c user.name=t -c user.email=t@example.com commit -q -am revert
  [ -z "$(git -C "$repo" diff HEAD~2 HEAD)" ] || { echo "control: the trees should be equal"; status=1; }
  if scan_commits "$repo" HEAD~2..HEAD >/dev/null 2>&1; then
    echo "control: a secret added and removed in the next commit was not found"
    status=1
  else
    echo "control: the secret added and removed in the next commit was found"
  fi
  rm -rf "$repo"
  return "$status"
}

# THE LIST: ID, the heading of its output (the step names of the shellcheck workflow), the command.
IDS=() TITLES=() CMDS=() LOCAL_ONLY=()
check() { IDS+=("$1"); TITLES+=("$2"); CMDS+=("$3"); LOCAL_ONLY+=("${4:-}"); }
check shellcheck "shellcheck" check_shellcheck
check security-defaults "Self-test of the secure-defaults guest commands (tools/vm/security-defaults.sh)" "tools/vm/security-defaults.sh --self-test"
check etc-copy "The copies of /etc, their restore, and which a run removes (tools/vm/test-etc-copy.sh)" check_etc_copy
check first-admin "The first administrator: the account, the refusals, the fixed defaults (tools/vm/test-first-admin.sh)" check_first_admin
check nyra-update "Offline test of the waiting part of nyra update (tools/vm/test-nyra-update.sh)" "tools/vm/test-nyra-update.sh"
check reserved-names "Offline test of the list of reserved names for the release tree (tools/install/test-reserved-names.sh)" "tools/install/test-reserved-names.sh"
check network-health "Offline test of the network health check (tools/vm/test-network-health.sh)" "tools/vm/test-network-health.sh"
check vm-boot "Self-test of the console matching (tools/vm/vm-boot.py)" "python3 -I tools/vm/vm-boot.py --self-test"
check screen-boot "Self-test of the power button wait of the screen test (tools/vm/screen-boot.py)" "python3 -I tools/vm/screen-boot.py --self-test"
check tpm-enroll "Offline test of the disk's TPM2 enrollment script (tools/vm/test-tpm-enroll.sh)" "tools/vm/test-tpm-enroll.sh"
check titanic-results "Self-test of the Titanic results (tools/titanic/results.py)" "python3 -I tools/titanic/results.py --self-test"
check verify-oci "Self-test of the cached image check (ci/verify-oci.py)" "python3 -I ci/verify-oci.py --self-test"
check image-yml-change "Self-test of the image.yml change check (ci/image-yml-change.py)" "python3 -I ci/image-yml-change.py --self-test"
check release-cache "Release jobs unpack no cache (ci/check-release-cache.py)" "python3 -I ci/check-release-cache.py --self-test && python3 -I ci/check-release-cache.py"
check check-artifact "Self-test of the artifact check (ci/check-artifact.sh)" "ci/check-artifact.sh --self-test"
check release-tree "Offline test of the installer's release tree mode (tools/install/test-release-tree.sh)" "tools/install/test-release-tree.sh"
check machine-interface "Offline test of the installer's interface for programs (tools/install/test-machine-interface.sh)" check_machine_interface
check mokauth "Self-test of the check that the Secure Boot request is for the password shown (tools/iso/mokauth.py)" "python3 -I tools/iso/mokauth.py --self-test"
check iso-manifest "Self-test of the ISO package list (ci/iso-manifest.sh)" check_iso_manifest
check sign-uki "Offline test of the UKI signing script (tools/signing/test-sign-uki.sh)" "tools/signing/test-sign-uki.sh"
check engine-lint "Only sign-uki.sh signs with an engine or a pkcs11 key" check_engine_lint
check sign-jobs "Only the sign jobs are in the environment sign and only they and the release-sign jobs have id-token (ci/check-sign-jobs.py)" "python3 -I ci/check-sign-jobs.py"
check publish-job "The publish job holds the secrets and cannot sign (ci/check-publish-job.py)" "python3 -I ci/check-publish-job.py --self-test && python3 -I ci/check-publish-job.py"
check credential-jobs "Only image.yml's sign jobs have id-token and the environment sign (ci/check-credential-jobs.py)" "python3 -I ci/check-credential-jobs.py --self-test && python3 -I ci/check-credential-jobs.py"
check iso-jobs "The ISO jobs of a pull request do not wait for sign and run the steps of the release ones (ci/check-iso-jobs.py)" "python3 -I ci/check-iso-jobs.py --self-test && python3 -I ci/check-iso-jobs.py"
check actionlint "actionlint" check_actionlint
check gitleaks "Secret scan of the commits not on origin/main (gitleaks)" check_gitleaks local
check gitleaks-control "Control of the secret scan: a secret added, then removed in the next commit, is found" check_gitleaks_control local

allow_skip=0 verbose=${IN_CI:+1} jobs=4 only=()
while [ $# -gt 0 ]; do
  case "$1" in
    --allow-skip) allow_skip=1 ;;
    --verbose) verbose=1 ;;
    --jobs) jobs="${2:?--jobs needs a number}"; shift ;;
    --only) only+=("${2:?--only needs an ID}"); shift ;;
    --list) printf '%s\n' "${IDS[@]}"; exit 0 ;;
    *) sed -n '3,6p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
  esac
  shift
done

selected=()
for i in "${!IDS[@]}"; do
  if [ "${#only[@]}" -gt 0 ]; then
    printf '%s\n' "${only[@]}" | grep -qx "${IDS[$i]}" || continue
  elif [ -n "$IN_CI" ] && [ -n "${LOCAL_ONLY[$i]}" ]; then
    echo "(${IDS[$i]} is not run here: the secrets workflow does it)"
    continue
  fi
  selected+=("$i")
done
for o in "${only[@]}"; do
  printf '%s\n' "${IDS[@]}" | grep -qx "$o" || { echo "precheck: no check with the ID $o (ci/precheck.sh --list)" >&2; exit 1; }
done

if [ -z "$IN_CI" ] && [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "note: uncommitted changes in the working tree: the checks run on the working tree, not on the commits"
fi

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
start=$SECONDS
# Run the checks at most $jobs at a time, each with its output in a file of its own, printed in the
# order of the list below so that the log reads the same on every run.
run_one() { # run_one INDEX: the output and the status of one check, and how long it took
  local t=$SECONDS rc
  (eval "${CMDS[$1]}") >"$out/$1.out" 2>&1 </dev/null
  rc=$?
  echo "$rc $((SECONDS - t))" >"$out/$1.rc"
}
for i in "${selected[@]}"; do
  while [ "$(jobs -rp | wc -l)" -ge "$jobs" ]; do wait -n; done
  run_one "$i" &
done
wait

failed=() skipped=() passed=0
for i in "${selected[@]}"; do
  read -r rc secs <"$out/$i.rc"
  if [ "$rc" = 0 ]; then
    if [ -z "$verbose" ]; then
      echo "ok   ${TITLES[$i]} (${secs}s)"
    else
      [ -n "$IN_CI" ] && echo "::group::${TITLES[$i]} (${secs}s)" || echo "=== ${TITLES[$i]} (${secs}s)"
      cat "$out/$i.out"
      [ -n "$IN_CI" ] && echo "::endgroup::"
    fi
    passed=$((passed + 1))
  elif [ "$rc" = "$SKIPPED" ]; then
    echo "=== ${TITLES[$i]}"
    cat "$out/$i.out"
    echo "!!! SKIPPED: ${IDS[$i]} did not run"
    skipped+=("${IDS[$i]}")
  else
    echo "=== ${TITLES[$i]} (${secs}s)"
    cat "$out/$i.out"
    echo "!!! FAILED: ${IDS[$i]} (status $rc)"
    [ -n "$IN_CI" ] && echo "::error title=${IDS[$i]}::${TITLES[$i]} failed"
    failed+=("${IDS[$i]}")
  fi
done

echo "=== precheck: $passed passed, ${#failed[@]} failed, ${#skipped[@]} skipped, $((SECONDS - start)) s"
[ "${#failed[@]}" -eq 0 ] || { echo "FAILED:  ${failed[*]}"; }
[ "${#skipped[@]}" -eq 0 ] || echo "SKIPPED: ${skipped[*]} (nothing was checked for them$([ "$allow_skip" = 1 ] && echo '; --allow-skip given'))"
[ "${#failed[@]}" -eq 0 ] || exit 1
[ "${#skipped[@]}" -eq 0 ] || [ "$allow_skip" = 1 ] || exit 2
exit 0
