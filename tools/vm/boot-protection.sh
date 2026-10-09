#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: boot protection on a copy of the installed test disk (docs/BOOT.md), with Secure Boot on
# (the image's UKI certificate enrolled as a MOK) and one firmware variable store kept across boots.
# The disk is the one install-boot made: bootc install, then esp-sync install (the boot files and
# loader.conf on the ESP, as the installer does). Checks, in order, on the same system:
#   0. before the first boot: loader.conf with "editor no", both copies of the boot files in place;
#   1. empty boot entries (firmware variables reset): boots through the fallback path; nothing on
#      the ESP needed repair; the "Nyra OS" entry is created, first in BootOrder; only root can
#      read the ESP (no permission bits for group and others);
#   2. boots through the "Nyra OS" entry; another entry is put first, as Windows does;
#   3. that entry fails (its file does not exist), the "Nyra OS" entry boots and is first again;
#   4. interrupted boot loader update (EFI/nyra/grubx64.efi cut in half): the firmware falls back
#      to EFI/BOOT, and the file is repaired;
#   5. fallback files deleted: boots through "Nyra OS", the files are back;
#   6. ESP full and the fallback systemd-boot corrupted: boots through "Nyra OS", the repair fails
#      visibly and leaves no half-written file;
#   7. space freed: the repair completes;
#   8. a newer systemd-boot in EFI/BOOT than this image's (as after an update that brought a newer
#      boot loader, then a fallback to this version): kept, never replaced by the older one;
#   9. an older one there and this version on trial (a counted entry whose boot-complete.target
#      fails): not replaced yet;
#  10. the same version healthy: blessed;
#  11. the next boot: the newer boot loader from this image is written.
# "Newer" and "older" are made by changing the first digit of the Debian version in the file's
# SBAT section; that copy is never started (the boots go through EFI/nyra), so its signature does
# not matter.
#   tools/vm/boot-protection.sh IMAGE DISK.qcow2 UKI_CERT WORKDIR LOGDIR SUMMARY
set -euo pipefail

image="$1" disk="$2" uki_cert="$3" work="$4" logs="$5" summary="$6"
bp="$work/boot-protection"
mnt="$bp/esp"
loop=""
mkdir -p "$mnt" "$bp/ref"
trap 'sudo umount -q "$mnt" 2>/dev/null || true; [ -z "$loop" ] || sudo losetup -d "$loop" || true; rm -rf "$bp"' EXIT

# Owner GUID: shim's. Secure Boot on, Microsoft keys, the image's UKI certificate as a MOK.
virt-fw-vars --input /usr/share/OVMF/OVMF_VARS_4M.ms.fd --output "$bp/vars.fd" \
  --add-mok 605dab50-e046-4300-abb6-3dd810dd8b23 "$uki_cert"

cid="$(sudo podman create -q "$image")"
for f in /usr/lib/shim/shimx64.efi.signed /usr/lib/shim/mmx64.efi.signed \
         /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed /usr/lib/nyra/boot/loader.conf; do
  sudo podman cp "$cid:$f" "$bp/ref/"
done
sudo podman rm -f "$cid" >/dev/null
sudo chown -R "$(id -u):$(id -g)" "$bp/ref"
shim="$bp/ref/shimx64.efi.signed" mm="$bp/ref/mmx64.efi.signed" sdboot="$bp/ref/systemd-bootx64.efi.signed"

qemu-img convert -O raw "$disk" "$bp/disk.raw"
loop="$(sudo losetup -P --show -f "$bp/disk.raw")"
esp=""
for p in "$loop"p*; do
  if [ "$(sudo blkid -o value -s TYPE "$p")" = vfat ]; then esp="$p"; fi
done
test -n "$esp"

# 0. The installed ESP, before the first boot.
sudo mount "$esp" "$mnt"
{
  echo "### Boot protection: the installed ESP before the first boot"
  echo
  echo '```'
  sudo cat "$mnt/loader/loader.conf"
  (cd "$mnt" && sudo find EFI/nyra EFI/BOOT -type f -exec sha256sum {} + | cut -c 1-16,65-)
  echo '```'
} >> "$summary"
sudo grep -qx 'editor no' "$mnt/loader/loader.conf"
sudo cmp "$bp/ref/loader.conf" "$mnt/loader/loader.conf"
for d in nyra BOOT; do
  sudo cmp "$sdboot" "$mnt/EFI/$d/grubx64.efi"
  sudo cmp "$mm" "$mnt/EFI/$d/mmx64.efi"
done
sudo cmp "$shim" "$mnt/EFI/nyra/shimx64.efi"
sudo cmp "$shim" "$mnt/EFI/BOOT/BOOTX64.EFI"
sudo umount "$mnt"

