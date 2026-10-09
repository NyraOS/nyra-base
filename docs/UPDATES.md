# System updates

bootc downloads and stages a new image; it does not decide which image a machine should run, refuses
nothing that is correctly signed (not even an older version) and does not react when a new version
is unhealthy (`docs/LESSONS.md`). `nyra-updated` adds those rules. It lives in [`updated/`](../updated):

| Crate | What it is |
|---|---|
| [`updated/channel-sheet`](../updated/channel-sheet) | library: verifies the signed channel sheet and picks the version for this machine |
| [`updated/daemon`](../updated/daemon) | `nyra-updated`, run by systemd: the safety rules around bootc |

CI (`.github/workflows/updated.yml`) runs `cargo fmt`, `clippy`, the unit tests and `cargo audit` on
every change under `updated/`, and the audit weekly. The VM tests are at the end of this page.

## The channel sheet

For every channel (`stable`, `beta`, `dev`) of a repository the update server publishes one small
JSON document, the same for every machine, signed with Ed25519 inside a
[DSSE](https://github.com/secure-systems-lab/dsse) envelope:

```json
{"payloadType": "application/vnd.nyra.channel-sheet.v1+json",
 "payload": "<base64 of the sheet>",
 "signatures": [{"keyid": "", "sig": "<base64 of the 64-byte Ed25519 signature>"}]}
```

The signature covers `DSSEv1 <len(type)> <type> <len(payload)> <payload>`: the exact payload bytes, so
there is no canonical-JSON problem, and a signature made with the same key for anything else is not a
valid sheet. The payload:

```json
{"schema": 1, "repository": "nyra-base", "channel": "stable",
 "sequence": 1791498540, "issued_at": 1791498540, "expires_at": 1792103340,
 "current":  {"digest": "sha256:<hex>", "version": "2026.10.3"},
 "previous": {"digest": "sha256:<hex>", "version": "2026.10.1"},
 "percent": 25, "halted": false, "retracted": ["sha256:<hex>"]}
```

| Field | Meaning |
|---|---|
| `schema` | `1`; unknown fields are refused, so a new field comes with a new schema and is never ignored in silence |
| `repository`, `channel` | a machine refuses the sheet of another channel or repository |
| `sequence` | grows with every new sheet of the channel; a machine never accepts a lower one, and an equal one only for the identical payload |
| `issued_at`, `expires_at` | Unix seconds; refused from `expires_at` on, refused if issued more than a day in the future, at most 31 days of validity |
| `current` | the newest version: manifest digest and release version (`year.month.build`, compared number by number) |
| `previous` | the last good version, for machines outside the rollout; `null` means no rollout (`percent` 100, not halted) |
| `percent` | rollout groups `0..percent-1` get `current` |
| `halted` | nobody new gets `current`; machines that run it keep it |
| `retracted` | retracted versions: only machines running one of them may go back to an older version |

The version order comes only from the signed sheet, never from tag names. A machine computes its own
rollout group, `HMAC-SHA256(install code, "nyra-rollout-group-v1\n<repository>:<channel>\n<current digest>") mod 100`,
from a random install code that never leaves it. The server cannot target a machine, and the group
changes with every release, so the same machines are not always the first.

The trusted public keys ship in the image (`/usr/lib/nyra/updates/channel-sheet.pem`); with no key
every sheet is refused. The `seed1` key of the test fixtures (`updated/channel-sheet/tests/data`) has
a private key anyone knows: `nyra-updated` refuses it as a trusted key.

## The rules

`nyra-updated check` (a timer, after `boot-complete.target`) learns what became of the last update,
fetches and verifies the sheet, and stages the version it picks, pinned by digest, without applying
it: the reboot stays the user's choice. `nyra-updated health-failed` (`OnFailure=` of the health checks)
reboots fully while a new version is on trial, so systemd-boot's boot counting can fall back
(`docs/BOOT.md`). Each rule has a unit test (`updated/daemon/src/tests.rs`):

1. One update at a time (a lock); every bootc, systemctl and curl call has a time limit and is killed
   with its children when it hangs.
2. The sheet's sequence and retracted digests are saved atomically before anything acts on the sheet.
3. A retracted digest is remembered and never a target again; an installed version retracted by any
   accepted sheet may still go back.
4. No downgrade, and no target below the image's version floor, not even a signed retraction (a leaked
   old key cannot send machines back to any image ever signed).
5. A version the machine fell back from is marked failed and never staged or offered again.
6. A retraction to the local rollback deployment uses `bootc rollback` (a switch would answer
   "No changes").
