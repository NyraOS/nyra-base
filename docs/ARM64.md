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

The only change is the architecture, set in `mkosi/mkosi.conf` by the workflow before mkosi runs:

| `mkosi.conf` | x86_64 | aarch64 |
|---|---|---|
| `Architecture=` | `x86-64` | `arm64` |
| signed systemd-boot | `systemd-boot-efi-amd64-signed` | `systemd-boot-efi-arm64-signed` |
| kernel | `linux-image-amd64` | `linux-image-arm64` |

Every other package has the same name, and at the pinned snapshot the same version, on both
architectures. The step fails if any other line of `mkosi.conf` names an architecture, so a new
architecture-specific package cannot slip through unnoticed.

Reproducible, as on x86_64: bootc is compiled twice, on two runners, and the two builds must be
identical; the image is built a second time from the same inputs and must have the same layers
(`ci/check-reproducible.sh`, which also covers nyra-updated and anything else compiled in the
`Containerfile`).

The workflow runs on `main` after every merge, by hand (`workflow_dispatch`), and on pull requests
that change it or `tools/vm/arm64-boot.sh`. It uses no cache, signs nothing for release and
publishes nothing. Its artifacts: the image (`nyra-base-arm64-oci-archive`), the package list
(`nyra-base-arm64-packages`, mkosi's manifest and bootc's `Cargo.lock`), the VM disk image
(`nyra-base-arm64-vm`) and the serial logs.

## What the tests prove

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
| Root partition type | `4f68bce3-e8cd-4db1-96e7-fbcaf984b709` | `b921b045-1df0-41c3-af44-4c6f280d3fae` (bootc and systemd pick the right one) |

`tools/vm/vm-boot.py`, `tools/vm/test-addon.sh` and `ci/pinned-images.sh` choose by the runner's
architecture; the x86_64 path is unchanged.

Not available on aarch64: Steam and Proton (x86 only). Real ARM laptops (for example Snapdragon)
need their own firmware, device trees and drivers, and are a separate piece of work.

## Running it in UTM on a Mac with Apple Silicon

The VM disk image is the `nyra-base-arm64-vm` artifact of a run of the `arm64` workflow:
`nyra-base-arm64.qcow2` (compressed; its virtual size is 12 GiB, it grows as it is used) and its
`.sha256`. Take it **only from a run on `main`** (a push, after review): the workflow also runs on
pull requests, forks included, and their artifacts can be downloaded the same way, so a disk from a
pull request is built from code nobody has reviewed yet:
`gh run list -R NyraOS/nyra-base -w arm64 -b main -e push`.

It is a **test disk**, not a system to keep data on:

- like the CI disks, it carries an add-on that lets the VM's settings pass systemd credentials:
  whoever can change the VM's settings sets root's password;
- its UKI is signed with that run's throwaway key;
- its root is not encrypted, and it has no TPM (see "What remains");
- it gets no updates: a newer image means a new disk.

1. Download the artifact straight to the external SSD (the run's page, "Artifacts", or
   `gh run download <run> -n nyra-base-arm64-vm -D /Volumes/<SSD>/nyra`, with `<run>` from the
   command above), unzip it there, and check it: `shasum -a 256 -c nyra-base-arm64.qcow2.sha256`.
2. In UTM: create a new virtual machine, "Virtualize", "Linux". Do not use Apple's Virtualization
   backend (it has neither a TPM nor Secure Boot); skip the boot ISO; 4 GiB of memory and 4 CPU
   cores are enough. Save it, then edit it:
   - Drives: remove the empty drive UTM created and import `nyra-base-arm64.qcow2` (VirtIO);
   - QEMU: UEFI boot on; a TPM 2.0 device on; Secure Boot off (do not load the default keys; see
     below);
   - QEMU arguments: add
     `-smbios type=11,value=io.systemd.credential:passwd.plaintext-password.root=<a password>` and
     `-smbios type=11,value=io.systemd.credential:firstboot.timezone=Europe/Bucharest` (or any
     time zone). The first boot sets the root password from it.
3. Start it and log in as root.

UTM keeps each VM as one `.utm` package, with the imported disk inside it. To keep it on the SSD,
create or move that package there (or move it in Finder and open it in UTM with File, Open); then
delete the downloaded `.qcow2` and the zip, which are copies.

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
- Updates on aarch64 from the update server: images signed and published per architecture (one
  image index with both), and `nyra-updated` following it.
- The Nyra Secure Boot key for aarch64 images, so that Secure Boot can stay on in UTM.
- A TPM on aarch64: Debian's arm64 kernel has no driver for QEMU's TIS TPMs (`CONFIG_TCG_TIS` and
  `CONFIG_TCG_TIS_I2C` are off), so neither CI nor a plain QEMU VM has one; whether UTM's TPM 2.0
  device works with it is to be checked in UTM.
