# Secure defaults

What an installed nyra-base system turns on by itself, closed by default (a feature that weakens
it is something the user switches on, not off), and how CI proves it.
`tools/vm/security-defaults.sh` boots the disk that the `install-boot` job installed with
`bootc install to-disk` and fails on any regression.

| Default | How | Checked in the VM |
|---|---|---|
| AppArmor on, profiles loaded | `apparmor` package; `apparmor.service` enabled from `/usr` (`sysinit.target.wants`); when its cache cannot be written (a full root file system), the profiles are loaded without it, and without `/etc/apparmor.d` (an emptied `/etc`) the image's profiles load from a copy in `/usr/lib/nyra/apparmor.d` (drop-in) | AppArmor in the active LSMs, the service active, profiles loaded, at least one in enforce mode |
| Kernel lockdown `integrity` | `lockdown=integrity` in `/usr/lib/bootc/kargs.d/10-nyra-lockdown.toml`; Debian's kernel also turns it on under Secure Boot | `/sys/kernel/security/lockdown` shows `[integrity]` |
| Inbound firewall, default deny | `nftables`; `/usr/lib/nyra/firewall.nft` loaded by `nyra-firewall.service` before the network; `systemd-networkd` requires it | the service active, `policy drop`; a TCP connection from a network namespace to a listener times out, and works once an accept rule is added |
| Only declared units running | units with no purpose in the base blocked from `/usr` (see below) | every running service, waiting timer and listening socket unit matches the allowlist in the script; every blocked unit is inactive |
| No undeclared listening sockets | resolved without LLMNR and mDNS (Containerfile) | every socket in `ss -tuln` matches the allowlist in the script: resolved's stub on loopback, networkd's DHCP client ports |
| Signature policy in place | `/etc/containers/policy.json` is a link to `/usr/lib/nyra/containers/policy.json` (read-only `/usr`) | the link, owner `root:root`, not group or world writable, `sigstoreSigned` present. That it refuses unsigned images is proven in the `build` job (`tools/signing/test-policy.sh`, docs/SIGNING.md) |
| ESP read-only | mounted read-only at `/boot` at every boot; only `esp-sync`, `systemd-bless-boot`, `systemd-boot-random-seed` and bootc make it writable, each in a mount namespace of its own (docs/BOOT.md, "The ESP is read-only") | the only FAT mount is `/boot`, `ro`; a write there fails with "Read-only file system" |
| Rare filesystems not autoloaded | `/usr/lib/modprobe.d/nyra-filesystems.conf` (`blacklist`) | `blacklist f2fs`, `hfsplus` and `squashfs` are there and none for vfat, exfat, ntfs, ext4, btrfs, xfs, udf, isofs, erofs, overlay; mounting an f2fs image fails without loading f2fs; a vfat image mounts |
| Removable media: mounted only when asked, not executable unless trusted | udisks2 and polkitd, started through D-Bus when a user asks to mount; `/usr/lib/udev/rules.d/90-nyra-udisks.rules` (see "Removable media") | Titanic T14 (`tools/vm/removable-media.sh`, docs/TITANIC.md): nothing mounted or running before a user asks; a squashfs stick refused, by its type and by name; `nosuid,nodev,noexec` on an untrusted stick, `exec`, `suid` and `dev` refused; a trusted stick without `noexec`, and a list others can write ignored; a user's loop device refused; udisks2's hardening in place |
| Authenticated time | `chrony` with NTS only (Cloudflare and Netnod), run by Debian's `chronyd-restricted.service` (never root, only `CAP_SYS_TIME`); configuration in `/usr/lib/nyra/chrony/chrony.conf`; no `systemd-timesyncd` (see "Time") | no `systemd-timesyncd`; the service active, chronyd as `_chrony` with `CAP_SYS_TIME` as its only effective capability, its seccomp filter on and its AppArmor profile in enforce mode, exactly the two NTS sources; `timedatectl` reports NTP on, and after `timedatectl set-ntp true` the same service runs and `chrony.service` stays disabled. That it corrects a wrong clock and ignores spoofed servers is proven by the update tests (T9, docs/UPDATES.md) |
| `su` without `sudo` | `su` is sudo-rs's (Rust), setuid root in place of util-linux's; sudo-rs's `sudo`, `sudoedit` and `visudo` are removed (see "Rust components") | `su --version` is sudo-rs's, `/usr/bin/su` is mode 4755 owned by root, no `sudo` command. Recovery checks an administrator's password with it (docs/BOOT.md, "Recovery") |

Covered elsewhere: the Secure Boot chain (shim, systemd-boot, the sealed UKI; unsigned and wrongly
signed refused) and boot counting are proven in the same job (docs/BOOT.md); signing with the real
Nyra key comes later (docs/BOOT.md, "What remains for the real Nyra key"). That the defaults survive
updates is checked by the update tests, which run this script again on the updated disk
(docs/UPDATES.md, T15).

## Units

Debian packages enable some units through their maintainer scripts. These have no purpose in the
base and are blocked with a `ConditionPathExists=/usr/lib/nyra/allow-<unit>` drop-in (Containerfile),
not through `/etc`, so the block follows the image on updates. A layer that needs one creates that
file.

