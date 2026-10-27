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
it: the reboot stays the user's choice. Right before it stages (`bootc switch`) or goes back to the
other version (`bootc rollback`) it makes a copy of `/etc` (`nyra-etc-copy@update.service` or
`@rollback`, docs/BOOT.md, "Restore earlier settings"); a copy that fails is logged as a warning and
does not hold the change back (`tools/vm/updates.sh`, boots 5 and 12).
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
5. A version the machine fell back from is marked failed and never staged or offered again (one
   exception: rule 15).
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
15. A version marked failed only by the network health check is tried once more: a day later, or
    as soon as the machine is on another network (below, "The network"). A second fallback from it
    is final; any other failure is final at once.

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
| `/usr/libexec/nyra-updated` | the binary, built on the CI tools image (Debian testing, like bootc) without network, from crates checked against `Cargo.lock` (not from cargo's cache or the registry index), and stripped; `Cargo.lock` and third-party crate licence notices in `/usr/share/doc/nyra-updated/` |
| `/usr/lib/nyra/updates/updated.conf` | `repository`, `channel` (the default; a machine's own choice wins, rule 14), `version_floor`; every key required, unknown or repeated keys refused; the server is not configurable. Optional `stage_timeout_seconds`: shortens the 2-hour limit of a pull (never longer); only the test versions set it (90 s) |
| `/usr/lib/nyra/updates/channel-sheet.pem` | the trusted sheet keys; the public key of the channel sheet signer (Ed25519, in a Cloud KMS key that never leaves it). A file with no key means updates are "not configured": every sheet is refused (nothing is even fetched), and each check reports it as a warning without failing the unit, so machines are not all `degraded` for a known state. The 14-day rule (below, "Updates that stop") does not make it an error: nothing is held up, there is nothing to update from. A missing or broken key file is an error. When image signing is turned on, the release build must require at least one key |
| `nyra-updated.timer` / `.service` | a check 15 minutes after boot, then every 6 hours (randomized); after `boot-complete.target`; only with the ESP checked and mounted at `/boot` (`RequiresMountsFor=`, docs/BOOT.md, "Mounts from /etc/fstab") |
| `nyra-updated-wait-online.service` | before every check: `systemd-networkd-wait-online --any --timeout=3600`, so a check that comes due without a network waits up to an hour for one and runs once a link is online, or when the hour is over (below, and docs/DEFAULTS.md, "Without a network"); a dynamic user without capabilities, `IPAddressDeny=any` |
| `nyra-health-system.service` | a health check: the core services (D-Bus, journald, logind, udevd, networkd, resolved) are running and AppArmor's profiles are loaded (`apparmor.service` active); the list is in `/usr/lib/nyra/health/system` |
| `nyra-health-bootc.service` | a health check: `bootc status` reports the booted image, so this version can still update itself |
| `nyra-health-network.service` | a health check, on a version on trial: the links that had a routable address at the last update check get one again (below, "The network"); `/usr/lib/nyra/health/network`, which also writes that list (`/var/lib/nyra-updated/network-links`, before every check of `nyra-updated.service`) |
| `nyra-health-.service.d/10-nyra.conf` | for every `nyra-health-*.service`: `Before=boot-complete.target systemd-user-sessions.service`, `OnFailure=nyra-updated-health-failed.service`, sandboxing |
| `nyra-updated-health-failed.service` | `nyra-updated health-failed`: the full reboot while on trial (rule 8); off trial, a version fallen back from forgiven once (rule 12), and the notice. Off trial it takes the check's lock: if a check holds it, the version is not forgiven (the prudent side) and the notice is still shown. `TimeoutStartSec=5min`, above its slowest path (the boot state, `bootc status` and the notice, up to 60 s each), so systemd does not stop it before the notice |
| `nyra-updated-install@.service` | `nyra-updated install %i`: stages the release named by the instance, started by an administrator with `systemctl start` after polkit asks for the password (above, "Updating from a terminal as an administrator"; the rule is in `49-nyra.rules`). Hardened like `nyra-updated.service` (same sandbox, `TimeoutStartSec=2h30min`, above the 2-hour pull); listed in the image build's `systemd-analyze verify` |
| `/usr/lib/nyra/profile.d/update-hint.sh` | the message at the login of an administrator about a version that was prepared and lost to a hard reset (above, "After a hard reset"); linked from `/etc/profile.d/update-hint.sh` |
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
The scheme has limits the sheet must respect, since a version that is not higher is refused as a
downgrade (rule 4): a Debian snapshot moved back across a month gives a lower version; renaming
`image.yml` starts its run number again from 1; a re-run of the same workflow run keeps the number.
So the sheet must never offer two digests with the same version, and a release after any of these
needs a version above the last one published.

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

**The network.** A version that breaks the network must fall back like any unhealthy one, but a
machine without a network must not make a good version fall back. `nyra-health-network.service`
judges only what is clearly the version's fault: a link that systemd-networkd configured with a
routable address (IPv4, or IPv6 beyond link-local) at the last update check before now has carrier,
but no routable address within 60 s. A link without carrier for 20 s (no cable; Ethernet takes a few
seconds to negotiate), waiting for authentication (`dormant`) or not there at all (a USB adapter
unplugged) is not judged. networkd or resolved not running is the core services check's.

- **The record.** Before every update check (`ExecStartPre=` of `nyra-updated.service`: 15 minutes
  after boot, then every 6 hours), on a healthy boot (`boot-complete.target` active),
  `/var/lib/nyra-updated/network-links` becomes the list of links networkd configured (setup state
  `configured`) with a routable address at that moment. With none (the machine is offline), the list
  stays as it was. Links networkd does not manage (a container bridge) are left out. An update is
  staged by such a check, so the list holds the links that worked when the version was downloaded.
  A change of the settings is followed at the next check: a port that is bridged or bonded (its
  bridge has the address), no longer managed, or only carries VLANs is no longer judged, so it never
  makes every new version fail. The new list is written to the disk (`sync`) before it replaces the
  old one: a power cut never leaves an empty list, which would judge nothing.
- **When it judges.** Only on a boot on trial (systemd-boot started an entry that counts its tries:
  `LoaderBootCountPath`, and no soft reboot since, which leaves that variable from the last full
  boot; nothing is blessed after a soft reboot either, and the next full boot is counted), so a
  version that passed its checks never waits for an address at boot, and a router that is down
  does not delay the login on it. And on the boot after a trial boot that failed it
  (`/var/lib/nyra-updated/network-failed`, written only when no other health check failed on that
  boot), which is the version fallen back to: rule 12 needs to know whether that one gets an
  address. If it does, the new version is marked failed; if it does not, the network or the
  settings are to blame, as for any check both versions fail: the new version is forgiven, and the
  notice says to reset the settings. If that boot judges nothing (no carrier, the link not there,
  `networkctl` lists no links), it passes too, and the new version is marked failed, with its one
  more try (below): at most one try more, simpler than telling those cases apart.
- **One more try (rule 15).** A version marked failed that way, by the network check alone, may
  still have met a network that was down only then (a router restarting during all three tries). The
  boot after the fallback, when it passes the check (an address, or nothing judged), leaves
  `/var/lib/nyra-updated/network-fallback`; the next update check takes it, marks the version failed
  as usual and remembers it (`network_retry` in the state: the digest, the time, the list of links
  with an address then). The version is staged once more, afresh (its old deployment, with the
  `/etc` of its tries, is deleted, as for rule 12), as soon as a check finds a day has passed or the
  list of links with an address is another (the machine moved from Wi-Fi to a cable, or to a dock):
  the simplest sign of another network the machine already keeps. The same link on another network
  (another Wi-Fi) is not told apart; the day covers it. If the version fails the network check
  again, it stays failed until the next version; if it boots healthy, nothing is left of the first
  failure. One version at a time, like a forgiven one; an older `nyra-updated` (after a rollback)
  drops the field and keeps the version failed.
- **The cost.** A version on trial whose link has carrier but gets no address delays the login by
  60 s; a version that breaks the network takes three times that longer to fall back. On trial, a
  recorded link without carrier (or not there) delays the login by 20 s before it counts as unplugged.
  If `networkctl` lists no links at all (networkd not running, or a format it no longer understands),
  nothing is judged and the journal has a warning.
- **Not covered.** A link that a new version names differently (another naming scheme) is "not
  there" and not judged, and a new kernel whose driver never reports carrier looks like a cable
  unplugged: such a version keeps running without a network. A router that answers no DHCP during
  all three tries, but answers again by the fallback boot, costs a good version its first try; it
  gets a second one (rule 15). Wi-Fi is not in the base yet.

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
`esp-writable`), the network, `/sysroot` and `/var`: it gets `ProtectSystem=full`,
`ProtectHome=tmpfs`, `PrivateTmp`, `NoNewPrivileges`, the kernel and cgroup protections and a list
of address families (`systemd-analyze security`: 6.5). The health checks and `health-failed` only
read state and ask systemd for a reboot: no network, no capabilities where possible. The network
check sees the machine's links (no private network namespace), but opens no network socket (only
`AF_UNIX` and `AF_NETLINK`). The pull itself is stopped by `nyra-updated` after 2 hours;
`TimeoutStartSec` is above that.

