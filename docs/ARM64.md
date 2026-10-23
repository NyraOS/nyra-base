# nyra-base on ARM64 (aarch64)

The desktop image is built for aarch64 too, from the same sources as x86_64, so that it can be
tested in a virtual machine on Apple Silicon (where an emulated x86_64 machine is too slow to use)
and, later, on ARM laptops. This is the first stage: the image builds, boots, and can be run in UTM.
x86_64 stays the reference: its build, its tests and the Titanic battery do not wait for aarch64.

## How it is built (`.github/workflows/arm64.yml`)

Natively, on GitHub's arm64 runners (`ubuntu-24.04-arm`), with the same files and steps as
`image.yml`: the CI tools image (`ci/tools.Containerfile`, the same pinned Debian testing base image,
its arm64 manifest), bootc from the same pinned source (`ci/build-bootc.sh`), mkosi from the same
Debian snapshot, the same `Containerfile` and `ci/build-image.sh` (sealed UKI with the recovery and
reset profiles, signed with a key made for the run, `bootc container lint --fatal-warnings`).

The steps are local actions, `.github/actions/arm64-prepare`, `arm64-bootc`, `arm64-build` and
`arm64-boot`, which the arm64 release jobs of `image.yml` run too ("Releases" below), so the image
`arm64.yml` tests is built exactly as the one a release signs.

The only change is the architecture, set in `mkosi/mkosi.conf` before mkosi runs:

| `mkosi.conf` | x86_64 | aarch64 |
|---|---|---|
| `Architecture=` | `x86-64` | `arm64` |
| signed systemd-boot | `systemd-boot-efi-amd64-signed` | `systemd-boot-efi-arm64-signed` |
| kernel | `linux-image-amd64` | `linux-image-arm64` |

Every other package has the same name, and at the pinned snapshot the same version, on both
architectures. The step fails if any other line of `mkosi.conf` names an architecture, so a new
architecture-specific package cannot slip through unnoticed. The same step sets the repository the
image follows for updates (`repository =` in `/usr/lib/nyra/updates/updated.conf`) to
`nyra-base-arm64`, and `ci/check-image-repository.sh` then checks the built image: its config says
`linux/arm64` and its `updated.conf` names exactly `nyra-base-arm64` (the control, `nyra-base`, must
be refused).

Reproducible, as on x86_64: bootc is compiled twice, on two runners, and the two builds must be
identical; the image is built a second time from the same inputs and must have the same layers
(`ci/check-reproducible.sh`, which also covers nyra-updated and anything else compiled in the
`Containerfile`).

The workflow runs on `main` after every merge, by hand (`workflow_dispatch`), and on pull requests
that change it, its local actions, `tools/vm/arm64-boot.sh`, `tools/signing/`, or the scripts that
make the UKI. It uses no cache, signs nothing for release and publishes nothing. Its artifacts: the
image (`nyra-base-arm64-oci-archive`), the package list (`nyra-base-arm64-packages`, mkosi's manifest
and bootc's `Cargo.lock`), the VM disk image (`nyra-base-arm64-vm`) and the serial logs.

## What the tests prove

The `build` job runs, on the AArch64 UKI (PE machine `0xAA64`), what `image.yml` runs on x86_64: the
UKI release gate's tests (`tools/signing/test-uki-gate.sh`, every refusal, with the committed
certificate as the `sign` job uses it), the PCR policy signing's tests
(`tools/signing/test-pcr-policy.sh`), and on pull requests the release mode build
(`ci/release-smoke.sh`). `ci/build-image.sh` itself signs the UKI with `tools/signing/sign-uki.sh`
(sbsign) and the run's key.

The `join` job, on an x86_64 runner without any token, does what `release-sign-arm64` does between its
checks and the KMS: Ubuntu's `qemu-user-static` installed and registered, the sealed arm64 image
checked against `build`'s hash and loaded, and `tools/signing/join-pcrsig.sh` joining the run's PCR
policy signature into the unsigned UKI with that image's `ukify` under qemu-user. The result must be
byte for byte the UKI `build` joined natively, and `sign-uki.sh` (x86_64 sbsign on an AArch64 PE) must
sign it with a key made in the job and verify it.