vm() {
  python3 -B tools/vm/vm-boot.py --secure-boot "$bp/vars.fd" --keep-vars --disk "$bp/disk.raw" --persist \
    --autologin --poweroff --timeout 240 --summary "$summary" "$@"
}
# Guest commands.
loader() { # systemd-boot's own path, as the firmware or shim started it
  echo "l=\"\$(tail -c +5 /sys/firmware/efi/efivars/LoaderImageIdentifier-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f | tr -d '\\000')\"; echo \"systemd-boot: \$l\"; test \"\$l\" = '$1'"
}
first='efibootmgr; o="$(efibootmgr | sed -n "s/^BootOrder: //p")"; efibootmgr -v | grep -q "^Boot${o%%,*}\*\{0,1\} Nyra OS$(printf "\t")"'
repair='s="$(systemctl is-system-running --wait)"; echo "system: $s"; journalctl -b -u nyra-boot-repair -o cat --no-pager; test "$s" = running'
# (Guest commands are typed into the login shell: no "exit" in them.)
same='u=/usr/lib; cmp $u/shim/shimx64.efi.signed /boot/EFI/nyra/shimx64.efi && cmp $u/shim/shimx64.efi.signed /boot/EFI/BOOT/BOOTX64.EFI && cmp $u/systemd/boot/efi/systemd-bootx64.efi.signed /boot/EFI/nyra/grubx64.efi && cmp $u/systemd/boot/efi/systemd-bootx64.efi.signed /boot/EFI/BOOT/grubx64.efi && cmp $u/shim/mmx64.efi.signed /boot/EFI/nyra/mmx64.efi && cmp $u/shim/mmx64.efi.signed /boot/EFI/BOOT/mmx64.efi && echo "boot files as in /usr"'
with_esp() { sudo mount "$esp" "$mnt"; "$@"; sudo umount "$mnt"; }

# The boots follow one system: stop at the first failure.
vm --log "$logs/serial-boot-protection-1.log" \
  --title "Boot protection 1: no boot entries (variables reset): fallback path, \"Nyra OS\" entry created" \
  --command "$(loader '\EFI\BOOT\grubx64.efi')" \
  --command "$repair" \
  --command '! journalctl -b -u nyra-boot-repair -o cat | grep "updated from" && echo "nothing on the ESP needed repair at the first boot"' \
  --command "$first" \
  --command 'o="$(findmnt -no OPTIONS -t vfat /boot | tr , "\n")"; echo "$o" | grep mask; echo "$o" | grep -Eqx "fmask=0[0-7]77" && echo "$o" | grep -Eqx "dmask=0[0-7]77"'

vm --log "$logs/serial-boot-protection-2.log" \
  --title "Boot protection 2: through the \"Nyra OS\" entry; another entry put first, as Windows does" \
  --command "$(loader '\EFI\nyra\grubx64.efi')" \
  --command "$repair" \
  --command 'd="$(findmnt -no SOURCE -t vfat /boot)"; efibootmgr -q -c -d "/dev/$(lsblk -no PKNAME "$d")" -p "$(cat /sys/class/block/${d##*/}/partition)" -L "Other OS" -l "\EFI\other\bootx64.efi"; efibootmgr; o="$(efibootmgr | sed -n "s/^BootOrder: //p")"; efibootmgr | grep -q "^Boot${o%%,*}\* Other OS"'

vm --log "$logs/serial-boot-protection-3.log" \
  --title "Boot protection 3: the other entry fails, \"Nyra OS\" boots and is first again" \
  --command "$(loader '\EFI\nyra\grubx64.efi')" \
  --command "$repair" \
  --command 'journalctl -b -u nyra-boot-repair -o cat | grep "is first again"' \
  --command "$first"

cut_in_half() { sudo truncate -s $(($(sudo stat -c %s "$mnt/EFI/nyra/grubx64.efi") / 2)) "$mnt/EFI/nyra/grubx64.efi"; }
with_esp cut_in_half
vm --log "$logs/serial-boot-protection-4.log" \
  --title "Boot protection 4: interrupted boot loader update (EFI/nyra/grubx64.efi cut in half): fallback path, repaired" \
  --command "$(loader '\EFI\BOOT\grubx64.efi')" \
  --command "$repair" \
  --command "$same" \
  --command "$first"

delete_fallback() { sudo rm "$mnt/EFI/BOOT/BOOTX64.EFI" "$mnt/EFI/BOOT/grubx64.efi"; }
with_esp delete_fallback
vm --log "$logs/serial-boot-protection-5.log" \
  --title "Boot protection 5: fallback files deleted: through \"Nyra OS\", put back" \
  --command "$(loader '\EFI\nyra\grubx64.efi')" \
  --command "$repair" \
  --command "$same"