**What a machine shows.** Every check writes its outcome to the journal (an error at priority 3, a
foreign image at 4) and to `/var/lib/nyra-updated/last-check.json` (`time`, `ok`, `message`), for
Settings, which will read it through the daemon (the file is root-only, like the rest of the state).
**Without a network** (a laptop offline, a link lost in the middle of a pull): a check that comes
due without a network waits for one (`nyra-updated-wait-online.service`, up to an hour) and runs as
soon as a link is online, or when the hour is over. When the download of the sheet or of the version fails and
systemd-networkd reports the machine `offline` (its `OnlineState`), the check says "no network
connection (…): the running version stays, the next check tries again", as a warning (`ok: false`),
and the unit does not fail: a check without a network does not make the machine `degraded`. Nothing
is marked failed, and the next check (the timer, every 6 hours) stages the update. Only the
machine's own link state counts: a server or a network that stops answering while the link is up is
still an error.
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
laptop offline for a holiday is not flagged, and the server signs the sheet at least daily. A failed
check leaves `last_success` as it is, even when it is later than the check's own time: the clock may
be behind at that check (a dead RTC at the build date, offline), and counting from it would report
days that never passed once the clock is right. A success that reads the sheet needs one that has
not expired (at most 31 days of validity), so a clock that was ahead then delays the count by at most
that; only the outcomes that come before the sheet (a boot not yet healthy, an owner's own image, a
wrong staged deployment discarded) do not check the time. An older `nyra-updated` (after a rollback) writes the file without `last_success`; the count then starts
again. The messages in the journal and in `last-check.json` are one line each, control characters
replaced by spaces and cut at 2000 characters: they carry what bootc and curl print, which can come
from the registry or the server. Two checks never write the file at once: it is written under the
lock, and a check that finds another one running writes nothing.

