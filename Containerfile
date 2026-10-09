# SPDX-License-Identifier: GPL-3.0-or-later
# nyra-base: the bootc layer on top of the mkosi output (mkosi/mkosi.conf).
# The initramfs and root filesystem steps follow bootcrew/mono (Apache-2.0,
# https://github.com/bootcrew/mono).
# Sealed boot (docs/BOOT.md): the kernel and initramfs leave /usr and go into a UKI whose command
# line pins the composefs digest. ci/build-image.sh runs the steps: target "sealed", the UKI from
# that committed image (bootc container ukify), signing outside the build, then this file again
# with SEALED=<the committed image> and the signed UKI as the build context "uki".
ARG ROOTFS=localhost/nyra-base-rootfs:latest
ARG SEALED=sealed
FROM ${ROOTFS} AS base

# bootc expects the kernel next to its modules.
RUN kver="$(ls /usr/lib/modules)" && [ "$(echo "$kver" | wc -l)" = 1 ] && \
    { [ -e "/usr/lib/modules/$kver/vmlinuz" ] || cp "/boot/vmlinuz-$kver" "/usr/lib/modules/$kver/vmlinuz"; }

# Configuration only through /usr: on installed systems /etc is kept across updates.
# (systemd-networkd and systemd-resolved are already enabled by the presets mkosi applies.)
# - no automatic update + reboot (bootc-fetch-apply-updates timer and service), no XFS healer on an ext4 root
# - wired network with DHCP; resolved without LLMNR and mDNS (no listening ports on the LAN)
RUN for u in bootc-fetch-apply-updates.timer bootc-fetch-apply-updates.service; do \
      mkdir -p "/usr/lib/systemd/system/$u.d" && \
      printf '# Nyra: updates are applied by nyra-updated, never with an automatic reboot\n[Unit]\nConditionPathExists=/usr/lib/nyra/allow-bootc-auto-reboot\n' \
        > "/usr/lib/systemd/system/$u.d/10-nyra.conf"; done && \
    mkdir -p /usr/lib/systemd/system/xfs_healer@.service.d /usr/lib/systemd/resolved.conf.d \
      /usr/lib/systemd/network /usr/lib/dracut/dracut.conf.d && \
    printf '# Nyra: the root filesystem is not XFS\n[Unit]\nConditionPathExists=/usr/lib/nyra/allow-xfs-healer\n' \
      > /usr/lib/systemd/system/xfs_healer@.service.d/10-nyra.conf && \
    printf '# Nyra: no name resolution services listening on the network\n[Resolve]\nLLMNR=no\nMulticastDNS=no\n' \
      > /usr/lib/systemd/resolved.conf.d/10-nyra.conf && \
    printf 'L! /etc/resolv.conf - - - - /run/systemd/resolve/stub-resolv.conf\n' > /usr/lib/tmpfiles.d/resolv-conf.conf && \
    printf '[Match]\nName=en* eth*\n[Network]\nDHCP=yes\n' > /usr/lib/systemd/network/80-nyra-wired.network && \
    systemctl is-enabled systemd-networkd.service && systemctl is-enabled systemd-resolved.service

# Our files in /usr: the signature policy (docs/SIGNING.md) and the boot settings (docs/BOOT.md).
COPY files/usr/ /usr/

# Image signatures (docs/SIGNING.md): images from updates.nyraos.com must carry our keyless
# signature; the policy and the Sigstore trust roots live in /usr. containers/image only reads
# /etc/containers, so /etc gets symlinks and nothing else: the content still updates with the image.
RUN mkdir -p /etc/containers/registries.d && \
    ln -sfn /usr/lib/nyra/containers/policy.json /etc/containers/policy.json && \
    ln -sfn /usr/lib/nyra/containers/registries.d/nyra.yaml /etc/containers/registries.d/nyra.yaml

# Boot (docs/BOOT.md), on the ESP, where bootc does neither: loader.conf from /usr (no command
# line editor at the boot menu) and three boot tries for every newly staged version.
RUN mkdir -p /usr/lib/systemd/system/multi-user.target.wants && cd /usr/lib/systemd/system/multi-user.target.wants && \
    ln -s ../nyra-boot-loader-conf.service ../nyra-boot-counter.service . && \
    test -f nyra-boot-loader-conf.service && test -f nyra-boot-counter.service && test -x /usr/lib/nyra/boot/esp-sync

