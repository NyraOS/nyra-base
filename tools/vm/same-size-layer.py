#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""CI only (tools/vm/updates.sh): a valid gzip'd tar layer with other content and exactly the same
size as LAYER, so that only a check of the layer's digest against the manifest can refuse it.

The tar is LAYER's with OLD replaced by NEW (same length; tar headers carry no checksum of the
content), deflated again and padded to LAYER's size with a gzip comment (FCOMMENT).
  same-size-layer.py LAYER OLD NEW OUTPUT
"""
import gzip
import struct
import sys
import zlib

layer, old, new, output = sys.argv[1], sys.argv[2].encode(), sys.argv[3].encode(), sys.argv[4]
original = open(layer, "rb").read()
tar = gzip.decompress(original)
if len(old) != len(new) or tar.count(old) != 1:
    sys.exit(f"{old!r} must occur once in the layer and have the length of {new!r}")
tar = tar.replace(old, new)
trailer = struct.pack("<II", zlib.crc32(tar), len(tar) & 0xFFFFFFFF)
for level in range(9, 0, -1):
    for strategy in (zlib.Z_DEFAULT_STRATEGY, zlib.Z_FILTERED, zlib.Z_RLE):
        c = zlib.compressobj(level, zlib.DEFLATED, -15, 9, strategy)
        body = c.compress(tar) + c.flush()
        pad = len(original) - (10 + len(body) + len(trailer))
        if pad >= 0:  # FCOMMENT pads: pad - 1 bytes of comment and its terminating zero
            flags, comment = (b"\x10", b"x" * (pad - 1) + b"\x00") if pad else (b"\x00", b"")
            header = b"\x1f\x8b\x08" + flags + b"\x00\x00\x00\x00\x00\xff" + comment
            out = header + body + trailer
            assert len(out) == len(original) and gzip.decompress(out) == tar and out != original
            open(output, "wb").write(out)
            sys.exit(0)
sys.exit(f"no deflate setting fits in {len(original)} bytes")
