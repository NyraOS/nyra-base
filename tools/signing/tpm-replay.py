# SPDX-License-Identifier: GPL-3.0-or-later
"""Helpers for tools/signing/tpm-unlock.sh: the PCR 11 measurements of the image's UKI, replayed
into a software TPM so the signed disk-unlock policy can be tested (docs/BOOT.md, "TPM2 unlock").

systemd-stub measures the UKI's sections into PCR 11 before the kernel starts, and systemd-pcrextend
adds one word per boot phase (enter-initrd, then leave-initrd, sysinit, ready). This reproduces that
sequence of PCR 11 extensions, so a test can bring a software TPM to the state of any phase of any
profile. The section reading is pe_sections.py (as the stub reads them) and the PCR 11 algorithm is
pcr-policy.py's. The test anchors every state it replays: the PCR 11 the software TPM holds must equal
what the image's own systemd-measure calculates from the same sections (verb "sections").

    tpm-replay.py extends UKI PROFILE PHASE   the PCR 11 extension digests (hex, space separated), in
                                              order, to reach PROFILE (main|recovery|reset) at PHASE
                                              (enter-initrd|leave-initrd|sysinit|ready)
    tpm-replay.py sections UKI PROFILE DIR    write PROFILE's effective measured sections to DIR (one
                                              file per section, named without the dot) and print the
                                              systemd-measure calculate options for them
    tpm-replay.py phase PHASE                 PHASE as systemd-measure --phase takes it (a:b:c)
    tpm-replay.py extract UKI PUBKEY SIG      write the UKI's .pcrpkey and .pcrsig to these files
    tpm-replay.py forge UKI SIG_IN SIG_OUT    a forged signature JSON: the enter-initrd signature of
                                              SIG_IN copied onto the main profile's leave-initrd
                                              policy, to prove the TPM refuses it (a signature cannot
                                              be replayed to another phase)
"""
import hashlib
import json
import os
import struct
import sys

sys.dont_write_bytecode = True  # nothing written into the checkout
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pe_sections import sections  # noqa: E402

# The sections systemd-stub measures into PCR 11, in its order (pcr-policy.py MEASURED; .pcrsig is
# never measured).
MEASURED = [".linux", ".osrel", ".cmdline", ".initrd", ".ucode", ".splash", ".dtb", ".uname", ".sbat",
            ".pcrpkey", ".profile"]
# The boot phases in order. systemd-pcrextend measures only each phase's own word (the ExecStart and
# ExecStop lines of systemd-pcrphase*.service), and systemd-measure --phase=a:b:c does the same, one
# word at a time. The signed policy covers the first (enter-initrd); each later word leaves PCR 11 past
# the signed value.
WORDS = ["enter-initrd", "leave-initrd", "sysinit", "ready"]


def phase_words(phase):
    """The words measured up to and including PHASE."""
    return WORDS[:WORDS.index(phase) + 1]


def measure_phase(phase):
    """PHASE as systemd-measure's --phase takes it: the words so far, joined by ':'."""
    return ":".join(phase_words(phase))


def sha256(data):
    return hashlib.sha256(data).digest()


def profiles(secs):
    """The base sections (before the first .profile) and each profile's sections (from its .profile)."""
    base, groups = [], []
    for name, data in secs:
        if name == ".profile":
            groups.append([])
        (groups[-1] if groups else base).append((name, data))
    return base, groups


def profile_id(group):
    text = dict(group)[".profile"].decode("utf-8")
    ids = [line[3:] for line in text.splitlines() if line.startswith("ID=")]
    return ids[0] if len(ids) == 1 else None


def extend_digests(base, group, phase):
    """The PCR 11 extension digests, in order, for one profile up to and including PHASE: for each
    non-empty measured section H(name\\0) then H(data), then H(word) for each phase word."""
    effective = dict(base)
    effective.update(dict(group))
    out = []
    for name in MEASURED:
        data = effective.get(name, b"")
        if data:  # the stub skips empty sections
            out.append(sha256(name.encode() + b"\0").hex())
            out.append(sha256(data).hex())
    for word in phase_words(phase):
        out.append(sha256(word.encode()).hex())
    return out


def pcr11(base, group, phase):
    pcr = bytes(32)
    for digest in extend_digests(base, group, phase):
        pcr = sha256(pcr + bytes.fromhex(digest))
    return pcr


def policy_digest(base, group, phase):
    """The TPM2_PolicyPCR digest of a profile at PHASE (pcr-policy.py policy_digest): H(zeros ||
    TPM_CC_PolicyPCR || one SHA-256 bank, PCR 11 || H(PCR 11))."""
    selection = struct.pack(">IHB3B", 1, 0x000B, 3, 0x00, 0x08, 0x00)
    return sha256(bytes(32) + struct.pack(">I", 0x17F) + selection + sha256(pcr11(base, group, phase))).hex()


def group_of(groups, which):
    found = [g for g in groups if profile_id(g) == which]
    if len(found) != 1:
        raise SystemExit(f"tpm-replay: {len(found)} profiles with ID={which}")
    return found[0]


def main():
    verb = sys.argv[1]
    if verb == "phase":
        print(measure_phase(sys.argv[2]))
        return
    secs = sections(sys.argv[2])
    base, groups = profiles(secs)
    if verb == "extends":
        which, phase = sys.argv[3], sys.argv[4]
        print(" ".join(extend_digests(base, group_of(groups, which), phase)))
    elif verb == "sections":
        effective = dict(base)
        effective.update(dict(group_of(groups, sys.argv[3])))
        options = []
        for name in MEASURED:
            data = effective.get(name, b"")
            if data:
                path = os.path.join(sys.argv[4], name[1:])
                with open(path, "wb") as f:
                    f.write(data)
                options.append(f"--{name[1:]}={name[1:]}")
        print(" ".join(options))
    elif verb == "extract":
        pub = [d for n, d in secs if n == ".pcrpkey"]
        sig = [d for n, d in secs if n == ".pcrsig"]
        if len(pub) != 1 or len(sig) != 1:
            raise SystemExit(f"tpm-replay: {len(pub)} .pcrpkey and {len(sig)} .pcrsig, expected 1 each")
        with open(sys.argv[3], "wb") as f:
            f.write(pub[0])
        with open(sys.argv[4], "wb") as f:
            f.write(sig[0].rstrip(b"\0 "))
    elif verb == "forge":
        sig = json.load(open(sys.argv[3]))
        signed = [p for p in sig["sha256"] if "sig" in p]
        if len(signed) != 1:
            raise SystemExit(f"tpm-replay: {len(signed)} signed policies, expected 1")
        main_group = group_of(groups, "main")
        leave = policy_digest(base, main_group, "leave-initrd")
        ref_hash = hashlib.sha256(b"initrd").hexdigest()
        forged = {"pcrs": [11], "pkfp": signed[0]["pkfp"], "pol": leave, "ref": "initrd",
                  "tbs": leave + ref_hash, "sig": signed[0]["sig"]}
        with open(sys.argv[4], "w") as f:
            json.dump({"sha256": [forged]}, f)
    else:
        raise SystemExit(f"tpm-replay: unknown verb {verb}")


if __name__ == "__main__":
    main()
