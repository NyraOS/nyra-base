# Automatic security updates (design)

Status: proposal, nothing here is implemented. Scope: the base image (`nyra-base`, `nyra-base-arm64`) and the
desktop image that is pinned on top of it. Feature and application updates are out of scope.

**Goal.** When Debian ships a fix for something in an image, a machine on `stable` gets it within 48 hours
(critical) or 7 days (high), with no human in the loop unless a stage fails or a vulnerability has no fix.

## Why now

The Debian snapshot in `mkosi/mkosi.conf` (`Snapshot=`) is the only way fixes enter the image. It was set by hand and
stayed 13 days behind: Debian had a newer kernel and expat, the weekly scan (docs/SBOM.md) went red with about 200
blocking findings, and the fix was a chain of manual steps over a day: a bump pull request, reviews, the release
run, a pull request in `nyra-updates` to promote it (a production deploy, merged by a person), and a pull request
in the desktop to move its pin. Smaller frictions seen on the way:

- the weekly report counted the same advisory once for the image and once for the ISO, and about 140 kernel
  advisories blocked only because they had no score yet ("unknown blocks", docs/SBOM.md);
- `snapshot.debian.org` answers 503 when asked too often;
- re-running a publish can hit an object-lock error on an object that already exists;
- every exception had to be renewed by hand every 14 days, and an expired one fails the build, including the build of
  the very pull request that would fix the finding.

## The pipeline

Every stage already exists except the ones marked **new**. Times are UTC.

| # | Stage | What happens | Human? |
|---|---|---|---|
| 1 | **Watch** (new) | Every 6 hours, read-only: fetch the newest snapshot, verify it (below), scan the package list of the current image against it. If it fixes at least one finding of severity medium or above, or the current snapshot is 14 days old, go to 2. Otherwise stop. | no |
| 2 | **Bump PR** (new) | The bot opens a pull request that changes only the `Snapshot=` line. | no |
| 3 | **Build and tests** | `image.yml` as for any pull request. | no |
| 4 | **Merge** (new) | If the bump pull request passes the rules of "Who merges what", the bot merges it. | no |
| 5 | **Release** | The push to `main` is a release run: build, KMS signing, tests on the signed image, `publish` to the registry (`dev`). | no |
| 6 | **Record** (new) | A pull request in `nyra-updates` adds the published version and digest to `releases.json`, which is what moves `dev`. | phase 1 |
| 7 | **Soak** | The nightly Titanic run (02:17) tests `main`. A night counts for version V when it is green (all 15 tests) with V's `Snapshot=`. | no |
| 8 | **Promote** (new) | After the first green night V goes to `beta`, after the second to `stable` (the first, for a fixed critical finding). One pull request each, in `nyra-updates`, with the evidence in its body. | phase 1 |
| 9 | **Desktop** (new) | The desktop repository sees a verified new base version and opens a pin-bump pull request; its own build and tests decide. | no |
| 10 | **Rollback** | Halt, retract or revert with the channel files that exist today ("Rollback"). | see below |
| 11 | **Alert** (new) | An issue, only in the cases of "Alerting". | - |

Time from a Debian fix to `stable`: at most 6 h for the watch, about 4 h for the bump pull request and the release
run (pull request about 1 h, release run about 2 h 20 min, measured), then the nights: about 36 h for a critical fix
(one night), about 3 days for the rest (two). That meets the 48 h and 7 day rules. A critical fix that appears while a
release is running waits for it: releases are one at a time.

### 1-2. Choosing the snapshot

The watch job uses Python's standard library, `gpgv` and a committed copy of the Debian archive keyring fingerprints
(changing them is a human change). It picks the newest snapshot of `unstable` that is at least 6 hours old (the
archive and the snapshot service need a moment; a bad upload is often pulled within hours), and requires:

- `InRelease` of that snapshot verifies against the keyring, `Suite: unstable`, `Codename: sid`;
- its `Date` is later than the `Date` of the current snapshot (no replay, no downgrade) and not in the future, and the
  timestamp in the URL agrees with it;
- the diff is exactly one changed line in `mkosi/mkosi.conf`, in the form `Snapshot=YYYYMMDDTHHMMSSZ`, and a newer one.

`mkosi` then installs from that snapshot with apt, which verifies the same signatures again. Requests are few and
small (`InRelease`, the package index the scanner already reads); on 503 or a timeout the job retries with growing
pauses and, if it still fails, ends without error: the next run tries again. Being unable to reach the service is not
an incident; being behind the deadlines is (see "Alerting"). If the newest snapshot does not build (unstable can break
for a day), the pull request stays red and the next run opens a newer one. There is no bisecting.

