#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: SSH and its two-step authentication (docs/DEFAULTS.md, "SSH"), in one boot of the
# installed test disk (QEMU snapshot mode, the disk is not changed):
#   - SSH is off as installed: ssh.service, ssh.socket and sshd-keygen.service disabled and inactive,
#     no systemd-ssh-generator and none of its sockets, nothing on port 22, no host keys, and
#     starting ssh.service does nothing (its condition, /usr/lib/nyra/allow-ssh, is not met); the
#     files of pam-totp are in place and the console's PAM stack (login) does not use its module;
#   - the server turned on for the test only: a drop-in in /run that empties the conditions of
#     ssh.service and sshd-keygen.service (the image has no /usr/lib/nyra/allow-ssh, and /usr is
#     read-only); the host keys are made on start; sshd's settings are the image's;
#   - logins from inside the guest to 127.0.0.1 (tools/vm/ssh-2fa-guest.py, each case from a source
#     address of its own), with a user "maria" and the root account, both with a password and the
#     test key:
#       password and a code, no two-step authentication yet        refused (module: not on)
#       (2fa enable maria, answered with the code of the secret it shows)
#       password, no code                                          refused (module: empty answer)
#       wrong password, right code                                 refused (module: app code
#                                                                  accepted, so pam_unix refused)
#       password and the right code                                accepted (module: app code)
#       the same code again                                        refused (module: already used)
#       key alone                                                  accepted, no code asked
#       root: key; password and right code (2fa enabled for root)  refused
#       (root's answers are never codes: with PermitRootLogin no, OpenSSH's PAM code replaces every
#       answer of root with a fixed wrong string, so the module refuses without seeing the code)
#       console login (login(1), as agetty starts it) with the password only   works
#       failed logins from one address until sshd drops it (PerSourcePenalties), then a key login
#       from another address                                       works
# Each guest command must end with the status of its whole check (vm-boot.py reads only the last
# status), so checks are joined with &&.
#   tools/vm/ssh-2fa.sh DISK.qcow2 LOGDIR SUMMARY
set -euo pipefail

disk="$1" logs="$2" summary="$3"

