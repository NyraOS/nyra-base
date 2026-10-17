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
it: the reboot stays the user's choice. Right before it stages (`bootc switch`) it makes a copy of
`/etc` (`/usr/lib/nyra/etc-copy update`, docs/BOOT.md, "Restore earlier settings"); a copy that fails
is logged as a warning and does not hold the update back (`tools/vm/updates.sh`, boot 5).
`nyra-updated health-failed` (`OnFailure=` of the health checks)
reboots fully while a new version is on trial, so systemd-boot's boot counting can fall back
(`docs/BOOT.md`); otherwise the system stays up and says how to reset the settings (below). Each
rule has a unit test (`updated/daemon/src/tests.rs`):

1. One update at a time (a lock, which `health-failed` takes too before it touches the state); every
   bootc, systemctl and curl call has a time limit and is killed with its children when it hangs. `bootc switch` and `bootc rollback` are followed by `sync`:
   bootc leaves part of what it writes on the ESP in memory, and a power cut then can damage the ESP
   (FAT has no journal; `patches/upstream/bootc-finalize-entries-swap.md`). A download (the sheet or
   the version) that fails while the machine has no network is reported as that, a warning (below),
   unless what failed is a refusal (a signature, a digest, a certificate).
2. The sheet's sequence and retracted digests are saved atomically before anything acts on the sheet.
3. A retracted digest is remembered and never a target again; an installed version retracted by any
   accepted sheet may still go back.
4. No downgrade, and no target below the image's version floor, not even a signed retraction (a leaked
   old key cannot send machines back to any image ever signed).
5. A version the machine fell back from is marked failed and never staged or offered again.
6. A retraction to the local rollback deployment uses `bootc rollback` (a switch would answer
   "No changes"), once: `bootc rollback` swaps the boot order every time it runs, so when `bootc status`
   already reports the rollback deployment as the next boot (`rollbackQueued`), a check before the
   reboot runs nothing (`WaitingForReboot`), as for a rollback the user queued. Not for a version
   forgiven under rule 12: that one is staged afresh, as there.
7. The image is pulled pinned by digest, and the staged digest must be the sheet's; a staged
   deployment that must not boot is never finalized (below).
8. A failed health check reboots fully: never a soft reboot, always after a soft reboot (which bypasses
   boot counting), and never on a version that is not on trial (no reboot loop).
9. The first healthy boot of a new version must have been a full boot with a boot counter, or it is
   reported as an error.
10. Nothing is done when the booted image is not from `updates.nyraos.com`: the server is fixed in
    code, because the signature policy covers exactly that name (`docs/SIGNING.md`). Any repository
    there is ours, so a version that moves its updates to another repository (`repository` in its
    configuration) keeps getting them from there. An owner who switched to their own image keeps it,
    and the outcome (`ForeignImage`) is logged as a warning at every check, so such a machine is not
    silently without updates. The installer must therefore install with an explicit tag
    (`updates.nyraos.com/nyra-base:stable`): without one the image counts as foreign.
11. A staged version that becomes unacceptable before the reboot (retracted, failed, or below the
    version floor; a version that bootc does not report, or that does not parse, counts as below it)
    is discarded the same way as in rule 7. A rollback queued for the next boot
    (`rollbackQueued`, by the user or by rule 6) to such a version is undone with another
    `bootc rollback` (`RollbackUndone`), so it never boots. After a fallback bootc still reports the
    failed version as the next boot (`docs/LESSONS.md`); this sets that order right too.
