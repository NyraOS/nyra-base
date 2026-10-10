# bootc: keep a bootable entry while the staged entries are swapped in (systemd-boot, ESP on FAT)

Status: kept here, not sent upstream yet (an upstream change needs the owner's approval and a check
that it does not break other distributions). Worked around in nyra-base by a fallback UKI that does
not depend on `loader/entries` (`esp-sync`, docs/BOOT.md "The fallback").

Upstream: bootc-dev/bootc, checked at v1.16.13 (`fa0d3f9cb9a0ce3b4d1dc2607a0bf5e31b822f60`).

## What

On the composefs backend with a BLS boot loader, `bootc-finalize-staged` makes a staged deployment
the default at shutdown with `rename_exchange_bls_entries` (`crates/lib/src/bootc_composefs/rollback.rs`):

1. `renameat2(loader/entries.staged, loader/entries, RENAME_EXCHANGE)`;
2. `remove_dir_all(loader/entries.staged)`, which now holds the previous entries;
3. `fsync` of `loader/`.

The comment calls the exchange atomic. On the ESP it is not: the ESP is FAT, and FAT keeps no
journal. The exchange changes two directory entries (and the `..` entry inside each directory),
and they reach the disk separately, as the kernel writes them back. Step 2 then frees the previous
entries before anything is on disk.

## Why it matters

A power cut during these steps can leave a `loader/entries` that no longer holds a usable entry.
systemd-boot then finds no entry at all, and the machine does not boot until someone repairs the ESP
by hand.

Seen in a VM (nyra-base `tools/titanic/power-cuts.sh`, one round in twenty, QEMU killed 0.6 s
after `systemctl reboot`, during `bootc-finalize-staged`): the next boot showed the systemd-boot
menu with only "Reboot Into Firmware Interface", then the firmware setup. The exact on-disk state
was not kept. The window cannot be hit on purpose from outside, because the whole swap is one
system call followed by writeback. The tests therefore reproduce the states it can leave (no
`loader/entries`, an empty one) on the ESP directly (`tools/vm/boot-protection.sh`, boots 12-13).

Staging also needs the booted entry (`get_booted_bls`), so a system brought up some other way cannot
stage the next update until that entry is back.

## Proposed change

Never let `loader/entries` hold fewer usable entries than it did before. Instead of swapping
directories, write the new entry files into `loader/entries` one by one (each with a temporary name,
`fsync`, then a rename, which only touches one directory entry), `fsync` the directory, and only
then delete the entries that are no longer wanted:

```text
for each file in entries.staged: write entries/<name>.tmp, fsync, rename to entries/<name>
fsync entries/
for each file in entries/ not in entries.staged: unlink
fsync entries/; remove_dir_all entries.staged; fsync loader/
```

At every moment, `loader/entries` holds either the old set, or the old and the new entries together,
or the new set. With two entries for the same deployment sorted by `sort-key`, the boot loader
picks the new primary entry as soon as it is complete. A shorter fix: `fsync` (or `syncfs`) after
the exchange and before `remove_dir_all`. That narrows the window but does not close it, because
the exchange itself is still not atomic on FAT.

## Effect

No moment without a usable boot entry during finalization, on any file system. Filesystems where
`RENAME_EXCHANGE` is atomic (ext4 `/boot`) see no change in behaviour.
