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
2. **UKI** from that committed image (`ci/ukify.sh`, with a second profile for recovery, see
   "Recovery"): `bootc container ukify` computes the composefs digest of the
   root filesystem and runs `ukify` with the command line `<kargs.d> composefs=<digest>` (today `rw
   lockdown=integrity panic=10 systemd.import_credentials=no composefs=…`: no root device,
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
- **shim on the ESP:** bootc installs only systemd-boot. `esp-sync install` puts shim and MokManager
  from `/usr/lib/shim/` on the ESP at install time, and `nyra-boot-repair` keeps them equal to the
  booted image's at every boot (see "Boot protection"), so an image with a newer shim brings it to
  the ESP for SBAT and `dbx` revocations. `bootctl update` does not overwrite shim.
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

1. **`editor no`**: `/usr/lib/nyra/boot/loader.conf` is written to the ESP's `loader/loader.conf`
   at install time (`esp-sync install`) and again by `nyra-boot-repair.service` at every boot when
   they differ. systemd-boot reads its settings only from the ESP, the editor is on by default, and
   `bootctl install` writes a loader.conf without it; there is no `/usr` hook in bootc or bootctl.
   CI checks the file on the installed disk before its first boot, and that the first boot found
   nothing to repair.
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

## Boot protection (`tools/vm/boot-protection.sh`)

The firmware has to find a boot loader even when its boot entries are gone (a firmware reset or
update), another system put itself first (Windows does after large updates), or a file on the ESP
is damaged. `/usr/lib/nyra/boot/esp-sync` keeps two independent copies of the boot files on the ESP:

| Path | Started by | Next to it |
|---|---|---|
| `\EFI\nyra\shimx64.efi` | the "Nyra OS" firmware entry | `grubx64.efi` (Debian-signed systemd-boot, the name shim starts), `mmx64.efi` (MokManager) |
| `\EFI\BOOT\BOOTX64.EFI` (shim) | any UEFI firmware, without boot entries (the fallback path) | the same two files |

Both lead to the same systemd-boot settings (`loader/loader.conf`) and entries. bootc's own copy of
systemd-boot (`\EFI\systemd\`) stays, but nothing starts it.

- **At install time** (`esp-sync install ESP`, from the image, on the new system's mounted ESP): the
  two copies and `loader.conf`, before the first boot. No firmware entry: it is created by the
  installed system itself, on the machine it runs on. bootc has no install hook, so the installer
  calls it after `bootc install`; in CI the `install-boot` job does.
- **At every boot** (`nyra-boot-repair.service`, `esp-sync repair`), each boot file is compared with
  the booted image's by the Debian version in its SBAT section (plain text in the PE file):
  - missing, or damaged (no SBAT, another component, the same version with other bytes): written
    again;
  - **newer on the ESP: kept**, with a warning in the journal (priority `warning`). A newer shim or
    systemd-boot may be there because of an SBAT or `dbx` revocation; if the machine falls back to an
    older system version (boot counting, rollback, an old entry picked in the menu), writing its older
    boot loader back could leave both copies revoked under Secure Boot;
  - **older on the ESP: replaced only from a blessed boot** (`systemd-bless-boot status` is `good` or
    `clean`), so a version still on trial never replaces a boot loader that works. The unit is not
    ordered after `systemd-bless-boot` (a health check ordered after `multi-user.target` would make
    a cycle), so the newer boot loader is written in the blessed boot or, at the latest, the next
    one. After a soft reboot (`SoftRebootsCount` above 0) the bless status is the last full boot's,
    possibly another version's: such a boot counts as not blessed.

  Each write is a new file, then a rename, so a failed write leaves the old one; `EFI/nyra` is
  written before `EFI/BOOT`, so an interrupted repair or update still leaves one complete copy. When
  it cannot repair (ESP full), the unit fails and the system shows as degraded; nothing half-written
  stays on the ESP. `loader.conf` is always made equal to the image's.

  After a full boot it also removes `loader/entries.staged`: nothing is staged yet then (bootc keeps
  the staged deployment in `/run`), so these entries are stale, left by a staging that was never
  finalized (a power cut), unless `bootc status` reports something staged by hand in the first
  seconds of the boot. It runs before `nyra-updated.service`. Stale staged entries are thus cleaned
  before a new update is staged, so the
  next update's swap brings in only its own entry and the running one (`patches/upstream/`).

  The "Nyra OS" firmware entry is created if this ESP has none (or one for another file), and put
  first in `BootOrder` again if something else was put first. Only entries for this ESP's partition
  are touched: another Nyra installation (another disk, a USB stick) keeps its entries, and
  `BootNext` (a one-time choice, such as "Restart in Windows") is left alone.
- **The fallback.** bootc makes a staged version the default at shutdown by swapping
  `loader/entries.staged` and `loader/entries` in one rename, then deleting the old set
  (`bootc-finalize-staged`). On FAT that rename is not atomic, and a power cut during it can leave
  no usable entry: systemd-boot then shows an empty menu and the machine does not boot
  (`patches/upstream/`). `esp-sync` therefore keeps a way to boot that does not depend on
  `loader/entries`, in a directory nothing writes during that swap:
  - `EFI/Linux/nyra-fallback-<digest>+0.efi`: a copy of a blessed version's UKI, signed as bootc
    installed it. systemd-boot finds UKIs in `EFI/Linux/` by itself; `+0` (no tries left) sorts it
    after every other entry, so it boots only when nothing else can. It boots that version's
    composefs image like bootc's own entry would.
  - `loader/nyra-fallback/<entry>.conf`: a copy of that version's boot entry. A full boot whose own
    entry is missing (it came up through the fallback) puts it back in `loader/entries`, with a
    warning in the journal, because bootc cannot stage the next update without it.
  - It is written at install time (the installed version), moved to the running version by
    `esp-sync repair` once that version is blessed (new file first, then the old one removed), and,
    at shutdown before a swap, moved to the running version if bootc is about to remove the version
    it points to (the last blessed one, while the running one is still on trial). It therefore
    always points to a version whose composefs image bootc keeps.
  - That move at shutdown can make a version that is **not blessed yet** the fallback: it happens
    when another update is staged while the running version is still on trial (`nyra-updated`
    stages nothing then, so in practice only an update staged by hand). This is acceptable: bootc
    keeps only the new version and the running one, so the last blessed version is deleted anyway,
    and a fallback pointing to a deleted image could not boot at all. The running version has at
    least booted to the point of shutting down cleanly; once a later version is blessed, the
    fallback moves to it.
  - **Space on the ESP.** One UKI is about 63 MB (kernel and initramfs). At most these sit on the ESP
    at once: bootc's UKIs for the booted, the rollback and a staged version, the fallback, and,
    for a moment, a second fallback (the new copy is written before the old one is removed): five
    UKIs, about 315 MB, plus the boot loaders (a few MB). On the 1 GiB ESP that `bootc install`
    creates, that leaves about 700 MB. When the ESP is full anyway, the copy fails before anything
    is replaced (a new file next to the old one, then a rename), the old fallback stays: at boot
    `esp-sync repair` fails visibly (the unit fails, the system shows as degraded); at shutdown the
    move only logs the failure, so the shutdown and bootc's swap go on.
- **The ESP is mounted only on access** (systemd's automount at `/boot`, unmounted when idle) and only
  root can read it: systemd mounts it with `fmask=0177,dmask=0077` (no bits for group and others,
  no execute bit on files); CI checks it.
- **Directory changes on the ESP reach the disk in order.** The ESP is FAT, and Linux's FAT driver
  writes directory changes in any order unless the mount is `dirsync`; `fsync` does not cover them
  all. A power cut during the shutdown with the swap of `loader/entries.staged` could leave
  `loader/entries` pointing at a freed cluster, and one after staging could leave
  `loader/entries.staged` without its `.` and `..`: Linux then reports a corrupted directory, sets
  the ESP read-only and every later update fails; `fsck.fat -a` does not repair it
  (docs/LESSONS.md). Every ESP mount is therefore `dirsync` (each directory change is written before
  the call returns): `/boot` (`boot.mount.d/10-nyra.conf`, the generator's options plus `dirsync`;
  CI checks it), the mounts `esp-sync` makes at shutdown, and bootc's own (patched in
  `ci/build-bootc.sh`, `patches/upstream/bootc-esp-dirsync.md`). bootc already writes each file to
  a temporary name, fsyncs it and renames it. After `bootc-finalize-staged`, `sync` runs
  (`bootc-finalize-staged.service.d/10-nyra.conf`): bootc detaches its mount lazily, so what it
  wrote (the old files it removed) is not necessarily on the disk when it exits.

CI follows one system through fourteen boots, with Secure Boot on and one firmware variable store kept
across them (`vm-boot.py --keep-vars`). The image's command line imports no credentials, so the test
console add-on on that disk is replaced by one signed with a key enrolled as a MOK in this test only:

| Boot | Done before it | Expected |
|---|---|---|
| 0 (no boot) | `bootc install`, then `esp-sync install` | `loader.conf` with `editor no`, both copies of the boot files as in the image, the fallback UKI and entry equal to the installed version's |
| 1 | no boot entries (fresh variable store) | boots through `\EFI\BOOT`; nothing needed repair; "Nyra OS" created, first in `BootOrder`; ESP readable only by root, mounted `dirsync` |
| 2 | | boots through `\EFI\nyra`; the test adds another entry, which is put first |
| 3 | | that entry fails (its file does not exist); "Nyra OS" boots and is first again |
| 4 | `\EFI\nyra\grubx64.efi` cut in half (an interrupted update) | the firmware falls back to `\EFI\BOOT`; the file is repaired |
| 5 | `\EFI\BOOT\BOOTX64.EFI` and `grubx64.efi` deleted | boots through "Nyra OS"; both are back |
| 6 | ESP filled, `\EFI\BOOT\grubx64.efi` changed by one byte | boots through "Nyra OS"; the repair fails visibly, no half-written file |
| 7 | space freed | the repair completes |
| 8 | a newer systemd-boot in `\EFI\BOOT` than the image's | kept |
| 9 | an older one there; this version on trial (counted entry, `boot-complete.target` fails) | not replaced yet, `systemd-bless-boot status` is `indeterminate` |
| 10 | | healthy: blessed (`good`); the image's systemd-boot is written in this boot or, at the latest, the next one |
| 11 | | `clean`; the boot files are the image's |
| 12 | `loader/entries` deleted (what a power cut during the swap can leave) | boots through the fallback UKI; the entry is put back |
| 13 | `loader/entries` emptied | the same |
| 14 | | boots through bootc's entry again; one fallback UKI, still `+0` |

"Newer" and "older" are made by changing the first digit of the Debian version in that file's SBAT
section; the copy is never started (those boots go through `\EFI\nyra`), so its broken signature
does not matter.

What the installer must still do (not part of this repository's tests): put the ESP on its own
partition for Nyra (not shared with Windows), with the GPT attributes that hide it from Windows, and
call `esp-sync install` after `bootc install`. Not covered yet: letting the user choose which system
comes first ("Nyra OS" is put first again by design; "Restart in Windows" will use `BootNext`), a
real shim update forced by an SBAT or `dbx` revocation. The recovery entry is described next.

## Recovery (`tools/vm/recovery.sh`)

The image's UKI has three profiles (a multi-profile UKI, systemd 257 and later), built by
`ci/ukify.sh` in step 2 of the sealed UKI and signed as one file in step 3:

| Profile | Title | Command line |
|---|---|---|
| 0 | Nyra OS | the one bootc writes: `<kargs.d> composefs=<digest>` |
| 1 | Nyra OS Recovery | the same plus `systemd.unit=rescue.target` |
| 2 | Nyra OS Reset settings | the same plus `systemd.unit=nyra-reset-settings.target` (see "Reset system settings") |

bootc computes the composefs digest, so `ci/ukify.sh` runs `bootc container ukify` once to read
the command line, makes the recovery profile PE file with `ukify build --profile --cmdline`, and runs
`bootc container ukify` again with `--profile` (labelling the base sections as profile 0) and
`--join-profile` (the recovery profile, profile 1, then the reset profile, profile 2). All profiles are sealed: under Secure Boot
the stub ignores any command line from the boot loader, and the only thing a boot entry chooses is
the profile (systemd-boot passes `@1`, systemd-stub honours it and reports it in `StubProfile`).

- **The menu entry** `loader/entries/nyra-recovery.CONF` (`title Nyra OS Recovery`, `uki` = a
  bootc UKI, `profile 1`, `sort-key nyra-recovery`, after bootc's `bootc-<os>-0/1` in the menu) is
  written by `nyra-boot-repair` at every boot, for the running system's UKI once that version is
  blessed (until then it stays on the version it points at, if that is still on the ESP). If that
  UKI is gone and the running one has no recovery profile, the entry is removed rather than left
  pointing at nothing. systemd-boot never picks a profile other than 0 by default.
  - **Why `.CONF`:** bootc 1.16 reads every `*.conf` in `loader/entries` as one of its deployments.
    An entry for a bootc UKI shows up as an extra "other deployment" in `bootc status` (seen in CI),
    and any other entry makes `bootc status` fail. bootc matches the suffix in lower case only, while
    systemd-boot and `bootctl` match it in any case, so the upper-case suffix keeps the entry out of
    bootc and in the menu. If bootc changes that, the CI check "one booted image in `bootc status`"
    fails.
  - The fallback UKI (`EFI/Linux/nyra-fallback-<digest>+0.efi`, see "Boot protection") is the same
    two-profile UKI, and systemd-boot lists every profile of a UKI it finds there: the menu also
    shows that version's "Nyra OS Recovery", at the end with the fallback. It is just as sealed.
  - bootc swaps `loader/entries` at every update: `esp-sync boot-counter` copies the recovery entry
    into `loader/entries.staged` at shutdown (its boot counting only renames `*.conf`), so it is there
    after the update too.
- **Authentication: an administrator's password.** Root has no password, and recovery must not be
  a root shell for anyone at the keyboard (no `SYSTEMD_SULOGIN_FORCE`). `rescue.service` runs
  `/usr/lib/nyra/boot/recovery-shell` instead of sulogin (a drop-in in `/usr`): it asks for a user
  name, accepts only members of the `sudo` group (the administrators) whose account has a usable
  password (`passwd -S` status `P`: PAM's `nullok` would let an empty password through), and checks
  the password with `su` through PAM, run as `nobody` so that it has to ask. Only then a root shell
  starts; leaving it continues to the normal boot target. A wrong password or a non-administrator
  gives a message and the prompt again, after 3 s. Control-C and Control-Z do nothing at the prompt;
  Control-D continues the normal boot (as sulogin does). `emergency.service` (a failed boot) still uses sulogin, which refuses
  a locked root: that stays as it is until the installer decides on it.
- **TPM:** profile 1 is measured differently from profile 0 (PCR 11 covers its `.cmdline` and
  `.profile`), so a PCR 11 policy signed only for profile 0 does not unlock the disk in recovery: the
  disk then needs its password or the recovery key. When TPM unlock is built, sign the PCR policy
  for the main profile only (`ukify --sign-profile=main`, the profile ID in `ci/ukify.sh`).

CI, on a copy of the installed disk, with Secure Boot on and one firmware variable store: the UKI
bootc installed verifies with this run's certificate and contains the recovery profile; a normal boot
writes the entry, and `bootc status` shows one booted image and no queued rollback; the test adds an administrator
and a plain user and picks the entry for the next boot only (`bootctl set-oneshot`). That boot runs
profile 1 (`LoaderEntrySelected`, `StubProfile`, `systemd.unit=rescue.target` on the command line,
Secure Boot on): an administrator with an empty password and a plain user are refused without a
password prompt, a wrong password gives no shell, the right one gives root in `rescue.target`.

## Reset system settings (`tools/vm/reset-settings.sh`)

When a user's changes in `/etc` break the system (`/etc/fstab`, `/etc/passwd`, the network, masked
or deleted services), the boot menu offers **"Nyra OS Reset settings"**: profile 2 of the same signed
UKI, with an entry `loader/entries/nyra-reset.CONF` kept by `nyra-boot-repair` exactly like the
recovery entry (written for the running blessed version, carried across updates, invisible to
bootc). A third profile needs no new key and keeps the command line sealed; it boots straight into
`nyra-reset-settings.target`, like `rescue.target`.

`nyra-reset-settings.service` (`/usr/lib/nyra/boot/reset-settings`) asks on the console to type
`RESET`; anything else, or Control-D, continues the normal boot and changes nothing. Then:

1. **The image's `/etc`.** bootc keeps each version's `/etc` in `/sysroot/state/deploy/<digest>/etc`
   and bind-mounts it on `/etc`. The image's own `/etc` is under that bind mount: a bind mount of `/`
   alone shows it. It is copied next to the current one, as `etc.nyra-new`.
2. **What is kept**, copied from the current `/etc` when it is valid:
   - `/etc/machine-id`: the machine's identity (the journal, the DHCP client identifier);
   - `/etc/hostname`: its name on the network;
   - **regular users** (UID 1000–59999): their lines in `passwd`, `shadow`, `subuid` and `subgid`,
     their own groups, and their membership in the image's groups (`sudo`: the administrators). Without
     them the files in `/home` would have no owner and nobody could log in, or open recovery.

   Everything else comes back from the image: mounts, network settings, enabled or masked services,
   time zone, firewall changes. `/home` and `/var` are not touched.
3. **Power cuts.** The two directories are exchanged in one step (`mv --exchange`, that is
   `renameat2` with `RENAME_EXCHANGE`), so any boot sees either the whole old `/etc` or the whole new
   one. Every `/etc` the reset builds carries a marker file (`.nyra-reset-new`) until it is in place;
   the directory is made as `etc.nyra-tmp` with the marker inside and only then renamed to
   `etc.nyra-new`, so an `etc.nyra-new` without the marker can only be the previous `/etc`. That tells
   the leftovers of an interrupted reset apart: `etc.nyra-tmp` (cut right after the directory was
   made) and an `etc.nyra-new` with the marker (cut before the switch) are removed by the next reset;
   an `etc.nyra-new` without it is the previous `/etc` (cut right after the switch), and the next reset
   keeps it as `etc.nyra-old`. Then the machine restarts into the normal boot.
4. **The previous `/etc`** stays as `etc.nyra-old` next to it, mode `0700`, for the user (or support)
   to look at. Only one is kept: the next reset replaces it, and bootc removes it with the rest of
   that version's state when the version itself is removed. That includes a previous `/etc` kept from
   an interrupted reset: the next reset keeps it at its start and replaces it at its end, so it
   survives only if that reset is interrupted too.

**Kept as is.** The kept users' lines (`passwd`, `shadow`, groups) are copied unchanged, including
their group and shell: the reset brings back broken system settings, it does not clean up an `/etc`
that someone took over. Once the disk is encrypted, `/etc/crypttab` and whatever the unlock needs must
be kept too.

**No password.** The reset grants no access: root stays locked, the users keep their passwords, and
everything that changes goes back to the image's (secure) defaults. Asking for an administrator's
password would make it useless in exactly the case it is for, a broken `/etc/passwd` or
`/etc/shadow`. It does undo an administrator's own settings, which is what it is for.

CI follows one system with Secure Boot on: a normal boot adds an administrator and a host name,
then breaks the settings (garbage in `/etc/fstab` and `/etc/passwd`, `systemd-resolved` masked,
`/etc/resolv.conf` deleted, a stray file); the reset entry answered with something else, and with
Control-D, changes nothing; a power cut as the reset starts building the new `/etc`, and another as it
switches to it, each leave `/etc` whole (all old or all new) on the next boot; a power cut right after
the switch leaves the new `/etc` in place, a running system, and the previous `/etc` as `etc.nyra-new`
(no marker); a power cut right after the new `/etc`'s directory is made leaves no `etc.nyra-new`
without its marker and `etc.nyra-old` as it was; the reset itself brings the image's `/etc` back and
reboots, and the next boot has none of the breakage, the administrator with the same password hash
and groups, the file in `/home`, the machine ID and the host name, and the previous `/etc` as
`etc.nyra-old` (`0700`).

What the installer and later work must still decide: other system data a user expects to keep (Wi-Fi
networks once NetworkManager is in the image), and a "reset everything" that also clears `/var` and
`/home` (the factory reset).

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
  that expires after two idle minutes and cannot be mounted again once shutdown has begun. When
  `nyra-updated` discarded the staged version (`/run/nyra-updated/discarded`, docs/UPDATES.md), it
  removes `entries.staged` instead, so that version is never swapped in (`nyra-updated` has removed it
  already, with `esp-sync discard`; this is the second time).
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

The automatic reboot when a health check fails, marking the failed version, the full reboot after a
soft reboot and the real health checks are in `nyra-updated` and its units (`docs/UPDATES.md`, tested
in `tools/vm/updates.sh`).
