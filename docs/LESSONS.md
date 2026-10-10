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
- The mkosi container needs `python3-pefile`.
- **apt only warns on a suite mismatch.** A correctly signed InRelease for another suite (unstable
  served where testing was asked) is accepted with `W: Conflicting distribution`. `ci/tools.Containerfile`
  fetches over http, so it checks the InRelease `Suite` and `Date` itself; mkosi fetches the snapshot
  over https (`snapshot.debian.org`), where a network attacker cannot swap files.
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
- containers/image (bootc, podman, skopeo) checks a keyless (Fulcio) signature only by OIDC issuer
  and **e-mail** address. GitHub Actions certificates name the workflow as a URI, which it cannot
  match (containers/image#2350), so we sign as a Google service account (`docs/SIGNING.md`).
- It also needs the Rekor v1 SET inside the old cosign signature format; cosign 3 must be told
  `--new-bundle-format=false --use-signing-config=false`.
- The bootc image has an empty `/var` (tmpfiles fills it at boot): running the image's own tools
  in a container (skopeo unpacking an oci-archive) needs `--tmpfs /var/tmp`.

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
- The ESP at `/boot` is an automount (systemd-gpt-auto-generator) that unmounts after two idle
  minutes, and an automount cannot be triggered once the shutdown transaction is queued. Anything that
  writes the ESP at shutdown mounts the partition itself (`LoaderDevicePartUUID`), as bootc does.
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
- A service with `StandardOutput=inherit` on the console (a prompt that needs the console at once)
  writes nothing to the journal: check its effects, not its log, in tests.

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
- Without credentials `systemd-firstboot` prompts on the console at the first boot and the boot
  waits: a test boot without them needs `systemd.firstboot=no` (a signed add-on here).
- A check that something did not happen at boot needs a control: the same boot with the effect
  turned on must show the marker, or its absence proves nothing.
- Any image built on top of a sealed image needs a new UKI (its digest changes); the kernel and
  initramfs can be taken out of the old UKI's `.linux` and `.initrd` sections.
- Boot counting keeps working on bootc's `uki` entries (`…+3.conf`): the UKI's own name must not
  change, bootc refers to it by path.

## Testing in CI
- Guest commands in `vm-boot.py --command` are typed into the root login shell: an `exit` in one
  ends that shell, and the result marker never comes. Chain with `&&` instead. With `--keep-vars`
  the firmware variables (boot entries, `BootOrder`) carry over between boots, as on a real machine.
- The install + boot test runs on GitHub-hosted runners with KVM: `bootc install to-disk --via-loopback`
  takes ~15 s, and the installed system reaches the login prompt 12–16 s after QEMU starts
  (`systemd-analyze`: 9–11 s).
- With root autologin the shell prompt can appear in the same instant as the login prompt: wait for it
  from the end of the login prompt, not from whatever the console buffer holds when you look.
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
- The bootc cache key hashes `ci/build-bootc.sh` and `ci/tools.Containerfile`, not `image.yml`, so
  editing the test jobs does not rebuild bootc (~35 min). Anything that changes the bootc build output
  belongs in that script, or the cache keeps serving the old build.
- The workflows cancel the previous run of the same branch on a new push: let a cold bootc build finish
  and save its cache before pushing again.
- **Release builds do not use the cache, pull requests do.** A release is what users install and what
  gets signed, so it is built only from pinned sources, never from a file another run left behind.
  Pull requests only test, so they restore the bootc build. A release restores the bootc cache only to
  compare it with its own fresh compile, never to build from it.
- A cache saved by a pull request is visible only to that pull request; a cache saved on `main` is
  visible to all. Release runs on `main` were cancelled by the next merge before they saved, so after a
  key change every new pull request built bootc from scratch (~38 min instead of ~8). The
  `bootc-cache` workflow saves it on `main` and is never cancelled while it runs. If a pull request
  still misses (the cache is evicted after 7 days without use), run it by hand on `main`
  (`gh workflow run bootc-cache.yml`) and push the pull request after it finishes.
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
- The `shellcheck` workflow lints every tracked file with a sh/bash/dash shebang, with the version
  preinstalled on the Ubuntu runner, at `-S warning`. Run it locally before pushing: the image workflow
  takes long and fails much later.

## Titanic (docs/TITANIC.md)
- composefs objects carry fs-verity: bytes changed on the block device under a mounted ext4 (root
  may write there) make every read of that block fail with `Input/output error`, through `/usr` and
  on the object itself. Drop the page cache first (`sync`, `blockdev --flushbufs`, `drop_caches`),
  or the old pages are served. The same write on a plain file in `/var` is the control.
- systemd sets the clock to its build time at boot when the hardware clock is before it **or more
  than about 15 years after it**: an RTC in 1970 and one in 2099 both start at the image's build
  time (the snapshot date), still before the real time. A clock that is wrong but within that range
  (2035) stays wrong. The image has no time synchronization, so nothing corrects it.
- curl reports a wrong clock as `SSL certificate OpenSSL verify result: certificate is not yet valid
  or the system clock is incorrect (9)` or `... certificate has expired (10)`, which is what
  `nyra-updated` passes on.
- ext4 keeps a few clusters that even root cannot take, so `stat -f -c %f` stays above zero on a
  full disk: prove "full" with a write that fails. bootc on a full root file system fails early
  (`Creating imgstorage: Creating tmpdir: No space left on device`), on a full ESP when it writes the
  UKI (`Writing UKI: No space left on device`); nothing is staged in either case.
- `vm-boot.py` shuts down cleanly only when every command passed: after a failed command QEMU is
  killed, so a version staged in that boot is never finalized. Stage in a boot of its own.
