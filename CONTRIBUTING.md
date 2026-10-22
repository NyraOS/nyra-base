# Contributing to nyra-base

This repository is the base of Nyra OS: what it builds boots on users' machines, so the rules are
strict but short.

- **Branch and pull request, never a push to `main`.** Enable the local guard once:
  `git config core.hooksPath tools/hooks` (`tools/hooks/pre-push` refuses a push to `main` and runs
  `ci/precheck.sh`, see "Before every push").
  Every change to the base is reviewed before it is merged (`.github/CODEOWNERS`).
- **One change per pull request**, small and with a clear reason. Prefer the simplest solution that
  works; no options or abstractions "for later".
- **Code rules** (for everyone, people and agents alike; reviews check them):
  - **Rust:** the code must be easy to read, without needless complication. A reader who knows
    Rust understands a function without jumping through five files; names say what a thing is;
    generics, traits, macros or `unsafe` only when really needed, with the reason written next to
    them; plain code instead of an abstraction used once; comments say why, not what.
- **Never weaken or skip a test to make it pass.** A flaky test is a bug: fix it or report it.
- **No secrets.** No keys, tokens or passwords in the repository, its history or CI logs; gitleaks
  scans every push. Test keys are generated in CI and deleted at the end (`tools/vm/secure-boot.sh`).
- **Configuration goes in `/usr`**, never in `/etc` of the image: `/etc` belongs to the user and is
  kept across updates (`docs/LESSONS.md`).
- **Pin what CI runs:** actions by commit SHA, container images by digest, packages by version or
  hash.
- **English** for code, comments, commit messages and documentation. New files carry an SPDX header
  (`GPL-3.0-or-later`, the licence of this repository); contributions are accepted under it. Exception: our patches to other projects in `patches/upstream/` are public domain
  (`Unlicense`, see `patches/upstream/README.md`).
- **CI minutes are limited:** run `ci/precheck.sh` before you push (below), and push once when the
  change is ready.

## Before every push

Run `ci/precheck.sh`. In about 40 seconds it runs what the `shellcheck` workflow runs (shellcheck
at the CI's version, the self-tests of the test tools, the lints of `ci/` and of the workflows,
actionlint) and a secret scan of your commits (gitleaks). The list of checks lives in that script and
CI runs the same script, so the two cannot drift. The pre-push hook runs it when you push anything
but Markdown files (only the secret scan for those).

- A tool that is not installed (shellcheck, actionlint, gitleaks) runs from a container image pinned
  by digest, in a podman store of its own (`~/.cache/nyra-precheck`, which must be yours with mode
  700, or the check is refused; the first run pulls the images). The test that needs root runs in a
  user namespace (`podman unshare`), never through `sudo`. A check that cannot run at all prints `SKIPPED` and fails the run; `--allow-skip` accepts
  that, and the SKIPPED line stays in the output. Never read a skipped check as a pass.
- The hook checks the checked-out tree, so it refuses to push any other ref (a tag, another branch):
  check the branch out, or push with `--no-verify`. `git push --no-verify` skips the hook, including
  its guard against pushes to `main`. It is for emergencies (the hook itself is broken, the registry is down); anything else it lets through, CI
  finds minutes later.
- A new offline check goes in `ci/precheck.sh`, not in a new workflow step.

What only CI can check, and why:

- **The image build, the boot, update, encryption and Titanic tests** (`image.yml`, `titanic.yml`,
  `arm64.yml`): they need KVM or an arm64 runner and 20 to 60 minutes. `/dev/kvm` is not available to
  every developer machine. Before you push a change to a guest script, rehearse its logic where you
  can: in a user namespace, with stubs, with a `--self-test` or an offline test next to it (like
  `tools/vm/test-network-health.sh`); prove that a new test fails when it should (run it against a
  copy of the code without the change); and say in the pull request what only the VM run can prove.
- **The SBOM and vulnerability gate** depends on the advisories of the day, not on your change: see
  "Before a push: the scan on a branch" in [`docs/SBOM.md`](docs/SBOM.md).
- **Signing, publishing and the release jobs** use the cloud keys and run on `main` only.
- **The Rust crates** (`updated.yml`, `ntpd-rs.yml`): `cargo fmt --check`, `cargo clippy` and
  `cargo test` run in CI; run them yourself when `cargo` is installed.

How the image is built and tested: [`README.md`](README.md), [`docs/BOOT.md`](docs/BOOT.md),
[`docs/SIGNING.md`](docs/SIGNING.md), [`docs/SBOM.md`](docs/SBOM.md), [`docs/LESSONS.md`](docs/LESSONS.md).
