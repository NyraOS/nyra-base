#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: runs in the guest of tools/vm/security-defaults.sh (docs/DEFAULTS.md, "Firewall"). Containers
# and the inbound default deny: a port published by a rootful container (netavark's DNAT in prerouting,
# so the traffic is forwarded, not delivered to a local socket) and the container network itself are
# reached from outside the host's own addresses (a network namespace joined by a veth pair, as in the
# firewall probe there) exactly as far as the policy says:
#   - a rootful published port answers on this machine (127.0.0.1 and its own address) and not from the
#     network; neither does the container's own address, with a route to it through this machine
#   - a rootless published port (pasta) the same
#   - a container still reaches the network, and the answers come back
# The container image is this system's /usr in a directory root (no registry, no network needed).
# Exit status 0 when every check held. SKIP_ROOTLESS=1 skips the rootless part (a rehearsal without a
# user of its own); PODMAN replaces the podman command line (a rehearsal with a store of its own).
set -u
cd /

podman="${PODMAN:-podman}"
dir="${CPORTS_DIR:-/var/tmp/cports}"
fail=0

expect() { # expect WANT GOT WHAT
	if [ "$1" = "$2" ]; then
		echo "ok: $3 ($2)"
	else
		echo "FAILED: $3: got $2, want $1"
		fail=1
	fi
}
# The HTTP status a client gets from a server, 000 when nothing answers within 4 s (a dropped packet).
status() { curl -s -m 4 -o /dev/null -w '%{http_code}' "$@" || true; }
# The same from the probe network namespace, which is outside this machine's addresses.
outside() { ip netns exec cports curl -s -m 4 -o /dev/null -w '%{http_code}' "$@" || true; }
wait_local() { # wait_local URL: the server answers on this machine
	for _ in $(seq 30); do
		[ "$(status "$1")" = 200 ] && return 0
		sleep 1
	done
	return 1
}

# The "outside": a veth pair into a network namespace, with a server there for the containers to reach.
ip netns add cports && ip link add c0 type veth peer name c1 netns cports &&
	ip addr add 198.51.100.1/24 dev c0 && ip link set c0 up &&
	ip -n cports addr add 198.51.100.2/24 dev c1 && ip -n cports link set c1 up &&
	ip -n cports link set lo up || {
	echo "FAILED: the probe network namespace"
	exit 1
}
mkdir -p "$dir/www" && echo outside >"$dir/www/index.html"
ip netns exec cports python3 -m http.server 9000 --bind 198.51.100.2 --directory "$dir/www" >/dev/null 2>&1 &
server=$!
mkroot() { # mkroot DIR: an empty directory root with /usr to mount over, the layout of a merged-/usr system
	mkdir -p "$1/usr" "$1/tmp" && ln -sfn usr/bin "$1/bin" && ln -sfn usr/lib "$1/lib" && ln -sfn usr/lib64 "$1/lib64"
}
mkroot "$dir/root"

chain="$(nft list chain inet nyra forward 2>&1)"
echo "$chain"
echo "$chain" | grep -q "policy drop"
expect 0 $? "the forward chain of inet nyra has policy drop"
input="$(nft list chain inet nyra input 2>&1)"
echo "$input" | grep -q "policy drop"
expect 0 $? "the input chain of inet nyra has policy drop"

