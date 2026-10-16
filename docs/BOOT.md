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
   root filesystem and runs `ukify` with the command line `<kargs.d> composefs=<digest>` (today
   `lockdown=integrity panic=10 rw rd.shell=0 rd.emergency=reboot systemd.import_credentials=no systemd.image_policy=… composefs=…`, pinned in
   `ci/uki-cmdline.txt`: no root device,
   systemd-gpt-auto-generator finds the root partition by its type). It reads the committed layers (`podman run --mount type=image`), not the
   build stage: `podman build --timestamp` rewrites file times when it commits, and the digest
   covers them. bootc checks the digest again at install and update, and refuses a UKI that does
   not match.
3. **Signing outside the image build.** First the PCR 11 policy of the main profile, for the
   initrd only (see "TPM2 unlock" below), then the whole UKI for Secure Boot. In CI both keys are
   made for that run only: generated, used once, deleted; only the UKI certificate (a job output,
   for the Secure Boot test) and the policy's public key leave the step. Nothing persists, nothing
   is cached or uploaded. The step signs exactly one file, and only the sealed UKI: a kernel and
   exactly the command lines of `ci/uki-cmdline.txt` and the Nyra SBAT component
   (`tools/signing/uki-check.py`, docs/SIGNING.md), with the policy signed for the main profile's
   initrd alone (`tools/signing/pcr-policy.py check`).
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
| the image's command line (only a signed add-on with `systemd.firstboot=no`) + the same credential + over SMBIOS `io.systemd.stub.kernel-cmdline-extra=systemd.import_credentials=yes …` (for systemd-stub) and `io.systemd.boot.kernel-cmdline-extra=…` (for systemd-boot) | the stub appends its string (the platform is trusted, see "The kernel command line is fixed"), so the credential applies; systemd-boot's is ignored | the stub's string last on `/proc/cmdline`, systemd-boot's absent; the drop-in's file exists |

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
when the firmware's only console is a serial port). Apart from what the firmware passes over SMBIOS
(see "The kernel command line is fixed"), that is the one thing the stub adds to the sealed command
line; on a machine with a screen it adds nothing.

