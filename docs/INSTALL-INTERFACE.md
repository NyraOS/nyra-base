# The installer's interface for programs

`tools/install/nyra-install.sh` can be driven by a program, the text installer of the installer ISO,
instead of a person at a terminal. It is the same script, with the same steps and the same refusals
(docs/INSTALL.md); four subcommands replace the three arguments of the terminal mode and
the questions it asks. The script stays the authority: it checks again everything the program
checked, and refuses what the program got wrong.

This is **protocol version 1**. `check` reports it; a program that does not know the version must not
go on.

All four subcommands run as root, **from a release tree only** (docs/INSTALL.md, "From a release
tree"). The version and the digest of the release are the ones `RELEASE` names; the policy, the trust
roots and the certificate are the tree's. A git checkout is refused by them (it has the terminal mode).

## `check`

Prints one JSON object on stdout, and nothing else, and exits 0; or exits 1 with the reason on stderr
and prints no JSON (a tree that is not the release it says, a certificate that is not the one of
docs/SIGNING.md). The facts about the machine are not refusals: the program decides what to do with them.

```json
{"protocol": 1, "arch": "x86_64", "uefi": true, "secure_boot": true, "shim_checks": true,
 "tpm": true, "mem_tenths": 80, "mem_need_gib": 6, "virt": false,
 "release": {"version": "2026.10.7", "commit": "<40 hex>", "digest": "sha256:<64 hex>",
             "signer": "nyra-image-signer@...", "cert_name": "Nyra OS Secure Boot 2026",
             "fingerprint": "6F:3E:51:...:44:F9"},
 "reserved": ["root", "daemon"]}
```

- `arch`: `x86_64` or `aarch64`. Any other machine is refused.
- `secure_boot`: on, and not in setup mode. `shim_checks`: shim's validation is on (`MokSBState`).
  `tpm`: exactly one TPM2 device, `/dev/tpmrm0`. `virt`: a virtual machine.
- `mem_tenths`: the memory in tenths of a GiB (`80` is 8.0 GiB); `mem_need_gib`: what `install` needs.
- `signer`: the address the signature policy accepts. `fingerprint`: all 32 bytes of the SHA-256
  fingerprint of `nyra.crt`, the certificate that `install` and `mok-import` ask for as a Machine Owner
  Key; it has been checked against docs/SIGNING.md.
- `reserved`: the names of the system, which an administrator cannot take, one per line of the file
  `reserved-names` at the root of the tree (an empty list if the tree has no such file; a file that
  cannot be read, or that is not a regular file, makes `check` fail). Whatever makes the tree writes it
  from the image it contains with `tools/install/reserved-names.sh IMAGE TREE`: the accounts and groups
  of the image, the names its `sysusers.d` files declare, and `root`, sorted, one per line, 0644.
  `install` refuses a name on it, and the image refuses it again.

## `disks`

Prints a JSON array on stdout: the whole disks of the machine (block devices of type `disk`; loop
devices, optical drives and zram are not listed), in the order of `lsblk`.

```json
[{"name": "sda", "path": "/dev/sda", "bytes": 500107862016, "model": "Samsung SSD 870 EVO",
  "serial": "S5H2NJ0N", "wwn": "0x5002538f", "ptuuid": "6f3c1d2e-...", "removable": false,
  "eligible": true, "reason": null,
  "parts": [{"label": "Windows (C:)", "fs": "ntfs", "bytes": 499000000000, "microsoft": true}]}]
```

`eligible` is false, with the first of these in `reason`, when:

| `reason` | when |
|---|---|
| `booted` | a partition or the disk has an `iso9660` file system or a label starting with `NYRA-ISO` |
| `in_use` | anything on it is mounted or is swap |
| `read_only` | it is read-only |
| `too_small` | it is under 32 GB; `min_gb` holds the minimum |

`microsoft` is true for a partition of type "Microsoft reserved" or "Microsoft basic data". `serial`,
`wwn` and `ptuuid` (the GUID of the partition table) are null if the disk has none; with the rest of the
entry they say which disk it is. `fs`, `label` and `model` are text of the disk and are escaped as
JSON: they can hold anything, control characters included, which a program must remove before it
draws them.

## `install --events-fd N --answers-fd M`

Installs. `N` and `M` are two different open descriptors from 3 to 8: the **events**, written by the
script, and the **answers**, read by it. The program starts the script with its standard input,
output and error on the terminal; the script moves its own output to the log and its input to
`/dev/null`, and uses the terminal only for the handoffs. A usage error (descriptors that are not open,
not root) exits 1 with no event. Anything after that is reported as below.

**Answers.** One JSON line on the answers descriptor, once, with exactly these fields:

```json
{"device": "/dev/sda", "confirm": "/dev/sda", "unlock": "tpm",
 "admin_name": "maria", "admin_password": "…"}
```

`confirm` is the path the owner typed (the program puts `/dev/` in front of the name); it must be the
same as `device`, which must be a disk that `disks` lists as eligible right now. `unlock` is `tpm` or `password`; with `password` there
is also `disk_password`. Names are `^[a-z][a-z0-9_-]{0,31}$`, not `root` and not in `reserved`.
Passwords are 12 to 64 printable ASCII characters; paths are `/dev/` and 1 to 32 more characters from
`A-Za-z0-9._-`. The line is at most 4096 characters and exactly one JSON value: a line with several
values, a key twice, a field more or less, or anything after the object is refused. The script parses
it once and takes the verdict and the fields from that one reading.

- The line is read into a variable, checked by `jq` through a pipe and dropped. It is never an
  argument, never in the environment, never in the log.
- `unlock: password` makes the disk open with `disk_password` instead of the TPM (no TPM is needed; Secure
  Boot is). Before anything is written, `password-memory` asks whether this machine can derive the key from a
  password with at least 256 MiB of memory (otherwise `fail` `verify`, exit 10). The password goes from the
  variable to a file in `/run/nyra-install` (mode 0600, memory only), the variable is cleared, `password-add`
  reads the file as key slot 1 (argon2id, at least 256 MiB; the key slots are 0 the key of the installation,
  1 the password, 2 the recovery key) and the file is deleted at once. It is never an argument, never in the
  environment, never in the log, never on the terminal. At the end `wipe-install-slot` removes key slot 0
  only (it checks that the key of the installation unlocks nothing afterwards) and the header must be exactly
  the recovery key and the one password slot (`check_luks_header_password`).
- The administrator is made at the first boot of the installed system, not by the installer: the image's
  own tools turn the password into a yescrypt hash before the disk is touched (`admin-record`, which gets
  the password on the standard input of the container, never as an argument or in the environment), and
  `NAME:HASH` goes into the new system as `/var/lib/nyra/first-admin` (docs/BOOT.md, "The first
  administrator and the fixed defaults"). The system then starts with `en_US.UTF-8`, the US keyboard, UTC
  and the host name `nyra`, and asks nothing. A name or a password that the image refuses is a failure
  of `verify`, before the first write.
- A wrong `confirm` is refused before anything is written, like a disk that is not eligible.
- The whole entry of `disks` for the chosen disk is kept, and checked again after the image is pulled,
  just before the first write: it must be identical (the same model, size, serial, partitions), or
  the installation stops with `fail` `verify` and exit 10. A different disk that took the name in the
  meantime is not erased.
- The terminal is looked at before that, too: if `/dev/tty` cannot be opened, or the process is not in
  its foreground process group, the installation stops with exit 10 and nothing is written.

**Events.** One JSON object per line on the events descriptor. Nothing of the text a person reads is in
them: that is in the log.

| Event | Meaning |
|---|---|
| `{"event":"step","id":ID,"state":"start"}` and `"done"` | `ID` is `verify` (the machine, the answers, the image and its signature), `prepare` (partitions, LUKS), `install` (the image), `protect` (the recovery key, the TPM, the header, the boot files), `final` (the Secure Boot key). In this order, one at a time. |
| `{"event":"disk-changed"}` | just before the first write, once, in `prepare` |
| `{"event":"handoff","id":"recovery-key"}` or `"mok-password"` | the script needs the terminal (below); in `protect` and in `final` |
| `{"event":"handoff-end"}` | it is done with the terminal |
| `{"event":"fail","id":ID,"disk_changed":BOOL}` | the last event of a failure. `ID` is `verify` (before the first write), `memory` (the machine has less than `mem_need_gib`), `write` (`prepare` or `install`), `protect` or `mok` (`final`). `disk_changed` is true if `disk-changed` was ever sent |
| `{"event":"done"}` | the last event of a success |

**Handoff.** The recovery key must be shown on the terminal (the owner presses Enter once it is written down), and `mokutil` asks for a
one-time password: neither goes through the program, a pipe or the log. The script emits `handoff`,
and **waits for a line `go` on the answers descriptor** (anything else is a failure). The program then
leaves the terminal in its normal mode and writes `go`; the script runs the step on `/dev/tty`, clears
the screen and its scroll-back, and emits `handoff-end`. The process must be in the foreground process
group of that terminal while this lasts, as a shell's job is. A failure during a handoff clears the
screen too. The recovery key is shown once and written nowhere; nothing is typed back and nothing is checked
against the disk, as in the terminal mode. `handoff-end` means the owner pressed Enter, so the program
waits for it and needs no result about the key.

**Exit status.** 0 success. **10: failed before the first write, the disk is as it was.** **11: failed
after it; the disk must be installed again from the start.** 1 is a usage error. A script that dies
without sending `fail` (killed) leaves it to the program to assume the worse: 11. `SIGTERM` and `SIGINT`
stop it like any failure (when the step it waits for ends: signal its process group to stop it sooner);
before `disk-changed` that is exit 10.

**Log.** `/run/nyra-installer/install.log` (memory, mode 0600, appended to). It holds the script's
output and its reasons for refusing. It holds no secret: none is an argument or in the environment, the
recovery key and the password of `mokutil` are on the terminal, and `podman` runs the steps that show
them with `--log-driver=none`.

## `mok-import --events-fd N --answers-fd M`

Requests the import of `nyra.crt` as a Machine Owner Key (for an owner who missed the blue screen at
the first boot). The certificate is the tree's, not an installed disk's, and has been checked against
docs/SIGNING.md. It reads no answers but `go`. Events: `handoff` (`mok-password`), `handoff-end`, `done`;
or `fail` with `id` `mok` and `disk_changed` false (exit 10). A key that is already enrolled is not a
failure; the handoff says so.

## What is tested

`tools/install/test-machine-interface.sh` (offline, in the shellcheck workflow) runs the script on a
terminal with stand-ins for the machine and the steps of the image: the JSON of `check` and `disks`;
the events of a whole installation in order, and the status, the id and `disk_changed` of a failure at
each step; the refusal, with the disk's first MiB unchanged, of a wrong confirmation, of a disk that
is in use, read-only, too small or the one the machine started from, of a disk that was mounted
during the pull or replaced by another one (another model and size) under the same name, of a machine
without Secure Boot, a TPM or memory, of answers that are incomplete, hold two values or a key twice,
have trailing text or are too long, and of an installation without a terminal; that
the recovery key is on the terminal after `go` and in no file, event or log; that the administrator's
password reaches the image on the standard input of its container (and a copy that puts it on the
command line is caught), the record is made before the disk is touched and is given to the step that
installs the system, and a record that fails is a failure of `verify` with the disk as it was; and that
no password is in an argument, the environment, `ps` or any file, the disk password included (a copy that writes
it to the log is found by the same search); an installation with a password runs on a machine without a TPM, and
the steps of the password fail as the steps of the TPM do (the disk changed, status 11). The real steps are tested as before
(`tools/install/test-recovery-key.sh`, `tools/install/test-verified-pull.sh`,
`tools/vm/install-encrypted.sh`); a whole installation from the installer ISO, with the real steps, is tested by the `iso-install` job (docs/ISO.md, "The installation test").