### 3. The scan gate: what blocks

The scan today (`tools/sbom/sbom.py`) blocks on critical, high and unknown. That is right for a person who reads the
report and wrong for a robot, because most of what it reports cannot be fixed by the robot. The report gets two classes:

| Class | Meaning | Robot's answer |
|---|---|---|
| **Fixable** | the tracker lists a fixed version in `sid` that is newer than ours | the cure is a snapshot that has it: bump. This class starts the 48 h / 7 day clock. |
| **Unfixed** | open or undetermined, no fixed version | nothing the robot can do: never blocks a release, is reported, can raise an alert |

Rules:

- **What the gate blocks**: a release is not promoted to `stable` if it has a fixable finding of critical, high or
  unknown severity that is *not also in the version `stable` serves now*. Never promote a regression, never hold back
  an improvement: a release that fixes five of six findings goes out and the sixth is fixed by the next bump.
  Publishing to `dev` and `beta` is never held by the scan (testers must be able to see the fix).
- **Unscored kernel advisories.** The tracker often has no CVSS vector for kernel advisories for weeks. The score is
  taken from, in order: the CVSS vector, Debian's urgency for `sid`. Fixable and unscored counts as high (the bump
  fixes it anyway). Unfixed and unscored is **pending**: listed, never blocking, and an exception is not needed. When
  it is scored, or its fix appears, the normal rules apply. Honest cost: an unfixed advisory that is really critical
  stays below the alert line until Debian or a CVSS vector says so. We cannot fix it earlier anyway, and a person
  reads the report.
- **One count.** The summary counts an advisory once per source package, and lists in which artifacts it appears
  (image, x86_64 ISO, aarch64 ISO). Exceptions stay per artifact, as today.
- **Expired exceptions** stop counting (their finding is blocking again, as now) but never fail the build by
  themselves. Today an expired entry stops the pull request that would remove the cause.
- **Exceptions that became fixed** are removed by the bot: a pull request that deletes whole `[[mitigation]]` blocks
  the scan reports as unneeded and nothing else. Deleting an exception can only make the gate stricter, so it may merge
  by itself.
- **Renewing and adding an exception** stays a human decision with a security review, always: it accepts a risk. What
  changes is the default expiry, 30 days instead of 14 (the limit stays 90): the daily bump removes an exception the day
  Debian fixes the finding, so a long expiry cannot outlive a fix, and the chore falls from about 26 renewals a year
  per exception to 12. The reason in the entry still decides.
- `--vulnerabilities=gate` is a third mode next to `report` and `block`: it blocks exactly the first rule. Before the
  first public release the release path goes to `gate`, not to `block` (docs/SBOM.md), because `block` would stop a
  release for a finding no snapshot can cure.

## Who merges what

Branch protection and the required checks of every repository stay as they are, with one addition (below). The
bot is a GitHub App, so no pull request ever has the bot as its approver and nobody approves their own change.

| Change | Phase 1 | Why |
|---|---|---|
| Bump pull request in `nyra-base` (only `Snapshot=`, newer, verified, all required checks green) | **bot merges** | It selects data from a signed archive, the diff is one line, and the same build and tests as any change decide. A person adds nothing to that. |
| Deleting exceptions that became fixed | **bot merges** | Only makes the gate stricter. |
| Adding or renewing an exception; any change to scanner, workflows, keys, signing, `policy.json` | human | Accepts a risk or changes what the checks trust. |
| Record a release in `nyra-updates` (`releases.json`) | human, one tap | Merge deploys: CI signs the channel sheet and writes it to production. The pull request body carries the proof; the merge is one click. |
| Promote to `beta`, to `stable` | human, one tap | The same. Stable is what users run. |
| Halt (`halted: true`) | human, one tap | Same path; see phase 2. |
| Retract, revert to `previous`, change the channel sheet key | human | Moves machines that already run the version, or changes what machines trust. |
| Desktop pin bump (only the pin files, a base version published and verified) | **bot merges** after the desktop's checks | Same as the base: the pin is the verified digest, the desktop's build and tests decide. |
| arm64 `stable` promotion | human | The arm64 gate (docs/ARM64.md) is not met. |

