#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The signed PCR 11 policy of the image's UKI (docs/BOOT.md, "TPM2 unlock").

The disk unlocks in the initrd only: the one policy signed is the main profile's PCR 11 in the
enter-initrd phase, with the policy reference "initrd" (the enrollment requires it). ci/ukify.sh builds
the UKI with the policy's public key (.pcrpkey) and, for the main profile only, the digests to sign
(.pcrsig, without signatures): that policy (ukify --sign-initrd-pcrs), and the four boot phases
without a reference, which ukify always adds and which are never signed. Step 3 of
ci/build-image.sh signs it with the policy key and checks the result before the UKI is signed for
Secure Boot. The sections are read as systemd-stub reads and measures them (pe_sections.py).

    pcr-policy.py sign UKI PRIVATE_KEY   computes the policy from the UKI's sections (independently
                                         of systemd-measure) and signs that, never data read from
                                         .pcrsig; refuses unless the UKI passes the checks below that
                                         come before signing, carries no signature yet, and its
                                         .pcrsig asks for exactly that policy (no other with a
                                         reference). Prints the signature as .pcrsig JSON, for
                                         ukify build --join-pcrsig --pcrsig.
    pcr-policy.py sign-kms UKI PUBLIC_KEY PKCS11_URI
                                         the same as sign, with the committed PUBLIC_KEY, and the key in
                                         the KMS signs (openssl dgst -engine pkcs11, see
                                         .github/workflows/image.yml). Before anything else, and before
                                         openssl runs, UKI (one regular file, no symlink) is copied into a
                                         private directory and the copy must pass uki-check.py with the
                                         sealed command line ci/uki-cmdline.txt and no signature: the
                                         artifact is not trusted, and the signature is for that copy's
                                         policy. Both verbs verify the signature
                                         with the public key before printing it, and print nothing if it
                                         does not verify (the signer is not the key of .pcrpkey).
    pcr-policy.py check UKI PUBLIC_KEY   refuses the UKI unless:
      - .pcrpkey is PUBLIC_KEY;
      - exactly one .pcrsig, in the profile with ID=main (profile 0), none in another profile;
      - only the SHA-256 bank; every policy in it for PCR 11 alone, with the fingerprint of
        PUBLIC_KEY, no policy reference other than "initrd", and its data to sign (tbs) what the TPM
        checks for its digest and reference;
      - the main profile's enter-initrd policy, computed here, is no other profile's;
      - exactly one policy signed: that one, with the reference "initrd", and its signature verifies
        with PUBLIC_KEY over the data computed here. A signature for any other phase or profile, or
        without the reference, is refused.
"""
import base64
import hashlib
import json
import os
import shutil
import stat
import struct
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True  # nothing written into the checkout
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pefile  # noqa: E402
from pe_sections import Refused, sections  # noqa: E402

# The sections systemd-stub measures into PCR 11, in its order (.pcrsig is never measured).
MEASURED = [".linux", ".osrel", ".cmdline", ".initrd", ".ucode", ".splash", ".dtb", ".uname", ".sbat",
            ".pcrpkey", ".profile"]
# Sections the stub would also measure, which this UKI must not have (not modelled here).
UNEXPECTED = {".dtbauto", ".hwids", ".efifw"}
# The one phase signed (systemd-pcrphase measures it into PCR 11 when the initrd starts, and
# leave-initrd when it ends), and the policy reference the enrollment requires
# (systemd-cryptenroll --tpm2-public-key-policyref=initrd).
PHASE = "enter-initrd"
REF = "initrd"


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
    """PCR 11 (SHA-256) in the enter-initrd phase after booting one profile."""
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
    return extend(pcr, sha256(PHASE.encode()))


def policy_digest(base, group):
    """The TPM2_PolicyPCR digest of one profile in the enter-initrd phase: H(previous policy (zeros)
    || TPM_CC_PolicyPCR || TPML_PCR_SELECTION (one SHA-256 bank, 0x000b, PCR 11 in a 3-byte bitmap)
    || H(PCR 11))."""
    selection = struct.pack(">IHB3B", 1, 0x000B, 3, 0x00, 0x08, 0x00)
    return sha256(bytes(32) + struct.pack(">I", 0x17F) + selection + sha256(pcr11(base, group))).hex()


def to_sign(pol, ref):
    """The data the key signs for TPM2_PolicyAuthorize (hex): the policy digest, then the policy
    reference as systemd passes it to the TPM, its SHA-256 (nothing without a reference)."""
    return pol + (sha256(ref.encode()).hex() if ref else "")


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


def verified(uki, public_key, key_name=None):
    """The checks of both verbs that need no signature. Returns the .pcrsig JSON, the key's
    fingerprint and the main profile's enter-initrd policy digest, computed from the sections."""
    secs = sections(uki)
    with open(public_key, "rb") as f:
        key_der = der(f.read())
    keys = [data for name, data in secs if name == ".pcrpkey"]
    if len(keys) != 1 or der(keys[0]) != key_der:
        raise Refused(f".pcrpkey is not {key_name or public_key}")
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
    for policy in pcrsig["sha256"]:
        if policy.get("pcrs") != [11] or policy.get("pkfp") != fp or policy.get("ref", REF) != REF:
            raise Refused(f"policy not for PCR 11 alone with this key (fingerprint {fp}) and the reference "
                          f"{REF!r} or none: {policy}")
        data = to_sign(policy["pol"], policy.get("ref"))
        if policy.get("tbs", data) != data:
            raise Refused(f"the data to sign is not the policy digest and its reference: {policy}")
    main = policy_digest(base, groups[0])
    for g in groups[1:]:
        if policy_digest(base, g) == main:
            raise Refused(f"the main profile's policy is also the policy of profile {profile_id(g)}")
    return pcrsig, fp, main


