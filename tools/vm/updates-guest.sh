# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=sh
# CI only: shell helpers for the guest in tools/vm/updates.sh, sourced from /var/lib/nyra-test.
# bootc status --format json is canonical (sorted keys, one line): in .status, "booted" comes before
# "rollback", "rollbackQueued" and "staged", and nothing after "staged" holds an image digest.

deployment() { # booted | staged | rollback: that deployment's part of bootc status
	s="$(bootc status --format json)"
	case "$1" in
	booted) s="$(bootc status --booted --format json)" ;;
	staged) s="${s##*'"staged":'}" ;;
	rollback)
		s="${s##*'"rollback":'}"
		s="${s%%'"rollbackQueued"'*}"
		;;
	esac
	printf '%s' "$s"
}

digest() { # booted | staged | rollback: that deployment's image digest, or "none"
	d="$(deployment "$1" | grep -o '"imageDigest":"[^"]*"' | head -1 | cut -d'"' -f4)"
	echo "${d:-none}"
}

expect_version() { # expect_version booted|staged|rollback VERSION: the version bootc reports for it
	v="$(deployment "$1" | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4)"
	echo "$1 version: ${v:-none}"
	[ "$v" = "$2" ]
}

expect() { # expect booted|staged|rollback DIGEST|none
	d="$(digest "$1")"
	echo "$1: $d"
	[ "$d" = "$2" ]
}

queued() { # the rollback deployment is the next boot: true or false
	bootc status --format json | grep -o '"rollbackQueued":[a-z]*' | cut -d: -f2
}

running() {
	s="$(systemctl is-system-running --wait)"
	echo "system: $s"
	systemctl --no-pager --failed
	[ "$s" = running ] && return 0
	# If it is the network: systemd-networkd's own account (debug level on the test disk).
	networkctl status --all --no-pager
	journalctl -b -u systemd-networkd -u systemd-networkd-wait-online -o short-monotonic --no-pager | tail -150
	return 1
}

entries() { ls /boot/loader/entries; }

blessed() { # no boot counter left: every entry is good
	entries
	! entries | grep -qF +
}

select_sheet() { # what the test sheet server answers at /channels/nyra-base/stable
	# -k: this is the test's own control request, which must work with a wrong clock too (T9).
	curl -kfsS "https://updates.nyraos.com/_test/select/$1" >/dev/null
}

run_check() { # nyra-updated check, as the timer starts it; prints last-check.json
	systemctl start nyra-updated.service
	rc=$?
	cat /var/lib/nyra-updated/last-check.json
	echo
	return $rc
}

without_key() { # without_key COMMAND...: COMMAND runs with an empty channel sheet key file (a bind mount over the
	# image's real key, undone afterwards): the fail-closed case of an image with no key
	key=/usr/lib/nyra/updates/channel-sheet.pem
	: >/run/nyra-test-no-key && mount --bind /run/nyra-test-no-key "$key" || return 1
	"$@"
	rc=$?
	umount "$key"
	return $rc
}

outcome() { # outcome SHEET PATTERN: the check succeeds with a result matching PATTERN
	select_sheet "$1" && run_check && grep -q -- "$2" /var/lib/nyra-updated/last-check.json
}

no_success_since() { # no_success_since DAYS: last-check.json says the last successful check was
	# DAYS days ago, as if updates had stopped then
	python3 -c 'import json, sys, time
p = "/var/lib/nyra-updated/last-check.json"
r = json.load(open(p))
r["last_success"] = int(time.time()) - int(sys.argv[1]) * 86400
json.dump(r, open(p, "w"))' "$1"
}

refused() { # refused SHEET REGEX: the check fails with an error matching REGEX (grep -E)
	select_sheet "$1" || return 1
	! run_check && grep -q '"ok":false' /var/lib/nyra-updated/last-check.json &&
		grep -qE -- "$2" /var/lib/nyra-updated/last-check.json
}

refused_switch() { # refused_switch IMAGE PATTERN: bootc switch fails with an error matching PATTERN
	out="$(bootc switch --quiet "$1" 2>&1)"
	rc=$?
	echo "$out"
	[ $rc != 0 ] && printf '%s' "$out" | grep -q -- "$2"
}

install_refused() { # install_refused VERSION PATTERN: nyra-updated install fails with a message matching PATTERN
	out="$(/usr/libexec/nyra-updated install "$1" 2>&1)"
	rc=$?
	echo "$out"
	[ $rc != 0 ] && printf '%s' "$out" | grep -q -- "$2"
}

wait_pidfile() { # wait_pidfile USER: the shell of USER has written its PID to /var/tmp/pid-USER; sets pid
	for _ in $(seq 30); do
		[ -s "/var/tmp/pid-$1" ] && pid="$(cat "/var/tmp/pid-$1")" && return 0
		sleep 1
	done
	echo "no process of $1"
	return 1
}

process_of() { # process_of USER: sets pid to a process of USER started from the root console: it has no
	# session of its own (it stays in root's, on the serial port, which has no seat)
	rm -f "/var/tmp/pid-$1"
	# shellcheck disable=SC2016 # the quoted script is the user's, $$ is its shell
	(runuser -u "$1" -- sh -c 'echo $$ >"/var/tmp/pid-$1"; exec sleep 60' sh "$1" >/dev/null 2>&1 </dev/null &)
	wait_pidfile "$1"
}

session_of() { # session_of USER: USER logged in on virtual console 5 (an autologin getty), which is a session
	# of seat0 as at a machine's screen; sets pid to their shell. polkit counts a session as local only with
	# a seat (docs/LESSONS.md), so only such a session is a local and active one for the rules.
	h="$(getent passwd "$1" | cut -d: -f6)"
	rm -f "/var/tmp/pid-$1"
	# The shell only keeps the session open; in_session puts commands into the session's scope.
	# shellcheck disable=SC2016 # the quoted script is the user's, $$ is its shell
	printf 'echo $$ >/var/tmp/pid-%s\nwhile :; do\n\tsleep 1\ndone\n' "$1" >"$h/.profile"
	mkdir -p /run/systemd/system/getty@tty5.service.d
	# shellcheck disable=SC2016 # $TERM is for systemd
	printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin %s --noclear - $TERM\n' "$1" \
		>/run/systemd/system/getty@tty5.service.d/autologin.conf
	systemctl daemon-reload && systemctl start getty@tty5.service && wait_pidfile "$1" || return 1
	sid="$(sed -n 's|.*/session-\(.*\)\.scope$|\1|p' "/proc/$pid/cgroup")"
	loginctl activate "$sid" # may return before logind reports it
	for _ in $(seq 30); do
		[ "$(loginctl show-session "$sid" -p Active --value)" = yes ] && break
		sleep 1
	done
	v="$(loginctl show-session "$sid" -p Seat -p Active -p Remote -p TTY)"
	echo "session $sid of $1, shell $pid: $v"
	echo "$v" | grep -qx Seat=seat0 && echo "$v" | grep -qx Active=yes && echo "$v" | grep -qx Remote=no
}

session_end() { # the login on virtual console 5 ends, and its session with it
	systemctl stop getty@tty5.service
	kill "$pid"
	rm -rf /run/systemd/system/getty@tty5.service.d
	systemctl daemon-reload
	for _ in $(seq 30); do
		loginctl show-session "$sid" >/dev/null 2>&1 || return 0
		sleep 1
	done
	echo "session $sid is still there"
	return 1
}

in_session() { # in_session USER COMMAND: COMMAND runs as USER inside the scope of the session that session_of
	# started (the process moves itself into the scope, as a login's processes are in it, so logind and polkit
	# count it as part of the session on seat0, not of the root console); prints its output, returns its exit
	# status. It does not wait for anything: a session that is gone fails at once.
	scope="$(sed -n 's|^0::||p' "/proc/$pid/cgroup")"
	case "$scope" in *session-*.scope) [ -w "/sys/fs/cgroup$scope/cgroup.procs" ] ;; *) false ;; esac || {
		echo "the session of $1 has no scope: '$scope'"
		return 1
	}
	sh -c 'echo $$ >"/sys/fs/cgroup$1/cgroup.procs" && exec runuser -u "$2" -- sh -c "$3"' sh "$scope" "$1" "$2" </dev/null
}

