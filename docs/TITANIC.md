# The Titanic battery

Tests that try to break the base: an update, a power cut, a bad network or an attacked boot must
never leave a machine that does not start. Every test has a scenario, an expected result, saved logs
and one result: `pass`, `partial`, `fail` or `not-implemented`.

## When it runs

- **Every night** (02:17 UTC) and by hand (`gh workflow run titanic.yml`), from
  [`.github/workflows/titanic.yml`](../.github/workflows/titanic.yml). Not on pull requests: they run
  the image workflow's own tests, and the pull request check validates `titanic.yml` with actionlint
  and runs the offline self-test of the results script.
- `titanic.yml` calls [`image.yml`](../.github/workflows/image.yml) unchanged: the image is built
  once, then its `install-boot` job runs every boot, update and security test on it. A nightly run
  builds with the caches; a manual run on `main` builds without caches, like a release, but is never signed, and it never
  delays or replaces a release build of `image.yml` (its own concurrency group).
- Then the `power-cuts` job installs the same image again and cuts the power at random moments of an
  update (below), and the `results` job writes `titanic-results.json`.

## The tests

| # | What we try to break | Covered by | Result today |
|---|---|---|---|
| T1 | Immutability | `/usr` read-only (first boot of `install-boot`), signature policy (`tools/signing/test-policy.sh`), refused UKIs (`tools/vm/secure-boot.sh`) | partial: a modified composefs object on disk is not tested yet |
| T2 | Power cuts | `tools/titanic/power-cuts.sh` (random moments), `tools/vm/updates.sh` (`nyra-updated` after cuts at fixed moments) | full |
| T3 | Broken version | `tools/vm/boot-counting.sh`, `tools/vm/updates.sh` (failed health check: back within 3 boots, not offered again), `tools/vm/soft-reboot-network.sh` (the network after every soft reboot and full boot of an update, 20 rounds a night) | partial: kernel panic, initramfs without the disk driver, no graphical session, dead network not tested yet |
| T4 | Signatures and versions | `tools/signing/test-policy.sh`, `tools/vm/secure-boot.sh`, `tools/vm/updates.sh` | full |
| T5 | Hostile network | `tools/vm/updates.sh` (registry down, corrupted layer, captive portal, spoofed server) | partial: a 50 kbit/s link, a server that stalls mid-download, spoofed DNS answers not tested yet |
| T6 | Full disk | none | not implemented |
| T7 | Attacked boot | `tools/vm/boot-protection.sh`, `tools/vm/secure-boot.sh` | full |
| T8 | Configuration broken by the user | none: needs the system settings reset | not implemented |
| T9 | Wrong clock (1970, 2099) | none | not implemented |
| T10 | Disk encryption | none: encryption does not exist yet | not implemented |
| T11 | Version jumps and channels | none: needs published versions and channels | not implemented |
| T12 | Hostile root (`rm -rf /`, `apt`, unsigned modules) | none (a read-only `/usr` is checked under T1) | not implemented |
| T13 | Extreme load during an update | none | not implemented |
| T14 | Removable media pulled out | none: needs removable media support | not implemented |
| T15 | Secure defaults | `tools/vm/security-defaults.sh`, `tools/vm/secure-boot.sh` (after installation) | partial: not checked again after an update yet |

A test passes only if every step that runs it succeeded; a test that covers only part of its
scenarios gives `partial` at best. A step that failed, was skipped or no longer exists fails the
test. The mapping from workflow steps to tests is in
[`tools/titanic/results.py`](../tools/titanic/results.py): renaming a step in `image.yml` means
renaming it there too.

A test that fails sometimes is a bug, never something to run again until it passes.

## Power cuts at random moments

[`tools/titanic/power-cuts.sh`](../tools/titanic/power-cuts.sh) runs 20 rounds a night. Each round
starts from a fresh copy of the installed disk, updates it with `bootc switch` to a test version of
the image served on the runner, and kills QEMU a random time after the start of one phase:

| Phase | The cut comes | Window |
|---|---|---|
| download | during the pull, with the registry throttled to 2 Mbit/s | 0-60 s |
| staging | during the switch at full speed (pull, deployment, staged boot entries) | 0-3 s |
| finalize | after `systemctl reboot`, while the staged entries are swapped in | 0-2 s |
| firstboot | after QEMU starts the first boot of the new version | 0-30 s |

The windows follow what the phases take on the CI runner (the switch at full speed about 3 s, the
shutdown with the swap about 2 s); wider ones put almost every cut after the phase. A cut that lands after its phase (the switch already done, the next boot already started) is a
moment too, and the log says where it landed. After the cut the machine must boot to a running
system on the old or the new version, and the update must then complete: switched again if the old
version booted, one reboot, the new version running. The phases take turns; the moments come from a
seed printed in the log, in the step summary and in `titanic-results.json`. To run the same moments
again, run the script with that seed (`tools/titanic/power-cuts.sh ... CUTS SEED`, see its header).

These rounds use `bootc` directly, without `nyra-updated`; that `nyra-updated` stages the update
again by itself after a cut is proven by `tools/vm/updates.sh`.

## Results

The `titanic-results` artifact holds `titanic-results.json`:

```json
{
  "schema": 1,
  "date": "2026-10-10",
  "commit": "<sha>",
  "run_url": "https://github.com/NyraOS/nyra-base/actions/runs/<id>",
  "seed": 12345,
  "tests": {
    "T1": { "name": "Immutability", "result": "partial", "note": "...", "run_url": "..." }
  }
}
```

`result` is `pass`, `partial`, `fail` or `not-implemented`. The step summary shows the same table.
The workflow only publishes the file as an artifact; it has no token for anything outside this
repository. The serial console logs are the artifacts `install-boot-serial-log` and
`titanic-power-cuts-serial-log`.
