#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds bootc from the pinned source, inside the CI tools image (ci/tools.Containerfile),
# and writes the stripped install tree to /cache/bootc.tar.
# Inputs: BOOTC_REF, BOOTC_COMMIT, SOURCE_DATE_EPOCH. The bootc cache key in
# .github/workflows/image.yml hashes this file, so any change here rebuilds bootc.
set -euxo pipefail
git clone -q --depth 1 --branch "$BOOTC_REF" https://github.com/bootc-dev/bootc.git /src
test "$(git -C /src rev-parse HEAD)" = "$BOOTC_COMMIT"
cd /src
# zlink-macros 0.7.0 emits the variants of a generated enum (cfsctl's varlink service) in HashMap
# order, which changes with every compile, so the binary does too; 0.7.1 uses a BTreeMap
# (docs/LESSONS.md). bootc's Cargo.lock still has 0.7.0. When a newer bootc has 0.7.1 or later,
# the grep fails the build: drop these lines then. The updated lock is pinned by hash, so the zlink
# checksums are not simply taken from the crates.io index of the day (the hash depends on the cargo
# version in ci/tools.Containerfile: after a change there, put the value the error prints).
grep -A1 -x 'name = "zlink-macros"' Cargo.lock | grep -qx 'version = "0.7.0"'
cargo update -p zlink --precise 0.7.1
echo "9e589a99e44be21d17dbca9e2423e8f6899991531a65005a55e9a2beaebc8fd8  Cargo.lock" | sha256sum -c - ||
  { echo "Cargo.lock after the zlink update is not the pinned one: $(sha256sum Cargo.lock)" >&2; exit 1; }
cargo fetch --locked
CARGO_NET_OFFLINE=true make bin install DESTDIR=/out
strip --strip-unneeded /out/usr/bin/bootc /out/usr/bin/system-reinstall-bootc /out/usr/lib/bootc/initramfs-setup
install -D -m 0644 Cargo.lock /out/usr/share/doc/bootc/Cargo.lock
# Same order, times and owners every time, so two builds give the same tar (compared on release builds).
tar --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --numeric-owner -C /out -cf /cache/bootc.tar .