The offline detection reads systemd-networkd's `OnlineState`. A link that networkd does not manage
(Wi-Fi through NetworkManager or iwd, later) is not seen: a download that fails on it is reported as
an error, the prudent side, until the detection covers it. A link lost while bootc downloads the
sigstore signature may be reported as an error too, not as no network: the image proxy's message then
names the signature, which counts as a refusal (the prudent side as well).

## Updating from a terminal as an administrator

On an installed system root has no password and there is no root shell (docs/DEFAULTS.md, "su"), so
nobody can run `bootc switch` by hand. An administrator (the user the installer made, a member of
the group `sudo`) runs `nyra update` (below). Under it is one command that names the version:

```sh
systemctl start nyra-updated-install@2026.10.600.service
```

polkit asks for that administrator's own password in the terminal. The command waits until the
version is staged (a pull can take long; interrupting `systemctl` only stops the waiting, and
`journalctl -u nyra-updated-install@2026.10.600.service` shows the result). It never reboots: the
reboot stays the user's choice.

`nyra-updated install VERSION` runs as root in that unit and refuses, before it pulls anything:

- an argument that is not a release version (`YEAR.MONTH.BUILD`, digits only);
- a signature policy that is not the shipped one: `/etc/containers/policy.json` and
  `/etc/containers/registries.d/nyra.yaml` must resolve to the files under `/usr/lib/nyra/containers/`,
  the policy must name one real signer for `updates.nyraos.com` (not the placeholder of an image built
  before the address was committed), and no per-user policy or `CONTAINERS_POLICY_JSON` may exist;
- a version that is not newer than the running one (numbers compared one by one), or below the
  image's version floor;
- an image without a sheet key (updates not configured): the channel sheet is mandatory, as for a
  check, so nothing is installed ("updates are not configured: no channel sheet key ...");
