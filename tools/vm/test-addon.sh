#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: a UKI add-on (extra kernel command line) for the test disks, built with ukify from the
# image's add-on stub; signed when KEY and CERT are given. Never part of the image.
#   tools/vm/test-addon.sh IMAGE OUT.addon.efi CMDLINE [KEY CERT]
set -euo pipefail

image="$1" out="$2" cmdline="$3" key="${4:-}" cert="${5:-}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cid="$(sudo podman create -q "$image")"
sudo podman cp "$cid:/usr/lib/systemd/boot/efi/addonx64.efi.stub" "$tmp/"
sudo podman rm -f "$cid" >/dev/null
sudo chown -R "$(id -u):$(id -g)" "$tmp"
sign=()
if [ -n "$key" ]; then sign=(--secureboot-private-key "$key" --secureboot-certificate "$cert"); fi
ukify build --stub "$tmp/addonx64.efi.stub" --cmdline "$cmdline" --output "$out" "${sign[@]}"
