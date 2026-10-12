#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Checks that an OCI layout directory (`podman save --format oci-dir --uncompressed`) holds exactly
the image with image ID ID, before podman loads it (ci/pinned-images.sh): one manifest, its config is
the blob with digest ID, and every layer blob, byte for byte, has the sha256 of the config's DiffID at
the same position (so it must be stored uncompressed). Nothing in the directory is trusted: every blob
it names is hashed. podman 5 checks the DiffIDs itself when it loads; podman 4.9 does not.

  verify-oci.py DIR ID
  verify-oci.py --self-test
"""
import hashlib
import json
import os
import re
import sys
import tempfile

DIGEST = re.compile(r"sha256:[0-9a-f]{64}")


def blob(d, digest):
    """The bytes of the blob DIGEST, checked against its digest."""
    if not isinstance(digest, str) or not DIGEST.fullmatch(digest):
        raise ValueError(f"not a sha256 digest: {digest!r}")
    with open(os.path.join(d, "blobs", "sha256", digest[7:]), "rb") as f:
        data = f.read()
    if "sha256:" + hashlib.sha256(data).hexdigest() != digest:
        raise ValueError(f"blob {digest} does not match its digest")
    return data


def verify(d, image_id):
    with open(os.path.join(d, "index.json"), "rb") as f:
        manifests = json.load(f)["manifests"]
    if len(manifests) != 1:
        raise ValueError(f"index.json lists {len(manifests)} manifests, not 1")
    manifest = json.loads(blob(d, manifests[0]["digest"]))
    if manifest["config"]["digest"] != "sha256:" + image_id:
        raise ValueError(f"the config is {manifest['config']['digest']}, not sha256:{image_id}")
    diff_ids = json.loads(blob(d, manifest["config"]["digest"]))["rootfs"]["diff_ids"]
    layers = manifest["layers"]
    if len(layers) != len(diff_ids):
        raise ValueError(f"{len(layers)} layers but {len(diff_ids)} DiffIDs in the config")
    for i, (layer, diff_id) in enumerate(zip(layers, diff_ids)):
        if layer["digest"] != diff_id:
            raise ValueError(f"layer {i} is {layer['digest']}, not the config's DiffID {diff_id}")
        blob(d, layer["digest"])


def self_test():
    def put(d, data):
        digest = "sha256:" + hashlib.sha256(data).hexdigest()
        with open(os.path.join(d, "blobs", "sha256", digest[7:]), "wb") as f:
            f.write(data)
        return digest

    def layout(d, layer, config_layer):
        """A layout whose config names CONFIG_LAYER's DiffID and whose manifest has LAYER."""
        os.makedirs(os.path.join(d, "blobs", "sha256"), exist_ok=True)
        cfg = json.dumps({"rootfs": {"type": "layers", "diff_ids": [put(d, config_layer)]}}).encode()
        manifest = json.dumps({"schemaVersion": 2, "config": {"digest": put(d, cfg)},
                               "layers": [{"digest": put(d, layer)}]}).encode()
        with open(os.path.join(d, "index.json"), "w") as f:
            json.dump({"schemaVersion": 2, "manifests": [{"digest": put(d, manifest)}]}, f)
        return hashlib.sha256(cfg).hexdigest()

    with tempfile.TemporaryDirectory() as t:
        good = os.path.join(t, "good")
        image_id = layout(good, b"layer", b"layer")
        verify(good, image_id)
        # The control: one layer changed, the manifest updated to it, the config (the ID) unchanged.
        bad = os.path.join(t, "bad")
        assert layout(bad, b"layer, changed", b"layer") == image_id
        for d, i, want in [(bad, image_id, "not the config's DiffID"), (good, "0" * 64, "the config is")]:
            try:
                verify(d, i)
            except ValueError as e:
                assert want in str(e), e
            else:
                raise AssertionError(f"{d} accepted for {i}")
        # A blob whose bytes do not match its name.
        with open(os.path.join(good, "blobs", "sha256", hashlib.sha256(b"layer").hexdigest()), "wb") as f:
            f.write(b"layer, changed")
        try:
            verify(good, image_id)
        except ValueError as e:
            assert "does not match its digest" in str(e), e
        else:
            raise AssertionError("a changed blob was accepted")
    print("verify-oci.py self-test: ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    elif len(sys.argv) == 3:
        try:
            verify(sys.argv[1], sys.argv[2])
        except (OSError, KeyError, TypeError, ValueError) as e:
            sys.exit(f"::error::{sys.argv[1]} is not image {sys.argv[2]}: {e}")
    else:
        sys.exit(__doc__)