- a channel sheet that cannot be fetched or verified (the fetch and the verification of a check; its
  sequence and retractions are kept as a check keeps them);
- a version that the verified sheet does not name: only the sheet's `current` and `previous` versions
  are installed, and nothing at all while the sheet says the channel is halted;
- a version whose digest in the sheet was retracted, or that this machine fell back from.

Before it fetches the sheet it settles what became of the version staged last time, as a check does
at its start (a version the machine fell back from is marked failed), instead of refusing while one
is unsettled. It then pulls `updates.nyraos.com/<repository>@<digest>`, the digest the sheet gives for
that version, and nothing else (the image's repository from `updated.conf`: `nyra-base`, or
`nyra-base-arm64`), under the update lock, with a copy of `/etc` first and `sync` after, exactly as a
check stages a version. The staged image must be that digest, otherwise it is discarded and nothing
is left to boot. Like a staged version of a check, it is remembered, so that a fallback marks it
failed. The signature policy and the sheet are the two guarantees: an installed machine without a
sheet key (a file with no key, as in a build of a fork) can not use this command, as it can not check
for updates. A change of Secure Boot key or of the disk's TPM policy needs the steps below.

Only `systemctl start` of exactly these unit names, by a member of `sudo` in a local, active
session (at the machine, not over SSH), asks for a password, the administrator's own
(`49-nyra.rules`); anyone else is refused, and so is every other start, stop or transient unit
(`systemd-run`, `run0`) of systemd's manager, for everyone but root. A transient unit is refused even
when it is named `nyra-updated-install@VERSION.service`: systemd asks polkit about it with the same
action, unit and verb as for the real unit and only the message differs, so the rule accepts the exact
message of `systemctl start` and nothing else (a transient unit runs any command as root). A wrong
password is polkit's usual denial. polkit's password helper is on in the image (docs/DEFAULTS.md,
"Passwords through polkit"), and this is the one action there that a password approves; polkit's administrator is root
alone, so this explicit rule, not the group `sudo`, is what lets the member of `sudo` through.

**`nyra update`** (`/usr/bin/nyra`, a short shell script) is what an administrator types. It needs no
`sudo` and does nothing as root itself. It says which version is installed and which one is available,
asks `Install it? [y/N]`, then starts the unit above with `systemctl start --no-block`, so polkit asks
for the password through systemctl's own agent on the terminal and the job then runs on without the
command. The administrator sees `Password:` and nothing else of the agent: pkttyagent writes a banner
around its prompt (`==== AUTHENTICATING FOR org.freedesktop.systemd1.manage-units ====`, the action's
message, `Authenticating as: NAME`, `==== AUTHENTICATION COMPLETE ====`) to `/dev/tty`, the terminal
itself and not stdout, so no redirection removes it and the agent has no option for it. `nyra update`
therefore runs `systemctl` through `/usr/libexec/nyra-prompt-only`, a short Python program that gives
the command a terminal of its own and passes on only the unfinished line (the prompt) and the empty
lines, not the lines that end in a newline. The keys typed go through unchanged, the polkit rule is
untouched (the message text it matches is still the one systemctl sends, just no longer shown), and
the failure of `systemctl` reaches `nyra update` as before: its stderr and its exit status.
While the job runs, one line on the terminal shows the stage and the time since the wait began,
rewritten in place (`Downloading and preparing the update... 2:35`; on a terminal too narrow for
it, the time alone, so that the line never wraps). It ends by telling the administrator to
restart with `systemctl reboot` when ready, and not to force-reset the computer (for example with the
Restart or Stop button of a virtual machine), or the update is lost, and to run `nyra update` again
if it is (below, "After a hard reset"). It
never restarts the computer. It refuses with one line when it is not run on a terminal, by a member of
`sudo` (polkit still refuses a session that is not local and active, for instance over SSH), or when
the update is not possible. Run again while the version waits for the restart, it says so. Ctrl+C
stops only the waiting: the install goes on, the command says so, and the next `nyra update` (while
the install still runs) shows that install instead of asking again, without a new password.
What it reports is only what the program wrote during this run (below), never the state of the
unit: a unit whose dependency failed, or that root stopped, ends `inactive` with no result, and that
is "The update was not installed."

