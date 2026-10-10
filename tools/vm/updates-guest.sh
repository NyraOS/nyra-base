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
