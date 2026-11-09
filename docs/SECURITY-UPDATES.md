# Automatic security updates (design)

Status: proposal, nothing here is implemented. Scope: the base image (`nyra-base`, `nyra-base-arm64`) and the
desktop image pinned on top of it. Feature and application updates are out of scope.

**Goal.** When Debian ships a fix for something in an image, a machine on `stable` gets it within 48 hours
(critical) or 7 days (high), with no human in the loop unless a stage fails or a vulnerability has no fix.

## Why now

`Snapshot=` in `mkosi/mkosi.conf` is the only way Debian fixes enter the image. It was set by hand and stayed 13 days
behind: Debian had a newer kernel and expat, the weekly scan (docs/SBOM.md) went red with about 200 blocking
findings, and the cure was a chain of manual steps over about a day: a bump pull request and its reviews, the release
run, a pull request in `nyra-updates` to promote it (a production deploy, merged by a person) and one in the desktop
to move its pin. Smaller frictions: the weekly report counted an advisory once for the image and once for the ISO and
blocked on about 140 kernel advisories that had no score yet; `snapshot.debian.org` answers 503 when asked too often;
re-running a publish can hit an object-lock error; every exception was renewed by hand every 14 days, and an expired
one fails the build, including the build of the pull request that would remove its cause.

## The pipeline

Every stage exists today except those marked **new**. Times are UTC.

| # | Stage | What happens | Human? |
|---|---|---|---|
| 1 | **Watch** (new) | Every 6 hours, read-only: fetch and verify the newest snapshot, scan the current package list against it. If it fixes a finding of medium or above, or `Snapshot=` is 14 days old, go to 2. | no |
| 2 | **Bump PR** (new) | The bot opens one pull request (one bot branch; a newer bump closes the older one) that changes only `Snapshot=`. | no |
| 3 | Build and tests | `image.yml` as for any pull request. | no |
| 4 | **Merge** (new) | The bot merges it if the rules of "Who merges what" hold. | no |
| 5 | Release | The push to `main` is a release run: build, KMS signing, tests on the signed image, `publish` (`dev`). | no |
| 6 | **Record** (new) | A pull request in `nyra-updates` adds version and digest to `releases.json`; that moves `dev`. | phase 1 |
| 7 | Soak | The nightly Titanic run tests `main` (a night counts only by the rules of "Promotion"). | no |
| 8 | **Promote** (new) | `beta` after the first counted night, `stable` after the second (the first for a critical fix). One pull request each in `nyra-updates`. | phase 1 |
| 9 | **Desktop** (new) | The desktop opens a pin-bump pull request for a verified, recorded base version. Its own channels stay human-only (below). | no |
| 10 | Rollback | Halt, retract or revert with the channel files that exist today. | see below |
| 11 | **Alert** (new) | An issue, only in the cases of "Alerting". | - |

Time from a Debian fix to `stable`: up to 6 h for the watch, about 4 h for the bump pull request (about 1 h), the merge polling delay and the
release run (about 2 h 20 min), then the nights: about 36 h for a critical fix, about 3 days otherwise. That meets
the 48 h and 7 day rules. Releases are one at a time, so a fix that appears during one waits for it.

### Choosing the snapshot (stage 1)

The watch job is Python's standard library and `gpgv`. It does all network parsing in a job without a token; the job that
holds the App token receives only a `Snapshot=` value checked against the strict pattern `YYYYMMDDTHHMMSSZ`. The keys are the Debian archive keyring of the pinned tools
image (the one `mkosi` and apt use), whose fingerprints are committed and checked; never a key taken from the snapshot
itself. Changing them is a human change. It takes the newest `unstable` snapshot that is at least 6 hours old (a bad
upload is often pulled within hours) and requires:

- `InRelease` verifies, `Suite: unstable`, `Codename: sid`;
- its `Date` is later than the current snapshot's `Date`, and `Date <= URL timestamp <= Date + 12 h`;
- the pull request diff is exactly the `Snapshot=` line (the rule of `bump-scope`, below).

The list of snapshots comes from an unauthenticated service. That is acceptable: the worst it can do is hide a newer
snapshot (the staleness alerts catch that) or offer an older one (refused by the `Date` rule). A transport error, a 503
or a truncated file means retry with growing pauses, then end the run without error. Only a signature that verifies
wrong is an integrity failure. If the newest snapshot does not build, the pull request stays red and a newer one
replaces it later; there is no bisecting.

