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
# first build), mounted read-only, each checked against Cargo.lock (ci/vendor-crates.sh); the build
# has no network.
FROM ${TOOLS} AS updated
COPY updated/ /src/
RUN --network=none --mount=type=bind,from=crates,target=/crates --mount=type=tmpfs,dst=/root \
    --mount=type=bind,source=ci/vendor-crates.sh,target=/vendor-crates.sh \
    sh /vendor-crates.sh /src/Cargo.lock && \
    cd /src && CARGO_NET_OFFLINE=true cargo build --release --locked -p nyra-updated && \
    strip target/release/nyra-updated

# zlib-rs as the system's libz.so.1 (zlib/, docs/DEFAULTS.md "zlib"), from its crates like
# nyra-updated: libz-rs-sys as a static library, linked into a shared library with zlib's soname and
# symbol versions (the version script libz-rs-sys ships, include/zlib.map), as zlib-rs documents.
# gzprintf and gzvprintf are missing: C variadic functions, which stable Rust cannot define.
# Hardened like Debian's libraries: RELRO and immediate binding (-z relro -z now).
FROM ${TOOLS} AS zlib
COPY zlib/ /src/
RUN --network=none --mount=type=bind,from=crates,target=/crates --mount=type=tmpfs,dst=/root \
    --mount=type=bind,source=ci/vendor-crates.sh,target=/vendor-crates.sh \
    sh /vendor-crates.sh /src/Cargo.lock && \
    cd /src && CARGO_NET_OFFLINE=true cargo build --release --locked && \
    set -- /root/vendor/libz-rs-sys-*/include/zlib.map && test -f "$1" && \
    cc -shared -Wl,--gc-sections -Wl,--whole-archive target/release/libz_rs.a -Wl,--no-whole-archive \
      -Wl,--version-script="$1" -Wl,--undefined-version -Wl,-soname,libz.so.1 -Wl,-z,relro,-z,now -lgcc_s -lc \
      -o target/libz.so.1 && \
    strip --strip-unneeded target/libz.so.1 && objdump -T target/libz.so.1 > /root/symbols && \
    grep -Eq ' ZLIB_1\.2\.0 +deflateBound$' /root/symbols && grep -Eq ' ZLIB_1\.3\.2 +compress_z$' /root/symbols && \
    readelf -d target/libz.so.1 | grep -q 'BIND_NOW' && readelf -l target/libz.so.1 | grep -q GNU_RELRO

