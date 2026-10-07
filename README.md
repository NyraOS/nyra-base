# nyra-base

The base image recipe of [Nyra OS](https://nyraos.com): a Debian system delivered as an image-based, atomic OS with [bootc](https://bootc.dev/bootc/).

- **Built with mkosi** directly from a pinned Debian snapshot (`snapshot.debian.org`), as an OCI image.
- **bootc with the composefs backend** and **systemd-boot**: no libostree, no GRUB. Updates are atomic, rollbacks are automatic (boot counting), `/usr` is read-only and verified (fs-verity).
- **Desktop:** Debian unstable, x86_64. **Server:** Debian stable with Debian LTS, x86_64 and arm64.

This repository holds only the base: the image recipe, the boot chain and the tests that try to break it (the "Titanic" battery). The rest of Nyra OS lives elsewhere.

## Status

Early work. The approach was validated in a VM: build, install, differential updates, automatic rollback after failed boots, signature enforcement, immutability, disk encryption, KDE Plasma. Results and lessons: [`docs/LOG.md`](docs/LOG.md) (added as the recipe moves here).

We are probably among the first to run bootc seriously on Debian. Findings go back upstream (bootc issue [#865](https://github.com/bootc-dev/bootc/issues/865)).

## Contributing

Every change goes through a pull request and must keep the test battery green. Security issues: please do not open a public issue; write to the maintainers first (a `SECURITY.md` follows).

## License

GPL-3.0-or-later. See [`LICENSE`](LICENSE).
