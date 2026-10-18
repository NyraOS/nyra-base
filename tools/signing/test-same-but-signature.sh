#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Offline test of tools/signing/same-but-signature.sh: tiny oci-archives are built here with python3's
# tar and json modules (no podman, no skopeo, no root), and sbattach is a stub on PATH (it removes the
# "SIGNATURE" the test appends to a UKI), so the test does not need sbsigntool and does not prove that
# the real sbattach --remove gives back the unsigned bytes: CI's release path has to show that.
# Accepted: the released image that is the tested one with another last layer holding the UKI plus
# a signature (the last layer gzip-compressed too). Refused: an earlier layer that differs, a layer
# missing, an extra file, a link, a second UKI or a whiteout in the last layer, a UKI outside
# boot/EFI/Linux, a UKI whose unsigned bytes differ, an unsigned UKI, an image index, and a blob that
# does not match its digest.
#   tools/signing/test-same-but-signature.sh
set -euo pipefail

check="$(dirname "$(readlink -f "$0")")/same-but-signature.sh"
t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT
mkdir "$t/bin"
cat > "$t/bin/sbattach" <<'STUB'
#!/bin/bash
[ "$1" = --remove ] && [ "$(tail -c 9 "$2")" = SIGNATURE ] || exit 1
head -c -9 "$2" > "$2.tmp" && mv "$2.tmp" "$2"
STUB
chmod +x "$t/bin/sbattach"
export PATH="$t/bin:$PATH"

# image.py ARCHIVE LAYER...: an oci-archive whose layers are the LAYER arguments, each
# "NAME=CONTENT,NAME=CONTENT" (a name ending in / is a directory, "gz:" first compresses the layer,
# "NAME->TARGET" a symlink, "NAME=hardlink:TARGET" a hard link); "index" as the only layer makes an image
# index, a "bad:" prefix makes a blob that does not match its digest.
cat > "$t/image.py" <<'PY'
import gzip, hashlib, io, json, sys, tarfile

def digest(data):
    return "sha256:" + hashlib.sha256(data).hexdigest()

def layer(spec):
    spec = spec.removeprefix("bad:")
    gz = spec.startswith("gz:")
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tar:
        for item in filter(None, spec.removeprefix("gz:").split(",")):
            info = tarfile.TarInfo()
            if "->" in item:
                info.name, info.linkname = item.split("->")
                info.type = tarfile.SYMTYPE
                tar.addfile(info)
                continue
            name, _, content = item.partition("=")
            info.name = name
            if name.endswith("/"):
                info.type = tarfile.DIRTYPE
                tar.addfile(info)
            elif content.startswith("hardlink:"):
                info.type, info.linkname = tarfile.LNKTYPE, content[9:]
                tar.addfile(info)
            else:
                info.size = len(content.encode())
                tar.addfile(info, io.BytesIO(content.encode()))
    data = buf.getvalue()
    return gzip.compress(data) if gz else data

archive, specs = sys.argv[1], sys.argv[2:]
blobs = {}
def add(data, bad=False):
    blobs[digest(data)] = b"corrupt" if bad else data
    return digest(data)

layers = [{"mediaType": "application/vnd.oci.image.layer.v1.tar", "size": 0,
           "digest": add(layer(s), bad=s.startswith("bad:"))} for s in specs
          if s != "index"]
manifest = {"schemaVersion": 2, "layers": layers}
media = "application/vnd.oci.image.manifest.v1+json"
if specs == ["index"]:
    media = "application/vnd.oci.image.index.v1+json"
index = {"schemaVersion": 2, "manifests": [{"mediaType": media, "size": 0,
                                           "digest": add(json.dumps(manifest).encode())}]}
with tarfile.open(archive, "w") as tar:
    def put(name, data):
        info = tarfile.TarInfo(name)
        info.size = len(data)
        tar.addfile(info, io.BytesIO(data))
    put("index.json", json.dumps(index).encode())
    for d, data in blobs.items():
        put("blobs/sha256/" + d[7:], data)
PY
image() { python3 -I "$t/image.py" "$@"; }

uki=boot/EFI/Linux/nyra.efi
dirs=boot/,boot/EFI/,boot/EFI/Linux/
printf 'UKI-BYTES' > "$t/unsigned.efi"
base1='etc/os-release=nyra'
base2='usr/bin/tool=binary'
image "$t/tested.tar" "$base1" "$base2" "$dirs,$uki=UKI-BYTES-OTHER-KEY"

