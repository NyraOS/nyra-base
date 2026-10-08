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
- containers/image (bootc, podman, skopeo) checks a keyless (Fulcio) signature only by OIDC issuer
  and **e-mail** address. GitHub Actions certificates name the workflow as a URI, which it cannot
  match (containers/image#2350), so we sign as a Google service account (`docs/SIGNING.md`).
- It also needs the Rekor v1 SET inside the old cosign signature format; cosign 3 must be told
  `--new-bundle-format=false --use-signing-config=false`.
- The bootc image has an empty `/var` (tmpfiles fills it at boot): running the image's own tools
  in a container (skopeo unpacking an oci-archive) needs `--tmpfs /var/tmp`.

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
  editing the test jobs does not rebuild bootc (~15 min). Anything that changes the bootc build output
  belongs in that script, or the cache keeps serving the old build.
- The workflows cancel the previous run of the same branch on a new push: let a cold bootc build finish
  and save its cache before pushing again.
- `bootc status --format json` is canonical JSON (one line, sorted keys), and `--booted` drops the staged
  and rollback entries. The test needs exactly one `imageDigest` in that output.
