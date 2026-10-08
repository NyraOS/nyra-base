# SPDX-License-Identifier: GPL-3.0-or-later
# CI tools: the bootc build dependencies and mkosi, from Debian testing at the
# same snapshot date as the image (unstable can be mid-transition, testing is
# consistent). The dated base image is older than any snapshot we use.
FROM docker.io/library/debian:testing-20261005@sha256:f35963177a0584848d5222b3d2b4f4ebcc6434d39db0a709c3088237ef619cbf
ARG SNAPSHOT
RUN test -n "$SNAPSHOT" && rm -f /etc/apt/sources.list.d/* /etc/apt/sources.list && \
    printf 'Types: deb\nURIs: http://snapshot.debian.org/archive/debian/%s/\nSuites: testing\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\nCheck-Valid-Until: no\n' \
      "$SNAPSHOT" > /etc/apt/sources.list.d/debian.sources && \
    printf 'Acquire::Retries "5";\nAcquire::http::Timeout "60";\n' > /etc/apt/apt.conf.d/80-retries && \
    apt-get update -q && \
    apt-get install -y -q --no-install-recommends \
      ca-certificates git make cargo rustc clang libclang-dev pkgconf go-md2man binutils \
      libzstd-dev libostree-dev libselinux1-dev libssl-dev \
      mkosi apt dpkg debian-archive-keyring bubblewrap zstd systemd uidmap cpio python3-pefile && \
    apt-get clean && rm -rf /var/lib/apt/lists/*
