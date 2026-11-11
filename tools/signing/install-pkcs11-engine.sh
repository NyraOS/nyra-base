#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# OpenSSL's PKCS#11 engine (libengine-pkcs11-openssl) for the release-sign jobs, pinned in this one place.
#   sudo tools/signing/install-pkcs11-engine.sh
# As root on an ubuntu-24.04 (noble, amd64) runner, after the job's apt-get installs (which must bring
# p11-kit, the package's one dependency the runner may lack) and before the auth step. Any error exits 1.
#
# Why it is pinned: the engine is the code that hands the KMS keys to `sbsign` and `openssl dgst`. libp11
# 0.4.12's engine crashes (SIGSEGV) when it loads a private key on OpenSSL 3.0.12 and 3.0.13, and noble
# ships 3.0.13. Ubuntu's 0.4.12-1.1ubuntu1 carries a workaround (it prints "Workaround for OpenSSL 3.0.13
# ... enabled"); 0.4.12-1.1ubuntu2 (noble-updates, 2026-11-10) dropped it, and an unpinned `apt-get
# install` took it the next run: every release signing died with exit 139, with no change in this
# repository. So the signing path takes this exact package, never whatever the archive has that day.
#
# Why the digest: the file is fetched over the network into a job that is about to hold the signing
# credentials, so it is checked against the committed SHA-256 before dpkg reads it, and nothing is
# installed if it does not match. That SHA-256 is the one in the archive's signed index
# (snapshot.ubuntu.com 20261109T000000Z, noble-updates InRelease, "Ubuntu Archive Automatic Signing
# Key (2018)", universe/binary-amd64/Packages.gz), and Launchpad's copy of the file has the same.
# The package is then held, so no later apt-get in the job can replace it, and its installed version
# is checked. Move the pin only to a version whose engine is known to sign on the runner's OpenSSL.
set -euo pipefail

version=0.4.12-1.1ubuntu1
url=https://snapshot.ubuntu.com/ubuntu/20261109T000000Z/pool/universe/libp/libp11/libengine-pkcs11-openssl_${version}_amd64.deb
sha256=d5a3106008c9ceec1b77fbd764ca66e03b8dd5ee14ab5529342cb847c0476baf

die() { echo "install-pkcs11-engine: $*" >&2; exit 1; }

[ "$#" -eq 0 ] || die "usage: sudo $0"
[ "$(id -u)" = 0 ] || die "run as root"
# shellcheck source=/dev/null
. /etc/os-release
[ "${VERSION_CODENAME:-}" = noble ] && [ "$(dpkg --print-architecture)" = amd64 ] ||
  die "the pinned package is for Ubuntu noble on amd64"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
deb="$tmp/engine.deb"
curl -fsSL --retry 3 -o "$deb" "$url" || die "download failed: $url"
echo "$sha256  $deb" | sha256sum -c --quiet - || die "the package does not match its pinned SHA-256"
dpkg -i "$deb" >/dev/null || die "dpkg could not install the package"
apt-mark hold libengine-pkcs11-openssl >/dev/null || die "cannot hold the package"
installed="$(dpkg-query -W -f='${Version} ${Status}' libengine-pkcs11-openssl)"
[ "$installed" = "$version hold ok installed" ] || die "installed: $installed, expected $version (held)"
echo "libengine-pkcs11-openssl $version installed and held (SHA-256 $sha256)"
