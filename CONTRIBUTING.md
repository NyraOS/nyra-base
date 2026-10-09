# Contributing to nyra-base

This repository is the base of Nyra OS: what it builds boots on users' machines, so the rules are
strict but short.

- **Branch and pull request, never a push to `main`.** Enable the local guard once:
  `git config core.hooksPath tools/hooks` (`tools/hooks/pre-push` refuses a push to `main`).
  Every change to the base is reviewed before it is merged (`.github/CODEOWNERS`).
- **One change per pull request**, small and with a clear reason. Prefer the simplest solution that
  works; no options or abstractions "for later".
- **Never weaken or skip a test to make it pass.** A flaky test is a bug: fix it or report it.
- **No secrets.** No keys, tokens or passwords in the repository, its history or CI logs; gitleaks
  scans every push. Test keys are generated in CI and deleted at the end (`tools/vm/secure-boot.sh`).
- **Configuration goes in `/usr`**, never in `/etc` of the image: `/etc` belongs to the user and is
  kept across updates (`docs/LESSONS.md`).
- **Pin what CI runs:** actions by commit SHA, container images by digest, packages by version or
  hash.
- **English** for code, comments, commit messages and documentation. New files carry an SPDX header
  (`GPL-3.0-or-later`, the licence of this repository); contributions are accepted under it.
- **CI minutes are limited:** run shellcheck, actionlint and the offline tests locally before you
  push, and push once when the change is ready.

How the image is built and tested: [`README.md`](README.md), [`docs/BOOT.md`](docs/BOOT.md),
[`docs/SIGNING.md`](docs/SIGNING.md), [`docs/SBOM.md`](docs/SBOM.md), [`docs/LESSONS.md`](docs/LESSONS.md).
