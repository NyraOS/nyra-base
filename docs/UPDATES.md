# System updates

bootc downloads and stages a new image; it does not decide which image a machine should run, refuses
nothing that is correctly signed (not even an older version) and does not react when a new version
is unhealthy (`docs/LESSONS.md`). `nyra-updated` adds those rules. It lives in [`updated/`](../updated):

| Crate | What it is |
|---|---|
| [`updated/channel-sheet`](../updated/channel-sheet) | library: verifies the signed channel sheet and picks the version for this machine |
| [`updated/daemon`](../updated/daemon) | `nyra-updated`, run by systemd: the safety rules around bootc |

CI (`.github/workflows/updated.yml`) runs `cargo fmt`, `clippy`, the unit tests and `cargo audit` on
every change under `updated/`, and the audit weekly.

Not in the image yet: the binary, its systemd units and the health checks go in with NyraOS#66.

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
7. The image is pulled pinned by digest, and the staged digest must be the sheet's.
8. A failed health check reboots fully: never a soft reboot, always after a soft reboot (which bypasses
   boot counting), and never on a version that is not on trial (no reboot loop).
9. The first healthy boot of a new version must have been a full boot with a boot counter, or it is
   reported as an error.
10. Nothing is done when the booted image is not from `updates.nyraos.com/<repository>`: the server is
    fixed in code, because the signature policy covers exactly that name (`docs/SIGNING.md`). An owner
    who switched to their own image keeps it.