### The scan gate (what blocks)

`tools/sbom/sbom.py` blocks on critical, high and unknown. That suits a person reading a report, not a robot, because
most findings cannot be cured by a bump. The report gets two classes, keyed by (advisory with its aliases, source
package, artifact):

| Class | Meaning | Answer |
|---|---|---|
| **Fixable** | the tracker lists a fixed version in `sid` newer than ours | bump; starts the 48 h / 7 day clock |
| **Unfixed** | open or undetermined | nothing the robot can do; reported, may raise an alert |

- **Where it is enforced.** In one place: the check that a pull request promoting a version to `stable` must pass in
  `nyra-updates`. It recomputes everything there, never trusting the pull request body. Publishing to `dev` and
  promoting to `beta` are never held by the scan, so testers see a fix at once. The release path of `image.yml`
  stays in `report` (a release is signed whatever the scan says, as today); the switch before the first public release
  (docs/SBOM.md) becomes: the promotion check, not the signing jobs, blocks.
- **What it blocks.** A fixable critical, high or unknown finding in V that is not also in the version `stable` serves
  now. Never promote a regression, never hold back an improvement.
- **Inputs.** The findings of the `stable` version come from its own SBOM inputs (the package list and Cargo.lock
  files of its release run, stored by hash and kept as long as any channel serves that version, not 90 days) scanned with today's tracker data, so both sides use the same data. The check
  fails closed when those inputs are missing, or when tracker data is unreachable, empty or truncated.
- **Missing inputs** are a human decision: a person may override the check for one promotion. The override counts only from a human
  actor, by authenticated identity (never an App, never text in the pull request body), and a promotion that used it is
  merged only by a human, phase 2 included.
- **Critical path.** One night instead of two only if the recomputed result shows the critical finding in `stable` and
  fixed in V.
- **Unscored advisories.** Kernel advisories often have no CVSS vector for weeks. Score = CVSS vector, else Debian's
  urgency for `sid`. Fixable and unscored counts as high. Unfixed and unscored is *pending*: listed with count and age
  in the status issue, never blocking, no exception needed. Honest cost: an unfixed advisory that is really critical
  stays below the alert line until Debian or a vector says so; we could not cure it earlier, and a person reads the
  report.
- **One count.** The summary counts an advisory once per source package and lists the artifacts it is in. Exceptions
  stay per artifact.
- **Expired exceptions** stop counting (their finding blocks again) but no longer fail the build by themselves.
- **Fixed exceptions** are deleted by the bot (a pull request that only deletes `[[mitigation]]` blocks the scan
  reports as unneeded). Deleting can only make the gate stricter.
- **Adding or renewing** an exception stays human, with a security review. The default expiry becomes 30 days
  (limit 90): the bot deletes an exception the day Debian fixes the finding, so a long expiry cannot outlive a fix,
  and renewals fall from about 26 to 12 a year per exception.

## Who merges what

The bot is a GitHub App, so it is never the approver of its own work. Approvals are not required in these
repositories today (docs/SIGNING.md, "Who can sign"), so what the bot may merge is limited by mechanical checks, not
by review. Anything the bot opens that is not one of the shapes below is left as a **draft** and never merges.

| Change | Phase 1 | Why |
|---|---|---|
| `nyra-base`: bump (shape B1) | **bot merges** | Data from a signed archive, one line, decided by the same build and tests as any change. |
| `nyra-base`: delete fixed exceptions (shape B2) | **bot merges** | Only stricter. |
| `nyra-desktop`: pin bump (shape D1) | **bot merges**, after the desktop's own build and test checks (now required) | Same reasoning. |
| `nyra-updates`: record, promote, halt (shapes U1 to U3) | **human**, one tap | A merge deploys: CI signs the sheet and writes it to production. The bot only opens the pull request, from its own fork. |
| Desktop channels (`beta`, `stable`): promotion | human | Until a rule exists that the desktop's pinned base is on the base's `stable` and the desktop's own SBOM passes the gate, nothing automatic promotes a desktop version. |
| New or renewed exception; scanner, workflows, keys, signing, policy | human | Accepts a risk or changes what the checks trust. |
| Retract, revert, sheet key; arm64 `stable` (gate of docs/ARM64.md not met) | human | Moves machines or changes trust. |