# Units that Debian packages enable but that have no purpose in the base (docs/DEFAULTS.md, the
# reasons are there), blocked from /usr; a layer that needs one creates /usr/lib/nyra/allow-<unit>.
RUN for u in nftables.service dpkg-db-backup.timer dpkg-db-backup.service \
      podman.socket podman.service podman-auto-update.timer podman-auto-update.service \
      netavark-dhcp-proxy.socket netavark-dhcp-proxy.service \
      e2scrub_all.timer e2scrub_all.service e2scrub_reap.service xfs_healer_start.service; do \
      test -f "/usr/lib/systemd/system/$u" && mkdir -p "/usr/lib/systemd/system/$u.d" && \
      printf '# Nyra: no purpose in the base image (docs/DEFAULTS.md)\n[Unit]\nConditionPathExists=/usr/lib/nyra/allow-%s\n' "$u" \
        > "/usr/lib/systemd/system/$u.d/10-nyra.conf" || exit 1; done

# Secure defaults (docs/DEFAULTS.md): AppArmor profiles and the inbound firewall at every boot,
# enabled from /usr; systemd-networkd does not start without the firewall.
RUN mkdir -p /usr/lib/systemd/system/sysinit.target.wants /usr/lib/systemd/system/systemd-networkd.service.d && \
    cd /usr/lib/systemd/system/sysinit.target.wants && ln -sf ../apparmor.service ../nyra-firewall.service . && \
    test -f apparmor.service && test -f nyra-firewall.service && test -x /usr/sbin/nft && \
    printf '# Nyra: no network without the inbound firewall\n[Unit]\nRequires=nyra-firewall.service\nAfter=nyra-firewall.service\n' \
      > /usr/lib/systemd/system/systemd-networkd.service.d/10-nyra-firewall.conf

# Generic initramfs (not host-only) with the bootc module, LUKS and TPM2 unlock.
RUN --mount=type=tmpfs,dst=/tmp --mount=type=tmpfs,dst=/root \
    printf 'systemdsystemconfdir=/etc/systemd/system\nsystemdsystemunitdir=/usr/lib/systemd/system\n' \
      > /usr/lib/dracut/dracut.conf.d/30-nyra-bootc-module.conf && \
    printf 'reproducible=yes\nhostonly=no\ncompress=zstd\nadd_dracutmodules+=" bootc crypt systemd-cryptsetup tpm2-tss "\n' \
      > /usr/lib/dracut/dracut.conf.d/30-nyra-container-build.conf && \
    kver="$(ls /usr/lib/modules)" && dracut --force "/usr/lib/modules/$kver/initramfs.img" "$kver"

# bootc root filesystem layout: state lives in /var, /usr is read-only, composefs on.
RUN rm -rf /boot /home /root /usr/local /srv /opt /mnt /var && \
    mkdir -p /sysroot /boot /usr/lib/ostree /var && \
    ln -sT sysroot/ostree /ostree && ln -sT var/roothome /root && ln -sT var/srv /srv && \
    ln -sT var/opt /opt && ln -sT var/mnt /mnt && ln -sT var/home /home && ln -sT ../var/usrlocal /usr/local && \
    printf 'd /var/%s 0755 root root -\n' opt home srv mnt usrlocal > /usr/lib/tmpfiles.d/bootc-base-dirs.conf && \
    printf 'd /var/roothome 0700 root root -\nd /run/media 0755 root root -\n' >> /usr/lib/tmpfiles.d/bootc-base-dirs.conf && \
    printf '[composefs]\nenabled = yes\n[sysroot]\nreadonly = true\n' > /usr/lib/ostree/prepare-root.conf && \
    sed -i 's|^HOME=.*|HOME=/var/home|' /etc/default/useradd

FROM base AS kernel
RUN mkdir /kernel && bootc container split-kernel-and-rootfs --rootfs / --output /kernel

FROM kernel AS sealed
RUN rm -rf /kernel

# The final image: the sealed root filesystem plus the signed UKI. bootc installs and updates only
# the UKI (a "uki" boot entry), never a kernel and initramfs of its own.
FROM ${SEALED}
COPY --from=uki . /boot/EFI/Linux/
LABEL containers.bootc=1
RUN bootc container lint --fatal-warnings
