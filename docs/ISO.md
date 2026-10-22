# The installer ISO

The installer ISO (x86_64) is what a person writes to a USB stick, or attaches to a virtual machine, to
install Nyra OS without a terminal. It boots to the text installer of github.com/NyraOS/installer on the
screen and on the serial console, with no login and no command to type, and installs the signed image that
is on the ISO itself, offline. This document is about the ISO: how it boots, what is on it, what its trust
rests on, and how CI builds and tests it. The installation steps are in `docs/INSTALL.md` and the interface
between the installer program and the script in `docs/INSTALL-INTERFACE.md`.

The ISO is built and tested by the `iso` job of `.github/workflows/image.yml`. Until it is signed and
published (a later step), the ISO of a release is kept as the `nyra-installer-iso` artifact of the run, and
is unsigned.

## What is on it

| Where | What |
|---|---|
| EFI partition (the ISO's El Torito boot image, and the second partition of a stick written with it) | `EFI/BOOT/BOOTX64.EFI` (shim, signed by Microsoft), `grubx64.efi` (GRUB, signed by Debian: its CD build, which looks for `/boot/grub/grub.cfg`), `mmx64.efi` (MokManager), and `nyra.cer`, the Nyra certificate in DER form, for MokManager's "Enroll key from disk" |
| `/boot/vmlinuz` | Debian's kernel, signed by Debian |
| `/boot/initrd.img` | the installer system (below), as a zstd-compressed cpio archive: the whole system is the initial RAM disk |
| `/boot/grub/grub.cfg` | one menu entry, "Install Nyra OS", with a three-second timeout |
| `/release/` | the release tree (below) |
| `/registry/` | the files of a registry that holds the signed image: `updates.nyraos.com/nyra-base:<version>` and its signature |

The volume label is `NYRA-ISO`. The installer never offers the disk or partition it started from: a disk with
an `iso9660` file system or a label starting with `NYRA-ISO` is "booted" in `nyra-install.sh disks`. A CD or
DVD drive is not a disk at all.

## The boot chain, and what Secure Boot covers

UEFI firmware -> shim (signed by Microsoft) -> GRUB (signed by Debian) -> the kernel (signed by Debian). The
chain is Debian's, not Nyra's: a fresh machine trusts Microsoft's keys, and Debian's shim trusts Debian's.
**The ISO needs no Machine Owner Key.** The MOK of Nyra's certificate is for the installed system, and it is
requested by the installer at the end of the installation.

Secure Boot covers shim, GRUB and the kernel. It does **not** cover `grub.cfg`, the initial RAM disk (the whole
installer system), the release tree, the policy or the trust roots on the ISO: a modified ISO or USB stick
still boots with Secure Boot on. What the ISO's trust rests on is its own signature, which is checked on the
person's own computer before it is written to a stick (`docs/INSTALL.md`). Anyone at the console can edit
GRUB's command line or open a shell from the installer's menu, and has root in the installer system either
way; the safeguards are in the install script (it checks the disk, the confirmation and the image again), not
in the screen.

## The session

The installer system is Debian unstable from the same snapshot as the image (`iso/mkosi.conf`), built by mkosi
in the CI tools image. It runs from memory.

- `nyra-installer@.service` runs the installer on a console with the terminal as its input and output; it
  starts again if the program ends without a restart. `nyra-installer-consoles.service` starts one instance on
  `tty1` and one on every other console the kernel writes to (`/sys/class/tty/console/active`: the serial port
  of `console=ttyS0,115200n8`, if the machine has one). Two instances never install at once (the installer's
  lock).
- There is **no login**: `getty@`, `serial-getty@`, `console-getty` and `container-getty@` are masked, root
  has no password, the emergency and rescue shells are masked. A shell comes only from the installer's own
  menu ("Open a shell"), which says that it is a temporary system in memory.
- There is **no network**: no network manager is enabled, no SSH server is installed, only the loopback
  interface exists. The tests check it.
- `/usr/lib/nyra/release` is the ISO's `/release` directory, bound read-only (the file system is read-only
  anyway). `/var/lib/containers` is a tmpfs, where the verified pull puts the image.
- `nyra-registry.service` serves the files in `/registry` on `127.0.0.1:80` (Debian's `docker-registry`,
  read-only, as a dynamic user). `/etc/hosts` names `updates.nyraos.com` as 127.0.0.1, and
  `registries.conf` allows plain HTTP for that name, on the ISO only.

## The release tree

`/usr/lib/nyra/release` is what `tools/install/` reads when it runs without a git checkout (`docs/INSTALL.md`,
"From a release tree"): `RELEASE` (version, digest, commit, architecture), the install scripts, the signature
policy and `registries.d`, the trust roots (`files/usr/lib/nyra/sigstore`), `nyra.crt`, `docs/SIGNING.md` (the
fingerprint the script checks), and `reserved-names`. The scripts read the policy, the trust roots and the
certificate from this tree alone.

