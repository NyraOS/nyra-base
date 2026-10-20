#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Reads back what bootc recorded for the deployment it installed under ROOT (the mounted target
# filesystem) and fails unless it is exactly IMGREF and DIGEST: the reference the machine updates
# from, and the manifest digest of the image it was made from (docs/BOOT.md). The record is the
# origin file of the deployment, state/deploy/<id>/<id>.origin (bootc's composefs backend).
#   tools/install/check-recorded.sh ROOT IMGREF DIGEST
set -euo pipefail

root="$1" imgref="$2" digest="$3"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "check-recorded: not a sha256 digest: $digest" >&2; exit 1; }

origins=("$root"/state/deploy/*/*.origin)
[ "${#origins[@]}" = 1 ] && [ -f "${origins[0]}" ] || {
  echo "check-recorded: expected one deployment under $root/state/deploy, found ${#origins[@]}" >&2
  exit 1
}
cat "${origins[0]}"

# The INI keys, as bootc writes them: container-image-reference (with its transport prefix) in
# [origin], manifest_digest in [image].
recorded="$(sed -n 's/^container-image-reference *= *//p' "${origins[0]}")"
[[ "$recorded" =~ ^ostree-unverified-(image:docker://|registry:)"$imgref"$ ]] || {
  echo "check-recorded: bootc recorded the reference \"$recorded\", not $imgref: reinstall the disk" >&2
  exit 1
}
[ "$(sed -n 's/^manifest_digest *= *//p' "${origins[0]}")" = "$digest" ] || {
  echo "check-recorded: bootc recorded another manifest digest than $digest: reinstall the disk" >&2
  exit 1
}
echo "check-recorded: $imgref, $digest"