# What systemd sends polkit as "polkit.message" for StartUnit (a unit that exists) and for StartTransientUnit
# (systemd-run, run0), which asks with the same unit and verb (49-nyra.rules).
start_message="Authentication is required to start '\$(unit)'."
transient_message="Authentication is required to start transient unit '\$(unit)'."

polkit_ask() { # polkit_ask WANT ACTION [UNIT VERB [MESSAGE]]: what polkit answers for the process $pid, asked with
	# pkcheck as root, since only root may pass details (UNIT, VERB, MESSAGE) to polkit: 0 yes, 1 no, 2 a
	# password would be asked (nobody can answer here)
	if [ -n "$5" ]; then
		pkcheck --process "$pid" --action-id "$2" --detail unit "$3" --detail verb "$4" --detail polkit.message "$5"
	elif [ -n "$3" ]; then
		pkcheck --process "$pid" --action-id "$2" --detail unit "$3" --detail verb "$4"
	else
		pkcheck --process "$pid" --action-id "$2"
	fi
	rc=$?
	echo "polkit: $2 $3 $4: $rc, wanted $1"
	[ "$rc" = "$1" ]
}

polkit_typed() { # polkit_typed PASSWORD: for the process $pid (of vmadmin), pkcheck as root asks polkit to start
	# the install unit and vmadmin's own authentication agent (pkttyagent, on a terminal that this function
	# makes) asks for a password; PASSWORD is typed at every prompt. Prints what the agent says; sets rc to
	# pkcheck's exit status: 0 only when polkit took the password as the proof asked for (the user's own,
	# since root has none), never when it is wrong; 124: no end within a minute.
	# The agent must run as the user: polkitd takes the user of the agent's subject as the one who made it,
	# and the password helper reports the user of its caller (the agent); with pkcheck's own agent, run as
	# root for the process of another user, the two differ and polkitd answers "No session for cookie" to a
	# right password. A user's own agent (systemctl's, a desktop's) is the case that matters.
	python3 -I -c 'import os, pty, pwd, select, subprocess, sys, time
user, password, pid, message = sys.argv[1:5]
r, w = os.pipe()
os.set_inheritable(w, True)
agent, fd = pty.fork()
if agent == 0:
    pw = pwd.getpwnam(user)
    os.initgroups(user, pw.pw_gid)
    os.setgid(pw.pw_gid)
    os.setuid(pw.pw_uid)
    os.close(r)
    os.execvp("pkttyagent", ["pkttyagent", "--process", pid, "--notify-fd", str(w)])
os.close(w)
select.select([r], [], [], 30)  # the agent closes it once it is registered
check = subprocess.Popen(["pkcheck", "--process", pid, "--action-id", "org.freedesktop.systemd1.manage-units",
                          "--detail", "unit", "nyra-updated-install@2026.10.600.service",
                          "--detail", "verb", "start", "--detail", "polkit.message", message,
                          "--allow-user-interaction"])
end = time.time() + 60
prompt = b""
while True:
    done = check.poll() is not None
    if not done and time.time() > end:
        check.kill()
        check.wait()
        break
    if not select.select([fd], [], [], 0 if done else 0.2)[0]:
        if done:
            break
        continue
    try:
        data = os.read(fd, 4096)
    except OSError:
        break
    sys.stdout.buffer.write(data)
    sys.stdout.flush()
    prompt += data
    if b"Password:" in prompt:
        time.sleep(0.3)  # the agent clears the terminal input right after it shows the prompt
        os.write(fd, password.encode() + b"\n")
        prompt = b""
os.kill(agent, 15)
os.waitpid(agent, 0)
sys.exit(124 if time.time() > end else check.returncode)' vmadmin "$1" "$pid" "$start_message"
	rc=$?
	echo "polkit with a typed password: $rc"
}