def signature_verifies(public_key, signature, data):
    with tempfile.NamedTemporaryFile() as f:
        f.write(signature)
        f.flush()
        return openssl("dgst", "-sha256", "-verify", public_key, "-signature", f.name, data=data).returncode == 0


def sign_with(uki, public_key, key_name, command):
    """The checks and the signature of both signing verbs; they differ only in the command that
    signs standard input (a list) and in where the public key comes from."""
    pcrsig, fp, main = verified(uki, public_key, key_name)
    if any("sig" in policy for policy in pcrsig["sha256"]):
        raise Refused("the UKI already carries PCR policy signatures")
    want = {"pcrs": [11], "pkfp": fp, "pol": main, "ref": REF, "tbs": to_sign(main, REF)}
    asked = [policy for policy in pcrsig["sha256"] if "ref" in policy]
    if asked != [want]:
        raise Refused(f"the UKI does not ask for exactly the main profile's {PHASE} policy computed here; "
                      f"nothing signed:\n  asked:    {asked}\n  computed: {want}")
    # The data computed here is signed, never the file's.
    data = bytes.fromhex(to_sign(main, REF))
    r = subprocess.run(command, input=data, capture_output=True, check=False)
    if r.returncode != 0:
        raise Refused(f"could not sign: {r.stderr.decode(errors='replace')}")
    # A signer that is not the key of .pcrpkey (a wrong key version in the KMS) must not get as far as
    # the UKI: the TPM would refuse the policy at every boot.
    if not signature_verifies(public_key, r.stdout, data):
        raise Refused(f"the signature does not verify with {key_name or public_key}; nothing signed")
    print(json.dumps({"sha256": [dict(want, sig=base64.b64encode(r.stdout).decode())]}))


def sign(uki, private_key):
    with tempfile.NamedTemporaryFile() as public_key:
        if openssl("pkey", "-in", private_key, "-pubout", "-out", public_key.name).returncode != 0:
            raise Refused(f"cannot read the private key {private_key}")
        sign_with(uki, public_key.name, f"the public half of {private_key}",
                  ["openssl", "dgst", "-sha256", "-sign", private_key])


def sealed_copy(uki, directory):
    """Copies the one regular file UKI (no symlink, no directory, read once) into DIRECTORY and
    refuses it unless it is the sealed UKI with no signature yet (uki-check.py, called as
    sign-uki.sh calls it). The KMS signs for that copy only: the artifact comes from a job that runs
    network and image code, so nothing in it is trusted before this."""
    try:
        fd = os.open(uki, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as e:
        raise Refused(f"cannot open {uki} (a symlink is refused): {e}") from e
    with os.fdopen(fd, "rb") as src:
        if not stat.S_ISREG(os.fstat(src.fileno()).st_mode):
            raise Refused(f"{uki} is not a regular file")
        copy = os.path.join(directory, "uki.efi")
        with open(copy, "wb") as dst:
            shutil.copyfileobj(src, dst)
    tools = os.path.dirname(os.path.abspath(__file__))
    r = subprocess.run([sys.executable, "-I", os.path.join(tools, "uki-check.py"), copy,
                        os.path.join(tools, "..", "..", "ci", "uki-cmdline.txt"), "0"],
                       capture_output=True, check=False)
    if r.returncode != 0:
        raise Refused(f"not the sealed UKI without a signature:\n{r.stderr.decode(errors='replace')}")
    return copy


def sign_kms(uki, public_key, pkcs11_uri):
    with tempfile.TemporaryDirectory() as directory:  # private (0700), removed at exit
        copy = sealed_copy(uki, directory)
        # The flags of the KMS dry run in .github/workflows/image.yml.
        sign_with(copy, public_key, None, ["openssl", "dgst", "-sha256", "-engine", "pkcs11",
                                           "-keyform", "engine", "-sign", pkcs11_uri])


def check(uki, public_key):
    pcrsig, fp, main = verified(uki, public_key)
    signed = [policy for policy in pcrsig["sha256"] if "sig" in policy]
    if [(policy["pol"], policy.get("ref")) for policy in signed] != [(main, REF)]:
        raise Refused(f"the signed policies are not exactly the main profile's {PHASE} policy with the "
                      f"reference {REF!r}:\n  signed:   {[(p['pol'], p.get('ref')) for p in signed]}\n"
                      f"  computed: {[(main, REF)]}")
    if not signature_verifies(public_key, base64.b64decode(signed[0]["sig"], validate=True),
                              bytes.fromhex(to_sign(main, REF))):
        raise Refused(f"the signature of policy {main} does not verify with {public_key}")
    print(f"pcr-policy: {uki}: PCR 11 policy signed for the main profile's {PHASE} phase only "
          f"(reference {REF!r}); key {fp[:16]}")


# verb: (function, number of arguments after the UKI)
VERBS = {"sign": (sign, 1), "sign-kms": (sign_kms, 2), "check": (check, 1)}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in VERBS or len(sys.argv) != 3 + VERBS[sys.argv[1]][1]:
        sys.exit(__doc__)
    verb, uki, *args = sys.argv[1:]
    try:
        VERBS[verb][0](uki, *args)
    except (Refused, OSError, ValueError, KeyError, TypeError, pefile.PEFormatError) as e:
        print(f"pcr-policy: refused {uki}: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
