#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Step 2 of ci/build-image.sh, inside the committed "sealed" image (its own bootc and ukify): the UKI
# with three profiles (docs/BOOT.md), signed afterwards as one file.
#   0 "Nyra OS"                 the command line bootc container ukify writes (kargs.d + composefs
#                               digest)
#   1 "Nyra OS Recovery"        the same command line plus systemd.unit=rescue.target
#   2 "Nyra OS Reset settings"  the same command line plus systemd.unit=nyra-reset-settings.target
# bootc computes the digest, so a first run gives the command line for the extra profiles; the
# second run, on the same root filesystem, has the same digest. In it the base sections are profile 0
# (--profile labels them; ukify puts that .profile section last among them) and the joined profiles
# are 1 and 2, in that order.
# TPM2 unlock (docs/BOOT.md): the UKI carries the PCR policy's public key (.pcrpkey, measured in every
# profile) and, for the main profile only, the PCR 11 policy digests to sign (.pcrsig, SHA-256 bank,
# systemd's four boot phases). No key is here: step 3 of ci/build-image.sh signs the digests.
#   sh ci/ukify.sh   (with the root filesystem at /target, the kernel at /kernel/<kver>, the policy's
#                     public key at /pcr/tpm2-pcr-public-key.pem, output in /out)
set -eu
k="$(ls /kernel)"
uki() { bootc container ukify --rootfs /target --kernel-dir "/kernel/$k" -- "$@"; }
uki --output /tmp/plain.efi
cmdline="$(python3 - /tmp/plain.efi <<'PY'
import sys, pefile
pe = pefile.PE(sys.argv[1])
print(next(s.get_data().rstrip(b"\0").decode().strip() for s in pe.sections if s.Name.rstrip(b"\0") == b".cmdline"))
PY
)"
case "$cmdline" in *composefs=*) ;; *) echo "ukify.sh: no composefs digest in the UKI's command line: $cmdline" >&2; exit 1 ;; esac
ukify build --profile "$(printf 'ID=recovery\nTITLE=Nyra OS Recovery')" \
  --cmdline "$cmdline systemd.unit=rescue.target" --output /tmp/recovery.profile.efi
ukify build --profile "$(printf 'ID=reset\nTITLE=Nyra OS Reset settings')" \
  --cmdline "$cmdline systemd.unit=nyra-reset-settings.target" --output /tmp/reset.profile.efi
uki --profile "$(printf 'ID=main\nTITLE=Nyra OS')" --join-profile /tmp/recovery.profile.efi \
  --join-profile /tmp/reset.profile.efi \
  --pcr-public-key /pcr/tpm2-pcr-public-key.pem --pcr-banks sha256 --policy-digest --json short --sign-profile main \
  --output "/out/$k.efi"
