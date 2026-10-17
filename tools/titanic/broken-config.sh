#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only (titanic.yml): Titanic T8, the configuration broken by the user (docs/TITANIC.md). One
# system on a copy of the installed test disk, with Secure Boot on (tools/titanic/secure-boot-system.sh):
#   1    a user, an administrator with a password, and a file in their home; control: the user logs
#        in with the password (su through PAM, run as the user so that it has to ask), a wrong one is
#        refused, and the network works (a file served by the runner, through QEMU's 10.0.2.2); then
#        the daily copy of /etc (nyra-etc-copy.service)
#   2-5  each of these on its own, then a reboot:
#          2  /etc/fstab: a line that is not a mount, and a disk that is not connected
#          3  /etc/passwd: every system account deleted (root and the user kept), a line that is not
#             an account
#          4  the network: the wired network's settings replaced in /etc with a wrong static address,
#             /etc/resolv.conf replaced with a wrong name server
#          5  /etc/systemd/system: everything deleted (the services enabled there), then systemd-resolved,
#             ntpd-rs, the firewall and the update timer masked
#        Expected: the system boots to a login prompt. What happens is in the step summary and the
#        serial logs: the system state, the failed units, the basic services, the network, whether the
#        user can log in, the notice a failed health check leaves on the console, and the warnings of
#        the boot. A boot that does not reach the login prompt fails the step. Then the
#        "Nyra OS Restore earlier settings" entry is picked for the next boot (bootctl set-oneshot, as
#        a user would in the boot menu), which offers the copy from boot 1; 1 restores it, and the
#        normal boot after it must be healthy: /etc/fstab, /etc/passwd (but the user's line), the
#        network settings, /etc/resolv.conf and /etc/systemd/system are the copy's, the user logs in
#        with their password (a wrong one is refused), the network works, the basic services are
#        active, the shadow sync ran and succeeded, Secure Boot and the lockdown on (serial logs
#        serial-broken-config-<n>-restore.log). The next breakage starts from that system.
#   6    all four at once; the "Nyra OS Recovery" entry is picked for the next boot
#   7    that boot: recovery asks for an administrator although /etc/passwd has no nobody (the
#        password is checked as the administrator, by UID); a wrong password gives no shell, the right
#        one a root shell in rescue.target; the shadow sync failed on the line that is not an account;
#        then "Nyra OS Restore earlier settings" is picked for the next boot
#   8    that boot: the copy from boot 1 restored; the normal boot after it is healthy (as above) and
#        the file in /home is the same; then all four broken again, "Nyra OS Reset settings" picked
#   9    that boot: RESET; the system restarts by itself into the normal boot: /etc/fstab,
#        /etc/passwd (plus the user's line), the network settings, /etc/resolv.conf and
#        /etc/systemd/system are the image's; the file in /home is the same; healthy (as above).
# Before each restore entry, copies the daily timer may have made since boot 1 (at midnight, of a
# broken /etc) are removed, so that the one offered is boot 1's.
# One unit is checked on every boot with a shell: bootc's shadow sync
# (bootc-sysusers-shadow-sync.service) failed on 3 and 7, where /etc/passwd has a line it cannot
# parse, for that reason; it ran and succeeded on all the others.
# Every boot runs even if one before it failed; the step fails if any did. The password is random,
# for this throwaway disk only.
#   tools/titanic/broken-config.sh IMAGE DISK.qcow2 UKI_CERT WORKDIR LOGDIR SUMMARY
set -euo pipefail

image="$1" disk="$2" uki_cert="$3" work="$4" logs="$5" summary="$6"
t8="$work/broken-config"
# shellcheck source=tools/titanic/secure-boot-system.sh
. tools/titanic/secure-boot-system.sh "$image" "$disk" "$uki_cert" "$t8" "$summary"

user=nyra-t8 pw="$(openssl rand -hex 12)" token="$(openssl rand -hex 8)"
# The network check: a file served by the runner, which the guest reaches as 10.0.2.2.
mkdir -p "$t8/www"
echo "$token" > "$t8/www/t8"
python3 -m http.server 8088 --bind 127.0.0.1 --directory "$t8/www" > "$t8/http.log" 2>&1 &

