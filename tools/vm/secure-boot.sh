#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: the Secure Boot chain on a copy of the installed test disk (docs/BOOT.md).
#   firmware (OVMF, Secure Boot on, Microsoft keys) -> shim (Debian, signed by Microsoft)
#   -> systemd-boot (signed by Debian, trusted by shim) -> UKI signed with a throwaway key
#   that is enrolled as a MOK (Machine Owner Key) in the firmware variables.
# The UKI wraps the kernel, initramfs and the whole command line (composefs digest included) of
# the boot entry bootc installed. Checks: the signed UKI boots with Secure Boot on; an unsigned
# UKI and one signed with a key that is not enrolled are refused; kernel arguments added in a
# boot loader entry for the signed UKI are ignored (what the boot menu editor would do).
# The keys are generated here, live only in WORKDIR on the ephemeral runner and are deleted at
# the end: never commit or upload them, never use a real key here.
#   tools/vm/secure-boot.sh IMAGE DISK.qcow2 WORKDIR LOGDIR SUMMARY
set -euo pipefail

image="$1" disk="$2" work="$3" logs="$4" summary="$5"
sb="$work/secure-boot"
mnt="$sb/esp"
uki=/EFI/Linux/nyra-test.efi
mkdir -p "$mnt"

# Throwaway keys: "test" is enrolled as a MOK, "other" is not.
openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=Nyra CI throwaway test key" \
  -keyout "$sb/test.key" -out "$sb/test.crt" 2>/dev/null
openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=Nyra CI key that is not enrolled" \
  -keyout "$sb/other.key" -out "$sb/other.crt" 2>/dev/null
# Owner GUID: shim's. The firmware variables come with Secure Boot on and the Microsoft keys.
virt-fw-vars --input /usr/share/OVMF/OVMF_VARS_4M.ms.fd --output "$sb/vars.fd" \
  --add-mok 605dab50-e046-4300-abb6-3dd810dd8b23 "$sb/test.crt"

# The boot binaries come from the image (Debian packages shim-signed, shim-helpers-amd64-signed,
# systemd-boot-efi-amd64-signed, systemd-boot-efi).
cid="$(sudo podman create -q "$image")"
for f in /usr/lib/shim/shimx64.efi.signed /usr/lib/shim/mmx64.efi.signed /usr/lib/os-release \
         /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed /usr/lib/systemd/boot/efi/linuxx64.efi.stub; do
  sudo podman cp "$cid:$f" "$sb/"
done
sudo podman rm -f "$cid" >/dev/null
sudo chown -R "$(id -u):$(id -g)" "$sb"

qemu-img convert -O raw "$disk" "$sb/disk.raw"
loop="$(sudo losetup -P --show -f "$sb/disk.raw")"
trap 'sudo umount -q "$mnt" 2>/dev/null || true; sudo losetup -d "$loop"; rm -rf "$sb"' EXIT
esp=""
for p in "$loop"p*; do
  if [ "$(sudo blkid -o value -s TYPE "$p")" = vfat ]; then esp="$p"; fi
done
test -n "$esp"