12. A version is marked failed only when the version the machine fell back to passes its health
    checks, or when the machine falls back from it a second time (below, "The version or the
    settings").
13. A version the machine went back from on purpose (`bootc rollback` by the user, later "go back to
    the previous version" in Settings, or by root) is not staged again (`HeldBack`): the machine
    stays where the user put it until the sheet offers another version, or the running version is
    retracted. Every check says so as a warning, in words: the machine runs a version without the
    latest fixes. A newer version that is neither failed, retracted nor forgiven becomes the rollback
    deployment only that way.
14. The channel is the one chosen on the machine (`nyra-updated set-channel`), or else the image's.
    Right after a change of channel the new channel's version may be older than the running one: the
    machine goes to it, once, but only with a sheet issued after the change, and never to a version
    rules 3-5 refuse (below, "Channels"). It is staged afresh, never reached by `bootc rollback`.
    Within a channel an older version stays refused (rule 4).

**Going back by hand.** The version Settings will offer to go back to (`offered_rollback`) is the
rollback deployment, unless it is retracted, failed, below the version floor, forgiven, or already
the next boot (`rollbackQueued`: a rollback already queued, or the version the machine fell back
from, which bootc still reports first). After the reboot the version left is held back (rule 13);
going forward again is another `bootc rollback`, and a check before that reboot waits for it.

When the running version is retracted and the version the sheet sends it to is refused (retracted,
failed, below the floor), the machine stays on the retracted version until a sheet offers another
one, and every check says so, as an error: "the running version … was retracted and this check could
not move the machine off it: …", followed by the reason. For example, the target of a retraction that
fails a second time (rule 12). The same when the download of that version fails, without a network
too: the next check tries again, and until then the report says which version the machine runs.

`bootc rollback` boots the rollback deployment with the `/etc` it kept from its time: passwords, SSH
keys, accounts and network settings changed since come back. When Settings offers "go back to the
previous version", it must warn about that.

### Channels (rule 14)

The image says which channel a new installation follows (`channel` in `updated.conf`, always
`stable`: the image build fails otherwise). The same signed image is promoted from one channel to
the next (`dev`, `beta`, `stable`), so the image does not decide which channel a machine is on: root can choose with `nyra-updated set-channel NAME`
(Settings will offer it later, to an administrator with a password). The choice is kept in the
state (`channel` in `/var/lib/nyra-updated/state.json`) and wins over the image's: it stays after a
rollback to an older version and after "Reset settings", which leaves `/var` alone. An unknown channel
is refused, by `set-channel` and in the state; a sheet of another channel or repository is refused
(it is signed for its own). The sequence is kept per repository and channel. A `nyra-updated` from
before the choice existed (an older version booted after a rollback) follows the image's channel and
deletes the choice the first time it saves the state; the machine then follows the image's channel
again, without a change of channel being counted (nothing records which channel it followed).

Every check notes the channel it follows (`following`). When that changes (a choice, or an image
with another default on a machine without one), the check records when (`channel_changed`: the
time of the check, but never before the newest sequence accepted so far, which is the time a sheet
was issued, so a clock that is behind cannot let an older sheet through). From then on the machine
follows the new channel's sheet like any other, with one exception: when the version that sheet
gives it is older than the running one (`beta` to `stable`, say), it goes there anyway. It is staged
like any update: merged with today's settings, pending, on trial with three tries. Never by
`bootc rollback`, even when that version is the local rollback deployment (the usual case: back to
the channel the machine came from): that deployment kept the `/etc` of its time (bootc keeps one per
deployment), so old passwords, accounts, firewall rules and network settings would come back. The
rollback deployment is deleted first (as in rule 12). The conditions:

- the sheet was issued after the change (`issued_at` at or after `channel_changed`). A sheet from
  before, an old one or a replayed one, does nothing (`WaitingForSheet`, not an error): the machine
  waits for the next sheet, which the server signs at least daily. A replayed sheet with a lower
  sequence is refused anyway (rule 2);
- the version passes rules 3-5: not retracted, not failed, not below the version floor;
- once: as soon as it is staged, or as soon as the new channel's sheet asks for no older version, the
  change is over, and an older version is refused again (rule 4). Until the reboot, a check whose
  sheet still gives the staged version waits for it (`WaitingForReboot`), as for any update.

Going back to the first channel before the reboot does not undo a version already staged: it boots,
and the next check on the first channel moves the machine up again (a newer version, staged as
usual).

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
| `/usr/libexec/nyra-updated` | the binary, built on the CI tools image (Debian testing, like bootc) without network, from crates checked against `Cargo.lock` (not from cargo's cache or the registry index), and stripped; `Cargo.lock` in `/usr/share/doc/nyra-updated/` |
| `/usr/lib/nyra/updates/updated.conf` | `repository`, `channel` (the default; a machine's own choice wins, rule 14), `version_floor`; every key required, unknown or repeated keys refused; the server is not configurable. Optional `stage_timeout_seconds`: shortens the 2-hour limit of a pull (never longer); only the test versions set it (90 s) |
| `/usr/lib/nyra/updates/channel-sheet.pem` | the trusted sheet keys; **none yet**: updates are "not configured" until the real key is committed. Every sheet is refused (nothing is even fetched), and each check reports it as a warning without failing the unit, so machines are not all `degraded` for a known state. The 14-day rule (below, "Updates that stop") does not make it an error: nothing is held up, there is nothing to update from. A missing or broken key file is an error. When image signing is turned on, the release build must require at least one key |
| `nyra-updated.timer` / `.service` | a check 15 minutes after boot, then every 6 hours (randomized); after `boot-complete.target`; only with the ESP checked and mounted at `/boot` (`RequiresMountsFor=`, docs/BOOT.md, "Mounts from /etc/fstab") |
| `nyra-health-system.service` | a health check: the core services (D-Bus, journald, logind, udevd, networkd, resolved) are running and AppArmor's profiles are loaded (`apparmor.service` active); the list is in `/usr/lib/nyra/health/system` |
| `nyra-health-bootc.service` | a health check: `bootc status` reports the booted image, so this version can still update itself |
| `nyra-health-.service.d/10-nyra.conf` | for every `nyra-health-*.service`: `Before=boot-complete.target systemd-user-sessions.service`, `OnFailure=nyra-updated-health-failed.service`, sandboxing |
| `nyra-updated-health-failed.service` | `nyra-updated health-failed`: the full reboot while on trial (rule 8); off trial, a version fallen back from forgiven once (rule 12), and the notice. Off trial it takes the check's lock: if a check holds it, the version is not forgiven (the prudent side) and the notice is still shown. `TimeoutStartSec=5min`, above its slowest path (the boot state, `bootc status` and the notice, up to 60 s each), so systemd does not stop it before the notice |
| `/usr/lib/nyra/health/notice` | the notice on the login console (`/run/issue.d`) and after a login (`/run/motd.d`): which services did not start (plain characters of their names only: agetty reads `\` escapes), and how to reset the settings |
| `systemd-bless-boot.service.d/10-nyra.conf` | no blessing after a soft reboot (below) |

The image build runs `systemd-analyze verify` on these units and `nyra-updated check-config`, which
fails on an invalid configuration or on a key from the test fixtures; CI also checks that it does
fail with the `seed1` fixture key in place. `boot-complete.target` is pulled in on every boot (not
only when systemd-boot counts tries), so the health checks always run and `nyra-updated` can rely on
the target being active on a healthy boot.

**The version.** An image's release version (`year.month.build`) is the year and month of its Debian
snapshot (`mkosi/mkosi.conf`) and the image workflow's run number, which only grows. The build puts
it in the manifest annotation `org.opencontainers.image.version`, where bootc reads it, and in the
config label of the same name; the test versions are built the same way (`podman build --annotation`,
`tools/vm/updates.sh` and `channels.sh`). bootc reports no version for an image without that
annotation, and `nyra-updated` cannot update from such a version and treats such a staged or rollback
deployment as below the version floor (rule 11). So install-boot checks that `bootc status` reports
the installed image's version, and the update test that it reports a staged one's.

**Health checks** are units named `nyra-health-*.service` that `boot-complete.target` requires
(links in `/usr/lib/systemd/system/boot-complete.target.requires/`). A failure keeps the boot from
being blessed and, while the version is on trial, reboots so systemd-boot can fall back. They finish
before `systemd-user-sessions.service`, so nobody can log in while they run and an unprivileged user
cannot make one fail (which would force reboots and mark a good version failed).

**The version or the settings.** A health check can fail because of the machine's own settings in
`/etc` (a deleted system account, a masked service, a mount in `/etc/fstab` that `apparmor.service`
needs), not because of the version. An update is only staged on a healthy boot, but settings changed
afterwards show at the next boot, which is the new version's first. That version then fails its three
tries and systemd-boot falls back. Both versions share those settings (bootc merges `/etc` into the
new version), so the older one fails its health checks too. It is not on trial and stays up, and
`health-failed` then:

- forgives the version fallen back from, once, instead of letting the next check mark it failed
  (rule 12). It checks with `bootc status` that the machine did fall back from the pending version
  (it is the rollback deployment, not the booted one), as the check does; a version only staged, or
  booted without a boot counter (rule 9), is left for the check. Once the settings are repaired and
  a boot is healthy, the version is offered again. Its deployment, the
  rollback one by then, kept the `/etc` it failed with: bootc keeps one `/etc` per deployment, and
  the repair only reached the running one. So that deployment is deleted (`bootc delete-deployment`)
  and the version is staged afresh like any update: merged with today's settings, pending, three
  tries. If it fails again, it is marked failed: at once on a healthy machine, and after the next
  repair if the older version fails again too (it was forgiven already, `forgiven` in the state).
  Once it boots healthy it is no longer forgiven. `forgiven` holds one version: if another version
  is forgiven in between and the first one comes back, it can be forgiven once more, at the cost of
  another three boots. A set would close that, but an older `nyra-updated` (booted after a rollback)
  must still read the state file, and it would refuse a field whose type changed.
  The same holds when the version comes back as the target of a retraction (the version fallen back
  to was retracted): bootc does not see boot counting and still reports the deployment fallen back
  from as the next boot (`rollbackQueued`), so rule 6 would wait for a reboot that boots the
  retracted version again;
- runs `/usr/lib/nyra/health/notice`. It names the core services that did not start (or the failed
  health checks) and says to restart and choose "Nyra OS Reset settings" in the boot menu, which
  keeps the user accounts, passwords and `/home` (`docs/BOOT.md`). The text is shown on the login
  console (agetty reads `/run/issue.d`, and is asked to show it again) and after a login (pam_motd
  reads `/run/motd.d`). It goes with the boot.

Any failed health check on a boot that is not on trial shows the notice, with or without an update:
a version that is not on trial passed its checks before, so what changed is the machine. The cost of
not knowing at once: the new version's three tries before the fallback.

A broken kernel or initramfs never reaches the health checks: the sealed command line has `panic=10`
(`/usr/lib/bootc/kargs.d/10-nyra-panic.toml`), so a kernel panic reboots instead of halting, and the
version uses up its tries like any unhealthy one.

**Soft reboots** skip the firmware, so systemd-boot does not count a try, while
`LoaderBootCountPath` still names the entry of the last full boot. `systemd-bless-boot` would then
bless an entry that did not just pass its health checks, or fail because bootc renamed it (the system
ends up `degraded`). The drop-in skips it when `SoftRebootsCount` is not 0. A health check that fails
after a soft reboot makes `nyra-updated health-failed` reboot fully, and the new version's entry,
which still has its `+3`, is counted from then on.

**Sandboxing.** `nyra-updated.service` runs bootc, which needs root, its own mount namespace (it
remounts `/sysroot` and the read-only ESP read-write there; `esp-sync discard` does the same through
`esp-writable`), the network, `/sysroot` and `/var`: it gets
`ProtectSystem=full`, `ProtectHome=tmpfs`, `PrivateTmp`, `NoNewPrivileges`, the kernel and cgroup
protections and a list of address families (`systemd-analyze security`: 6.5). The health checks and
`health-failed` only read state and ask systemd for a reboot: no network, no capabilities where
possible. The pull itself is stopped by `nyra-updated` after 2 hours; `TimeoutStartSec` is above that.

**What a machine shows.** Every check writes its outcome to the journal (an error at priority 3, a
foreign image at 4) and to `/var/lib/nyra-updated/last-check.json` (`time`, `ok`, `message`), for
Settings, which will read it through the daemon (the file is root-only, like the rest of the state).
**Without a network** (a laptop offline, a link lost in the middle of a pull): when the download of
the sheet or of the version fails and systemd-networkd reports the machine `offline` (its
`OnlineState`), the check says "no network connection (…): the running version stays, the next check
tries again", as a warning (`ok: false`), and the unit does not fail: a check without a network
does not make the machine `degraded`. Nothing is marked failed, and the next check (the timer, every
6 hours) stages the update. Only the machine's own link state counts: a server or a network that
stops answering while the link is up is still an error.
When the state file is broken, every check fails with a message naming it, and updates stop (fail
closed: forgetting it would forget the sequence and the retractions). The repair, until Settings
offers it: move `/var/lib/nyra-updated/state.json` away; the next check starts over, and the version
floor still applies. A state lost after a fallback does not know the version the machine fell back
from: bootc still reports it as the next boot (`rollbackQueued`), so every check answers
`WaitingForReboot` for it until the sheet offers another version. That is misleading, not unsafe: a
reboot starts the running version again, because the entry of the version fallen back from has no
tries left.

**Updates that stop.** `last-check.json` also keeps `last_success`, the time of the last successful
check (until one succeeds, of the first check). When a check fails 14 days or more after it, whatever
the cause (no network, a server that does not answer, a refused sheet), its message starts with "no
successful check for N days:" and it is an error: the unit fails and the machine is `degraded`. An
image without a sheet key ("not configured") is the exception: it stays a warning and counts as a
success here, because no update is held up. Someone who controls the
machine's link could otherwise keep it on an old version with only warnings to show. 14 days: a
laptop offline for a holiday is not flagged, and the server signs the sheet at least daily. A time
in the future (a clock that was ahead) counts as now. An older `nyra-updated` (after a rollback)
writes the file without `last_success`; the count then starts again.

The offline detection reads systemd-networkd's `OnlineState`. A link that networkd does not manage
(Wi-Fi through NetworkManager or iwd, later) is not seen: a download that fails on it is reported as
an error, the prudent side, until the detection covers it.

## Tests in a VM (`tools/vm/updates.sh`)

The `install-boot` job follows one installed VM through 40 boots and real updates. Everything the
guest trusts is made for the run: a sigstore key stands in for the keyless signer (the guest's
`/etc/containers/policy.json` is the shipped policy with that key), a channel sheet key is baked
only into the test versions, and a CA signs the certificate of a sheet server on the runner. The
guest reaches the runner as `updates.nyraos.com` (`/etc/hosts` on the test disk): the registry on
port 80 (plain HTTP, `insecure` on the test disk) and the sheet server on 443. The test versions
v0-v17 carry the version in the manifest annotation `org.opencontainers.image.version`, which is where
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
| T2 | power cut after staging, before finalization, then an update to another version | only the new version's entry and the running one are staged (the stale ones are removed at boot); the new version boots, two boot entries |
| T2 | power cut when the new version's kernel starts | the second try boots and is blessed; the first boot of the new version counts (rule 9) |
| — | staged version retracted before the reboot, with an acceptable rollback deployment and with a failed one | not finalized: the next boot is the running version, boot order and rollback deployment unchanged, no staged entries left |
| T3 | new version whose health check fails | it reboots by itself three times, systemd-boot falls back, the version is marked failed; bootc, which still has it first, gets the order set right (`RollbackUndone`, rule 11); the version is refused |
| T5 | captive portal answers HTML | refused (malformed sheet) |
| T5 | spoofed server (certificate not from a trusted CA) | refused (TLS) |
| T4 | older version served (downgrade), replayed older sheet | refused |
| — | soft reboot into a new version from a counted boot | `systemd-bless-boot` skipped, system `running`, the entry keeps `+3` |
| T4 | signed retraction below the version floor | refused |
| T4 | signed retraction to the local rollback deployment, then a second check before the reboot | `bootc rollback` once (rule 6): the second check leaves the order as it is, and the rollback deployment boots |
| T5 | registry down | refused (connection refused), nothing staged |
| T5 | corrupted layer in the registry | refused when the layer is read, nothing staged |
| T3 | a good version, the settings broken after it was staged (`systemd-resolved` masked) | it fails its health check three times and systemd-boot falls back; the older version fails it too and stays up: the new version is not marked failed, the console and the login message say to reset the settings. Settings repaired: the version is offered again, its old deployment (with the old `/etc`) deleted, staged afresh; it boots counted and is blessed |
| T3 | new version whose kernel finds no usable initramfs | it panics and reboots by itself (`panic=10`) three times, systemd-boot falls back, the version is marked failed, bootc's order set right, and the version refused |
| T5 | DNS answer for another host (a certificate from a trusted CA, for another name) | refused (TLS name check), nothing staged |
| T5 | a 50 kbit/s link | the pull is stopped at the time limit, nothing staged; staged later on a normal link |
| T5 | the registry stops answering in the middle of a pull | the pull is stopped at the time limit, nothing staged; staged once the registry answers |
| T2 | power cuts at random moments while `nyra-updated` pulls and stages (5 rounds, seed printed) | the running version comes back every time; the update is staged in the end |
| T15 | the secure defaults after these updates (`tools/vm/security-defaults.sh` on the updated disk) | as after the installation |
| T9 | the hardware clock in 2099 and in 1970 (systemd sets both to its build time at boot, before the real time), and in 2035 (kept, ahead, outside the validity of every certificate) | chronyd corrects the clock through NTS by itself (docs/DEFAULTS.md, "Time"), the update is staged or the system is up to date; chronyd's memory, context switches and CPU time are printed |
| T9 | the hardware clock in 2035 and the NTS servers' names pointing to the runner: an untrusted certificate on the NTS-KE port, an NTP server that answers with a time in 2001 | the clock stays in 2035, chronyd sends not one NTP request (the server counts only the test's own probe, which shows UDP 123 reaches it); the sheet server's certificate refused (expired), nothing staged; unsigned and wrongly signed images refused; with the real servers back, the clock is corrected and the system is up to date |
| T4 | a valid layer with other content and exactly the same size served in place of the right one (`tools/vm/same-size-layer.py`) | refused: the image proxy checks each layer's digest against the signed manifest (`corrupted blob, expecting …` at `FinishPipe`), nothing staged; staged once the registry is repaired |
| T3 | a retraction to an older version that is not a local deployment, the settings broken after it was staged | it fails its health check three times and systemd-boot falls back to the retracted version, which fails it too: the older version is forgiven, and bootc still reports it as the next boot (`rollbackQueued`). Settings repaired: the retraction deletes its deployment (with the old `/etc`) and stages it afresh instead of waiting for a reboot; it boots counted and is blessed |
| T3 | a dead network: the guest's link down before a check, then cut while the update downloads (the registry throttled to 2 Mbit/s, the cut 10 s into a ~16 MiB pull) | the check says "no network connection" (a journal warning, `ok: false`), the unit does not fail, nothing is staged or marked failed, the running version stays; with the link back the next check stages the update, which boots counted and is blessed |

**Version jumps and channels** (`tools/vm/channels.sh`, Titanic T11): on its own copy of the
installed disk, set up the same way, with two sheet keys and the test versions 2026.11.1-11, each
with its own update configuration (sheet key, repository, default channel, version floor).

| Boot | Scenario | Expected |
|---|---|---|
| 2 | on 2026.11.1, a sheet for 2026.11.5 (2026.11.3 retracted) signed with a key the version does not trust yet | refused |
| 2 | the same sheet with the trusted key | 2026.11.5 staged directly; an older sheet offering 2026.11.3 refused (sequence), a later one refused (retracted) |
| 3 | on 2026.11.5, which raises the version floor to itself: a signed retraction to 2026.11.4 | refused (below the floor) |
| 3-4 | 2026.11.6 trusts only a new sheet key | it boots; a sheet signed with the old key refused, the new key's accepted |
| 4-5 | 2026.11.7 has `beta` as its default channel | it boots and asks for `beta`'s sheet; `stable`'s refused; beta's 2026.11.9 staged |
| 6 | `set-channel nightly`, and no name | refused, nothing chosen |
| 6 | `set-channel stable` on 2026.11.9; stable's version is 2026.11.8 | a sheet issued before the change: nothing done (`WaitingForSheet`); one issued after it, below the floor: refused; then 2026.11.8 staged; until the reboot, that sheet and a later one wait for it (`WaitingForReboot`); a replayed sheet and an even older version refused |
| 6 | `set-channel` by another user than root | refused (permission denied), nothing chosen |
| 7-8 | 2026.11.8 boots; back to 2026.11.9 by hand (`bootc rollback`), whose default is `beta` | the machine still follows `stable`, and 2026.11.8 is refused as a downgrade (no new change) |
| 8-9 | on 2026.11.9, a file written in `/etc`; `set-channel beta`, then `stable` again: stable's 2026.11.8 is the rollback deployment | it is deleted and 2026.11.8 staged afresh (no `bootc rollback`); it boots counted, with the file |
| 9-10 | 2026.11.10 moves its updates to the repository `nyra-next` | it boots and asks for `nyra-next`'s sheet; `nyra-base`'s refused; 2026.11.11 staged from `nyra-next` |
| 11 | 2026.11.11 from `nyra-next` | up to date |

The versions the jump skips never boot: every boot checks which version runs.

**Network across soft reboots** (`tools/vm/soft-reboot-network.sh`): on its own copy of the installed
disk, ROUNDS rounds of a full boot (of the version the last round soft-rebooted into) and a soft
reboot into another test version, each needing a running system and the network up. CI runs 2
rounds, the nightly Titanic run 20 (`soft-reboot-rounds`, up to 99, also for a manual run of the
image workflow). On the test disks `systemd-networkd` logs at debug level, and when the system is
not `running` both tests print its journal and the link state.

Power cuts at many random moments, finalization included, run every night with `bootc` directly
(`docs/TITANIC.md`). The time limit of a pull is shortened to 90 s in the test versions only
(`stage_timeout_seconds`), so the slow link and the stalled registry are tested in minutes; production
keeps 2 hours. Not covered yet: power cuts during finalization with `nyra-updated`, and the real keyless
signature (the `sign` job, `docs/SIGNING.md`).
