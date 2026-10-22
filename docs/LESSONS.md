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
- **Two builds of the same commit must give the same layers.** With the snapshot and
  `SOURCE_DATE_EPOCH` pinned (mkosi sets every mtime to it, `podman build --timestamp` too, dracut runs
  with `reproducible=yes`), two image builds on top of the same bootc binary differed in two files of
  mkosi's layer: `/var/log/alternatives.log` (update-alternatives writes the wall-clock time) and
  `/var/cache/ldconfig/aux-cache` (inode numbers and change times). `RemoveFiles=` in `mkosi.conf` drops
  them. The final file system did not even contain them (bootc's layout removes `/var`), but the layer
  digest still changed. The image workflow builds a second time on `main` and compares the layers
  (`ci/check-reproducible.sh`), which lists the differing files when it fails.
- **Two compiles of the same bootc commit must give the same binary.** They did not: zlink-macros 0.7.0
  (the varlink service macro behind cfsctl in bootc) emits the variants of a generated enum in `HashMap`
  order, and a proc macro's `HashMap` gets a new random seed in every compiler run, so the enum, and with
  it the code layout of `/usr/bin/bootc`, changed every time (the other two bootc binaries were
  identical). zlink-macros 0.7.1 uses a `BTreeMap`; `ci/build-bootc.sh` moves the zlink crates to 0.7.1
  until bootc's own Cargo.lock does (checked locally: eight expansions with 0.7.0 gave seven variant
  orders, with 0.7.1 one). The tar of the build is written with fixed order, times and owners. Release
  builds still compile bootc themselves, then compare the result with the cached build of the same key
  and fail on any difference. The image check above (`ci/check-reproducible.sh`) reuses one bootc build
  and runs on one runner, so it does not catch differences in bootc or ones that depend on the host.
- **Download once, then build without network.** The reproducibility check builds the image a second
  time with `--no-cache`, and cargo downloaded nyra-updated's crates from crates.io again, two minutes
  after the first build: a 17 s network outage on the runner outlasted cargo's 3 retries (about 10 s
  per request) and failed the job before any test. `ci/build-image.sh` now fetches the crates once
  (`cargo fetch --locked`, 10 retries: over a minute per request), and both builds compile them in a
  `RUN --network=none` step from that directory, mounted read-only.