| Unit | Why it is blocked |
|---|---|
| `nftables.service` | Debian's loader of `/etc/nftables.conf`, which starts with `flush ruleset`: running after `nyra-firewall.service` it would remove the Nyra ruleset (both are ordered only before `network-pre.target`). `nyra-firewall.service` replaces it; it is also ordered after it, which covers the boot only (see below) |
| `dpkg-db-backup.timer`, `.service` | backs up the dpkg database, which mkosi removes from the image |
| `podman.socket`, `podman.service` | podman's Docker-compatible API as root; nothing in the base uses it (Distrobox uses the podman command) |
| `podman-auto-update.timer`, `.service` | pulls and restarts containers labelled for auto-update, unattended, every day |
| `podman-restart.service` | starts root's containers whose restart policy is `always` at boot; the base has none (Distrobox and `podman run` as a user are rootless). It runs podman as root at every boot, and podman's first command after a boot rewrites root's container database even when it holds no container: with the root file system full that fails and the system is `degraded` |
| `podman-clean-transient.service` | removes what containers left behind in podman's transient storage mode, which the base does not use; it fails on a full root file system for the same reason |
| `netavark-dhcp-proxy.socket`, `.service` | a root daemon for DHCP on macvlan container networks, which the base does not set up |
| `e2scrub_all.timer`, `e2scrub_all.service`, `e2scrub_reap.service` | online ext4 checks through LVM snapshots; the base has no LVM |
| `xfs_healer_start.service` | XFS self-healing; the root is ext4 (`xfs_healer@` is blocked too) |
| `systemd-pcrlock-*.service` (7), `systemd-pcrlock.socket`, `systemd-sysupdate-notify-pcrlock.socket` | systemd-pcrlock writes a TPM policy (an NV index) at every boot; Nyra unlocks with the signed PCR policy instead (docs/BOOT.md, "TPM2 unlock") |
| `systemd-sysupdate-notify-bootctl.socket` | lets `systemd-sysupdate` ask `bootctl` (as root) to link a UKI it installed into the boot menu; Nyra updates through bootc, not `systemd-sysupdate`, and only `esp-sync` and bootc write boot entries (docs/BOOT.md, "The ESP is read-only") |
| `systemd-tpm2-clear.service` | asks the firmware to clear the TPM on `factory-reset.target`, which Nyra does not use |
| `systemd-pcrextend.socket` | a Varlink API to extend PCRs; the phase units run the tool directly. On an encrypted root, systemd-cryptsetup calls it to measure the volume key (PCR 15) and the key slot (NvPCR), which the image turns off instead (docs/BOOT.md, "PCR 15, not measured") |
| `systemd-pcrmachine.service`, `systemd-pcrproduct.service`, `systemd-pcrnvdone.service`, `systemd-pcrfs-root.service` | measure the machine ID, the product ID and the root file system into PCR 15 and NvPCRs, which the Nyra policy does not use |
| `systemd-pcrlogin@.service` (`allow-pcrlogin`) | measures each login into the NvPCR `login`; the image has no NvPCRs (see "TPM measurement units that stay") |
| `tpm-udev.path` | TPM device permissions inside containers only |
| `systemd-boot-update.service` | `bootctl update` at every boot: it would write a newer systemd-boot over `EFI/BOOT/grubx64.efi` from a version still on trial, and to `EFI/systemd/`, which nothing starts. `esp-sync` keeps the boot files instead (docs/BOOT.md, "Boot protection"), and the ESP is read-only outside it |

On an installed machine `/usr` is read-only, so an administrator turns a blocked unit back on with
a drop-in in `/etc` whose empty `ConditionPathExists=` resets the unit's conditions. **Unblock the
pair together:** a socket or timer only triggers its service, which stays blocked otherwise (an
unblocked `podman.socket` alone fails with "Trigger limit hit" on the first connection). For
podman's API (devcontainers, compose tools), as root:

```bash
for u in podman.socket podman.service; do
  mkdir -p "/etc/systemd/system/$u.d"
  printf '[Unit]\nConditionPathExists=\n' > "/etc/systemd/system/$u.d/override.conf"
done
systemctl daemon-reload
systemctl enable --now podman.socket
```

Each `override.conf` then contains:

```ini
[Unit]
ConditionPathExists=
```

(`systemctl edit <unit>` creates the same file.) The same goes for the other pairs:
`podman-auto-update.timer` + `.service`, `netavark-dhcp-proxy.socket` + `.service`,
`dpkg-db-backup.timer` + `.service`, `e2scrub_all.timer` + `e2scrub_all.service`; enable the
socket or timer. `podman-restart.service` is on its own: unblocked and enabled
(`systemctl enable podman-restart.service`; our preset disables it, see "Without a network"), it
starts root's containers with `--restart=always` at every boot, after waiting for the network
(`network-online.target`): a boot without a network then waits 2 minutes for it and ends `degraded`.

Per systemd.unit(5), any `Condition…=` assigned the empty string resets the whole list, conditions
of every kind, including any in the unit file itself (`systemctl cat <unit>` shows them). Drop-ins
apply in file-name order across `/usr` and `/etc`, so the file must sort after `10-nyra.conf`
(`override.conf` does; `00-….conf` would not). The drop-ins live in `/etc`, so they survive updates.