# --- guest commands (as in tools/titanic/secure-boot-system.sh) -----------------------------------
units="systemd-journald.service dbus.service systemd-logind.service systemd-networkd.service systemd-resolved.service ntpd-rs.service nyra-firewall.service apparmor.service nyra-updated.timer"
net="curl -fsS --max-time 10 http://10.0.2.2:8088/t8 | grep -qx $token"
# The user's password through PAM: su, run as the user so that it has to ask, reads it from its input.
# By UID: su (sudo-rs) refuses to run for a user it cannot look up, and the broken /etc/passwd has no
# nobody, but the user's line stays.
su="setpriv --reuid=\$(id -u $user) --regid=\$(id -g $user) --clear-groups -- su -c id -- $user"
login_ok="printf '%s\\n' '$pw' | $su | grep '^uid=[0-9]*($user)'"
login_wrong="! printf 'wrong\\n' | $su"
# bootc's shadow sync (it removes /etc/shadow and /etc/gshadow lines of accounts that are gone) stops
# before it changes anything when /etc/passwd has a line it cannot parse: the unit fails. That is the
# only failure of it T8 allows, with that reason, on the boots with that line; everywhere else it ran
# and succeeded.
shadow_unit=bootc-sysusers-shadow-sync.service
shadow_ok="test \"\$(systemctl is-active $shadow_unit)\" = active && echo '$shadow_unit: ran and succeeded'"
shadow_refused="systemctl is-failed -q $shadow_unit && journalctl -b -u $shadow_unit --no-pager | grep -F 'failed to parse passwd entry' && echo '$shadow_unit: failed as expected, on the line that is not an account in /etc/passwd'"

break_fstab='mkdir -p /var/mnt/data && printf "a line that is not a mount\nLABEL=nyra-t8-data /var/mnt/data ext4 defaults 0 2\n" >> /etc/fstab && cat /etc/fstab'
break_passwd="grep -E '^(root|$user):' /etc/passwd > /var/tmp/passwd && echo 'a line that is not an account' >> /var/tmp/passwd && cat /var/tmp/passwd > /etc/passwd && rm /var/tmp/passwd && cat /etc/passwd"
break_network='mkdir -p /etc/systemd/network && printf "[Match]\nName=en* eth*\n[Network]\nAddress=192.0.2.10/24\nGateway=192.0.2.1\nDNS=192.0.2.53\n" > /etc/systemd/network/80-nyra-wired.network && rm -f /etc/resolv.conf && echo "nameserver 192.0.2.53" > /etc/resolv.conf && cat /etc/systemd/network/80-nyra-wired.network /etc/resolv.conf'
break_services='rm -rf /etc/systemd/system/* && systemctl mask systemd-resolved.service ntpd-rs.service nyra-firewall.service nyra-updated.timer && ls -lR /etc/systemd/system'

# What a broken system does after it booted; only shown, never a failure.
observe="s=\"\$(timeout 150 systemctl is-system-running --wait)\"; echo \"system: \$s\"; systemctl --no-pager --failed; for u in $units; do echo \"\$u: \$(systemctl is-active \$u)\"; done; ip -br address; ip route; if $net; then echo 'network: the runner answers'; else echo 'network: the runner does not answer'; fi; if $login_ok; then echo '$user: logs in with the password'; else echo '$user: cannot log in'; fi; cat /run/issue.d/50-nyra-health.issue 2>/dev/null; journalctl -b -p warning -o short-monotonic --no-pager | tail -n 40; true"
# /etc after the reset: the broken paths are the image's (seen under the bind mount of /etc through a
# bind mount of / alone, as the reset itself does), /etc/passwd with the user's line added.
image_etc="i=/run/nyra-t8-image; f=0; mkdir -p \$i && mount --bind / \$i && mount -o remount,bind,ro \$i || f=1; for p in fstab passwd systemd/system systemd/network resolv.conf; do if test \$p = passwd; then grep -v '^$user:' /etc/passwd | diff \$i/etc/passwd - || f=1; elif test -e \$i/etc/\$p || test -L \$i/etc/\$p; then diff -r --no-dereference \$i/etc/\$p /etc/\$p || f=1; elif test -e /etc/\$p || test -L /etc/\$p; then echo \"/etc/\$p is not in the image\"; f=1; fi; done; umount \$i; test \$f = 0 && echo '/etc/fstab, /etc/passwd (plus the user), the network settings, /etc/resolv.conf and /etc/systemd/system are the image'\"'\"'s'"