### The shapes (checked by `bump-scope`)

`bump-scope` is a required check in `nyra-base`, `nyra-updates` and `nyra-desktop`, a `pull_request_target`
workflow with `contents: read` and `pull-requests: read` only. It checks out nothing from the pull request, never puts
a title, body or branch name into a shell, and evaluates exactly the event's `head.sha` on `opened`, `synchronize`,
`reopened` and `edited`. The App is recognised only by the **authenticated GitHub actor**: the sender of a `push` or
`synchronize` event, `merged_by`, and the pull request's activity records, by numeric App id; never by the git author
or committer fields (anyone can write those), a name or a branch prefix. The decision sticks to the pull request:
once the App has pushed to it or sent any event on it (an edit, a reopen, a retargeted base), it stays limited to the shapes for good, and a later human `edited` or `reopened` event
with the same `head.sha` does not turn the check green. If the actor cannot be determined, the check fails. For a pull
request the App never touched, it passes. In `nyra-updates` the bot is recognised by **both** App ids (the PR App and the
fork App) and the bot account, and any pull request whose head repository is the bot fork counts as touched; the guard
does the same. The App's `pull_requests: write` could also approve; its reviews never
count, should approvals ever be required. Common rule: the files list has exactly the allowed
files, each with status `modified`, no `previous_filename`, and mode `100644` (never a symlink `120000`, a submodule
`160000` or an executable).

- **B1** (`nyra-base`): one file, `mkosi/mkosi.conf`. The head file equals the base file with only the `Snapshot=`
  line replaced by `Snapshot=YYYYMMDDTHHMMSSZ`, a later date. The whole file is compared, not a patch.
- **B2**: only `tools/sbom/mitigations.toml`, `mitigations-iso.toml` or `mitigations-iso-arm64.toml`. Both sides are
  parsed as TOML; the head entries are an exact subset of the base entries (same fields), at least one removed.