The `policy` job, on an arm64 runner without a token, runs what `verify-signature-arm64` runs on a
release, minus Nyra's signature: the image's own skopeo (native) puts the image into the throwaway
registry, and `tools/signing/test-policy.sh` checks the policy the image ships for `nyra-base-arm64`
(unsigned and wrongly signed images refused, other registries and local transports accepted). The
`join` job also reads the sealed arm64 image the way `sign-arm64` does on its x86_64 runner (podman
creates a container only to copy files out of it, the runner's skopeo copies the archive into the
registry with its manifest digest unchanged) and checks the repository allow-list on it.

The `boot` job installs the image as the installer does (`tools/vm/install-disk.sh`, then
`esp-sync install`) and boots it with QEMU's `virt` machine and edk2 (Ubuntu's `qemu-efi-aarch64`,
AAVMF), with KVM when the runner has it and emulated (TCG) otherwise; its summary says which.
GitHub's arm64 runners (`ubuntu-24.04-arm`) have no `/dev/kvm` (October 2026), so the boots are
emulated. Emulated, the running system's 10 s wait for a device (docs/BOOT.md, "Mounts from
/etc/fstab") is over before udev has even started: `vm-boot.py` gives the serial console and the
`/dev/disk/...` devices systemd's 90 s back, as a drop-in passed as a credential, or the getty on
`ttyAMA0` and the ESP mount fail with their devices.
`tools/vm/arm64-boot.sh`:

1. without Secure Boot: the system starts with no failed unit, it runs the image that was
   installed, `/usr` is read-only, the ESP holds the arm64 boot files and `esp-sync` created the
   "Nyra OS" firmware entry;
2. with Secure Boot and the Microsoft keys (`AAVMF_VARS.ms.fd`): Debian's shim for arm64 (signed by
   Microsoft) starts Debian's signed systemd-boot, which starts the UKI signed with the run's key
   (enrolled as a MOK, as on x86_64).

With KVM, boot counting across real updates also runs (`tools/vm/boot-counting.sh`: an update that
never gets healthy falls back after three tries, a healthy one is blessed). Emulated, its boots
would not fit the timeouts made for KVM, so it does not run.

## The screen (`display` job, `tools/vm/arm64-display.sh`)

Every other test reads the serial console. A person's virtual machine (UTM on Apple Silicon) has a
display and a USB keyboard instead, and its disk password is asked on the screen. The `display` job
installs the image on an encrypted disk with a password, the way the installer does, and boots it in a
machine made like UTM's: QEMU's `virt` machine with Secure Boot, a virtio GPU, a USB keyboard on an xHCI
controller, a virtio console and a serial port, and no test console add-on (the sealed command line as
it is). `tools/vm/screen-boot.py` saves the screen every 15 s (QMP `screendump`, PNG files in the artifact
`arm64-screen`), reads it with tesseract, types the password on the keyboard (QMP `send-key`) when the
prompt is on the screen, and presses the power button until the guest powers itself off, which only a
system that is up does. It passes when the prompt was on the screen and the password opened the disk.
The installer's partitioning must give the root partition the aarch64 type (the job checks it): with
the x86-64 type the initrd never finds the root, `nyra-root-wait.service` ends the wait after 90 s and
the machine restarts. The prompt must be on the screen, which a virtual GPU shows only once its driver
is loaded: the initrd carries `virtio_gpu`, `bochs`, `qxl`, `vmwgfx` and `hyperv_drm` with their helpers
(`add_drivers` in the Containerfile, about 0.4 to 0.9 MB), and the build fails if one is missing. The
kernel's own `efifb` shows the prompt on a real PC; the firmware's display of a virtio GPU on aarch64 is
not a framebuffer it can use.

## What differs from x86_64

