#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: the terminal editor (docs/DEFAULTS.md, "Terminal editor"), in one boot of the installed
# test disk (QEMU snapshot mode, the disk is not changed):
#   - `editor --version` is the editor's; `editor` is /usr/bin/editor, the alternatives link to
#     /usr/libexec/nyra-editor (root's, mode 755); neither `nano` nor `edit` leads to it;
#   - EDITOR and VISUAL are "editor" in root's login shell (the console's autologin) and in a user's
#     (login(1) on a pseudo-terminal with the password), from /etc/environment, the image's link;
#   - on a pseudo-terminal, as root a file in /etc and as a user a file in the home directory: the
#     editor opens it, a few characters are typed, ^O writes it, ^X ends the editor; the file has
#     the new text and its owner and mode (tools/vm/editor-guest.py).
# There is no sudoedit in the base to try (docs/DEFAULTS.md, "su").
# Each guest command must end with the status of its whole check (vm-boot.py reads only the last
# status), so checks are joined with &&.
#   tools/vm/editor.sh DISK.qcow2 LOGDIR SUMMARY
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
mapfile -t setup < <(put tools/vm/editor-guest.py /var/lib/nyra-test/editor-guest.py)
g='python3 -I /var/lib/nyra-test/editor-guest.py'

files='bad=; for c in nano edit; do p="$(command -v "$c")"; test -z "$p" || test "$(readlink -f "$p")" != /usr/libexec/nyra-editor || bad="$bad $c"; done; echo "leading to the editor:${bad:- nothing but editor}"; test -z "$bad" && v="$(editor --version)" && echo "$v" && case "$v" in "Editor "*" (nyra-editor), "*) ;; *) false ;; esac && test "$(command -v editor)" = /usr/bin/editor && test "$(readlink /usr/bin/editor)" = /etc/alternatives/editor && test "$(readlink /etc/alternatives/editor)" = /usr/libexec/nyra-editor && test "$(stat -c "%a %U %G" /usr/libexec/nyra-editor)" = "755 root root" && echo "editor: /usr/bin/editor -> /etc/alternatives/editor -> /usr/libexec/nyra-editor"'
root_env='echo "root: EDITOR=$EDITOR VISUAL=$VISUAL" && test "$EDITOR" = editor && test "$VISUAL" = editor && test "$(readlink /etc/environment)" = /usr/lib/nyra/environment'
user='useradd -m -s /bin/bash maria && echo "maria:Maria-pw-31" | chpasswd && echo "a user maria with a password"'

python3 -B tools/vm/vm-boot.py --autologin --disk "$disk" --timeout 240 \
  --log "$logs/serial-editor.log" --summary "$summary" \
  --title "Terminal editor" \
  "${setup[@]}" \
  --command "$files" \
  --command "$root_env" \
  --command "$user" \
  --command "$g login maria Maria-pw-31" \
  --command "$g edit root /etc/nyra-editor-test.conf" \
  --command "$g edit maria /var/home/maria/notes.txt"
