#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: starts a throwaway registry on 127.0.0.1:80 that answers as updates.nyraos.com
# (and as other.test, a stand-in for any other registry), so the signature policy is tested
# under the real public name. Nothing leaves the runner. Also writes a small image as an
# oci-archive (the registry image itself) for the tests: OUTPUT_DIR/tiny.oci.tar.
#   tools/signing/local-registry.sh OUTPUT_DIR
set -euo pipefail

# registry 3.0.0, the Docker official image through Amazon ECR Public's mirror of the official images (the
# same digest; Docker Hub limits unauthenticated pulls per runner IP).
registry=public.ecr.aws/docker/library/registry@sha256:6c5666b861f3505b116bb9aa9b25175e71210414bd010d92035ff64018f9457e

sudo podman run -d --name nyra-test-registry --network host -e REGISTRY_HTTP_ADDR=127.0.0.1:80 "$registry" >/dev/null
echo '127.0.0.1 updates.nyraos.com other.test' | sudo tee -a /etc/hosts >/dev/null
for _ in $(seq 30); do curl -fs http://updates.nyraos.com/v2/ >/dev/null && break; sleep 1; done
curl -fsS http://updates.nyraos.com/v2/ >/dev/null

sudo podman save -q --format oci-archive -o "$1/tiny.oci.tar" "$registry"
sudo chown "$(id -u):$(id -g)" "$1/tiny.oci.tar"
