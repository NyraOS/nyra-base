# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=sh
# CI only: shell helpers for the guest in tools/vm/updates.sh, sourced from /var/lib/nyra-test.
# bootc status --format json is canonical (sorted keys, one line): in .status, "booted" comes before
# "rollback", "rollbackQueued" and "staged", and nothing after "staged" holds an image digest.

digest() { # booted | staged | rollback: that deployment's image digest, or "none"
	s="$(bootc status --format json)"
	case "$1" in
	booted) s="$(bootc status --booted --format json)" ;;
	staged) s="${s##*'"staged":'}" ;;
	rollback)
		s="${s##*'"rollback":'}"
		s="${s%%'"rollbackQueued"'*}"
		;;
	esac
	d="$(printf '%s' "$s" | grep -o '"imageDigest":"[^"]*"' | head -1 | cut -d'"' -f4)"
	echo "${d:-none}"
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