polkit_diagnose() { # what the password helper, polkitd and the PAM stack say, for a typed password that fails
	journalctl -b --no-pager -o cat -u 'polkit-agent-helper@*' -u polkit.service -t polkit-agent-helper-1 | tail -n 40
	systemctl status polkit-agent-helper.socket --no-pager
	cat /etc/pam.d/polkit-1 /usr/lib/pam.d/polkit-1 2>&1
}

polkit_user() { # polkit_user WANT: for the process $pid, polkit answers WANT to starting the install unit
	# (with the message of a plain start) and no to all else of systemd's manager (without the rule these
	# would ask for a password)
	m=org.freedesktop.systemd1
	i=nyra-updated-install@2026.10.600.service
	polkit_ask "$1" $m.manage-units $i start "$start_message" || return 1
	# the same unit and verb, as systemd-run and run0 ask for a new unit of that name that runs any command
	# (the one difference is the message), or without a message: no
	polkit_ask 1 $m.manage-units $i start "$transient_message" || return 1
	polkit_ask 1 $m.manage-units $i start || return 1
	for verb in stop restart try-restart reload kill; do
		polkit_ask 1 $m.manage-units $i $verb "$start_message" || return 1
	done
	# systemd-run asks for manage-units with the verb and unit it will start; without them the answer is
	# still no (the rule needs both)
	polkit_ask 1 $m.manage-units &&
		polkit_ask 1 $m.manage-units nyra-updated-install@evil.service start "$start_message" &&
		polkit_ask 1 $m.manage-units ssh.service start "$start_message" &&
		polkit_ask 1 $m.manage-unit-files &&
		polkit_ask 1 $m.reload-daemon &&
		polkit_ask 1 $m.set-environment
}

