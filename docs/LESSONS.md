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
- **bootc's own build is not reproducible yet:** two compiles of the same `BOOTC_COMMIT` give a different
  `/usr/bin/bootc` (symbols in another order), tracked in WaggSoftware/NyraOS#73. The check above reuses
  the bootc binary of the first build, so it does not catch that; it also runs on one runner, so it does
  not catch what depends on the host.
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

## Testing in CI
- The install + boot test runs on GitHub-hosted runners with KVM: `bootc install to-disk --via-loopback`
  takes ~15 s, and the installed system reaches the login prompt 12–16 s after QEMU starts
  (`systemd-analyze`: 9–11 s).
- With root autologin the shell prompt can appear in the same instant as the login prompt: wait for it
  from the end of the login prompt, not from whatever the console buffer holds when you look.
- On x86 the serial console needs `console=ttyS0`. The test passes it with `bootc install --karg`, so it
  lives only in the test disk's boot entry, never in the image.
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
  Pull requests only test, so they restore the bootc build.
- A cache saved by a pull request is visible only to that pull request; a cache saved on `main` is
  visible to all. Release runs on `main` were cancelled by the next merge before they saved, so after a
  key change every new pull request built bootc from scratch (~38 min instead of ~8). The
  `bootc-cache` workflow saves it on `main` and is never cancelled while it runs. If a pull request
  still misses (the cache is evicted after 7 days without use), run it by hand on `main`
  (`gh workflow run bootc-cache.yml`) and push the pull request after it finishes.
- `set -e` also applies inside an `EXIT` trap: a failing command there skips the rest of the trap.
  Clean-up steps that may fail get `|| true` before anything that must run (deleting keys).
- `bootc status --format json` is canonical JSON (one line, sorted keys), and `--booted` drops the staged
  and rollback entries. The test needs exactly one `imageDigest` in that output.
- Boot tests that follow one system across reboots write to the disk (`vm-boot.py --persist`) and shut
  down cleanly (`--poweroff`), so `bootc-finalize-staged` runs. The VM reaches a registry on the runner
  as `10.0.2.2` (QEMU user networking), declared `insecure` in the guest's `/etc` on the test disk.
- The `shellcheck` workflow lints every tracked file with a sh/bash/dash shebang, with the version
  preinstalled on the Ubuntu runner, at `-S warning`. Run it locally before pushing: the image workflow
  takes long and fails much later.
