#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: the Secure Boot chain on a copy of the installed test disk (docs/BOOT.md).
#   firmware (OVMF, Secure Boot on, Microsoft keys) -> shim (Debian, signed by Microsoft)
#   -> systemd-boot (signed by Debian, trusted by shim) -> the image's sealed UKI, as bootc installed
#   it, signed in the build job with that run's key (UKI_CERT), enrolled here as a MOK.
# Checks: bootc installed only the UKI (a "uki" entry, no kernel or initramfs of its own); the
# signed UKI boots; the same UKI with a changed initramfs (signature kept), without a signature,
# or signed with a key that is not enrolled is refused; unsigned add-ons and plain credentials on
# the ESP have no effect (a signed add-on does: the files are where the stub looks); kernel
# arguments added in the boot entry are ignored (what the boot menu editor would do).
# The keys "local" (enrolled, signs the control add-on) and "other" (not enrolled) are made here,
# live only in WORKDIR on the ephemeral runner and are deleted at the end: never commit or upload
# them, never use a real key here.
#   tools/vm/secure-boot.sh IMAGE DISK.qcow2 UKI_CERT WORKDIR LOGDIR SUMMARY
set -euo pipefail

image="$1" disk="$2" uki_cert="$3" work="$4" logs="$5" summary="$6"
sb="$work/secure-boot"
mnt="$sb/esp"
loop=""
mkdir -p "$mnt"
# Set before the keys exist, so they are deleted whatever fails. set -e also applies inside the trap:
# every step before rm -rf must not fail.
trap 'sudo umount -q "$mnt" 2>/dev/null || true; [ -z "$loop" ] || sudo losetup -d "$loop" || true; rm -rf "$sb"' EXIT

openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=Nyra CI add-on test key" \
  -keyout "$sb/local.key" -out "$sb/local.crt" 2>/dev/null
openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=Nyra CI key that is not enrolled" \
  -keyout "$sb/other.key" -out "$sb/other.crt" 2>/dev/null
# Owner GUID: shim's. The firmware variables come with Secure Boot on and the Microsoft keys.
virt-fw-vars --input /usr/share/OVMF/OVMF_VARS_4M.ms.fd --output "$sb/vars.fd" \
  --add-mok 605dab50-e046-4300-abb6-3dd810dd8b23 "$uki_cert" \
  --add-mok 605dab50-e046-4300-abb6-3dd810dd8b23 "$sb/local.crt"

# The boot binaries come from the image (Debian packages shim-signed, shim-helpers-amd64-signed,
# systemd-boot-efi-amd64-signed, systemd-boot-efi).
cid="$(sudo podman create -q "$image")"
for f in /usr/lib/shim/shimx64.efi.signed /usr/lib/shim/mmx64.efi.signed \
         /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed /usr/lib/systemd/boot/efi/addonx64.efi.stub; do
  sudo podman cp "$cid:$f" "$sb/"
done
sudo podman rm -f "$cid" >/dev/null
sudo chown -R "$(id -u):$(id -g)" "$sb"

qemu-img convert -O raw "$disk" "$sb/disk.raw"
loop="$(sudo losetup -P --show -f "$sb/disk.raw")"
esp=""
for p in "$loop"p*; do
  if [ "$(sudo blkid -o value -s TYPE "$p")" = vfat ]; then esp="$p"; fi
done
test -n "$esp"