sudo mount "$esp" "$mnt"
# bootc install (bootctl) put the Debian-signed systemd-boot on the ESP.
cmp "$sb/systemd-bootx64.efi.signed" "$mnt/EFI/systemd/systemd-bootx64.efi"
entries=("$mnt"/loader/entries/*.conf)
test "${#entries[@]}" = 1
entry="${entries[0]}"
cat "$entry"
options="$(sed -n 's/^options[[:space:]]\+//p' "$entry" | paste -sd ' ')"
linux="$(sed -n 's/^linux[[:space:]]\+//p' "$entry")"
mapfile -t initrds < <(sed -n 's/^initrd[[:space:]]\+//p' "$entry")
grep -q 'composefs=' <<<"$options"
ukify build --linux "$mnt$linux" "${initrds[@]/#/--initrd=$mnt}" --cmdline "$options" \
  --os-release "@$sb/os-release" --stub "$sb/linuxx64.efi.stub" --output "$sb/unsigned.efi"
sbsign --key "$sb/test.key" --cert "$sb/test.crt" --output "$sb/signed.efi" "$sb/unsigned.efi"
sbsign --key "$sb/other.key" --cert "$sb/other.crt" --output "$sb/other.efi" "$sb/unsigned.efi"
sbverify --cert "$sb/test.crt" "$sb/signed.efi"

# What the installer will do (docs/BOOT.md): shim on the removable-media path, systemd-boot next
# to it under the name shim starts, MokManager for key enrollment. Only the UKI is bootable.
sudo cp "$sb/shimx64.efi.signed" "$mnt/EFI/BOOT/BOOTX64.EFI"
sudo cp "$sb/systemd-bootx64.efi.signed" "$mnt/EFI/BOOT/grubx64.efi"
sudo cp "$sb/mmx64.efi.signed" "$mnt/EFI/BOOT/mmx64.efi"
sudo rm "$entry"
sudo cp "$sb/signed.efi" "$mnt$uki"
sudo umount "$mnt"

vm() {
  python3 -B tools/vm/vm-boot.py --secure-boot "$sb/vars.fd" --disk "$sb/disk.raw" --timeout 180 \
    --summary "$summary" "$@"
}
efivar() { # guest command that prints a systemd-boot EFI variable (UTF-16 text after 4 attribute bytes)
  echo "tail -c +5 /sys/firmware/efi/efivars/$1-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f | tr -d '\\000'"
}

# The four boots are independent: run them all, fail at the end.
fail=0
vm --autologin --log "$logs/serial-secure-boot.log" \
  --title "Secure Boot: shim -> systemd-boot -> UKI signed with the enrolled test key" \
  --command 'mokutil --sb-state; mokutil --sb-state | grep -qx "SecureBoot enabled"' \
  --command 'mokutil --list-enrolled | grep "CN=Nyra CI"; mokutil --list-enrolled | grep -q "CN=Nyra CI throwaway test key"' \
  --command "echo \"boot loader: \$($(efivar LoaderImageIdentifier))\"" \
  --command "e=\"\$($(efivar LoaderEntrySelected))\"; s=\"\$($(efivar StubInfo))\"; echo \"entry: \$e, stub: \$s\"; test \"\$e\" = nyra-test.efi && echo \"\$s\" | grep -q systemd-stub" \
  --command 'cat /sys/kernel/security/lockdown; grep -q "\[integrity\]" /sys/kernel/security/lockdown' \
  --command 'cat /proc/cmdline; grep -q "composefs=" /proc/cmdline' \
  --command 's="$(systemctl is-system-running --wait)"; echo "system: $s"; systemctl --no-pager --failed; test "$s" = running' \
  || fail=1

for variant in unsigned other; do
  sudo mount "$esp" "$mnt"
  sudo cp "$sb/$variant.efi" "$mnt$uki"
  sudo umount "$mnt"
  vm --log "$logs/serial-secure-boot-$variant.log" \
    --title "Secure Boot: UKI $([ "$variant" = unsigned ] && echo "without a signature" || echo "signed with a key that is not enrolled") is refused" \
    --refused 'Error loading EFI binary \\EFI\\Linux\\nyra-test\.efi: Security violation' || fail=1
done

# A boot loader entry that starts the signed UKI with an extra kernel argument, as the boot menu
# editor would: with Secure Boot, systemd-stub ignores it and uses the command line in the UKI.
sudo mount "$esp" "$mnt"
sudo mkdir -p "$mnt/EFI/nyra-test" "$mnt/loader/entries"
sudo rm "$mnt$uki"
sudo cp "$sb/signed.efi" "$mnt/EFI/nyra-test/uki.efi"
printf 'title Extra kernel argument\nefi /EFI/nyra-test/uki.efi\noptions %s nyra.injected=1\n' "$options" \
  | sudo tee "$mnt/loader/entries/injected.conf" >/dev/null
sudo umount "$mnt"
vm --autologin --log "$logs/serial-secure-boot-injected.log" \
  --title "Secure Boot: kernel arguments added in the boot loader entry are ignored" \
  --command "e=\"\$($(efivar LoaderEntrySelected))\"; echo \"entry: \$e\"; test \"\$e\" = injected.conf" \
  --command 'cat /proc/cmdline; grep -q "composefs=" /proc/cmdline && ! grep -q "nyra.injected" /proc/cmdline' \
  || fail=1
exit "$fail"