# ntpd-rs, the time client (ntpd-rs/, docs/DEFAULTS.md "Time"), from its crates like nyra-updated,
# with our patch for a clock that is far off (patches/upstream/ntpd-rs-wrong-clock.md) applied to the
# checked ntp-proto crate. ntpd's build script takes a commit and a date from git, or today's date
# without git: both are given, so the build is the same every time. The licence notices of every
# crate in the programs go to target/doc/third-party (ci/crate-licenses.sh).
FROM ${TOOLS} AS ntpd
COPY ntpd-rs/ /src/
RUN --network=none --mount=type=bind,from=crates,target=/crates --mount=type=tmpfs,dst=/root \
    --mount=type=bind,source=ci/vendor-crates.sh,target=/vendor-crates.sh \
    --mount=type=bind,source=ci/crate-licenses.sh,target=/crate-licenses.sh \
    --mount=type=bind,source=patches/upstream/ntpd-rs-wrong-clock.patch,target=/ntpd-rs.patch \
    sh /vendor-crates.sh /src/Cargo.lock && \
    cd /root/vendor && set -- ntp-proto-*/ && [ $# = 1 ] && git apply -p2 --directory="$1" /ntpd-rs.patch && \
    cd /src && NTPD_RS_GIT_REV=nyra NTPD_RS_GIT_DATE=- CARGO_NET_OFFLINE=true cargo build --release --locked && \
    strip target/release/ntp-daemon target/release/ntp-ctl && \
    CARGO_NET_OFFLINE=true sh /crate-licenses.sh target/doc/third-party && set -- target/doc/third-party/ntpd-*/ && [ $# = 1 ]

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

# su from sudo-rs (docs/DEFAULTS.md, "su") in place of util-linux's, setuid root like it (its package
# script set the mode). Nothing else of sudo-rs stays: no sudo, sudoedit or visudo on the desktop.
RUN test "$(stat -c '%a %U %G' /usr/lib/cargo/bin/su)" = '4755 root root' && test -f /etc/pam.d/su && \
    mv -f /usr/lib/cargo/bin/su /usr/bin/su && \
    rm /usr/lib/cargo/bin/sudo /usr/lib/cargo/bin/visudo /usr/bin/su-rs /usr/bin/sudo-rs /usr/bin/sudoedit-rs \
      /usr/bin/visudo-rs && rmdir /etc/sudoers.d && \
    su --version 2>&1 | grep -q '^su-rs ' && ! command -v sudo && ! command -v sudoedit && ! command -v visudo

# uutils coreutils (docs/DEFAULTS.md, "Core utilities"): every GNU coreutils command that uutils has
# becomes a link to its multi-call binary, which runs the command its link is named after; the rest
# of the build (dracut, the initramfs) already uses them. GNU's basenc, factor and stty stay (uutils
# has none in Debian's build); the build fails when that list changes.
RUN cd /usr/lib/cargo/bin/coreutils && for u in *; do \
      for d in /usr/bin /usr/sbin; do \
        [ -e "$d/$u" ] || continue; \
        grep -q 'GNU coreutils' "$d/$u" || { echo "$d/$u is not GNU's" >&2; exit 1; }; \
        if [ "$d" = /usr/bin ]; then ln -sf coreutils "$d/$u"; else ln -sf ../bin/coreutils "$d/$u"; fi || exit 1; \
      done; \
    done && cd / && rm -r /usr/lib/cargo/bin/coreutils && \
    gnu="$(for f in /usr/bin/* /usr/sbin/*; do \
      if [ -f "$f" ] && [ ! -L "$f" ] && [ "$f" != /usr/bin/coreutils ] && grep -q 'GNU coreutils' "$f"; then echo "${f##*/}"; fi; \
    done | tr '\n' ' ')" && \
    { [ "$gnu" = 'basenc factor stty ' ] || { echo "GNU coreutils left: $gnu" >&2; exit 1; }; } && \
    ls --version | grep -q '(uutils coreutils)' && test "$(readlink /usr/sbin/chroot)" = ../bin/coreutils

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

# zlib-rs (docs/DEFAULTS.md, "zlib"): our libz.so.1 in place of the file Debian's libz.so.1 link points
# to, so every program and library that uses zlib loads it. A program that uses gzprintf or gzvprintf
# would not load: none in the image does, and the build fails if one appears.
COPY --from=zlib /src/target/libz.so.1 /usr/lib/x86_64-linux-gnu/libz.so.1.nyra
COPY --from=zlib /src/Cargo.lock /usr/share/doc/nyra-zlib/Cargo.lock
RUN cd /usr/lib/x86_64-linux-gnu && f="$(readlink libz.so.1)" && test -f "$f" && mv libz.so.1.nyra "$f" && \
    grep -aq zlib-rs libz.so.1 && ! grep -rlaw -e gzprintf -e gzvprintf /usr/bin /usr/sbin /usr/lib /usr/libexec

# Authenticated time (docs/DEFAULTS.md, "Time"): ntpd-rs with our configuration and unit from /usr,
# never root, CAP_SYS_TIME as its only capability, in a sandbox and under its AppArmor profile (moved
# to /etc/apparmor.d, where apparmor.service reads profiles; the copy in /usr follows below). Enabled by
# our preset, which systemd applies again at the first boot; systemd-timedated manages the same unit
# (ntp-units.d/10-nyra.list). No other time client: no chrony, no systemd-timesyncd. The build fails
# if the configuration does not parse or lacks its four NTS servers or three agreeing sources, if
# /usr/lib/clock-epoch (the image's date, the floor of the clock; image.yml checks that its time is
# SOURCE_DATE_EPOCH) is missing, or if the profile does not parse.
COPY --from=ntpd /src/target/release/ntp-daemon /src/target/release/ntp-ctl /usr/bin/
COPY --from=ntpd /src/Cargo.lock /src/target/doc/ /usr/share/doc/ntpd-rs/
RUN mv /usr/lib/nyra/ntpd-rs/usr.bin.ntp-daemon /etc/apparmor.d/ && \
    apparmor_parser --skip-kernel-load --skip-cache /etc/apparmor.d/usr.bin.ntp-daemon && \
    systemctl preset ntpd-rs.service && test "$(systemctl is-enabled ntpd-rs.service)" = enabled && \
    ! test -e /usr/lib/systemd/system/systemd-timesyncd.service && ! test -e /usr/sbin/chronyd && \
    test "$(cat /usr/lib/systemd/ntp-units.d/*.list | grep -v '^#' | head -1)" = ntpd-rs.service && \
    ntp-ctl validate -c /usr/lib/nyra/ntpd-rs/ntp.toml && \
    test "$(grep -c '^mode = "nts"$' /usr/lib/nyra/ntpd-rs/ntp.toml)" = 4 && \
    grep -qx 'minimum-agreeing-sources = 3' /usr/lib/nyra/ntpd-rs/ntp.toml && test -f /usr/lib/clock-epoch

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

# Without a network (docs/DEFAULTS.md): nothing in the base pulls in network-online.target, so
# systemd-networkd-wait-online never runs at boot. Two of the blocked units wanted it from
# default.target; our preset disables them. An update check waits for the network on its own, for a
# finite time shorter than the timer's 6 hours, so a check always runs and reports.
RUN --mount=type=tmpfs,dst=/run systemctl preset podman-restart.service podman-auto-update.service && \
    test "$(systemctl is-enabled podman-restart.service)" = disabled && \
    test "$(systemctl is-enabled podman-auto-update.service)" = disabled && \
    systemd-analyze verify --man=no --recursive-errors=no /usr/lib/systemd/system/nyra-updated-wait-online.service && \
    t="$(sed -n 's/^ExecStart=.*systemd-networkd-wait-online .*--timeout=\([0-9]*\)$/\1/p' \
      /usr/lib/systemd/system/nyra-updated-wait-online.service)" && \
    test "${t:-0}" -gt 0 && test "$t" -lt 21600

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
    ln -s ../nyra-health-system.service ../nyra-health-bootc.service boot-complete.target.requires/ && \
    systemd-analyze verify --man=no --recursive-errors=no nyra-updated.service nyra-updated.timer \
      nyra-etc-copy@daily.service nyra-etc-copy.timer \
      nyra-updated-health-failed.service nyra-health-system.service nyra-health-bootc.service \
      systemd-bless-boot.service systemd-boot-random-seed.service apparmor.service ntpd-rs.service \
      serial-getty@ttyS0.service getty@tty1.service nyra-tty-hangup@ttyS0.service systemd-journal-flush.service && \
    test -x /usr/lib/nyra/health/notice && /usr/libexec/nyra-updated check-config && \
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