# /etc after "Restore earlier settings": the broken paths are those of the copy made in boot 1
# (/etc/passwd without the user's line: accounts come from the current /etc, not from the copy).
copies=/var/lib/nyra/etc-copies
copy_etc="c=$copies/\$(cat /var/nyra-t8-copy); f=0; for p in fstab passwd systemd/system systemd/network resolv.conf; do if test \$p = passwd; then grep -v '^$user:' \$c/passwd > /run/nyra-t8-p1; grep -v '^$user:' /etc/passwd | diff /run/nyra-t8-p1 - || f=1; elif test -e \$c/\$p || test -L \$c/\$p; then diff -r --no-dereference \$c/\$p /etc/\$p || f=1; elif test -e /etc/\$p || test -L /etc/\$p; then echo \"/etc/\$p is not in the copy\"; f=1; fi; done; test \$f = 0 && echo '/etc/fstab, /etc/passwd, the network settings, /etc/resolv.conf and /etc/systemd/system are the copy'\"'\"'s'"
# The daily timer may make a copy of a broken /etc at a boot after midnight: before each restore,
# every copy but boot 1's is removed, so that the one offered is boot 1's.
only_copy="c=\"\$(cat /var/nyra-t8-copy)\"; for x in \$(ls $copies); do test \"\$x\" = \"\$c\" || rm -rf \"$copies/\$x\"; done; ls $copies; test \"\$(ls $copies)\" = \"\$c\""
restore_next='bootctl set-oneshot nyra-restore.CONF && echo "next boot: Restore earlier settings (as picked in the boot menu)"'
restore_answer='\(daily copy\)(.|\n)*Type the number of the copy to restore, anything else or Control-D to boot normally: '
# What the restore (and the reset) must bring back.
healthy=(--command "$running" --command "$login_ok && $login_wrong && echo '$user logs in with the password, a wrong one is refused'" --command "$net && echo 'the network works: the runner answers'" --command "systemctl is-active $units" --command "$shadow_ok" --command "$secure")

answer='Type RESET to reset, anything else or Control-D to boot normally: '
fail=0

vm --poweroff --log "$logs/serial-broken-config-1.log" \
  --title "Broken configuration 1: a user with a password and a file in /home; a copy of /etc" \
  --command "$running" \
  --command "$shadow_ok" \
  --command "$secure" \
  --command "useradd -m -G sudo -s /bin/bash $user && printf '$user:%s\\n' '$pw' | chpasswd && echo $token > /home/$user/keep.txt && chown $user: /home/$user/keep.txt && ls -l /home/$user" \
  --command "$login_ok && $login_wrong && echo '$user logs in with the password, a wrong one is refused (control)'" \
  --command "$net && echo 'the network works: the runner answers (control)'" \
  --command "systemctl start nyra-etc-copy.service && ls $copies | grep -- '-daily\$' | sort | tail -n 1 > /var/nyra-t8-copy && echo \"the daily copy: \$(cat /var/nyra-t8-copy)\"" || fail=1

# Each breakage on its own: does it boot? Then "Restore earlier settings" with the copy from boot 1,
# which must repair it, so that the next breakage starts from a healthy system again.
rows=""
n=2
for what in fstab passwd network services; do
  case "$what" in
    fstab) title="/etc/fstab: a line that is not a mount, a disk that is not connected" b="$break_fstab" ;;
    passwd) title="/etc/passwd: the system accounts deleted, a line that is not an account" b="$break_passwd" ;;
    network) title="the network: a wrong static address, a wrong name server" b="$break_network" ;;
    services) title="/etc/systemd/system: emptied, then 4 services masked" b="$break_services" ;;
  esac
  shadow="$shadow_ok"
  [ "$what" != passwd ] || shadow="$shadow_refused"
  if vm --poweroff --log "$logs/serial-broken-config-$n.log" \
      --title "Broken configuration $n: $title; the next boot; Restore earlier settings picked" \
      --command "$b" --command '@reboot systemctl reboot' --command "$observe" --command "$shadow" \
      --command "$only_copy" --command "$restore_next"; then
    row="| $title | boots to a login prompt |"
  else
    row="| $title | **does not boot to a login prompt, or the shadow sync is not as expected** (serial-broken-config-$n.log) |"
    fail=1
  fi
  if vm --poweroff --log "$logs/serial-broken-config-$n-restore.log" --chat "$restore_answer=>1" --chat-then-login \
      --title "Broken configuration $n: Restore earlier settings (the copy from boot 1), then the normal boot" \
      --command "$copy_etc" "${healthy[@]}"; then
    rows+="$row the copy from before repairs it |"$'\n'
  else
    rows+="$row **the copy from before does not repair it** (serial-broken-config-$n-restore.log) |"$'\n'
    fail=1
  fi
  n=$((n + 1))
