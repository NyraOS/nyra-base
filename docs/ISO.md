# The installer ISO

The installer ISO (x86_64) is what a person writes to a USB stick, or attaches to a virtual machine, to
install Nyra OS without a terminal. It boots to the text installer of github.com/NyraOS/installer on the
screen and on the serial console, with no login and no command to type, and installs the signed image that
is on the ISO itself, offline. This document is about the ISO: how it boots, what is on it, what its trust
rests on, and how CI builds and tests it. The installation steps are in `docs/INSTALL.md` and the interface
between the installer program and the script in `docs/INSTALL-INTERFACE.md`.

The ISO is built and tested by the `iso` job of `.github/workflows/image.yml`.

**Status: the ISO is UNSIGNED, for testing only.** There is no signature of the ISO yet and nothing
verifies one. The only check a person can make is the SHA-256 of the file against the one the run prints
(the `iso` job's log), read in their own logged-in browser; it shows that the file is the run's, not that
the run is Nyra's. A build on main keeps the ISO as the `nyra-installer-iso-unsigned-<mode>` artifact of the run (14 days),
only after every test of the job passed; `test` in the name means that the ISO trusts a key made for the run
instead of the release signer (below).
Do not install anything you care about from it. "Before the ISO is signed or published" below is what has to
be done first.

## Trying the ISO

What you need: a computer (or a virtual machine) with UEFI firmware, **Secure Boot on** (the Microsoft keys,
which are the default), a TPM 2.0, **at least 6 GiB of memory (8 GiB recommended)** and an empty disk of **at
least 32 GB**. These are the thresholds of `tools/install/machine.sh` today (`min_memory_gib`,
`min_disk_gb`); this ISO's tests do not determine them, and the memory the real image needs is in the
summary of the `iso` job.

1. **Check the file** on your own computer before you write it. The ISO is unsigned: all there is to check is
   the SHA-256 that the run printed (the `iso` job's log), read in your own logged-in browser, against
   `sha256sum nyra-installer.iso` (`shasum -a 256` on macOS).
2. **Write it to a USB stick** (the stick is erased). The file is a hybrid image: it is written as it is,
   byte for byte, not extracted.
   - Linux: `lsblk` to find the stick, then
     `sudo dd if=nyra-installer.iso of=/dev/sdX bs=4M conv=fsync status=progress`. **Double-check
     `/dev/sdX`**: `dd` overwrites whatever disk you name, and the stick is the one whose size you recognise.
   - macOS: `diskutil list`, `diskutil unmountDisk /dev/diskN`, then
     `sudo dd if=nyra-installer.iso of=/dev/rdiskN bs=4m`. Check `N` the same way.
   - A graphical tool that writes a raw image works too: GNOME Disks ("Restore Disk Image"), balenaEtcher, or
     Rufus in "DD Image" mode. These are not tested here.
3. **Boot from the stick**: use the firmware's boot menu (often F12, F10, Esc or F8 at power-on). Do not turn
   Secure Boot off. GRUB shows one entry, "Install Nyra OS", for three seconds.
4. **What you see.** After about a minute the installer's first screen, "Nyra OS installer", with "Welcome to
   Nyra OS." It is the same program on the screen and on the serial console (`ttyS0`, 115200 8N1, if the
   machine has one): use either; only one of them can run an installation at a time. There is no login and
   no password. The keyboard is US: the installer has no language or layout choice yet, and MokManager's blue
   screen at the first boot uses a US layout too. The menu's "Open a shell" is for recovery and experts.
5. **In a virtual machine**: attach the ISO as a USB disk or as a CD/DVD, with UEFI and Secure Boot on (the
   Microsoft keys) and a virtual TPM 2.0. Leave the ISO attached until the installer says to restart, then
   detach it.

## What is on it

| Where | What |
|---|---|
| EFI partition (the ISO's El Torito boot image, and the second partition of a stick written with it) | `EFI/BOOT/BOOTX64.EFI` (shim, signed by Microsoft), `grubx64.efi` (GRUB, signed by Debian: its CD build, which looks for `/boot/grub/grub.cfg`), `mmx64.efi` (MokManager), `boot/grub/grub.cfg` (a stub, below), and `nyra.cer`, the Nyra certificate in DER form, for MokManager's "Enroll key from disk" |
| `/boot/vmlinuz` | Debian's kernel, signed by Debian |
| `/boot/initrd.img` | the installer system (below) and the release tree, as a zstd-compressed cpio archive: the whole system is the initial RAM disk |
| `/boot/grub/grub.cfg` | one menu entry, "Install Nyra OS", with a three-second timeout |
| `/registry/` | the files of a registry that holds the signed image: `updates.nyraos.com/nyra-base:<version>` and its signature |

The volume label is `NYRA-ISO-` and sixteen hexadecimal digits, the **build identifier** (a hash of the
release tree's `RELEASE` file and the mode of the build). GRUB looks for this label, and the session mounts
the medium with it, so that another medium that is there by accident (one labelled `NYRA-ISO` that has a
`/boot/vmlinuz`, an older Nyra stick, an installed system) does not take the place of the ISO that was
booted. This does **not** hold against a medium made to copy the label: the label is a name, not a check.
What limits that is that the medium serves only the registry store, which fails closed against the
signature policy and the digest of the release tree in the RAM disk; and copying the label, or editing
the stub `grub.cfg` on a stick's EFI partition, needs physical access to the stick, which is the same as
editing the stick. The installer never offers the disk or partition it started from: a disk with an `iso9660`
file system or a label starting with `NYRA-ISO` is "booted" in `nyra-install.sh disks`. A CD or DVD drive is
not a disk at all.

## The boot chain, and what Secure Boot covers

UEFI firmware -> shim (signed by Microsoft) -> GRUB (signed by Debian) -> the kernel (signed by Debian). The
chain is Debian's, not Nyra's: a fresh machine trusts Microsoft's keys, and Debian's shim trusts Debian's.
**The ISO needs no Machine Owner Key.** The MOK of Nyra's certificate is for the installed system, and it is
requested by the installer at the end of the installation.

Secure Boot covers shim, GRUB and the kernel. It does **not** cover `grub.cfg`, the stub `grub.cfg` on the
stick's EFI partition, the initial RAM disk (the whole installer system and the release tree: the policy and
the trust roots), or the registry store: a modified ISO or USB stick still boots with Secure Boot on. What
the ISO's trust will rest on is its own signature, checked on the person's own computer before the stick is
written. **That signature does not exist yet** (see the status above and the checklist below). Anyone at the
console can edit GRUB's command line or open a shell from the installer's menu, and has root in the
installer system either way; the safeguards are in the install script (it checks the disk, the
confirmation and the image again), not in the screen.

Once the kernel runs, **nothing the session trusts is read from a medium**: the release tree is in the RAM
disk, which GRUB loaded from the medium it found by the build identifier. The medium is mounted afterwards
only for the registry store, which is data: what it serves is accepted by the signature policy and the
digest of the release tree, or refused.

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
- `/usr/lib/nyra/release` is in the RAM disk and is read-only for the installer and the shell it opens
  (`ReadOnlyPaths=`). `/run/iso` is the medium of this build (`run-iso.mount`, whose `What=` is the label with
  the build identifier, set by a drop-in in the RAM disk). `/var/lib/containers` is a tmpfs, where the
  verified pull puts the image.
- `nyra-registry.service` serves the files in `/registry` on `127.0.0.1:80` (Debian's `docker-registry`,
  read-only, as a dynamic user). `/etc/hosts` names `updates.nyraos.com` as 127.0.0.1, and
  `registries.conf` allows plain HTTP for that name, on the ISO only.

## The release tree

`/usr/lib/nyra/release`, in the RAM disk, is what `tools/install/` reads when it runs without a git checkout (`docs/INSTALL.md`,
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
| 2 | `ci/build-iso-os.sh` | the installer system with mkosi; its package list (`nyra-installer-os.manifest`) is exact. The boot files (shim and GRUB, signed) come from a tree of their own (`iso/boot/mkosi.conf`): only three `.efi` files are copied from it to the ISO, so GRUB's dependencies (grub2-common, freetype, brotli, png, fuse and the rest) are not in the installer system. The kernel package asks for an initial RAM disk tool: `initramfs-tools` is listed so that apt does not take dracut |
| 3 | `ci/iso-registry.sh` | the image and its signature copied into a registry, with the registry and skopeo of the installer system (run as a container from its own tree, without network), so the files are what the ISO's registry reads |
| 4 | `ci/build-iso.sh` | the release tree and the drop-in with the build identifier, the RAM disk (two cpio archives, the system's without the kernel, GRUB and shim, which are on the ISO already, and the tree's), the EFI image, and the ISO with xorriso (hybrid: a CD and a GPT with the EFI partition second) |

Two modes, one code path:

- **release** (a build on main whose `sign` job succeeded): the signature is the release's own, checked
  against the sign job's outputs, and the policy of the tree is the shipped one.
- **test** (pull requests, and main without signing): the image is signed with a key made for the run, and the
  policy of the tree trusts that key for `updates.nyraos.com` instead. The shipped signer stays in the file,
  under a scope that no image has, so that `check` still names it. A test ISO is kept only from main and
  named `test` (below).

The job has no secret and no `id-token`, runs no code from the image, and is not a dependency of `sign` or
`publish`.

## Tests

`tools/iso/boot-test.py` boots the ISO in QEMU with the Microsoft Secure Boot keys (OVMF), a TPM (swtpm) and
an empty disk, with the serial console as a socket: once as a CD and once as a USB stick. It checks that:

- the installer's first screen appears on the serial console and no login prompt does;
- from the menu, a shell opens as root, and in it: Secure Boot is on; only `lo` exists; the only listener is
  the registry on 127.0.0.1; no getty and no SSH server runs; no unit failed; the only process that is not root's is the registry; no PAM configuration names `pam_namespace`; unprivileged `bpf()` is off; the login prompts and the emergency and rescue shells are masked; root has no password; the
  release tree is read-only and root's; `check` sees UEFI, Secure Boot, shim validation and the TPM; `disks`
  offers the empty disk and not the medium the ISO started from (as a CD it is not a disk, as a USB stick it
  is "booted"); the medium mounted has the label of the build; each installer instance uses under 15 MiB;
- (USB stick only) with a **second USB stick attached before the ISO**, labelled `NYRA-ISO`, with a
  `/boot/vmlinuz` and a release tree that names another release: the session still boots (GRUB finds the
  ISO by the build identifier), has the ISO's own `RELEASE`, mounts its own medium, and lists both sticks as
  "booted";
- (CD only) the image on the ISO passes the verified pull with the policy of the release tree, offline, and
  the memory after it is in the summary;
- leaving the shell goes back to the installer's menu, not to a prompt;
- **altered ISOs** (two more ISOs, made like the real one from a copy of its inputs): one with the
  image's layer replaced in the registry store by another gzip stream, one whose `RELEASE` names another digest. In each, the verified
  pull is refused for the reason that was made, which the messages of `verified-pull.sh` tell from a failing
  registry or tool (another digest: exit 2, "is sha256:X, not sha256:f..."; a layer replaced by another valid
  gzip stream: exit 1, "Digest did not match" and no registry error), and that podman answers and no
  image is left in the storage. The unaltered CD boot with `--pull` is the control.

The job also runs the vulnerability scan of the ISO (`tools/sbom/sbom.py --iso`, `docs/SBOM.md`): the
installer system's Debian packages and the installer program's crates, with its own file of exceptions,
`tools/sbom/mitigations-iso.toml` (the image's file never applies to the ISO, nor this one to the image).
The scan refuses an empty scan: every package of `iso/mkosi.conf` is in the manifest, the program has crates,
and none comes from a git source. The SBOM is the `nyra-installer-iso-sbom` artifact.

### The installation test

The `iso-install` job (a matrix of two: the disk unlocked by a **password**, and by the **TPM**) installs from
the ISO, by the keys a person presses, and boots what it installed:

1. `tools/iso/install-test.py` boots the ISO in QEMU (KVM, UEFI, Secure Boot with the Microsoft keys, swtpm)
   with an empty 64 GB disk, and drives the installer on the serial console. `tools/iso/screen.py` is a small
   terminal emulator (cursor positions, erasing, scrolling) that keeps the screen the installer drew, so that
   the test knows which of the eight screens it is on by its title, and which item has the focus, and never
   waits for a time. It answers the installer's `ESC [ 6 n` size question like a terminal of 80 columns.
2. It goes through: the menu, "1 of 8 This computer" (UEFI, Secure Boot, TPM, memory all ok), the release, the
   disk (`vda`), the encryption (password: typed twice), the administrator (name and password twice), the
   review (the disk name typed to confirm), the installation, and then the two handoffs: the recovery key,
   read from the console and typed back at the prompt, and the one-time password of the Secure Boot key,
   typed twice at `mokutil`'s prompts. It ends on "8 of 8 Done".
3. It checks that the recovery key was on the console once, that no password was echoed, and that the
   Machine Owner Key was **requested**: the firmware variable `MokNew` holds the Nyra certificate.
4. `tools/iso/installed-test.sh` boots the installed disk with Secure Boot on: the disk unlocks (the password
   typed at the prompt, or the TPM), the first administrator exists in `sudo` with a home and a yescrypt
   hash, root is locked, no empty password, the record is gone, the fixed defaults are set, nothing failed,
   `bootc status` names `updates.nyraos.com/nyra-base`, the digest and the version of the release. A second
   boot: the recovery key opens the disk (both ways). With the TPM the first boot is opened by the temporary
   enrollment, without a prompt (checked); the real enrollment is made by a boot without the test console, which
   the encryption tests cover (`tools/vm/encryption-first-boot.sh`).

**The console of the installed system.** The installed image's command line is sealed and has no console,
so, as in the other tests of the base (`tools/vm/first-admin.sh`), the test puts a signed add-on that turns
credential import on on the disk's EFI partition, and `vm-boot.py` passes the console and the login as
credentials. The add-on is signed with a key made for the run; that key and the image's certificate are
enrolled as Machine Owner Keys in a copy of the firmware variables, which stands in for MokManager. That
step is not the installer's: the screen of MokManager, and the installer's request, are checked as far as
CI can (`MokNew`).

**The recovery key and the QR code.** `systemd-cryptenroll --recovery-key` draws a QR code with block
characters and prints the key as text next to it: on the Linux console and on a serial console the text is
there and readable (64 letters in 8 groups of 8). The test takes the key from that text, so the QR code's
looks on a serial terminal do not matter for the test; only a person with a phone can tell if the code scans.

Not tested in CI: MokManager, real firmware, a real stick, UTM, keyboards other than US, whether the QR code
scans, and that the recovery key is not in the installer session's journal (that session has no shell by
then; `tools/install/test-recovery-key.sh` checks the same steps for the journal and the container logs).

## Decisions, and why

- **The root is the cpio, not a squashfs.** Debian's kernel runs systemd from a cpio initial RAM disk with
  no initramfs tools and no live-boot: the system is the RAM disk (`rootfs`), `podman run` works on it with
  `no_pivot_root` (a root that is the initial RAM disk cannot be pivoted away from), and the script's pull goes
  to a tmpfs on `/var/lib/containers`. The cost is the memory of the whole system (see "Limits"); a squashfs would keep it on the medium.
- **The registry store is read from the medium, the release tree is not.** The image (the largest part) is
  read from the medium; only the container storage is in memory. What decides whether the image may be
  installed (policy, trust roots, scripts, digest) is in the RAM disk, so it cannot come from another
  medium.
- **A registry, not a directory.** The signature policy's sigstore attachments are only looked up through the
  registry protocol, so the policy and `verified-pull.sh` stay exactly as they are.
- **The registry is a package of the distribution.** Debian's `docker-registry` reads the files that the same
  binary wrote; what it serves is verified by the policy and the digest, so its version is not a trust root.
- **No D-Bus.** `systemctl reboot` and `poweroff` work without it (a warning about the bus goes to the console);
  podman uses `cgroupfs`.
- **Hybrid image.** The same file boots as a CD (El Torito) and as a stick (the EFI partition is the second
  partition of the GPT); the ISO file system is also the first, so a stick shows `iso9660` and the label
  `NYRA-ISO-` and the build identifier.

## Limits

- Memory: **about 0.65 GiB of RAM is in use after the installer system has booted**, measured in a QEMU
  virtual machine (6 GiB, a small stand-in image, `MemTotal - MemFree` after boot). That is the whole system,
  the RAM disk included. The pull then holds the unpacked image in the tmpfs on `/var/lib/containers` (up to
  75% of the memory); the registry's files are read from the medium and are only in the page cache. The
  summary of the `iso` job's boot test (`Memory, idle` and `Memory, after the pull`) has the numbers for the
  real image; they, not this figure, decide the memory the installer asks for.
- Reproducibility: the ISO is built so that the same inputs give the same file (times in the tree are
  `SOURCE_DATE_EPOCH`, the archive is sorted and root's, the ESP image has fixed times and volume ID), and
  the `iso` job builds the last step twice and compares the two files. The installer system itself (mkosi)
  and the installer program are built once per job: their reproducibility is not checked here.
- Debian's GRUB, shim and kernel are the pinned snapshot's. When Microsoft's or Debian's keys change (the
  Microsoft UEFI CA 2011 expires), the ISO needs a newer snapshot; nothing on it is signed by Nyra.

## Before the ISO is signed or published

Not done yet; the ISO must not be signed, published or recommended before each of these is. (The ISO is
unsigned, and `iso` is not a dependency of `sign` or `publish`.)

- **The recovery key and the session's journal**: checked for the steps themselves (`tools/install/test-recovery-key.sh`),
  not in the installer session, which the install test cannot enter once the installation has begun.
- **The exceptions of the scan** (`tools/sbom/mitigations-iso.toml`) rest on facts the boot test checks (the registry is the only unprivileged process and runs under `RestrictNamespaces=` and a system-call filter, no PAM file loads `pam_namespace`, unprivileged bpf is off) and on the medium being mounted as `iso9660` only; they expire in at most 90 days (14 for a vulnerability with a fix in Debian), and every bump of the snapshot is a review of the file.
- **`check` names the signer from the `updates.nyraos.com` scope of the policy**, so that the test ISO's
  decoy scope (the shipped signer under a name no image has) can go.
- **The installer program pinned also by the SHA-256 of its git archive**, next to the commit in
  `iso/installer-commit`.
- **The ISO's signature**: `SHA256SUMS` signed by the release signer, published with the ISO, verified by
  `verify-iso`, and the exact commands in `docs/INSTALL.md` (the person verifies on their own computer
  before writing the stick); this document's status paragraph then changes.
