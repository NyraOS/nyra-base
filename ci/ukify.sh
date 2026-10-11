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
# profile) and, for the main profile only, the PCR 11 policy digests to sign (.pcrsig, SHA-256 bank):
# the enter-initrd phase with the policy reference "initrd" (--sign-initrd-pcrs), the only one that
# step 3 of ci/build-image.sh signs, so the disk unlocks in the initrd only. ukify adds the four boot
# phases without a reference as well (it cannot leave them out without a key); they stay unsigned.
# No key is here.
# SBAT (docs/BOOT.md, "SBAT"): the stub's and kernel's components, ukify's "uki" line, and the Nyra
# component, whose generation is raised to revoke every older Nyra UKI. --sbat replaces ukify's own
# text, so it repeats the "sbat" and "uki" lines.
#   sh ci/ukify.sh   (with the root filesystem at /target, the kernel at /kernel/<kver>, the policy's
#                     public key at /pcr/tpm2-pcr-public-key.pem, output in /out)
set -eu
k="$(ls /kernel)"
sbat='sbat,1,SBAT Version,sbat,1,https://github.com/rhboot/shim/blob/main/SBAT.md
uki,1,UKI,uki,1,https://uapi-group.org/specifications/specs/unified_kernel_image/
nyra,1,Nyra OS,nyra-base,1,https://github.com/NyraOS/nyra-base/blob/main/docs/BOOT.md'
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
  --join-profile /tmp/reset.profile.efi --sbat "$sbat" \
  --pcr-public-key /pcr/tpm2-pcr-public-key.pem --pcr-banks sha256 --policy-digest --sign-initrd-pcrs \
  --json short --sign-profile main --output "/out/$k.efi"
