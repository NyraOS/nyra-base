# bootc: mount the ESP with MS_DIRSYNC

Status: applied in nyra-base's bootc build (`ci/build-bootc.sh`), not sent upstream yet (an
upstream change needs the project's approval and a check that it does not break other
distributions).

Upstream: bootc-dev/bootc, checked at v1.16.13 (`fa0d3f9cb9a0ce3b4d1dc2607a0bf5e31b822f60`).

## What

On the composefs backend, bootc mounts the ESP itself (`mount_esp`, `mount_esp_writable`,
`mount_esp_at` in `crates/lib/src/bootc_composefs/boot.rs`) with `ESP_MOUNT_FLAGS`
(`MS_NOEXEC | MS_NOSUID`). Staging creates `loader/entries.staged` with `create_dir_all` and writes
the entries into it with `atomic_write` (temporary file, fsync, rename, fsync of the directory);
afterwards it fsyncs the ESP's top directory. At shutdown `bootc-finalize-staged` swaps
`loader/entries.staged` and `loader/entries` (`renameat2(RENAME_EXCHANGE)`), removes the old set
and fsyncs `loader`.

## Why it matters

The ESP is FAT, and Linux's FAT driver does not order directory changes unless the filesystem is
mounted with `MS_DIRSYNC`; `fsync` of a directory does not cover them all:

- `renameat2(RENAME_EXCHANGE)` only swaps the two inodes' positions in memory and marks both
  inodes dirty. Their entries in the parent are rewritten when those inodes are written back, not
  by `fsync` of the parent. At finalization, the removal of the old set and `fsync(loader)` put on
  disk the deletion of `entries.staged` and the freed clusters of the old set, while `entries` on
  disk still points at the old set's first cluster, now free. After a power cut, Linux reports
  `FAT-fs: corrupted directory (invalid entries)` when it looks up `loader/entries` and remounts the
  ESP read-only; bootc then fails with `Getting sorted Type1 boot entries: Input/output error`.
  `fsck.fat -a` (dosfstools 4.2) does not repair it: it sets the directory's start cluster to 0,
  which Linux still refuses.
- A new directory's first cluster (its `.` and `..`) is attached to the *parent* directory's
  buffers. `fsync` of the new directory writes its entry in the parent but not that cluster, and
  `fsync` of the ESP's top directory does not cover `loader`. After staging, `loader/entries.staged`
  can be on disk while its cluster still holds old data.

Reproduced in a VM (nyra-base `tools/titanic/power-cuts.sh`, power cuts at random moments of an
update): 3 of 5 cuts during the shutdown with the swap left the ESP in that state. Reproduced on a
loop device as well: the same sequence of calls (staging as bootc does, `sync`, then exchange,
`remove_dir_all`, `fsync(loader)`), with the image file copied right after it as the power cut,
fails every time without `dirsync` and never with it.

With `MS_DIRSYNC` the FAT driver writes every directory change (create, rename, exchange, unlink)
before the call returns, and a new directory's cluster before its entry in the parent.

## Proposed change

```diff
--- a/crates/lib/src/bootc_composefs/boot.rs
+++ b/crates/lib/src/bootc_composefs/boot.rs
@@
-/// Mount flags shared by all ESP mounts: non-executable, no setuid.
+/// Mount flags shared by all ESP mounts: non-executable, no setuid, and directory changes
+/// written synchronously (on FAT, a new directory's cluster is otherwise written independently
+/// of its entry in the parent, and a power cut can leave a directory without `.` and `..`).
 const ESP_MOUNT_FLAGS: MountFlags =
-    MountFlags::from_bits_retain(MountFlags::NOEXEC.bits() | MountFlags::NOSUID.bits());
+    MountFlags::from_bits_retain(
+        MountFlags::NOEXEC.bits() | MountFlags::NOSUID.bits() | MountFlags::DIRSYNC.bits(),
+    );
```

(`ci/build-bootc.sh` applies the same change with `sed`, without the comment.)

## Limits

This covers fresh mounts only. When the ESP is already mounted, bootc remounts the existing mount
(`mount_remount`) and then mounts the same device again, which shares the existing superblock: a
remount through `mount(2)` does not change `MS_DIRSYNC` (not part of `MS_RMT_MASK`), and the second
mount keeps the superblock's flags. nyra-base therefore also mounts `/boot` with `dirsync`
(`files/usr/lib/systemd/system/boot.mount.d/10-nyra.conf`). An upstream fix could pass `dirsync`
in the remount's data string instead, which the kernel applies as a superblock flag.

## Effect

No change in what bootc writes; directory operations on the ESP become synchronous (a few small
writes more per update).
