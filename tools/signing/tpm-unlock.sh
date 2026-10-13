#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: the signed PCR 11 policy unlocks the disk in the initrd and nowhere else (docs/BOOT.md,
# "TPM2 unlock"). A software TPM (swtpm) stands in for a machine's TPM; the image's
# own systemd 262 does the enrolling and unsealing, so this tests the real tools, not a model.
#
# No VM and no KVM: systemd-stub measures the UKI's sections into PCR 11 and systemd-pcrextend adds
# the boot phases. tpm-replay.py reproduces that exact sequence (the stub's section reading is
# pe_sections.py, the PCR 11 algorithm is pcr-policy.py's), so each boot state is reached by
# replaying it into swtpm, from a power-on (PCR 11 = 0) each time. A real power-cycle resets the
# PCRs while the TPM's seed and storage root key persist in its state, exactly as between two boots
# of a machine: swtpm is restarted on the same state directory for every state.
#
# A throwaway LUKS2 disk is enrolled against the UKI's own policy public key (.pcrpkey) and signature
# (.pcrsig), with the documented binding:
#   systemd-cryptenroll --tpm2-public-key-pcrs=11 --tpm2-public-key-policyref=initrd --tpm2-pcrs=7+12
# The disk's key is random, generated here and deleted at the end; nothing secret is printed. The
# test then checks, for each boot state, whether the TPM releases (unseals) the key:
#   main profile, enter-initrd            -> unseals     (the disk unlocks in the initrd)
#   main profile, leave-initrd / sysinit / ready -> refused (no unlock on the running system)
#   recovery profile / reset profile      -> refused     (their PCR 11 is not in the signed policy)
#   an add-on measured into PCR 12        -> refused     (PCR 12 binds "no add-ons")
#   an enrollment without the reference   -> refused     (no signature in the JSON without "initrd";
#                                                       the TPM checks pol || H("initrd") anyway)
#   the enter-initrd signature on the next phase's policy (forged) -> refused by the TPM
# "Unseals" means systemd-cryptsetup reaches "Completed TPM2 key unsealing": the key was released.
# (Activating the device-mapper target afterwards needs no TPM and is not part of this check.)
# No NvPCR: the image and the initramfs ship no NvPCR definitions, so no NV index is ever allocated
# (docs/DEFAULTS.md, "No NvPCRs").
#
# Every replayed state is anchored: after the replay, the PCR 11 that swtpm holds must equal what the
# image's systemd-measure calculates from the same sections for that phase, or the test fails. Every
# row is bound to its reason: the unlock row must show the key unsealed over an encrypted (HMAC)
# session, and each refusal must show the message that says why (one line of it is printed per row).
#
# Requires swtpm and python3-pefile on the runner, and the image loaded as IMAGE; the image's tools
# run with --network host so they reach swtpm on 127.0.0.1 (its default port, 2321).
#   tools/signing/tpm-unlock.sh IMAGE WORKDIR LOGDIR SUMMARY
set -euo pipefail

image="$1" work="$2" logs="$3" summary="$4"
t="$work/tpm-unlock"
swpid=""
dev="swtpm:host=127.0.0.1"
mkdir -p "$t"
# swtpm's state lives in LOGDIR (the runner's temporary directory), owned by this user: Ubuntu's
# AppArmor profile for swtpm lets it write only under the user's home and /tmp, not in WORKDIR.
state="$(mktemp -d "$logs/swtpm-state.XXXXXX")"
# The key, the disk and the TPM state are deleted whatever happens (the image's containers run as
# root, so the files they wrote need sudo); swtpm is stopped first.
trap '[ -z "$swpid" ] || kill "$swpid" 2>/dev/null || true; sudo rm -rf "$t" "$state"' EXIT