**Do not unblock `nftables.service`** unless it is meant to replace the Nyra firewall: its reload
and stop run `flush ruleset`, which removes `inet nyra` while `nyra-firewall.service` still shows
`active`. `systemctl restart nyra-firewall` loads the Nyra rules again. (`After=nftables.service`
only orders the two at boot.)

Kept: `fstrim.timer` (weekly TRIM for SSDs), `systemd-tmpfiles-clean.timer`, `nyra-updated.timer`
(update checks, docs/UPDATES.md), `nyra-etc-copy.timer` (the daily copy of `/etc`, docs/BOOT.md,
"Restore earlier settings"), `chronyd-restricted.service` (the clock, see "Time").

The check lists running services, waiting timers and listening sockets. One-shot units that run
at boot and exit are not on that list; the blocked ones are checked one by one.

### TPM measurement units that stay

`systemd-tpm` (for `systemd-measure` and the boot phases, docs/BOOT.md "TPM2 unlock") also enables the
units above. Only these stay, all from `/usr`:

| Unit | Why | Cost |
|---|---|---|
| `systemd-pcrphase-initrd.service` (initramfs) | measures `enter-initrd` into PCR 11 when the initrd starts (the only phase the signed policy covers) and `leave-initrd` when it ends, which ends the unlock | one-shot at boot, one TPM command at start and one at stop (milliseconds); nothing resident, no wake-ups |
| `systemd-pcrphase-sysinit.service`, `systemd-pcrphase.service` | measure `sysinit` and `ready` into PCR 11: a second barrier, so PCR 11 leaves the signed value even if `leave-initrd` was not measured | one-shot at boot, one TPM command each; nothing resident |
| `systemd-pcrosseparator.service` (initramfs) | a separator into PCR 7, 12 and the other firmware PCRs before the disk is unlocked, so what is measured later does not count as boot state | one-shot in the initramfs, one TPM command; nothing resident |
| `systemd-tpm2-setup-early.service` (initramfs), `systemd-tpm2-setup.service` | the TPM's storage root key (SRK), which salts and encrypts the session that unlocks the disk | one-shot at boot. The early one creates the SRK once; the later one also creates the endorsement key (EK) once, when the TPM allows it. Both stay in the TPM as persistent objects, also after a reinstall; later boots only read them. No NV index (no NvPCRs, below); nothing resident |

Nyra's own, in the initramfs only:

| Unit | Why | Cost |
|---|---|---|
| `nyra-root-wait.service` | the initrd waits for an encrypted root without a time limit (its passphrase may take long), but a root partition must still appear within 90 s (docs/BOOT.md, "Disk encryption") | a wait in the background in the initrd: checks once a second whether the root partition is there, which it normally is within a second or two, and is stopped when the initrd ends; nothing resident |
| `nyra-luks-root.service` | with an encrypted root, the running system finds the ESP on the LUKS2 partition's disk (docs/BOOT.md, "Disk encryption") | one-shot in the initrd, only with an encrypted root: one symbolic link; nothing resident |
| `nyra-tpm-enroll.service` | the first boot of a disk installed for a TPM enrolls it with the signed PCR policy, and a boot whose TPM refused enrolls it again once the recovery key is typed (docs/BOOT.md, "Disk encryption") | one-shot in the initrd, after the disk is unlocked: on an encrypted disk it reads the LUKS2 tokens from the header (milliseconds) and stops there, except at the first boot or after a refusal (one enrollment, under a second); on a plain disk nothing; nothing resident. It also removes the key typed at the prompt from the kernel's cache. With it, the initramfs carries `systemd-cryptenroll`, `cryptsetup`, `od` and `keyctl` (keyutils, a new package of about 100 KB, without its `request-key` upcall: `request-key`, `key.dns_resolver` and their configuration are removed from the image) |

`systemd-pcrphase-factory-reset.service` and `systemd-pcrphase-storage-target-mode.service` stay
linked too, but only `factory-reset.target` and `storage-target-mode.target` start them, and nothing in
Nyra starts those targets.

All of them start only on a machine with a TPM that booted a measured UKI (`ConditionSecurity=measured-os`),
and do nothing on one without (`--graceful`). No socket or service stays running.

**No NvPCRs.** systemd 262 defines four NvPCRs (`cryptsetup`, `hardware`, `login`, `verity`; NV
indexes in the TPM that work like extra PCRs), and Nyra uses none. The image ships no NvPCR
definitions (`/usr/lib/nvpcr/*.nvpcr` are removed in the Containerfile, so the initramfs has none
either). Without them `systemd-tpm2-setup-early` allocates nothing, and `systemd-pcrnvdone.service`
(their separator) and `systemd-pcrlogin@.service` (a measurement at every login) stay blocked. With
the definitions, the first boot would allocate four NV indexes that stay in the TPM after a
reinstall, for nothing that Nyra reads. Removing only the definitions is not enough: the login
measurement then fails at every login, hence its block. Cost now: none. The software-TPM test
(docs/BOOT.md, "The software-TPM test") checks that `/usr/lib/nvpcr` is absent from the image;
`systemd-tpm2-setup` itself does not run in that test (it talks only to a kernel TPM), so the test's
own NV check shows only that enrolling and unsealing allocate no NV index.

