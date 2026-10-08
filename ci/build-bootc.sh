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
cargo fetch --locked
CARGO_NET_OFFLINE=true make bin install DESTDIR=/out
strip --strip-unneeded /out/usr/bin/bootc /out/usr/bin/system-reinstall-bootc /out/usr/lib/bootc/initramfs-setup
install -D -m 0644 Cargo.lock /out/usr/share/doc/bootc/Cargo.lock
tar -C /out -cf /cache/bootc.tar .