- **D1** (`nyra-desktop`): only `base/pin`, `base/pin-arm64`, `base/manifest.json` and `base/manifest-arm64.json`, the
  ones the new base version changes. The four lines of a pin keep their form and the version is higher. The digest equals
  the one recorded for that version in `releases.json` of the matching channel file (`channels/nyra-base/` for `pin`,
  `channels/nyra-base-arm64/` for `pin-arm64`) on `main`; `commit=` equals the commit of V's release run; and the
  manifest equals, byte for byte, the manifest of that release run (`manifest-arm64.json` against the arm64 release run's).
- **U1** (`nyra-updates`, record): only `channels/<repo>/releases.json`: one added key `"<version>": "sha256:..."`,
  unique (a re-run keeps its run number and may give another digest: the second never replaces the first), and
  its digest is the one `verified-pull.sh` accepts from the registry.
- **U2** (promote): only `channels/<repo>/{beta,stable}.json`: `current` becomes a higher recorded version,
  `previous` the old `current`, nothing else changes, and the proof of "Promotion" holds.
- **U3** (halt): only a channel file, only `halted` false to true.

The merge job checks the shape again, requires the required checks green, and merges with `sha` set to the head it
checked, so a later push cannot slip in.

### The release path does not trust `bump-scope` alone

`bump-scope` limits what the App may write; it cannot limit what the App's key could merge if a check were missing
or wrong. So each repository also has a fail-closed guard, and the guard runs no code the App can write: its logic is
inline in the workflow file (which the App cannot change) or read from the commit of the last published release, never
from `ci/`, `tools/` or `.github/actions` at the candidate commit. "The last published release" is the successful release run recorded in
`releases.json`, never a tag or a GitHub Release (the App could create those).

- **`nyra-base`:** before `release-sign` and `sign`, a job lists every commit since the last published release. If the
  App pushed or merged one (by the actor fields above, `merged_by` included) and the pull request is not one of the
  shapes, nothing is signed or published and an alert is raised.
- **`nyra-updates`:** the same in `channel-publish` (also on its daily scheduled run) and `registry-deploy` (which runs
  on `main` only; the job on every branch push is `registry.yml`, tests with no secrets).
- **`nyra-desktop`:** the same before its release jobs.

Residual risk, one sentence, the same in `docs/SIGNING.md`: a stolen key can block releases until a person acknowledges the commit, open drafts, and create tags, Releases or dispatches, which nothing trusts. The guard refuses any commit the App pushed or merged
outside the shapes, a human's green pull request merged by the App included, so the release stops instead of being signed.
`.github/actions/*` is not covered by the `workflows`
permission, so a change there counts as a workflow change, and the first pull request must show that GitHub refuses an
App merge that touches `.github/workflows`.

**Clearing a block.** A person adds the sha of the refused commit to `release-guard-ack`, a file in a directory the App
cannot write (a path rule of `bump-scope`: any App pull request touching it fails). The guard honours an entry only if
the commit that added it was neither pushed nor merged by any bot App (the same actor fields), so it does not rest on
that path rule alone. The guard then skips that commit,
so one bad commit does not stop every later security release. The acknowledgement is a normal reviewed change.

### Credentials

**One GitHub App per repository** (`nyra-bot-base`, `nyra-bot-updates`, `nyra-bot-desktop`), each installed on that
repository only, so a stolen key reaches one repository. That costs four keys instead of one (`nyra-updates` has two, below); each is a standing
secret in an environment `bot` of its repository (deployment branch `main` only). Why Apps and not `GITHUB_TOKEN`: a
pull request opened or merged with it starts no workflows, so checks would not run and a merge would not start the
release. Why not a personal token: it carries a person's reach and does not expire. Permissions: `contents: write`,
`pull_requests: write`, `metadata: read`; never `workflows`, administration, secrets, environments or approvals.
**`nyra-updates` is different in phase 1:** its installation gets only `pull_requests: write` and `metadata: read`.
The branch the pull request comes from lives in a fork owned by a separate bot account that is not a member of
`NyraOS`; the credential that writes the fork (a second App, installed on the fork only) is **not** installed on
`nyra-updates`. In phase 2 the `nyra-updates` installation gets `contents: write`, together with the guard.

| Stage | Token |
|---|---|
| Watch, scan, evidence, `bump-scope` | none, or `contents: read` and `pull-requests: read`; public data only |
| Open and merge the bump (`nyra-base`) | App token for `nyra-base` |
| Build, sign, publish | unchanged: environments `sign` and `publish`, workload identity; the App adds no signer path beyond "Who can sign" |
| Record, promote, halt (`nyra-updates`) | phase 1: one token that writes the fork (installed there only) and one with `pull_requests: write` on `nyra-updates`; no `contents: write` on `nyra-updates`. Phase 2: `contents: write` there too, with the guard above. |
| Desktop pin | App token for `nyra-desktop`; it reads `nyra-updates` through its public API |
| Alert | the repository's own `GITHUB_TOKEN`, `issues: write` |

Every stage reads the one before it through public APIs; no repository holds a token for another. `ci/check-credential-jobs.py`
enforces, on every pull request: the environment `bot` appears only in named open or merge jobs of workflows triggered by
`schedule` or `workflow_dispatch`, never in a `pull_request_target` or `workflow_run` workflow, never in a job with `id-token`. `nyra-updates` has no such check today and `nyra-desktop` keeps its own in
`credentials.yml`: each gets the equivalent in its own pull request.

**Branch protection changes**, all small: `bump-scope` becomes required everywhere; `nyra-updates` `main` requires a
pull request (0 approvals, like `nyra-base`), which makes phase 1 a rule instead of a habit (today the registry job runs
on any push to a branch, so a convention is not enough); `nyra-desktop` `main` requires, besides secret scan, its build and
test checks; and **every required check is pinned to the GitHub Actions app (id 15368)**, which also fixes today's
`build` and `install-boot`, which accept a status from any source. `docs/SIGNING.md` ("Who can sign") lists the App as
a principal that can get a change onto `main`, with the limits above.

## Promotion

A night counts for version V only if all hold:

- `titanic.yml`, event `schedule`, branch `main`, repository `NyraOS/nyra-base`;
- its `head_sha` is the commit of V's release run, found as the successful `image.yml` push run on `main` whose
  digest is V's entry in `releases.json` (the build number is in V's version);