- **The newest version** comes from `nyra-updated available`, which any user can run and which writes
  nothing (no lock, nothing under `/var/lib`). It fetches the channel sheet (curl with an empty
  environment, so the user's proxy and certificate variables do not matter) and verifies it as a check
  does (the mandatory key, the signature, repository and channel, the validity time). It prints the
  sheet's `current` version when that is a release version and newer than `IMAGE_VERSION` of
  `/usr/lib/os-release`. A halted sheet, a sheet that does not verify, a missing key or no network is
  one plain sentence and a failure.
- **The offer is informational.** A user can not read the daemon's state (the files of
  `/var/lib/nyra-updated` are root's, mode 0600: the sequence of the last sheet, retracted and failed
  versions, a channel chosen with `set-channel`) or run `bootc status`. So the offer takes no sequence number, and an older signed
  sheet that is still valid could be offered. `install` repeats every check as root, with the stored
  sequence, and has the last word; a version it refuses is reported with its reason. The offer also
  ignores the gradual rollout (`install` accepts `current` for every machine). What a check stored is
  not used: a stored value would be an offer that was not verified now.
- **The result** of `install` is written, success or failure, as one line to
  `/run/nyra-updated-install.result` (mode 0644, gone at the next boot, which is when a staged version
  stops being staged): `staged VERSION` (with `already` when the version was staged before, by a check
  or an earlier install, and nothing was pulled again), or `failed VERSION` and the reason. An
  administrator reads neither the journal nor `bootc status`, so `nyra update` shows the reason from
  this file when the install failed during this run (not an older line), and uses `staged VERSION` to
  say that a version is already prepared. When the unit was not started at all (a wrong password, a
  cancelled question, a session that is not at the computer), there is no new line, and it says so
  in one sentence. Everything the wrapper prints that carries data goes through `printf '%s'`:
  dash's `echo` acts on a backslash in it.
- **The stage** is written by `install` as one line to `/run/nyra-updated-install.stage` (mode 0644,
  written to a temporary file and renamed, best effort): `Checking the update` when it starts, and
  `Downloading and preparing the update` just before the pull (not when the version was staged
  before). The lines are fixed words, never text from bootc, curl or the registry. The wrapper polls
  the unit every second (a job is queued or running) and reads the stage only if the file was
  written after the wrapper's own start, as it does for the result. An empty answer of `systemctl`
  is not "finished": it is waited through, for 30 seconds at most. When the job has ended, the
  wrapper waits up to 5 seconds for a result written during this run; without one, or with one for
  another version, the update was not installed. The stage is written after the lock is taken, so
  only the run that holds it writes it, and each file has a temporary file of its own. There is no percentage:
  bootc has a hidden `--progress-fd` that reports bytes as JSON lines, but it needs a pipe on a
  file descriptor that the daemon's `run` (which collects the output only at the end) does not give, and the
  VM test could not exercise it. The stage and the time are what is shown.

### After a hard reset

`bootc` keeps a staged deployment in memory only: the marker `/run/composefs/staged-deployment` is made
when a version is staged and read at the clean shutdown that applies it. A power cut or a forced restart
before that shutdown loses the marker, and the old version boots, without a word. What was pulled stays on
disk (`/sysroot/composefs`), so staging the version again pulls only what is missing.
The update test (below, T2) counts the bytes the registry sends for the second staging and fails when they
are not a small part of the first staging's, so "nothing is downloaded again" is a measured claim.

So that the administrator learns of it, `nyra-updated` leaves the version it staged last in
`/var/lib/nyra-updated/staged-version` (one line, mode 0644, written like the other state files:
a temporary file, `fsync`, rename). Every staging writes it (a check or `install`), after bootc staged the
digest of the sheet, and a newer staging replaces it. The directory is mode 0711 for this: everybody can
enter it, so that a login can read this file by its name, and only root can list it; every other file in
it stays root's, 0600. The file holds only the version, which is not a secret (the channel sheet is
public).

**The message.** The login script `/usr/lib/nyra/profile.d/update-hint.sh` (linked from
`/etc/profile.d/update-hint.sh`, which Debian's `/etc/profile` reads for a login shell; the content is in
`/usr` and updates with the image, a user who removes the link only loses the message) prints, once per
login, to an administrator:

```
Version 2026.10.600 was prepared, but the update was not finished.
Run `nyra update` to prepare it again; nothing is downloaded again.
```

