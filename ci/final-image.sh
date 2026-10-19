#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The final image (step 4 of ci/build-image.sh): the last stage of the Containerfile, FROM the sealed
# image + COPY of the signed UKI into /boot/EFI/Linux. The one place that builds it, for
# ci/build-image.sh and for any job that signs the UKI later, so the two cannot differ. Every
# flag that reaches the image (--timestamp, the version, the options after TAG: annotations and labels) is here
# or in the caller's options, never in a second copy.
# SOURCE_DATE_EPOCH is required; VERSION (default dev) is passed as NYRA_VERSION as in every other
# build of a run. The stages before the last are not built, so the root filesystem, the crates and
# the next PCR policy key are not needed.
#   VERSION=... SOURCE_DATE_EPOCH=... ci/final-image.sh SEALED_IMAGE SIGNED_UKI_DIR TAG [podman build options...]
set -euo pipefail

sealed="$1" signed="$2" tag="$3"
shift 3
# --pull=never: only the local sealed image is used, nothing is fetched by this build.
sudo podman build --pull=never --timestamp "$SOURCE_DATE_EPOCH" --build-arg NYRA_VERSION="${VERSION:-dev}" "$@" \
  --build-arg SEALED="$sealed" --build-context uki="$signed" -t "$tag" -f Containerfile .
