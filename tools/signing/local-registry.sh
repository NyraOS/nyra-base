#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: starts a throwaway registry on 127.0.0.1:80 that answers as updates.nyraos.com
# (and as other.test, a stand-in for any other registry), so the signature policy is tested
# under the real public name. Nothing leaves the runner. Also writes a small image as an
# oci-archive (the registry image itself) for the tests: OUTPUT_DIR/tiny.oci.tar.
#   tools/signing/local-registry.sh OUTPUT_DIR
set -euo pipefail

# registry 3.0.0, pinned by digest and loaded by ci/pinned-images.sh (.github/actions/pinned-images).
registry=localhost/pinned/registry

# The runner's loopback has a 64 KiB MTU, so a TCP segment is up to 64 KiB. During a large upload
# (a 700 MB layer) the kernel can shrink the registry socket's receive buffer below that: the
# registry then offers a window smaller than one segment, the sender waits for a larger one (silly
# window avoidance) and the upload stalls for good (seen in CI: podman push hung, the sender in
# persist mode, rwnd-limited, the receiver's queue empty). With a 1500-byte MTU a segment always
# fits. The guests' traffic to the registry (QEMU user networking) uses the same loopback.
sudo ip link set dev lo mtu 1500
sudo podman run -d --pull=never --name nyra-test-registry --network host -e REGISTRY_HTTP_ADDR=127.0.0.1:80 "$registry" >/dev/null
echo '127.0.0.1 updates.nyraos.com other.test' | sudo tee -a /etc/hosts >/dev/null
for _ in $(seq 30); do curl -fs http://updates.nyraos.com/v2/ >/dev/null && break; sleep 1; done
curl -fsS http://updates.nyraos.com/v2/ >/dev/null

sudo podman save -q --format oci-archive -o "$1/tiny.oci.tar" "$registry"
sudo chown "$(id -u):$(id -g)" "$1/tiny.oci.tar"
