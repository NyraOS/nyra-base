# The Titanic battery

Tests that try to break the base: an update, a power cut, a bad network or an attacked boot must
never leave a machine that does not start. Every test has a scenario, an expected result, saved logs
and one result: `pass`, `partial`, `fail` or `not-implemented`.

## When it runs

- **Every night** (02:17 UTC) and by hand (`gh workflow run titanic.yml`), from
  [`.github/workflows/titanic.yml`](../.github/workflows/titanic.yml). Not on pull requests: they run
  the image workflow's own tests, and the pull request check validates `titanic.yml` with actionlint
  and runs the offline self-test of the results script.
- `titanic.yml` calls [`image.yml`](../.github/workflows/image.yml) unchanged: the image is built
  once, then its `install-boot` job runs every boot, update and security test on it. A nightly run
  builds with the caches; a manual run on `main` builds without caches, like a release, but is never signed, and it never
  delays or replaces a release build of `image.yml` (its own concurrency group).
- Then the `power-cuts` job installs the same image again and cuts the power at random moments of an
  update (below); in parallel the `stress` job installs it too, fills its disk, updates it under
  extreme load, lets a hostile root loose on it and breaks its configuration (below). The `results` job writes
  `titanic-results.json`.

## The tests

| # | What we try to break | Covered by | Result today |
|---|---|---|---|
| T1 | Immutability | `/usr` read-only (first boot of `install-boot`), `tools/vm/tampered-object.sh` (a composefs object changed on the disk: a read error), signature policy (`tools/signing/test-policy.sh`), refused UKIs (`tools/vm/secure-boot.sh`) | full |
| T2 | Power cuts | `tools/titanic/power-cuts.sh` (random moments), `tools/vm/updates.sh` (`nyra-updated` after cuts at fixed and at random moments) | full |
| T3 | Broken version | `tools/vm/boot-counting.sh`, `tools/vm/updates.sh` (failed health check: back within 3 boots, not offered again; a good version with the settings broken after it was staged: back within 3 boots, but not marked failed, since the older version fails too; offered again once the settings are repaired), `tools/vm/soft-reboot-network.sh` (the network after every soft reboot and full boot of an update, 20 rounds a night), `tools/vm/updates.sh` (a kernel panic: no usable initramfs; a dead network: the link down before a check and in the middle of a download, then back), `tools/vm/network-health.sh` (a version whose link gets no address, where the version before had one: back within 3 boots, not offered again; the same kind of version without a cable: not judged) | full; the graphical session is left for the desktop (below) |
| T4 | Signatures and versions | `tools/signing/test-policy.sh`, `tools/vm/secure-boot.sh`, `tools/vm/updates.sh` | full |
| T5 | Hostile network | `tools/vm/updates.sh` (registry down, corrupted layer, captive portal, spoofed server, DNS answer for another host, a 50 kbit/s link, a registry that stalls mid-pull) | full |
| T6 | Full disk | `tools/titanic/full-disk.sh` (the root file system full during an update and at boot, the ESP full during an update, the space the system takes across 8 updates in a row) | full; the message for the user is left for the desktop (below) |
| T7 | Attacked boot | `tools/vm/boot-protection.sh`, `tools/vm/secure-boot.sh`, `tools/signing/tpm-unlock.sh` (the signed PCR policy unlocks the disk only in the initrd, swtpm) | full |
| T8 | Configuration broken by the user | `tools/titanic/broken-config.sh` (`/etc/fstab`, `/etc/passwd`, the network settings and `/etc/systemd/system` broken, each on its own: does the system boot, and does Restore earlier settings repair it? Then all of it at once, Recovery without the system accounts, Restore earlier settings, and, broken again, Reset settings, with Secure Boot) | full |
| T9 | Wrong clock (1970, 2099) | `tools/vm/updates.sh` (the hardware clock in 1970, 2099 and 2035: chronyd corrects it through NTS by itself and the update works; with the NTS servers spoofed the clock stays wrong, no unauthenticated NTP request is sent, the update server's certificate and unsigned images are refused) | full |
| T10 | Disk encryption | `tools/vm/encryption.sh` (without a TPM: the password and the recovery key unlock the disk in the initrd, a wrong password is asked again, the recovery key typed 120 s later and the password after three wrong ones still unlock it, no root partition ends in emergency mode after 90 s, neither secret in the logs or on the disk outside LUKS), `tools/vm/encryption-tpm.sh` (with a TPM and Secure Boot: the first boot unlocks by itself and enrolls the disk with the signed PCR policy, the next ones unlock by themselves, without the TPM the recovery key unlocks it, a TPM that stops answering before `leave-initrd` forces a reboot; after the TPM refused because of a new Secure Boot database, a new TPM or a different PCR 12, the recovery key unlocks it and the disk is enrolled again, but never with Secure Boot off or an add-on measured, and never a disk set up with a password with a forged TPM2 token; the recovery profile asks for the disk); the signed TPM unlock policy is tested under T7 and T15 (`tools/signing/tpm-unlock.sh`) | partial: not yet updates, the policy key's rotation, the PIN; the first boot without a TPM or with Secure Boot off is checked by hand only |
| T11 | Version jumps and channels | `tools/vm/channels.sh` (a jump over several versions with a retracted one between, refused sheets on the way and a retraction below the floor the jump raised; versions that change the sheet key, the default channel and the repository; a channel chosen on the machine, which survives a rollback; beta to stable back to stable's older version only with a sheet issued after the change, once, never below the floor, staged afresh with today's `/etc` even when it is the rollback deployment) | full |
| T12 | Hostile root (`rm -rf /`, `apt`, unsigned modules) | `tools/titanic/hostile-root.sh` (apt and dpkg, an unsigned module, the lockdown, `rm -rf --no-preserve-root /` then Reset settings, with Secure Boot) | full |
| T13 | Extreme load during an update | `tools/titanic/extreme-load.sh` (8 busy loops on 2 vCPUs, less than 200 MiB of memory free, the disk written without a pause) | full |
| T14 | Removable media pulled out | `tools/vm/removable-media.sh` (USB sticks pulled out during a write, during an update and during the boot; a stick with ESP, root, swap and /home partitions at boot; trusted, untrusted and refused sticks; a user's loop device) | full |
| T15 | Secure defaults | `tools/vm/security-defaults.sh`, `tools/vm/secure-boot.sh` (after installation), `tools/vm/updates.sh` (the same check again after updates), `tools/signing/tpm-unlock.sh` (the TPM releases the disk key only in the initrd, swtpm; no NvPCR definitions in the image) | full |

A test passes only if every step that runs it succeeded; a test that covers only part of its
scenarios gives `partial` at best. A step that failed, was skipped or no longer exists fails the
test. The mapping from workflow steps to tests is in
[`tools/titanic/results.py`](../tools/titanic/results.py): renaming a step in `image.yml` means
renaming it there too.

A test that fails sometimes is a bug, never something to run again until it passes.

## Left for the desktop

Two scenarios need a graphical session, which the base does not have. They are not part of the
base's results: T3 and T6 pass when every scenario without a desktop passes. They are criteria of the
desktop's gate instead, tested once there is a desktop:

| # | Scenario | Expected |
|---|---|---|
| T3 | an update to a version whose graphical session does not start, and the version the machine falls back to | the broken version falls back like any version that fails its health check; the session of the version fallen back to starts |
| T6 | the disk full during an update | the desktop tells the user that the update failed, why, and what to do |

## Power cuts at random moments

[`tools/titanic/power-cuts.sh`](../tools/titanic/power-cuts.sh) runs 20 rounds a night. Each round
starts from a fresh copy of the installed disk, updates it with `bootc switch` to a test version of
the image served on the runner, and kills QEMU a random time after the start of one phase:

| Phase | The cut comes | Window |
|---|---|---|
| download | during the pull, with the registry throttled to 2 Mbit/s | 0-60 s |
| staging | during the switch at full speed (pull, deployment, staged boot entries) | 0-3 s |
| finalize | after `systemctl reboot`, while the staged entries are swapped in | 0-2 s |
| firstboot | after QEMU starts the first boot of the new version | 0-30 s |

The windows follow what the phases take on the CI runner (the switch at full speed about 3 s, the
shutdown with the swap about 2 s); wider ones put almost every cut after the phase. A cut that lands after its phase (the switch already done, the next boot already started) is a
moment too, and the log says where it landed. After the cut the machine must boot to a running
system on the old or the new version, and the update must then complete: switched again if the old
version booted, one reboot, the new version running. The phases take turns; the moments come from a
seed printed in the log, in the step summary and in `titanic-results.json`. To run the same moments
again, run the script with that seed (`tools/titanic/power-cuts.sh ... CUTS SEED`, see its header).

These rounds use `bootc` directly, without `nyra-updated`; that `nyra-updated` stages the update
again by itself after a cut is proven by `tools/vm/updates.sh`.

## A full disk

[`tools/titanic/full-disk.sh`](../tools/titanic/full-disk.sh) follows one installed system, updated
with `bootc switch` to test versions served on the runner (each with 16 MiB of its own and its own
UKI):

| Boot | What | Expected |
|---|---|---|
| 1 | AppArmor's cache removed, the root file system (`/var` and the composefs store share it) filled to the last block, then an update | the update fails with "No space left on device", nothing staged, the system still `running` |
| 2 | a boot with the disk still full | `running`, the health checks pass; AppArmor loaded again without its cache (the journal says so), as many profiles as in boot 1 |
| 3 | the root file system freed, the ESP full, an update | the update fails the same way, nothing staged; with space again it is staged |
| 4-11 | 8 updates in a row, one per boot | each version boots; the space the system takes (`/sysroot/composefs`, `/sysroot/state/deploy`, the ESP) does not grow from the third update on, within 1 MiB (one version is 16 MiB) |

The table of the sizes is in the step summary. A system that keeps old versions grows by a version at
every update; one that stays the same from the third update on stays the same after any number.

## Extreme load

[`tools/titanic/extreme-load.sh`](../tools/titanic/extreme-load.sh): in a VM with 2 vCPUs and 2 GiB,
8 busy loops, memory taken until less than 200 MiB is available (the out-of-memory killer may stop
anything, bootc too) and 256 MiB written and flushed again and again; the load is checked (load
average 3 or more, less than 300 MiB available). Then an update with `bootc switch`: it must either
stage exactly the test version or fail with nothing staged. The next boot must run the old or the new
version; the update then completes without load, and the new version boots and runs.

## A hostile root

[`tools/titanic/hostile-root.sh`](../tools/titanic/hostile-root.sh) follows one installed system with
Secure Boot on (the UKI certificate of the run as a MOK, as in the boot tests of docs/BOOT.md). Each
protection has a control in the same run, so that the test fails if the protection is missing, not
only if the action fails for another reason:

| Boot | What root does | Expected | Control |
|---|---|---|---|
| 1 | `apt install`, `apt-get install` | both fail and say what to use instead (the Store, Distrobox; docs/DEFAULTS.md, "apt and dpkg") | |
| 1 | `dpkg -i`, `dpkg --install` of a package with a file in `/usr/bin` | both fail with the same message, the file is not there | dpkg's queries (`-l`, `-L`, `-S`, `--status`) find the package installed below |
| 1 | the same with Debian's dpkg itself (`/usr/lib/nyra/dpkg -i`), past the message | fails with "Read-only file system", the file is not there | the same package installs with `--root=` into a writable directory |
| 1 | | `/usr` has the same checksum after apt and dpkg as before | |
| 1 | `insmod` of an in-tree module (`dummy`) with its signature cut off | refused by the kernel's signature check ("Loading of unsigned module is rejected": with Secure Boot the kernel enforces module signatures) | the same module with its signature loads from the same place |
| 1 | `echo none > /sys/kernel/security/lockdown` | refused, still `integrity` | raising it to `confidentiality` works |
| 2 | `rm -rf --no-preserve-root /`, then a power cut | `/usr` and the ESP have the same checksums as before; `EFI/BOOT/BOOTX64.EFI` is still the image's shim | the markers the test put in `/etc` and `/var` are gone |
| 3 | the "Nyra OS Reset settings" entry, picked before `rm` | no first-boot question before the reset's, and AppArmor loaded in that boot (the image's profiles from `/usr`); `/etc` is the image's again, root locked, the system restarts into the normal boot and runs; `/usr` unchanged, Secure Boot and the lockdown on, the "Nyra OS" firmware entry back | |

The checksum covers every path under `/usr` with its type, mode, owner, size and link target, and the
content of every file; the ESP's (at `/boot`) covers the same, taken right before and after `rm`, so
that even a partial delete fails the test, which the next boot's repair would otherwise hide. The
ESP as `rm` left it is listed in the step summary. The files are hashed through `find -exec`, not
`xargs`: after `rm` there is no `/dev/null`, xargs then starts its command with standard input
closed, and a Rust program such as uutils' `sha256sum` aborts on that (docs/DEFAULTS.md, "Core
utilities"). Any command of the checksum that fails fails the check (`pipefail`), so a missing hash
can never pass as one.

apt and dpkg: the message is help, not the protection, so both are tested: what the commands say,
and Debian's dpkg itself, past the message, against the read-only `/usr`.

**What happens:** `/usr` is unchanged, and so is the ESP: it is read-only at `/boot` (docs/BOOT.md,
"The ESP is read-only"), so `rm` only gets "Read-only file system" there. `rm` does delete the
`Boot####` and `BootOrder` firmware variables (efivarfs lets those be removed; the others, such as
systemd-boot's one-time entry, are immutable). The next boot therefore goes through the firmware's
fallback path, `\EFI\BOOT\BOOTX64.EFI`, into the "Reset settings" entry picked before `rm`; the
normal boot after the reset creates the "Nyra OS" firmware entry again. The reset itself must not
depend on `/etc`: `/usr/bin/awk` is a link through `/etc/alternatives`, so it calls `mawk`.

With `/etc` gone, the boot counts as a first boot, but `systemd-firstboot` does not run on the reset
entry (docs/BOOT.md, "No first-boot questions"): the first question on the console is the reset's.
Any other question would stop the boot before it, so the test fails there; it also fails if the
console shows `systemd-firstboot` starting.

Not covered: what `rm` takes with `/var`, including `/home`: the files of the users are gone, which
no reset can bring back.

## Configuration broken by the user

[`tools/titanic/broken-config.sh`](../tools/titanic/broken-config.sh) follows one installed system
with Secure Boot on, set up as for the hostile root (the shared part is
[`tools/titanic/secure-boot-system.sh`](../tools/titanic/secure-boot-system.sh)). Root breaks `/etc`
the way a user can; the system must still boot, "Restore earlier settings" (docs/BOOT.md) must bring
back the settings of a copy made before, and "Reset settings" (docs/BOOT.md, "Reset system settings")
the image's:

| Boot | What | Expected |
|---|---|---|
| 1 | a user, an administrator with a password, and a file in their home; then the daily copy of `/etc` | control: the user logs in with the password, a wrong one is refused, the network works |
| 2 | `/etc/fstab`: a line that is not a mount, and a disk that is not connected (`LABEL=nyra-t8-data`, without `nofail`) | the system boots to a login prompt; then "Nyra OS Restore earlier settings" (`bootctl set-oneshot`, as in the boot menu) with the copy from boot 1 repairs it (below) |
| 3 | `/etc/passwd`: every system account deleted (root and the user kept), a line that is not an account | the same |
| 4 | the network: the wired network's settings replaced in `/etc/systemd/network` with a wrong static address, `/etc/resolv.conf` replaced with a wrong name server | the same |
| 5 | `/etc/systemd/system`: everything deleted (what the image enables there), then systemd-resolved, chronyd, the firewall and the update timer masked | the same |
| 6 | all four at once; "Nyra OS Recovery" picked for the next boot | |
| 7 | that boot: Recovery without the system accounts | it asks for an administrator although `/etc/passwd` has no `nobody`; a wrong password gives no shell, the right one a root shell in `rescue.target`; "Nyra OS Restore earlier settings" picked for the next boot |
| 8 | that boot: the copy from boot 1, then the normal boot | repaired (below), the file in `/home` is the same; then all four broken again, "Nyra OS Reset settings" picked |
| 9 | that boot: `RESET`, then the normal boot | `/etc/fstab`, `/etc/passwd` (plus the user's line), `/etc/systemd/network`, `/etc/resolv.conf` and `/etc/systemd/system` are the image's; the file in `/home` is the same; healthy (below) |

**Repaired** means: `/etc/fstab`, `/etc/passwd` (but the user's line, which comes from the current
`/etc`), `/etc/systemd/network`, `/etc/resolv.conf` and `/etc/systemd/system` are as in `/etc` when
the copy was made (the copy holds only what differed from the image; the rest is the image's); and
**healthy**: running; the user logs in with their password, a wrong one is refused; the network
works; the basic services are active (journald, D-Bus, logind, networkd, resolved, chronyd, the
firewall, AppArmor, the update timer); Secure Boot and the lockdown on.

Boots 2-5 each break the system, reboot it, so that each breakage shows what it does on its own, then
restore the copy, which must leave a healthy system for the next one. Before each restore, copies the
daily timer may have made since boot 1 (at midnight, of a broken `/etc`) are removed, so that the
one offered is boot 1's. What happens is in the step summary and the serial logs
(`serial-broken-config-<boot>.log` and `serial-broken-config-<boot>-restore.log` in
`titanic-stress-serial-log`): the system state, the failed units, the basic services, the network,
whether the user can log in, the boot's warnings. A boot that does not reach the login prompt fails
the test: the expected result is that the system boots. The summary ends with one line per breakage
and the results of the restore and of the reset.

**One failed unit is expected, and only there.** bootc's `bootc-sysusers-shadow-sync.service` runs
on every boot before `systemd-sysusers` and removes the lines of `/etc/shadow` and `/etc/gshadow`
whose account is gone. It reads `/etc/passwd` first, and when a line there is not an account it stops
with an error before it changes anything: the unit fails. On boots 3 and 7 (and on boots 8 and 9
before the restore and the reset) that is what it should do. It is harmless: `systemd-sysusers` runs only when `/etc` needs an
update, which these boots do not, and nothing else waits for it. T8 checks it on every boot with a
shell: on boots 3 and 7 it failed, on the line that is not an account (its journal); on all the
others, the normal boots after the restores and the reset included, it ran and succeeded. A failure anywhere else, or for
another reason, fails the test; `systemctl --failed` is not filtered.

The password check is `su` through PAM, run as the user who logs in (by UID: sudo-rs's `su` refuses
to run for a user it cannot look up, and the broken `/etc/passwd` has no `nobody`) so that it has to ask; the network check is a file served by the runner, which the guest
reaches as 10.0.2.2. The image's `/etc` is read the way the reset reads it: under the bind mount of
the state `/etc`, through a bind mount of `/` alone.

## Removable media pulled out

[`tools/vm/removable-media.sh`](../tools/vm/removable-media.sh), in the `install-boot` job, follows a
copy of the installed disk with USB sticks on QEMU's USB controller. QEMU plugs them in and pulls them
out without asking the guest (`vm-boot.py --qmp`, `device_del` and `device_add`), as a hand does.
How the base mounts them is in docs/DEFAULTS.md, "Removable media".

| Boot | What | Expected |
|---|---|---|
| 1 | two FAT sticks, a stick with an ext4 and an exFAT partition, and a squashfs stick plugged in | nothing mounted, udisks2 not even started |
| 1 | `udisksctl mount` of the squashfs stick, and of a FAT stick with `-t squashfs` | neither mounted; squashfs's module not even loaded |
| 1 | one stick put in `/etc/nyra/trusted-media` | udev marks it trusted, also when its line is the last one and has no newline; with the list writable by others, it is not |
| 1 | `udisksctl mount` with `exec`, `suid`, `dev` | refused |
| 1 | both FAT sticks mounted, a program copied to each | both `nosuid,nodev`; the untrusted one `noexec` too; the program runs from the trusted stick only ("Permission denied" on the other); udisks2 runs with its hardening drop-in |
| 1 | the ext4 and the exFAT partitions mounted, a file written to each | `nosuid,nodev,noexec`, as the untrusted FAT stick; each unmounts |
| 1 | the untrusted stick written without a pause (32 MiB, flushed, again and again), pulled out 2 s in | the writer stops on its own, `sync` returns, the stick and its mount are gone within 30 s, the trusted stick still reads, the system `running` |
| 1 | plugged in again | not mounted until asked; then mounts `noexec` |
| 1 | a user logged in on a virtual console (an autologin on tty5, made the foreground console): an active local session on seat0 | polkit lets them mount a stick, but `loop-setup` and `modify-device` need an administrator: `udisksctl loop-setup` refused, no loop device; polkit loaded the rules without an error |
| 1 | shutdown with the trusted stick mounted | clean |
| 2 | a stick mounted and written, `bootc switch` to a test version, the stick pulled out half a second into the switch | the switch was still running, then succeeds with exactly the test version staged; clean shutdown, which finalizes it |
| 3 | a boot with a stick that has an ESP, a root (x86-64), a swap and a /home partition, by their Discoverable Partitions types, and the FAT stick | the test version runs; the root, the ESP and `/dev/gpt-auto-root` are on the boot disk; no swap; nothing mounted from the sticks |
| 4-6 | the same stick pulled out 3, 6 and 10 s after QEMU starts (the firmware, the kernel and its initrd, the start of the system) | each boot reaches the login prompt and `running`, no job waits; the kernel log says when the stick went; clean shutdown |

Every boot ends with a clean shutdown: it fails on a file system left mounted (`Failed unmounting`) and
on a shutdown longer than 60 s.

Why the system stick is not used: systemd-gpt-auto-generator uses only the disk the boot came from,
and there only the root and the ESP (the image policy on the sealed command line, docs/BOOT.md,
"Disk encryption"). A boot from the stick itself (its ESP) is up to the firmware and Secure Boot.

## Results

The `titanic-results` artifact holds `titanic-results.json`:

```json
{
  "schema": 1,
  "date": "2026-10-10",
  "commit": "<sha>",
  "run_url": "https://github.com/NyraOS/nyra-base/actions/runs/<id>",
  "seed": 12345,
  "tests": {
    "T1": { "name": "Immutability", "result": "partial", "note": "...", "run_url": "..." }
  }
}
```

`result` is `pass`, `partial`, `fail` or `not-implemented`. The step summary shows the same table.
The workflow only publishes the file as an artifact; it has no token for anything outside this
repository. The serial console logs are the artifacts `install-boot-serial-log` and
`titanic-power-cuts-serial-log`.