# --- rootful: a published port, and the container's outbound network ------------------------------------
$podman rm -f cports-web >/dev/null 2>&1
$podman run -d --name cports-web -p 8081:8081 --rootfs -v /usr:/usr:ro "$dir/root" /usr/bin/python3 -m http.server 8081 --bind 0.0.0.0 >/dev/null
expect 0 $? "a rootful container publishing 8081 starts"
if wait_local http://127.0.0.1:8081/; then
	expect 200 "$(status http://127.0.0.1:8081/)" "rootful published port, from this machine (127.0.0.1)"
	expect 200 "$(status http://198.51.100.1:8081/)" "rootful published port, from this machine (its own address)"
	expect 000 "$(outside http://198.51.100.1:8081/)" "rootful published port, from the network"
	cip="$($podman inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' cports-web)"
	echo "container address: $cip"
	expect 1 "$(echo "$cip" | grep -c '^[0-9.]*$')" "the container has an address"
	ip -n cports route add 10.88.0.0/16 via 198.51.100.1
	expect 000 "$(outside "http://$cip:8081/")" "the container's own address, from the network (routed through this machine)"
	# Control: an explicit accept rule opens the port, so the drop above was the forward chain.
	nft insert rule inet nyra forward iifname c0 tcp dport 8081 accept
	expect 200 "$(outside http://198.51.100.1:8081/)" "rootful published port, from the network, with an accept rule in the forward chain"
	h="$(nft -a list chain inet nyra forward | sed -n 's/.*iifname "c0".*# handle \([0-9]*\)$/\1/p')"
	nft delete rule inet nyra forward handle "$h"
	expect 000 "$(outside http://198.51.100.1:8081/)" "rootful published port, from the network, with the rule removed"
else
	echo "FAILED: the published port 8081 does not answer on this machine"
	$podman logs cports-web 2>&1 | tail -5
	fail=1
fi
out="$($podman run --rm --rootfs -v /usr:/usr:ro "$dir/root" /usr/bin/python3 -c \
	"import urllib.request; print(urllib.request.urlopen('http://198.51.100.2:9000/', timeout=8).read().decode().strip())" 2>&1)"
echo "$out" | tail -3
expect outside "$(echo "$out" | tail -1)" "a rootful container reaches the network (outbound)"
# A network of its own (a second bridge, podman1 or the next free name) reaches out as well.
$podman network create --disable-dns cports-net >/dev/null
out="$($podman run --rm --network cports-net --rootfs -v /usr:/usr:ro "$dir/root" /usr/bin/python3 -c \
	"import urllib.request; print(urllib.request.urlopen('http://198.51.100.2:9000/', timeout=8).read().decode().strip())" 2>&1)"
echo "$out" | tail -3
expect outside "$(echo "$out" | tail -1)" "a rootful container on a network of its own reaches the network (outbound)"
$podman network rm cports-net >/dev/null 2>&1
$podman rm -f cports-web >/dev/null 2>&1

# --- rootless: a published port ----------------------------------------------------------------------------
if [ -n "${SKIP_ROOTLESS:-}" ]; then
	echo "skipped: the rootless published port (SKIP_ROOTLESS)"
elif ! command -v pasta >/dev/null 2>&1 && ! command -v slirp4netns >/dev/null 2>&1; then
	echo "skipped: the rootless published port (the image has neither pasta nor slirp4netns, so podman cannot publish a port as a user)"
else
	id cports >/dev/null 2>&1 || useradd -m cports || fail=1
	uid="$(id -u cports)"
	# A user's container root must belong to that user (the user namespace maps no other owner).
	mkroot "$dir/user-root" && chown -R cports "$dir/user-root"
	install -d -o cports -m 700 "/run/user/$uid"
	user() { runuser -u cports -- env HOME=/home/cports XDG_RUNTIME_DIR="/run/user/$uid" "$@"; }
	user podman run -d --name cports-user --cgroups=disabled -p 8082:8082 --rootfs -v /usr:/usr:ro "$dir/user-root" \
		/usr/bin/python3 -m http.server 8082 --bind 0.0.0.0 >/dev/null
	expect 0 $? "a rootless container publishing 8082 starts"
	if wait_local http://127.0.0.1:8082/; then
		expect 200 "$(status http://127.0.0.1:8082/)" "rootless published port, from this machine (127.0.0.1)"
		expect 000 "$(outside http://198.51.100.1:8082/)" "rootless published port, from the network"
	else
		echo "FAILED: the published port 8082 does not answer on this machine"
		user podman logs cports-user 2>&1 | tail -5
		fail=1
	fi
	user podman rm -f cports-user >/dev/null 2>&1
fi

nft list chain inet nyra forward
kill "$server" 2>/dev/null
ip netns del cports
rm -rf "$dir"
exit "$fail"