done

vm --poweroff --log "$logs/serial-broken-config-6.log" \
  --title "Broken configuration 6: all of it at once; Recovery picked for the next boot" \
  --command "$shadow_ok" \
  --command "$break_services" \
  --command "$break_network" \
  --command "$break_passwd" \
  --command "$break_fstab" \
  --command 'bootctl set-oneshot nyra-recovery.CONF && echo "next boot: Recovery (as picked in the boot menu)"' || fail=1

# Recovery checks the password through su run as the administrator, by UID: /etc/passwd has no nobody now.
again='Wrong user name or password, or not an administrator\.(.|\n)*Administrator user name: '
if vm --poweroff --log "$logs/serial-broken-config-7.log" \
    --chat "Administrator user name: =>$user" --chat "Password: =>wrong-$token" \
    --chat "$again=>$user" --chat "Password: =>$pw" \
    --title "Broken configuration 7: Recovery without the system accounts; Restore earlier settings picked for the next boot" \
    --command 'id; test "$(id -u)" = 0 && grep -q "systemd.unit=rescue.target" /proc/cmdline && systemctl is-active rescue.target' \
    --command '! grep "^nobody:" /etc/passwd && echo "/etc/passwd has no nobody"' \
    --command "$shadow_refused" \
    --command "$only_copy" \
    --command "$restore_next"; then
  recovery="recovery asks for an administrator and opens a root shell for the right password, without the system accounts"
else
  recovery="**recovery did not work without the system accounts** (serial-broken-config-7.log)"
  fail=1
fi

if vm --poweroff --log "$logs/serial-broken-config-8.log" --chat "$restore_answer=>1" --chat-then-login \
    --title "Broken configuration 8: Restore earlier settings, the normal boot; then all of it broken again, Reset settings picked" \
    --command "$copy_etc" \
    --command "test \"\$(cat /home/$user/keep.txt)\" = $token && test \"\$(stat -c %U /home/$user/keep.txt)\" = $user && echo 'the file in /home is the same'" \
    "${healthy[@]}" \
    --command "$break_services" \
    --command "$break_network" \
    --command "$break_passwd" \
    --command "$break_fstab" \
    --command 'bootctl set-oneshot nyra-reset.CONF && echo "next boot: Reset settings (as picked in the boot menu)"'; then
  restore="the copy from before repairs all of it: the system runs, the user logs in, the network works"
else
  restore="**the copy from before did not repair all of it** (serial-broken-config-8.log)"
  fail=1
fi

if vm --poweroff --log "$logs/serial-broken-config-9.log" --chat "$answer=>RESET" --chat-then-login \
    --title "Broken configuration 9: Reset settings, then the normal boot" \
    --command "$image_etc" \
    --command "test \"\$(cat /home/$user/keep.txt)\" = $token && test \"\$(stat -c %U /home/$user/keep.txt)\" = $user && echo 'the file in /home is the same'" \
    "${healthy[@]}"; then
  reset="the reset brings the image's settings back: the system runs, the user logs in, the network works"
else
  reset="**the reset did not bring the system back** (serial-broken-config-9.log)"
  fail=1
fi

{
  echo "### Configuration broken by the user (Titanic T8)"
  echo
  echo "| Broken | Before the restore | Restore earlier settings |"
  echo "|---|---|---|"
  printf '%s' "$rows"
  echo
  echo "All of it at once, then Recovery: $recovery."
  echo
  echo "Then Restore earlier settings: $restore."
  echo
  echo "All of it broken again, then Reset settings: $reset."
  echo
} >> "$summary"

exit "$fail"
