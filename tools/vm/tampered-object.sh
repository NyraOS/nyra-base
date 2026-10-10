#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: Titanic T1, a file of /usr changed on the disk itself (docs/TITANIC.md). One boot of the
# installed test disk (QEMU snapshot mode, the disk is not changed). In the guest, as root: the
# composefs object behind a file of /usr is found in /sysroot/composefs/objects (same size, same
# content), and bytes of its first block are overwritten on the block device, under the file
# system; the page cache is dropped. Reading the file through /usr, and the object itself, must then
# fail with an I/O error (fs-verity), never return the changed bytes.
# Control: the same write on a plain file of the same file system (in /var) changes what it reads,
# so the error above comes from the verification, not from a write that never reached the disk.
#   tools/vm/tampered-object.sh DISK.qcow2 LOGDIR SUMMARY
set -euo pipefail

disk="$1" logs="$2" summary="$3"
file=/usr/share/common-licenses/GPL-3

# overwrite FILE: "NYRA-TAMPERED" written 100 bytes into FILE's first block, on the block device
# under its file system; then the caches are dropped.
overwrite='overwrite() { dev="$(findmnt -no SOURCE -T "$1" | sed "s/\[.*//")" && bs="$(stat -f -c %S "$1")" && blk="$(filefrag -e -b"$bs" "$1" | awk "\$1 == \"0:\" {sub(/\\.\\..*/, \"\", \$4); print \$4}")" && test -n "$blk" && echo "$1: block $blk of $dev" && printf NYRA-TAMPERED | dd of="$dev" bs=1 seek=$((blk * bs + 100)) conv=notrunc status=none && sync && blockdev --flushbufs "$dev" && echo 3 > /proc/sys/vm/drop_caches; }'
object='size="$(stat -c %s '"$file"')" && obj="$(find /sysroot/composefs/objects -type f -size "${size}c" -exec cmp -s '"$file"' {} \; -print -quit)" && test -n "$obj" && echo "object: $obj"'

python3 -B tools/vm/vm-boot.py --autologin --disk "$disk" --timeout 240 \
  --log "$logs/serial-tampered-object.log" --summary "$summary" \
  --title "Tampered composefs object (Titanic T1)" \
  --command 's="$(systemctl is-system-running --wait)"; echo "system: $s"; test "$s" = running' \
  --command "$overwrite; head -c 300 /usr/share/common-licenses/GPL-2 > /var/nyra-control && sync && overwrite /var/nyra-control && grep -a NYRA-TAMPERED /var/nyra-control && echo 'control: the write reached the plain file'" \
  --command "$object && $overwrite && overwrite \"\$obj\" && ! cat $file > /dev/null && cat $file 2>&1 >/dev/null | grep 'Input/output error' && ! cat \"\$obj\" > /dev/null && ! grep -aq NYRA-TAMPERED $file \"\$obj\" 2>/dev/null && echo 'the changed object: I/O error, through /usr and directly'"