accepted() {
  local name="$1" out
  shift
  out="$("$check" "$@" 2>&1)" || { echo "$out"; echo "::error::$name: refused, expected: accepted"; exit 1; }
  echo "ok: $name"
}
# refused NAME REASON ARGS...: must fail, with REASON (an extended regular expression) in the message.
refused() {
  local name="$1" reason="$2" out
  shift 2
  if out="$("$check" "$@" 2>&1)"; then
    echo "$out"; echo "::error::$name: accepted, expected: refused"; exit 1
  fi
  grep -Eq "refused: .*($reason)" <<< "$out" || { echo "$out"; echo "::error::$name: refused for another reason than: $reason"; exit 1; }
  echo "ok: $name refused"
}
# released NAME LAYER...: the released archive $t/NAME.tar; it differs from the tested one as the layers say.
released() { local n="$1"; shift; image "$t/$n.tar" "$@"; }

released good "$base1" "$base2" "$dirs,$uki=UKI-BYTESSIGNATURE"
accepted "the tested image plus a signature" "$t/tested.tar" "$t/good.tar" "$t/unsigned.efi"
released goodgz "$base1" "$base2" "gz:$dirs,$uki=UKI-BYTESSIGNATURE"
accepted "a gzip-compressed last layer" "$t/tested.tar" "$t/goodgz.tar" "$t/unsigned.efi"
released nodirs "$base1" "$base2" "$uki=UKI-BYTESSIGNATURE"
accepted "a last layer without its directory entries" "$t/tested.tar" "$t/nodirs.tar" "$t/unsigned.efi"

released early "$base1" 'usr/bin/tool=changed' "$dirs,$uki=UKI-BYTESSIGNATURE"
refused "a changed earlier layer" "layer before the last differs" "$t/tested.tar" "$t/early.tar" "$t/unsigned.efi"
released short "$base2" "$dirs,$uki=UKI-BYTESSIGNATURE"
refused "a missing layer" "same number of layers" "$t/tested.tar" "$t/short.tar" "$t/unsigned.efi"
released extra "$base1" "$base2" "$dirs,$uki=UKI-BYTESSIGNATURE,etc/passwd=x"
refused "an extra file in the last layer" "etc/passwd" "$t/tested.tar" "$t/extra.tar" "$t/unsigned.efi"
released addon "$base1" "$base2" "$dirs,$uki=UKI-BYTESSIGNATURE,boot/EFI/Linux/addon.efi=SIGNATURE"
refused "a second UKI in the last layer" "exactly one" "$t/tested.tar" "$t/addon.tar" "$t/unsigned.efi"
released extradir "$base1" "$base2" "$dirs,$uki=UKI-BYTESSIGNATURE,boot/EFI/Linux/nyra.efi.extra.d/"
refused "an extra directory in the last layer" "extra.d" "$t/tested.tar" "$t/extradir.tar" "$t/unsigned.efi"
released link "$base1" "$base2" "$dirs,$uki=UKI-BYTESSIGNATURE,boot/EFI/Linux/b.efi->/etc/shadow"
refused "a symlink in the last layer" "b.efi" "$t/tested.tar" "$t/link.tar" "$t/unsigned.efi"
released hard "$base1" "$base2" "$dirs,$uki=UKI-BYTESSIGNATURE,boot/EFI/Linux/b.efi=hardlink:$uki"
refused "a hard link in the last layer" "b.efi" "$t/tested.tar" "$t/hard.tar" "$t/unsigned.efi"
released whiteout "$base1" "$base2" "$dirs,$uki=UKI-BYTESSIGNATURE,usr/bin/.wh.tool="
refused "a whiteout in the last layer" "wh.tool" "$t/tested.tar" "$t/whiteout.tar" "$t/unsigned.efi"
released elsewhere "$base1" "$base2" "usr/,usr/lib/,usr/lib/nyra.efi=UKI-BYTESSIGNATURE"
refused "a UKI outside boot/EFI/Linux" "holds .usr." "$t/tested.tar" "$t/elsewhere.tar" "$t/unsigned.efi"
released noefi "$base1" "$base2" "$dirs"
refused "a last layer without a UKI" "exactly one" "$t/tested.tar" "$t/noefi.tar" "$t/unsigned.efi"
released changed "$base1" "$base2" "$dirs,$uki=OTHER-BYTESSIGNATURE"
refused "a UKI whose unsigned bytes differ" "is not" "$t/tested.tar" "$t/changed.tar" "$t/unsigned.efi"
released unsigned "$base1" "$base2" "$dirs,$uki=UKI-BYTES"
refused "an unsigned UKI" "sbattach" "$t/tested.tar" "$t/unsigned.tar" "$t/unsigned.efi"
image "$t/index.tar" index
refused "an image index" "cannot read the layers|OCI image manifest" "$t/tested.tar" "$t/index.tar" "$t/unsigned.efi"
image "$t/badblob.tar" "$base1" "$base2" "bad:$dirs,$uki=UKI-BYTESSIGNATURE"
refused "a blob that does not match its digest" "does not match" "$t/tested.tar" "$t/badblob.tar" "$t/unsigned.efi"
refused "a file that is not an archive" "cannot read the layers" "$t/tested.tar" "$t/unsigned.efi" "$t/unsigned.efi"
echo "same-but-signature: all tests passed"