only when all of this is true: the shell is interactive and its input and output are a terminal (not an
`ssh` command, `scp`, `sftp` or a script); `staged-version` holds a release version and it is newer than
`IMAGE_VERSION` of `/usr/lib/os-release` (numbers compared one by one); `/run/composefs/staged-deployment`
does not exist (a version that is staged now is applied by the next restart); and the user is a member of
`sudo`, the test `nyra update` makes. It reads these three files and runs `id`; it asks nothing, runs
nothing privileged, evaluates nothing from the files (the version is checked for its shape, digits and dots
only, before the arithmetic), prints nothing on any error, and leaves no variable or function in the shell.
A terminal opened inside a desktop session is not a login shell and shows nothing.

**When the record goes.** A newer staging replaces it. `nyra-updated` removes it at the start of every
check and `install` when the running version is the one it names or a newer one (it was applied, or
something else was installed), and when the machine fell back from the version that was pending (it
failed: nothing to prepare again). The script ignores it in the same cases by itself (the running version
is not older), and while the version is staged. What the record cannot know: a version that was
retracted after it was staged still shows the message until the next check stages another one (or
`nyra update` says why that version is refused).

## Moving a machine to updates.nyraos.com

**The steps below are for the CI test VM**, which has a root shell. On an installed system root
has no password and `su -` does not exist as a way in; there the command above is used. It runs the
checks of step 1 and the switch of step 5 itself, not the digest, MOK and TPM steps.

A new VM is installed from a release with the installer (docs/INSTALL.md), which does the pull,
the digest check (step 2) and the MOK import (step 3) itself. This section is for an owner who moves
an existing Nyra VM to the published releases. A machine installed from an image built before the channel sheet key was committed does not update by itself: each new release is a manual `bootc switch`
to its version tag, with the same digest check as below. A machine installed from an image built
before the signer address was committed (its policy names `signer-not-configured@nyra.invalid`)
cannot switch: reinstall it from a release.

**The guarantee.** containers/image applies `policy.json` to the exact name
`updates.nyraos.com/nyra-base`: the image must be signed by the Nyra signer (docs/SIGNING.md,
"Other registries and local images"). It holds only if that policy is the shipped one and the
reference is exactly that name, which is what the checks below prove. Nothing else gives the
guarantee (`--enforce-container-sigpolicy` has no effect on Nyra's composefs backend; the guarantee
is the policy alone).

**1. Checks on the running system.** All of them are required. In the CI test VM, run every
command of this section in one root shell.

```sh
readlink -f /etc/containers/policy.json                # /usr/lib/nyra/containers/policy.json
readlink -f /etc/containers/registries.d/nyra.yaml     # /usr/lib/nyra/containers/registries.d/nyra.yaml
grep -o '"subjectEmail": *"[^"]*"' /usr/lib/nyra/containers/policy.json
                                                       # "nyra-image-signer@nyra-signing-3076.iam.gserviceaccount.com"
[ ! -e /root/.config/containers/policy.json ] && echo ok
[ -z "${CONTAINERS_POLICY_JSON+x}" ] && echo ok        # prints nothing if the variable is set
```

Any other address, including `signer-not-configured@nyra.invalid`, means: reinstall from the
release. Never edit or replace the policy to get past a check. A per-user policy or
`CONTAINERS_POLICY_JSON` wins over `/etc`, so those two must be absent.

The reference is exactly `updates.nyraos.com/nyra-base:<version>`: lowercase, no port, a version tag.
Never `:stable` or any other channel tag by hand.

**2. The expected digest.** It is in the summary of the release run: the `sign` job's "Signed" table
(`publish` prints it too). Note the version and the `sha256:` digest.

**3. The Machine Owner Key, before the switch.** Take `nyra.crt` from the running system's
`/usr/lib/nyra/secureboot/nyra.crt`, or from a clone of nyra-base `main`. Check the **full**
SHA-256 fingerprint, all 32 bytes, against docs/SIGNING.md ("Making the UKI certificate")
before importing; do not compare a shortened form:

```sh
openssl x509 -noout -fingerprint -sha256 -in /usr/lib/nyra/secureboot/nyra.crt
openssl x509 -in /usr/lib/nyra/secureboot/nyra.crt -outform DER -out /root/nyra.der
mokutil --import /root/nyra.der
```

