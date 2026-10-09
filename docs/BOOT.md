# The boot chain

How a Nyra machine boots, what CI proves about it, and what is still missing. Desktop, x86_64.

```
firmware (UEFI, Secure Boot)
  -> shim            Debian's, signed by Microsoft (UEFI CA 2011 and 2023)
  -> systemd-boot    Debian's, signed by Debian; shim trusts Debian's key
  -> UKI             kernel + initramfs + command line in one file, signed with the Nyra key (a MOK)
  -> the system      composefs: the digest on the command line pins every file in /usr
```

The image ships the signed boot binaries from Debian: `shim-signed` (`/usr/lib/shim/shimx64.efi.signed`,
`mmx64.efi.signed`, plus `mokutil`) and `systemd-boot-efi-amd64-signed`. `bootc install` runs
`bootctl install`, which prefers the `.signed` systemd-boot, so the ESP gets the Debian-signed one.

## What CI proves (`tools/vm/secure-boot.sh`)

The `install-boot` job takes the disk that `bootc install` produced and, on a copy of it:

1. generates two throwaway keys on the runner: `test` and `other`;
2. enrolls `test` as a MOK (Machine Owner Key) directly in the firmware variables with
   `virt-fw-vars --add-mok`, on top of Ubuntu's OVMF variables with Secure Boot on and the
   Microsoft keys (this stands in for the user confirming the key in MokManager);
3. builds a UKI with `ukify` from the kernel, initramfs and the whole `options` line of the entry bootc
   wrote (so the composefs digest and the root device are inside the signed file), and signs it with
   `test`; the same UKI is also kept unsigned and signed with `other`;
