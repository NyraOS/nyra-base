# Installing Nyra OS from a release

This page installs from a Debian live session with a script. To install from the Nyra installer ISO, which
needs no terminal and no network, see [docs/ISO.md](ISO.md), "Trying the ISO".

`tools/install/nyra-install.sh` installs a published release (`updates.nyraos.com/nyra-base`, or
`nyra-base-arm64` on an aarch64 machine: the installer takes the repository from the machine's
architecture, never from an argument) on the
whole disk of the machine it runs on, from a Debian live session. It is made for a VM with a vTPM
and Secure Boot on (shim validation included); it refuses a machine without them (the steps for a disk password are in `tools/install/in-image.sh` and tested in CI, docs/BOOT.md; this script does not offer them yet).
It does what `tools/vm/install-encrypted.sh` does in CI, with the same steps
(`tools/install/in-image.sh`): GPT, LUKS2 with a recovery key, ext4 with fs-verity, `bootc install`,
`esp-sync install`, and the temporary TPM2 enrollment that the first boot replaces
(docs/BOOT.md, "Disk encryption").

**What you get, and what it rests on.** The image is pulled by `tools/install/verified-pull.sh`
under the signature policy of the checkout, pinned to the digest you give and to the version and
commit labels, and everything that touches the disk runs from that image by its ID, with no network
and no pull (docs/SIGNING.md, "What the installer guarantees"). What you must trust, because nothing
here can check it: GitHub over HTTPS (the release values and the clone), the Debian live ISO, and your
own eyes on the signer address and the certificate fingerprint. Steps 1 to 4 are that bootstrap.

## Once: your own anchors

Do these once, outside the clone, and keep the result in your own notes. At each install you compare
with the notes, not with the clone.

- In the Google Cloud console of the project `nyra-signing-3076`, check that the service account
  `nyra-image-signer@nyra-signing-3076.iam.gserviceaccount.com` exists and is the image signer.
- Check that the public key of the KMS key `uki` is the public key of `nyra.crt`
  (docs/SIGNING.md, "Making the UKI certificate").
- Write down the full SHA-256 fingerprint of `nyra.crt` (all 32 bytes).

## Steps