sudo mount "$esp" "$mnt"
# bootc install (bootctl) put the Debian-signed systemd-boot on the ESP.
cmp "$sb/systemd-bootx64.efi.signed" "$mnt/EFI/systemd/systemd-bootx64.efi"
# UKI only: one entry, of type "uki", for a UKI under EFI/Linux/bootc; no kernel or initramfs anywhere.
entries=("$mnt"/loader/entries/*.conf)
test "${#entries[@]}" = 1
entry="${entries[0]}"
cat "$entry"
if grep -Eq '^(linux|initrd|options)[[:space:]]' "$entry"; then echo "not a UKI-only entry"; exit 1; fi
uki="$(sed -n 's/^uki[[:space:]]\+//p' "$entry")"
[[ "$uki" =~ ^/EFI/Linux/bootc/bootc_composefs-[0-9a-f]{128}\.efi$ ]]
test -z "$(sudo find "$mnt" -iname 'vmlinuz*' -o -iname 'initrd*' -o -iname 'initramfs*')"
sudo cp "$mnt$uki" "$sb/signed.efi"
sudo chown "$(id -u):$(id -g)" "$sb/signed.efi"
sbverify --cert "$uki_cert" "$sb/signed.efi"

# What the installer will do (docs/BOOT.md): shim on the removable-media path, systemd-boot next
# to it under the name shim starts, MokManager for key enrollment.
sudo cp "$sb/shimx64.efi.signed" "$mnt/EFI/BOOT/BOOTX64.EFI"
sudo cp "$sb/systemd-bootx64.efi.signed" "$mnt/EFI/BOOT/grubx64.efi"
sudo cp "$sb/mmx64.efi.signed" "$mnt/EFI/BOOT/mmx64.efi"
sudo umount "$mnt"

# The refused variants of the signed UKI:
# - tampered: one byte in the middle of the initramfs (.initrd section) changed, signature kept;
# - unsigned: the signature removed; other: signed with the key that is not enrolled.
read -r off size < <(objdump -h "$sb/signed.efi" | awk '$2 == ".initrd" { print $6, $3 }')
cp "$sb/signed.efi" "$sb/tampered.efi"
printf '\xff' | dd of="$sb/tampered.efi" bs=1 seek=$((0x$off + 0x$size / 2)) conv=notrunc status=none
if cmp -s "$sb/signed.efi" "$sb/tampered.efi"; then echo "the byte was already 0xff"; exit 1; fi
cp "$sb/signed.efi" "$sb/unsigned.efi"
sbattach --remove "$sb/unsigned.efi"
sbsign --key "$sb/other.key" --cert "$sb/other.crt" --output "$sb/other.efi" "$sb/unsigned.efi"

# Add-ons (extra kernel arguments) next to the UKI and for every UKI, and plain (unencrypted)
# credentials, a tmpfiles.d line each, for this UKI and for every UKI.
ukify build --stub "$sb/addonx64.efi.stub" --cmdline nyra.addon.unsigned=1 --output "$sb/unsigned.addon.efi"
ukify build --stub "$sb/addonx64.efi.stub" --cmdline nyra.addon.global=1 --output "$sb/global.addon.efi"
ukify build --stub "$sb/addonx64.efi.stub" --cmdline nyra.addon.signed=1 --output "$sb/control.addon.efi" \
  --secureboot-private-key "$sb/local.key" --secureboot-certificate "$sb/local.crt"
printf 'f /run/nyra-cred-uki 0644 root root - injected\n' > "$sb/uki.cred"
printf 'f /run/nyra-cred-global 0644 root root - injected\n' > "$sb/global.cred"

vm() {
  python3 -B tools/vm/vm-boot.py --secure-boot "$sb/vars.fd" --disk "$sb/disk.raw" --timeout 180 \
    --summary "$summary" "$@"
}
efivar() { # guest command that prints a systemd-boot EFI variable (UTF-16 text after 4 attribute bytes)
  echo "tail -c +5 /sys/firmware/efi/efivars/$1-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f | tr -d '\\000'"
}
name="${entry##*/}"