4. lays out the ESP the way the installer will: shim as `\EFI\BOOT\BOOTX64.EFI`, systemd-boot next
   to it as `grubx64.efi` (the name shim starts), MokManager as `mmx64.efi`, the UKI in
   `\EFI\Linux\`, and no Type #1 entry;
5. boots it with the Secure Boot firmware (OVMF `secboot`, SMM).

| Boot | Expected | Checked in the guest or on the console |
|---|---|---|
| UKI signed with `test` | boots | `mokutil --sb-state` = enabled, `test` listed by `mokutil --list-enrolled` (only shim publishes that list), entry `nyra-test.efi` started through systemd-stub, kernel lockdown `[integrity]`, composefs digest on `/proc/cmdline`, system `running` |
| UKI without a signature | refused | `Error loading EFI binary \EFI\Linux\nyra-test.efi: Security violation`, no kernel |
| UKI signed with `other` | refused | same |
| entry `efi <signed UKI>` + `options … nyra.injected=1` | boots, argument ignored | `nyra.injected` absent from `/proc/cmdline` |

The `test` key is not in the firmware's `db`, so only shim (through the MOK list) can have accepted
the signed UKI: systemd-boot loads images through shim's verification protocol. The keys exist only
in the job's work directory on the ephemeral runner and are deleted at the end.

Not covered yet: the real installer, MokManager enrollment on a real machine, a kernel built and
signed by Nyra (today it is Debian's), and revocation: what happens when SBAT or `dbx` updates
revoke an old shim or systemd-boot.

## What changes for the real Nyra key

Nothing in the chain; only where the key lives and who signs:

- **The key** is generated offline and kept on a hardware token, so that a compromised CI runner or
  developer machine cannot sign a boot image; CI and automated tooling never see it.
  Only its certificate goes into the image (for example `/usr/lib/nyra/secureboot/nyra.crt`), for the
  installer.
- **Enrollment:** the installer runs `mokutil --import` with that certificate; on the next boot the
  user confirms it once in MokManager (a one-time password shown by the installer). This is the same
  step Debian and Ubuntu use for DKMS keys. A machine whose owner prefers it can put the
  certificate in `db` instead (setup mode); shim checks `db` too.
- **The UKI comes from the image build**, not from the test: bootc's sealed-image flow
  (`bootc container split-kernel-and-rootfs`, then `bootc container ukify`, which puts the composefs
  digest on the command line), the signed UKI copied to `/boot/EFI/Linux/` in the image. bootc then
  installs and updates UKIs (`bootType: uki`) and writes no Type #1 entries. Signing it without
  putting the key in CI needs one of: a signing service backed by the hardware key or a KMS (`sbsign`
  through PKCS#11), or bootc's external-signing flow (CI builds the unsigned UKI, it is signed
  offline, the signed file is injected). Still to decide, with a security review. Image signing stays
  off until `main` is a protected branch, because anyone who can push to `main` could otherwise get
  their code signed (`docs/SIGNING.md`); the same rule applies here.
- **shim on the ESP:** bootc installs only systemd-boot. The installer copies shim and MokManager
  from `/usr/lib/shim/` (as the test does), and the updater must keep shim current for SBAT and
  `dbx` revocations, or a revoked shim stops booting. `bootctl update` does not overwrite shim (it
  only replaces systemd-boot).
- **Kernel modules** are signed by Debian today; once Nyra builds its own kernel, its modules will be
  signed with the Nyra key in the MOK list.

### Until then: the gap in today's install

Today bootc installs Type #1 entries (kernel and initramfs as separate files, command line in the
entry). With Secure Boot on, shim accepts the Debian-signed kernel, but **nothing verifies the
initramfs or the command line**. Only the signed UKI closes that, which is why production must boot
UKIs only.

## The kernel command line is fixed

The security review of the install and boot test (#3) found that `systemd.set_credential=` and
`systemd.unit-dropin.*` work from the kernel command line, so anyone at the keyboard could add, for
example, a root autologin from the boot menu editor. Two layers close it:

1. **`editor no`** (now): `/usr/lib/nyra/boot/loader.conf` is copied to the ESP's
   `loader/loader.conf` by `nyra-boot-loader-conf.service` at every boot when they differ.
   systemd-boot reads its settings only from the ESP, the editor is on by default, and
   `bootctl install` writes a loader.conf without it; there is no `/usr` hook in bootc or bootctl.
   The very first boot after installation still has the editor until that unit runs: the installer
   should write the file too.
2. **UKI with a fixed command line under Secure Boot** (the direction): systemd-stub ignores any
   command line passed by the boot loader when Secure Boot is on and the UKI has its own `.cmdline`.
   CI proves it (last row of the table above). Without Secure Boot the stub accepts it; there, any
   physical attacker can also boot another system, so that is not a boundary we can hold.

Still open: whether to also stop importing credentials from firmware tables (SMBIOS, `fw_cfg`) in
production (`systemd.import_credentials=no` in the sealed command line), which the tests use for
console access; a security review decides.

## Boot counting (`tools/vm/boot-counting.sh`)

A new version must prove itself, or the machine goes back to the previous one by itself (systemd
[automatic boot assessment](https://systemd.io/AUTOMATIC_BOOT_ASSESSMENT/)):

- bootc writes the entries of a staged version to `loader/entries.staged` on the ESP when it stages
  it, and swaps that directory with `loader/entries` at shutdown (`bootc-finalize-staged`). It writes
  no boot counter.
- **`nyra-boot-counter.service`** (stopped at shutdown just before `bootc-finalize-staged`) renames
  the new entry in `entries.staged` to `…+3.conf`. The counter therefore lands in the same atomic swap
  as the entry itself; the running system's entry, found by its composefs digest, gets none. It
  mounts the ESP itself (by the partition systemd-boot reports), like bootc: `/boot` is an automount
  that expires after two idle minutes and cannot be mounted again once shutdown has begun.
- systemd-boot lowers the counter on every try (`+2-1`, `+1-2`, `+0-3`) and sorts an entry with no
  tries left after all others, so the previous version boots next.
- `systemd-bless-boot` drops the counter once `boot-complete.target` is reached. Health checks are
  units `RequiredBy=boot-complete.target`; a failing one keeps the boot from being blessed.

CI follows one VM through six boots: the installed version switches (from a local registry) to an
unhealthy version (a test-only unit required by `boot-complete.target` fails), which then runs three
times and is never blessed; systemd-boot falls back to the installed version on its own; that one
switches to a healthy version, which is blessed on its first boot.

The automatic reboot when a health check fails, marking the failed version, the full reboot after a
soft reboot and the real health checks are in `nyra-updated` and its units (`docs/UPDATES.md`, tested
in `tools/vm/updates.sh`). Still to build: moving the counter into the UKI file name
(`EFI/Linux/…+3.efi`) when we switch to UKIs.
