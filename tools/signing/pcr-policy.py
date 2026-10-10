#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The signed PCR 11 policy of the image's UKI (docs/BOOT.md, "TPM2 unlock").

ci/ukify.sh builds the UKI with the policy's public key (.pcrpkey) and, for the main profile only,
the PCR 11 policy digests to sign (.pcrsig, without signatures). Step 3 of ci/build-image.sh signs
them with the policy key and checks the result before the UKI is signed for Secure Boot.

    pcr-policy.py sign UKI PRIVATE_KEY        prints the .pcrsig JSON with the signatures added
                                              (for ukify build --join-pcrsig --pcrsig)
    pcr-policy.py check UKI PUBLIC_KEY        refuses the UKI unless:
      - .pcrpkey is PUBLIC_KEY;
      - exactly one .pcrsig, in the profile with ID=main (profile 0), none in another profile;
      - every policy in it: SHA-256 bank, PCR 11 only, no policy reference, the fingerprint of
        PUBLIC_KEY, a signature that verifies with PUBLIC_KEY;
      - the signed policies are exactly the PCR 11 policies of the main profile for systemd's four
        boot phases, computed here from the UKI's sections (independently of systemd-measure), and
        none of them is a policy of another profile.
"""
import base64
import hashlib
import json
import struct
import subprocess
import sys
import tempfile

import pefile

# The sections systemd-stub measures into PCR 11, in its order (.pcrsig is never measured).
MEASURED = [".linux", ".osrel", ".cmdline", ".initrd", ".ucode", ".splash", ".dtb", ".uname", ".sbat",
            ".pcrpkey", ".profile"]
# Sections the stub would also measure, which this UKI must not have (not modelled here).
UNEXPECTED = {".dtbauto", ".hwids", ".efifw"}
# systemd-measure's default phases (systemd-pcrphase): each starts again from the UKI's measurement.
PHASES = ["enter-initrd", "enter-initrd:leave-initrd", "enter-initrd:leave-initrd:sysinit",
          "enter-initrd:leave-initrd:sysinit:ready"]


class Refused(Exception):
    pass


def sections(path):
    """[(name, data)] in the order of the section table, which is the order systemd-stub reads them in
    (pefile sorts its list by address); data is what the stub measures (the section's virtual size)."""
    pe = pefile.PE(path, fast_load=True)
    return [(s.Name.rstrip(b"\0").decode("ascii"), s.get_data(length=min(s.Misc_VirtualSize, s.SizeOfRawData)))
            for s in sorted(pe.sections, key=lambda s: s.get_file_offset())]


def profiles(secs):
    """The base sections (before the first .profile), and each profile's sections (from its .profile)."""
    base, groups = [], []
    for name, data in secs:
        if name == ".profile":
            groups.append([])
        (groups[-1] if groups else base).append((name, data))
    return base, groups


def profile_id(group):
    text = group[0][1].decode("utf-8")
    ids = [line[3:] for line in text.splitlines() if line.startswith("ID=")]
    return ids[0] if len(ids) == 1 else None


def sha256(data):
    return hashlib.sha256(data).digest()


def extend(pcr, digest):
    return sha256(pcr + digest)


def pcr11(base, group):
    """PCR 11 (SHA-256) after booting one profile, for each boot phase."""
    effective = dict(base)
    effective.update(group)  # a profile's section replaces the base section of the same name
    if UNEXPECTED & effective.keys():
        raise Refused(f"sections not modelled here: {sorted(UNEXPECTED & effective.keys())}")
    pcr = bytes(32)
    for name in MEASURED:
        data = effective.get(name, b"")
        if data:  # the stub skips empty sections
            pcr = extend(pcr, sha256(name.encode() + b"\0"))
            pcr = extend(pcr, sha256(data))
    values = []
    for phase in PHASES:
        value = pcr
        for word in phase.split(":"):
            value = extend(value, sha256(word.encode()))
        values.append(value)
    return values


def policies(base, group):
    """The TPM2_PolicyPCR digests of one profile, for each boot phase: H(previous policy (zeros) ||
    TPM_CC_PolicyPCR || TPML_PCR_SELECTION (one SHA-256 bank, 0x000b, PCR 11 in a 3-byte bitmap) ||
    H(PCR 11))."""
    selection = struct.pack(">IHB3B", 1, 0x000B, 3, 0x00, 0x08, 0x00)
    return [sha256(bytes(32) + struct.pack(">I", 0x17F) + selection + sha256(v)).hex() for v in pcr11(base, group)]


def openssl(*args, data=None):
    return subprocess.run(["openssl", *args], input=data, capture_output=True, check=False)


def der(public_key_pem):
    with tempfile.NamedTemporaryFile() as f:
        f.write(public_key_pem)
        f.flush()
        r = openssl("pkey", "-pubin", "-in", f.name, "-outform", "DER")
    if r.returncode != 0 or not r.stdout:
        raise Refused("the public key does not parse")
    return r.stdout


def fingerprint(public_key):
    """systemd's key fingerprint in the policies: SHA-256 of i2d_PublicKey, for RSA the PKCS#1
    RSAPublicKey DER (not the SubjectPublicKeyInfo)."""
    r = openssl("rsa", "-pubin", "-in", public_key, "-RSAPublicKey_out", "-outform", "DER")
    if r.returncode != 0 or not r.stdout:
        raise Refused("the policy key is not an RSA public key")
    return hashlib.sha256(r.stdout).hexdigest()


def the_pcrsig(secs):
    found = [data for name, data in secs if name == ".pcrsig"]
    if len(found) != 1:
        raise Refused(f"{len(found)} .pcrsig sections, not 1")
    return json.loads(found[0].rstrip(b"\0 ").decode("utf-8"))


def sign(uki, private_key):
    pcrsig = the_pcrsig(sections(uki))
    for policy in pcrsig.get("sha256", []):
        r = openssl("dgst", "-sha256", "-sign", private_key, data=bytes.fromhex(policy["tbs"]))
        if r.returncode != 0:
            raise Refused(f"openssl could not sign: {r.stderr.decode(errors='replace')}")
        policy["sig"] = base64.b64encode(r.stdout).decode()
    print(json.dumps(pcrsig))


def check(uki, public_key):
    secs = sections(uki)
    with open(public_key, "rb") as f:
        key_der = der(f.read())
    keys = [data for name, data in secs if name == ".pcrpkey"]
    if len(keys) != 1 or der(keys[0]) != key_der:
        raise Refused(f".pcrpkey is not {public_key}")
    base, groups = profiles(secs)
    if not groups or profile_id(groups[0]) != "main":
        raise Refused("profile 0 is not the main profile (ID=main)")
    where = [profile_id(g) for g in groups if any(name == ".pcrsig" for name, _ in g)]
    if any(name == ".pcrsig" for name, _ in base) or where != ["main"]:
        raise Refused(f"the signed PCR policy is not in the main profile alone: base "
                      f"{any(name == '.pcrsig' for name, _ in base)}, profiles {where}")
    pcrsig = the_pcrsig(secs)
    if list(pcrsig) != ["sha256"]:
        raise Refused(f"banks {list(pcrsig)}, expected only sha256")
    fp = fingerprint(public_key)
    signed = []
    with tempfile.TemporaryDirectory() as tmp:
        for policy in pcrsig["sha256"]:
            if policy.get("pcrs") != [11] or "ref" in policy or policy.get("pkfp") != fp:
                raise Refused(f"policy not for PCR 11 alone with this key (fingerprint {fp}): {policy}")
            if policy.get("tbs", policy["pol"]) != policy["pol"]:
                raise Refused(f"the signed data is not the policy digest: {policy}")
            with open(f"{tmp}/sig", "wb") as f:
                f.write(base64.b64decode(policy.get("sig", ""), validate=True))
            r = openssl("dgst", "-sha256", "-verify", public_key, "-signature", f"{tmp}/sig",
                        data=bytes.fromhex(policy["pol"]))
            if r.returncode != 0:
                raise Refused(f"the signature of policy {policy['pol']} does not verify with {public_key}")
            signed.append(policy["pol"])
    main = policies(base, groups[0])
    if sorted(signed) != sorted(main):
        raise Refused(f"the signed policies are not the main profile's PCR 11 policies:\n"
                      f"  signed:   {sorted(signed)}\n  computed: {sorted(main)}")
    for g in groups[1:]:
        if set(policies(base, g)) & set(signed):
            raise Refused(f"a signed policy also matches profile {profile_id(g)}")
    print(f"pcr-policy: {uki}: PCR 11 policy signed for the main profile only ({len(signed)} phases), "
          f"profiles {[profile_id(g) for g in groups[1:]]} not covered; key {fp[:16]}")


def main():
    verb, uki, key = sys.argv[1:]
    try:
        {"sign": sign, "check": check}[verb](uki, key)
    except (Refused, OSError, ValueError, KeyError, pefile.PEFormatError) as e:
        print(f"pcr-policy: refused {uki}: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
