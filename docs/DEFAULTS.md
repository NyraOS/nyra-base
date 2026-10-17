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
| Rare filesystems not autoloaded | `/usr/lib/modprobe.d/nyra-filesystems.conf` (`blacklist`) | `blacklist f2fs` is there and none for vfat, exfat, ntfs3, ext4, btrfs, xfs, udf, isofs, hfsplus, squashfs, erofs, overlay; mounting an f2fs image fails without loading f2fs; a vfat image mounts |
| Authenticated time | `chrony` with NTS only (Cloudflare and Netnod), run by Debian's `chronyd-restricted.service` (never root, only `CAP_SYS_TIME`); configuration in `/usr/lib/nyra/chrony/chrony.conf`; no `systemd-timesyncd` (see "Time") | no `systemd-timesyncd`; the service active, chronyd as `_chrony` with `CAP_SYS_TIME` as its only effective capability, its seccomp filter on and its AppArmor profile in enforce mode, exactly the two NTS sources; `timedatectl` reports NTP on, and after `timedatectl set-ntp true` the same service runs and `chrony.service` stays disabled. That it corrects a wrong clock and ignores spoofed servers is proven by the update tests (T9, docs/UPDATES.md) |

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
socket or timer. `podman-restart.service` is on its own (Debian already enables it): once unblocked, it
starts root's containers with `--restart=always` at every boot.

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