Reboot, enroll the key in MokManager with the one-time password, then check
`mokutil --sb-state` (`SecureBoot enabled`) and `mokutil --list-enrolled`. `mokutil --test-key
/root/nyra.der` says whether the key is already enrolled (do it before the import as well).

**4. The TPM.** Before the switch, have the disk's recovery key at hand and console access: its
prompt is in the initrd, not on the network.

**5. Switch, and check before rebooting.**

```sh
bootc switch updates.nyraos.com/nyra-base:<version>
sync
bootc status
```

In the output of `bootc status`, read the staged entry's image reference and its digest. The staged
image must be exactly `updates.nyraos.com/nyra-base:<version>` with the digest from step 2.
On a mismatch, **do not reboot**: `bootc switch <the booted reference>` back, and report it.
Otherwise `systemctl reboot`.

**6. After the first good boot.**

- Remove every other MOK, such as a CI run's throwaway key: its private half came from a CI run, and
  a PR build's key may have left the run. `mokutil --list-enrolled` shows them; for each other one,
  `mokutil --export` writes `MOK-000N.der` files. Print the fingerprint of each:

  ```sh
  for f in MOK-*.der; do echo "$f"; openssl x509 -inform DER -noout -fingerprint -sha256 -in "$f"; done
  ```

  The one whose SHA-256 fingerprint is `nyra.crt`'s (step 3) is Nyra's; `mokutil --delete
  MOK-000N.der` removes each of the others (confirm at the next boot). Keep the Nyra key.
- The TPM enrollments, in the same root shell. `systemd-cryptenroll` lists only the slot types; the
  key behind each TPM2 slot is in the record. The LUKS2 device is the one under the opened root:

  ```sh
  dev="$(cryptsetup status root | sed -n 's/^ *device: *//p')"
  systemd-cryptenroll "$dev"                           # one recovery slot, two tpm2 slots
  cat /var/lib/nyra/tpm2-slots
  sha256sum /usr/lib/nyra/secureboot/tpm2-pcr-public-key.pem \
    /usr/lib/nyra/secureboot/tpm2-pcr-public-key-next.pem
  ```

  Each record line is `<slot> <sha256 of a PCR public key PEM>` (with ` pin` after it when a PIN
  is set); `retired <sha256>` lines list keys that were removed. The two `tpm2` slots must be the
  two slot numbers of the record, and its two hashes must be the two `sha256sum` values above
  (current and next key, each once, none retired). `nyra-tpm-enroll` removes the old one after the
  recovery key is typed (docs/BOOT.md, "Enrolled again after the TPM refused").

**If the new UKI does not boot** (the MOK is missing, so shim refuses it), boot counting falls back
to the previous version after three tries. Fix the MOK (import and enroll it as in step 3). Do not
turn Secure Boot off: that changes PCR 7 and the TPM stops unlocking the disk.

## Tests in a VM (`tools/vm/updates.sh`)

The `install-boot-updates` job follows one installed VM through 40 boots and real updates. Everything the
guest trusts is made for the run: a sigstore key stands in for the keyless signer (the guest's
`/etc/containers/policy.json` is the shipped policy with that key), a channel sheet key is baked
only into the test versions (the installed image keeps the real key, which no test sheet is signed
with; the first boot empties the key file with a bind mount to prove the fail-closed cases), and a CA signs the certificate of a sheet server on the runner. The
guest reaches the runner as `updates.nyraos.com` (`/etc/hosts` on the test disk): the registry on
port 80 (plain HTTP, `insecure` on the test disk) and the sheet server on 443. The test versions
v0-v17 carry the version in the manifest annotation `org.opencontainers.image.version`, which is where
bootc reads it.