| | x86_64 | aarch64 |
|---|---|---|
| Boot files on the ESP | `shimx64.efi`, `grubx64.efi`, `mmx64.efi`, fallback `\EFI\BOOT\BOOTX64.EFI` | `shimaa64.efi`, `grubaa64.efi`, `mmaa64.efi`, fallback `\EFI\BOOT\BOOTAA64.EFI` (`esp-sync` picks them by `uname -m`) |
| Signed shim and systemd-boot | Debian: `shim-signed`, `systemd-boot-efi-amd64-signed` | Debian ships both for arm64: `shim-signed` (with `shim-helpers-arm64-signed`), `systemd-boot-efi-arm64-signed` |
| UKI and add-on stubs | `linuxx64.efi.stub`, `addonx64.efi.stub` | `linuxaa64.efi.stub`, `addonaa64.efi.stub` |
| UKI sections | | ukify adds a `.hwids` section by itself (systemd ships hardware IDs for arm64 laptops, used to pick a devicetree from `.dtbauto` sections). The UKI has no `.dtbauto`, and the PCR policy tools refuse sections they do not model, so every ukify run on the UKI turns it off (`--hwids ''` in `ci/ukify.sh` and where `ci/build-image.sh` joins the PCR signature; no change on x86_64) |
| Test firmware | OVMF, Secure Boot variables protected by SMM | AAVMF; ARM has no SMM, so in a VM the guest can write the variable store (a limit of the test machine, not of the image) |
| Serial console in the tests | `ttyS0`, no kernel messages without `console=` | `ttyAMA0`; the kernel finds it by itself (ACPI SPCR), so its messages show up on it |
| TPM in the tests | `tpm-crb` | none: QEMU's `virt` machine has only TIS TPMs (`tpm-tis-device`, `tpm-tis-i2c`), and Debian's arm64 kernel has neither driver (its only built-in TPM driver is CRB) |
| Root partition type | `4f68bce3-e8cd-4db1-96e7-fbcaf984b709` | `b921b045-1df0-41c3-af44-4c6f280d3fae` (bootc and systemd pick the right one; the installer's `root_type` in `tools/install/lib.sh` by `uname -m`: the initrd ignores the other architecture's type and never finds the root) |

`tools/vm/vm-boot.py`, `tools/vm/test-addon.sh` and `ci/pinned-images.sh` choose by the runner's
architecture; the x86_64 path is unchanged.

Not available on aarch64: Steam and Proton (x86 only). Real ARM laptops (for example Snapdragon)
need their own firmware, device trees and drivers, and are a separate piece of work.

## Releases

