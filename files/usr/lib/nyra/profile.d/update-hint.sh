# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=sh
# Read by /etc/profile at the login of an interactive shell (bash or dash), through the link
# /etc/profile.d/update-hint.sh (docs/UPDATES.md, "After a hard reset"). It tells an administrator that
# a version was prepared and then lost, because the computer was reset before the clean shutdown that
# applies it. It only ever reads three small files, runs nothing but `id`, never asks anything and
# never fails visibly: whatever goes wrong, the login goes on without a word.
#
# The message is shown when all of this is true:
#   - the shell is interactive and its input and output are a terminal (not ssh with a command, scp,
#     sftp, a script);
#   - nyra-updated left the version it prepared last in staged-version (it is on /var: a reset loses
#     what bootc keeps in /run), and it is newer than the running one (/usr/lib/os-release);
#   - it is not staged now. bootc's marker for that (/run/composefs/staged-deployment) is root's alone
#     (the directory is 0700), so a login can not look at it. Line 2 of staged-version is the kernel's
#     identifier of the boot that staged the version: in that same boot the version is still staged,
#     and the next restart installs it; in a later boot it was lost (a clean restart would have
#     installed it, and then the running version is not older);
#   - the user is an administrator, decided as `nyra update` decides it (a member of sudo).
# nyra-updated removes staged-version when the version runs or the machine fell back from it, and
# every staging replaces it, so a version that is applied, failed or superseded is not announced.
#
# Everything runs in a subshell, so the user's shell gets no variable and no function from here.
nyra_update_hint() (
	case $- in *i*) ;; *) exit 0 ;; esac
	[ -t 0 ] && [ -t 1 ] || exit 0
	flag=/var/lib/nyra-updated/staged-version
	[ -r "$flag" ] || exit 0
	case " $(/usr/bin/id -nG) " in *" sudo "*) ;; *) exit 0 ;; esac

	# key VERSION: sets k to YEAR.MONTH.BUILD as one number; fails for anything else (the shape that
	# nyra-updated accepts: 4, 1-2 and 1-6 digits, no leading zero, so the arithmetic below never
	# sees an octal number or one too big).
	key() {
		case $1 in *.*.*) ;; *) return 1 ;; esac
		y=${1%%.*}
		r=${1#*.}
		m=${r%%.*}
		b=${r#*.}
		for x in "$y" "$m" "$b"; do
			case $x in '' | *[!0-9]* | 0?*) return 1 ;; esac
		done
		[ "${#y}" -eq 4 ] && [ "${#m}" -le 2 ] && [ "${#b}" -le 6 ] || return 1
		k=$((y * 100000000 + m * 1000000 + b))
	}

	# Both lines, each one possibly without its newline at the end of the file.
	want=
	staged_boot=
	{
		read -r want || :
		read -r staged_boot || :
	} <"$flag"
	key "$want" || exit 0
	wanted=$k
	running=
	while IFS= read -r line; do
		case $line in IMAGE_VERSION=*)
			running=${line#IMAGE_VERSION=}
			break
			;;
		esac
	done </usr/lib/os-release
	running=${running#\"}
	running=${running%\"}
	key "$running" || exit 0
	[ "$k" -lt "$wanted" ] || exit 0

	# Staged in this boot: still staged. No boot identifier, or none to compare with: say nothing.
	[ -n "$staged_boot" ] || exit 0
	boot=
	read -r boot </proc/sys/kernel/random/boot_id || :
	[ -n "$boot" ] && [ "$boot" != "$staged_boot" ] || exit 0

	# shellcheck disable=SC2016 # the backticks are text
	again='Run `nyra update` to prepare it again; nothing is downloaded again.' # the sentence, in one place
	printf '\nVersion %s was prepared, but the update was not finished.\n%s\n\n' "$want" "$again"
)
nyra_update_hint 2>/dev/null || :
unset -f nyra_update_hint