7. The image is pulled pinned by digest, and the staged digest must be the sheet's; a staged
   deployment that must not boot is never finalized (below).
8. A failed health check reboots fully: never a soft reboot, always after a soft reboot (which bypasses
   boot counting), and never on a version that is not on trial (no reboot loop).
9. The first healthy boot of a new version must have been a full boot with a boot counter, or it is
   reported as an error.
10. Nothing is done when the booted image is not from `updates.nyraos.com/<repository>`: the server is
    fixed in code, because the signature policy covers exactly that name (`docs/SIGNING.md`). An owner
    who switched to their own image keeps it, and the outcome (`ForeignImage`) is logged as a warning
    at every check, so such a machine is not silently without updates. The installer must therefore
    install with an explicit tag (`updates.nyraos.com/nyra-base:stable`): without one the image counts
    as foreign.
11. A staged version that becomes unacceptable before the reboot (retracted, failed, or below the
    version floor) is discarded the same way as in rule 7.

### Discarding a staged deployment (rules 7 and 11)

A staged deployment that becomes unacceptable before the reboot (a digest other than the sheet's,
retracted, failed, or below the version floor) is never finalized, whatever the rollback deployment
is, and the boot order is not touched. bootc keeps the staged deployment in `/run` and only swaps
its boot entries in at shutdown (`bootc-finalize-staged`). `nyra-updated` writes the digest to
`/run/nyra-updated/discarded` and removes the staged entries from the ESP at once (`esp-sync discard`);
at shutdown, before that swap, `esp-sync` (`nyra-boot-counter.service`) removes them again, in case
that failed or something was staged since. `bootc-finalize-staged` then has nothing to swap in (it
reports an error), the next boot is the running version, and no entry of the discarded version is
left for a later update. Until the reboot `nyra-updated` stages nothing else, and anything staged
by hand is discarded with it.

## In the image

| Path | What |
|---|---|
| `/usr/libexec/nyra-updated` | the binary, built on the CI tools image (Debian testing, like bootc) and stripped; `Cargo.lock` in `/usr/share/doc/nyra-updated/` |
| `/usr/lib/nyra/updates/updated.conf` | `repository`, `channel`, `version_floor`; every key required, unknown or repeated keys refused; the server is not configurable |
| `/usr/lib/nyra/updates/channel-sheet.pem` | the trusted sheet keys; **none yet**: updates are "not configured" until the real key is committed. Every sheet is refused (nothing is even fetched), and each check reports it as a warning without failing the unit, so machines are not all `degraded` for a known state. A missing or broken key file is an error. When image signing is turned on, the release build must require at least one key |
| `nyra-updated.timer` / `.service` | a check 15 minutes after boot, then every 6 hours (randomized); after `boot-complete.target` |
| `nyra-health-system.service` | a health check: the core services (D-Bus, journald, logind, udevd, networkd, resolved) are running |
| `nyra-health-.service.d/10-nyra.conf` | for every `nyra-health-*.service`: `Before=boot-complete.target systemd-user-sessions.service`, `OnFailure=nyra-updated-health-failed.service`, sandboxing |
| `nyra-updated-health-failed.service` | `nyra-updated health-failed`: the full reboot while on trial (rule 8) |
| `systemd-bless-boot.service.d/10-nyra.conf` | no blessing after a soft reboot (below) |

The image build runs `systemd-analyze verify` on these units and `nyra-updated check-config`, which
fails on an invalid configuration or on a key from the test fixtures; CI also checks that it does
fail with the `seed1` fixture key in place. `boot-complete.target` is pulled in on every boot (not
only when systemd-boot counts tries), so the health checks always run and `nyra-updated` can rely on
the target being active on a healthy boot.

**Health checks** are units named `nyra-health-*.service` that `boot-complete.target` requires
(links in `/usr/lib/systemd/system/boot-complete.target.requires/`). A failure keeps the boot from
being blessed and, while the version is on trial, reboots so systemd-boot can fall back. They finish
before `systemd-user-sessions.service`, so nobody can log in while they run and an unprivileged user
cannot make one fail (which would force reboots and mark a good version failed). A check that bootc
itself works (`bootc status`) would be valuable, but bootc needs its own boot entries for that, and the
Secure Boot test lays the ESP out by hand without them (`docs/BOOT.md`); it comes with the UKI layout.

**Soft reboots** skip the firmware, so systemd-boot does not count a try, while
`LoaderBootCountPath` still names the entry of the last full boot. `systemd-bless-boot` would then
bless an entry that did not just pass its health checks, or fail because bootc renamed it (the system
ends up `degraded`). The drop-in skips it when `SoftRebootsCount` is not 0. A health check that fails
after a soft reboot makes `nyra-updated health-failed` reboot fully, and the new version's entry,
which still has its `+3`, is counted from then on.

