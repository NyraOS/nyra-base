# systemd: a failed read of LoaderDevicePartUUID leaves the initrd without its root

Status: not sent upstream. nyra-base works around it in the image
(`files/usr/lib/udev/rules.d/61-nyra-gpt-auto-root.rules`, docs/BOOT.md, "Finding the root
partition"); the change below would make that rule unnecessary.

Upstream: systemd/systemd, checked at v262 (Debian `262-1`). Related: systemd/systemd#38842 (slow
reads of the same variable in the same udev probe, in QEMU).

## What

In the initrd, `/dev/gpt-auto-root` exists only if the probe of the whole boot disk
(`builtin_blkid()` → `find_gpt_root()` in `src/udev/udev-builtin-blkid.c`) reads
`LoaderDevicePartUUID`, finds that ESP on the disk and sets `ID_PART_GPT_AUTO_ROOT_UUID`; the
partitions, probed after the disk, import it and the root one gets `ID_PART_GPT_AUTO_ROOT=1`.
`find_gpt_root()` reads the variable once (`efi_loader_get_device_part_uuid()`). Any error other
than `ENOENT` or "not supported" ends the probe with a debug message; `builtin_blkid()` ignores the
return value; nothing probes the disk again. systemd-gpt-auto-generator has already made
`sysroot.mount` wait for `/dev/gpt-auto-root`, so the boot ends in emergency mode after the device
timeout, with nothing at the default log level that says why.

## Why it matters

Reads from efivarfs go to the firmware, often through SMM, and can fail now and then;
`efi_get_variable()` already retries `EINTR` for that reason, but no other error. In nyra-base's CI
(QEMU + KVM, OVMF with SMM, Secure Boot, kernel 7.2, systemd 262) two boots in a few thousand stopped
this way: the disk without `ID_PART_GPT_AUTO_ROOT_DISK`/`ID_PART_GPT_AUTO_ROOT_UUID`, the variable
naming the ESP on it, the generator's read of the same variable a moment earlier fine, and one CPU
unresponsive for one second right when the disk was probed. A failed read of the variable at that
moment, given to the probe by a 1-byte file put over it, reproduces it every time.

## Proposed change

In the initrd, retry the read a few times with a short delay before giving up, and say so at the
default log level when it still fails (the machine will not find its root):

```diff
--- a/src/udev/udev-builtin-blkid.c
+++ b/src/udev/udev-builtin-blkid.c
@@ static int find_gpt_root(UdevEvent *event, blkid_probe pr, const char *loop_backing_fname) {
         if (in_initrd()) {
                 /* In the initrd look at the boot loader provided data (and loopback backing fname) to find
                  * our *future* root */
 
-                r = efi_loader_get_device_part_uuid(&esp_or_xbootldr);
+                /* Firmware variable reads fail now and then; without this one the root is never found. */
+                for (unsigned try = 0;; try++) {
+                        r = efi_loader_get_device_part_uuid(&esp_or_xbootldr);
+                        if (r >= 0 || r == -ENOENT || ERRNO_IS_NEG_NOT_SUPPORTED(r) || try >= 10)
+                                break;
+                        (void) usleep_safe(100 * USEC_PER_MSEC);
+                }
                 if (r < 0) {
                         if (r != -ENOENT && !ERRNO_IS_NEG_NOT_SUPPORTED(r))
-                                return log_debug_errno(r, "Unable to determine loader partition UUID: %m");
+                                return log_device_warning_errno(dev, r, "Unable to determine loader partition UUID, cannot find the root partition: %m");
```

An alternative is to let the event fail so that udevd retries it, but builtin results are not
retried today, and the read is the only step here that depends on the firmware.