**Phase 2** (decision for the owner, only after the pipeline has run 14 days without a false promotion): the bot also
merges, in `nyra-updates`, exactly three shapes: record a release, promote, halt. Each has a check there that
recomputes the evidence from public data and fails the pull request if the body is wrong (below). Until then the
owner's rule that automation does not merge production deploys holds, so phase 1 costs one tap per release and per
promotion; with a release only when a fix exists, that is a few taps a week.

### Credentials

One new standing secret, no more: the private key of **one GitHub App** (`nyra-bot`), installed on `nyra-base`,
`nyra-updates` and `nyra-desktop`, with `contents: write`, `pull_requests: write` and `metadata: read`, and nothing
else: no `workflows` (so a push cannot touch `.github/workflows`; GitHub refuses it), no administration, secrets,
environments or approvals. Why an App and not `GITHUB_TOKEN`: a pull request opened or merged with it does not start
workflows, so the checks would never run and a merge would not start the release run. Why not a personal token: it
carries a person's reach and does not expire by itself. The key lives in an environment `bot` (deployment branch:
`main` only) of each repository, and only the job that opens or merges the pull request reads it, minting a
one-hour token for that repository.

| Stage | Token and permissions |
|---|---|
| Watch, scan, decide | none: `contents: read`, public data only |
| Open and merge the bump pull request | App token for `nyra-base` |
| Build, sign, publish | unchanged: environments `sign` and `publish`, workload identity, nothing new |
| Record, promote, halt | App token for `nyra-updates`; the checks read `nyra-base` through its public API |
| Desktop pin | App token for `nyra-desktop`; it pulls from `nyra-updates` (public), `nyra-base` never writes there |
| Alert | the repository's own `GITHUB_TOKEN`, `issues: write` |

Every stage pulls from the one before it with public, read-only access. No repository holds a token for another one,
which is what stops one compromise from spreading.

**The one change to branch protection:** a required check `bump-scope` (a `pull_request_target` workflow that reads the
diff through the API and checks out nothing from the pull request). For a pull request whose author is the App it
requires one of the allowed shapes in the table (the `Snapshot=` line; whole deleted `[[mitigation]]` blocks; in
`nyra-updates`, one channel file or `releases.json` line; in the desktop, the pin files) and fails otherwise. For
everybody else it passes at once. Without it, a stolen App key could merge any change outside `.github/workflows`
(the signing scripts under `ci/`, for example) once the checks pass, because the repository requires no approval.
With it the key can merge nothing but a snapshot line, and the line is checked by the archive signature.

## Rollback

All of it exists: the channel files in `nyra-updates` (`halted`, `retracted`, `previous`) and the client rules in
docs/UPDATES.md.

- **A bad bump on `main`:** a revert pull request of the bump (the bot may open it; a person merges). The next
  release gets a new version; clients never go down (rule 4), so a revert is a new, older package set with a higher
  version number.
- **A bad version on `dev` or `beta`:** the soak does not promote it; the next bump replaces it.
- **A bad version on `stable`:** `halted` stops new machines from taking it at once; `retracted` lets machines that
  run it go back; `previous` is the revert. The promote job opens the halt pull request by itself when a night is
  red on `main` with the promoted version and the failing test is not an infrastructure failure (the runner was shut
  down, nothing else failed). Retraction is always a person: it moves machines.

## Alerting

Nothing is sent when nothing is wrong: no daily summary, no "all green". One status issue is edited in place (no
notification). A new issue, assigned to the owner, only for:

1. **A stage failed and the deadline is at risk:** a fixable critical finding served by `stable` for more than 36 h,
   or a high one for more than 5 days, whatever stage the fix is stuck at.
2. **A critical or high finding has no fix** (Debian urgency `high` counts), is not covered by an exception, and has
   been open 3 days. Once per advisory. The issue asks for a decision: an exception with a reason, a patch, or removal.
3. **An integrity failure of the snapshot:** a bad signature, a `Suite` or `Date` that is wrong, a `Date` that goes
   back. Immediately; the pipeline stops until a person says it may go on.
4. **An exception expires in 3 days** and its finding is still unfixed.

The issues are public: they name the stage and the counts, not what is unfixed; advisory ids stay in the scan
summary the issue links to, as they do now.

## Threat model

