#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Checks that an OCI layout directory, as `podman save --format oci-dir --uncompressed` writes it,
holds exactly the image with image ID ID (ci/pinned-images.sh): one manifest, its config is the blob
with digest ID, and every layer blob, byte for byte, has the sha256 of the config's DiffID at the same
position (so it must be stored uncompressed). Every blob it names is hashed. JSON with a key twice
(also when only the case differs: Go's decoder matches keys that way), a key that is not ASCII, or
a schemaVersion other than the number 2 is refused: podman reads the same manifest with Go, and it
must not read other layers than the ones checked here. podman 5 checks the DiffIDs itself when it reads an image; podman 4.9
does not.

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


def strict(pairs):
    """json object_pairs_hook: ASCII keys only (Go folds some other letters to ASCII ones, the long s
    to s), and no key twice, not even in another case."""
    keys = [k.lower() for k, _ in pairs]
    if not all(k.isascii() for k in keys) or len(set(keys)) != len(keys):
        raise ValueError(f"a key that is not ASCII or appears twice: {sorted(k for k, _ in pairs)!r}")
    return dict(pairs)


def parse(data):
    return json.loads(data, object_pairs_hook=strict)


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
        index = parse(f.read())
    manifests = index["manifests"]
    if len(manifests) != 1:
        raise ValueError(f"index.json lists {len(manifests)} manifests, not 1")
    manifest = parse(blob(d, manifests[0]["digest"]))
    for name, doc in ("index.json", index), ("the manifest", manifest):
        if type(doc["schemaVersion"]) is not int or doc["schemaVersion"] != 2:
            raise ValueError(f"{name} has schemaVersion {doc['schemaVersion']!r}, not 2")
    if manifest["config"]["digest"] != "sha256:" + image_id:
        raise ValueError(f"the config is {manifest['config']['digest']}, not sha256:{image_id}")
    diff_ids = parse(blob(d, manifest["config"]["digest"]))["rootfs"]["diff_ids"]
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

    def layout(d, layer, config_layer, manifest_extra="", index_extra="", version="2"):
        """A layout whose config names CONFIG_LAYER's DiffID and whose manifest has LAYER; the
        EXTRA texts are added to the manifest's and the index's JSON objects as they are."""
        os.makedirs(os.path.join(d, "blobs", "sha256"), exist_ok=True)
        cfg = json.dumps({"rootfs": {"type": "layers", "diff_ids": [put(d, config_layer)]}}).encode()
        manifest = (f'{{"schemaVersion": 2, "config": {{"digest": "{put(d, cfg)}"}}, '
                    f'"layers": [{{"digest": "{put(d, layer)}"}}]{manifest_extra}}}').encode()
        with open(os.path.join(d, "index.json"), "w") as f:
            f.write(f'{{"schemaVersion": {version}, "manifests": [{{"digest": "{put(d, manifest)}"}}]'
                    f'{index_extra}}}')
        return hashlib.sha256(cfg).hexdigest()

    def refused(d, image_id, want):
        try:
            verify(d, image_id)
        except ValueError as e:
            assert want in str(e), e
        else:
            raise AssertionError(f"{d} accepted")

    with tempfile.TemporaryDirectory() as t:
        good = os.path.join(t, "good")
        image_id = layout(good, b"layer", b"layer")
        verify(good, image_id)
        refused(good, "0" * 64, "the config is")
        changed = put(good, b"layer, changed")
        cases = [
            # One layer changed, the manifest names it, the config (the ID) is unchanged.
            ("changed", {"layer": b"layer, changed"}, "not the config's DiffID"),
            # The same key twice, in another case: a Go reader takes the last one.
            ("manifest", {"manifest_extra": f', "Layers": [{{"digest": "{changed}"}}]'}, "twice"),
            ("index", {"index_extra": ', "Manifests": []'}, "twice"),
            ("folded", {"manifest_extra": f', "layer\u017f": [{{"digest": "{changed}"}}]'}, "not ASCII"),
            ("version", {"version": '"2"'}, "schemaVersion '2'"),
        ]
        for name, kwargs, want in cases:
            d = os.path.join(t, name)
            assert layout(d, **{"layer": b"layer", "config_layer": b"layer", **kwargs}) == image_id
            refused(d, image_id, want)
        # A blob whose bytes do not match its name.
        with open(os.path.join(good, "blobs", "sha256", hashlib.sha256(b"layer").hexdigest()), "wb") as f:
            f.write(b"layer, changed")
        refused(good, image_id, "does not match its digest")
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