uki="$t/uki.efi"
cid="$(sudo podman create -q "$image")"
sudo podman cp "$cid:/boot/EFI/Linux" "$t/Linux"
sudo podman rm -f "$cid" >/dev/null
sudo chown -R "$(id -u):$(id -g)" "$t/Linux"
ukis=("$t"/Linux/*.efi)
test "${#ukis[@]}" = 1
cp "${ukis[0]}" "$uki"

# The UKI's policy public key and signature, the forged signature, and each profile's measured
# sections for systemd-measure (read as the stub reads them, pe_sections.py).
python3 tools/signing/tpm-replay.py extract "$uki" "$t/pcrpkey.pem" "$t/pcrsig.json"
python3 tools/signing/tpm-replay.py forge "$uki" "$t/pcrsig.json" "$t/forged.json"
for p in main recovery reset; do
  mkdir -p "$t/sec-$p"
  python3 tools/signing/tpm-replay.py sections "$uki" "$p" "$t/sec-$p" > "$t/sec-$p.options"
done

# A random key for this throwaway disk, never printed. The user-facing password and recovery-key
# fallback is a property of a real encrypted boot (left for the encryption work), not of this
# policy test.
( umask 077; head -c 32 /dev/urandom | base64 > "$t/key" )

power_cycle() { # restart swtpm on the same state: PCR 11 back to 0, the seed and SRK kept
  if [ -n "$swpid" ]; then kill "$swpid" 2>/dev/null || true; wait "$swpid" 2>/dev/null || true; fi
  swtpm socket --tpm2 --tpmstate "dir=$state" --server type=tcp,port=2321 --ctrl type=tcp,port=2322 \
    --flags not-need-init,startup-clear &
  swpid=$!
  # It must be listening before any tpm2 command, or the state would be silently wrong.

  for _ in $(seq 50); do
    if ! kill -0 "$swpid" 2>/dev/null; then echo "::error::tpm-unlock: swtpm exited at start"; exit 1; fi
    if (exec 3<>/dev/tcp/127.0.0.1/2321) 2>/dev/null; then return 0; fi
    sleep 0.2
  done
  echo "::error::tpm-unlock: swtpm is not listening on 127.0.0.1:2321 after 10 s"; exit 1
}

run() { # the image's tools, reaching swtpm on the host
  sudo podman run --rm --network host -v "$t:/w:z" "$image" bash -c "set -euo pipefail; $1"
}

# Replay a boot state into swtpm: PCR 11 of PROFILE at PHASE, anchored to systemd-measure, and PCR 7
# and 12 at fixed test values (ADDON=1 extends PCR 12 once more, as an add-on would).
replay() { # replay PROFILE PHASE [ADDON]
  local digests phase addon=""
  digests="$(python3 tools/signing/tpm-replay.py extends "$uki" "$1" "$2")"
  phase="$(python3 tools/signing/tpm-replay.py phase "$2")"
  if [ "${3:-}" = 1 ]; then addon='tpm2_pcrextend 12:sha256=$(printf addon | sha256sum | cut -c1-64)'; fi
  run "export TPM2TOOLS_TCTI=$dev
    for h in $digests; do tpm2_pcrextend 11:sha256=\$h; done
    tpm2_pcrextend 7:sha256=\$(printf s7 | sha256sum | cut -c1-64) 12:sha256=\$(printf s12 | sha256sum | cut -c1-64)
    ${addon:-true}
    got=\$(tpm2_pcrread sha256:11 | sed -n 's/^ *11 *: 0x//p' | tr 'A-F' 'a-f')
    want=\$(cd /w/sec-$1 && /usr/lib/systemd/systemd-measure calculate --bank=sha256 --phase=$phase \
      \$(cat /w/sec-$1.options) --json=short | sed -n 's/.*\"hash\":\"\\([0-9a-f]*\\)\".*/\\1/p')
    if [ -z \"\$want\" ] || [ \"\$got\" != \"\$want\" ]; then
      echo \"::error::tpm-unlock: replayed PCR 11 of $1 at $phase is \$got, systemd-measure says \$want\"; exit 1
    fi
    echo \"tpm-unlock: PCR 11 of $1 at $phase anchored to systemd-measure: \${got:0:16}…\""
}

# Enroll a throwaway disk at the main profile's enter-initrd, with the documented binding.
enroll() { # enroll DISK REF(yes|no)
  local ref=""
  if [ "$2" = yes ]; then ref="--tpm2-public-key-policyref=initrd"; fi
  run "export SYSTEMD_TPM2_DEVICE=$dev
    truncate -s 48M /w/$1.img
    cryptsetup luksFormat -q --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 /w/$1.img /w/key
    systemd-cryptenroll /w/$1.img --unlock-key-file=/w/key --tpm2-device=$dev \
      --tpm2-public-key=/w/pcrpkey.pem --tpm2-public-key-pcrs=11 $ref --tpm2-pcrs=7+12 2>&1"
}

fail=0
# Try to unseal DISK with SIGFILE in the current state, and check the result and its reason:
#   row DESCRIPTION DISK SIGFILE unsealed
#   row DESCRIPTION DISK SIGFILE refused REASON-REGEX
row() {
  local log="$logs/tpm-unlock-$2-${RANDOM}.log" result line mark="OK"
  run "SYSTEMD_LOG_LEVEL=debug /usr/lib/systemd/systemd-cryptsetup attach nyra-tpm-test /w/$2.img - \
    tpm2-device=$dev,tpm2-signature=/w/$3,headless=yes 2>&1 || true" > "$log" 2>&1
  if grep -q "Completed TPM2 key unsealing" "$log"; then result=unsealed; else result=refused; fi
  if [ "$4" = unsealed ]; then
    # Unsealed over an encrypted session, salted with the TPM's storage key.
    line="$(grep -m1 -E "Starting HMAC encryption session" "$log" || true)"
    if [ "$result" != unsealed ] || [ -z "$line" ]; then mark="WRONG"; fi
    [ -n "$line" ] || line="(no encrypted session in the log)"
  else
    line="$(grep -m1 -E "$5" "$log" || true)"
    if [ "$result" != refused ] || [ -z "$line" ]; then mark="WRONG"; fi
    [ -n "$line" ] || line="(expected reason not in the log: $5)"
  fi
  [ "$mark" = OK ] || fail=1
  printf '| %s | %s | %s | %s | `%s` |\n' "$1" "$4" "$result" "$mark" "$line" >> "$summary"
  echo "tpm-unlock: $1: expected $4, got $result [$mark]: $line"
}

check() { # check DESCRIPTION EXPECTED RESULT
  local mark="OK"
  if [ "$2" != "$3" ]; then mark="WRONG"; fail=1; fi
  printf '| %s | %s | %s | %s | |\n' "$1" "$2" "$3" "$mark" >> "$summary"
  echo "tpm-unlock: $1: expected $2, got $3 [$mark]"
}

{
  echo "### TPM2 disk-unlock policy (swtpm)"
  echo
  echo "| Boot state / enrollment | Expected | Result | | Reason (log) |"
  echo "|---|---|---|---|---|"
} >> "$summary"

# The disks: one enrolled with the reference (the documented binding), one without.
power_cycle; replay main enter-initrd; enroll da yes
power_cycle; replay main enter-initrd; enroll noref no

# No NvPCR. The evidence is that the image ships no NvPCR definitions (/usr/lib/nvpcr), so
# systemd-tpm2-setup, which allocates them at boot, has none to allocate (it does not run here: it
# talks only to a kernel TPM). The NV index check after the last row only shows that enrolling and
# unsealing allocate none.
check "image NvPCR definitions (/usr/lib/nvpcr)" none "$(run 'if test -e /usr/lib/nvpcr; then echo some; else echo none; fi')"

nosig="No signature for current PCR policy in TPM2 signature JSON"
# The documented binding: unseals only in the main profile's enter-initrd.
power_cycle; replay main enter-initrd; row "main profile, enter-initrd" da pcrsig.json unsealed
power_cycle; replay main leave-initrd; row "main profile, leave-initrd (running system)" da pcrsig.json refused "$nosig"
power_cycle; replay main sysinit;      row "main profile, sysinit (running system)" da pcrsig.json refused "$nosig"
power_cycle; replay main ready;        row "main profile, ready (running system)" da pcrsig.json refused "$nosig"
power_cycle; replay recovery enter-initrd; row "recovery profile" da pcrsig.json refused "$nosig"
power_cycle; replay reset enter-initrd;    row "reset profile" da pcrsig.json refused "$nosig"
# PCR 12 differs from the enrolled value: the policy the TPM computes from the PCRs is not the one
# the key was sealed with.
power_cycle; replay main enter-initrd 1; row "an add-on measured into PCR 12" da pcrsig.json refused \
  "Current policy digest does not match stored policy digest"
# The enter-initrd signature on the next phase's policy, at the real leave-initrd state: the TPM
# rejects the signature.
power_cycle; replay main leave-initrd; row "forged signature on the next phase" da forged.json refused "Failed to validate signature in TPM"
# Without the reference, systemd finds no signature for it in the JSON (the TPM would refuse it too:
# the signature covers pol || H("initrd")).
power_cycle; replay main enter-initrd; row "enrollment without the reference" noref pcrsig.json refused "$nosig"
nv="$(run "export TPM2TOOLS_TCTI=$dev; tpm2_getcap handles-nv-index")"
check "NV indexes after enrolling and unsealing" none "$(if [ -z "$(tr -d '[:space:]' <<<"$nv")" ]; then echo none; else echo some; fi)"

echo >> "$summary"
if [ "$fail" = 0 ]; then
  echo "tpm-unlock: the signed PCR 11 policy unlocks the disk only in the main profile's enter-initrd phase"
else
  echo "::error::tpm-unlock: the disk-unlock policy did not behave as expected (table in the step summary)"
fi
exit "$fail"
