#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Fails when any layer of an OCI archive (podman save --format oci-archive) holds an SSH host key
file (a path whose last part starts with ssh_host_): a later layer that removes it only adds a
whiteout, and whoever pulls the image still gets the file (docs/DEFAULTS.md, "SSH"). Every layer of
every manifest is read, compressed or not (gzip, zstd through the zstd command).

  no-host-keys.py ARCHIVE...
  no-host-keys.py --self-test
"""
import gzip
import io
import json
import os
import re
import subprocess
import sys
import tarfile
import tempfile

KEY = re.compile(r"(^|/)ssh_host_[^/]*$")


def layer_names(blob, media_type):
    """Every member name of one layer blob (a file object)."""
    if media_type.endswith("+zstd"):
        out = subprocess.run(["zstd", "-dc"], stdin=blob, capture_output=True, check=True).stdout
        blob = io.BytesIO(out)
    with tarfile.open(fileobj=blob, mode="r|*") as layer:
        for member in layer:
            yield member.name


def host_keys(path):
    """The (layer digest, path) of every host key file in the OCI archive at PATH."""
    found = []
    with tarfile.open(path) as archive:
        def read(name):
            return archive.extractfile(name).read()

        def blob_name(digest):
            algo, _, hexdigest = digest.partition(":")
            return f"blobs/{algo}/{hexdigest}"

        index = json.loads(read("index.json"))
        if not index["manifests"]:
            raise ValueError(f"{path}: no manifest")
        for m in index["manifests"]:
            manifest = json.loads(read(blob_name(m["digest"])))
            if not manifest["layers"]:
                raise ValueError(f"{path}: a manifest without layers")
            for layer in manifest["layers"]:
                with archive.extractfile(blob_name(layer["digest"])) as blob:
                    for name in layer_names(blob, layer.get("mediaType", "")):
                        if KEY.search(name.rstrip("/")):
                            found.append((layer["digest"], name))
    return found


def self_test():
    with tempfile.TemporaryDirectory() as d:
        def tar(members):
            """An uncompressed tar with these (name, bytes) files."""
            buf = io.BytesIO()
            with tarfile.open(fileobj=buf, mode="w") as t:
                for name, data in members:
                    info = tarfile.TarInfo(name)
                    info.size = len(data)
                    t.addfile(info, io.BytesIO(data))
            return buf.getvalue()

        def archive(name, layers, gz=False):
            blobs, entries = {}, []
            for i, members in enumerate(layers):
                data = gzip.compress(tar(members)) if gz else tar(members)
                digest = f"sha256:{i:064x}"
                blobs[digest] = data
                entries.append({"mediaType": "application/vnd.oci.image.layer.v1.tar" + ("+gzip" if gz else ""),
                                "digest": digest})
            manifest = json.dumps({"schemaVersion": 2, "layers": entries}).encode()
            blobs["sha256:" + "f" * 64] = manifest
            index = json.dumps({"schemaVersion": 2, "manifests": [{"digest": "sha256:" + "f" * 64}]}).encode()
            path = os.path.join(d, name)
            files = [("index.json", index)] + [(f"blobs/sha256/{k[7:]}", v) for k, v in blobs.items()]
            with open(path, "wb") as f:
                f.write(tar(files))
            return path

        clean = [[("etc/ssh/sshd_config", b"x"), ("usr/sbin/sshd", b"x")], [("etc/ssh/.wh.ssh_host_rsa_key", b"")]]
        hidden = [[("etc/ssh/ssh_host_ed25519_key", b"k"), ("etc/ssh/ssh_host_ed25519_key.pub", b"p")],
                  [("etc/ssh/.wh.ssh_host_ed25519_key", b""), ("etc/ssh/.wh.ssh_host_ed25519_key.pub", b"")]]
        assert host_keys(archive("clean.tar", clean)) == [], "a whiteout is not a key"
        assert host_keys(archive("clean-gz.tar", clean, gz=True)) == []
        for name, gz in ("hidden.tar", False), ("hidden-gz.tar", True):
            found = host_keys(archive(name, hidden, gz))
            assert [n for _, n in found] == ["etc/ssh/ssh_host_ed25519_key", "etc/ssh/ssh_host_ed25519_key.pub"], found
            assert {dg for dg, _ in found} == {f"sha256:{0:064x}"}, "the first layer, though the second removes it"
    print("no-host-keys.py: self-test passed")


def main(args):
    if args == ["--self-test"]:
        self_test()
        return 0
    if not args:
        sys.exit(__doc__)
    bad = 0
    for path in args:
        found = host_keys(path)
        for digest, name in found:
            print(f"::error::{path}: layer {digest} holds {name}")
        bad |= bool(found)
        if not found:
            print(f"{path}: no SSH host key in any layer")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