- `titanic-results.json` has T1 to T15 as the gate in docs/TITANIC.md requires;
- attempt 1, or a later attempt only when every earlier failure was an infrastructure failure (below); a test
  failure in any attempt makes the night red;
- two nights are two different UTC dates.

The nightly tests a non-release build of commit C; the release run tests the signed image of the same commit. Both
must be green; the nightly alone proves less than it appears to.

**Starvation.** With up to 4 bumps a day the same commit is rarely `HEAD` on two nights. So a **candidate freeze**: while
a version waits on `beta` (lifted when its night is red or it is halted), the watch opens no non-critical bump; a critical bump may, and restarts the count for the
newer version (the older one is never promoted). Nothing else lands on `main` that changes the image without the same
hold being visible in the status issue.

**Infrastructure failure fails closed.** It is only a runner lost or shut down with no test step failed. Anything
unclear is red; disk or memory exhaustion, a hang, a timeout inside a test: red. An infrastructure-labelled night never
counts green by itself. One automatic re-run of the failed jobs is allowed; if that is also infrastructure, or two nights
running for the same version are, it counts as red: a halt pull request and an alert.

## Rollback

The channel files in `nyra-updates` and the client rules of docs/UPDATES.md exist today.

- **Bad version on `dev` or `beta`:** it is not promoted; the next bump replaces it.
- **Bad version on `stable`:** `halted` stops new machines at once; `retracted` lets machines that run it go back;
  `previous` reverts. The halt pull request is opened on a red night (not infrastructure, above) with the promoted
  version; a phase 2 bot merges a halt only when a recomputed red night proves it. Retraction is always human.
- **Bad bump on `main`:** a revert pull request (the bot may open it, a person merges). Left alone, the watch would
  bump back to the same package set within 6 hours, so a human commits a **hold** to the repository (a pause flag, or a
  minimum next snapshot) that the watch obeys; the status issue shows an active hold.
- **A revert is a new version, and clients refuse going down** (rule 4, docs/UPDATES.md). Across a month boundary the
  version (year.month.build) is lower, so clients would refuse it. The answer is then a forward fix, never a revert.

## Alerting

Nothing is sent when nothing is wrong: no daily summary. One status issue is edited in place (no notification) with the
current snapshot, version per channel, active hold, and pending-unscored count and oldest age. A new issue, assigned to
the owner, only for:

1. **A deadline at risk:** a fixable critical finding served by `stable` for more than 36 h, or a high one for more than
   5 days, at whatever stage the fix is stuck. These checks keep running while the pipeline is stopped.
2. **A critical or high finding with no fix** (Debian urgency `high` counts), not under an exception, open 3 days.
   Once per advisory; it asks for a decision: an exception with a reason, a patch, or removal.
3. **An integrity failure of a snapshot** (a verified-wrong signature, wrong `Suite`, a `Date` that goes back). At once;
   the bump stops until a person releases it.
4. **An exception expires in 3 days** and the finding is still unfixed.
5. **The watch is stale:** no verified run succeeded for 48 h, or `Snapshot=` is older than 16 days. This and the
   deadline checks run in a workflow of their own, not in the watch, so a broken watch cannot hide itself.
6. **Guard or infrastructure red** (above): a guard that stopped a release, a halt pull request.

Issues are public. They carry stage, ids and counts, never tracker or OSV description text; what is unfixed is in the
scan summary they link to, as now.

## Threat model

| Threat | Answer |
|---|---|
| Poisoned or replayed snapshot | Signature against the pinned keyring, suite, `Date` rules, 6 hour age, apt verifies again. Debian's archive stays the root of trust, as for the image today. |
| Poisoned tracker or OSV data | A bump never depends on it for correctness (the 14 day backstop bumps anyway; installed content is always a signed snapshot). Hiding a finding delays a fix by days and the promotion check fails closed on empty or truncated data; a fake "fixed" causes only a bump to a genuine snapshot. |
| Malicious pull request from the bot's token | `bump-scope` (authenticated actor: sender, `merged_by`, activity records), the release-path guard, no `workflows` permission, no approvals, no push to `main`, no fork write in `nyra-updates` phase 1, one App per repository. Residual: "The release path". |
| Replay or downgrade of a channel | Unchanged: signed sheet, `sequence`, version floor. U2 only raises. |
| Supply chain of the automation | Standard library and `gpgv`; actions pinned by commit; checks run from `main`, never from the bot's branch; Actions-pinned required checks. |
| Trust in one night | The rules of "Promotion". |

