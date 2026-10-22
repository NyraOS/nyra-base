#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The package list of the installer ISO for the SBOM and the vulnerability scan (docs/ISO.md): the packages
# of the installer system, and those of the boot tree (iso/boot/mkosi.conf) whose files reach the ISO. The
# Debian security tracker knows GRUB and shim by their source packages, grub2 and shim, which the signed
# packages only cite (Built-Using): the unsigned ones, whose sources they are, are listed too. Exactly these
# five must be in the boot tree's manifest, once each; anything else fails, so that a change of the boot
# packages cannot take GRUB or shim out of the scan unnoticed.
#   ci/iso-manifest.sh OS_MANIFEST BOOT_MANIFEST OUT
#   ci/iso-manifest.sh --self-test
set -euo pipefail

boot_packages='["grub-efi-amd64-signed", "grub-efi-amd64-unsigned", "shim-helpers-amd64-signed", "shim-signed", "shim-unsigned"]'

merge() {
  local os="$1" boot="$2" out="$3"
  jq -e --argjson want "$boot_packages" '[.packages[].name | select(IN($want[]))] | sort == $want' "$boot" > /dev/null \
    || { echo "iso-manifest: the boot tree's manifest does not list exactly $boot_packages, once each" >&2; return 1; }
  jq -s --argjson want "$boot_packages" '.[0].packages += [.[1].packages[] | select(.name | IN($want[]))] | .[0]' "$os" "$boot" > "$out"
  echo "iso-manifest: $(jq '.packages | length' "$out") packages"
}

if [ "${1:-}" = --self-test ]; then
  d="$(mktemp -d)"
  trap 'rm -rf "$d"' EXIT
  pkg() { jq -cn --arg n "$1" '{name: $n, version: "1", architecture: "amd64"}'; }
  manifest() { # manifest NAME... : a manifest with these packages
    local list
    list="$(for n in "$@"; do pkg "$n"; done | jq -s .)"
    jq -n --argjson l "$list" '{config: {distribution: "debian"}, packages: $l}'
  }
  manifest systemd podman > "$d/os.json"
  manifest grub-efi-amd64-signed grub-efi-amd64-unsigned shim-helpers-amd64-signed shim-signed shim-unsigned grub2-common libfreetype6 > "$d/good.json"
  merge "$d/os.json" "$d/good.json" "$d/out.json" > /dev/null
  [ "$(jq -r '[.packages[].name] | sort | join(" ")' "$d/out.json")" = "grub-efi-amd64-signed grub-efi-amd64-unsigned podman shim-helpers-amd64-signed shim-signed shim-unsigned systemd" ] \
    || { echo "self-test: wrong merge" >&2; exit 1; }
  # Refused: one of the five missing (the source packages the tracker knows), one twice, and none.
  manifest grub-efi-amd64-signed shim-helpers-amd64-signed shim-signed grub2-common > "$d/no-sources.json"
  manifest grub-efi-amd64-signed grub-efi-amd64-unsigned shim-helpers-amd64-signed shim-signed shim-unsigned shim-signed > "$d/twice.json"
  manifest grub2-common > "$d/none.json"
  for bad in no-sources twice none; do
    if merge "$d/os.json" "$d/$bad.json" "$d/refused.json" 2> /dev/null; then echo "self-test: accepted $bad" >&2; exit 1; fi
  done
  echo "iso-manifest.sh self-test: ok"
  exit 0
fi
[ $# = 3 ] || { echo "usage: iso-manifest.sh OS_MANIFEST BOOT_MANIFEST OUT" >&2; exit 1; }
merge "$@"
