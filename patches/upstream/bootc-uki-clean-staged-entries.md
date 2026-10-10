# bootc: clean stale staged entries before staging a UKI deployment (systemd-boot)

Status: kept here, not sent upstream yet (an upstream change needs the owner's approval and a check
that it does not break other distributions). Worked around in nyra-base by `esp-sync repair`
(stale staged entries removed at every full boot, docs/UPDATES.md).

Upstream: bootc-dev/bootc, checked at v1.16.13 (`fa0d3f9cb9a0ce3b4d1dc2607a0bf5e31b822f60`).

## What

On the composefs backend with systemd-boot and UKIs, staging an image writes its boot entries to
`loader/entries.staged` on the ESP; `bootc-finalize-staged` swaps that directory with
`loader/entries` at shutdown. `write_systemd_uki_config` (`crates/lib/src/bootc_composefs/boot.rs`)
creates `loader/entries.staged` with `create_dir_all` and adds the new entries to whatever is
already there. The Type #1 path (`setup_composefs_bls_boot`) removes the directory first, and
`validate_update` removes it too, but only for an image that is already pulled.

## Why it matters

A staged deployment lives in `/run`; if the machine loses power between staging and finalization,
`loader/entries.staged` stays on the ESP. When the next update is another image that is not pulled
yet, its entries are added next to the old ones, and the swap at shutdown brings the old version's
entry back into `loader/entries`: three entries instead of two, and systemd-boot may pick the old
version instead of the new one. bootc's own `rollback` asserts exactly two entries afterwards.

Reproduced in a VM (nyra-base `tools/vm/updates.sh`, boots 17–19, before the workaround): stage v9,
power cut before finalization, stage v10 → `loader/entries.staged` holds three files instead of two:
v10's entry, the booted one's, and a file left by the interrupted staging (in that run under a
temporary name, the rename not yet on disk; with the rename on disk it is v9's `.conf` entry).

## Proposed change

Remove stale staged entries before writing new ones, as the Type #1 path does:

```diff
--- a/crates/lib/src/bootc_composefs/boot.rs
+++ b/crates/lib/src/bootc_composefs/boot.rs
@@ fn write_systemd_uki_config(
         BootSetupType::Upgrade((_, booted_cfs, ..)) => {
+            // Entries left by a staging that was never finalized (power loss) must not be
+            // swapped in with this one.
+            esp_dir
+                .remove_all_optional(TYPE1_ENT_PATH_STAGED)
+                .with_context(|| format!("Removing {TYPE1_ENT_PATH_STAGED}"))?;
             esp_dir
                 .create_dir_all(TYPE1_ENT_PATH_STAGED)
                 .with_context(|| format!("Creating {TYPE1_ENT_PATH_STAGED}"))?;
```

The same applies to `user.cfg.staged` in the GRUB UKI path if it can be left behind the same way
(not checked).

## Effect

Every staging starts from an empty `loader/entries.staged`, so only the staged deployment and the
booted one are swapped in, whatever an earlier interrupted staging left. No change when nothing was
left behind.