## Not automated

- Keys, signing policy, the sheet key, the keyring, the scanner and the workflows.
- Adding or renewing an exception; deciding about a vulnerability with no fix.
- Retraction and revert on `stable`; arm64 `stable` until its gate is met; any `nyra-updates` merge in phase 1.
- Promotion of desktop versions to `beta` and `stable`, until the rule of "Who merges what" exists.
- Application, Flatpak and feature updates; patching a package ourselves (carried like any change).
- Fixing a failing Titanic test: a test that fails is a bug, and the night does not count.
- The server edition (Debian stable): a separate proposal.

## Ordered pull requests

Each is useful alone. Estimates are focused work; CI (about 1 h per pull request) and review dominate the clock.

| # | Pull request | Gives | Estimate |
|---|---|---|---|
| 1 | Scanner: classes, one count, urgency fallback, expired exceptions do not fail the build, unneeded-exception list, recompute-from-inputs mode | a report a person acts on in minutes | 2 days |
| 2 | Publish is idempotent (an identical existing object is success) | safe re-runs | 0.5 day |
| 3 | Required checks pinned to Actions; `nyra-updates` requires pull requests; desktop requires build and test (owner changes settings) | no hole before a bot exists | 0.5 day |
| 4 | `tools/snapshot` and `snapshot-bump.yml`, dry run: verify, choose, decide, summary | a daily answer to "are we behind", and the integrity checks | 2 days |
| 5 | Alerts and the status issue (cases 1 to 6, hold flag) | the owner hears about failures | 1 day |
| 6 | App for `nyra-base`, `bump-scope` (B1, B2), `check-credential-jobs.py` rules, the release-path guard and `release-guard-ack`, SIGNING.md; the bot opens the bump pull request | automatic up to review | 3.5 days |
| 7 | Bot merges B1 and B2 | no human in the common case | 0.5 day |
| 8 | `nyra-updates`: the two Apps and the fork, fork pull requests, U1, `bump-scope`, record-release, a credential-job check like the base's | `dev` moves without a manual edit; phase 1 enforced | 3 days |
| 9 | Promotion: evidence check, candidate freeze, infrastructure rule, U2, the one re-run | promotion is one tap, with proof | 3 days |
| 10 | Desktop: App, D1, `bump-scope`, guard, the bot-environment rules in its `credentials.yml`; follows `dev` of the base | the desktop follows the base | 2 days |
| 11 | Halt (U3) and its alert | the failure path is automatic | 1 day |
| 12 | Phase 2: `contents: write` and merges for U1 to U3, with the `nyra-updates` guard | no human at all | 1 day |

About 20 working days, about 5 to 6 weeks of calendar time, plus 14 days of phase 1 before the owner decides on phase 2.
After 7 the base follows Debian by itself; after 9 the whole path needs only taps.

## Questions for the owner

1. **Phase 2:** may the bot merge record, promote and halt in `nyra-updates`, given that phase 1 uses fork pull
   requests, the repository requires pull requests, and the guard of "The release path" exists? *Recommendation: yes,
   after 14 clean days; not before.*
2. **One GitHub App per repository** (four keys, each a standing secret: base, desktop, and two for `nyra-updates`, one
   for the fork and one for its pull requests) rather than one shared key or a personal token? *Recommendation: yes;
   the extra keys buy that a stolen key reaches one repository, and none can write `nyra-updates` in phase 1.*
3. **Branch protection changes** of "Credentials" (`bump-scope` required, Actions-pinned checks, required pull
   requests in `nyra-updates`, desktop build and test required)? *Recommendation: yes, all of them, before any bot exists.*
4. **Numbers:** beta after 1 counted night, stable after 2 (1 for a critical fix), a candidate freeze, no gradual rollout
   while there are no outside users. *Recommendation: as written; add a gradual rollout before the public release.*
5. **Exceptions and unscored advisories:** default expiry 30 days; unfixed unscored advisories "pending". *Recommendation:
   yes to both.*
