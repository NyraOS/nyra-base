#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Proves that the released image is the tested image plus a Secure Boot signature
# (docs/SIGNING.md, ci/build-image.sh: the last stage is FROM the sealed image + COPY of the signed UKI).
# TESTED and RELEASED are oci-archives (podman save --format oci-archive), UNSIGNED_UKI is the UKI the
# tested image was sealed with, before any signature. It refuses unless:
#   - both images have the same number of layers and all but the last have the same digests in their
#     manifests;
#   - the last layer of RELEASED holds only boot/EFI/Linux/<name>.efi (a regular file) and its parent
#     directories: no other file, link, device or whiteout;
#   - that UKI, with its signature removed (sbattach --remove, on a copy), is byte for byte UNSIGNED_UKI.
# The archives are read with python3 -I (tar and JSON from its standard library): no skopeo or podman
# is needed, and nothing in them is executed. Any other layout (an image index, a layer with a
# compression python cannot read, a blob that does not match its digest) is refused.
#   tools/signing/same-but-signature.sh TESTED_OCI_ARCHIVE RELEASED_OCI_ARCHIVE UNSIGNED_UKI
set -euo pipefail

[ $# -eq 3 ] || { echo "usage: $0 TESTED_OCI_ARCHIVE RELEASED_OCI_ARCHIVE UNSIGNED_UKI" >&2; exit 2; }
tested="$1" released="$2" unsigned="$3"
refuse() { echo "same-but-signature: refused: $*" >&2; exit 1; }
for f in "$tested" "$released" "$unsigned"; do [ -f "$f" ] || refuse "$f is not a file"; done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

oci() { python3 -I -c '
import gzip, hashlib, io, json, re, sys, tarfile

def refuse(msg):
    sys.exit("same-but-signature: refused: " + msg)

def blob(tar, digest):
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        refuse("unexpected digest " + repr(digest))
    try:
        member = tar.getmember("blobs/sha256/" + digest[7:])
    except KeyError:
        refuse("blob " + digest + " is not in the archive")
    if not member.isreg():
        refuse("blob " + digest + " is not a regular file")
    return member

def read(tar, digest):
    data = tar.extractfile(blob(tar, digest)).read()
    if "sha256:" + hashlib.sha256(data).hexdigest() != digest:
        refuse("blob " + digest + " does not match its digest")
    return data

def manifest(tar):
    try:
        index = json.load(tar.extractfile(tar.getmember("index.json")))
    except (KeyError, ValueError, AttributeError):
        refuse("no readable index.json: not an oci-archive")
    if len(index.get("manifests", [])) != 1:
        refuse("index.json must list exactly one image")
    entry = index["manifests"][0]
    if entry.get("mediaType") != "application/vnd.oci.image.manifest.v1+json":
        refuse("index.json does not point at an OCI image manifest")
    layers = json.loads(read(tar, entry["digest"]))["layers"]
    if not layers:
        refuse("the image has no layer")
    return [layer["digest"] for layer in layers]

def last_layer(tar, digest):
    data = read(tar, digest)
    if data[:2] == b"\x1f\x8b":
        data = gzip.decompress(data)
    try:
        return tarfile.open(fileobj=io.BytesIO(data))
    except tarfile.TarError:
        refuse("the last layer is not a tar (or gzip tar) archive")

cmd, archive = sys.argv[1], sys.argv[2]
with tarfile.open(archive) as tar:
    layers = manifest(tar)
    if cmd == "layers":
        print("\n".join(layers))
        sys.exit()
    # "uki": check the last layer holds only the UKI, and write it to sys.argv[3]
    names = {"boot", "boot/EFI", "boot/EFI/Linux"}
    ukis = []
    with last_layer(tar, layers[-1]) as layer:
        for member in layer:
            name = member.name.removeprefix("./").rstrip("/")
            if name in ("", ".", "/"):
                continue
            if member.isdir() and name in names:
                continue
            if member.isreg() and re.fullmatch(r"boot/EFI/Linux/[A-Za-z0-9._+-]+\.efi", name):
                ukis.append(member)
                continue
            refuse("the last layer holds " + repr(member.name) + "; only boot/EFI/Linux/<name>.efi is allowed")
        if len(ukis) != 1:
            refuse("the last layer must hold exactly one boot/EFI/Linux/<name>.efi, it holds %d" % len(ukis))
        with open(sys.argv[3], "wb") as out:
            out.write(layer.extractfile(ukis[0]).read())
' "$@"; }

oci layers "$tested" > "$work/tested.layers" || refuse "cannot read the layers of $tested"
oci layers "$released" > "$work/released.layers" || refuse "cannot read the layers of $released"

n="$(wc -l < "$work/tested.layers")"
[ "$n" -eq "$(wc -l < "$work/released.layers")" ] || refuse "the images do not have the same number of layers"
[ "$n" -ge 2 ] || refuse "an image with a single layer has no earlier layers to compare"
cmp -s <(head -n "$((n - 1))" "$work/tested.layers") <(head -n "$((n - 1))" "$work/released.layers") \
  || refuse "a layer before the last differs between the tested and the released image"

oci uki "$released" "$work/signed.efi" || refuse "cannot take the UKI from the last layer of $released"
sbattach --remove "$work/signed.efi" > /dev/null || refuse "sbattach could not remove the signature"
cmp -s "$work/signed.efi" "$unsigned" || refuse "the released UKI without its signature is not $unsigned"
echo "same-but-signature: ok: $n layers, the last holds only the UKI, and it is $unsigned plus a signature"
