#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""CI only: does the Secure Boot request that the installer queued ask for the password it showed?

`mokutil --import --hash-file` writes two firmware variables: MokNew (the key) and MokAuth, which MokManager
compares with what is typed on the blue screen. If MokAuth held the hash of another password than the one on
the screen, the person would be locked out there. tools/iso/install-test.py reads MokAuth from the firmware's
variables after the install and asks matches() whether the password read from the console (without the dash,
as it is typed) is the one it holds.

MokAuth is mokutil's pw_crypt_t, packed, little endian: method (2 bytes, 4 is SHA-512 crypt), rounds (8),
salt size (2), salt (32 bytes of text), hash (128 bytes, of which the first 64 are the SHA-512 digest). The
digest is the one that `openssl passwd -6` prints, written in crypt's base 64 with its byte order. matches()
makes that hash again with openssl, from the salt in MokAuth, and compares the digests.

    mokauth.py --self-test        a request made by mokutil's own code, then the same with other passwords
"""
import struct
import subprocess
import sys

B64 = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
SHA512_CRYPT, ROUNDS, SIZE = 4, 5000, 172


def digest_of(crypt_hash):
    """The 64 bytes of the 86 characters at the end of a $6$ hash (the order of mokutil's password-crypt.c)."""
    text = crypt_hash.rsplit("$", 1)[1]
    out = bytearray(64)
    for n in range(21):
        high = n * 22 % 63
        value = sum(B64.index(c) << (6 * i) for i, c in enumerate(text[4 * n:4 * n + 4]))
        out[(high + 42) % 63] = value & 0xFF
        out[(high + 21) % 63] = (value >> 8) & 0xFF
        out[high] = (value >> 16) & 0xFF
    out[63] = ((B64.index(text[85]) << 6) | B64.index(text[84])) & 0xFF
    return bytes(out)


def matches(auth_hex, password):
    """True when the MokAuth variable (hex, as virt-fw-vars prints it) is the hash of password."""
    raw = bytes.fromhex(auth_hex)
    if len(raw) != SIZE:
        return False
    method, rounds, salt_size = struct.unpack("<HQH", raw[:12])
    if method != SHA512_CRYPT or rounds != ROUNDS or salt_size > 32:
        return False
    salt = raw[12:12 + salt_size].decode("ascii")
    again = subprocess.run(["openssl", "passwd", "-6", "-stdin", "-salt", salt], input=password + "\n",
                           capture_output=True, text=True, check=True).stdout.strip()
    return digest_of(again) == raw[44:108]


def self_test():
    # Made by the code of mokutil (password-crypt.c, decode_pass) for the password abcdefghjk and the salt
    # Zx1q9LmN4rTb2vYc, as `mokutil --import --hash-file` stores it.
    auth = ("0400881300000000000010005a783171394c6d4e347254623276596300000000000000000000000000000000"
            "f04a988e854dc641810336e7f7baac2129651942ce7f2deb5c29163825ded764344660680ec0d7de69dfb880"
            "31c8c3109100ff1b48497de6561704baa60f1253" + "00" * 64)
    assert matches(auth, "abcdefghjk"), "the password of the request was not accepted"
    # The mutations: another password, the password with its dash, one wrong byte in the hash, a short request.
    assert not matches(auth, "abcdefghjm"), "another password was accepted"
    assert not matches(auth, "abcde-fghjk"), "the password with its dash was accepted"
    flipped = auth[:100] + ("0" if auth[100] != "0" else "1") + auth[101:]
    assert not matches(flipped, "abcdefghjk"), "a changed hash was accepted"
    assert not matches(auth[:-2], "abcdefghjk"), "a short request was accepted"
    print("mokauth.py self-test: ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    else:
        sys.exit("usage: mokauth.py --self-test")