| Titanic | Scenario | Expected |
|---|---|---|
| T4 | the installed image with its key file emptied (a bind mount over it for these cases) | "updates are not configured" (`ok: false`), nothing fetched, the unit not failed |
| T4 | unsigned image from `updates.nyraos.com`, shipped policy | `bootc switch` refused |
| T4 | unsigned, and signed with another key, test policy | refused |
| — | image from another registry | accepted; `nyra-updated` reports `ForeignImage` (journal warning) |
| T4 | sheet signed with another key | refused |
| T2 | power cut while the update downloads (the registry throttled to 2 Mbit/s, the cut 4–12 s into a ~16 MiB pull, while `nyra-updated` is still activating and nothing is staged) | the old version boots, nothing staged; the next check stages it again |
| T2 | power cut after staging, before finalization | the old version boots, nothing staged; an administrator's login says that the version was prepared, a standard user's says nothing; staged again, and the registry sends a small part of the bytes of the first staging (counted); while it is staged, no message; once it runs, no message and the record is removed at the next check |
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
| T9 | the hardware clock in 2099 and in 1970 (systemd sets both to the image's date at boot, the Debian snapshot date, before the real time), and in 2035 (kept, ahead, outside the validity of every certificate) | ntpd-rs corrects the clock through NTS by itself (docs/DEFAULTS.md, "Time"), the update is staged or the system is up to date; ntpd-rs's memory, context switches and CPU time are printed |
| T9 | the hardware clock in 2035 and the NTS servers' names pointing to the runner: a real NTS server (the image's ntp-daemon) with an untrusted certificate, which gives keys and the runner's time over NTS, and an NTP server that answers with a time in 2001 | the clock stays in 2035, every time from the NTS server refused ("the server's certificate is not valid at that time"), ntpd-rs sends not one unauthenticated NTP request (the server counts only the test's own probe, which shows UDP 123 reaches it); the sheet server's certificate refused (expired), nothing staged; unsigned and wrongly signed images refused; with the real servers back, the clock is corrected and the system is up to date |
| T4 | a valid layer with other content and exactly the same size served in place of the right one (`tools/vm/same-size-layer.py`) | refused: the image proxy checks each layer's digest against the signed manifest (`corrupted blob, expecting …` at `FinishPipe`), nothing staged; staged once the registry is repaired |
| T3 | a retraction to an older version that is not a local deployment, the settings broken after it was staged | it fails its health check three times and systemd-boot falls back to the retracted version, which fails it too: the older version is forgiven, and bootc still reports it as the next boot (`rollbackQueued`). Settings repaired: the retraction deletes its deployment (with the old `/etc`) and stages it afresh instead of waiting for a reboot; it boots counted and is blessed |
| T3 | a dead network: the guest's link down before a check, then cut while the update downloads (the registry throttled to 2 Mbit/s, the cut 10 s into a ~16 MiB pull) | before the check: it waits for the network (not started after 20 s), nothing fails; the cut: the check says "no network connection" (a journal warning, `ok: false`), the unit does not fail, nothing is staged or marked failed, the running version stays; with the link back the next check stages the update, which boots counted and is blessed |

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

**A version that breaks the network** (`tools/vm/network-health.sh`, Titanic T3): on its own copy of
the installed disk, set up the same way, with the test versions 2026.12.1 (good), 2026.12.2 and
2026.12.3 (the image's wired network without DHCP and router advertisements: the link has carrier and
only an IPv6 link-local address).

| Boot | Scenario | Expected |
|---|---|---|
| 1-2 | 2026.12.1 boots on trial | the network check has no record yet and passes; the next update check records the link with its address, and a link recorded before but not there now is dropped at the next check; 2026.12.2 staged |
| 3-6 | 2026.12.2 | no routable address within 60 s, three times: it reboots by itself and systemd-boot falls back to 2026.12.1, which checks the network too (the boot after a failed trial) and passes (`network-fallback`); 2026.12.2 is marked failed, remembered for one more try (`network_retry`, not due on the same network the same day), bootc's order set right (`RollbackUndone`) and the version refused; 2026.12.3 staged |
| 7 | 2026.12.3 with the cable unplugged (`vm-boot.py --no-carrier`: the NIC's link down from the start) | the link is not judged (no carrier), the boot is healthy and blessed, the version is not marked failed |

The check's own cases run without a VM on every pull request (`tools/vm/test-network-health.sh`, a
stand-in for `networkctl`): the list replaced at each check and kept while offline, synced before the
rename; a recorded port that is bridged or no longer managed judged until the next check and not
after it; a soft reboot, no cable, a link not there, `dormant` and an empty `networkctl` not judged;
the boot after a failed trial judged, and the only one off trial; `network-fallback` left when that
boot passes, with an address or with nothing judged (no cable), never when it gets no address
either and never on a trial boot; no marker when another health check failed too.

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