`image.yml` makes an arm64 release in the same run as the x86_64 one, from the same commit and with
the same version, when the repository variable `ARM64_RELEASE` is `on` (off, the default: the jobs
are skipped). The jobs are part of `image.yml`, never a workflow it calls (docs/SIGNING.md, "Release
mode"), and nothing of the x86_64 release needs them: an arm64 failure never holds back an x86_64
release.

| Job | Runner | Permissions | What it does |
|---|---|---|---|
| `bootc-arm64` (two copies) | `ubuntu-24.04-arm` | `contents: read` | bootc from its pinned source, no cache (`arm64-bootc`) |
| `build-arm64` | `ubuntu-24.04-arm` | `contents: read` | the image in release mode (`arm64-build`, `NYRA_RELEASE=1`): both bootc builds identical, the UKI with the committed PCR policy key, unsigned; architecture and repository checked; the PCR policy tests; a second build with the same layers. Uploads the unsigned UKI and the sealed image (one day), their hashes as job outputs |
| `release-sign-arm64` | `ubuntu-24.04` (x86_64) | `contents: read`, `id-token: write` | as `release-sign`: the KMS signs the PCR policy, the join under qemu-user (`tools/signing/join-pcrsig.sh`), the KMS signs the UKI (`sign-uki.sh`, the committed `nyra.crt`) |
| `release-image-arm64` | `ubuntu-24.04-arm` | `contents: read` | as `release-image`: the final image (`ci/final-image.sh`), the same layers as `build-arm64`'s but the UKI's, `ci/check-image-repository.sh`, the UKI release gate. Uploads `nyra-base-arm64-release-oci-archive` (one day) |
| `boot-arm64` | `ubuntu-24.04-arm` | `contents: read` | `tools/vm/arm64-boot.sh` on the release image: without Secure Boot, and with the Microsoft keys and the committed `nyra.crt` enrolled as the MOK |
| `sign-arm64` | `ubuntu-24.04` (x86_64) | `contents: read`, `id-token: write`; environment `sign` | after the x86_64 `build`, `install-boot` and `encryption` and the arm64 jobs above: as `sign`, for `updates.nyraos.com/nyra-base-arm64`: hash check, the architecture and repository check, the UKI release gate, keyless cosign signature, the signature exported as an OCI layout (`nyra-base-arm64-signature`). Runs no code of the image |
| `verify-signature-arm64` | `ubuntu-24.04-arm` | `contents: read` | the image and the signature in a throwaway registry, checked with the policy the image ships (`tools/signing/test-policy.sh`, the image's own skopeo) |
| `publish-arm64` | `ubuntu-24.04` | `contents: read`; environment `publish` | only with `PUBLISH_ENABLED` `on`: as `publish`, to `nyra-base-arm64` (docs/SIGNING.md, "Publishing") |
| `verify-published-arm64` | `ubuntu-24.04-arm` | `contents: read` | the pull a machine makes (`tools/install/verified-pull.sh nyra-base-arm64`), no secret |

Every artifact is checked against the hash its job reported (`ci/check-artifact.sh`). The KMS
library has no arm64 build, so signing runs on x86_64 (`tools/signing/kms-pkcs11.sh`, unchanged).
The same KMS keys, certificate and MOK as x86_64; each `release-sign-arm64` run counts as a release
for revocation, and the SBAT generation is shared (docs/SIGNING.md).

The run's concurrency group is one per branch and a running release is never cancelled, so a slow
arm64 run (boots under TCG, up to a few hours) holds the next run on `main` in the queue even though no
x86_64 job waits for it.

Turning it on (owner): `gh variable set ARM64_RELEASE -R NyraOS/nyra-base --body on`, then a run on
`main` (`gh workflow run image.yml -R NyraOS/nyra-base --ref main`). Off again:
`gh variable delete ARM64_RELEASE -R NyraOS/nyra-base`.

Not run on arm64 (no KVM on GitHub's arm64 runners, and no TPM driver for QEMU's `virt` machine):
boot counting, disk encryption and TPM unlock, the update tests, Titanic; nor the SBOM, the
vulnerability scan and the setuid and file-capability lists ("What remains").

**Signed and published as `nyra-base-arm64`.** The repository is bound to the architecture, a
two-value allow-list: `nyra-base` is `linux/amd64`, `nyra-base-arm64` is `linux/arm64`. It is applied
in `ci/check-image-repository.sh` (config and `updated.conf`, both architectures' `release-image` and
`sign-arm64`), `publish-arm64`, `publish-image.sh` of `nyra-updates`, `tools/install/verified-pull.sh`
(which also refuses a pulled image of the other architecture), `tools/install/nyra-install.sh` (the
repository comes from `uname -m`, never from an argument) and `tools/install/check-recorded.sh`.
Publishing needs `PUBLISH_ENABLED` as well and writes the image and its signature only: the channel
sheets are a separate step in `nyra-updates`, and the arm64 releases go to the **`dev` channel only**.
**Gate:** no arm64 digest enters the `stable` channel sheet of `nyra-base-arm64` until disk
encryption, TPM unlock and boot counting run on arm64 in CI (a runner with KVM, or a TPM the arm64
kernel drives). The arm64 jobs of `image.yml` are skipped on pull requests; their steps are
rehearsed as far as possible without a token by `arm64.yml` (`join`, `policy`), and only a run on
`main` proves the KMS and keyless signatures, the publication and the pull from the registry.

**Secure Boot on an arm64 VM is weaker than on x86_64.** AAVMF (in CI) and UTM have no SMM and no
secure world, so root in the guest can write the UEFI variable store, `db` and the MOK list included:
on such a VM, the Secure Boot variables are not protected against a compromised running system. What
remains is the TPM's PCR 7 binding: a changed `db` or MOK list makes the disk ask for its recovery key.

The installer ISO for aarch64 (`docs/ISO.md`, "aarch64") is built from the arm64 release image by the
`iso-arm64` job and, on pull requests, by the `iso` job of `arm64.yml`; both boot it emulated.

## Running it in UTM on a Mac with Apple Silicon

The VM disk image is the `nyra-base-arm64-vm` artifact of a run of the `arm64` workflow:
`nyra-base-arm64.qcow2` (compressed; its virtual size is 12 GiB, it grows as it is used) and its
`.sha256`. Take it **only from a successful run on `main`** (a push, after review): the workflow
also runs on pull requests, forks included, and their artifacts can be downloaded the same way, so
a disk from a pull request is built from code nobody has reviewed yet; and the disk is uploaded
before the boot tests, so a failed run has one too:
`gh run list -R NyraOS/nyra-base -w arm64 -b main -e push -s success`.

It is a **test disk**, not a system to keep data on:

- like the CI disks, it carries an add-on that lets the VM's settings pass systemd credentials:
  whoever can change the VM's settings gets a root shell;
- its UKI is signed with that run's throwaway key, so it boots only with Secure Boot off;
- its root is not encrypted;
- it gets no updates: a newer image means a new disk.

1. Download and check the disk on the external drive. With the GitHub CLI (`brew install gh`, then
   `gh auth login` once):
   `gh run download <run> -R NyraOS/nyra-base -n nyra-base-arm64-vm -D /Volumes/<drive>/nyra`
   (`<run>` from the command above; `gh` unzips it). Or in a browser, logged in to GitHub: the
   run's page, "Artifacts", `nyra-base-arm64-vm`, then unzip it into `/Volumes/<drive>/nyra`. Then
   `cd /Volumes/<drive>/nyra && shasum -a 256 -c nyra-base-arm64.qcow2.sha256`, which must print
   `nyra-base-arm64.qcow2: OK`.
2. In UTM: create a new virtual machine, "Virtualize", "Linux". Leave "Use Apple Virtualization"
   off and "Boot ISO Image (optional)" empty; 4 GiB of memory and 4 CPU cores are enough; keep the
   proposed drive size (that empty drive is deleted below). On "Summary", untick "Open VM Settings"
   and click "Save".
3. Put the VM on the external drive before importing the disk: UTM always creates a new VM in its
   own folder on the Mac's internal disk, and copies an imported disk into the VM. Right-click the
   VM in UTM's list, "Move…", "Confirm", choose `/Volumes/<drive>/nyra`, "Save": UTM copies the VM
   there, deletes it from the internal disk and keeps a shortcut to it in the list.
4. Right-click the VM, "Edit":
   - Drives: right-click the empty drive UTM created, "Delete" (confirm with "Delete"); then
     "New…" under the drives, interface VirtIO, "Import…", `nyra-base-arm64.qcow2` (UTM copies it
     into the VM, on the external drive);
   - QEMU: UEFI boot on; **"TPM 2.0 Device" off** (switching it on also loads the Secure Boot keys,
     see below);
   - QEMU arguments: add
     `-smbios type=11,value=io.systemd.credential.binary:systemd.unit-dropin.getty@tty1.service=W1NlcnZpY2VdCkV4ZWNTdGFydD0KRXhlY1N0YXJ0PS0vc2Jpbi9hZ2V0dHkgLS1hdXRvbG9naW4gcm9vdCAtLW5vcmVzZXQgLS1ub2NsZWFyIC0gJHtURVJNfQo=`
     (in one piece: UTM splits the arguments at spaces, and this one has none). The long value is
     a drop-in for the console's login prompt, in base64, like the one CI uses on the serial console:
     ```
     [Service]
     ExecStart=
     ExecStart=-/sbin/agetty --autologin root --noreset --noclear - ${TERM}
     ```
     It logs root in on the console at every boot where it is passed.

   The image is set to UTC; set the time zone after login with `timedatectl set-timezone <Zone>`.

   Then "Save".
5. Start it. The console shows the boot messages, then a root shell (the first boot takes longer).
   `systemctl is-system-running` should print `running`.
6. To log in with a password instead: set root's password with `passwd`, shut the VM down
   (`poweroff`), remove the argument, and start it again. The password stays (it is in
   `/etc/shadow` on the disk); the console now asks for it.

**Why not a password credential:** the image's root account is locked (`*` in `/etc/shadow`), and
it is already there on the first boot, so neither systemd-sysusers (which uses
`passwd.plaintext-password.root` only when it creates root) nor systemd-firstboot (only while root
has no account or is `!unprovisioned`, docs/BOOT.md "No first-boot questions") sets a password
from it: the login says "Login incorrect". CI logs in the same way, with autologin
(`tools/vm/vm-boot.py --autologin`). The drop-in needs nothing from the first boot, so it works on a
VM that has already booted: only its arguments change.

Afterwards, delete the downloaded `.qcow2`: UTM keeps its own copy in the package.

**A TPM in UTM (optional, to check):** with the "TPM 2.0 Device" switch on, UTM gives the VM a CRB
TPM (`tpm-crb-device`), which Debian's arm64 kernel has a driver for, unlike QEMU's plain `virt`
machine in CI. The same switch also ticks "Reset UEFI Variables" and "Preload Secure Boot Keys"
(under "Maintenance") and uses the Secure Boot firmware, and with Microsoft's keys loaded shim
refuses this disk's UKI. To try it: switch the TPM on, untick "Preload Secure Boot Keys" before the
first boot (if the VM already booted with the keys, tick "Reset UEFI Variables" once with the
preload unticked), then after login check `systemd-analyze has-tpm2` and `mokutil --sb-state`
(Secure Boot must say disabled).

**Secure Boot in UTM:** possible (UTM's QEMU backend can load the Microsoft keys, which trust
Debian's shim), but the UKI is signed with the CI run's throwaway key: it boots only after that
key is enrolled as a MOK, from the running system (`mokutil --import`) and MokManager at the next
boot, for every new image. Until images are signed with the Nyra key, test without Secure Boot; the
Secure Boot chain on aarch64 is proven in CI.

## What remains

- The SBOM and the vulnerability scan for aarch64 (`tools/sbom/sbom.py` reads the amd64 package
  index only); the setuid and file-capability lists (`ci/setuid.txt`, `ci/capabilities.txt`)
  checked on the aarch64 image.
- The tests that still name the x86_64 boot files or firmware (`tools/vm/secure-boot.sh`,
  `boot-protection.sh`, `recovery.sh`, `reset-settings.sh`, `boot-repeat.sh`, `encryption-tpm.sh`,
  `tools/titanic/hostile-root.sh`, `secure-boot-system.sh`, `power-cuts.sh`), and
  `tools/vm/install-encrypted.sh` with its root partition type: parametrized like `vm-boot.py`, and
  run on aarch64.
- The Titanic battery on aarch64, then its gate, after the x86_64 gate. Its VM tests need KVM to
  run in reasonable time: without KVM on GitHub's arm64 runners, they need runners with KVM (for
  example a bare-metal ARM machine) or much longer timeouts for emulation.
- Updates on aarch64 from the update server: the release image ("Releases") signed and published to
  `nyra-base-arm64`, and `nyra-updated` following its channel sheets.
- A TPM on aarch64 in CI: Debian's arm64 kernel has no driver for QEMU's TIS TPMs (`CONFIG_TCG_TIS`
  and `CONFIG_TCG_TIS_I2C` are off), so the CI VM has none. UTM gives a CRB TPM, which the kernel
  does support: to be checked in UTM (see "A TPM in UTM" above).