**1. The Debian live ISO, on your own computer.** Download a Debian live image with its
`SHA512SUMS` and `SHA512SUMS.sign`. Verify the signature with the Debian CD signing key, whose
fingerprint you read on debian.org (https://www.debian.org/CD/verify, over HTTPS), then the checksum:

```sh
gpg --verify SHA512SUMS.sign SHA512SUMS
sha512sum -c --ignore-missing SHA512SUMS
```

The VM: UEFI with **Secure Boot on** (Microsoft keys; the Debian ISO boots with it), a vTPM 2.0, a
network, and memory for the image (the live session keeps it in RAM: about twice the size of the
image, see the Image row of the release run). A pull that fails for lack of space is not a signature
problem. The live root is an overlayfs, which the pull's storage cannot sit on: the installer
mounts a tmpfs on `/var/lib/containers`, so the image is held in RAM while it is pulled. Attach the ISO and boot it. **Do not start an SSH server or any remote login in the live
session.** The installer's recovery key is shown on its console.

**2. The release values, in your own browser.** On github.com, in the run of the `image` workflow
that made the release, read:
- the version (`2026.10.N`),
- the manifest digest (`sha256:...`, the `sign` job's "Signed" table),
- the release commit (40 hexadecimal characters).

Take them from there, logged in, and not from a message someone relayed to you.

**3. The live session.** In a root shell on the VM console (`sudo -i`):

```sh
apt update && apt install -y podman skopeo git mokutil openssl jq
ls /dev/tpmrm0           # exactly one TPM2 device
mokutil --sb-state       # SecureBoot enabled
```

The disk tools (`cryptsetup`, `systemd-cryptenroll`, `mkfs`, `bootc`) are not installed here: the
installer uses those of the image it verified.

**4. The checkout, at the release commit.**

```sh
git clone https://github.com/NyraOS/nyra-base
cd nyra-base
git checkout --detach <the 40-character commit>
git rev-parse HEAD       # the commit of step 2
grep -o '"subjectEmail": *"[^"]*"' files/usr/lib/nyra/containers/policy.json
openssl x509 -noout -fingerprint -sha256 -in files/usr/lib/nyra/secureboot/nyra.crt
```

The address must be `nyra-image-signer@nyra-signing-3076.iam.gserviceaccount.com` and the
fingerprint the one in your notes (also in docs/SIGNING.md, but the clone is not an independent
witness). Anything else: stop. The installer refuses a checkout with changes, or one that is on a
branch, and prints its commit; the image's `org.opencontainers.image.revision` label must be that
commit, which ties the clone to the release.

**5. Install.** `DEVICE` is the whole disk of the VM (`lsblk`), for example `/dev/vda`:

```sh
tools/install/nyra-install.sh DEVICE 2026.10.N sha256:<digest>
```

It asks for confirmation (type the device path), then:
- pulls and verifies the image (a refused signature, another digest or other labels stop it);
- installs, and reads back what bootc recorded: the reference `updates.nyraos.com/nyra-base:<version>`
  and the digest;
- **shows the recovery key once** on the console, with a QR code. Write it down on paper. It is shown
  nowhere else: not in a file, not in a log. Type it back at the prompt; it is checked against the
  recovery key slot. If it does not match, a new key is made and shown (the old one stops working);
- enrolls the TPM, removes the key of the installation, checks the LUKS header (the recovery key and
  one TPM2 enrollment, no other key slot), clears the screen;
- shows the full fingerprint of the certificate it takes from the image, and checks that it is the one
  of docs/SIGNING.md. **Compare it with your notes.** Then it runs `mokutil --import`: type a
  one-time password at mokutil's prompt (MokManager uses a US keyboard layout).

If it fails after it began to write to the disk, the disk must be installed again from the start;
there is no way to continue.

**6. Go straight to the first boot.** Until the first Nyra boot, the TPM enrollment has no policy and
opens the disk from any system booted in that VM; the disk holds no user data yet, but keep that window
short. Detach the ISO and reboot. MokManager (a blue screen) comes first: *Enroll MOK*, *View key*
(compare the certificate with your notes), *Continue*, *Yes*, the one-time password, reboot. The next
boot is the first boot: it unlocks the disk with the temporary enrollment and replaces it with the
real one. Never turn Secure Boot off: the TPM unlock depends on it.

If the import failed or the MokManager screen did not come, boot the live ISO again and, in the
checkout, check the fingerprint of `files/usr/lib/nyra/secureboot/nyra.crt` against your notes, then:

```sh
openssl x509 -in files/usr/lib/nyra/secureboot/nyra.crt -outform DER -out nyra.der
mokutil --test-key nyra.der; mokutil --import nyra.der
```

**7. Checks in the new system**, as root (`su -`), before you delete an older VM:
- docs/UPDATES.md, "Moving a machine to updates.nyraos.com": step 1 (the policy and `subjectEmail`),
  and step 6 (remove every other MOK: a reinstalled VM keeps its firmware variables, and only Nyra's
  key may stay; the record of the TPM2 slots);
- `mokutil --list-enrolled` and `mokutil --sb-state`;
- `bootc status`: the image is exactly `updates.nyraos.com/nyra-base:<version>` with the digest of
  step 2.

## From a release tree

`nyra-install.sh` and `verified-pull.sh` also run from a **release tree**: the files of one release
without any git, as the installer ISO ships them. It is the same code and the same refusals; only the
source of the commit differs. The tree holds what the scripts read (`tools/install/`,
`files/usr/lib/nyra/` with the policy, the trust roots and `nyra.crt`, and `docs/SIGNING.md`) and a
file `RELEASE` at its root instead of the `.git`. They read the policy, the trust roots and the
certificate from the tree alone, and need neither `git` nor a clone.

`RELEASE` is exactly these four lines, in this order:

```
version=2026.10.N
digest=sha256:<64 hexadecimal characters>
commit=<40 hexadecimal characters>
architecture=amd64
```

`architecture` is `amd64` for `nyra-base` and `arm64` for `nyra-base-arm64` (the repository is still
chosen from `uname -m`, never from an argument). The scripts refuse a tree whose `RELEASE`:

- names another version, another digest than the one given, or the other architecture;
- is not exactly those four lines (a missing, repeated or extra line, a commit that is not 40 lowercase
  hexadecimal characters), or is not a regular file;
- is next to a `.git` (a tree is a checkout or a release tree, not both).

The `commit` takes the place of `git rev-parse HEAD`: it must be the `org.opencontainers.image.revision`
label of the pulled image, as the commit of a clone must, and the digest stays mandatory. A tree that
is neither (no `RELEASE` and no `.git`) is refused. The tree must be read-only to everything but its
maker; that is for whatever ships it (the ISO) to see to, the scripts cannot.

A program can drive `nyra-install.sh` from a release tree instead of a person: `check`, `disks`,
`install` and `mok-import` take the version and the digest from `RELEASE`, answer in JSON and hand the
terminal over for the recovery key and the password of `mokutil` (docs/INSTALL-INTERFACE.md). It is
the same steps and the same refusals. It also leaves the first administrator for the first boot, with
the fixed defaults (docs/BOOT.md, "The first administrator and the fixed defaults"); the terminal mode
makes no account, and leaves no way to log in but recovery.

## Notes

- The hypervisor's operator can see the VM's console (where the recovery key is shown) and its vTPM
  state. That cannot be avoided in a VM on someone else's host.
- The install is not tested in CI on a machine's TPM, MokManager or a Debian live session. CI tests
  what the script runs: the verified pull, also from a release tree, and the install by image ID
  (`tools/install/test-verified-pull.sh`; the rules of `RELEASE` offline in
  `tools/install/test-release-tree.sh`), the LUKS, TPM, record and `esp-sync` steps and the header
  check (`tools/vm/install-encrypted.sh` and the encryption tests), and that the recovery key is
  shown once and is in no log (`tools/install/test-recovery-key.sh`). The interface for programs is
  tested offline, with stand-ins for the machine, in `tools/install/test-machine-interface.sh`; the
  administrator's record and the first boot that turns it into an account, in
  `tools/install/test-admin-record.sh`, `tools/vm/encryption.sh`, `tools/vm/first-admin.sh` and, offline,
  `tools/vm/test-first-admin.sh`.
- On an arm64 VM (UTM on Apple Silicon, or QEMU with AAVMF) there is no SMM and no secure world, so
  root in the guest can write the firmware's variable store, Secure Boot's `db` and the MOK list
  included: there, Secure Boot variables are not protected against a compromised running system.
  What remains is the TPM's PCR 7 binding: a changed `db` or MOK list makes the disk ask for its
  recovery key (docs/ARM64.md, "Releases").
- arm64 releases are published as `nyra-base-arm64` to the `dev` channel only. The installer's arm64
  path (the verified pull, LUKS, the TPM, the recovery key) is not tested in CI: GitHub's arm64
  runners have no KVM and QEMU's `virt` machine has no TPM the arm64 kernel drives (docs/ARM64.md). Do
  not rely on it for data you cannot lose until that is covered.