**`FailureAction=reboot-force`.** The phase and separator units have it upstream, and it stays. What
each failure would do:
- **`leave-initrd` not measured:** this is the one that matters. PCR 11 would keep the
  `enter-initrd` value, so the running system could still get the disk's key out of the TPM. The
  forced reboot is the barrier; `sysinit` is a second one.
- **`enter-initrd` or the separator not measured:** PCR 11, or PCR 7 and 12, then match no enrolled
  value, and the disk asks for its password. These units fail closed by themselves; the reboot adds
  nothing.
- **`sysinit` or `ready` not measured:** no effect on the unlock, since PCR 11 is already past the
  signed value.

A reboot loop is therefore possible only with a TPM that is present but fails at every boot. Boot
counting cannot help there, since every version does the same. Such a TPM cannot unseal either, so the
loop costs availability, not confidentiality; a TPM that fails once makes one extra reboot. The way
out is to turn the TPM off in the firmware: the stub then measures nothing, the units do nothing, and
the disk asks for its password or the recovery key. The encryption test with a TPM (docs/BOOT.md,
"Disk encryption") checks it in real boots: no unit failed, the forced reboot when the TPM stops
answering before `leave-initrd`, and that way out (without the TPM, the recovery key unlocks the disk).

## Firewall

The ruleset (`inet nyra`, input hook only) lets in loopback, replies to connections this machine
started, the ICMPv6 that IPv6 needs (neighbour discovery, router advertisements, MLD queries) and
DHCPv6 replies from the link. Everything else that is addressed to this machine is dropped.
Outbound and forwarded traffic is not filtered: chronyd's NTS key exchange (TCP 4460) and NTP
queries (UDP 123) go out, and only their replies come back in (`established`). Nothing listens for
time: chronyd opens no server port and no command port (see "Time").

- nftables, not firewalld, for now: the default firewall is meant to be firewalld, with
  per-network zones and a D-Bus API for a future Security app. firewalld would bring `polkitd`
  (whose setuid agent helper has an open CVE today), Python GObject bindings and the
  NetworkManager introspection data into the base before anything uses its API. When firewalld
  arrives, it replaces this ruleset (and the `nyra-firewall.service` unit).
- Containers can still reach the network, rootless (Distrobox, `podman run` as a user) or rootful.
  What the firewall stops is inbound traffic: a port published with `podman run -p` or a server
  started inside Distrobox answers on localhost only, not from other machines, until a rule opens
  it. Rootful podman networks with DNS (aardvark-dns on the bridge) also need a rule.
- A port opened on purpose (a server, Quick Share later) needs a rule, and a line in the
  listening-socket allowlist of the test.

## Without a network

A boot without any network (a laptop away from its Wi-Fi, the cable unplugged) is an ordinary boot:
the system is `running`, no unit failed, and nothing waits for the network on the way to the login.

**Nothing in the base pulls in `network-online.target`.** Its unit,
`systemd-networkd-wait-online.service`, waits for the network and fails after 2 minutes without
one: the system would be `degraded`, and everything ordered after the target, `graphical.target` with
it, would wait those 2 minutes. Debian enables `podman-restart.service` and
`podman-auto-update.service` in `default.target`, and both want the target. They are blocked (see
"Units"), but a blocked unit still pulls in what it wants, so our preset also disables both
(`/usr/lib/systemd/system-preset/80-nyra.preset`, applied in the image build and again at the first
boot). A machine installed before keeps their links, since `/etc` is its own (docs/LESSONS.md,
"Configuration"); `systemctl disable podman-restart.service podman-auto-update.service` removes them.
wait-online keeps its defaults: with nothing pulling it in, a shorter time limit or `--any` would
only change what a layer that needs it gets.

**The update check waits for the network on its own.** `nyra-updated.service` wants and is ordered
after `nyra-updated-wait-online.service`, which runs
`systemd-networkd-wait-online --any --timeout=3600` before every check: it waits until
systemd-networkd reports one link online (configured, DHCP included), for up to an hour, and does not
stay active, so the next check waits again. A check that comes due without a network (the timer,
15 minutes after boot and every 6 hours) waits as a queued start job, and runs as soon as a link is
online instead of at the next timer run, up to 6 hours later; nothing retries or fails in the
meantime. When the hour is over, or the wait fails, the check runs anyway (`-`) and reports what it
finds: "no network connection" without a network (docs/UPDATES.md, "What a machine shows"), or the
update itself on a machine that is online through a link networkd does not manage.

The time limit is finite on purpose, and shorter than the timer's 6 hours (the image build fails
otherwise): a check that never ran would write nothing and fail nothing, so a machine whose updates
stopped, because its link never counts as online for networkd or because the local network keeps it
from being configured, would show nothing. With the limit, every timer run ends in a check that
reports.

- `--any`: one link online is enough; a second port without a cable does not hold the check back.
- Only links that systemd-networkd manages count (the wired ones in the base). When the desktop
  brings its own network manager, this wait follows it.
- Cost: while it waits, one process (the `systemd-networkd-wait-online` binary, run as a dynamic
  user without capabilities or IP traffic, `IPAddressDeny=any`) that sleeps until a link or its state
  changes or the hour is over; no polling. Its memory is printed by the test.