polkit_cases() { # 49-nyra.rules: a member of sudo in a local and active session is asked for their own
	# password to start the install unit; no seat, or not in sudo: no (1); root: yes (0)
	pw=correct-test-password-1
	echo "vmadmin:$pw" | chpasswd || return 1
	process_of vmadmin && polkit_user 1 &&
		process_of vmuser && polkit_user 1 &&
		session_of vmuser && polkit_user 1 && session_end &&
		session_of vmadmin && polkit_user 2 && polkit_own_password "$pw" &&
		no_root_command vmadmin nyra-updated-install@2026.10.601.service && session_end &&
		pid=$$ && polkit_ask 0 org.freedesktop.systemd1.manage-units ssh.service start "$transient_message"
}

polkit_own_password() { # polkit_own_password PASSWORD: in the session of vmadmin the install unit needs vmadmin's
	# own password (AUTH_SELF): typing it gives yes. Root has no password, so a rule that asked for an
	# administrator's (AUTH_ADMIN) could never give yes this way. A wrong one does not.
	polkit_typed "$1"
	[ "$rc" = 0 ] || {
		polkit_diagnose
		return 1
	}
	polkit_typed wrong-password
	[ "$rc" = 1 ] || [ "$rc" = 3 ] || {
		polkit_diagnose
		return 1
	}
}

untrusted_tls() { # the sheet server's certificate is no longer trusted (a spoofed server)
	select_sheet "$1" || return 1
	mv /usr/local/share/ca-certificates/nyra-test.crt /var/lib/nyra-test/
	update-ca-certificates --fresh >/dev/null 2>&1
	! run_check && grep -q 'SSL certificate' /var/lib/nyra-updated/last-check.json
	rc=$?
	mv /var/lib/nyra-test/nyra-test.crt /usr/local/share/ca-certificates/
	update-ca-certificates >/dev/null 2>&1
	return $rc
}

network() { # network down|up: the guest's only network link, down or up again (a cable pulled out,
	# plugged in); waits until systemd-networkd reports the machine offline or online
	dev="$(ip -o link show | awk -F': ' '$2 != "lo" { print $2; exit }')"
	want=offline
	[ "$1" = up ] && want=online
	ip link set dev "$dev" "$1" || return 1
	for _ in $(seq 60); do
		state="$(busctl get-property org.freedesktop.network1 /org/freedesktop/network1 org.freedesktop.network1.Manager OnlineState)"
		if [ "$state" = "s \"$want\"" ]; then
			echo "$dev $1: networkd reports $want"
			return 0
		fi
		sleep 1
	done
	echo "$dev $1: networkd still reports $state"
	return 1
}

