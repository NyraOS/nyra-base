# Secure defaults

What an installed nyra-base system turns on by itself (NyraOS T15, DECIZII F101, F151, F168), and
how CI proves it. `tools/vm/security-defaults.sh` boots the disk that the `install-boot` job
installed with `bootc install to-disk` and fails on any regression.

| Default | How | Checked in the VM |
|---|---|---|
| AppArmor on, profiles loaded | `apparmor` package; `apparmor.service` enabled from `/usr` (`sysinit.target.wants`) | AppArmor in the active LSMs, the service active, profiles loaded, at least one in enforce mode |
| Kernel lockdown `integrity` | `lockdown=integrity` in `/usr/lib/bootc/kargs.d/10-nyra-lockdown.toml`; Debian's kernel also turns it on under Secure Boot | `/sys/kernel/security/lockdown` shows `[integrity]` |
| Inbound firewall, default deny | `nftables`; `/usr/lib/nyra/firewall.nft` loaded by `nyra-firewall.service` before the network; `systemd-networkd` requires it | the service active, `policy drop`; a TCP connection from a network namespace to a listener times out, and works once an accept rule is added |
| No undeclared listening sockets | resolved without LLMNR and mDNS (Containerfile) | every socket in `ss -tuln` matches the allowlist in the script: resolved's stub on loopback, networkd's DHCP client ports |
| Signature policy in place (F168) | `/etc/containers/policy.json` is a link to `/usr/lib/nyra/containers/policy.json` (read-only `/usr`) | the link, owner `root:root`, not group or world writable, `sigstoreSigned` present. That it refuses unsigned images is proven in the `build` job (`tools/signing/test-policy.sh`, docs/SIGNING.md) |
| Rare filesystems not autoloaded | `/usr/lib/modprobe.d/nyra-filesystems.conf` (`blacklist`) | `blacklist f2fs` is there and none for vfat, exfat, ntfs3, ext4, btrfs, xfs, udf, isofs, hfsplus, squashfs, erofs, overlay; mounting an f2fs image fails without loading f2fs; a vfat image mounts |

Covered elsewhere: the Secure Boot chain (shim, systemd-boot, signed UKI; unsigned and wrongly
signed refused) and boot counting are proven in the same job (docs/BOOT.md); the Nyra MOK and the
sealed boot come with NyraOS#65. That the defaults survive an update is for the update tests
(NyraOS#66): they can run this script again after `bootc switch`.

## Firewall

The ruleset (`inet nyra`, input hook only) lets in loopback, replies to connections this machine
started, the ICMPv6 that IPv6 needs (neighbour discovery, router advertisements, MLD queries) and
DHCPv6 replies from the link. Everything else that is addressed to this machine is dropped.
Outbound and forwarded traffic is not filtered.

- nftables, not firewalld, for now: the plan's firewall is firewalld with per-network zones and a
  D-Bus API for the Security app (PLAN-SECURITATE, Phase 1). firewalld would bring `polkitd`
  (whose setuid agent helper has an open CVE today), Python GObject bindings and the
  NetworkManager introspection data into the base before anything uses its API. When firewalld
  arrives, it replaces this ruleset (and the `nyra-firewall.service` unit).
- Rootless containers (Distrobox, `podman run` as a user) are not affected. Rootful podman
  networks with DNS (aardvark-dns on the bridge) need an explicit rule.
- A port opened on purpose (a server, Quick Share later) needs a rule, and a line in the
  listening-socket allowlist of the test.

## Filesystems

`blacklist` only stops the automatic load, when a mount or udev asks the kernel for a filesystem
type; `modprobe <name>` by an administrator still works. The list holds rare and legacy formats
whose parsers face crafted disks and images (f2fs had CVE-2019-19449 and CVE-2019-19814, still
unfixed upstream). Formats that people plug in stay loadable.