# The boots are independent: run them all, fail at the end.
fail=0
vm --autologin --log "$logs/serial-secure-boot.log" \
  --title "Secure Boot: shim -> systemd-boot -> the image's UKI, signed with this run's key (MOK)" \
  --command 'mokutil --sb-state; mokutil --sb-state | grep -qx "SecureBoot enabled"' \
  --command 'mokutil --list-enrolled | grep "CN=Nyra CI"; mokutil --list-enrolled | grep -q "CN=Nyra CI per-run UKI key"' \
  --command "echo \"boot loader: \$($(efivar LoaderImageIdentifier))\"" \
  --command "e=\"\$($(efivar LoaderEntrySelected))\"; s=\"\$($(efivar StubInfo))\"; echo \"entry: \$e, stub: \$s\"; test \"\$e\" = $name && echo \"\$s\" | grep -q systemd-stub" \
  --command 'cat /sys/kernel/security/lockdown; grep -q "\[integrity\]" /sys/kernel/security/lockdown' \
  --command 'cat /proc/cmdline; grep -Eq "(^| )composefs=[0-9a-f]{128}( |$)" /proc/cmdline' \
  --command 's="$(systemctl is-system-running --wait)"; echo "system: $s"; systemctl --no-pager --failed; test "$s" = running' \
  || fail=1

for variant in tampered unsigned other; do
  sudo mount "$esp" "$mnt"
  sudo cp "$sb/$variant.efi" "$mnt$uki"
  sudo umount "$mnt"
  case "$variant" in
    tampered) what="with a changed initramfs (signature kept)" ;;
    unsigned) what="without a signature" ;;
    other) what="signed with a key that is not enrolled" ;;
  esac
  vm --log "$logs/serial-secure-boot-$variant.log" --title "Secure Boot: the UKI $what is refused" \
    --refused 'Error loading EFI binary .*bootc_composefs-[0-9a-f]+\.efi: Security violation' || fail=1
done

# Add-ons and credentials: only the add-on signed with an enrolled key may change the command line;
# the plain credentials must not create their files.
sudo mount "$esp" "$mnt"
sudo cp "$sb/signed.efi" "$mnt$uki"
sudo mkdir -p "$mnt$uki.extra.d" "$mnt/loader/addons" "$mnt/loader/credentials"
sudo cp "$sb/unsigned.addon.efi" "$sb/control.addon.efi" "$mnt$uki.extra.d/"
sudo cp "$sb/global.addon.efi" "$mnt/loader/addons/"
sudo cp "$sb/uki.cred" "$mnt$uki.extra.d/tmpfiles.extra.cred"
sudo cp "$sb/global.cred" "$mnt/loader/credentials/tmpfiles.extra.cred"
sudo umount "$mnt"
vm --autologin --log "$logs/serial-secure-boot-extras.log" \
  --title "Secure Boot: unsigned add-ons and plain credentials on the ESP have no effect" \
  --command 'cat /proc/cmdline; grep -q "nyra.addon.signed=1" /proc/cmdline && ! grep -Eq "nyra.addon.(unsigned|global)" /proc/cmdline' \
  --command 'ls -l /run/nyra-cred-* 2>&1; test ! -e /run/nyra-cred-uki && test ! -e /run/nyra-cred-global' \
  --command 's="$(systemctl is-system-running --wait)"; echo "system: $s"; systemctl --no-pager --failed; ls -lR /.extra /run/credentials 2>&1 | head -40; journalctl -b -o cat --no-pager | grep -i -e credential -e addon | head -20' \
  || fail=1

# The entry that starts the signed UKI with an extra kernel argument, as the boot menu editor would:
# with Secure Boot, systemd-stub ignores it and uses the command line in the UKI.
sudo mount "$esp" "$mnt"
sudo rm -r "$mnt$uki.extra.d" "$mnt/loader/addons" "$mnt/loader/credentials"
printf 'options nyra.injected=1\n' | sudo tee -a "$mnt/loader/entries/$name" >/dev/null
sudo umount "$mnt"
vm --autologin --log "$logs/serial-secure-boot-injected.log" \
  --title "Secure Boot: kernel arguments added in the boot entry are ignored" \
  --command "e=\"\$($(efivar LoaderEntrySelected))\"; echo \"entry: \$e\"; test \"\$e\" = $name" \
  --command 'cat /proc/cmdline; grep -q "composefs=" /proc/cmdline && ! grep -q "nyra.injected" /proc/cmdline' \
  || fail=1
exit "$fail"
