# Secure defaults

What an installed nyra-base system turns on by itself, closed by default (a feature that weakens
it is something the user switches on, not off), and how CI proves it.
`tools/vm/security-defaults.sh` boots the disk that the `install-boot` job installed with
`bootc install to-disk` and fails on any regression.

| Default | How | Checked in the VM |
|---|---|---|
| AppArmor on, profiles loaded | `apparmor` package; `apparmor.service` enabled from `/usr` (`sysinit.target.wants`) | AppArmor in the active LSMs, the service active, profiles loaded, at least one in enforce mode |
| Kernel lockdown `integrity` | `lockdown=integrity` in `/usr/lib/bootc/kargs.d/10-nyra-lockdown.toml`; Debian's kernel also turns it on under Secure Boot | `/sys/kernel/security/lockdown` shows `[integrity]` |
| Inbound firewall, default deny | `nftables`; `/usr/lib/nyra/firewall.nft` loaded by `nyra-firewall.service` before the network; `systemd-networkd` requires it | the service active, `policy drop`; a TCP connection from a network namespace to a listener times out, and works once an accept rule is added |
| Only declared units running | units with no purpose in the base blocked from `/usr` (see below) | every running service, waiting timer and listening socket unit matches the allowlist in the script; every blocked unit is inactive |
| No undeclared listening sockets | resolved without LLMNR and mDNS (Containerfile) | every socket in `ss -tuln` matches the allowlist in the script: resolved's stub on loopback, networkd's DHCP client ports |
| Signature policy in place | `/etc/containers/policy.json` is a link to `/usr/lib/nyra/containers/policy.json` (read-only `/usr`) | the link, owner `root:root`, not group or world writable, `sigstoreSigned` present. That it refuses unsigned images is proven in the `build` job (`tools/signing/test-policy.sh`, docs/SIGNING.md) |
| Rare filesystems not autoloaded | `/usr/lib/modprobe.d/nyra-filesystems.conf` (`blacklist`) | `blacklist f2fs` is there and none for vfat, exfat, ntfs3, ext4, btrfs, xfs, udf, isofs, hfsplus, squashfs, erofs, overlay; mounting an f2fs image fails without loading f2fs; a vfat image mounts |

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
| `netavark-dhcp-proxy.socket`, `.service` | a root daemon for DHCP on macvlan container networks, which the base does not set up |
| `e2scrub_all.timer`, `e2scrub_all.service`, `e2scrub_reap.service` | online ext4 checks through LVM snapshots; the base has no LVM |
| `xfs_healer_start.service` | XFS self-healing; the root is ext4 (`xfs_healer@` is blocked too) |

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
socket or timer.

Per systemd.unit(5), any `Condition…=` assigned the empty string resets the whole list, conditions
of every kind, including any in the unit file itself (`systemctl cat <unit>` shows them). Drop-ins
apply in file-name order across `/usr` and `/etc`, so the file must sort after `10-nyra.conf`
(`override.conf` does; `00-….conf` would not). The drop-ins live in `/etc`, so they survive updates.

**Do not unblock `nftables.service`** unless it is meant to replace the Nyra firewall: its reload
and stop run `flush ruleset`, which removes `inet nyra` while `nyra-firewall.service` still shows
`active`. `systemctl restart nyra-firewall` loads the Nyra rules again. (`After=nftables.service`
only orders the two at boot.)

Kept: `fstrim.timer` (weekly TRIM for SSDs), `systemd-tmpfiles-clean.timer`, `nyra-updated.timer`
(update checks, docs/UPDATES.md), `podman-restart.service`
(starts the user's rootful containers with `--restart=always` at boot), `podman-clean-transient.service`.

The check lists running services, waiting timers and listening sockets. One-shot units that run
at boot and exit are not on that list; the blocked ones are checked one by one.

## Firewall

The ruleset (`inet nyra`, input hook only) lets in loopback, replies to connections this machine
started, the ICMPv6 that IPv6 needs (neighbour discovery, router advertisements, MLD queries) and
DHCPv6 replies from the link. Everything else that is addressed to this machine is dropped.
Outbound and forwarded traffic is not filtered.

- nftables, not firewalld, for now: the plan's firewall is firewalld with per-network zones and a
  D-Bus API for a future Security app. firewalld would bring `polkitd`
  (whose setuid agent helper has an open CVE today), Python GObject bindings and the
  NetworkManager introspection data into the base before anything uses its API. When firewalld
  arrives, it replaces this ruleset (and the `nyra-firewall.service` unit).
- Containers can still reach the network, rootless (Distrobox, `podman run` as a user) or rootful.
  What the firewall stops is inbound traffic: a port published with `podman run -p` or a server
  started inside Distrobox answers on localhost only, not from other machines, until a rule opens
  it. Rootful podman networks with DNS (aardvark-dns on the bridge) also need a rule.
- A port opened on purpose (a server, Quick Share later) needs a rule, and a line in the
  listening-socket allowlist of the test.

## Filesystems

`blacklist` only stops the automatic load, when a mount or udev asks the kernel for a filesystem
type; `modprobe <name>` by an administrator still works. The list holds rare and legacy formats
whose parsers face crafted disks and images (f2fs had CVE-2019-19449 and CVE-2019-19814, still
unfixed upstream). Formats that people plug in stay loadable.