**Sandboxing.** `nyra-updated.service` runs bootc, which needs root, its own mount namespace (it
remounts `/sysroot` and mounts the ESP privately), the network, `/sysroot` and `/var`: it gets
`ProtectSystem=full`, `ProtectHome=tmpfs`, `PrivateTmp`, `NoNewPrivileges`, the kernel and cgroup
protections and a list of address families (`systemd-analyze security`: 6.5). The health checks and
`health-failed` only read state and ask systemd for a reboot: no network, no capabilities where
possible. The pull itself is stopped by `nyra-updated` after 2 hours; `TimeoutStartSec` is above that.

**What a machine shows.** Every check writes its outcome to the journal (an error at priority 3, a
foreign image at 4) and to `/var/lib/nyra-updated/last-check.json` (`time`, `ok`, `message`), for
Settings, which will read it through the daemon (the file is root-only, like the rest of the state).
When the state file is broken, every check fails with a message naming it, and updates stop (fail
closed: forgetting it would forget the sequence and the retractions). The repair, until Settings
offers it: move `/var/lib/nyra-updated/state.json` away; the next check starts over, and the version
floor still applies.

## Tests in a VM (`tools/vm/updates.sh`)

The `install-boot` job follows one installed VM through 16 boots and real updates. Everything the
guest trusts is made for the run: a sigstore key stands in for the keyless signer (the guest's
`/etc/containers/policy.json` is the shipped policy with that key), a channel sheet key is baked
only into the test versions, and a CA signs the certificate of a sheet server on the runner. The
guest reaches the runner as `updates.nyraos.com` (`/etc/hosts` on the test disk): the registry on
port 80 (plain HTTP, `insecure` on the test disk) and the sheet server on 443. The test versions
v0-v8 carry the version in the manifest annotation `org.opencontainers.image.version`, which is where
bootc reads it.

| Titanic | Scenario | Expected |
|---|---|---|
| T4 | the installed image, no sheet key | "updates are not configured" (`ok: false`), nothing fetched, the unit not failed |
| T4 | unsigned image from `updates.nyraos.com`, shipped policy | `bootc switch` refused |
| T4 | unsigned, and signed with another key, test policy | refused |
| — | image from another registry | accepted; `nyra-updated` reports `ForeignImage` (journal warning) |
| T4 | sheet signed with another key | refused |
| T2 | power cut while the update downloads (the registry throttled to 2 Mbit/s, the cut 4–12 s into a ~16 MiB pull, while `nyra-updated` is still activating and nothing is staged) | the old version boots, nothing staged; the next check stages it again |
| T2 | power cut after staging, before finalization | the old version boots, nothing staged; staged again |
| T2 | power cut when the new version's kernel starts | the second try boots and is blessed; the first boot of the new version counts (rule 9) |
| — | staged version retracted before the reboot, with an acceptable rollback deployment and with a failed one | not finalized: the next boot is the running version, boot order and rollback deployment unchanged, no staged entries left |
| T3 | new version whose health check fails | it reboots by itself three times, systemd-boot falls back, the version is marked failed and refused |
| T5 | captive portal answers HTML | refused (malformed sheet) |
| T5 | spoofed server (certificate not from a trusted CA) | refused (TLS) |
| T4 | older version served (downgrade), replayed older sheet | refused |
| — | soft reboot into a new version from a counted boot | `systemd-bless-boot` skipped, system `running`, the entry keeps `+3` |
| T4 | signed retraction below the version floor | refused |
| T4 | signed retraction to the local rollback deployment | `bootc rollback` (rule 6) |
| T5 | registry down | refused (connection refused), nothing staged |
| T5 | corrupted layer in the registry | refused when the layer is read, nothing staged |
| T4 | a valid layer with other content and exactly the same size served in place of the right one (`tools/vm/same-size-layer.py`) | refused: the image proxy checks each layer's digest against the signed manifest (`corrupted blob, expecting …` at `FinishPipe`), nothing staged; staged once the registry is repaired |

Not covered yet: power cuts at many random moments and during finalization, a slow (50 kbit/s) link
and a server that stalls mid-download (the 2-hour limit is unit-tested only), DNS answers for another
host, a broken kernel or initramfs (a kernel panic needs `panic=` to reboot at all), and the real
keyless signature (the `sign` job, `docs/SIGNING.md`).
