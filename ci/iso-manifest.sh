#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The package list of the installer ISO for the SBOM and the vulnerability scan (docs/ISO.md): the packages
# of the installer system, and those of the boot tree (iso/boot/mkosi.conf) whose files reach the ISO. The
# Debian security tracker knows GRUB and shim by their source packages, grub2 and shim, which the signed
# packages only cite (Built-Using): the unsigned ones, whose sources they are, are listed too. Exactly these
# five must be in the boot tree's manifest, once each; anything else fails, so that a change of the boot
# packages cannot take GRUB or shim out of the scan unnoticed.
# ISO_ARCH (amd64, default, or arm64) names the architecture: the GRUB and shim-helpers packages are
# grub-efi-ARCH-signed, grub-efi-ARCH-unsigned and shim-helpers-ARCH-signed, and every package of both
# manifests is built for ARCH or for all.
#   ci/iso-manifest.sh OS_MANIFEST BOOT_MANIFEST OUT
#   ci/iso-manifest.sh --self-test
set -euo pipefail

arch="${ISO_ARCH:-amd64}"
[ "$arch" = amd64 ] || [ "$arch" = arm64 ] || { echo "iso-manifest: ISO_ARCH is amd64 or arm64, not $arch" >&2; exit 1; }
boot_packages_for() { # ARCH: the five packages, sorted
  jq -cn --arg a "$1" '["grub-efi-\($a)-signed", "grub-efi-\($a)-unsigned", "shim-helpers-\($a)-signed", "shim-signed", "shim-unsigned"] | sort'
}
boot_packages="$(boot_packages_for "$arch")"

merge() {
  local os="$1" boot="$2" out="$3"
  jq -es --arg arch "$arch" '[.[].packages[].architecture] | all(. == $arch or . == "all")' "$os" "$boot" > /dev/null \
    || { echo "iso-manifest: a package in the manifests is not built for $arch (or all)" >&2; return 1; }
  jq -e --argjson want "$boot_packages" '[.packages[].name | select(IN($want[]))] | sort == $want' "$boot" > /dev/null \
    || { echo "iso-manifest: the boot tree's manifest does not list exactly $boot_packages, once each" >&2; return 1; }
  jq -s --argjson want "$boot_packages" '.[0].packages += [.[1].packages[] | select(.name | IN($want[]))] | .[0]' "$os" "$boot" > "$out"
  echo "iso-manifest: $(jq '.packages | length' "$out") packages"
}

if [ "${1:-}" = --self-test ]; then
  d="$(mktemp -d)"
  trap 'rm -rf "$d"' EXIT
  for arch in amd64 arm64; do
    boot_packages="$(boot_packages_for "$arch")"
    other=arm64
    [ "$arch" = amd64 ] || other=amd64
    pkg() { jq -cn --arg n "$1" --arg a "${2:-$arch}" '{name: $n, version: "1", architecture: $a}'; }
    manifest() { # manifest NAME... : a manifest with these packages
      local list
      list="$(for n in "$@"; do pkg "$n"; done | jq -s .)"
      jq -n --argjson l "$list" '{config: {distribution: "debian"}, packages: $l}'
    }
    manifest systemd podman > "$d/os.json"
    manifest "grub-efi-$arch-signed" "grub-efi-$arch-unsigned" "shim-helpers-$arch-signed" shim-signed shim-unsigned grub2-common libfreetype6 > "$d/good.json"
    merge "$d/os.json" "$d/good.json" "$d/out.json" > /dev/null
    [ "$(jq -r '[.packages[].name] | sort | join(" ")' "$d/out.json")" = "grub-efi-$arch-signed grub-efi-$arch-unsigned podman shim-helpers-$arch-signed shim-signed shim-unsigned systemd" ] \
      || { echo "self-test: wrong merge ($arch)" >&2; exit 1; }
    # Refused: one of the five missing (the source packages the tracker knows), one twice, none, the other
    # architecture's GRUB, and a package built for the other architecture.
    manifest "grub-efi-$arch-signed" "shim-helpers-$arch-signed" shim-signed grub2-common > "$d/no-sources.json"
    manifest "grub-efi-$arch-signed" "grub-efi-$arch-unsigned" "shim-helpers-$arch-signed" shim-signed shim-unsigned shim-signed > "$d/twice.json"
    manifest grub2-common > "$d/none.json"
    manifest "grub-efi-$other-signed" "grub-efi-$other-unsigned" "shim-helpers-$other-signed" shim-signed shim-unsigned > "$d/other-arch-names.json"
    { pkg systemd; pkg podman "$other"; } | jq -s '{packages: .}' > "$d/os-other.json"
    for bad in no-sources twice none other-arch-names; do
      if merge "$d/os.json" "$d/$bad.json" "$d/refused.json" 2> /dev/null; then echo "self-test: accepted $bad ($arch)" >&2; exit 1; fi
    done
    if merge "$d/os-other.json" "$d/good.json" "$d/refused.json" 2> /dev/null; then echo "self-test: accepted a package of the other architecture ($arch)" >&2; exit 1; fi
  done
  echo "iso-manifest.sh self-test: ok"
  exit 0
fi
[ $# = 3 ] || { echo "usage: iso-manifest.sh OS_MANIFEST BOOT_MANIFEST OUT" >&2; exit 1; }
merge "$@"