- **An offline cargo build trusts its cache and its index.** Cargo checks a crate against `Cargo.lock`
  only when it downloads it: a `.crate` already in its cache is used as it is (checked: one with a
  changed file compiled without a word), and the unpacked `registry/src` is not checked at all. The
  features of a crate come from the registry index, which `Cargo.lock` does not pin: with `default`
  emptied in libc's index entry, the build passed and the binary changed. Checking the `.crate` files
  with `sha256sum` is not enough either if the check and cargo can look at different directories (a
  second cache directory, checked instead of cargo's). So the `Containerfile` uses neither: it copies
  each `.crate` that `Cargo.lock` lists, checks the copy against the lock's checksum, unpacks it into a
  cargo directory source (`replace-with` for crates.io), and fails unless the context has exactly one
  cache directory. The same edited index then gives the same binary; a changed or missing crate fails
  the build. The binary differs from an online build only in the source paths in panic messages.
- **Strip bootc.** Debug info makes it ~378 MB; stripped it is ~40 MB.
- **mkosi installs only what is listed.** No `passwd`, `login`, `util-linux` unless named. The list in
  `mkosi/mkosi.conf` is the whole system.
- **mkosi removes the dpkg database** from the image. The package list for the SBOM and vulnerability
  scanning comes from `ManifestFormat=json` (exact versions).
- The mkosi manifest names binary packages only (name, version, architecture). Vulnerability data
  (Debian Security Tracker, OSV) is keyed by source package and source version, which differ for
  binNMUs (`libbz2-1.0 1.0.8-6+b2` comes from `bzip2 1.0.8-6`). The snapshot's `Packages` index maps one
  to the other (`docs/SBOM.md`).
- The Debian Security Tracker JSON has no CVSS scores, and its urgency is `not yet assigned` for most
  CVEs. OSV's `DEBIAN-CVE-*` records carry the CVSS vectors (v3 or v4) but cover Debian releases, not
  `sid`: querying OSV with a `sid` version matches open ranges of older releases. So the tracker says
  whether `sid` is affected and OSV says how badly.
- **Pick a snapshot by the amd64 `Packages` index, not by the source upload.** A fixed source can be
  on `snapshot.debian.org` hours before its amd64 build (podman 5.8.6+ds1-3: source and most
  architectures at `20261012T023456Z`, amd64 only at `20261012T082414Z`). Check the version in the
  snapshot's `dists/unstable/main/binary-amd64/Packages.xz` (its hash is in the signed InRelease), or
  ask `snapshot.debian.org/mr/package/<src>/<ver>/binfiles/<bin>/<ver>?fileinfo=1` for the amd64
  `first_seen`.
- **The kernel arrives in two steps.** The `linux` source builds the modules; the image
  (`linux-image-amd64`, `linux-image-<abi>`, `linux-binary-<abi>`) comes from `linux-signed-amd64`,
  which follows later (linux 7.2.11-1: modules at `20261015T205142Z`, signed image at
  `20261016T023245Z`). Check `linux-image-amd64` in the `Packages` index, not the `linux` upload.
- The mkosi container needs `python3-pefile`.
- **apt only warns on a suite mismatch.** A correctly signed InRelease for another suite (unstable
  served where testing was asked) is accepted with `W: Conflicting distribution`. `ci/tools.Containerfile`
  fetches over http, so it checks the InRelease `Suite` and `Date` itself; mkosi fetches the snapshot
  over https (`snapshot.debian.org`), where a network attacker cannot swap files.
- At runtime bootc needs `ostree` and `zstd` in the image, or `bootc container lint` complains.
- **SSH host keys never go in the image, not even in a hidden layer.** Debian's `openssh-server`
  generates host keys when it is installed, so they would end up in a public image, the same on every
  machine. Removing them in the Containerfile is not enough: a `RUN rm` only adds whiteouts in a
  later layer, and the keys stay in the mkosi layer for whoever pulls the image. mkosi removes them
  (`RemoveFiles=`), the Containerfile only checks, and CI reads every layer of the exported image
  (`ci/no-host-keys.py`). The same holds for any secret a package script makes. `sshd-keygen.service`
  makes the keys on the machine; Debian's runs on the first boot only (`ConditionFirstBoot=yes`): SSH
  turned on later would start without keys, so a drop-in resets its conditions.
- **Installing sshd turns on systemd's SSH sockets.** `systemd-ssh-generator` (systemd 256 and later)
  writes `sshd-unix-local.socket` at every boot once an sshd binary is there, `sshd-vsock.socket` in a
  VM, and `sshd-extra-N.socket` for each `systemd.ssh_listen=` or `ssh.listen` credential: names a
  drop-in cannot all cover. The base removes the generator (docs/DEFAULTS.md, "SSH").
- **Package tmpfiles lines can touch `/usr`.** openssh-client's `z /usr/bin/ssh-agent 2755 root _ssh`
  would change a file in the read-only `/usr` at every boot; such a line goes from the image (its
  effect is set at build time, or not at all).

## Configuration
- **Never configure through `/etc` in the image.** On an installed system `/etc` is kept across updates
  (three-way merge), so `systemctl disable` or a new preset in a later image changes nothing. Change
  behaviour with drop-ins in `/usr/lib/systemd/system/<unit>.d/`, for example `ConditionPathExists=`.
- **bootc's preset enables `bootc-fetch-apply-updates.timer`**, which reboots on its own after an update.
  It is blocked with a `/usr` drop-in. `xfs_healer@` (from `xfsprogs`) fails on a non-XFS root and is
  blocked the same way.
- **A blocked unit still pulls in what it wants.** A condition only stops the unit itself: Debian
  enables `podman-restart.service` and `podman-auto-update.service` in `default.target`, and though
  both were blocked, their `Wants=network-online.target` started `systemd-networkd-wait-online` at
  every boot. Without a network it fails after 2 minutes (`degraded`), and `graphical.target`, ordered
  after them, waits those 2 minutes. Such a unit is disabled too, with a `disable` line in our preset:
  systemd applies the presets again at the first boot, and a unit no preset line names is enabled
  then, so a `systemctl disable` in the image build alone would not last.
- **`network-online.target` stays reached for the whole boot.** Once
  `systemd-networkd-wait-online.service` has passed, it stays active, so a later wait for the network
  (an update check after the link was lost) does not wait. A unit that needs the network each time
  runs `systemd-networkd-wait-online` itself, in a oneshot without `RemainAfterExit=`.
- **A drop-in cannot remove a dependency.** `OnFailure=` (empty) in a `local-fs.target.d` drop-in leaves
  `OnFailure=emergency.target` in place (checked with systemd 262): a dependency goes away only with
  the unit file itself, so the image build edits `local-fs.target`. `OnFailureJobMode=fail` is no way
  around it: emergency mode still starts, next to the boot (its conflicting stop jobs are dropped "to
  minimize impact"), as seen when the "Reset settings" question came mixed with the emergency shell.
- **Without `OnFailure=`, `local-fs.target` is no longer a barrier.** A mount that fails at once (a
  wrong option) fails the target's job at once, and every unit ordered only `After=local-fs.target`
  starts while the other local mounts are still pending. In CI `systemd-boot-random-seed` (through
  `esp-writable`) mounted the ESP read-write while its fsck ran, and `boot.mount` failed once. A unit
  that needs a mount is ordered after that mount itself (`After=boot.mount`, `RequiresMountsFor=`);
  the same holds for the boot's tmpfiles and `/tmp` (`After=tmp.mount`).
- **dracut copies a unit's drop-ins only when its module lists them**, but it copies every
  `/usr/lib/systemd/system.conf.d/*.conf`. `DefaultDeviceTimeoutSec=` there would also shorten the
  initramfs's wait for the root disk; a prefix drop-in for device units (`dev-.device.d/`, which
  systemd applies to every `dev-*.device`) stays in the running system. The image build checks it with
  `lsinitrd`.
- **bootc does not see boot counting.** It orders the boot entries by sort key, so after systemd-boot
  fell back from a version with no tries left (`+0-3`), `bootc status` still has that version first
  (`rollbackQueued: true`), and `bootc rollback` then puts the running version first (seen in CI).
- **bootc keeps one `/etc` per deployment.** A version fallen back from keeps the `/etc` it was
  finalized with: repairing the running system's settings does not reach it, and booting it again
  (`bootc rollback`) brings the broken settings back (seen in CI). To try it with today's settings,
  delete it (`bootc delete-deployment <composefs digest>`, a hidden command in bootc 1.16) and stage
  it again: bootc does not stage an image that already has a deployment ("No changes").
- **A failed health check does not say whether the version or the settings are broken.** A deleted
  system account (`messagebus`, `systemd-network`) or a masked service fails the core services after
  the next boot, whichever version boots. Settings changed after an update was staged therefore fail
  the new version's tries, and the fallback finds the same `/etc`. What tells them apart is the
  older version: if it fails too, the settings are to blame (docs/UPDATES.md, "The version or the
  settings").
- **Account names are lookups in `/etc`** (`nsswitch.conf` has only `files`): with a broken
  `/etc/passwd`, `setpriv --reuid=nobody` fails ("failed to parse reuid: 'nobody'"). Code that must
  work then, recovery above all, gives IDs by number (65534 for `nobody` and `nogroup`).
- **A message on the text console without touching `/etc`:** agetty (util-linux 2.42) reads issue
  drop-ins from `/etc/issue.d`, `/run/issue.d` and `/usr/lib/issue.d` (`*.issue`), and `agetty
  --reload` makes the ones already at the login prompt show it again; Debian's `pam_motd` reads
  `/run/motd.d` after a login.
- **agetty always shows `/etc/issue` when there is one.** util-linux 2.42 (the image's) takes the
  first of `/etc/issue`, `/run/issue`, `/usr/lib/issue` as the main file, so `/usr/lib/issue` never
  shows next to an `/etc/issue`; the drop-ins of all three `issue.d` directories show after it.
- **Removing a file from the image's `/etc` is not enough when tmpfiles makes it again.** With
  Debian's `/etc/issue` gone, the first boot had one anyway: systemd's `C! /etc/issue`
  (`/usr/lib/tmpfiles.d/debian.conf`) copies `/usr/share/factory/etc/issue` there whenever it is
  missing. A `C` line whose source is missing is skipped, so the image removes the factory file
  too. Check `systemd-tmpfiles --cat-config` for the path before relying on its absence.
- **bootc's title for a UKI's boot entry is `PRETTY_NAME` and then `VERSION_ID`** (composefs-boot,
  from the UKI's `.osrel`; `VERSION` when there is no `VERSION_ID`), and the entry's version and file
  name come from the same field (the composefs digest without either). A `PRETTY_NAME` that carries
  the version needs neither: no `VERSION_ID`, and no `VERSION=` either.
- **The image had `/etc/os-release` as a copy of `/usr/lib/os-release`** (a file, not Debian's link):
  replacing only `/usr/lib/os-release` would leave the old name in the file programs read first.
- **A disk in `/etc/fstab` without `nofail`** that is not connected cost 90 s and then emergency mode,
  with root locked: no way out but the boot menu (Titanic T8). The "Reset settings" profile was hit too,
  since `/etc/fstab` is read on every boot; it has `fstab=no` now (docs/BOOT.md, "Mounts from
  /etc/fstab").

## Shutdown
- **A console login could hold the shutdown for 90 s** (about one power-off in ten in CI). After
  `systemctl poweroff` typed on the console, bash (5.3, readline 8.3) prints its next prompt while
  systemd stops the getty unit and sends SIGTERM and SIGHUP. When the SIGHUP lands while readline
  sets up the terminal (`tcsetattr(TCSADRAIN)` waits for the console output to drain, which takes
  long while the shutdown messages go to the same serial console), bash only records it and then
  waits for input in `pselect` with no signal pending; `login` waits for bash. systemd kills both at
  the stop timeout. A lost signal cannot be sent again from a unit setting, but a hung-up TTY stays
  hung up: every later read returns end of file. systemd hangs up a unit's TTY (`TTYVHangup=yes`)
  before it runs any of the unit's commands, so a no-op `ExecStop=` in `nyra-tty-hangup@<tty>`
  (wanted by `getty@` and `serial-getty@`, ordered after them, so stopped first) hangs the console
  up before the getty's kill signal. It hits anyone who shuts down from a text console, not only the
  tests (a shell in a terminal window gets end of file when the window closes).
- **Every command of a `Type=idle` unit waits for the job queue**, `ExecStop=` too, for up to 5 s
  (`IDLE_TIMEOUT_USEC`), and during a shutdown the queue is never empty. The getty units are
  `Type=idle` (their prompt should not mix with boot messages), so the first version of the hangup,
  an `ExecStop=` in the getty units themselves, made every power-off about 5.5 s longer.
- **`RequiresMountsFor=` adds `Requires=` only when the mount has a unit file**; otherwise only
  `After=`. bootc's `/var` is a bind mount set up in the initrd, with no unit file, so nothing stopped
  `systemd-journal-flush.service` at shutdown: journald was never told to leave `/var`
  (`journalctl --smart-relinquish-var`), kept its files there open, and every power-off printed
  `Failed unmounting var.mount` (systemd-shutdown then killed journald and unmounted it). A drop-in adds
  `Requires=var.mount`; `vm-boot.py --poweroff` now fails on any `Failed unmounting` and on a shutdown
  longer than 60 s.
- To see a shutdown from the inside: `systemd-analyze log-target kmsg` before `systemctl poweroff`
  puts systemd's own messages (`State 'stop-sigterm' timed out`, `Killing process N (bash)`) on the
  serial console with timestamps, and a transient unit started with `systemd-run -p
  DefaultDependencies=no` is not stopped by the shutdown, so it can write `/proc/<pid>/status`
  (pending, blocked, caught signals), `wchan`, `stack` and open files of the remaining processes to
  `/dev/kmsg` while the stop job waits.

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
- containers/image (bootc, podman, skopeo) checks a keyless (Fulcio) signature only by OIDC issuer
  and **e-mail** address. GitHub Actions certificates name the workflow as a URI, which it cannot
  match (containers/image#2350), so we sign as a Google service account (`docs/SIGNING.md`).
- It also needs the Rekor v1 SET inside the old cosign signature format; cosign 3 must be told
  `--new-bundle-format=false --use-signing-config=false`.
- The bootc image has an empty `/var` (tmpfiles fills it at boot): running the image's own tools
  in a container (skopeo unpacking an oci-archive) needs `--tmpfs /var/tmp`.
- In the initrd, `/dev/gpt-auto-root` hangs on one read of `LoaderDevicePartUUID`, made by udev's
  probe of the whole boot disk. If it fails, systemd 262 never probes again and the initrd waits 90 s,
  then emergency mode. Recognize it in the diagnostics: the disk without `ID_PART_GPT_AUTO_ROOT_DISK`,
  the root partition without `ID_PART_GPT_AUTO_ROOT=1`. The image probes such a disk once more
  (docs/BOOT.md, "Finding the root partition").
- udev's `blkid` builtin runs once per event: a second `IMPORT{builtin}="blkid"` in the same event
  returns the first result. Probing again needs a new event (`udevadm trigger --action=change`).
- systemd-udevd has its own mount namespace and a system call filter without `@mount`: a test rule
  that mounts needs a drop-in with `SystemCallFilter=`, and what it mounts only udev sees.

## Boot chain (docs/BOOT.md)
- Debian ships the signed boot binaries as packages: `shim-signed` (signed by both the Microsoft UEFI
  CA 2011 and 2023; depends on `systemd-boot` as an alternative to GRUB) and
  `systemd-boot-efi-amd64-signed`. `bootctl install` picks `systemd-boot*.efi.signed` over the
  unsigned file by itself.
- bootc's systemd-boot install does not place shim. shim on the removable-media path
  (`\EFI\BOOT\BOOTX64.EFI`) starts `grubx64.efi` from its own directory; without `fbx64.efi` next to
  it, it does not run the fallback that creates firmware entries.
- systemd-boot loads images through shim's verification, so a key in the MOK list is enough for a
  UKI; firmware `db` is not needed. A refused UKI shows `Error loading EFI binary …: Security
  violation`, then shim starts MokManager (10 s countdown) before the firmware moves on.
- For tests, a MOK can be written straight into the OVMF variables (`virt-fw-vars --add-mok`), no
  MokManager interaction. The Secure Boot OVMF needs `-machine smm=on` and a secure pflash.
- With Secure Boot on and a `.cmdline` in the UKI, systemd-stub ignores the command line the boot
  loader passes (entry `options`, the menu editor).
- With Type #1 entries and Secure Boot on, shim accepts Debian's signed kernel, but the initramfs and
  the command line are not verified at all.
- systemd-boot reads its settings only from the ESP (`loader/loader.conf`), the editor is on by
  default, and `bootctl install` writes the file (only if it is missing) without `editor no`.
- bootc (composefs) writes a staged version's entries to `loader/entries.staged` when it stages it and
  swaps the directory in at shutdown. Adding the boot counter there, before the swap, makes it atomic
  with the entry. bootc reads entries by content and sort key, so the `+N-M` suffix does not confuse it.
- systemd-gpt-auto-generator mounts the ESP at `/boot` on access (an automount that unmounts after
  two idle minutes, and cannot be triggered once the shutdown transaction is queued). It is mounted
  far more often than it looks: `systemd-boot-update.service` at every boot, any `bootctl` call
  (`set-oneshot` too), `systemd-bless-boot`. In Titanic T12 it was already mounted read-write when
  `rm -rf --no-preserve-root /` ran, and the delete removed every boot file. Whether the ESP happens
  to be mounted at that moment must not matter: Nyra blocks the automount and keeps the ESP mounted
  read-only from the start of the boot (docs/BOOT.md, "The ESP is read-only").
- The generator writes its units to `/run/systemd/generator.late`, below `/usr/lib/systemd/system`:
  drop-ins in `/usr` apply to them (`Options=`, a `ConditionPathExists=` that blocks the automount),
  and `Wants=boot.mount` from `local-fs.target` mounts the ESP without the automount.
- Read-only is a flag of the superblock and of each mount. A remount of an existing mount
  (`mount -o remount,rw`, not a bind remount) inside a mount namespace of its own makes the
  superblock writable and that one mount, while the same file system stays read-only through every
  other mount of it. A second, fresh mount of the device with the other read-only state fails with
  `EBUSY` ("Can't mount, would change RO state"): remount what is mounted, mount the device only when
  it is not. bootc does the same for the ESP (`mount_esp_writable`).
- `mount -o remount,rw /boot` (util-linux 2.41, new mount API) failed on the ESP with "mount point not
  mounted or bad option": it takes the mount's current options (`dirsync` among them) to the
  superblock reconfiguration, which accepts only the flags a remount may change. The classic
  `mount(2)` remount ignores `dirsync` instead: `LIBMOUNT_FORCE_MOUNT2=always mount
  --options-source=disable -o remount,rw,…`.
- `/usr/bin/awk` is a Debian alternatives link (`/usr/bin/awk` -> `/etc/alternatives/awk` ->
  `/usr/bin/mawk`): with `/etc` emptied (Titanic T12) or broken, `awk` is "not found" although `/usr`
  is intact. What must work with a broken `/etc` (`reset-settings`, `esp-sync`) calls `mawk`.
- efivarfs lets root delete the standard firmware variables (`Boot####`, `BootOrder`); the others
  (systemd-boot's `LoaderEntryOneShot`, for example) are created immutable and survive `rm -rf /`.
  Without `BootOrder`, OVMF boots the disk's fallback path (`\EFI\BOOT\BOOTX64.EFI`).
- `systemctl is-enabled` reports `disabled` for units enabled only through `/usr/lib/systemd/system/*.wants/`
  links, although systemd starts them: do not use it to check vendor enablement.
- Debian's kernel packages now put `vmlinuz` in `/usr/lib/modules/<kver>/`; the signed image is in
  `linux-binary-<kver>`, `linux-image-<kver>` is only a metapackage.

- **Boot protection (seen in CI, OVMF):** a firmware entry whose file is missing, or whose shim
  cannot start a damaged `grubx64.efi`, makes the firmware try the next entry in `BootOrder`; the
  automatic disk entry then starts the fallback path (`\EFI\BOOT\BOOTX64.EFI`). The firmware's own
  `UiApp` entry is in `BootOrder` but is never started automatically. A damaged first choice costs
  about 4 s. shim starts `grubx64.efi` from its own directory, and systemd-boot reports that path in
  `LoaderImageIdentifier`, which is how a test tells which copy booted.
- Boot binaries on the ESP are compared by the Debian line of their SBAT section, which `grep -a` reads
  straight from the PE file (`shim.debian,1,Debian,shim,16.1,…`; systemd-boot's vendor field is
  "Debian GNU/Linux", not "Debian"). Never write an older boot loader over a newer one: the newer one
  may be there because of a revocation.
- `systemd-bless-boot status` after a soft reboot describes the last full boot, which may have been
  another system version: check `systemctl show -P SoftRebootsCount` before trusting it.
- systemd mounts the ESP with `fmask=0177,dmask=0077`: only root can read it, and no file on it is
  executable.
- Linux's FAT driver does not order directory changes, and `fsync` of a directory does not cover
  them all. `rename(RENAME_EXCHANGE)` only marks the two moved inodes dirty: their entries in the
  parent are written when *those* inodes are written back, not by `fsync` of the parent. So
  bootc-finalize-staged's swap, removal of the old set and `fsync(loader)` put on disk the removal
  and the freed cluster, but not the swap: after a power cut `loader/entries` points at a free
  cluster (seen in CI: 3 of 5 cuts during the shutdown with the swap; reproduced with a loop
  device). Likewise a new directory's first cluster (`.` and `..`) is a buffer of the parent, which
  `fsync` of the new directory does not write. Linux then reports "FAT-fs: corrupted directory
  (invalid entries)" and sets the ESP read-only; every later update fails.
- `fsck.fat -a` (dosfstools 4.2) does not repair that: for a directory whose first cluster is free
  it prints "Contains a free cluster … Assuming EOF" and sets the directory's start cluster to 0,
  which Linux still refuses as a corrupted directory.
- Only a `dirsync` mount orders it (each directory change is written before the call returns, a new
  directory's cluster before its entry in the parent). A remount through `mount(2)` does not change
  `dirsync` (it is not among the flags a remount applies), and a second mount of the same device
  keeps the first one's superblock flags: the first mount has to be `dirsync`.
- `fsck.fat` (dosfstools 4.2) exits 1 for any damage it finds, even when it cannot read the boot
  sector at all ("Logical sector size is zero"), and 6 only when it cannot open the device.
  `systemd-fsck` takes 1 as "errors corrected": a damaged ESP usually passes its check, and it is the
  mount that fails. A unit that needs the ESP checked waits for `boot.mount`, not for its fsck.
- `findmnt -t vfat` (util-linux 2.41) exits 0 when nothing matches, as long as no mount point is
  given: test its output (`test -z "$(findmnt -n -t vfat)"`), or name the target (`findmnt -t vfat /boot`).
- `efibootmgr -c` puts the new entry first in `BootOrder`. Entries are matched by label, partition
  UUID and path, so an old "Nyra OS" entry for another disk is replaced, not reused.

- **Multi-profile UKI (systemd 262, from the sources):** a Type #1 entry selects a profile with
  `profile N`; systemd-boot passes `@N` in front of the options, and systemd-stub takes the profile
  from it even under Secure Boot, when it ignores the rest of the command line. A profile's
  `.cmdline` replaces the base one, it does not append. systemd-boot never picks a profile above 0 as
  the default. With `--join-profile`, ukify ends the base sections with a `.profile` section of its
  own (`ID=main` if `--profile` is not given), which becomes profile 0: joining a separate "main"
  profile as well would shift recovery to profile 2. Label the base with `--profile` and join only
  the extra profiles.
- **bootc 1.16 reads every `*.conf` in `loader/entries`** as one of its deployments (status, rollback
  detection, garbage collection). An extra entry for a bootc UKI showed up in CI as a second "other
  deployment" in `bootc status --booted`, and one for any other file makes bootc fail (no `version`, or
  no `bootc_composefs-<digest>` in the path). bootc matches `.conf` in lower case, systemd-boot and
  `bootctl` in any case: an entry named `*.CONF` is in the boot menu and invisible to bootc. systemd-boot
  reports its ID in lower case (`LoaderEntrySelected` = `nyra-recovery.conf`); `bootctl set-oneshot`
  takes either.

- **The image's own `/etc` on a running system:** bootc bind-mounts the version's state directory on
  `/etc`; a bind mount of `/` alone (not recursive) shows the image's `/etc` under it.
- **Swapping two directories in one step:** `mv -T --exchange A B` (coreutils 9.5 and later,
  `renameat2` with `RENAME_EXCHANGE`). Without `-T`, mv moves A into B when B is a directory.
  util-linux's `exch` does the same, but its package (util-linux-extra) also installs `newgrp` setuid
  root: CI now fails when the image gains a setuid or setgid file not listed in `ci/setuid.txt`.
- A check whose list is empty (`ci/capabilities.txt`) never shows that it can fail. The build job
  runs it once more on a container of the image (`podman mount`) with one file given
  `cap_net_raw+ep` by the host's `setcap`, and requires exactly that error. Both checks read the
  mounted root filesystem from the host, so the same code runs on the image and on the control.
- A service with `StandardOutput=inherit` on the console (a prompt that needs the console at once)
  writes nothing to the journal: check its effects, not its log, in tests.
- **One UKI profile can serve two boot menu entries.** An entry only picks the profile, and
  systemd-boot puts the ID of the entry it started in `LoaderEntrySelected`, which the booted system
  reads. A second action on the same sealed command line (Restore earlier settings next to Reset
  settings) needs no new profile, so no new PCR 11 value, no new sealed command line and no change
  to the signed policy. Which entry was picked grants nothing: both are in the same menu.
- systemd-boot orders entries by `sort-key` first: numbered keys (`nyra-1-recovery`,
  `nyra-2-restore`, `nyra-3-reset`) keep our entries in the order we want, after bootc's
  (`bootc-…`); with names alone, `nyra-reset` would sort before `nyra-restore`.
- A timer that runs at boot (`Persistent=true`) sees the hardware clock, which may be years off until
  chronyd corrects it, and `time-sync.target` does not wait for chronyd here (`chrony-wait` is off).
  Anything that deletes by date must not trust that clock: count back from the newest existing item
  not in the future, and remove future-dated ones only once `NTPSynchronized` is `yes`.
- **A copy of `/etc` on ext4:** the image's `/etc` is 971 files and 734 KiB of data, but 2.9 MiB on
  disk, since each small file takes a 4 KiB block. On a booted system it was 16 MiB:
  `systemd-hwdb-update.service` writes udev's 14 MB `hwdb.bin` to `/etc/udev` at the first boot
  when the image has no `/usr/lib/udev/hwdb.bin`. `systemd-hwdb update --usr` in the image build
  puts it there instead (the same bytes on every build); the service then writes `/etc` only when
  the user adds rules in `/etc/udev/hwdb.d`. coreutils 9 `cp` reflinks by default
  (`--reflink=auto`), which would make copies nearly free on btrfs or XFS, not on ext4.
- **A whole copy of `/etc` restored on a newer version brings back the older version's defaults**
  (Debian's files there, such as AppArmor's and PAM's), and bootc's merge then keeps them as the
  user's changes. Keeping only what differs from the image's `/etc`, plus the list of what was
  deleted, and laying that over the running version's `/etc` avoids it, and the copy shrinks from
  about 3 MiB to tens of KiB.
- **Comparing two files with their ACLs and extended attributes without `getfattr`:** archive each as
  a one-member tar (`--no-recursion --format=posix --numeric-owner --acls --xattrs
  --xattrs-include='*' --mtime=@0 --pax-option=delete=atime,delete=ctime`) and compare the bytes:
  without the `delete`, equal files give different archives. Older GNU tars put their PID in the
  extended header name (`PaxHeaders.<pid>`); 1.35's default, `%d/PaxHeaders/%f`, does not. In GNU
  tar 1.35, `--xattrs-include` alone already turns on `--xattrs`.
- **GNU `cp -a` writes a file through a link at the destination** (it refuses only a dangling link,
  and a directory over a link), and `cp -a SRC/. DST/` gives an existing `DST` directory (and every
  existing directory under it) the source's mode and owner. Laying one tree over another therefore
  first removes, parents first, whatever is at each path the source has, unless both are
  directories; otherwise a link in the destination can lead the copy outside.

## Secure defaults (docs/DEFAULTS.md)
- Debian packages enable their units in maintainer scripts, which mkosi runs: the base came up with
  podman's root API (`podman.socket` and `podman.service` started at boot), `podman-auto-update.timer`,
  netavark's DHCP proxy, `dpkg-db-backup.timer` (no dpkg database to back up), e2scrub (no LVM) and
  `nftables.service`. The boot log on the serial console (`Started …`, `Listening on …`, `Finished …`)
  lists them; a `ConditionPathExists=` drop-in in `/usr` blocks them.
- Debian's `nftables.service` loads `/etc/nftables.conf`, which starts with `flush ruleset`. Next to
  another ruleset loaded before `network-pre.target`, the order between the two is a race: block it
  and order our unit after it.
- systemd-networkd with DHCP leaves no socket in `ss -tuln` once it has a lease: in the base only
  resolved's stub listens.
- `blacklist` in modprobe.d also stops the load that `mount` asks for through the `fs-<type>` alias
  (the kernel logs `request_module fs-f2fs succeeded, but still no fs?`); `modprobe <name>` still works.
- A guest command in `vm-boot.py` passes on the status of its last command, and the guest shell has
  no `set -e` or `pipefail`: a `for` loop reports only its last iteration, and `x="$(cmd | awk …)"`
  hides a failing `cmd`. Join checks with `&&`, set a flag in loops, require non-empty input
  (`tools/vm/security-defaults.sh --self-test` covers this with stubs).
- Unblocking a socket or timer without its service does not work: the trigger keeps hitting the
  blocked service until systemd's trigger limit fails the socket.
- A firewall test inside the VM that connects to the machine's own address proves nothing: that
  traffic goes through loopback. A network namespace joined by a veth pair is outside the host's
  addresses, so its connection meets the input chain like traffic from the LAN.
- Under Secure Boot with a UKI, the kernel command line is the one inside the UKI: arguments from
  `/usr/lib/bootc/kargs.d` reach Type #1 entries (bootc install, updates), not a hand-built UKI.
- mkosi runs `systemctl preset-all` after installing the packages, and Debian ships no
  `disable *` preset: every unit with an `[Install]` section ends up enabled, conflicting ones too
  (`chrony.service` and `chronyd-restricted.service`, plus `chrony-wait.service`). On a first boot
  systemd applies the presets again (enable only), so a unit that must stay off needs a `disable`
  line in a preset in `/usr/lib/systemd/system-preset/`; a `systemctl disable` alone in the build
  could be undone.
  A `ConditionPathExists=` block does not help against `Conflicts=`: the start jobs of both units
  are already in the same transaction.
- `systemd-timedated` takes the time service from `ntp-units.d/*.list` (the first loadable unit of
  the lists in name order), not from what is enabled: with only chrony's `50-chrony.list` it reported
  NTP off next to a running `chronyd-restricted`, and `timedatectl set-ntp true` enabled
  `chrony.service`, whose alias then made `chronyd-restricted` stop. A list of our own that sorts
  first (`10-nyra.list`) points it at the unit we ship.
- Debian's AppArmor profile for `chronyd` allows reading `/etc/chrony/**` and, through
  `abstractions/base`, everything under `/usr/lib`: a configuration in `/usr/lib/nyra/chrony/` is
  readable, one in `/usr/share/` would not be.
- `chronyd -U` (Debian's `chronyd-restricted.service`) runs without root, so it cannot bind the
  command port (UDP 323): set `cmdport 0`; `chronyc` as root uses the Unix socket.
  `chrony-wait.service` asks over `127.0.0.1` and therefore cannot work with it.
- NTS-KE checks the certificate dates with the local clock: with the clock in 2035 both
  `time.cloudflare.com` and `nts.netnod.se` were refused as expired, so NTS alone can never correct
  a clock that is far off. chrony's `nocerttimecheck 1` lifts only the date check, until the first
  clock update (Debian's configuration does not set it); ntpd-rs needs our patch (docs/DEFAULTS.md,
  "Time").
- chrony names its saved NTS cookies after the server's IP address (`ntsdumpdir`): a name that
  resolves to another address starts with a new key exchange.
- Without an audit daemon the kernel prints every audit record (`audit: type=1334 ... op=LOAD`,
  `type=1130 ... unit=...`) through printk, at "notice", even while systemd-journald collects the
  same records from `systemd-journald-audit.socket`: journald only listens to the records, it does
  not register as the audit daemon, and the kernel prints whenever no daemon is registered
  (`kauditd_hold_skb` in `kernel/audit.c`). The summary of the rate limit (`kauditd_printk_skb: N
  callbacks suppressed`) is a "warning" (`lib/ratelimit.c`), so a console threshold that still shows
  warnings still shows that line: the image shows errors only (`kernel.printk = 4 4 1 7`, the
  threshold of `quiet`). There is one threshold for all consoles; the kernel log and the journal
  keep everything.
- Since that threshold, the serial logs of the VM tests show the kernel's own lines only up to the
  initrd's `systemd-sysctl` (about a second into the initrd), then errors only; the rest is in the
  journal (`journalctl -k`). Each boot starts at the kernel's default again, so `Linux version`
  still marks every kernel start, and `reboot: Restarting system` is an emergency message. For a
  run that needs all kernel lines on the serial log (timestamps of a flaky boot), pass
  `--credential 'sysctl.extra=kernel.printk = 7 4 1 7'` to `vm-boot.py`: the test console imports
  credentials, the image does not.

## Rust components (docs/DEFAULTS.md)

- sudo-rs's `su` (0.2.15) asks for the password up to three times, also when its input is not a
  terminal; with the password on its input and nothing after it, the second read ends the attempt.
  It also refuses a calling UID that has no `/etc/passwd` line ("user 'current user' not found"),
  where util-linux's `su` only needs the target account.
- zlib-rs as `libz.so.1`: a cdylib from `cargo build` has no soname and no symbol versions, and
  programs linked against zlib ask for versioned symbols (`deflateBound@ZLIB_1.2.0`). zlib-rs's way
  is a static library linked with `cc -shared` and zlib's version script (`--undefined-version`, since
  the script names functions the build leaves out). Its `gzprintf` feature needs a nightly compiler
  (`c_variadic`); a stable build simply lacks `gzprintf` and `gzvprintf`.
- uutils (coreutils 0.12.0, findutils 0.10.0, diffutils 0.5.0) differs from GNU where it is not
  obvious: `find -newermt` refuses every date form (dracut's `clamp_mtimes` relies on `@SECONDS`),
  `find -printf %m` prints the mode without the setuid, setgid and sticky bits, and `diff` has no
  `-r`. Compare a command's output with GNU's on the same input before relying on it; a listing made
  with uutils `find` can hide a difference of `cp` (it looked as if `cp -a` dropped the setgid bit).
- uutils `od -j N` skips by the size `stat` reports, also on its standard input, and fails ("cannot
  skip past end of combined input") where that size is smaller than the content: procfs files, and
  efivarfs in the initrd, where the TPM enrollment read `SecureBoot` as missing and gave up ("Secure
  Boot is off"). GNU reads to skip. `od -N 5` and the fifth number, or a pipe, work with both.
- A Rust program started with fd 0, 1 or 2 closed reopens it on `/dev/null`, and aborts (SIGABRT)
  when it cannot: with `/dev/null` gone (`rm -rf /` in Titanic T12), uutils' `sha256sum` died at
  once. GNU xargs starts its command with standard input closed when it cannot open `/dev/null`, so
  `find | xargs -0 sha256sum` hashed nothing and printed the hash of an empty input, which looked
  like a changed `/usr`. `find -exec cmd {} +` passes the shell's own descriptors; `set -o pipefail`
  inside the command substitution turns such a failure into a failed check instead of a wrong hash.
- GNU strings are no test for GNU binaries: uutils' multi-call binary contains "GNU coreutils" too.
- ntpd-rs (1.9.0) checks NTS-KE certificates with rustls against the system clock and has no option
  to skip the dates, so it cannot correct a clock outside their validity by itself. libfaketime
  (`FAKETIME=@2035-06-01 00:00:00`) with `ntp-ctl force-sync` shows it without root: `ExpiredContext`
  on every key exchange.
- rustls passes the time to the certificate verifier (`verify_server_cert(..., now)`), so the same
  verifier checks a chain at any other time; the handshake signature (`verify_tls13_signature`) does
  not depend on the time, and the connection keeps the chain (`peer_certificates()`). That is how our
  ntpd-rs patch checks a certificate at the time the server gives.
- ntp-daemon (1.9.0) opens a netlink socket at startup (the machine's addresses and their changes):
  with `RestrictAddressFamilies=` without `AF_NETLINK` it exits with status 1 right after "using
  config file", and upstream's binary prints no error. Our build's `ntp-daemon` prints it.
- A service with `PrivateTmp=`/`ProtectSystem=` sandboxing and its own AppArmor profile cannot use
  `Type=notify`: the write to systemd's notification socket is refused as a "disconnected path"
  (`name="systemd/notify"`), the start times out after 90 s and the unit fails (ntpd-rs in CI).
  `Type=exec` needs no notification.
- `ps -o user=` shows a `DynamicUser=` service's UID as a number, not the unit's name: compare it
  with `systemctl show -P UID <unit>`.
- AppArmor checks the resolved path: on the image `/usr/local` links to `/var/usrlocal`, so a CA
  added with update-ca-certificates is read as `/var/usrlocal/share/ca-certificates/...`, which the
  `ssl_certs` abstraction does not name (it allows `/usr/local/share/ca-certificates/`). Seen with
  the update tests' CA: every read of the CA directory by ntp-daemon was denied.
- ntpd-rs's selection already wants a majority: the largest set of sources that agree must be more
  than half of the usable ones, and at least `minimum-agreeing-sources` (default 3).
- ntpd's build script asks git for a commit and its date; outside a git checkout `git diff-index`
  fails, the build counts as "dirty" and takes today's date (`date -u`), so the binary changes every
  day. `NTPD_RS_GIT_REV` and `NTPD_RS_GIT_DATE` in the environment avoid it.
- `git apply` works outside a repository, like `patch`: `git apply -p2 --directory=ntp-proto-1.9.0`
  applies a patch made in the upstream tree (`a/ntp-proto/src/...`) to the crate unpacked from
  crates.io.
- systemd's `@privileged` system call set contains `@clock`: a time client can deny `@resources`
  but not `@privileged`. `systemd-analyze security --offline=true FILE` scores a unit file that is
  not installed.

## Sealed UKI (docs/BOOT.md)
- bootc v1.16 builds and installs sealed UKIs: `bootc container split-kernel-and-rootfs`, then
  `bootc container ukify` (it needs `ukify` in the image: `systemd-ukify`). A UKI in
  `/boot/EFI/Linux/` makes `bootc install` write only a `uki` entry (systemd-boot's key for a UKI
  path), for `EFI/Linux/bootc/bootc_composefs-<digest>.efi`.
- The composefs digest covers file times. `podman build --timestamp` rewrites them when it commits,
  so a UKI computed from the build stage does not match the image: compute it from the committed
  image (`podman run --mount type=image,…`).
- `bootc install --karg` is refused with a UKI, and the sealed command line cannot get
  `console=ttyS0` for tests. The credential `getty.ttys.serial=ttyS0` gives a getty on the serial
  port without it. In QEMU without a display, systemd-stub appends `console=uart,io,0x3f8` by itself,
  so kernel messages still arrive; "no system started" checks also look for the login prompt.
- Credentials that systemd-stub picks up from the ESP (`*.cred`) arrive as "untrusted" and are not
  used as settings when they do not decrypt; the production image does not import them at all
  (`systemd.import_credentials=no`). Check the whole system state in such a test, not only the
  value the credential would have set.
- `systemd.import_credentials=no` stops every credential import (SMBIOS, `fw_cfg`, kernel command
  line, systemd-stub), in the initrd and on the host. For a repeated kernel argument systemd uses
  the last occurrence, and systemd-stub puts add-ons after the UKI's own command line: a signed
  add-on can turn it back on, so tests do exactly that and the Nyra key never signs such add-ons.
  The stub also appends the SMBIOS string `io.systemd.stub.kernel-cmdline-extra`, under Secure Boot
  too (measured into PCR 12): the platform can turn import back on the same way.
- Without credentials `systemd-firstboot` prompts on the console at the first boot and the boot
  waits: a test boot without them needs `systemd.firstboot=no` (a signed add-on here).
- A check that something did not happen at boot needs a control: the same boot with the effect
  turned on must show the marker, or its absence proves nothing.
- Any image built on top of a sealed image needs a new UKI (its digest changes); the kernel and
  initramfs can be taken out of the old UKI's `.linux` and `.initrd` sections.
- Boot counting keeps working on bootc's `uki` entries (`…+3.conf`): the UKI's own name must not
  change, bootc refers to it by path.
- bootc joins the `kargs.d` arguments in file name order (`10-nyra-lockdown`, `10-nyra-panic`,
  `10-nyra-rw`, `20-nyra-credentials`), so the sealed command line starts with `lockdown=integrity`,
  not with `rw` as our docs said. Read it from a booted `/proc/cmdline` in CI, not from memory. It is
  pinned in `ci/uki-cmdline.txt`: a package that drops its own file in `/usr/lib/bootc/kargs.d` would
  change the sealed command line without any change of ours, and the signing step now refuses that.
- **The PCR 11 policy can be signed outside the UKI build** (systemd 258 and later): `ukify
  --policy-digest --pcr-public-key … --sign-profile main` puts the digests to sign (`tbs`) in `.pcrsig`
  without any key, a plain SHA-256 signature over each (`openssl dgst -sha256 -sign`) is the whole
  signing, and `ukify --join-pcrsig … --pcrsig @…` writes them back into the same space. With
  `--policy-digest`, ukify refuses `--phases` (it must match `--pcr-private-key`) and always adds
  systemd's four default phases. For a policy that unlocks in the initrd only, add
  `--sign-initrd-pcrs` (systemd 262): it adds the `enter-initrd` digest with the policy reference
  `initrd`, and only that one gets signed. Its data to sign is the digest followed by SHA-256 of the
  reference, and the enrollment must name it (`systemd-cryptenroll
  --tpm2-public-key-policyref=initrd`). `--join-pcrsig` only adds signatures to the entries already
  there (matched by `tbs`), so the unsigned ones stay; systemd skips an entry without a signature.
- **Sign only what you computed.** A signer that signs the `tbs` it finds in a file signs whatever a
  broken or tampered build put there, and with the real key a PCR 11 signature is a credential that
  cannot be taken back. `pcr-policy.py sign` computes the digest from the UKI and signs that.
  PKCS#1 v1.5 is deterministic, so CI compares the signature byte for byte with systemd-measure's own.
- `ukify --sbat` replaces ukify's default SBAT text, including its `uki` line: pass the `sbat` and
  `uki` lines with the Nyra one. The stub's and the kernel's lines are merged in either way. An SBAT
  revocation reaches a machine only through shim's built-in policy, so a component of our own is
  revocable only with a shim of our own.
- **NvPCRs in systemd 262 are all or nothing** (from the sources). `systemd-tpm2-setup-early` reads
  `/usr/lib/nvpcr/*.nvpcr` (dracut copies them into the initramfs) and allocates each NV index
  before it looks for the signed `initrd` policy that authorizes its first write. Without that
  policy the unit fails and the index stays in the TPM. `systemd-pcrlogin@` fails at every login
  when the `login` NvPCR is missing. Ship the definitions with the signed `initrd` policy and the
  separator, or neither (Nyra: neither).
- Debian ships `systemd-measure` (and `systemd-pcrphase`) in **`systemd-tpm`**, not in `systemd` or
  `systemd-ukify`; ukify fails with `FileNotFoundError` without it. The initramfs needs dracut's
  `systemd-pcrextend` module, or the boot phases the policy covers are never measured.
- **The signed PCR 11 unlock can be tested without a VM** (`tools/signing/tpm-unlock.sh`). systemd-stub
  measures the UKI's sections into PCR 11 and systemd-pcrextend adds the boot phases, so the exact
  PCR 11 state of any phase of any profile is reached by replaying that sequence into a software TPM
  (swtpm): for each non-empty measured section extend `H(name\0)` then `H(data)`, then one word per
  phase: `H("enter-initrd")`, `H("leave-initrd")`, `H("sysinit")`, `H("ready")`. systemd-pcrextend
  measures only the phase's own word, and `systemd-measure --phase=enter-initrd:leave-initrd` splits
  on `:` and extends one word at a time; extending the whole `a:b` string gives values no machine
  ever has. Reuse the stub's section reader (`pe_sections.py`) and the signer's algorithm
  (`pcr-policy.py`), and anchor every replayed state: compare the PCR 11 the software TPM holds with
  `systemd-measure calculate --phase=…` from the image. A positive control on one state alone does
  not catch a wrong later phase: a test whose refusals come from never reaching the real state
  passes even when the policy is broken. Prove such a test with a mutation (here: a `.pcrsig` that
  signs all four phases must fail it).
- A refusal row must check its reason, not only the absence of success: a malformed input or a
  failed setup step otherwise looks like a refusal. Run every setup step with `set -e`.
- **Reset a PCR by power-cycling the TPM, not with `tpm2_clear`.** `tpm2_clear` drops the owner
  hierarchy and the TPM's seed, so a key sealed with the systemd SRK can no longer be loaded ("Failed
  to unseal"). Restarting swtpm on the same state directory (`--flags startup-clear`) resets the PCRs
  to 0 while the seed and the persistent SRK stay, which is what happens between two boots. A second
  `tpm2_startup` on a running swtpm does nothing (it is already initialized).
- **Ubuntu confines swtpm with AppArmor** (`/etc/apparmor.d/usr.bin.swtpm`): it may write its state
  only under the user's home, `/tmp` and libvirt's directories. A state directory elsewhere (the CI
  work disk, `/mnt/work`) fails with "SWTPM_NVRAM_Lock_Dir: Could not open lockfile: Permission
  denied", and then nothing listens. Keep the state in `RUNNER_TEMP` and wait until swtpm accepts a
  connection before the first TPM command.
- **`systemd-tpm2-setup` ignores `SYSTEMD_TPM2_DEVICE` and talks only to a kernel TPM** (`/dev/tpmrm0`),
  so it cannot be pointed at an swtpm over TCP from userspace; it exits "No complete TPM2 support
  detected" with `--graceful`. `systemd-cryptenroll` and `systemd-cryptsetup` do honour the variable
  (and `swtpm:host=…,port=…`), so the unlock test uses them directly.
- **A LUKS activation needs device-mapper, which a plain container does not have**, but the TPM part
  does not: `systemd-cryptsetup attach` reaches "Completed TPM2 key unsealing" (the key is released)
  before it fails to create the dm target. The unlock test asserts on the unsealing, so it needs no
  privileged container and no device-mapper (`dm_mod`).
- The policy's key fingerprint (`pkfp`) is SHA-256 of `i2d_PublicKey`: for RSA the PKCS#1
  `RSAPublicKey` DER (`openssl rsa -pubin -RSAPublicKey_out -outform DER`), not the
  SubjectPublicKeyInfo.
- A refusal test needs a control and a reason: the same gate must accept a correct image in the same
  run, and every refusal must match its expected message. Otherwise a missing tool (`sbverify` not
  installed, `pefile` missing) or a gate that refuses everything looks like a passing negative test.
- **A check on a PE file must read it as systemd-stub does, not as pefile does** (systemd 262, from
  the sources). pefile sorts `pe.sections` by address; the stub reads the section table in order and
  groups profiles by it. The stub compares names up to the first NUL; `rstrip(b"\0")` keeps what
  follows. pefile stops at an all-zero section header (or after three errors in one header, or past
  0x800 headers) and only adds a warning; the stub reads on. The stub ignores a section that reaches
  beyond SizeOfImage, takes the first section of a name, and reads sections from memory, where a later
  section can overlap an earlier one. Read through one function (`tools/signing/pe_sections.py`) and
  refuse every file where the two readings could differ, instead of modelling each difference.
- Under Secure Boot a profile without its own `.cmdline` takes the base one, and with no base one the
  boot loader's: pin the whole `.cmdline`/`.profile` layout, not just the command lines in order.
  Compare command lines as bytes: Python's `str.strip()` also removes `\x1c` to `\x1f`, and
  systemd-stub turns control characters into spaces, neither of which the committed line shows.
- `sbverify --cert` passes when any one of the file's signatures verifies, and `sbsign` on a signed
  file adds a second signature ("adding additional signature"): count the certificate table's
  entries to require exactly one.
- Variants for a PE check are cheapest made from the real UKI: change its section headers (name,
  addresses, place in the table) or a command line in its file alignment slack, then sign. A variant
  proves the new rule only if the old check accepted it: run the variants against the old code once.
- systemd-stub reads its sections in memory, where the loader put them, and shim 16 replaces the
  firmware's loader: it does not copy a section without `IMAGE_SCN_MEM_READ` or with
  `IMAGE_SCN_MEM_DISCARDABLE`, fills one with `IMAGE_SCN_CNT_UNINITIALIZED_DATA` with zeros, and
  applies the `.reloc` relocations anywhere in the image. A check that reads the file must refuse all
  of these, or it reads bytes the stub never sees.
- `python3 -I` does not put the script's directory on `sys.path`; a script that imports a module next
  to it adds that directory itself (and sets `sys.dont_write_bytecode`, so nothing is written into the
  checkout).

## Disk encryption (docs/BOOT.md)
- An encrypted root needs nothing on the sealed command line: systemd-gpt-auto-generator finds a LUKS2
  root partition by its type and sets up `systemd-cryptsetup@root.service` for `/dev/gpt-auto-root-luks`
  (with `tpm2-device=auto` when the stub measured the boot).
- **Its root device still waits only systemd's 90 s.** gpt-auto gives the opened volume
  (`dev-mapper-root.device`) no time limit, but the root mount waits for `/dev/gpt-auto-root`, whose job
  times out after 90 s: a passphrase typed later ends in emergency mode. And systemd-cryptsetup gives up
  after three wrong passphrases (`tries=3`), which gpt-auto offers no way to change.
- **gpt-auto's measurement of the root cannot be turned off through its options either** (systemd 262,
  from the sources): it writes `tpm2-measure-pcr=yes,tpm2-measure-keyslot-nvpcr=yes` into the unit when
  the stub measured the boot. systemd-cryptsetup sends both through systemd-pcrextend's socket and only
  logs an error when that fails; `SYSTEMD_FORCE_MEASURE=0` in the unit's environment skips both, and
  nothing else in systemd-cryptsetup reads it. Setting `tpm2-measure-pcr=no` and
  `tpm2-measure-keyslot-nvpcr=no` instead (with no `fixate-volume-key=`) would also let it use
  libcryptsetup's token plugins (`use_token_plugins()`): it avoids them only while it needs the volume key.
- **bootc points `/run/systemd/volatile-root` at `/dev/gpt-auto-root`**, which for an encrypted root is
  the opened volume. systemd's `blockdev_get_root()` takes that link as it is (it traces dm-crypt to the
  partition only without the link), so gpt-auto in the running system finds no disk and mounts no ESP
  at `/boot`. bootc keeps a link that is already there.
- Once gpt-auto finds the root's disk in the running system, it uses every partition type on it under
  systemd's default host image policy (swap, `/home`, `/srv`, `/var`, `/var/tmp`, unencrypted ones
  included). `systemd.image_policy=` on the command line limits it (`designator=flags:...:=default`;
  `ignore` skips a type without failing the dissection). To see what it would do, run it by hand into
  a temporary directory; `SYSTEMD_PROC_CMDLINE=` replaces the kernel command line for it.
- **LUKS2 tokens are not authenticated**: anyone with the disk can add, change or point a token at
  another key slot, without any key. Never decide from the header whether a disk is enrolled for the
  TPM, nor which key slot to remove (`--wipe-slot=tpm2` follows the tokens); keep that inside the
  encrypted volume.
- Debian's keyutils is more than `keyctl`: it installs the kernel's `request-key` upcall (`request-key`,
  `key.dns_resolver`, `/etc/request-key.conf` with debug handlers on), through which the kernel runs
  programs as root on behalf of any user. Remove those files when only `keyctl` is needed.
- Test a script that runs as root in the initrd without a hook in it: an environment variable that
  moves its paths is one more input, and the manager's environment can be set from the kernel command
  line (`systemd.setenv=`). Run it unchanged in a mount namespace instead (`unshare -rm`, or `sudo
  unshare -m` where user namespaces cannot mount), chrooted into a directory of stand-ins with the
  host's `/usr` bound read-only; unmount before removing anything, and remove with
  `--one-file-system`.
- An initrd that writes into the root's `/var` (the running system's, so its root's) must not follow
  symbolic links there: check every component of the path before reading or writing.
- `systemd-cryptenroll --tpm2-signature=` checks a new enrollment by unsealing it, which needs a
  signature by the enrolled key for the current PCR 11: a next policy key, which has signed nothing
  yet, can only be enrolled without that check.
- In the initrd, after bootc's `bootc-root-setup.service`, `/sysroot` is the composed root: `/usr` the
  composefs image (pinned by the digest on the sealed command line, so a file read from it is the
  image's), `/var` the shared `/var`; before it, `/sysroot` is the physical root.
- `cryptsetup open --test-passphrase -v` says which key slot a key opens ("Key slot N unlocked.") on
  stderr.
- **`systemd-cryptenroll` does nothing when the same policy is already enrolled** (it compares the
  policy hash, not the TPM): after a TPM is cleared or replaced, the PCR values, so the policy, are the
  same, and it keeps the old enrollment that the new TPM cannot open, then exits with success. Remove
  the old enrollment first.
- systemd-stub did not set `StubPcrKernelParameters` when it measured add-ons into PCR 12 (systemd 262,
  in a VM): to know whether anything but the OS separator went into PCR 12, compare its value
  (`/sys/class/tpm/tpm0/pcr-sha256/12`) with SHA-256(32 zero bytes, SHA-256("os-separator")).
- A key typed at systemd-cryptsetup's prompt stays in root's user keyring for 150 s (keyname
  `cryptsetup`, also after switch-root), but a service's private session keyring does not see it:
  `KeyringMode=shared`, then `keyctl search @u user cryptsetup`, `keyctl pipe` (NUL-separated) and
  `keyctl invalidate`.
- QEMU keeps running when its swtpm dies: the guest's TPM commands fail (`tpm_recv: error -5`), which
  is how a test makes a measurement fail at a chosen moment. With QEMU, swtpm's state must also be under
  `RUNNER_TEMP` (Ubuntu's AppArmor profile, above); its control socket can be in `/tmp`.
- In a container without udev, device-mapper waits for udev's confirmation forever (closing a LUKS volume
  hung): `DM_DISABLE_UDEV=1` makes it create its nodes itself.
- An ext4 that was not cleanly unmounted cannot be mounted read-only on a read-only device: `-o
  ro,noload` (no journal replay).
- `systemd-cryptenroll --recovery-key` prints the key alone on stdout, and the rest, a QR code of the
  key included, on stderr: keep stderr out of the logs.
- systemd-ask-password prints its prompt before it turns echo off: input that arrives at once is
  echoed. A test that types a secret on a console waits a moment after the prompt.
- "Remove every enrollment for a key this boot neither uses nor carries as next" is wrong on a
  fallback: the previous release, confirmed good, would remove the newer key's enrollment (and mark it
  retired, so it is never enrolled again). Found while writing the rotation test in a VM; the record
  keeps enrollments in the order they were made, and only older ones are removed.
- **A `Type=oneshot` unit that is still running when the initrd ends fails.** initrd-cleanup's isolate
  stops it with SIGTERM, and for a oneshot only exit status 0 is a clean end (`Result=signal`). The
  console shows only "Stopped", the failed state crosses the switch to the real root, and the running
  system is `degraded` with no `FAILED` line anywhere on the console. A wait in the background that the
  initrd may cut short is `Type=simple`, for which SIGTERM is a clean end. Seen in CI, now and then: the
  root wait checked once a second, and the initrd took about as long after the root appeared.
- **TPM2 PIN (systemd 262).** gpt-auto sets `tpm2-measure-pcr=yes`, which turns off libcryptsetup's
  token plugin, so systemd-cryptsetup handles the PIN itself: up to five tries, then
  the passphrase prompt; an empty PIN (with Argon2id) goes straight to it; a locked TPM
  ("dictionary attack lock-out mode") too. It asks for the PIN before it unseals, so it asks even when
  the PCRs no longer match (and the PIN typed is then never checked), and for a token of another policy
  key; the next token takes the PIN from the kernel's cache (`tpm2-pin`), an empty one is asked again.
  A correct PIN does not reset the TPM's failure counter: only time does.
- systemd-cryptenroll takes `$PIN` (and `$NEWPIN`) once: the first TPM2 token it tries consumes it, and
  for the next one it asks on the console. The credential `cryptenroll.tpm2-pin` (in
  `$CREDENTIALS_DIRECTORY`) is read again for each token, and for each of its five tries: a wrong PIN
  there counts five times against the TPM.
- With a PIN, systemd-cryptenroll replaces an enrollment of the same policy (same key, same PCR values)
  by itself, removing its slot after adding the new one; without a PIN it keeps it and does nothing.
- swtpm (libtpms) locks after 3 wrong authorizations and forgives one every 1000 s of running time; a
  shutdown that is not orderly also counts as one when a protected object was used. A test that needs
  a known count copies the TPM state directory and puts it back.

## Removable media (docs/DEFAULTS.md)
- **udisks2 needs polkitd, even for root.** It falls back to "root only" only when the polkit
  library cannot be set up at all, and the library sets up fine without polkitd (a D-Bus proxy to a
  name nobody owns); every check then fails. polkitd itself allows root everything.
- udisks2 (2.10, 2.11) computes mount options from its built-in defaults, then
  `/etc/udisks2/mount_options.conf`, then the device's udev properties `UDISKS_MOUNT_OPTIONS_*`, each
  replacing the one before per key. It always puts `nodev,nosuid` first, and every option a caller
  passes must be in the `allow` list: an `allow` without `exec` refuses `-o exec`.
- Debian builds udisks2 to mount at `/media/<user>/<label>`. On a read-only root, `/media` must be a
  link to a writable place (`/run/media`).
- Debian's packages enable `udisks2.service` in `graphical.target` and polkit's
  `polkit-agent-helper.socket` (polkit 127 and later: the password helper is socket-activated, no
  longer setuid). Both work through D-Bus or the socket on request; a preset keeps them off at boot.
- udisks2 2.11 with polkitd 128 adds 29 packages, about 15 MB installed (a snapshot of October
  2026); the largest is NSS (5 MB), which its crypto plugin needs through `libvolume-key1`.
  polkitd depends on `logind`, which `libpam-systemd` provides: its postinst puts `pam_systemd` into
  `/etc/pam.d/common-session`, so every login gets a logind session, a user manager and a
  `/run/user/UID` tmpfs (root's console login too, which it did not before).
- **`run-user-UID.mount` has no order against the user manager.** At shutdown systemd unmounts it
  next to stopping `user@UID.service` and `user-runtime-dir@UID.service` (whose stop unmounts it
  anyway); once in CI the unmount came first, while the user manager still had files open there:
  `Failed unmounting run-user-0.mount`. `After=run-user-%i.mount` in a `user-runtime-dir@.service`
  drop-in stops the mount unit last.
- udisks2 mounts only a device whose udev usage (`ID_FS_USAGE`) is `filesystem` (or not probed at
  all). A file system type named by the caller (`-t`) is accepted from a list built into udisks2
  (hfsplus, squashfs, erofs, f2fs and more) or from `/proc/filesystems`; nothing configures it away.
- Debian's kernel 7.2 has the new `ntfs` driver and no ntfs3. udisks2 tries ntfs3 first for an NTFS
  signature and goes on to the next driver when the type is unknown.
- polkit's `pkcheck --process PID` answers 0 (allowed), 1 (no) or 2 (an authentication would be
  needed and nobody can answer it), which tells a policy apart without an agent.
- polkit counts a session as local only when it has a seat: a logind session without one
  (`systemd-run -p PAMName=login --uid=USER`) is `Active=yes` for logind but gets a policy's
  `allow_any` answer, and `-p TTYPath=` does not give it a seat either. A login on a virtual
  console does (an autologin getty drop-in on a free VT); `loginctl activate` makes it the active
  session of seat0, but may return before logind reports it: wait for `Active=yes`.
- A user with a login has two sessions: the login's and their manager's (class `manager`, no TTY).
- A FAT stick pulled out while it is written stays damaged: the next mount says `Volume was not
  properly unmounted`, and a write that hits the damage (a lost directory entry, a cluster chain the
  FAT no longer has) is a FAT error, which makes the file system read-only (`errors=remount-ro`). In
  T14 the writer of boot 2 once stopped with "Read-only file system" before its stick was pulled,
  most likely so; boot 2 repairs the stick with `fsck.vfat -a` first and pulls it only while a `dd`
  runs.
- When a disk goes away, the kernel (7.2) syncs its file system as it can (`del_gendisk`, I/O to the
  device already fails), then unregisters its writeback (`bdi_unregister`): the flusher never writes
  the pages dirtied after that. A writer throttled on them sleeps in `balance_dirty_pages()` in a
  killable state, which the hung task detector does not report. Once in T14 (boot 2, the stick
  pulled during an update) the writer did not end within 300 s and printed nothing; where it waited
  was not recorded. Boot 2 now prints the writer's `wchan` and kernel stack and the blocked tasks if
  it still runs after 110 s.

## Testing in CI
- In bash, `printf … | check …` runs `check` in a subshell: a `fail=1` it sets is lost and the test
  exits 0 whatever happens. Pass the input as an argument (or use `lastpipe`), and prove a test can
  fail by running it against changed copies of the code (mutants) that must make it exit non-zero.
- On the CI runner's loopback (64 KiB MTU) a large upload to the throwaway registry can stall for
  good: the kernel shrinks the receiving socket's buffer below one segment, the window it offers is
  smaller than the sender's MSS, and silly window avoidance keeps the sender waiting (podman push
  hung about once in 80 pushes; the sender rwnd-limited in persist mode, the receiver's queue empty).
  The test registry sets the loopback MTU to 1500 (`tools/signing/local-registry.sh`).
- Guest commands in `vm-boot.py --command` are typed into the root login shell: an `exit` in one
  ends that shell, and the result marker never comes. Chain with `&&` instead. With `--keep-vars`
  the firmware variables (boot entries, `BootOrder`) carry over between boots, as on a real machine.
- The install + boot test runs on GitHub-hosted runners with KVM: `bootc install to-disk --via-loopback`
  takes ~15 s, and the installed system reaches the login prompt 12–16 s after QEMU starts
  (`systemd-analyze`: 9–11 s).
- With root autologin the shell prompt can appear in the same instant as the login prompt: wait for it
  from the end of the login prompt, not from whatever the console buffer holds when you look.
- A kernel message can land in the middle of any prompt on the serial console ("Type RESET" then
  "[    4.007221] clocksource: Watchdog remote CPU 1 read timed out" then " to reset: "), and a
  pattern matched on the raw console then waits until its timeout. `vm-boot.py` matches every prompt
  (`--chat`, `--refused`, login, password, shell) without kernel messages (`clean()`) and maps the
  end of the match back to the raw console (`raw_offset()`), so the next wait starts right after the
  prompt and kernel starts are still counted up to it. Console triggers (`--power-cut-at`,
  `--tpm-fail-at`, `--qmp`, `--marker`) and command results are mostly printed by units or commands,
  so they split the same way; they match on the raw console or without kernel messages, since a
  trigger can also be a kernel message itself (`Linux version`). A prompt pattern ending in
  `[^\r\n:]*:` stops at the prompt's colon instead of running into a kernel message after it.
- A test's own check of a saved serial log afterwards (the boot did not ask for the recovery key, a
  unit's message showed up) splits the same way, and `grep` on the raw log then passes a check that a
  prompt did not show up although it did. Such checks use `vm-boot.py --on-console PATTERN LOG`, the
  same match as during the run (a Python regular expression), not `grep`.
- On x86 the kernel's serial console needs `console=ttyS0`. With the sealed UKI the tests no longer
  pass it (see "Sealed UKI" above); the getty on ttyS0 comes from a credential.
- The image sets no root password, and systemd-firstboot ignores `passwd.*` credentials once root exists
  in `/etc/shadow`. For console access the test passes a `systemd.unit-dropin.serial-getty@ttyS0.service`
  credential over SMBIOS (root autologin for that boot only).
- `bootc status` reports the same manifest digest as `podman image inspect` of the loaded oci-archive,
  so CI checks that the booted system is exactly the image that was built.
- The install + boot job runs images built from pull requests, as root in a `--privileged` container
  and in a VM with KVM. It must stay on ephemeral GitHub-hosted runners: never run `pull_request`
  jobs on self-hosted runners.
- The GitHub-hosted Ubuntu 24.04 image enables root's `podman-auto-update.timer` (daily,
  `Persistent=true`, `RandomizedDelaySec=900`), so on a fresh runner it fires once within 15 min of boot,
  and its service ends with `podman image prune -f`, which deletes untagged images. `podman pull -q
  oci:<dir>` stores mkosi's image untagged until the next command tags it; a prune started while the pull
  writes the layer waits for the layer lock and then lists the images just as the pull creates its image.
  That failed about one build in 40, with `locating pulled image "sha256:…" name in containers storage:
  …: image not known` from the pull or `<id>: image not known` from `podman tag` (podman 4.9.3; running
  `podman image prune -f` during the pull reproduces both). Every job that uses podman stops the timer
  and its service first.
- Amazon ECR Public answers anonymous pulls from busy runner IPs with `toomanyrequests: Data limit
  exceeded` (several jobs in one day: the test registry's `podman pull` in install-boot and Titanic).
  The base images the CI takes from it are pulled once per pinned digest and kept in the Actions cache
  (`ci/pinned-images.sh`). Release jobs never use the cache, so they pull, and one refused pull stopped
  a release: each job pulls only the images it needs (`images:` of the action; the cache key names
  them), and a failed pull from ECR Public is tried again on Docker Hub by the same index digest
  (`docker.io/library/<name>@sha256:…`). ECR Public's copies of Docker Hub's official images are the
  same index, byte for byte, so the digest and the image ID stay the only things trusted, whichever
  source served the image; the job's log says which one. `podman save` and `podman load` keep the
  image ID (the config digest) but not the manifest digest, so a loaded copy is not found by
  `name@sha256:…`: the script tags the image `localhost/pinned/<name>`, and the tools image is built
  `--from` that tag.
- The image ID alone does not prove a loaded copy: podman 4.9.3 (the runner's) does not check the
  layers against the config's DiffIDs when it reads an image (podman 5 does). Checking the files
  before podman reads them is not enough either: a checker in another language can parse the same
  JSON differently from Go's decoder (which matches keys without regard to case), and `podman load`
  picks the format itself. So `ci/pinned-images.sh` checks what podman stored: it reads the cached
  copy with the `oci:` transport, saves the image again (`--format oci-dir --uncompressed`) and
  `ci/verify-oci.py` checks every layer against the config's DiffIDs, refusing JSON keys that are
  not ASCII or appear twice in any case (`podman save` passes the stored manifest through). A refused
  cache entry fails every job that restores it: delete it (`gh cache delete pinned-images-…`, the key
  is in the job's log) or change the key.
- The bootc cache key hashes `ci/build-bootc.sh` and `ci/tools.Containerfile`, not `image.yml`, so
  editing the test jobs does not rebuild bootc (~35 min). Anything that changes the bootc build output
  belongs in that script, or the cache keeps serving the old build.
- A step with `if: ${{ !cancelled() }}` also runs after an earlier step failed, and then fails for a
  reason of its own (the TPM2 unlock test with `mkdir /mnt/work: Permission denied` when the pinned
  images failed), which hides the first error in the log. Such a step names the steps it needs:
  `!cancelled() && steps.<id>.outcome == 'success'`.
- The workflows cancel the previous run of the same branch on a new push: let a cold bootc build finish
  and save its cache before pushing again.
- **Release builds do not use the cache, pull requests do.** A release is what users install and what
  gets signed, so it is built only from pinned sources, never from a file another run left behind.
  Pull requests only test, so they restore the bootc build. A release job does not even unpack a
  cache: `actions/cache` restores an entry by extracting its archive as the runner's user, so the
  entry decides which files the job then runs, before any check of what it holds. Release jobs only
  look caches up (`lookup-only`, to save one that is missing), and `ci/check-release-cache.py` fails
  CI when a restore in `image.yml` or a local action it uses would unpack in a release. The
  comparison of the release's bootc with the cached build runs in a job of its own
  (`bootc-reproducible`), with no permissions and no checkout.
- `permissions:` does not limit the runner's own token for artifacts and caches: any job of a run
  can replace an artifact another job of the run uploaded. Artifacts that reach the release are
  checked against the sha256 their producing job reported as a job output (`ci/check-artifact.sh`):
  a finished job's outputs cannot be changed.
- A cache saved by a pull request is visible only to that pull request; a cache saved on `main` is
  visible to all. Release runs on `main` were cancelled by the next merge before they saved, so after a
  key change every new pull request built bootc from scratch (~38 min instead of ~8). The
  `bootc-cache` workflow saves it on `main` and is never cancelled while it runs. If a pull request
  still misses (the cache is evicted after 7 days without use), run it by hand on `main`
  (`gh workflow run bootc-cache.yml`) and push the pull request after it finishes.
- **Compare the times of two units only when something orders them.** Units with no `After=` or
  `Before=` between them start in parallel, and which one finishes first changes from boot to boot. A
  check that a broken `/etc/fstab` mount failed before `boot.mount` passed run after run, then failed
  by 4 ms. When a scenario needs an order, the test sets it (there, `x-systemd.before=` on the test's
  own fstab line), checks the declared order (`systemctl show -P Before`) and then the observed times.
  A margin of seconds between unordered units is still a guess about timing, not an order.
- `set -e` also applies inside an `EXIT` trap: a failing command there skips the rest of the trap.
  Clean-up steps that may fail get `|| true` before anything that must run (deleting keys).
- **Keep CI runs to what a change needs.** Every job counts rounded up to a whole minute. While this
  repository was private, its 2000 included minutes a month were gone in nine days: a pull request push
  cost ~25 minutes (image ~20, the KVM probe ~2, gitleaks twice, shellcheck), a merge ~29. On a private
  repository, check the usage before heavy CI work: `gh api organizations/<org>/settings/billing/usage`
  (works without `admin:org`; sum `quantity` for the `Actions Linux` SKU this month). Since then `image.yml` builds only when a
  file that can affect the image or its tests changed, a change only in `tools/sbom/` scans the last image
  built on main, the KVM probe is manual, and gitleaks runs once per push (pull_request runs only for forks).
- `bootc status --format json` is canonical JSON (one line, sorted keys), and `--booted` drops the staged
  and rollback entries. The test needs exactly one `imageDigest` in that output.
- bootc on the composefs backend reads the version it reports from the **manifest annotation**
  `org.opencontainers.image.version`, not from the config label (`podman build --annotation`, pushed
  as an OCI manifest).
- composefs `bootc rollback` needs a rollback deployment, drops a staged deployment and swaps the boot
  order immediately (it rewrites `loader/entries`, without boot counters); called again it swaps back.
  There is no command that only drops a staged deployment. A staged deployment's entries are only
  swapped in at shutdown (`bootc-finalize-staged`): removing `loader/entries.staged` before that keeps
  it from booting without touching the boot order.
- With systemd-boot and UKIs, bootc adds a new staging's entries to a `loader/entries.staged` left
  by an earlier staging that was never finalized (it only clears it for an image already pulled), so
  a power cut between staging and finalization can bring an old entry back with the next update.
  Stale staged entries are removed at every full boot (`esp-sync repair`).
- bootc-finalize-staged swaps `loader/entries.staged` and `loader/entries` with one
  `renameat2(RENAME_EXCHANGE)`, then deletes the old set before `fsync`. On the FAT ESP that is not
  atomic: a power cut there (one random cut in twenty in CI) left no boot entry at all, and systemd-boot
  showed only "Reboot Into Firmware Interface". A fallback UKI in `EFI/Linux/` with `+0` in its name
  (sorted last, booted only when nothing else can) does not depend on that directory (`esp-sync`).
  The ESP is now mounted `dirsync` everywhere, which orders the swap and the removal (above); the
  fallback stays for whatever `dirsync` cannot make atomic on FAT.
- After staging, bootc fsyncs only the ESP's top directory: a power cut right after `bootc switch`
  left orphaned clusters and a corrupted `loader/entries.staged` once in CI. `nyra-updated` runs
  `sync` after every `bootc switch` and `bootc rollback`.
- `bootc status` on composefs with systemd-boot needs bootc's own Type #1 entries on the ESP ("First
  boot entry not found" otherwise).
- `bootc switch --apply` to an image that is already staged reboots fully even with `--soft-reboot`
  ("Image specification is unchanged"): soft-reboot into a new image directly.
- `systemctl is-active A B` succeeds if **any** of them is active: check units one by one.
- `systemd-bless-boot status` says `indeterminate` while an entry has tries left and `dirty` on the
  last try (`+0-3`); both mean the boot is on trial.
- systemd's `RestrictSUIDSGID=` makes `openat2()` fail with `ENOSYS`; bootc then cannot open its
  auth file. Sandboxing a unit that runs bootc or `systemd-bless-boot` is verified in the VM.
- After a soft reboot `LoaderBootCountPath` still names the entry of the last full boot, so
  `systemd-bless-boot` would act on it; it is skipped then (`docs/UPDATES.md`).
- Boot tests that follow one system across reboots write to the disk (`vm-boot.py --persist`) and shut
  down cleanly (`--poweroff`), so `bootc-finalize-staged` runs. The VM reaches a registry on the runner
  as `10.0.2.2` (QEMU user networking), declared `insecure` in the guest's `/etc` on the test disk.
- A boot that fails now and then: compare the kernel timestamps of the failed boot's serial log
  with all the passing boots of the same run (the serial log artifact). The flaky root partition
  showed up only that way: a one-second stall of one CPU right when the boot disk was probed, in
  the two failed boots and in none of the 182 others.
- A kernel message can land in the middle of a prompt on the serial console ("Please enter
  rec[    4.007221] clocksource: Watchdog remote CPU 1 read timed out" then "overy key for disk
  root:"), when the runner is busy. A pattern that must match the whole prompt is matched in the
  console without kernel messages (`clean()` in `vm-boot.py`), as the status lines already were.
- The job log shows only the last 40 lines of a failed boot's console; `vm-boot.py` names the
  serial log file in the job's serial log artifact that has all of it.
- QEMU pulls out a USB stick with the QMP command `device_del` at once, without the guest's
  cooperation (`usb-storage` on `qemu-xhci`). With its drive given as `-blockdev`, the drive stays
  after the device is gone, so `device_add` plugs the same stick in again (`vm-boot.py --qmp`).
- `set -e` does not stop the script when `! command` fails: write `if command; then exit 1; fi`.
- Right after `losetup -P --show`, the loop device's partition devices (`/dev/loopNp1`, ...) can
  be missing for a moment, for instance while udev rereads the partition table. A `"$loop"p*` glob
  then finds nothing, and a bare `test -n "$esp"` under `set -e` ends the step with exit 1 and no
  message. A CI step once ended like that, after the disk copy and before any boot, and passed when
  re-run with the same image; the other silent checks there depend only on the image, so this race
  is the likely cause (the log alone cannot tell). `tools/vm/esp-of.sh` waits for udev, retries for up to 10 s and fails
  with a `::error::` that names the loop device and the partitions it found. A check that can fail
  under `set -e` should say what it expected.
- `vm-boot.py`'s `wait_for` used to stop as soon as QEMU had exited, before it read the last lines:
  a guest that printed the awaited line and powered off at once looked like it never printed it.
  It now looks once more after the console reader has finished.
- The sealed command line has `rd.emergency=reboot`: a boot that ends in the initrd's emergency mode
  starts again after its diagnostics. A check that expects such a boot and no new kernel start
  needs `rd.emergency=halt` in its test add-on (`tools/vm/boot-repeat.sh`).
- With `rd.emergency=reboot`, a boot without the test console's credentials (no emergency
  diagnostics) that fails in the initrd reboots silently, and the next boot can pass the check.
  `vm-boot.py` therefore fails at once on a kernel start ("Linux version" on the console) that the
  run did not announce: `--boots N` expects N, a `--chat-then-login` chat and `@reboot` one more each.
- Output that the serial port has not sent yet is dropped when the next command of the unit resets
  the console: the initrd's emergency diagnostics (`ExecStartPre`) lost their last lines and end
  marker once, when `dracut-emergency` started. The diagnostics now sleep 3 s after the marker.
- `subprocess.Popen` with the default buffering keeps typed text in a buffer: a write to a QEMU that
  has exited fails only at `flush()`, and the buffer fails again when Python exits ("Exception
  ignored ... BrokenPipeError"). `vm-boot.py` uses unbuffered pipes (`bufsize=0`) and reports the exit.
- The `shellcheck` workflow lints every tracked file with a sh/bash/dash shebang, with the version
  preinstalled on the Ubuntu runner, at `-S warning`. Run `ci/precheck.sh` locally before pushing (the
  workflow runs the same script; the pre-push hook does it for you): the image workflow takes long and
  fails much later.
- Emulated (QEMU TCG, GitHub's arm64 runners), the image's 10 s wait for a device ran out before udev
  had even started: `ttyAMA0` and the ESP timed out, the serial getty and `boot.mount` failed with
  them, and the boot reached `boot-complete.target` with no login prompt (seen in CI). A drop-in
  passed as a credential with a later name (`systemd.unit-dropin.UNIT~20-emulated`) gives them
  systemd's 90 s back. A credential drop-in for `dev-.device` would reach the initrd too, where a
  drop-in with the image's name (`10-nyra`) hides the root's own `dev-gpt\x2dauto\x2droot.device.d/10-nyra.conf`
  (systemd keeps one drop-in per file name), and a later name overrides its "no limit".
- QEMU's `virt` machine has only TIS TPMs (`tpm-tis-device`, `tpm-tis-i2c`, QEMU 8.2 to 10.0), and
  Debian's arm64 kernel builds neither driver (`CONFIG_TCG_TIS`, `CONFIG_TCG_TIS_I2C` off; CRB is
  built in): the guest gets the firmware's TPM2 table but no `/dev/tpm0`, and waits 90 s for it in
  the initrd.

## Titanic (docs/TITANIC.md)
- bootc 1.16 enables `bootc-sysusers-shadow-sync.service` (through its generator, on composefs boots
  with an `/etc/shadow`): before `systemd-sysusers` it removes the `/etc/shadow` and `/etc/gshadow`
  lines whose account is in neither `/etc/passwd` nor `/usr/lib/passwd`. A line in `/etc/passwd` that
  is not an account (not empty, not `#`, `+` or `-`) makes it stop before it writes anything, with
  `failed to parse passwd entry at line N` in its journal, and the unit fails. That is harmless:
  `systemd-sysusers` runs only when `/etc` needs an update (`ConditionNeedsUpdate=/etc`), and the
  unit is only wanted by `sysinit.target`. Seen on every T8 boot with that line, before the reset.
- composefs objects carry fs-verity: bytes changed on the block device under a mounted ext4 (root
  may write there) make every read of that block fail with `Input/output error`, through `/usr` and
  on the object itself. Drop the page cache first (`sync`, `blockdev --flushbufs`, `drop_caches`),
  or the old pages are served. The same write on a plain file in `/var` is the control.
- systemd sets the clock at boot to the image's date (the time of `/usr/lib/clock-epoch`, the
  snapshot date; without that file, systemd's own build time) when the hardware clock is before it
  **or more than about 15 years after it**: an RTC in 1970 and one in 2099 both start there, still
  before the real time. A clock that is wrong but within that range
  (2035) stays wrong until the time client corrects it (docs/DEFAULTS.md, "Time").
- curl reports a wrong clock as `SSL certificate OpenSSL verify result: certificate is not yet valid
  or the system clock is incorrect (9)` or `... certificate has expired (10)`, which is what
  `nyra-updated` passes on.
- ext4 keeps a few clusters that even root cannot take, so `stat -f -c %f` stays above zero on a
  full disk: prove "full" with a write that fails. bootc on a full root file system fails early
  (`Creating imgstorage: Creating tmpdir: No space left on device`), on a full ESP when it writes the
  UKI (`Writing UKI: No space left on device`); nothing is staged in either case.
- podman's first command after a boot refreshes its database (`removing container exit codes`),
  even with no container at all: on a full file system every podman command fails with `database or
  disk is full` until space is freed. Units that run podman at boot (Debian enables
  `podman-restart.service` and `podman-clean-transient.service`) then leave the system `degraded`.
  The serial console only shows `Failed to start`; reproduce without a VM with `unshare -rm`, a small
  tmpfs as `--root` and a fresh tmpfs as `--runroot` for each "boot".
- Debian also enables podman's user units for every user (`/etc/systemd/user/*.wants`): a console
  login as root starts them in root's user manager, which runs podman as root on root's storage.
  A condition on podman's own files in `/var/lib/containers` therefore cannot tell whether root uses
  containers.
- `apparmor_parser --write-cache` (Debian's `apparmor.service`) exits without loading any profile
  when it cannot set up its cache directory for lack of space (`Failed setting up policy cache …: No
  space left on device`); only a missing parent or a read-only location are ignored. Whether the
  cache exists depends on a race at the first boot: `apparmor.service` runs next to
  `systemd-tmpfiles-setup.service`, and without `/var/cache` yet the parser loads without writing a
  cache. So one T6 run passed and the next had AppArmor failing on the full disk.
- With an NTS client in the base, the update tests' boots with a wrong hardware clock (2099, 1970,
  2035) were corrected within seconds of reaching the network, so a check that needs the clock
  wrong must keep it from its servers (the T9 hostile boot points their names at the runner).
- A disk filled to the last block does not stay full across a reboot. ext4 keeps 4096 clusters that
  even root cannot take, and the fill ends with the free ones only a few below that (11 in CI). At
  every boot `systemd-tmpfiles-setup.service` removes the previous boot's PrivateTmp directories in
  `/var/tmp` (`R! /var/tmp/systemd-private-*`), 9 blocks in CI, next to `apparmor.service`: root can
  then write a few blocks. The parser then sets up its cache directory and fails on the cache files
  (`Unable to replace "…".  Unknown error (28): No space left on device`: the profile reached the
  kernel, the cache write failed), and the fallback loads the profiles without the cache.
- `df` and `stat -f -c %a` show 0 available long before root is out of space: they also leave out
  the 5% kept for root (mkfs.ext4's default, as bootc runs it). What root can still write is
  `stat -f -c %f` minus the 4096 clusters ext4 keeps back.
- Right after `/etc/hosts` was edited, a restarted chronyd still got the old address (systemd-resolved
  answered from its copy of the file); wait until `getent ahosts` shows the change. chronyd then
  replaced that address with an IPv6 one the VM cannot reach (QEMU user networking, no IPv6 route out)
  and stayed on it for minutes: a source it replaces can land on an address of the other family.
- `vm-boot.py` shuts down cleanly only when every command passed: after a failed command QEMU is
  killed, so a version staged in that boot is never finalized. Stage in a boot of its own.
- `rm -rf --no-preserve-root /` takes under 2 s in the VM and reaches more than `/etc` and `/var`:
  it walks into `/boot`, which systemd's automount mounts on access, and empties the ESP; in
  `/sys/firmware/efi/efivars` it removes `Boot####` and `BootOrder` (efivarfs marks every other
  variable immutable, which `rm` does not undo). `/` (composefs) and `/sysroot` are read-only, so
  `/usr` and the composefs store stay as they were. Afterwards `/dev/null` is gone too: `xargs`
  complains, but the commands still work.
- Under Secure Boot, Debian's kernel enforces module signatures itself: an unsigned module fails with
  "Key was rejected by service" and the kernel logs "Loading of unsigned module is rejected", not the
  lockdown's "Operation not permitted". Debian's modules are `.ko.xz`, signed before compression; the
  signature is appended (signature, a 12-byte `struct module_signature` ending with its length, then
  `~Module signature appended~\n`), so cutting it off gives the unsigned module.
- apt is not in the image; dpkg is (it is essential) without a database. dpkg 1.23 makes an empty
  database in `/var/lib/dpkg` by itself and gets as far as unpacking into `/usr`, where it fails with
  "Read-only file system"; with `--root` into an empty writable directory the same package installs.
- With `/etc` emptied, the next boot is a first boot (no machine ID): systemd-sysusers creates root
  again with the password `!unprovisioned`, which systemd-firstboot (262) treats as not set up, so
  it asks for a root password, and without credentials a time zone, before any later unit (the
  reset's question) gets the console; seen in CI. A `ConditionKernelCommandLine=!…` drop-in in `/usr`
  skips it for one boot entry only; on every other boot the drop-in runs systemd's command line
  without `--prompt-root-password`. Its other wanted units still run: `first-boot-complete.target`
  is reached and the machine ID is committed. In early boot, systemd may print a skipped unit's
  condition on the console ("… skipped, unmet condition check"), so a check that a unit did not run
  looks for what it prints when it runs ("Initial Setup...", "Initial Setup."), not for its name.
- systemd-firstboot (262) reads the `passwd.hashed-password.root` and `passwd.plaintext-password.root`
  credentials and sets root's password from them whether or not it was asked to prompt for one, while
  root is not set up (missing or `!unprovisioned`); `--prompt-root-password` only adds the question.
  The `firstboot.*` credentials never touch root. systemd-sysusers uses the same `passwd.*`
  credentials when it creates root, before systemd-firstboot runs, so only not importing credentials
  keeps them out.
- A drop-in that replaces `ExecStart=` copies the upstream command line and hides later changes to
  it: the image build compares systemd's line with the one the copy was made from.
- dpkg combines short options (`dpkg -Ri DIR` installs every package under `DIR`), so a wrapper that
  refuses `-i` looks inside such groups too, up to an option that takes the rest as its value
  (`-iD1` installs with debug level 1; in `-Di` the `i` is the value of `-D`). A `COPY` of
  `files/usr/` over `/usr/bin/dpkg` replaces the binary: move it away in a step before the `COPY`.
- Debian keeps the AppArmor profiles only in `/etc/apparmor.d`. With `/etc` emptied, Debian's
  `apparmor.systemd reload` warns ("Unable to find profiles directory"), loads nothing and exits 0;
  only our check that some profile is loaded failed `apparmor.service`, in the Reset settings boot
  (seen in the T12 logs). `apparmor_parser --base DIR -- DIR` loads a copy from elsewhere, with its
  includes (`tunables/`, `abstractions/`) resolved there instead of in `/etc`.
- The image's `login.defs` gives every new user 65536 subordinate UIDs and GIDs from 100000 up
  (`SUB_UID_MIN`, `SUB_GID_MIN`; `/etc/subuid` and `/etc/subgid` exist, empty). Lower IDs are the
  system's, the users' and systemd's own (dynamic users, `nobody`): what Reset settings keeps from an
  old `/etc` must start at 100000 or above.
- A guest command's own `timeout` must end before `vm-boot.py` stops waiting for the command's result
  (300 s from when it is typed), and so must the diagnostics after it; otherwise a hang gives only
  "no result from" and no state. T14's writer during the update had `timeout 300`, started after the
  command, so its exit never came.
- Code that runs in a job holding signing credentials must be as little as possible: building an image runs its `RUN` steps and reads the workspace where the credentials file is, so a release signs in one job that runs only a network-less container of the sealed image, and builds the final image in a job with no `id-token`.
- `podman run NAME` pulls the name when it is not in the local storage, under the system's own signature policy (a live system's accepts anything): an installer runs everything by image ID with `--pull=never --network none`, and gets the disk tools from the image it verified, not from the live system.
