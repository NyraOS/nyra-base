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

## The sealed UKI (`ci/build-image.sh`)

The image boots only a UKI (Unified Kernel Image: systemd-stub + kernel + initramfs + command
line in one PE file), built in the image build with bootc's sealed-image flow:

1. **Root filesystem without kernel** (Containerfile target `sealed`): `bootc container
   split-kernel-and-rootfs` moves `vmlinuz` and `initramfs.img` out of `/usr/lib/modules/<kver>/`,
   since they end up inside the UKI. The image is committed.
2. **UKI** from that committed image: `bootc container ukify` computes the composefs digest of the
   root filesystem and runs `ukify` with the command line `<kargs.d> composefs=<digest>` (today `rw
   lockdown=integrity systemd.import_credentials=no composefs=…`: no root device,
   systemd-gpt-auto-generator finds the root partition by its type). It reads the committed layers (`podman run --mount type=image`), not the
   build stage: `podman build --timestamp` rewrites file times when it commits, and the digest
   covers them. bootc checks the digest again at install and update, and refuses a UKI that does
   not match.
3. **Signing outside the image build.** In CI the UKI is signed with a key made for that run only:
   generated, used once, deleted; only its certificate leaves the step (a job output), for the
   Secure Boot test. Nothing persists, nothing is cached or uploaded.
4. **Final image:** the committed root filesystem plus the signed UKI in `/boot/EFI/Linux/<kver>.efi`.

`bootc install` sees the UKI and installs only it: `EFI/Linux/bootc/bootc_composefs-<digest>.efi` on
the ESP and a boot entry of type `uki` (`loader/entries/*.conf` with a single `uki` line, no `linux`,
`initrd` or `options`). Updates do the same. External kernel arguments are refused
(`bootc install --karg` fails with a UKI), so the test console is set up differently, below.

Test versions built on top of the image (boot counting) need their own UKI, because any change
changes the digest: `tools/vm/boot-counting.sh` takes the kernel and initramfs out of the image's
UKI and runs `bootc container ukify` on the committed test image (unsigned: those boots run without
Secure Boot).

## What CI proves (`tools/vm/secure-boot.sh`)

The `install-boot` job takes the disk that `bootc install` produced and, on a copy of it:

1. checks that the ESP holds only the UKI: one `uki` entry for `EFI/Linux/bootc/bootc_composefs-<digest>.efi`,
   no kernel or initramfs file anywhere, and that UKI verifies against this run's certificate;
2. enrolls this run's UKI certificate, and a local add-on test key, as MOKs (Machine Owner Keys)
   directly in the firmware variables with `virt-fw-vars --add-mok`, on top of Ubuntu's OVMF
   variables with Secure Boot on and the Microsoft keys (this stands in for the user confirming the
   key in MokManager);
3. lays out the ESP the way the installer will: shim as `\EFI\BOOT\BOOTX64.EFI`, systemd-boot next
   to it as `grubx64.efi` (the name shim starts), MokManager as `mmx64.efi`;
4. boots it with the Secure Boot firmware (OVMF `secboot`, SMM).

| Boot | Expected | Checked in the guest or on the console |
|---|---|---|
| the image's UKI, signed with this run's key | boots | `mokutil --sb-state` = enabled, the key listed by `mokutil --list-enrolled` (only shim publishes that list), bootc's entry started through systemd-stub, kernel lockdown `[integrity]`, `composefs=<digest>` on `/proc/cmdline`, system `running` |
| the same UKI with one byte of the initramfs changed, signature kept | refused | `Error loading EFI binary \EFI\Linux\bootc\bootc_composefs-….efi: Security violation`, no system starts |
| the same UKI without a signature | refused | same |
| the same UKI signed with a key that is not enrolled | refused | same |
| unsigned add-ons (`<uki>.efi.extra.d/`, `loader/addons/`), signed add-ons in both places (a control next to the UKI, the test console for every UKI), plain credentials (`tmpfiles.extra` next to the UKI, `sysctl.extra` in `loader/credentials/`) | only the signed add-ons apply; with the test add-on (import on) the credentials are read (control) | their arguments on `/proc/cmdline`, none from the unsigned ones; neither credential sets its value; the boot is not clean (`systemd-sysctl` does not start) |
| the same credentials on the ESP, with the image's command line (only a signed add-on with `systemd.firstboot=no`) | ignored | nothing fails to start (console), where the same boot with the test add-on shows the failure (control) |
| bootc's entry + `options … nyra.injected=1` | boots, argument ignored | `nyra.injected` absent from `/proc/cmdline` |
| the image's command line (only a signed add-on with `systemd.firstboot=no`) + a credential over SMBIOS that adds a drop-in printing a marker | no effect | the marker never shows on the console after `multi-user.target` |
| the same with the test console add-on (`systemd.import_credentials=yes`) | the credential applies (control) | the marker shows; in the first boot, the drop-in's file exists |