put() { # guest commands that write the local file $1 to $2, in pieces the console takes
  local b64 i
  b64="$(base64 -w0 <"$1")"
  echo "--command"
  echo "mkdir -p \"\$(dirname $2)\" && : > $2.b64"
  for ((i = 0; i < ${#b64}; i += 1500)); do
    echo "--command"
    echo "printf %s ${b64:i:1500} >> $2.b64"
  done
  echo "--command"
  echo "base64 -d $2.b64 > $2 && rm $2.b64"
}
mapfile -t setup < <(put tools/vm/ssh-2fa-guest.py /var/lib/nyra-test/ssh-2fa-guest.py)
g='python3 -I /var/lib/nyra-test/ssh-2fa-guest.py'

off='e="$(systemctl is-enabled ssh.service ssh.socket sshd-keygen.service | sort -u)"; a="$(systemctl is-active ssh.service ssh.socket sshd-keygen.service | sort -u)"; g="$(systemctl list-units --all --plain --no-legend "sshd-*.socket")"; echo "enabled: $e; active: $a; generated sockets: ${g:-none}"; test "$e" = disabled && test "$a" = inactive && test -z "$g" && test ! -e /usr/lib/systemd/system-generators/systemd-ssh-generator && test -z "$(ss -Htln "sport = :22")" && ! ls /etc/ssh/ssh_host_* 2>/dev/null && systemctl start ssh.service && c="$(systemctl show -P ConditionResult ssh.service)" && echo "ssh.service started, condition result: $c" && test "$c" = no && ! systemctl is-active ssh.service && echo "SSH is off: no host keys, no systemd-ssh-generator, nothing listens, ssh.service does not start without /usr/lib/nyra/allow-ssh"'
files='test "$(readlink /usr/bin/2fa)" = ../libexec/nyra-2fa && test -x /usr/libexec/nyra-2fa && ls -l /usr/lib/*-linux-gnu/security/pam_nyra_totp.so && test "$(stat -c "%a %U %G" /var/lib/nyra/2fa)" = "700 root root" && test "$(readlink /etc/pam.d/sshd)" = /usr/lib/nyra/pam.d/sshd && grep "^auth" /etc/pam.d/sshd && test "$(readlink /etc/ssh/sshd_config.d/10-nyra.conf)" = /usr/lib/nyra/ssh/10-nyra.conf && ! grep -l pam_nyra_totp /etc/pam.d/login /etc/pam.d/common-* && echo "pam-totp in place; the console login does not use its module"'
# Test only: the drop-ins empty every condition of the two units (an empty Condition...= resets them).
on='for u in ssh.service sshd-keygen.service; do mkdir -p "/run/systemd/system/$u.d" && printf "[Unit]\nConditionPathExists=\n" > "/run/systemd/system/$u.d/50-nyra-test.conf"; done; systemctl daemon-reload && systemctl start ssh.service && systemctl is-active ssh.service && ls /etc/ssh/ssh_host_*_key && ss -Htln "sport = :22" | grep -q . && c="$(sshd -T)" && echo "$c" | grep -iE "^(passwordauthentication|kbdinteractiveauthentication|authenticationmethods|permitrootlogin|usepam|persourcepenalties) " && echo "$c" | grep -qix "passwordauthentication no" && echo "$c" | grep -qix "kbdinteractiveauthentication yes" && echo "$c" | grep -qix "authenticationmethods publickey keyboard-interactive:pam" && echo "$c" | grep -qix "permitrootlogin no" && echo "$c" | grep -qix "usepam yes" && echo "$c" | grep -qi "^persourcepenalties crash:" && ! echo "$c" | grep -qix "persourcepenalties no"'
users='useradd -m -s /bin/bash maria && echo "maria:Maria-pw-31" | chpasswd && echo "root:Root-pw-31" | chpasswd && install -d -m 700 /run/nyra-test && ssh-keygen -q -t ed25519 -N "" -f /run/nyra-test/id_ed25519 && install -d -m 700 -o maria -g maria /var/home/maria/.ssh && install -m 600 -o maria -g maria /run/nyra-test/id_ed25519.pub /var/home/maria/.ssh/authorized_keys && install -d -m 700 /root/.ssh && install -m 600 /run/nyra-test/id_ed25519.pub /root/.ssh/authorized_keys && echo "maria and root: a password and the test key"'
journal='journalctl -b --no-pager -o cat | grep -F pam_nyra_totp | tail -n 20; journalctl -b --no-pager -o cat -u ssh.service | grep -i penalt | tail -n 3; true'

python3 -B tools/vm/vm-boot.py --autologin --disk "$disk" --timeout 240 \
  --log "$logs/serial-ssh-2fa.log" --summary "$summary" \
  --title "SSH with two-step authentication (test only: the server turned on)" \
  "${setup[@]}" \
  --command "$off" \
  --command "$files" \
  --command "$on" \
  --command "$users" \
  --command "$g refuse ssh maria 2 Maria-pw-31 000000 'refused: two-step authentication is not on for the user'" \
  --command "$g enable maria" \
  --command "$g refuse ssh maria 3 Maria-pw-31 none 'refused: (empty answer|no answer)'" \
  --command "$g refuse ssh maria 4 Wrong-pw-31 fresh 'accepted: app code'" \
  --command "$g accept ssh maria 5 Maria-pw-31 fresh 'accepted: app code'" \
  --command "$g refuse ssh maria 6 Maria-pw-31 last 'refused: the code was already used'" \
  --command "$g accept key maria 7" \
  --command "$g enable root" \
  --command "$g refuse key root 8" \
  --command "$g refuse ssh root 9 Root-pw-31 fresh 'refused: neither a right app code nor an unused recovery code'" \
  --command "$g login maria Maria-pw-31" \
  --command "$g penalty maria 99 Maria-pw-31" \
  --command "$g accept key maria 10" \
  --command "$journal"
