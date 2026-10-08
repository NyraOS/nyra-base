# Lessons: bootc on Debian

Technical findings from the prototype (VM tests, October 2026) that shape this recipe.
Each line is something that broke or surprised us once.

## Building
- **Build the base straight from a snapshot.** mkosi with `Snapshot=` installs every package from one
  `snapshot.debian.org` date. Building on top of the `debian:unstable` container image mixes package
  versions from different days, so the build is not reproducible.
- **Debian unstable has transitions.** On 2026-10-06 `libselinux1` was already 3.11 while
  `libselinux1-dev` was still 3.9: they could not be installed together. Our own tools (bootc) are
  therefore compiled on Debian testing, then copied into the unstable image. The binary only needs
  forward-compatible libraries (libselinux, libostree).
- **bootc needs `libclang`** to build (bindgen for the SELinux bindings), plus `libostree-dev`,
  `libselinux1-dev`, `libssl-dev`, `libzstd-dev`, `go-md2man`.
- **Strip bootc.** Debug info makes it ~378 MB; stripped it is ~40 MB.
- **mkosi installs only what is listed.** No `passwd`, `login`, `util-linux` unless named. The list in
  `mkosi/mkosi.conf` is the whole system.
- **mkosi removes the dpkg database** from the image. The package list for the SBOM and vulnerability
  scanning comes from `ManifestFormat=json` (exact versions).
- The mkosi container needs `python3-pefile`.
- At runtime bootc needs `ostree` and `zstd` in the image, or `bootc container lint` complains.
- **No SSH server in the shared base:** Debian's `openssh-server` generates host keys when it is
  installed, so they would end up in a public image. Enable SSH, with keys generated on the machine, in a
  layer that needs it.

## Configuration
- **Never configure through `/etc` in the image.** On an installed system `/etc` is kept across updates
  (three-way merge), so `systemctl disable` or a new preset in a later image changes nothing. Change
  behaviour with drop-ins in `/usr/lib/systemd/system/<unit>.d/`, for example `ConditionPathExists=`.
- **bootc's preset enables `bootc-fetch-apply-updates.timer`**, which reboots on its own after an update.
  It is blocked with a `/usr` drop-in. `xfs_healer@` (from `xfsprogs`) fails on a non-XFS root and is
  blocked the same way.

## Installing and booting
- `bootc install to-disk --composefs-backend --bootloader systemd` works on Debian: ESP + ext4 root with
  `verity`, systemd-boot, BLS entries, initramfs from dracut with the `bootc` module.
- **bootc does not write boot counting** (`+3`) into new entries, so automatic rollback is not active out
  of the box. Renaming the new entry to `…+3.conf` after `bootc-finalize-staged` makes systemd-boot fall
  back after three failed boots; `systemd-bless-boot` confirms good boots.
- bootc puts systemd-boot on the removable-media path too, so the machine boots after the EFI variables
  are reset; it does not create a firmware boot entry.
- After a soft reboot, boot counting is bypassed: a failing health check must trigger a full reboot.
- `bootc upgrade` hangs forever if the registry disappears mid-download: callers need a timeout.
- bootc has no downgrade protection: any correctly signed older image is accepted.
- Signature policy: cosign signs the repository name without a tag, so the policy must use
  `signedIdentity: matchRepository`.