- A check started by hand and waited for (`systemctl start nyra-updated.service`) waits that long
  too: whatever starts a check on request, Settings later, starts it without waiting (`--no-block`).

**Checked in the VM** (`tools/vm/no-network.sh`, on the installed disk): with the cable unplugged
from the start (QEMU's link down before the CPU starts), the system is `running`, no unit failed,
neither wait-online nor `network-online.target` started, and `graphical.target` came within 60 s; an
update check started then is still waiting after 150 s (past wait-online's 2 minutes), with the
shipped limit of an hour, and nothing failed; with the limit shortened to 20 s for the test, the check
runs once it is over and succeeds, and nothing failed. With the network, the same holds at boot; with
the link taken down a check waits, and once the link is up again it runs and succeeds within 90 s.

## Time

The clock decides whether a TLS certificate is valid, so an attacker who can move it can make an
expired or revoked certificate look valid, or a good one look expired. Plain NTP is not authenticated:
anyone on the path can answer. The base therefore takes its time only through NTS (Network Time
Security, RFC 8915): a TLS key exchange with the server (NTS-KE, TCP 4460), then NTP packets
(UDP 123) authenticated with the keys from that exchange.

| What | How |
|---|---|
| Client | `chrony`, which conflicts with `systemd-timesyncd` (not installed) |
| Sources | `time.cloudflare.com` and `nts.netnod.se`, both with `nts`; no pool, no servers from DHCP, no unauthenticated fallback. `minsources 2`: the clock is updated only when both operators are reachable and agree, so one compromised or impersonated server cannot move it |
| Configuration | `/usr/lib/nyra/chrony/chrony.conf`, passed with `-f` by a drop-in of `chronyd-restricted.service`. Debian's `/etc/chrony/chrony.conf` (an unauthenticated pool and servers from DHCP) stays as the package left it and is not read |
| Service | Debian's `chronyd-restricted.service`: started as `_chrony`, with `CAP_SYS_TIME` as its only capability (bounding and ambient), `NoNewPrivileges`, `ProtectSystem=strict`, its own state, runtime and log directories only, Debian's seccomp filter (`-F 1`, set in the drop-in) and AppArmor profile (enforce mode) (`systemd-analyze security`: exposure 1.9, "OK"). Our preset (`/usr/lib/systemd/system-preset/80-nyra.preset`) enables it and disables `chrony.service` (chronyd started as root; the two units conflict) and `chrony-wait.service` (it asks chronyd over UDP 323, which the restricted client does not open, and would delay the boot). systemd applies presets again at the first boot, so the preset is what keeps them that way. `/usr/lib/systemd/ntp-units.d/10-nyra.list` names it as the NTP service for `systemd-timedated`, ahead of chrony's own list: `timedatectl` reports it, and turning automatic time on (`timedatectl set-ntp true`, later the desktop's switch) enables and starts it, never `chrony.service` with Debian's configuration |
| State | NTS cookies (`ntsdumpdir`) and the drift file in `/var/lib/chrony` |
| Control | `chronyc` as root, over the Unix socket in `/run/chrony`; `cmdport 0`, so no UDP 323 |
| Bootstrap | `nocerttimecheck 1`, see below |

**A wrong clock at boot.** NTS-KE checks the server certificate like any TLS client, including its
validity dates. A machine whose clock is outside them (a hardware clock in 2035, or reset by an empty
battery to a date before the certificate was issued) could therefore never correct it: the
certificates of `time.cloudflare.com` and `nts.netnod.se` were checked with the clock in 2035 and
both were refused as expired. Such a machine would also fail every update (docs/UPDATES.md, T9).
`nocerttimecheck 1` turns off only the check of the dates, and only until the first clock update
after chronyd starts; the chain to a trusted CA and the server name are still checked. Debian's
configuration does not set it; chrony's documentation describes this case as its purpose.

What it costs: until that first update, an attacker on the path who holds the private key of a
certificate for one of these names that has *expired* (and was issued by a trusted CA) can complete
the key exchange and offer a wrong time. A stolen key of a certificate that is still valid works
with or without this setting (chrony does not check revocation), so the expired keys are the only
addition. With `minsources 2` the attacker needs such keys for both operators, Cloudflare and
Netnod, at the same time. Not done: pinning the CAs of the two servers (`ntstrustedcerts`), which
would stop time synchronization silently the day an operator changes its CA.

What `minsources 2` costs: if one of the two operators cannot be reached, the clock is not updated
at all and runs on the hardware clock until both answer again.

**Local changes**, in `/etc`, kept across updates: more sources in `/etc/chrony/sources.d/*.sources`
(they count towards `minsources`); other directives in `/etc/chrony/conf.d/*.conf`, which are read
after ours and override them (`minsources 1`, for example). To replace the whole configuration, set
`DAEMON_OPTS="-F 1 -f /etc/chrony/my.conf"` in `/etc/default/chrony`: the later `-f` wins.

**Cost**, measured in the update tests (docs/UPDATES.md, T9) on the CI's VM, two runs: about
1.0 MB installed (the `chrony` package, 727 KB, plus `ucf`, `sensible-utils` and two small Perl
libraries); one resident process, started at boot because the clock has to be right before the
first update check. Synchronized and idle: about 10.8 MB resident (most of it shared libraries,
GnuTLS among them) and about 6.3 MB charged to its cgroup; at most 5 context switches in 60 s
(about 0.08 per second); 82 to 87 ms of CPU time from its start, key exchanges included. It polls
each of the two sources every 64 to 1024 s and has no listening socket.

## Filesystems

`blacklist` only stops the automatic load, when a mount or udev asks the kernel for a filesystem
type; `modprobe <name>` by an administrator still works. The list holds rare and legacy formats
whose parsers face crafted disks and images (f2fs had CVE-2019-19449 and CVE-2019-19814, still
unfixed upstream). Formats that people plug in stay loadable.

## Removable media

A USB stick, an SD card, an external disk, any file system that is not in `/etc/fstab`, is mounted
only when a user asks for it: today root, with `udisksctl mount -b /dev/sdX1`; later the desktop,
which mounts what is plugged in only for the user of the active, unlocked session. Nothing mounts a
stick when it is plugged in, at boot, at the login screen or while the screen is locked. Mounting
makes the kernel read the file system, and a crafted file system is a way to attack the kernel; an
unattended machine reads nothing that is plugged into it.

| What | How |
|---|---|
| Mounting | udisks2 (`udisksctl`, and later the desktop through D-Bus), at `/media/<user>/<label>`. `/media` is a link to `/run/media`, since the root file system is read-only. On unmount or removal udisks2 removes the mount point |
| Options | udisks2 always adds `nosuid` and `nodev`. `90-nyra-udisks.rules` adds `noexec` and takes `exec`, `suid` and `dev` off the options a caller may ask for, so `udisksctl mount -o exec` is refused |
| Trusted media | a file system in `/etc/nyra/trusted-media` is mounted without `noexec`; `nosuid` and `nodev` stay (below) |
| File systems | vfat, exfat, NTFS (the kernel's `ntfs` driver: kernel 7.2 has no ntfs3, and udisks2, which tries ntfs3 first, goes on to it), ext4 (also ext2 and ext3, read by the ext4 driver), btrfs, xfs, iso9660, udf. Only kernel drivers: no FUSE drivers, no new checking tools. Every other file system is refused (below) |
| Services | `udisks2.service` and `polkit.service` start through D-Bus on the first request, never at boot: our preset disables `udisks2.service`, which Debian enables in `graphical.target`. udisks2 runs as root, with a hardening drop-in (`udisks2.service.d/10-nyra.conf`: no new privileges, only Unix and netlink sockets, no namespaces, no real-time scheduling, no writable and executable memory, native system calls only); it keeps the system's mount namespace, since its mounts must be the system's. polkitd runs as its own user, sandboxed by its unit; it has no setuid helper |
| Who may mount | root always (polkit allows root everything). Other users by udisks2's polkit policy: a removable file system from an active local session without a password; an internal disk with an administrator's password. Two things udisks2 allows any active session need an administrator's password too (`/usr/share/polkit-1/rules.d/49-nyra.rules`): setting up a file as a loop device (`udisksctl loop-setup`), since a user's file would otherwise become a file system for the kernel to read, with no stick at all; and changing a removable disk (`modify-device`: its label, formatting, partitions), since libblockdev passes a new label to `fatlabel` unchecked (CVE-2026-111581, low). Nothing in the base needs either yet |
| Passwords through polkit | none today. Every "administrator's password" above needs polkit's password helper, whose socket (`polkit-agent-helper.socket`) is disabled (our preset) until something in the base asks users for a password through polkit and the helper has no known open issue (`tools/sbom/mitigations.toml`); until then those actions are refused for everyone but root. The administrators are the group `sudo` (`49-nyra.rules`, as Debian's default) |
| Logins | `libpam-systemd`, which polkitd needs: every login gets a logind session, which is how polkit knows an active local session. With it every user who logs in, root on the console too, gets their user manager (`user@UID.service`) and `/run/user/UID`; the user manager starts the user units Debian enables for every user. At shutdown `/run/user/UID` is unmounted only after the user manager has stopped (`user-runtime-dir@.service.d/10-nyra.conf`) |

**Refused file systems.** `90-nyra-udisks.rules` gives every other file system that blkid finds
(hfsplus, squashfs, erofs, f2fs, ...) the usage `nyra-refused` instead of `filesystem`, and udisks2
mounts only a device whose usage is `filesystem`. A caller can still name a file system type
(`udisksctl mount -t TYPE`), which udisks2 accepts from a fixed list of well-known ones; the kernel
loads the driver for it on its own, unless it is blacklisted (see "Filesystems"): hfsplus, squashfs
and f2fs are. What stays: erofs is always loaded (composefs uses it), so a user in an active session
can ask for `-t erofs` on a stick they plug in, whatever blkid saw on it. udisks2 has no setting to
refuse a type asked for by name.

Cost: 29 packages, about 15 MB installed (udisks2 with its libblockdev plugins and parted, polkitd,
libpam-systemd, and NSS, 5 MB, for udisks2's crypto plugin). No resident process until a user asks
to mount.

**What polkitd turns on besides udisks2.** With polkitd in the image, every D-Bus service that asks
polkit gets its answers from the services' own policies (before, without polkitd, their checks
failed for everyone but root). For a user in an active local session, without a password: logind's
power-off, reboot and suspend, and lingering for themselves (`set-self-linger`: their user manager
keeps running after they log out); Flatpak's system helper updates installed apps and runtimes,
changes remotes and repository settings and updates the AppStream data, and members of `sudo` may
also install apps system-wide (Flatpak's own rule). Nothing more is opened here; what stays is decided
with Settings.

udisks2 reads the options from udev properties of the device (`UDISKS_MOUNT_OPTIONS_DEFAULTS`,
`UDISKS_MOUNT_OPTIONS_ALLOW`), which win over its own defaults and over
`/etc/udisks2/mount_options.conf`. An administrator changes them with a rule of the same name in
`/etc/udev/rules.d`, which replaces ours.

**Trusted media.** The desktop will ask, the first time a stick is plugged in, whether it is
trusted: a trusted stick can run programs, the others cannot; the question can be turned off in
Settings. The base keeps the answers in `/etc/nyra/trusted-media`, read by
`/usr/lib/nyra/media/trusted` when udev processes a device:

```
# a file system's UUID (lsblk -o UUID), then optionally the drive's serial (udevadm info: ID_SERIAL)
1A2B-3C4D SanDisk_Cruzer_Blade_4C530001230101115355-0:0
```

When a line names a serial, both must match. The list counts only when root owns it and `/etc/nyra`,
and nobody else can write either; otherwise nothing is trusted. A change applies when the stick is
plugged in again, or at once with `udevadm trigger --action=change /dev/sdX1`. "Reset settings"
empties `/etc`, and with it the list.

**What trust is, and what `noexec` is.** A file system's UUID and a drive's serial are whatever the
stick reports: FAT's UUID is a 32-bit number chosen when it is formatted (`mkfs.vfat -i`), and a
prepared stick can copy both from a stick the user trusts. Trust therefore saves the user a
question; it does not prove which stick is plugged in, and is not a security boundary. Neither is
`noexec`: a user can still copy a program into their home folder and run it there, or run a script
with `sh file`. What it stops is running a program straight from the stick, by a click or by
mistake, and mapping code from it (`mmap` with `PROT_EXEC`). `nosuid` and `nodev` are the boundary,
and they stay on every stick.

Titanic T14 (docs/TITANIC.md) checks all of it, and that a stick pulled out at any moment leaves the
system running.

## apt and dpkg

The system in `/usr` comes from the image, read-only, and is updated as a whole, so a package
manager cannot install anything into it. Instead of failing with "command not found" or "Read-only
file system", the commands people try say what to use instead, on standard error, and exit with 1:

```
apt and dpkg can’t install apps on Nyra OS: the system is read-only and updated as a whole.
Install apps from the Store (Flatpak).
For developer tools, use apt in a Distrobox container: distrobox create, then distrobox enter.
```

- `apt` and `apt-get` (not in the image otherwise) are links to `/usr/lib/nyra/no-apt`, which prints
  that message.
- `dpkg` is essential in Debian and stays, without a package database. The image build moves it to
  `/usr/lib/nyra/dpkg`; `/usr/bin/dpkg` is a wrapper that prints the message for an install (`-i`,
  `--install`, `--unpack`, also `-i` among other short options such as `-Ri` or `-iD1`) and runs dpkg for
  everything else: the queries (`-l`, `-L`, `-S`, `--status`), `dpkg-deb`'s actions, a
  `--compare-versions` from a script.

The message is help, not the protection: `/usr` stays read-only for dpkg itself too. Titanic T12
(docs/TITANIC.md) checks both: the message from all three commands, and "Read-only file system" from
`/usr/lib/nyra/dpkg -i`, with `/usr` unchanged.

## Rust components

Some of Debian's tools are replaced with rewrites in Rust, where the rewrite does what the base
needs. Each was tried against the scripts and tests of the base; what failed stays Debian's, with
the reason below.

### su

`su` is the one from [sudo-rs](https://github.com/trifectatechfoundation/sudo-rs) (Debian's
`sudo-rs` package), moved to `/usr/bin/su` over util-linux's and setuid root like it (the package's
script sets the mode; `ci/setuid.txt` still lists `/usr/bin/su`). The rest of the package goes in
the Containerfile: there is no `sudo`, `sudoedit` or `visudo` on the desktop. It uses the same PAM
services as util-linux's (`/etc/pam.d/su`, and `su-l` for a login shell).

Two differences matter for the base, both handled in recovery (docs/BOOT.md, "Recovery"):
- sudo-rs asks for the password up to three times; recovery reads it once itself and gives it to `su`
  on its input, so a wrong one is one try, as before.
- sudo-rs refuses to run for a calling user it cannot look up ("user 'current user' not found"),
  where util-linux's ran as UID 65534 without a `nobody` line in `/etc/passwd`. Recovery therefore
  runs `su` as the administrator who logs in, by UID, instead of `nobody`.

### zlib

The image's `libz.so.1` is [zlib-rs](https://github.com/trifectatechfoundation/zlib-rs), built in the
image build: Debian has its crates, but no package with the library. `zlib/` holds a small crate
that builds `libz-rs-sys` (pinned in `zlib/Cargo.lock`, each crate checked against it, without
network: `ci/vendor-crates.sh`) as a static library; the Containerfile links it into a shared
library with zlib's soname and symbol versions (`zlib.map` from `libz-rs-sys`), as zlib-rs documents
for a drop-in, and puts it over the file Debian's `libz.so.1` link points to. Debian's `zlib1g`
package stays installed for its link and in the SBOM (docs/SBOM.md). The features are those of
zlib-rs's own C library build (the C allocator, CPU features detected at run time) plus the `gz*` file
functions. Not used: the crate `libz-rs-sys-cdylib`, which also carries about 66 MB of test
binaries and profiling data.

Missing: `gzprintf` and `gzvprintf`. They are C variadic functions, which stable Rust cannot define
(zlib-rs builds them only with a nightly compiler). A program that uses one would not load; none in
the image does, and the build fails if one appears (a search of `/usr` for the names). `zlibVersion()`
returns `1.3.0-zlib-rs-<version>`.

Checked before: Python's `zlib` and `gzip` modules (compression levels -1 to 9, zlib, raw and gzip
streams, data from both libraries decompressed by the other) and curl's `--compressed`. Size: about
500 KB against Debian's 120 KB.

