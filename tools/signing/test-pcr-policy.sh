#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: tests tools/signing/pcr-policy.py (docs/BOOT.md, "TPM2 unlock") on a UKI that ci/ukify.sh
# builds exactly as step 2 of ci/build-image.sh does, from SEALED (the committed root filesystem,
# "<tag>-sealed") and KERNEL_DIR, but with a policy key made here:
#   - accepted: sign, join with the image's ukify, check (the control); the signature is byte for byte
#     the one systemd-measure itself makes for the main profile's enter-initrd phase with the reference
#     "initrd", so the policy computed here, independently, is systemd's;
#   - sign refuses, and prints no signature, for: a key that is not .pcrpkey; a .pcrsig asking for a
#     later phase under the reference; a measured section changed after ukify (the digest in .pcrsig is
#     no longer the UKI's); a UKI that already carries signatures;
#   - check refuses, each .pcrsig signed with the key made here: a later phase signed as well as
#     enter-initrd, a later phase only, enter-initrd without the reference, the policy twice, PCRs 7 and
#     11, a SHA-1 bank, another reference, data to sign that is not the policy and its reference,
#     another key's fingerprint, a signature by another key.
# The keys are made here, live only in WORKDIR on the ephemeral runner and are deleted at the end:
# never commit or upload them, never use a real key here.
#   tools/signing/test-pcr-policy.sh SEALED KERNEL_DIR WORKDIR
set -euo pipefail

sealed="$1" kernel="$2" work="$3"
t="$work/pcr-policy-test"
mkdir -p "$t/pcr" "$t/out"
trap 'sudo rm -rf "$t"' EXIT
policy() { python3 -I tools/signing/pcr-policy.py "$@"; }
# refused REASON VERB UKI KEY: pcr-policy.py must fail, for REASON (an extended regular expression),
# and print nothing on standard output (no signature).
refused() {
  local reason="$1" out
  shift
  if out="$(policy "$@" 2>"$t/err")"; then
    echo "::error::pcr-policy.py accepted $* (expected: refused, $reason)"
    exit 1
  fi
  cat "$t/err"
  [ -z "$out" ] || { echo "::error::pcr-policy.py $1 printed output while refusing: $out"; exit 1; }
  grep -Eq "$reason" "$t/err" || { echo "::error::pcr-policy.py refused $*, but not for: $reason"; exit 1; }
  echo "refused as expected: $*"
}
image() { sudo podman run --rm --network none --tmpfs /tmp --tmpfs /var/tmp "$@"; }

for k in pcr other; do
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$t/$k.key" 2>/dev/null
done
openssl pkey -in "$t/pcr.key" -pubout -out "$t/pcr/tpm2-pcr-public-key.pem"
pub="$t/pcr/tpm2-pcr-public-key.pem"
image --mount "type=image,source=$sealed,target=/target" -v "$kernel:/kernel:ro" -v "$t/pcr:/pcr:ro" \
  -v "$t/out:/out" -v "$PWD/ci/ukify.sh:/ukify.sh:ro" "$sealed" sh /ukify.sh >/dev/null