offline_reported() { # offline_reported DIGEST: the last check found no network and said so, as a
	# warning: the unit did not fail and DIGEST is not marked failed
	grep -q '"ok":false' /var/lib/nyra-updated/last-check.json &&
		grep -q 'no network connection' /var/lib/nyra-updated/last-check.json &&
		journalctl -b -u nyra-updated -p warning -o cat | grep 'no network connection' &&
		! systemctl is-failed --quiet nyra-updated.service &&
		python3 -c 'import json, sys; sys.exit(sys.argv[1] in json.load(open("/var/lib/nyra-updated/state.json")).get("failed", []))' "$1"
}

synced() { # synced NOT_BEFORE: within 4 minutes, ntpd-rs set the clock through NTS; it reads between
	# NOT_BEFORE (the runner's time when this boot started) and 10 minutes later. ntpd-rs's first
	# update can take up to eight answers from three servers, which it asks every 16 s.
	for _ in $(seq 240); do
		now="$(date +%s)"
		[ "$now" -ge "$1" ] && [ "$now" -lt $(($1 + 600)) ] && break
		sleep 1
	done
	ntp-ctl -c /usr/lib/nyra/ntpd-rs/ntp.toml status
	date -u
	now="$(date +%s)"
	if ! { [ "$now" -ge "$1" ] && [ "$now" -lt $(($1 + 600)) ]; }; then
		journalctl -b -u ntpd-rs -o short-monotonic --no-pager | tail -50
		return 1
	fi
}

not_synced() { # ntpd-rs tried for 30 s and did not set the clock
	sleep 30
	ntp-ctl -c /usr/lib/nyra/ntpd-rs/ntp.toml status
	journalctl -b -u ntpd-rs -o short-monotonic --no-pager | tail -20
	systemctl is-active ntpd-rs.service && ! journalctl -b -u ntpd-rs -o cat --no-pager | grep -F 'Jumped offset'
}

no_root_command() { # no_root_command USER UNIT: USER, in their session (session_of USER), can not run a command
	# as root with systemd-run (named UNIT, a name that the rule gives a password prompt for as a unit that
	# exists) or run0: polkit refuses at once ("Access denied", not a request for a password), and the
	# command did not run. First the control: the real `systemctl start` of that unit name (another version)
	# is answered with a request for authentication (no password is given: --no-ask-password), so the
	# polkit rule gives it a password prompt, which a changed message of systemd would break, and the
	# denial below comes from the rule and not from something else.
	in_session "$1" "timeout 60 systemctl start --no-ask-password nyra-updated-install@2026.10.602.service" >/var/tmp/no-root-command 2>&1
	rc=$?
	echo "systemctl start: $rc: $(cat /var/tmp/no-root-command)"
	[ "$rc" != 0 ] && grep -qi 'requires interactive authentication' /var/tmp/no-root-command &&
		! systemctl is-active --quiet "nyra-updated-install@2026.10.602.service" || return 1
	rm -f /var/tmp/ran-systemd-run /var/tmp/ran-run0
	in_session "$1" "timeout 60 systemd-run --unit=$2 --wait /usr/bin/touch /var/tmp/ran-systemd-run" >/var/tmp/no-root-command 2>&1
	rc=$?
	echo "systemd-run: $rc: $(cat /var/tmp/no-root-command)"
	denied_without_running /var/tmp/no-root-command /var/tmp/ran-systemd-run "$2" || return 1
	command -v run0 >/dev/null || { echo "no run0 in the image"; return 0; }
	in_session "$1" "timeout 60 run0 /usr/bin/touch /var/tmp/ran-run0" >/var/tmp/no-root-command 2>&1
	rc=$?
	echo "run0: $rc: $(cat /var/tmp/no-root-command)"
	denied_without_running /var/tmp/no-root-command /var/tmp/ran-run0
}

denied_without_running() { # denied_without_running OUTPUT MARKER [UNIT]: the last command (status rc) failed with a denial, never asked for a
	# password, did not create MARKER, and left no unit UNIT
	[ "$rc" != 0 ] && grep -qiE 'access denied|not authorized' "$1" &&
		! grep -qiE 'authentication|password' "$1" && [ ! -e "$2" ] &&
		{ [ -z "$3" ] || ! systemctl is-active --quiet "$3"; }
}