| Threat | Answer |
|---|---|
| Poisoned or replayed snapshot | Signature against the committed keyring, suite, monotonic `Date`, 6 hour age, apt verifies again. Debian's archive remains the root of trust, as it is for the image today (it cannot be removed). |
| Poisoned tracker or OSV data | The bump never depends on them for correctness: the 14 day backstop bumps anyway, and what is installed is always a signed snapshot. Hiding a finding can delay a bump by days, not install anything. A fake "fixed" can only cause a bump to a genuine snapshot. The scan keeps its checks for empty or truncated data. |
| Malicious pull request from the bot's token | `bump-scope`; no `workflows` permission; no approvals; no push to `main`; secrets and environments out of reach. |
| Replay or downgrade of a channel | Unchanged: signed sheet, `sequence`, version floor. A promote pull request can only raise a channel's version, and its check requires it. |
| Supply chain of the automation | Standard library and `gpgv` only; actions pinned by commit like the rest; the scripts are in the repository and reviewed; the check that governs the bot runs from `main`, never from the bot's branch. |
| Too much trust in one night | A night means all 15 tests green on a build of exactly that `Snapshot=`; a pull request run, a manual run or another branch never counts. |

## Not automated

- Keys, signing policy, the channel sheet key, the Debian keyring fingerprints, the scanner and the workflows.
- Adding or renewing an exception, and deciding what to do about a vulnerability that has no fix.
- Retraction, and revert on `stable`.
- arm64 `stable` until its gate is met.
- Application, Flatpak, and feature updates.
- Hotfixes by patching a package ourselves (`patches/`): a person decides; the pipeline carries them like any change.
- Fixing a failing Titanic test: a test that fails is a bug and the night does not count.
- Debian stable (the server edition): same stages, a separate proposal when that edition exists.

## Ordered pull requests

Each is useful alone and merges on its own. Estimates are focused work; CI (about 1 h for a pull request) and review
dominate the wall-clock time.

| # | Pull request | Gives | Estimate |
|---|---|---|---|
| 1 | Scanner: classes, `gate` mode, Debian urgency fallback, one count, expired exceptions no longer fail the build, list of unneeded exceptions | a weekly report a person can act on in minutes | 1.5 days |
| 2 | Publish is idempotent: an object that already exists with the same content is success, not an error | safe re-runs of a release | 0.5 day |
| 3 | `tools/snapshot` and `snapshot-bump.yml`, dry run: verify, choose, decide, write a summary; opens nothing | a daily answer to "are we behind?", and the integrity checks | 1.5 days |
| 4 | Alerts and the status issue (cases 1 to 4) | the owner hears about failures; the backlog is visible | 1 day |
| 5 | `nyra-bot` App (owner creates it), `bump-scope` workflow and the one protection change, the bot opens the bump pull request | the bump is automatic up to review | 1 day |
| 6 | Bot merges bump pull requests and the removal of fixed exceptions | no human for the common case | 0.5 day |
| 7 | `record-release` in `nyra-updates` (pull request with proof) and its check | `dev` moves from the publish without a manual edit | 1 day |
| 8 | Promotion: the evidence check (Titanic nights, scan class, never lower) and the beta and stable pull requests | promotion is one tap, with proof | 2 days |
| 9 | Desktop pin bump (pull from `nyra-updates`, pin files only, `bump-scope` for the desktop) | the desktop follows the base | 1 day |
| 10 | Halt pull request on a red night, one automatic re-run for an infrastructure-only failure | the failure path is automatic | 1 day |
| 11 | Phase 2: bot merges record, promote and halt in `nyra-updates` | no human at all in the normal case | 0.5 day |

About 11 working days of work, 3 weeks of calendar time with reviews, plus 14 days of phase 1 before the owner decides on
phase 2. After PR 6 the base follows Debian by itself; after PR 8 the whole path needs only taps.

## Questions for the owner

1. **Phase 2:** may the bot merge exactly three shapes in `nyra-updates` (record, promote, halt), each backed by a
   check that recomputes the proof? *Recommendation: yes, after 14 clean days of phase 1; until then taps.*
2. **One GitHub App key** as the only new standing secret, instead of a personal token or no automation of the merges?
   *Recommendation: the App, with the permissions above.*
3. **One more required check, `bump-scope`,** in the protection of `nyra-base`, `nyra-updates` and `nyra-desktop`?
   *Recommendation: yes; without it a stolen key is far more powerful than the design assumes.*
4. **Numbers:** beta after 1 green night, stable after 2 (1 for a critical fix), no gradual rollout while there are no
   outside users, the release path in `gate` mode before the first public release. *Recommendation: as written;
   revisit the nights and add a gradual rollout before the public release.*
5. **Exceptions and unscored advisories:** default expiry 30 days, and unfixed unscored advisories "pending" instead of
   blocking. *Recommendation: yes to both; the daily bump removes an exception when Debian fixes it, and a person
   still reads every unfixed critical or high.*