# The ESP filled up to the last cluster, and one byte of the fallback systemd-boot changed in place
# (no space needed), so its signature no longer matches.
fill_and_corrupt() {
  sudo dd if=/dev/zero of="$mnt/filler" bs=1M status=none 2>/dev/null || true
  sudo dd if=/dev/zero of="$mnt/filler2" bs=4k status=none 2>/dev/null || true
  printf '\xff' | sudo dd of="$mnt/EFI/BOOT/grubx64.efi" bs=1 seek=4096 conv=notrunc status=none
  df -h "$mnt"
}
with_esp fill_and_corrupt
vm --log "$logs/serial-boot-protection-6.log" \
  --title "Boot protection 6: ESP full, fallback systemd-boot corrupted: boots, the repair fails visibly" \
  --command "$(loader '\EFI\nyra\grubx64.efi')" \
  --command 's="$(systemctl is-system-running --wait)"; echo "system: $s"; journalctl -b -u nyra-boot-repair -o cat --no-pager; systemctl is-failed -q nyra-boot-repair && journalctl -b -u nyra-boot-repair -o cat | grep -q "could not write /boot/EFI/BOOT/grubx64.efi"' \
  --command '! ls /boot/EFI/*/*.nyra-new 2>/dev/null && echo "no half-written file" && ! cmp -s /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed /boot/EFI/BOOT/grubx64.efi && echo "the damaged file is left as it was"' \
  --command "$first"

free_space() { sudo rm -f "$mnt/filler" "$mnt/filler2"; }
with_esp free_space
vm --log "$logs/serial-boot-protection-7.log" \
  --title "Boot protection 7: space freed: the repair completes" \
  --command "$(loader '\EFI\nyra\grubx64.efi')" \
  --command "$repair" \
  --command "$same"

# Sets the first digit of the Debian version in systemd-boot's SBAT section (FILE DIGIT), in place.
set_version() {
  sudo python3 - "$1" "$2" <<'PY'
import sys
f, digit = sys.argv[1], sys.argv[2].encode()
b = bytearray(open(f, "rb").read())
i = b.index(b"\nsystemd-boot.debian,") + 1
for _ in range(4):
    i = b.index(b",", i) + 1
b[i:i + 1] = digit
open(f, "wb").write(b)
PY
  echo "$1: $(sudo grep -a -m 1 -oE '^systemd-boot\.debian,[^,]+,[^,]+,[^,]+,[^,]+' "$1")"
}
fallback_sdboot='/boot/EFI/BOOT/grubx64.efi'

newer_on_esp() { set_version "$mnt/EFI/BOOT/grubx64.efi" 9; sudo sha256sum "$mnt/EFI/BOOT/grubx64.efi" | tee "$bp/newer.sha256"; }
with_esp newer_on_esp
vm --log "$logs/serial-boot-protection-8.log" \
  --title "Boot protection 8: a newer systemd-boot on the ESP than this image's is kept" \
  --command "$(loader '\EFI\nyra\grubx64.efi')" \
  --command "$repair" \
  --command "journalctl -b -u nyra-boot-repair -o cat | grep 'is newer than this image' && ! cmp -s /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed $fallback_sdboot"
check_kept() { sudo sha256sum -c "$bp/newer.sha256"; }
with_esp check_kept

older_on_esp_on_trial() {
  sudo cp "$sdboot" "$mnt/EFI/BOOT/grubx64.efi"
  set_version "$mnt/EFI/BOOT/grubx64.efi" 1
  local entries=("$mnt"/loader/entries/*.conf)
  test "${#entries[@]}" = 1
  sudo mv "${entries[0]}" "${entries[0]%.conf}+3.conf"
  ls "$mnt/loader/entries"
}
with_esp older_on_esp_on_trial
vm --log "$logs/serial-boot-protection-9.log" \
  --credential $'systemd.unit-dropin.boot-complete.target=[Unit]\nRequires=nyra-test-missing.service\n' \
  --title "Boot protection 9: an older systemd-boot on the ESP, this version on trial: not replaced yet" \
  --command "$(loader '\EFI\nyra\grubx64.efi')" \
  --command 's="$(systemctl is-system-running --wait)"; echo "system: $s"; ls /boot/loader/entries; b="$(/usr/lib/systemd/systemd-bless-boot status)"; echo "bless: $b"; test "$b" = indeterminate' \
  --command "journalctl -b -u nyra-boot-repair -o cat | grep 'once this version is blessed' && ! cmp -s /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed $fallback_sdboot"

vm --log "$logs/serial-boot-protection-10.log" \
  --title "Boot protection 10: the same version healthy: blessed" \
  --command "$(loader '\EFI\nyra\grubx64.efi')" \
  --command "$repair" \
  --command 'ls /boot/loader/entries; b="$(/usr/lib/systemd/systemd-bless-boot status)"; echo "bless: $b"; test "$b" = good'

vm --log "$logs/serial-boot-protection-11.log" \
  --title "Boot protection 11: after the blessing, the newer systemd-boot from this image is written" \
  --command "$(loader '\EFI\nyra\grubx64.efi')" \
  --command "$repair" \
  --command 'b="$(/usr/lib/systemd/systemd-bless-boot status)"; echo "bless: $b"; test "$b" = clean' \
  --command "$same"