Not covered yet: the real installer, MokManager enrollment on a real machine, a kernel built and
signed by Nyra (today it is Debian's), and revocation: what happens when SBAT or `dbx` updates
revoke an old shim or systemd-boot.

## What remains for the real Nyra key

The flow does not change; only who signs in step 3 of `ci/build-image.sh`, and when:

- **The key** is generated offline and kept on a hardware token (or in a KMS/HSM), so that a
  compromised CI runner or developer machine cannot sign a boot image; CI and automated tooling
  never see it. Only its certificate is committed, as `files/usr/lib/nyra/secureboot/nyra.crt`: it
  goes into the image for the installer, and the release gate (docs/SIGNING.md) refuses to sign an
  image whose UKI it did not sign. Until it is committed, no image gets a release signature.
- **Signing:** CI builds the unsigned UKI (step 2) and the final image waits for the signed one:
  either a signing service backed by the token or KMS (`sbsign` through PKCS#11, or
  `systemd-sbsign` with a provider), or bootc's external-signing flow (the UKI is signed offline and
  injected, bootc#1498). Still to decide with a security review; until then it stays off, like
  image signing (`docs/SIGNING.md`).
- **Enrollment:** the installer runs `mokutil --import` with that certificate; on the next boot the
  user confirms it once in MokManager (a one-time password shown by the installer). A machine whose
  owner prefers it can put the certificate in `db` instead (setup mode); shim checks `db` too.
- **Add-ons:** the Nyra key never signs a generic command-line add-on. A signed add-on applies to
  any Nyra UKI (the control add-on in the test proves that), so one such file would undo the fixed
  command line on every machine. The signing step and the release gate enforce it
  (`tools/signing/uki-check.py`); whatever signs with the real key must run that check first.
- **shim on the ESP:** bootc installs only systemd-boot. `esp-sync install` puts shim and MokManager
  from `/usr/lib/shim/` on the ESP at install time, and `nyra-boot-repair` keeps them equal to the
  booted image's at every boot (see "Boot protection"), so an image with a newer shim brings it to
  the ESP for SBAT and `dbx` revocations. `bootctl update` does not overwrite shim.
- **Kernel modules** are signed by Debian today; once Nyra builds its own kernel, its modules will be
  signed with the Nyra key in the MOK list.

### What Secure Boot alone does not stop

shim trusts everything Debian signs, so Secure Boot keeps unsigned code out of the boot but does not
by itself prove that the Nyra UKI booted: a Debian-signed kernel with another initramfs passes it
too. Disk unlock therefore depends on what the TPM measured, not on Secure Boot alone:

- **TPM2 unlock never depends on PCR 7 alone** (PCR 7 says "Secure Boot on, these keys", which any
  boot through shim also satisfies). It binds to the **signed policy on PCR 11** (the Nyra UKI's
  main profile, "TPM2 unlock" below) **plus PCR 7**.
- **An old Nyra UKI, still validly signed, can boot an old image version** if someone puts it on
  the ESP (bootc has no downgrade protection either, LESSONS). Both answers are used:
  - **SBAT generations** in the UKI (`.sbat` section) for versions that must not boot at all
    (coarse, so for serious cases only). The component is in every UKI, but a revocation reaches
    machines only through a shim that carries it ("SBAT" below);
  - **rotating the PCR policy key**: an old UKI carries a policy signed with an old key, so once
    machines are enrolled with the new key it may still boot, but it no longer unlocks the disk
    (it asks for the password or the recovery key). How the rotation works is in "TPM2 unlock".

## Disk encryption (`tools/vm/install-encrypted.sh`, `tools/vm/encryption.sh`)

The root file system is encrypted with LUKS2, and nothing about it is in the boot chain: the sealed
command line has no `rd.luks.*` argument and the image has no `/etc/crypttab`. In the initrd,
systemd-gpt-auto-generator finds the root partition by its type ("Finding the root partition"), sees
LUKS on it and sets up `systemd-cryptsetup@root.service` for `/dev/gpt-auto-root-luks`; the opened
volume is `/dev/mapper/root`. The unlock therefore reads nothing from `/etc`, and works the same after
"Reset settings".

**The disk** (what the installer creates; `tools/vm/install-encrypted.sh` does the same in CI):
- GPT with the ESP (1 GiB, FAT) and the root partition, with the Discoverable Partitions root type
  of the architecture (x86-64: `4f68bce3-e8cd-4db1-96e7-fbcaf984b709`), on the disk of the ESP, so that
  `LoaderDevicePartUUID` leads to it;
- LUKS2 on the root partition: aes-xts-plain64 with a 512-bit key, 4096-byte sectors, discards
  allowed (a flag in the header, so TRIM reaches the SSD; the price is that the disk shows which
  blocks are unused, not what they held);
- ext4 with fs-verity on the opened volume, then `bootc install to-filesystem --root-mount-spec ""`
  (no `root=`: the initrd finds it by its type) and `esp-sync install`.

**Key slots:**
- **the recovery key, always**: systemd-cryptenroll's `--recovery-key`, 256 bits written as 64
  characters in 8 groups, from an alphabet whose letters sit in the same place on QWERTY, QWERTZ and
  AZERTY keyboards, with a `systemd-recovery` token. Every prompt for the disk accepts it in place of
  the password. It is shown to the user once, at installation, and never written to a log. Its key
  slot has the minimal key derivation (PBKDF2, as systemd-cryptenroll sets it): 256 random bits need no
  slow derivation;
- **a password**, on a machine without a TPM: argon2id, with cryptsetup's own benchmark on the machine
  (the installer runs there): about 2 s, up to 1 GiB of memory, less on a machine with little memory.
  What protects a password is that cost against an attack on a copy of the header, not the number of
  tries at the prompt (unlimited, below), so the installer must also require a minimum argon2id memory
  and a minimum password strength. The initrd reads the keyboard as US, since it has no user settings,
  so the installer accepts only password characters that sit in the same place on the user's layout;
- **with a TPM (not yet):** the TPM2 enrollments of "TPM2 unlock" below, made by the installed system
  in its initrd at its first boot, never by the installer: PCR 7 and 12 must be the installed boot's,
  after the separator. The recovery key stays in every case.

**Never locked out.** In the initrd (all three in the initramfs):
- the root device has no time limit (`dev-gpt\x2dauto\x2droot.device.d`): an encrypted root appears only
  once its passphrase is typed, and a recovery key read off paper can take longer than systemd's 90 s
  for a device, after which the initrd would end in emergency mode and restart;
- a root partition, plain or encrypted, must still appear within 90 s (`nyra-root-wait.service`), or
  the initrd goes to emergency mode as before ("Finding the root partition");
- after three wrong passphrases systemd-cryptsetup gives up; it is started again
  (`systemd-cryptsetup@root.service.d`), so the prompt comes back as long as it takes, without a
  restart.

**Only the root and the ESP of the root's disk.** The sealed command line has
`systemd.image_policy=root=encrypted+unprotected+absent:esp=unprotected+absent:=ignore`
(`/usr/lib/bootc/kargs.d/20-nyra-image-policy.toml`): in the running system, systemd-gpt-auto-generator
uses the root partition and the ESP and ignores every other partition type on that disk (swap,
`/home`, `/srv`, `/var`, `/var/tmp`, ...). Without it, someone with the disk in hand could add an
unencrypted swap or `/var/tmp` partition to the GPT, which is not measured, and the system would write
memory or temporary files there in the clear. Nyra uses none of those partitions.

**The ESP of an encrypted root.** The running system mounts the ESP of the root's disk at `/boot`
(systemd-gpt-auto-generator), and finds that disk through `/run/systemd/volatile-root`, which bootc
points at `/dev/gpt-auto-root`: for an encrypted root, the opened volume, whose disk systemd does not
look for. `nyra-luks-root.service` (initrd only) points it at the LUKS2 partition first, as systemd
itself finds the disk of an encrypted root file system; bootc keeps a link that is already there.

**What CI proves** (`tools/vm/encryption.sh`, `install-boot` job, Titanic T10): the image installed on
its own disk as above, booted without a TPM, the passphrase prompt answered on the serial console:

| Check | Result |
|---|---|
| The partition table and the LUKS2 header, read offline | the layout and format above; one password key slot (argon2id), one recovery key slot with its token, no other token |
| The password (first boot, kept on the disk) | unlocks in the initrd; the root is `/dev/mapper/root`, LUKS2 with discards; the ESP mounted at `/boot`; the system `running` |
| The recovery key | unlocks in place of the password |
| A wrong password, then the recovery key 120 s later | asked again; the late key still unlocks |
| Three wrong passwords | asked again, without a restart; the password unlocks it |
| Unencrypted swap, `/var/tmp` and `/srv` partitions added to the disk | not swapped to, not mounted; the ESP still at `/boot`; the control: gpt-auto run with a command line without the image policy makes a swap unit for the added partition |
| Both secrets, searched for | not in the serial logs or the job summary, not in the unencrypted part of the disk (ESP, LUKS2 header), not in the decrypted root file system (the journal included) |

**Known limits.**
- The passphrase prompt is on the console until the graphical unlock screen comes: what is typed
  before the prompt appears, or in the second between two prompts after a wrong passphrase, is shown on
  the screen in the clear (never in a log).
- aes-xts protects what is on the disk from being read, not from being changed: the root file system
  has no integrity protection of its own, so someone with the disk in hand can corrupt chosen sectors
  of `/etc` or `/var` (not read them). `/usr` is verified (composefs and fs-verity). Most distributions
  encrypt this way; LUKS2 integrity costs speed and space.
- The root is found by its type on the disk the boot came from. Without a TPM nothing proves to the
  user that the prompt comes from their own system: someone who replaces the boot files can show a
  prompt of their own and take the passphrase (encryption without attestation cannot tell). With a TPM,
  the disk unlocks only for the measured, signed boot ("TPM2 unlock").

Not covered yet: everything with a TPM (the first-boot enrollment, updates, Secure Boot turned off, a
changed PCR 7 or 12, a cleared or missing TPM, the policy key's rotation, the PIN).

## TPM2 unlock: the signed PCR policy

The disk will be encrypted (LUKS) and, on a machine with a TPM, unlock by itself at boot only when
the Nyra UKI's main profile booted. This repository builds the signed policy into the UKI, checks
it, and tests the unlock it authorizes with a software TPM (`tools/signing/tpm-unlock.sh`, "The
software-TPM test" below); enrolling a user's disk comes later, from the installed system's initrd
("Disk encryption" above).

**What is measured.** systemd-stub measures the UKI's sections into PCR 11 before it starts the
kernel: `.linux`, `.osrel`, `.cmdline`, `.initrd`, `.uname`, `.sbat`, `.pcrpkey` and `.profile`,
each as its name and the SHA-256 of its content. A profile's own sections replace the base ones, so
each profile gives another PCR 11: the recovery and reset profiles differ in `.cmdline` and
`.profile`. systemd then adds the boot phases: `enter-initrd` when the initrd starts, `leave-initrd`
when it ends, then `sysinit` and `ready` in the system. That is systemd-pcrphase, from the
`systemd-tpm` package in the image and dracut's `systemd-pcrextend` module in the initramfs. Without
it PCR 11 would never match the signed policy. The other units that package enables (systemd-pcrlock
among them) are blocked; which stay and what they cost is in docs/DEFAULTS.md.

**What is signed: the initrd only.** One policy is signed: the main profile's PCR 11 in the
`enter-initrd` phase, with the policy reference `initrd`. The disk therefore unlocks only while the
initrd runs. Once `leave-initrd` is measured, PCR 11 matches no signed policy, so a program that
becomes root on the running system cannot get the disk's key out of the TPM. The reference keeps
this signature from serving any other purpose of the same key: the TPM accepts it only for an
enrollment that names `initrd`.

`ci/ukify.sh` (no key there) builds the UKI with the policy's public key as `.pcrpkey` and, for the
main profile only (`--sign-profile main`), a `.pcrsig` section with the TPM2 PolicyPCR digest to sign
(`--sign-initrd-pcrs`: PCR 11, SHA-256 bank, `enter-initrd`, reference `initrd`). Without a key, ukify
cannot leave out the digests of the four phases without a reference, so they are there too. They are
never signed, and an unsigned entry authorizes nothing: systemd looks for a signature by the
enrolled key, with the enrolled reference.

Step 3 of `ci/build-image.sh` signs with the policy key (`tools/signing/pcr-policy.py sign`), puts
the signature into `.pcrsig` with the image's `ukify --join-pcrsig`, and only then signs the whole
UKI for Secure Boot. **The signer checks before it signs:**
- it computes the main profile's `enter-initrd` policy itself, from the UKI's sections as the stub
  measures them;
- it signs that computed data, never a digest read from `.pcrsig`;
- it refuses the UKI unless `.pcrsig` asks for exactly that policy, in the main profile alone, for
  the key's own `.pcrpkey`, with no signature yet.

With the real key a signature is a credential: it unlocks every boot whose PCR 11 has that value,
until the key is rotated, whatever happens to the file afterwards. So whatever signs with the real key
(a KMS or a hardware token) must run this check first.

The recovery and reset profiles get no `.pcrsig`: nothing signs their PCR 11, so they can never
unlock the disk through the TPM.

**What is checked** (`pcr-policy.py check`, in the signing step and in the release gate,
docs/SIGNING.md):
- `.pcrpkey` is the expected key;
- exactly one `.pcrsig`, in the profile with `ID=main` (profile 0);
- every policy in it is SHA-256, PCR 11 only, for that key, with no reference other than `initrd`;
- exactly one policy is signed: the main profile's `enter-initrd` policy with the reference `initrd`.
  The script computes it again from the UKI's sections (not with systemd-measure) and checks that it
  is no other profile's. Its signature must verify over that computed data.
- A signature for a later phase, for another profile or without the reference is refused.

CI tests both verbs on a UKI built by `ci/ukify.sh` with a policy key of the test
(`tools/signing/test-pcr-policy.sh`). systemd-measure signs the same policy with the same signature,
and every refusal above is checked with its reason.

**What the enrollment must bind** (the installed system enrolls its disk; the software-TPM test below
enrolls a throwaway one the same way): `systemd-cryptenroll --tpm2-public-key=<.pcrpkey>
--tpm2-public-key-pcrs=11 --tpm2-public-key-policyref=initrd --tpm2-pcrs=7+12`, so that unlock needs:
- the signed PCR 11 policy (the Nyra UKI's main profile, in the initrd);
- PCR 7 as enrolled (Secure Boot on, the same keys): never PCR 7 alone;
- **PCR 12 at its value without add-ons**: systemd-stub measures add-ons and credentials from the
  ESP into PCR 12, and a Nyra machine has none (the Nyra key never signs an add-on, the release
  gate refuses any next to the UKI), so anything placed there stops the unlock. The same holds for a
  command line the firmware passes over SMBIOS, which the stub also measures into PCR 12.

The sealed command line has `rd.shell=0 rd.emergency=reboot`
(`/usr/lib/bootc/kargs.d/15-nyra-initrd.toml`): a failure in the initrd reboots instead of opening a
shell, before or after the disk is unlocked. `systemd.import_credentials=no` stays. systemd-cryptsetup
talks to the TPM over an encrypted session (parameter encryption, salted with the TPM's storage key)
by itself.

**The policy key.** In CI it is made for each run, like the UKI key, and deleted after signing. The
real one is described in docs/SIGNING.md ("The PCR policy key"): kept like the UKI key, outside CI,
with only its public half committed, and rotated, with the next key enrolled in advance.

**The software-TPM test** (`tools/signing/tpm-unlock.sh`, `install-boot` job). The signing step and
the release gate prove the policy is *signed* right; this proves the policy *unlocks* right, with the
image's own systemd (262) and a software TPM (swtpm). No VM and no KVM: systemd-stub measures the
UKI's sections into PCR 11 and systemd-pcrextend adds one word per boot phase (`enter-initrd`, then
`leave-initrd`, `sysinit`, `ready`), so `tools/signing/tpm-replay.py` replays that sequence (the
stub's section reading is `pe_sections.py`, the PCR 11 algorithm is `pcr-policy.py`'s) to bring swtpm
to any phase of any profile, from a power-on each time (the TPM is restarted on its state, so PCR 11
resets to 0 while the seed and storage root key persist, as between two boots). Every replayed state
is anchored: the PCR 11 swtpm then holds must equal what the image's `systemd-measure calculate`
gives for that profile and phase, or the test fails. A throwaway LUKS2 disk, with a random key
generated here and deleted at the end, is enrolled with the binding above, and the test checks for
each state whether the TPM releases the key, and why:

| State / enrollment | Unlock | Reason checked in the log |
|---|---|---|
| main profile, `enter-initrd` (the signed policy) | **yes** | the key unsealed, over an encrypted (HMAC) session |
| main profile, `leave-initrd`, `sysinit` or `ready` (the running system) | no | no signature for that PCR 11 policy |
| recovery profile, reset profile | no | no signature for that PCR 11 policy |
| an add-on measured into PCR 12 | no | the policy from the PCRs is not the one the key was sealed with |
| the `enter-initrd` signature replayed onto the next phase's policy | no | the TPM rejects the signature |
| an enrollment without the `initrd` reference | no | no signature without the reference (the TPM would refuse it too: the signature covers the policy and the reference) |

"Unlock" is systemd-cryptsetup reaching the key unsealing; activating the device-mapper target
afterwards needs no TPM and is not part of the check. A `.pcrsig` that also signed the later phases
makes the `leave-initrd`, `sysinit` and `ready` rows fail (checked when the test was written). NvPCRs: the test
checks that the image ships no NvPCR definitions (`/usr/lib/nvpcr`), so `systemd-tpm2-setup` has
none to allocate (docs/DEFAULTS.md); that unit itself does not run in the test.

Not covered here, and left for the encryption work: a real encrypted boot through the initrd with a
TPM attached to the VM (no TPM unit failing, the forced reboot on a missed `leave-initrd`, the way
out of a reboot loop with the TPM turned off). The password and the recovery key are tested without a
TPM ("Disk encryption" above).

## SBAT

Every UKI's `.sbat` section carries, after the stub's and ukify's own lines, the Nyra component
(`ci/ukify.sh`):

```
nyra,1,Nyra OS,nyra-base,1,https://github.com/NyraOS/nyra-base/blob/main/docs/BOOT.md
```

The second field is the generation. The signing step and the release gate refuse a UKI without
exactly one such line (`tools/signing/uki-check.py`).

**Revoking every older Nyra UKI** (a flaw serious enough that no older version may boot, for
example in the initramfs or the command line):
1. raise the generation in `ci/ukify.sh` (`nyra,2,…`) in the release that fixes it;
2. deliver the revocation `nyra,2` to the machines in shim's SBAT policy (the `SbatLevel` variable).
   shim verifies every UKI that systemd-boot starts, and then refuses one with `nyra,1`, wherever it
   comes from (to be proven in a VM test when the revocation exists).

Step 2 is not possible yet: only shim writes `SbatLevel`, from the policy built into it, and the shim
in the image is Debian's, which will not carry a Nyra revocation. So it needs a shim signed for
Nyra, a separate step with its own review. Until then, the answer to an old UKI that still boots is
the rotation of the PCR policy key: it may boot, but it no longer unlocks the disk.

## The kernel command line is fixed

A security review of the install and boot test found that `systemd.set_credential=` and
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
command-line add-on, or the platform itself (below). Without credentials, `systemd-firstboot` asks
for its settings at the first boot, so the installer must provide them.

**The platform is trusted.** systemd-stub appends the SMBIOS OEM string
`io.systemd.stub.kernel-cmdline-extra` to the command line even under Secure Boot (upstream treats
SMBIOS as set by the firmware or a VM's host, and ignores it only in a confidential VM), after the
UKI's own `.cmdline` and the add-ons. Whoever sets SMBIOS can therefore add kernel arguments, and the
last occurrence wins: `systemd.import_credentials=yes` turns credential import back on (CI shows it,
table above). That is the firmware, or a VM's host, which can already run whatever it wants below the
system; the command line under Secure Boot is no boundary against it. What it cannot do is unlock
the disk: the stub measures the string into PCR 12, which the TPM2 enrollment will bind ("TPM2 unlock" above).
systemd-boot's own SMBIOS string (`io.systemd.boot.kernel-cmdline-extra`) only reaches the boot
loader's command line, which the stub ignores under Secure Boot.

## Finding the root partition

The command line names no root device. In the initrd, systemd-gpt-auto-generator makes
`sysroot.mount` wait for `/dev/gpt-auto-root`, a symlink that udev creates (`90-image-dissect.rules`)
for the partition marked `ID_PART_GPT_AUTO_ROOT=1`. That mark comes from the probe of the whole disk
(blkid builtin, `60-persistent-storage.rules`): it reads the EFI variable `LoaderDevicePartUUID`
(the ESP that systemd-boot started from) and, if that ESP is on the disk, records the root
partition's UUID on the disk (`ID_PART_GPT_AUTO_ROOT_DISK=1`, `ID_PART_GPT_AUTO_ROOT_UUID`); the
partitions, probed after the disk, compare their UUID with it. systemd (262) reads the variable
once: when that read fails the disk is never marked, nothing probes it again, and the initrd waits
90 s for its root, then gives up (emergency mode, which reboots: `rd.emergency=reboot`).

In CI that happened in two boots out of thousands (install and boot test: once in "Boot protection",
once in "Secure Boot"). The emergency diagnostics of the second one show the whole disk without
`ID_PART_GPT_AUTO_ROOT_DISK` and `ID_PART_GPT_AUTO_ROOT_UUID`, so its root partition without the
mark, while the variable named the ESP on that disk. The generator had read the same variable a
moment earlier (it reads the whole value) and it read fine at the end: only the disk probe went
without it. In both boots, and in none of the other 182 in those runs, one CPU stopped answering
for one second exactly then (`clocksource: Watchdog remote CPU 1 read timed out`, and everything
that waited for that CPU one second late), most likely a firmware (SMM) variable access that hung
and failed. The firmware or the kernel may fail that read now and then (systemd already retries
it when it is interrupted); systemd giving up after one failed read is what turns it into a
machine that does not start.

`/usr/lib/udev/rules.d/61-nyra-gpt-auto-root.rules`, in the initrd (`install_items`), probes once
more a GPT disk that the first probe did not mark, only in the initrd and only when systemd-boot set
`LoaderDevicePartUUID`: the blkid builtin runs once per event, so the rule sends a "change" event to
the disk and its partitions (`udevadm trigger --parent-match`). "add" only, so there is one more
try at most; on a disk that is not the boot disk the second probe finds nothing, as the first. The
upstream change is in `patches/upstream/systemd-gpt-auto-root-efivar-read.md`.

`tools/vm/boot-repeat.sh` (image.yml, `boot-rounds`) proves it: a test-only udev rule puts a 1-byte
file over the variable for the first probe of the boot disk, inside systemd-udevd's own mount
namespace. With the image's rule masked the initrd waits in vain, as in the boots that failed; with
it the system starts. Then the same boot, without the test rule, many times on six runners. Both
boots also run in install-boot for every image, so that a systemd or dracut update that changes the
order of the rules or leaves the rule out of the initrd fails there.

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
- **The ESP is read-only at `/boot`** (see "The ESP is read-only" below) and only root can read it:
  `fmask=0177,dmask=0077` (no bits for group and others, no execute bit on files); CI checks it.
- **Directory changes on the ESP reach the disk in order.** The ESP is FAT, and Linux's FAT driver
  writes directory changes in any order unless the mount is `dirsync`; `fsync` does not cover them
  all. A power cut during the shutdown with the swap of `loader/entries.staged` could leave
  `loader/entries` pointing at a freed cluster, and one after staging could leave
  `loader/entries.staged` without its `.` and `..`: Linux then reports a corrupted directory, sets
  the ESP read-only and every later update fails; `fsck.fat -a` does not repair it
  (docs/LESSONS.md). Every ESP mount is therefore `dirsync` (each directory change is written before
  the call returns): `/boot` (`boot.mount.d/10-nyra.conf`, the generator's options with `ro` and
  `dirsync`; CI checks it; a remount keeps the flag), and bootc's own (patched in `ci/build-bootc.sh`,
  `patches/upstream/bootc-esp-dirsync.md`). bootc already writes each file to
  a temporary name, fsyncs it and renames it. After `bootc-finalize-staged`, `sync` runs
  (`bootc-finalize-staged.service.d/10-nyra.conf`): bootc detaches its mount lazily, so what it
  wrote (the old files it removed) is not necessarily on the disk when it exits.

CI follows one system through sixteen boots, with Secure Boot on and one firmware variable store kept
across them (`vm-boot.py --keep-vars`). The image's command line imports no credentials, so the test
console add-on on that disk is replaced by one signed with a key enrolled as a MOK in this test only:

| Boot | Done before it | Expected |
|---|---|---|
| 0 (no boot) | `bootc install`, then `esp-sync install` | `loader.conf` with `editor no`, both copies of the boot files as in the image, the fallback UKI and entry equal to the installed version's |
| 1 | no boot entries (fresh variable store) | boots through `\EFI\BOOT`; nothing needed repair; "Nyra OS" created, first in `BootOrder`; ESP readable only by root, mounted read-only and `dirsync` at boot (not on access) |
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
| 15 | a drop-in in `/etc` that makes the ESP's file system check fail | `boot.mount` fails; `esp-writable` refuses with an error in the journal and the random seed on the ESP is unchanged; no FAT file system mounted; `nyra-updated` does not run; the health checks pass and the system starts, with only the check and the random seed failed |
| 16 | that drop-in removed | the ESP checked and mounted read-only again, the repair runs, `esp-writable` writes (a new random seed) |

"Newer" and "older" are made by changing the first digit of the Debian version in that file's SBAT
section; the copy is never started (those boots go through `\EFI\nyra`), so its broken signature
does not matter.

### The ESP is read-only

Root can delete anything it can reach, and `rm -rf --no-preserve-root /` reaches every mounted file
system. The ESP used to be mounted read-write on access (systemd-gpt-auto-generator's automount at
`/boot`, which `systemd-boot-update`, `bootctl` and `systemd-bless-boot` trigger), so whether it was
mounted at a given moment was a matter of chance. In the Titanic hostile root test it was, and the
delete removed shim, systemd-boot, the UKIs and the fallback path, so the
machine no longer booted at all, not even into recovery. It also removes the `Boot####` and
`BootOrder` firmware variables: efivarfs lets root delete those standard variables (others are
immutable). That alone does not stop the boot: the firmware then starts the fallback path,
`\EFI\BOOT\BOOTX64.EFI`, and `esp-sync repair` creates the "Nyra OS" entry again (boot 1 above).
So the ESP must stay intact:

- **`/boot` is read-only for every process.** `boot.mount` (the generator's mount unit) mounts the
  ESP read-only from the start of the boot (`local-fs.target.d/10-nyra.conf` wants it); the automount
  is blocked (`boot.automount.d/10-nyra.conf`). A write through `/boot` fails with "Read-only file
  system", whoever makes it. Reading needs nothing special (`bootctl`, `systemd-bless-boot status`,
  `bootc status`).
- **Writers use `/usr/lib/nyra/boot/esp-writable COMMAND`**: it runs the command in a mount namespace
  of its own, where `/boot` is remounted read-write. That makes the file system itself
  writable, but read-only is also a flag of each mount, and every other process's `/boot` keeps it.
  bootc does exactly this for its own writes (a remount of the existing mount in its namespace).
  It only remounts what `boot.mount` mounted after the ESP's file system check: when `/boot` is not
  mounted (the check or the mount failed), it writes nothing and logs an error that points to
  `journalctl -u boot.mount` (see "Mounts from /etc/fstab").
  Through it: `esp-sync` (`repair`, `boot-counter`, `discard`; it runs itself again under
  `esp-writable`), `systemd-bless-boot good` and `bootctl random-seed` (drop-ins that replace their
  `ExecStart=`). `systemd-boot-update.service` is blocked instead (docs/DEFAULTS.md): it would write
  a newer systemd-boot over `EFI/BOOT/grubx64.efi` from a version still on trial; `esp-sync` keeps
  the boot files.
- Once something has written, the FAT file system stays mounted read-write underneath until the
  shutdown, as on a system that keeps its ESP mounted: a power cut leaves the FAT "dirty" flag set,
  which nothing depends on. The directory changes themselves are ordered by `dirsync` (above).
- Root can still remount `/boot` read-write on purpose, or write the disk directly: this stops a
  delete that walks the file system, not an administrator who means it.

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
| 2 | Nyra OS Reset settings | the same plus `systemd.unit=nyra-reset-settings.target fstab=no` (see "Reset system settings") |

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
  the password with `su` through PAM, run as `nobody` so that it has to ask. `nobody` is given by
  number (UID and GID 65534): name lookups read only `/etc/passwd` and `/etc/group`, which may have
  lost the account exactly when recovery is needed (Titanic T8). Only then a root shell
  starts; leaving it continues to the normal boot target. A wrong password or a non-administrator
  gives a message and the prompt again, after 3 s. Control-C and Control-Z do nothing at the prompt;
  Control-D continues the normal boot (as sulogin does). `emergency.service` (a failed boot) still uses sulogin, which refuses
  a locked root: that stays as it is until the installer decides on it.
- **TPM:** profile 1 is measured differently from profile 0 (PCR 11 covers its `.cmdline` and
  `.profile`), and the PCR policy is signed for the main profile only (`--sign-profile main` in
  `ci/ukify.sh`), so recovery does not unlock the disk through the TPM: the disk then needs its
  password or the recovery key ("TPM2 unlock").

CI, on a copy of the installed disk, with Secure Boot on and one firmware variable store: the UKI
bootc installed verifies with this run's certificate and contains the recovery profile; a normal boot
writes the entry, and `bootc status` shows one booted image and no queued rollback; the test adds an administrator
and a plain user and picks the entry for the next boot only (`bootctl set-oneshot`). That boot runs
profile 1 (`LoaderEntrySelected`, `StubProfile`, `systemd.unit=rescue.target` on the command line,
Secure Boot on): an administrator with an empty password and a plain user are refused without a
password prompt, a wrong password gives no shell, the right one gives root in `rescue.target`.

## Reset system settings (`tools/vm/reset-settings.sh`)

When a user's changes in `/etc` break the system (`/etc/fstab`, `/etc/passwd`, the network, masked
or deleted services), the boot menu offers **"Nyra OS Reset settings"**. When a health check fails
on a version that is not on trial, the login console and the message after a login point there
(`docs/UPDATES.md`, "The version or the settings"). It is profile 2 of the same signed
UKI, with an entry `loader/entries/nyra-reset.CONF` kept by `nyra-boot-repair` exactly like the
recovery entry (written for the running blessed version, carried across updates, invisible to
bootc). A third profile needs no new key and keeps the command line sealed; it boots straight into
`nyra-reset-settings.target`, like `rescue.target`. Its `fstab=no` makes systemd ignore `/etc/fstab`,
in the initramfs too: whatever the user wrote there, the reset's question comes at once, and the image
mounts nothing from it (its `/etc` has no `fstab`).

`nyra-reset-settings.service` (`/usr/lib/nyra/boot/reset-settings`) asks on the console to type
`RESET`; anything else, or Control-D, continues the normal boot and changes nothing. Then:

1. **The image's `/etc`.** bootc keeps each version's `/etc` in `/sysroot/state/deploy/<digest>/etc`
   and bind-mounts it on `/etc`. The image's own `/etc` is under that bind mount: a bind mount of `/`
   alone shows it. It is copied next to the current one, as `etc.nyra-new`.
2. **What is kept**, copied from the current `/etc` when it is valid:
   - `/etc/machine-id`: the machine's identity (the journal, the DHCP client identifier);
   - `/etc/hostname`: its name on the network;
   - **regular users** (UID and primary GID 1000–59999): their lines in `passwd`, `shadow`, `subuid`
     and `subgid`, their own groups, and their membership in the image's groups (`sudo`: the
     administrators). Without them the files in `/home` would have no owner and nobody could log in,
     or open recovery. A line is kept only if both its name and its IDs (UID and primary GID, or
     GID) qualify, and a name that appears twice in `passwd`, `shadow`, `group` or `gshadow` is not
     kept at all: which line would be the account? A user's range of subordinate IDs (`subuid`,
     `subgid`, for containers) is kept only if it is that name's only line in the file, numeric, and
     starts at 100000 or above, as `useradd` assigns them (`SUB_UID_MIN`): lower IDs belong to the
     system and to the users themselves, which no user's containers may map. The account itself is
     kept either way.

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
that someone took over. An encrypted disk needs nothing from `/etc` to unlock ("Disk encryption").

**No password.** The reset grants no access: root stays locked, the users keep their passwords, and
everything that changes goes back to the image's (secure) defaults. Asking for an administrator's
password would make it useless in exactly the case it is for, a broken `/etc/passwd` or
`/etc/shadow`. It does undo an administrator's own settings, which is what it is for.

**No first-boot questions.** With `/etc` emptied (or without a machine ID), systemd counts the boot as
the first one: systemd-sysusers creates root again with the password `!unprovisioned`, and
systemd's `systemd-firstboot` would ask for a root password, so whoever is at the console could set
one, and, without credentials, a time zone. A drop-in in `/usr`
(`systemd-firstboot.service.d/10-nyra.conf`) changes two things:

- **Never a root password question**, on every boot: it runs systemd's own command line without
  `--prompt-root-password` (the image build fails when systemd's line changes, so the copy is
  checked again). Root stays locked (`!unprovisioned`) on a normal boot with `/etc` emptied. The
  other questions stay as they were: the locale, the keymap (on a local console, not a serial one)
  and the time zone, each only when it is not set yet (the installer is to set them). `systemd-firstboot`
  still sets root's password from the `passwd.*` credentials, as systemd-sysusers does before it,
  but the image imports no credentials (see "The kernel command line is fixed").
- **Not at all on the reset entry**, when the command line has `systemd.unit=nyra-reset-settings.target`,
  which under Secure Boot only the sealed reset profile has, or an SMBIOS string from the firmware or
  a VM's host (see "The platform is trusted"; that only skips the questions): the first question is
  the reset's. Root stays locked: the reset brings back the image's root account (`*`), and it never
  copies root's lines from the old `/etc`.

On the first boot after an install, root is already in `/etc/shadow` (the image's `*`), so
`systemd-firstboot` never asked for its password there; nothing changes on that boot.

CI follows one system with Secure Boot on: a normal boot adds an administrator and a host name,
then breaks the settings (garbage in `/etc/fstab` and `/etc/passwd`, `systemd-resolved` masked,
`/etc/resolv.conf` deleted, a stray file, a user and a group name each twice, first with ID 0);
the reset entry answered with something else, and with
Control-D, changes nothing; a power cut as the reset starts building the new `/etc`, and another as it
switches to it, each leave `/etc` whole (all old or all new) on the next boot; a power cut right after
the switch leaves the new `/etc` in place, a running system, and the previous `/etc` as `etc.nyra-new`
(no marker); a power cut right after the new `/etc`'s directory is made leaves no `etc.nyra-new`
without its marker and `etc.nyra-old` as it was; the reset itself brings the image's `/etc` back and
reboots, and the next boot has none of the breakage, the administrator with the same password hash
and groups, the file in `/home`, the machine ID and the host name, nothing of the names found twice
(root the only UID 0), and the previous `/etc` as
`etc.nyra-old` (`0700`). Then `/etc/fstab` breaks again (see "Mounts from /etc/fstab"): the normal boot
goes on, the reset entry asks at once without reading it, and the reset removes it. Last, `/etc` is
emptied and the normal entry boots: `systemd-firstboot` runs (a first boot) and finishes with success,
asks nothing (the test passes the time zone as a credential), the boot reaches `multi-user.target`, and
root is locked (a drop-in passed as a credential prints the unit's state and root's line from
`/etc/shadow` on the console, so the check does not depend on a login with `/etc` emptied).

Titanic T8 (docs/TITANIC.md, "Configuration broken by the user") breaks `/etc/fstab`, `/etc/passwd`,
the network and `/etc/systemd/system` the way a user could, checks that each still boots, then breaks
all of it at once, opens Recovery without the system accounts in `/etc/passwd`, and resets it.
While `/etc/passwd` has a line that is not an account, bootc's `bootc-sysusers-shadow-sync.service`
fails without changing anything (docs/TITANIC.md); after the reset it runs and succeeds again.

What the installer and later work must still decide: other system data a user expects to keep (Wi-Fi
networks once NetworkManager is in the image), and a "reset everything" that also clears `/var` and
`/home` (the factory reset). After `/etc` is emptied no administrator is left, so recovery has no one
to authenticate.

## Mounts from /etc/fstab

A line the user adds to `/etc/fstab` that cannot be mounted does not stop the boot: the system starts
without that file system, as a disk that is not connected simply does not show up. Without `nofail`,
systemd would wait 90 s for the disk, then fail `local-fs.target` and start emergency mode, whose
root shell is locked (root has no password), so the machine could only be switched off. Two changes,
both in the running system only: the initramfs, which mounts the root and `/usr`, keeps systemd's
behaviour (the image build checks that the drop-in below is not in it, and changes `local-fs.target`
only after the initramfs is built):

- **10 s for a device**, not 90 s: a drop-in for every `/dev/...` device unit
  (`dev-.device.d/10-nyra.conf`, `JobRunningTimeoutSec=10s`). A line's own
  `x-systemd.device-timeout=` still wins, for a disk that takes longer to appear, or one unlocked with
  a password typed at boot (`/etc/crypttab`), which needs `x-systemd.device-timeout=0`.
- **No emergency mode from `local-fs.target`**: the image's `local-fs.target` has no
  `OnFailure=emergency.target` (removed in the image build; a drop-in cannot remove a dependency).
  The mount that failed stays failed, nothing else is held back.

The journal says what is missing: `Timed out waiting for device … - /dev/disk/by-label/…` and
`Dependency failed for var-mnt-….mount`, or `Failed to mount …` for a line that does not work. A line
that is not a mount at all is skipped by systemd. The "Reset settings" entry ignores `/etc/fstab`
entirely (`fstab=no`, see "Reset system settings").

**What `local-fs.target` no longer guarantees.** A mount that fails at once (a wrong option or type)
fails `local-fs.target` at once too, so a unit ordered only after `local-fs.target` can start while
the other local mounts are still in progress. The root, `/usr`, `/etc` and `/var` are set up in the
initramfs and are not among them. The ESP is: `boot.mount` comes after its file system check, and
the units that write to the ESP are ordered after `boot.mount` itself:

- `systemd-boot-random-seed` (the only one that runs this early, before `sysinit.target`) has
  `After=boot.mount` in its drop-in. Without it, CI saw it start before the ESP's check, with
  `esp-writable` mounting the ESP read-write while it was checked, and `boot.mount` then fail;
- `nyra-boot-repair` has `RequiresMountsFor=/boot`; `systemd-bless-boot` and `nyra-updated` come after
  `boot-complete.target`, whose health checks come after `nyra-boot-repair`; bootc writes when
  `nyra-updated` stages an update and at shutdown, as does `nyra-boot-counter`.

`/tmp` (a tmpfs, `tmp.mount`) is the other local mount. The boot's tmpfiles
(`systemd-tmpfiles-setup`, which makes `/tmp/.X11-unix` and the like) are ordered after `tmp.mount`
in their drop-in, and units with `PrivateTmp=` wait for it by themselves.

If the ESP itself cannot be mounted (a damaged partition), the boot goes on as before this change:
`boot.mount` is wanted, not required, by `local-fs.target`. `nyra-boot-repair` is then skipped. When
the kernel refuses to mount the ESP, a health check may fail as well: a version on trial then falls
back after its three tries, and a version that is not on trial stays up with that check failed. There
is no reboot loop either way. When only the file system check failed (the partition itself can be
mounted), the health checks pass (CI, below). Nyra's own writes to the ESP need it checked and
mounted: `esp-writable` refuses (an error in the journal, pointing to
`journalctl -u boot.mount`), so the boot loader random seed fails visibly and a counted boot is not
blessed; `nyra-updated` does not run (`RequiresMountsFor=/boot`; each start tries the check and the
mount again), so no update is staged that would boot without its boot counter. The user, or a later
boot whose check passes, decides what happens to the ESP. What stays accepted: a version already on
trial when the ESP breaks is not blessed, so after its three tries systemd-boot starts the previous
version. Once `nyra-updated` runs again (the ESP checked and mounted), it marks that version failed
if the version the machine fell back to passes its health checks (docs/UPDATES.md, rules 5 and 12).
The same happened before when the partition could not be mounted at all. CI:
`tools/vm/boot-protection.sh`, boots 15 and 16.

**A line with `x-initrd.mount`** is mounted in the initramfs, which keeps systemd's own behaviour:
if it fails, the initramfs's emergency mode reboots (`rd.emergency=reboot`),
so the normal entry restarts again and again. The "Reset settings" entry does not read `/etc/fstab`
(`fstab=no`, in the initramfs too), so it still boots, and the reset removes the user's `/etc/fstab`.

CI (`tools/vm/reset-settings.sh`, boots 13-15) adds to `/etc/fstab`, without `nofail`, a disk that is not
connected, a swap partition on a disk that is not connected (`tmp.mount` waits for `swap.target`), a
line that is not a mount, and a `proc` mount with an option it does not know, which fails at once,
before the ESP and `/tmp` are mounted. The normal boot reaches the login prompt without emergency
mode, and only the `proc` mount failed. The boot loader random seed is ordered after `boot.mount` and
came after the ESP's check and `boot.mount`, and `nyra-boot-repair` ran. The boot's tmpfiles are
ordered after `tmp.mount` and came after it (`/tmp/.X11-unix` is root's, mode 1777). The journal
names the missing disk less than 20 s after the start of the system. The reset entry asks within
30 s of the start of the system, without reading `/etc/fstab`, and the reset removes the lines.

## Boot counting (`tools/vm/boot-counting.sh`)

A new version must prove itself, or the machine goes back to the previous one by itself (systemd
[automatic boot assessment](https://systemd.io/AUTOMATIC_BOOT_ASSESSMENT/)):

- bootc writes the entries of a staged version to `loader/entries.staged` on the ESP when it stages
  it, and swaps that directory with `loader/entries` at shutdown (`bootc-finalize-staged`). It writes
  no boot counter.
- **`nyra-boot-counter.service`** (stopped at shutdown just before `bootc-finalize-staged`) renames
  the new entry in `entries.staged` to `…+3.conf`. The counter therefore lands in the same atomic swap
  as the entry itself; the running system's entry, found by its composefs digest, gets none. It
  writes through `esp-writable` (see "The ESP is read-only") and stops before `boot.mount` is
  unmounted. When
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