The keys are not in the firmware's `db`, so only shim (through the MOK list) can have accepted the
signed UKI: systemd-boot loads images through shim's verification protocol, and systemd-stub does
the same for add-ons. "No system starts" means neither a kernel message nor a login prompt within
60 s. The keys made by the test live only in the job's work directory on the ephemeral runner and
are deleted at the end.

**Console access in the tests.** The sealed command line has no `console=ttyS0` and imports no
credentials, and the image does not change for the tests' sake. The test harness (`vm-boot.py`)
passes a getty on the serial port and root autologin as systemd credentials, and every test disk
gets an add-on in `loader/addons/` (for every UKI, updated ones too) with
`systemd.import_credentials=yes` (`tools/vm/test-console.sh`): systemd uses the last occurrence on
the command line, and add-ons come after the UKI's own. It is unsigned on the disks booted without
Secure Boot; the Secure Boot test replaces it with one signed by a key enrolled only there.
Kernel messages still reach the serial log in the VM:
systemd-stub itself appended `console=uart,io,0x3f8` to the command line (observed in CI; it does so
when the firmware's only console is a serial port). That is the one thing the stub adds to the
sealed command line; on a machine with a screen it adds nothing.

Not covered yet: the real installer, MokManager enrollment on a real machine, a kernel built and
signed by Nyra (today it is Debian's), and revocation: what happens when SBAT or `dbx` updates
revoke an old shim or systemd-boot.

## What remains for the real Nyra key

The flow does not change; only who signs in step 3 of `ci/build-image.sh`, and when:

- **The key** is generated offline and kept on a hardware token (or in a KMS/HSM), so that a
  compromised CI runner or developer machine cannot sign a boot image; CI and automated tooling
  never see it. Only its certificate goes into the image (for example
  `/usr/lib/nyra/secureboot/nyra.crt`), for the installer.
- **Signing:** CI builds the unsigned UKI (step 2) and the final image waits for the signed one:
  either a signing service backed by the token or KMS (`sbsign` through PKCS#11, or
  `systemd-sbsign` with a provider), or bootc's external-signing flow (the UKI is signed offline and
  injected, bootc#1498). Still to decide with a security review, together with image signing:
  both stay off until `main` is a protected branch (`docs/SIGNING.md`).
- **Enrollment:** the installer runs `mokutil --import` with that certificate; on the next boot the
  user confirms it once in MokManager (a one-time password shown by the installer). A machine whose
  owner prefers it can put the certificate in `db` instead (setup mode); shim checks `db` too.
- **Add-ons:** the Nyra key never signs a generic command-line add-on. A signed add-on applies to
  any Nyra UKI (the control add-on in the test proves that), so one such file would undo the fixed
  command line on every machine.
- **shim on the ESP:** bootc installs only systemd-boot. The installer copies shim and MokManager
  from `/usr/lib/shim/` (as the test does), and the updater must keep shim current for SBAT and
  `dbx` revocations, or a revoked shim stops booting. `bootctl update` does not overwrite shim.
- **Kernel modules** are signed by Debian today; once Nyra builds its own kernel, its modules will be
  signed with the Nyra key in the MOK list.

### What Secure Boot alone does not stop

shim trusts everything Debian signs. Anyone who can write the ESP (root on the machine, or the
disk out of the machine) can add a boot entry with a Debian-signed kernel and an initramfs of their
own: shim accepts the kernel, and nothing checks that initramfs. Secure Boot therefore keeps
unsigned code out of the boot, but does not by itself prove that the Nyra UKI booted. Two rules
follow, for the owner to confirm when TPM unlock is built:

- **TPM2 unlock never depends on PCR 7 alone** (PCR 7 says "Secure Boot on, these keys", which a
  Debian-signed boot also satisfies). It binds to a **signed policy on PCR 11** (the UKI's sections
  as measured by systemd-stub; `ukify --measure` with `--pcr-private-key`, policy signed by a Nyra
  key) **plus PCR 7**. That needs `systemd-measure`/`ukify --measure` in the signing step and the
  public PCR key in the image; not built yet.
- **An old Nyra UKI, still validly signed, can boot an old image version** if someone puts it on
  the ESP (bootc has no downgrade protection either, LESSONS). Options, not decided:
  - SBAT generations in the UKI (`.sbat` section): revoking old ones needs shim's SBAT policy
    update on every machine; coarse, and a mistake bricks boots;
  - the TPM policy: sign the PCR 11 policy with a key per release line, and stop signing old
    policies (or rotate the policy key), so an old UKI boots but no longer unlocks the disk;
  - both. Decision points for the owner: which of these, how often the policy key rotates, and
    whether an old version may still boot without unlocking (recovery) or must not boot at all.

## The kernel command line is fixed

The security review of the install and boot test (#3) found that `systemd.set_credential=` and
`systemd.unit-dropin.*` work from the kernel command line, so anyone at the keyboard could add, for
example, a root autologin from the boot menu editor. Two layers close it:

1. **`editor no`**: `/usr/lib/nyra/boot/loader.conf` is copied to the ESP's `loader/loader.conf`
   by `nyra-boot-loader-conf.service` at every boot when they differ. systemd-boot reads its
   settings only from the ESP, the editor is on by default, and `bootctl install` writes a
   loader.conf without it; there is no `/usr` hook in bootc or bootctl. The very first boot after
   installation still has the editor until that unit runs: the installer should write the file too.
2. **The sealed UKI:** systemd-stub ignores any command line passed by the boot loader when Secure
   Boot is on and the UKI has its own `.cmdline` (last row of the table above). Without Secure Boot
   the stub accepts it; there, any physical attacker can also boot another system, so that is not a
   boundary we can hold.

Credentials: the production image ignores credential files placed on the ESP (`*.cred`, which
systemd-stub passes on), together with every other source, below; the test shows a clean boot with
them present. With credential import on, systemd treats them as "untrusted" and does not use a
plain one as a setting.

The sealed command line also imports no systemd credentials at all (`systemd.import_credentials=no`,
`/usr/lib/bootc/kargs.d/20-nyra-credentials.toml`): none from firmware tables (SMBIOS, `fw_cfg`),
the kernel command line or systemd-stub. Nothing outside the signed image configures the system at
boot; settings for a machine come from the installer and from `/etc`. Only an add-on signed with an
enrolled key could turn import back on, which is why the Nyra key never signs a generic
command-line add-on. Without credentials, `systemd-firstboot` asks for its settings at the first
boot, so the installer must provide them.

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

**With UKIs** nothing changes: bootc still writes a Type #1 entry per version, of type `uki`
(`uki /EFI/Linux/bootc/bootc_composefs-<digest>.efi`), and systemd-boot counts tries on that entry's file
name exactly as before. The counter does not move into the UKI's file name: bootc refers to the UKI
by its exact path from the entry, and the UKI is not auto-discovered (it is under
`EFI/Linux/bootc/`, which systemd-boot does not scan). `nyra-boot-counter` finds the running
system's entry by the digest in the UKI's file name (or, for Type #1 kernels, in `options`).

Still to build (in `nyra-updated`, LESSONS): an automatic reboot when a health check fails (in CI
the test powers the VM off after each try), marking the failed version so it is not offered or
staged again, and the full reboot after a failed soft reboot.
