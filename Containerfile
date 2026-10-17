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
ARG TOOLS=localhost/nyra-tools

# nyra-updated (updated/, docs/UPDATES.md), compiled on the CI tools image (Debian testing, like
# bootc: docs/LESSONS.md). Only the stripped binary and its Cargo.lock (for the SBOM) reach the image.
# Its crates come from the build context "crates" (ci/build-image.sh fetches them once, before the
# first build), mounted read-only; the build has no network. Cargo does not check a crate already in
# its download cache against Cargo.lock, and takes features from the registry index, which nothing
# pins. So neither cargo's cache nor the index is used: each .crate the lock lists is copied, checked
# against the lock's checksum, and unpacked into a directory source that replaces crates.io.
FROM ${TOOLS} AS updated
COPY updated/ /src/
RUN --network=none --mount=type=bind,from=crates,target=/crates --mount=type=tmpfs,dst=/root \
    set -- /crates/registry/cache/*/ && \
    { [ $# = 1 ] || { echo "expected one crate cache directory, found: $*" >&2; exit 1; }; } && \
    c="$1" && mkdir -p /root/vendor /root/.cargo && \
    awk -F'"' '/^name = /{n=$2} /^version = /{v=$2} /^checksum = /{print $2 " " n "-" v}' /src/Cargo.lock > /root/sums && \
    test -s /root/sums && \
    while read -r sum crate; do \
      cp "$c$crate.crate" /root/x.crate && echo "$sum  /root/x.crate" | sha256sum --quiet --strict -c - && \
      tar -xzf /root/x.crate -C /root/vendor && \
      printf '{"files":{},"package":"%s"}' "$sum" > "/root/vendor/$crate/.cargo-checksum.json" || exit 1; \
    done < /root/sums && \
    printf '[source.crates-io]\nreplace-with = "checked"\n[source.checked]\ndirectory = "/root/vendor"\n' > /root/.cargo/config.toml && \
    cd /src && CARGO_NET_OFFLINE=true cargo build --release --locked -p nyra-updated && \
    strip target/release/nyra-updated

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

# apt and dpkg (docs/DEFAULTS.md, "apt and dpkg"): apt is not in the image, and Debian's dpkg moves
# to /usr/lib/nyra/dpkg; files/ puts apt, apt-get and a dpkg wrapper in their place, which refuse to
# install with a message that says what to use instead (the queries still go to dpkg).
RUN test ! -e /usr/bin/apt && test ! -e /usr/bin/apt-get && mkdir -p /usr/lib/nyra && \
    mv /usr/bin/dpkg /usr/lib/nyra/dpkg

# udev's hardware database (hwdb.bin, 14 MB) in /usr, built from the image's hwdb.d (the same bytes
# every build): without it, systemd-hwdb-update writes it to /etc at the first boot, and every copy
# of /etc would carry it (docs/BOOT.md, "Restore earlier settings"). It still goes to /etc when the
# user adds rules in /etc/udev/hwdb.d.
RUN systemd-hwdb update --usr && test -s /usr/lib/udev/hwdb.bin && test ! -e /etc/udev/hwdb.bin

# Our files in /usr: the signature policy (docs/SIGNING.md), the boot settings (docs/BOOT.md) and
# the update units and configuration (docs/UPDATES.md).
# Our systemd-firstboot drop-in repeats systemd's command line without --prompt-root-password
# (docs/BOOT.md, "No first-boot questions"): the build fails when systemd's own line changes.
COPY files/usr/ /usr/
RUN dpkg --print-architecture && dpkg -i /dev/null 2>&1 | grep -q Distrobox && \
    apt-get install hello 2>&1 | grep -q Distrobox && \
    grep -Fqx 'ExecStart=systemd-firstboot --prompt-locale --prompt-keymap-auto --prompt-timezone --prompt-root-password --mute-console=yes' \
      /usr/lib/systemd/system/systemd-firstboot.service
COPY --from=updated /src/target/release/nyra-updated /usr/libexec/nyra-updated
COPY --from=updated /src/Cargo.lock /usr/share/doc/nyra-updated/Cargo.lock

# Authenticated time (docs/DEFAULTS.md, "Time"): chronyd as Debian's restricted NTS client, with our
# configuration from /usr (drop-in). Our preset replaces the units that Debian's scripts and mkosi's
# presets enabled; systemd applies it again at the first boot. systemd-timedated manages the same
# unit (ntp-units.d/10-nyra.list). No systemd-timesyncd (chrony conflicts with it). The build fails
# if the configuration does not parse.
RUN systemctl preset chronyd-restricted.service chrony.service chrony-wait.service && \
    test "$(systemctl is-enabled chronyd-restricted.service)" = enabled && \
    test "$(systemctl is-enabled chrony.service)" = disabled && \
    test "$(systemctl is-enabled chrony-wait.service)" = disabled && \
    ! test -e /usr/lib/systemd/system/systemd-timesyncd.service && \
    test "$(cat /usr/lib/systemd/ntp-units.d/*.list | grep -v '^#' | head -1)" = chronyd-restricted.service && \
    chronyd -p -f /usr/lib/nyra/chrony/chrony.conf | grep -c ' nts$' | grep -qx 2

# Removable media (docs/DEFAULTS.md): udisks2 mounts what a user asks for with Nyra's options
# (90-nyra-udisks.rules); it and polkitd start through D-Bus, not at boot (our preset).
RUN systemctl preset udisks2.service polkit-agent-helper.socket && \
    test "$(systemctl is-enabled udisks2.service)" = disabled && \
    test "$(systemctl is-enabled polkit-agent-helper.socket)" = disabled && \
    test -f /usr/share/dbus-1/system-services/org.freedesktop.UDisks2.service && \
    test -f /usr/share/dbus-1/system-services/org.freedesktop.PolicyKit1.service && \
    test -x /usr/lib/nyra/media/trusted && test -f /usr/lib/udev/rules.d/90-nyra-udisks.rules && \
    test -f /usr/share/polkit-1/rules.d/49-nyra.rules && test -f /usr/share/polkit-1/rules.d/50-default.rules && \
    grep -q pam_systemd /etc/pam.d/common-session && \
    test "$(/usr/lib/nyra/media/trusted)" = NYRA_MEDIA_TRUSTED=0

# Image signatures (docs/SIGNING.md): images from updates.nyraos.com must carry our keyless
# signature; the policy and the Sigstore trust roots live in /usr. containers/image only reads
# /etc/containers, so /etc gets symlinks and nothing else: the content still updates with the image.
RUN mkdir -p /etc/containers/registries.d && \
    ln -sfn /usr/lib/nyra/containers/policy.json /etc/containers/policy.json && \
    ln -sfn /usr/lib/nyra/containers/registries.d/nyra.yaml /etc/containers/registries.d/nyra.yaml

# Boot (docs/BOOT.md), on the ESP, where bootc does neither: at every boot the boot files (shim,
# systemd-boot, MokManager; named and fallback copies), loader.conf (no command line editor) and the
# "Nyra OS" firmware entry first in BootOrder; three boot tries for every newly staged version.
# The ESP is read-only at /boot, mounted dirsync at every boot instead of on access, and writable
# only through esp-writable; it is synced after bootc-finalize-staged (drop-ins, docs/BOOT.md).
RUN mkdir -p /usr/lib/systemd/system/multi-user.target.wants && cd /usr/lib/systemd/system/multi-user.target.wants && \
    ln -s ../nyra-boot-repair.service ../nyra-boot-counter.service . && \
    test -f nyra-boot-repair.service && test -f nyra-boot-counter.service && test -x /usr/lib/nyra/boot/esp-sync && \
    test -x /usr/lib/nyra/boot/esp-writable && test -x /usr/bin/mawk && test -f ../boot.mount.d/10-nyra.conf && \
    test -f ../boot.automount.d/10-nyra.conf && test -f ../local-fs.target.d/10-nyra.conf && \
    test -f ../systemd-bless-boot.service && test -f ../systemd-bless-boot.service.d/20-esp.conf && \
    test -f ../systemd-boot-random-seed.service && test -f ../systemd-boot-random-seed.service.d/10-nyra.conf && \
    test -f ../bootc-finalize-staged.service && test -f ../bootc-finalize-staged.service.d/10-nyra.conf

# Units that Debian packages enable but that have no purpose in the base (docs/DEFAULTS.md, the
# reasons are there), blocked from /usr; a layer that needs one creates /usr/lib/nyra/allow-<unit>.
RUN for u in nftables.service dpkg-db-backup.timer dpkg-db-backup.service \
      podman.socket podman.service podman-auto-update.timer podman-auto-update.service \
      podman-restart.service podman-clean-transient.service \
      netavark-dhcp-proxy.socket netavark-dhcp-proxy.service \
      e2scrub_all.timer e2scrub_all.service e2scrub_reap.service xfs_healer_start.service \
      systemd-pcrlock-file-system.service systemd-pcrlock-firmware-code.service \
      systemd-pcrlock-firmware-config.service systemd-pcrlock-machine-id.service \
      systemd-pcrlock-make-policy.service systemd-pcrlock-secureboot-authority.service \
      systemd-pcrlock-secureboot-policy.service systemd-pcrlock.socket systemd-sysupdate-notify-pcrlock.socket \
      systemd-sysupdate-notify-bootctl.socket \
      systemd-tpm2-clear.service systemd-pcrextend.socket systemd-pcrmachine.service systemd-pcrproduct.service \
      systemd-pcrnvdone.service systemd-pcrfs-root.service tpm-udev.path systemd-boot-update.service; do \
      test -f "/usr/lib/systemd/system/$u" && mkdir -p "/usr/lib/systemd/system/$u.d" && \
      printf '# Nyra: no purpose in the base image (docs/DEFAULTS.md)\n[Unit]\nConditionPathExists=/usr/lib/nyra/allow-%s\n' "$u" \
        > "/usr/lib/systemd/system/$u.d/10-nyra.conf" || exit 1; done

# No NvPCRs (docs/DEFAULTS.md, "TPM measurement units that stay"): without their definitions
# systemd-tpm2-setup-early allocates no NV index in the TPM, and dracut copies none into the initramfs;
# the measurement of each login into the NvPCR "login" is blocked with them (it would fail).
RUN rm /usr/lib/nvpcr/*.nvpcr && rmdir /usr/lib/nvpcr && \
    test -f /usr/lib/systemd/system/systemd-pcrlogin@.service && \
    mkdir -p /usr/lib/systemd/system/systemd-pcrlogin@.service.d && \
    printf '# Nyra: no NvPCRs in the base image (docs/DEFAULTS.md)\n[Unit]\nConditionPathExists=/usr/lib/nyra/allow-pcrlogin\n' \
      > /usr/lib/systemd/system/systemd-pcrlogin@.service.d/10-nyra.conf

# Secure defaults (docs/DEFAULTS.md): AppArmor profiles and the inbound firewall at every boot,
# enabled from /usr; systemd-networkd does not start without the firewall. A copy of the profiles in
# /usr loads when /etc/apparmor.d is gone (apparmor.service drop-in).
RUN cp -a /etc/apparmor.d /usr/lib/nyra/apparmor.d && \
    mkdir -p /usr/lib/systemd/system/sysinit.target.wants /usr/lib/systemd/system/systemd-networkd.service.d && \
    cd /usr/lib/systemd/system/sysinit.target.wants && ln -sf ../apparmor.service ../nyra-firewall.service . && \
    test -f apparmor.service && test -f nyra-firewall.service && test -x /usr/sbin/nft && \
    printf '# Nyra: no network without the inbound firewall\n[Unit]\nRequires=nyra-firewall.service\nAfter=nyra-firewall.service\n' \
      > /usr/lib/systemd/system/systemd-networkd.service.d/10-nyra-firewall.conf

# Updates (docs/UPDATES.md): the check timer, and the health checks that boot-complete.target requires,
# with the target pulled in on every boot (not only on counted ones); the daily copy of /etc
# (docs/BOOT.md, "Restore earlier settings"). The build fails if a unit does
# not verify (these, and the shutdown ones: console hangup, journal flush; docs/LESSONS.md), or if
# the configuration is invalid or trusts a test key, or the notice health-failed runs is missing.
# The image's default channel must be stable: every machine without a channel of its own follows
# it, and the same image is promoted from one channel to the next (docs/UPDATES.md, "Channels").
# (systemd-analyze writes to /run, which must stay empty in the image.)
RUN --mount=type=tmpfs,dst=/run cd /usr/lib/systemd/system && mkdir -p timers.target.wants boot-complete.target.requires && \
    ln -s ../nyra-updated.timer ../nyra-etc-copy.timer timers.target.wants/ && \
    ln -s ../boot-complete.target multi-user.target.wants/ && \
    ln -s ../nyra-health-system.service ../nyra-health-bootc.service ../nyra-health-network.service \
      boot-complete.target.requires/ && \
    systemd-analyze verify --man=no --recursive-errors=no nyra-updated.service nyra-updated.timer \
      nyra-etc-copy@daily.service nyra-etc-copy.timer \
      nyra-updated-health-failed.service nyra-health-system.service nyra-health-bootc.service nyra-health-network.service \
      systemd-bless-boot.service systemd-boot-random-seed.service apparmor.service chronyd-restricted.service \
      serial-getty@ttyS0.service getty@tty1.service nyra-tty-hangup@ttyS0.service systemd-journal-flush.service && \
    test -x /usr/lib/nyra/health/notice && test -x /usr/lib/nyra/health/network && /usr/libexec/nyra-updated check-config && \
    grep -qx 'channel = stable' /usr/lib/nyra/updates/updated.conf

# keyutils without its request-key upcall (mkosi/mkosi.conf, RemoveFiles=): only keyctl.
RUN test -x /usr/bin/keyctl && \
    for f in /usr/sbin/request-key /usr/sbin/key.dns_resolver /etc/request-key.conf /etc/request-key.d \
      /usr/share/keyutils /sbin/request-key; do \
      ! test -e "$f" || { echo "keyutils left $f in the image"; exit 1; }; done

# Generic initramfs (not host-only) with the bootc module, LUKS and TPM2 unlock, the measurement of
# the boot phases into PCR 11 (systemd-pcrextend: the signed PCR policy expects them, docs/BOOT.md),
# and the udev rule that probes the boot disk once more when its first probe could not read
# LoaderDevicePartUUID (docs/BOOT.md, "Finding the root partition"), and for an encrypted root: no time
# limit for its device, the passphrase asked again after wrong ones, a root partition still required
# within 90 s (nyra-root-wait.service), the ESP found on its disk (nyra-luks-root.service), and its
# TPM2 enrollment (nyra-tpm-enroll.service) with the tools that runs (docs/BOOT.md, "Disk encryption").
# The 10 s device timeout of the running system (dev-.device.d) must stay out of it: the root may take
# longer to appear.
RUN --mount=type=tmpfs,dst=/tmp --mount=type=tmpfs,dst=/root \
    printf 'systemdsystemconfdir=/etc/systemd/system\nsystemdsystemunitdir=/usr/lib/systemd/system\n' \
      > /usr/lib/dracut/dracut.conf.d/30-nyra-bootc-module.conf && \
    test -f /usr/lib/udev/rules.d/61-nyra-gpt-auto-root.rules && \
    mkdir -p /usr/lib/systemd/system/initrd.target.wants && \
    ln -s ../nyra-root-wait.service ../nyra-luks-root.service ../nyra-tpm-enroll.service \
      /usr/lib/systemd/system/initrd.target.wants/ && \
    printf 'reproducible=yes\nhostonly=no\ncompress=zstd\nadd_dracutmodules+=" bootc crypt systemd-cryptsetup tpm2-tss systemd-pcrextend "\n' \
      > /usr/lib/dracut/dracut.conf.d/30-nyra-container-build.conf && \
    printf '%s\n' 'install_items+=" /usr/lib/udev/rules.d/61-nyra-gpt-auto-root.rules /usr/lib/nyra/boot/root-wait /usr/lib/systemd/system/nyra-root-wait.service /usr/lib/systemd/system/initrd.target.wants/nyra-root-wait.service /usr/lib/systemd/system/systemd-cryptsetup@root.service.d/10-nyra.conf /usr/lib/systemd/system/dev-gpt\x2dauto\x2droot.device.d/10-nyra.conf /usr/lib/nyra/boot/luks-root /usr/lib/systemd/system/nyra-luks-root.service /usr/lib/systemd/system/initrd.target.wants/nyra-luks-root.service /usr/lib/nyra/boot/tpm-enroll /usr/lib/systemd/system/nyra-tpm-enroll.service /usr/lib/systemd/system/initrd.target.wants/nyra-tpm-enroll.service /usr/bin/systemd-cryptenroll /usr/sbin/cryptsetup /usr/bin/od /usr/bin/keyctl "' \
      >> /usr/lib/dracut/dracut.conf.d/30-nyra-container-build.conf && \
    kver="$(ls /usr/lib/modules)" && dracut --force "/usr/lib/modules/$kver/initramfs.img" "$kver" && \
    lsinitrd "/usr/lib/modules/$kver/initramfs.img" > /tmp/initrd.txt && \
    grep -q ' usr/lib/systemd/system/local-fs.target$' /tmp/initrd.txt && \
    for f in usr/lib/nyra/boot/root-wait usr/lib/systemd/system/nyra-root-wait.service \
      'usr/lib/systemd/system/initrd.target.wants/nyra-root-wait.service -> ' \
      usr/lib/systemd/system/systemd-cryptsetup@root.service.d/10-nyra.conf \
      'usr/lib/systemd/system/dev-gpt\x2dauto\x2droot.device.d/10-nyra.conf' usr/lib/nyra/boot/luks-root \
      usr/lib/systemd/system/nyra-luks-root.service 'usr/lib/systemd/system/initrd.target.wants/nyra-luks-root.service -> ' \
      usr/lib/nyra/boot/tpm-enroll usr/lib/systemd/system/nyra-tpm-enroll.service \
      'usr/lib/systemd/system/initrd.target.wants/nyra-tpm-enroll.service -> ' \
      usr/bin/systemd-cryptenroll usr/sbin/cryptsetup usr/bin/od usr/bin/keyctl; do \
      grep -qF " $f" /tmp/initrd.txt || { echo "not in the initramfs: $f"; exit 1; }; done && \
    ! grep -F 'dev-.device.d' /tmp/initrd.txt

# Mounts from /etc/fstab (docs/BOOT.md): one that fails (a disk that is not connected, a wrong line)
# does not stop the boot in emergency mode, whose root shell is locked anyway. systemd's local-fs.target
# starts emergency.target when it fails, and a drop-in cannot remove a dependency: the running
# system's copy loses its OnFailure= lines. After dracut: the initramfs keeps systemd's own.
RUN f=/usr/lib/systemd/system/local-fs.target && grep -qx 'OnFailure=emergency.target' "$f" && \
    sed -i '/^OnFailure/d' "$f" && ! grep -q '^OnFailure' "$f"

# bootc root filesystem layout: state lives in /var, /usr is read-only, composefs on. /media, where
# udisks2 mounts removable media (docs/DEFAULTS.md), is /run/media: the root itself is read-only.
RUN rm -rf /boot /home /root /usr/local /srv /opt /mnt /media /var && \
    mkdir -p /sysroot /boot /usr/lib/ostree /var && \
    ln -sT sysroot/ostree /ostree && ln -sT var/roothome /root && ln -sT var/srv /srv && ln -sT run/media /media && \
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
# The copy of the AppArmor profiles in /usr (apparmor.service drop-in) is the image's /etc/apparmor.d,
# file for file and link for link, also when a step after the copy changed one of them.
RUN diff -r --no-dereference /etc/apparmor.d /usr/lib/nyra/apparmor.d && bootc container lint --fatal-warnings