The image is pulled from the registry on 127.0.0.1 by `tools/install/verified-pull.sh`, unchanged: the shipped
policy requires the release signer's Fulcio signature with a Rekor entry, which containers/image checks
offline (the signature carries Rekor's signed entry timestamp), so nothing that the local registry serves is
trusted for being served. The digest in `RELEASE` is the one the person installing compares with GitHub; the
commit in it must be the image's revision label.

## How it is built

| Step | Script | What |
|---|---|---|
| 1 | `ci/build-installer.sh` | `nyra-installer` from the commit in `iso/installer-commit`: only that commit is fetched, the crates by the checksums of its `Cargo.lock`, and the build runs with `--locked --offline` and no network |
| 2 | `ci/build-iso-os.sh` | the installer system with mkosi; its package list (`nyra-installer-os.manifest`) is exact |
| 3 | `ci/iso-registry.sh` | the image and its signature copied into a registry, with the registry and skopeo of the installer system (run as a container from its own tree, without network), so the files are what the ISO's registry reads |
| 4 | `ci/build-iso.sh` | the release tree, the RAM disk (cpio, without the kernel, GRUB and shim, which are on the ISO already), the EFI image, and the ISO with xorriso (hybrid: a CD and a GPT with the EFI partition second) |

Two modes, one code path:

- **release** (a build on main whose `sign` job succeeded): the signature is the release's own, checked
  against the sign job's outputs, and the policy of the tree is the shipped one.
- **test** (pull requests, and main without signing): the image is signed with a key made for the run, and the
  policy of the tree trusts that key for `updates.nyraos.com` instead. The shipped signer stays in the file,
  under a scope that no image has, so that `check` still names it. A test ISO is never uploaded.

The job has no secret and no `id-token`, runs no code from the image, and is not a dependency of `sign` or
`publish`.

## Tests

`tools/iso/boot-test.py` boots the ISO in QEMU with the Microsoft Secure Boot keys (OVMF), a TPM (swtpm) and
an empty disk, with the serial console as a socket: once as a CD and once as a USB stick. It checks that:

- the installer's first screen appears on the serial console and no login prompt does;
- from the menu, a shell opens as root, and in it: Secure Boot is on; only `lo` exists; the only listener is
  the registry on 127.0.0.1; no getty and no SSH server runs; no unit failed; root has no password; the
  release tree is read-only and root's; `check` sees UEFI, Secure Boot, shim validation and the TPM; `disks`
  offers the empty disk and not the medium the ISO started from (as a CD it is not a disk, as a USB stick it
  is "booted"); each installer instance uses under 15 MiB;
- (CD only) the image on the ISO passes the verified pull with the policy of the release tree, offline, and
  the memory after it is in the summary.

Not tested in CI: MokManager, real firmware, a real stick, UTM, keyboards other than US.

## Decisions, and why

- **The root is the cpio, not a squashfs.** Debian's kernel runs systemd from a cpio initial RAM disk with
  no initramfs tools and no live-boot: the system is the RAM disk (`rootfs`), `podman run` works on it with
  `no_pivot_root` (a root that is the initial RAM disk cannot be pivoted away from), and the script's pull goes
  to a tmpfs on `/var/lib/containers`. The cost is the memory of the whole system (about 0.5 GiB in use, 0.2
  GiB compressed on the ISO); a squashfs would keep it on the medium.
- **The ISO file system is mounted, not copied.** The image (the largest part) and the release tree are read
  from the medium; only the container storage is in memory.
- **A registry, not a directory.** The signature policy's sigstore attachments are only looked up through the
  registry protocol, so the policy and `verified-pull.sh` stay exactly as they are.
- **The registry is a package of the distribution.** Debian's `docker-registry` reads the files that the same
  binary wrote; what it serves is verified by the policy and the digest, so its version is not a trust root.
- **No D-Bus.** `systemctl reboot` and `poweroff` work without it (a warning about the bus goes to the console);
  podman uses `cgroupfs`.
- **Hybrid image.** The same file boots as a CD (El Torito) and as a stick (the EFI partition is the second
  partition of the GPT); the ISO file system is also the first, so a stick shows `iso9660` and the label
  `NYRA-ISO`.

## Limits

- The image is held in memory twice: as the registry's files are read from the medium, and as the unpacked
  image in the tmpfs. The installer needs the memory the `check` command reports as `mem_need_gib`, and the
  ISO's tests record what the pull actually used in the job summary.
- Debian's GRUB, shim and kernel are the pinned snapshot's. When Microsoft's or Debian's keys change (the
  Microsoft UEFI CA 2011 expires), the ISO needs a newer snapshot; nothing on it is signed by Nyra.
