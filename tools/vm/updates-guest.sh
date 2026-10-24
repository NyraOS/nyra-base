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
	printf 'echo $$ >/var/tmp/pid-%s\nexec sleep 300\n' "$1" >"$h/.profile"
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

polkit_ask() { # polkit_ask WANT ACTION [UNIT VERB]: what polkit answers for the process $pid, asked with
	# pkcheck as root, since only root may pass details (UNIT, VERB) to polkit: 0 yes, 1 no, 2 a
	# password would be asked (nobody can answer here)
	if [ -n "$3" ]; then
		pkcheck --process "$pid" --action-id "$2" --detail unit "$3" --detail verb "$4"
	else
		pkcheck --process "$pid" --action-id "$2"
	fi
	rc=$?
	echo "polkit: $2 $3 $4: $rc, wanted $1"
	[ "$rc" = "$1" ]
}

polkit_user() { # polkit_user WANT: for the process $pid, polkit answers WANT to starting the install unit
	# and no to all else of systemd's manager (without the rule these would ask for a password)
	m=org.freedesktop.systemd1
	polkit_ask "$1" $m.manage-units nyra-updated-install@2026.10.600.service start &&
		polkit_ask 1 $m.manage-units nyra-updated-install@2026.10.600.service stop &&
		polkit_ask 1 $m.manage-units nyra-updated-install@evil.service start &&
		polkit_ask 1 $m.manage-units ssh.service start &&
		polkit_ask 1 $m.manage-unit-files &&
		polkit_ask 1 $m.reload-daemon &&
		polkit_ask 1 $m.set-environment
}

polkit_cases() { # 49-nyra.rules: a member of sudo in a local and active session is asked for their own
	# password (2) to start the install unit; no seat, or not in sudo: no (1); root: yes (0)
	process_of vmadmin && polkit_user 1 &&
		process_of vmuser && polkit_user 1 &&
		session_of vmuser && polkit_user 1 && session_end &&
		session_of vmadmin && polkit_user 2 && session_end &&
		pid=$$ && polkit_ask 0 org.freedesktop.systemd1.manage-units ssh.service start
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

no_root_command() { # no_root_command USER UNIT: USER can not run a command as root with systemd-run (named UNIT) or run0
	out="$(timeout 60 runuser -u "$1" -- systemd-run --unit="$2" --wait /bin/true 2>&1)"
	rc=$?
	echo "systemd-run: $rc: $out"
	[ $rc != 0 ] || return 1
	! systemctl is-active --quiet "$2" || return 1
	command -v run0 >/dev/null || { echo "no run0 in the image"; return 0; }
	out="$(timeout 60 runuser -u "$1" -- run0 /bin/true 2>&1)"
	rc=$?
	echo "run0: $rc: $out"
	[ $rc != 0 ]
}