### Core utilities

The commands of GNU coreutils are those of [uutils coreutils](https://github.com/uutils/coreutils)
(Debian's `rust-coreutils`): `/usr/bin/<command>` (and `/usr/sbin/chroot`) is a link to its
multi-call binary `/usr/bin/coreutils`, which runs the command its link is named after. GNU's
`basenc`, `factor` and `stty` stay: Debian's build of uutils has none of them. GNU coreutils stays
installed for them; the build fails when that list changes. The image build itself (dracut, the
initramfs) already runs with uutils.

Checked against GNU before, on the same input, for what the base's scripts and tests use: `mv -T
--exchange` (the switch of Reset settings), `cp -a` (modes with setuid, setgid and sticky bits, owners,
times, links, hard links, FIFOs, ACLs, extended attributes, `cp -a SRC/. DEST/`,
`--one-file-system`), `chmod` and `chown --reference`, `install -m` and `-D`, `date` (`-d` with ISO
and `@seconds`, `+FORMAT`, `-u`), `sort` (`-r`, `-V`, `-u`, `-z`, the C locale), `stat -c` (`%a`,
`%U`, `%G`, `%s`, `%t %T`) and `stat -f`, `head`, `tail` (`-c +N`, `-n +N`, `-1`), `cut`, `tr`, `od
-An -tu1 -N5` (the TPM enrollment in the initramfs: not `-j`, below), `seq -w`, `id -nG`, `readlink -f`,
`mktemp -d`, `truncate`, `du`, `base64`, `sha256sum -c`, `ln -sT` and `-sfn`, `mkdir -m`, `tee -a`,
`timeout`, `dd ... conv=fsync status=none`: same output and exit codes. The initramfs stays
reproducible.

Cost, measured in CI against main (the three Rust components together, uutils' share by far the
largest): the image (OCI archive) 24 MB larger (+4.2%); the UKI 4.9 MB larger, the initramfs in it
12.6 MB larger uncompressed (the multi-call binary, about 13.8 MB, instead of the few GNU commands it
needs); no measurable difference in boot time.

Every Rust program, uutils' commands among them, aborts at its start (SIGABRT, exit 134) when it is
started with standard input, output or error closed and `/dev/null` cannot be opened: Rust's runtime
opens `/dev/null` in place of a closed descriptor and aborts if it cannot. GNU's commands run on.
That needs both a closed descriptor and no `/dev/null`: systemd always gives services open
descriptors, and recovery and Reset settings start on a fresh devtmpfs, which has `/dev/null`. It
happened in Titanic T12, after `rm -rf /`: GNU xargs, unable to open `/dev/null`, started
`sha256sum` with standard input closed (the test now hashes with `find -exec`, docs/TITANIC.md). In a
shell where `/dev/null` was deleted, `mknod -m 666 /dev/null c 1 3` brings it back.

One difference was found only in a VM: `od -j N` skips by the size the file system reports, and
efivarfs in the initramfs reported less than the variable holds, so `od -An -tu1 -j4 -N1` on
`SecureBoot` failed and the TPM enrollment took Secure Boot for off. GNU reads to skip. The enrollment
now reads the first five bytes (`od -N5`) and takes the fifth, which both do the same.

### What stays Debian's

| Component | Why it is not replaced (yet) |
|---|---|
| chrony, not ntpd-rs (1.9.0) | ntpd-rs checks the NTS server's certificate against the system clock, with no way to skip the dates until the first clock update (chrony's `nocerttimecheck`, see "Time"). A clock in 2035 or 2099 therefore never gets corrected: every key exchange fails with an expired certificate (tried with the clock moved, against `time.cloudflare.com` and `nts.netnod.se`), and the update tests (T9) need that correction |
| GNU findutils, not uutils findutils (0.10.0) | `find -newermt` accepts no date at all ("I cannot figure out how to interpret ..."), and dracut clamps the initramfs file times with `find -newermt @SECONDS` for a reproducible build; `-printf %m` drops the setuid, setgid and sticky bits, which Titanic's check of `/usr` (T12) records |
| GNU diffutils, not uutils diffutils (0.5.0) | no recursive `diff -r`, which the image build uses to compare the copy of the AppArmor profiles with `/etc/apparmor.d` |

