#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: a UKI add-on (extra kernel command line) for the test disks, built with ukify from the
# image's add-on stub (addonx64.efi.stub, addonaa64.efi.stub on aarch64: the image is built for the
# runner's architecture); signed when KEY and CERT are given. Never part of the image.
#   tools/vm/test-addon.sh IMAGE OUT.addon.efi CMDLINE [KEY CERT]
set -euo pipefail

image="$1" out="$2" cmdline="$3" key="${4:-}" cert="${5:-}"
case "$(uname -m)" in
x86_64) stub=addonx64.efi.stub ;;
aarch64) stub=addonaa64.efi.stub ;;
*) echo "test-addon.sh: no add-on stub for $(uname -m)" >&2; exit 1 ;;
esac
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cid="$(sudo podman create -q "$image")"
sudo podman cp "$cid:/usr/lib/systemd/boot/efi/$stub" "$tmp/"
sudo podman rm -f "$cid" >/dev/null
sudo chown -R "$(id -u):$(id -g)" "$tmp"
sign=()
if [ -n "$key" ]; then sign=(--secureboot-private-key "$key" --secureboot-certificate "$cert"); fi
ukify build --stub "$tmp/$stub" --cmdline "$cmdline" --output "$out" "${sign[@]}"
