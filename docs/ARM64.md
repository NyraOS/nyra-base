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
- Updates on aarch64 from the update server: images signed and published per architecture (one
  image index with both), and `nyra-updated` following it.
- The Nyra Secure Boot key for aarch64 images, so that Secure Boot can stay on in UTM.
- A TPM on aarch64 in CI: Debian's arm64 kernel has no driver for QEMU's TIS TPMs (`CONFIG_TCG_TIS`
  and `CONFIG_TCG_TIS_I2C` are off), so the CI VM has none. UTM gives a CRB TPM, which the kernel
  does support: to be checked in UTM (see "A TPM in UTM" above).
