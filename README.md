# nyra-base

The base image recipe of [Nyra OS](https://nyraos.com): a Debian system delivered as an image-based, atomic OS with [bootc](https://bootc.dev/bootc/).

- **Built with mkosi** directly from a pinned Debian snapshot (`snapshot.debian.org`), as an OCI image.
- **bootc with the composefs backend** and **systemd-boot**: no libostree, no GRUB. Updates are atomic, rollbacks are automatic (boot counting), `/usr` is read-only and verified (fs-verity).
- **Desktop:** Debian unstable, x86_64. **Server:** Debian stable with Debian LTS, x86_64 and arm64.

This repository holds only the base: the image recipe, the boot chain and the tests that try to break it (the "Titanic" battery). The rest of Nyra OS lives elsewhere.

## Status

Early work. The approach was validated in a VM: build, install, differential updates, automatic rollback after failed boots, signature enforcement, immutability, disk encryption, KDE Plasma. Lessons learned: [`docs/LESSONS.md`](docs/LESSONS.md).

We are probably among the first to run bootc seriously on Debian. Findings go back upstream (bootc issue [#865](https://github.com/bootc-dev/bootc/issues/865)).

## Building

CI (`.github/workflows/image.yml`) builds the desktop image on every pull request:

1. bootc, from a pinned release tag, compiled on Debian testing (`ci/tools.Containerfile`).
2. The root filesystem, by mkosi from the Debian snapshot set in [`mkosi/mkosi.conf`](mkosi/mkosi.conf) (`Snapshot=`, the only place where the date lives).
3. The bootc layer ([`Containerfile`](Containerfile)): initramfs, root filesystem layout, `/usr` drop-ins, then `bootc container lint --fatal-warnings`.

The image (oci-archive) and its SBOM are workflow artifacts: the Debian package list (mkosi JSON manifest, exact versions) and bootc's `Cargo.lock` (the Rust crates compiled into bootc; also shipped in the image as `/usr/share/doc/bootc/Cargo.lock`). Nothing is pushed to a registry yet.

The `install-boot` job then takes that oci-archive, installs it on a disk image with `bootc install to-disk --composefs-backend --bootloader systemd` (loopback) and boots it with QEMU, KVM and UEFI ([`tools/vm/vm-boot.py`](tools/vm/vm-boot.py)). It passes only if the system reaches `running` (not `degraded`), `bootc status` reports the image that was built and `/usr` is read-only. The console access it needs (`console=ttyS0` on the test disk, root autologin through a systemd credential) exists only in the test, not in the image. The job runs pull-request images privileged, so it stays on ephemeral GitHub-hosted runners, never self-hosted ones.

Release builds (`main`) use no cached content and are signed keylessly in CI (Sigstore, through a Google service account); the image refuses unsigned images from the Nyra registry. Details: [`docs/SIGNING.md`](docs/SIGNING.md).

## Contributing

Every change goes through a pull request and must keep the test battery green. Security issues: please do not open a public issue; write to the maintainers first (a `SECURITY.md` follows).

## License

GPL-3.0-or-later. See [`LICENSE`](LICENSE).
