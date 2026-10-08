# SPDX-License-Identifier: GPL-3.0-or-later
# CI tools: the bootc build dependencies and mkosi, from Debian testing at the
# same snapshot date as the image (unstable can be mid-transition, testing is
# consistent). The dated base image is older than any snapshot we use.
# The source is http (the base image has no ca-certificates) and snapshots are
# old, so apt checks signatures but not freshness (Check-Valid-Until: no). To stop
# a network attacker from serving an older, correctly signed InRelease, the build
# fails unless the verified InRelease is dated within 12 h before SNAPSHOT
# (testing is published every 6 h and a snapshot id resolves to the last import
# at or before it).
FROM docker.io/library/debian:testing-20261005@sha256:f35963177a0584848d5222b3d2b4f4ebcc6434d39db0a709c3088237ef619cbf
ARG SNAPSHOT
RUN test -n "$SNAPSHOT" && rm -f /etc/apt/sources.list.d/* /etc/apt/sources.list && \
    printf 'Types: deb\nURIs: http://snapshot.debian.org/archive/debian/%s/\nSuites: testing\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\nCheck-Valid-Until: no\n' \
      "$SNAPSHOT" > /etc/apt/sources.list.d/debian.sources && \
    printf 'Acquire::Retries "5";\nAcquire::http::Timeout "60";\n' > /etc/apt/apt.conf.d/80-retries && \
    apt-get update -q && \
    want=$(date -u -d "$(echo "$SNAPSHOT" | sed -E 's/^(....)(..)(..)T(..)(..)(..)Z$/\1-\2-\3T\4:\5:\6Z/')" +%s) && \
    rel=$(sed -n '/^Date: /{s///p;q}' "/var/lib/apt/lists/snapshot.debian.org_archive_debian_${SNAPSHOT}_dists_testing_InRelease") && \
    test -n "$rel" && got=$(date -u -d "$rel" +%s) && \
    { [ "$got" -le "$want" ] && [ "$got" -gt $((want - 43200)) ] || \
      { echo "InRelease Date '$rel' is not within 12 h before snapshot $SNAPSHOT" >&2; exit 1; }; } && \
    apt-get install -y -q --no-install-recommends \
      ca-certificates git make cargo rustc clang libclang-dev pkgconf go-md2man binutils \
      libzstd-dev libostree-dev libselinux1-dev libssl-dev \
      mkosi apt dpkg debian-archive-keyring bubblewrap zstd systemd uidmap cpio python3-pefile && \
    apt-get clean && rm -rf /var/lib/apt/lists/*