sudo chown -R "$(id -u):$(id -g)" "$t"
mv "$t"/out/*.efi "$t/unsigned.efi"

# The control: signed, joined and checked as in ci/build-image.sh.
policy sign "$t/unsigned.efi" "$t/pcr.key" > "$t/pcrsig.json"
image -v "$t:/t" "$sealed" ukify build --join-pcrsig /t/unsigned.efi --pcrsig @/t/pcrsig.json --output /t/signed.efi
sudo chown -R "$(id -u):$(id -g)" "$t"
policy check "$t/signed.efi" "$pub"

# systemd-measure signs the main profile's sections (as the stub measures them) for the enter-initrd
# phase with the reference "initrd": the same policy and the same signature (PKCS#1 v1.5 is
# deterministic).
mkdir "$t/main"
python3 -I - "$t/unsigned.efi" "$t/main" > "$t/measure-args" <<'PY'
import sys
sys.path.insert(0, "tools/signing")
from pe_sections import sections
uki, out = sys.argv[1:]
base, groups = [], []
for name, data in sections(uki):
    if name == ".profile":
        groups.append([])
    (groups[-1] if groups else base).append((name, data))
main = dict(base)
main.update(groups[0])
for name in (".linux", ".osrel", ".cmdline", ".initrd", ".uname", ".sbat", ".pcrpkey", ".profile"):
    open(f"{out}/{name[1:]}", "wb").write(main[name])
    print(f"--{name[1:]}=/t/main/{name[1:]}")
PY
mapfile -t args < "$t/measure-args"
image -v "$t:/t" "$sealed" /usr/lib/systemd/systemd-measure sign "${args[@]}" --bank=sha256 \
  --phase=enter-initrd --policyref=initrd --private-key=/t/pcr.key --public-key=/t/pcr/tpm2-pcr-public-key.pem \
  --json=short > "$t/measure.json"
python3 -I - "$t/measure.json" "$t/pcrsig.json" <<'PY'
import json
import sys
measure, ours = (json.load(open(f))["sha256"] for f in sys.argv[1:])
assert len(measure) == 1 and len(ours) == 1, (measure, ours)
for field in ("pcrs", "pkfp", "pol", "ref", "sig"):
    assert measure[0][field] == ours[0][field], (field, measure[0], ours[0])
print(f"systemd-measure signs the same policy, with the same signature: {ours[0]['pol']}")
PY

# Variants: the UKI's .pcrsig replaced (it is not measured, and ukify left room in it), the other
# sections unchanged; policies signed with the key made here (or the other one).
python3 -I - "$t/unsigned.efi" "$t/signed.efi" "$t" <<'PY'
import base64
import hashlib
import json
import struct
import subprocess
import sys
import pefile
unsigned, signed, out = sys.argv[1:]

def load(path):
    data = open(path, "rb").read()
    pe = pefile.PE(data=data, fast_load=True)
    sec = next(s for s in pe.sections if s.Name.split(b"\0")[0] == b".pcrsig")
    raw = data[sec.PointerToRawData:sec.PointerToRawData + sec.Misc_VirtualSize]
    return data, sec, json.loads(raw.rstrip(b"\0 "))["sha256"]

def write(name, src, policies, extra=None):
    data, sec, _ = src
    text = json.dumps(dict({"sha256": policies}, **(extra or {}))).encode()
    assert len(text) <= sec.SizeOfRawData
    p = bytearray(data)
    p[sec.PointerToRawData:sec.PointerToRawData + sec.SizeOfRawData] = text + bytes(sec.SizeOfRawData - len(text))
    struct.pack_into("<I", p, sec.get_file_offset() + 8, len(text))
    open(f"{out}/{name}.efi", "wb").write(p)

def sign(policy, key="pcr"):
    sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", f"{out}/{key}.key"],
                         input=bytes.fromhex(policy["tbs"]), capture_output=True, check=True).stdout
    return dict(policy, sig=base64.b64encode(sig).decode())

def initrd(policy, ref="initrd"):
    """The same policy with a reference: the data to sign is the digest, then the reference's SHA-256."""
    return dict(policy, ref=ref, tbs=policy["pol"] + hashlib.sha256(ref.encode()).hexdigest())

u, s = load(unsigned), load(signed)
entries = s[2]
good = [p for p in entries if "sig" in p]
plain = [p for p in entries if "ref" not in p]
assert len(entries) == 5 and len(good) == 1 and len(plain) == 4, entries
good = good[0]
unsigned_plain = [p for p in plain if p["pol"] == good["pol"]]
later = [p for p in plain if p["pol"] != good["pol"]]
assert len(unsigned_plain) == 1 and len(later) == 3, entries

# For sign: the policy under the reference replaced by a later phase's.
write("sign-later", u, plain + [initrd(later[0])])
# For sign: one byte of the .osrel section changed (it is measured into PCR 11).
data, _, _ = u
pe = pefile.PE(data=data, fast_load=True)
osrel = next(x for x in pe.sections if x.Name.split(b"\0")[0] == b".osrel")
p = bytearray(data)
p[osrel.PointerToRawData] ^= 1
open(f"{out}/sign-osrel.efi", "wb").write(p)

# For check.
write("later-too", s, entries + [sign(initrd(later[0]))])
write("later-only", s, plain + [sign(initrd(later[0]))])
write("noref", s, later + [sign(unsigned_plain[0]), {k: v for k, v in good.items() if k != "sig"}])
write("twice", s, entries + [good])
write("pcrs", s, plain + [dict(good, pcrs=[7, 11])])
write("sha1", s, entries, {"sha1": [good]})
write("otherref", s, plain + [sign(initrd(good, "other"))])
write("tbs", s, plain + [sign(dict(good, tbs=good["pol"]))])
write("pkfp", s, plain + [dict(good, pkfp="00" * 32)])
write("othersig", s, plain + [sign(good, "other")])
PY

refused "\\.pcrpkey is not" sign "$t/unsigned.efi" "$t/other.key"
refused "does not ask for exactly the main profile's enter-initrd policy" sign "$t/sign-later.efi" "$t/pcr.key"
refused "does not ask for exactly the main profile's enter-initrd policy" sign "$t/sign-osrel.efi" "$t/pcr.key"
refused "already carries PCR policy signatures" sign "$t/signed.efi" "$t/pcr.key"

refused "signed policies are not exactly" check "$t/later-too.efi" "$pub"
refused "signed policies are not exactly" check "$t/later-only.efi" "$pub"
refused "signed policies are not exactly" check "$t/noref.efi" "$pub"
refused "signed policies are not exactly" check "$t/twice.efi" "$pub"
refused "policy not for PCR 11 alone" check "$t/pcrs.efi" "$pub"
refused "banks \\['sha256', 'sha1'\\]" check "$t/sha1.efi" "$pub"
refused "policy not for PCR 11 alone .* the reference 'initrd' or none" check "$t/otherref.efi" "$pub"
refused "the data to sign is not the policy digest and its reference" check "$t/tbs.efi" "$pub"
refused "policy not for PCR 11 alone" check "$t/pkfp.efi" "$pub"
refused "does not verify" check "$t/othersig.efi" "$pub"

echo "pcr-policy.py passed all checks."
