#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: Titanic T3, a new version that breaks the network, on its own copy of the installed test
# disk (docs/UPDATES.md, "The network"). Set up like tools/vm/updates.sh: everything the guest trusts
# is made for this run (an image signing key standing in for the keyless signer, a channel sheet key
# baked only into the test versions, a CA for the sheet server), and the guest reaches the runner as
# updates.nyraos.com: the registry on port 80, a sheet server on 443 that serves whichever signed
# sheet the guest selects.
#
# Test versions (2026.12.N, the version in the manifest annotation bootc reads):
#   g1 2026.12.1  good
#   b2 2026.12.2  the wired network without DHCP and without router advertisements: the link comes
#                 up with carrier but never gets a routable address
#   b3 2026.12.3  the same as b2
# The boots:
#   1    installed image: test trust set up; switch to g1 by its channel tag
#   2    g1: the network check has nothing recorded yet; an update check records the link with its
#        address; b2 staged
#   3-6  b2 gets no address within 60 s and fails the network check, three times; systemd-boot
#        falls back to g1, which checks the network too (the boot after a failed trial) and passes;
#        b2 is marked failed and refused; b3 staged
#   7    b3 with the cable unplugged (no carrier): the network check does not judge it, the boot is
#        healthy and blessed, b3 is not marked failed
#   tools/vm/network-health.sh IMAGE DISK.qcow2 WORKDIR LOGDIR SUMMARY
set -euo pipefail

image="$1" disk="$2" work="$3" logs="$4" summary="$5"
PS4='+ network-health.sh:$LINENO: '
set -x
u="$work/network-health"
mkdir -p "$u/context" "$u/sheets"

# --- keys ------------------------------------------------------------------------------------------
openssl genpkey -algorithm ed25519 -out "$u/sheet.key"
openssl pkey -in "$u/sheet.key" -pubout -out "$u/context/channel-sheet.pem"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 -subj /CN=nyra-test-ca \
  -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign \
  -keyout "$u/ca.key" -out "$u/ca.crt" 2>/dev/null
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj /CN=updates.nyraos.com \
  -keyout "$u/server.key" -out "$u/server.csr" 2>/dev/null
openssl x509 -req -in "$u/server.csr" -CA "$u/ca.crt" -CAkey "$u/ca.key" -CAcreateserial -days 2 \
  -extfile <(printf 'subjectAltName=DNS:updates.nyraos.com\nextendedKeyUsage=serverAuth\n') \
  -out "$u/server.crt" 2>/dev/null
echo nyra-network-health-test >"$u/pass"
sudo podman run --rm --network none -v "$u:/u:z" "$image" \
  skopeo generate-sigstore-key --output-prefix /u/sigstore --passphrase-file /u/pass >/dev/null
sudo chown -R "$(id -u):$(id -g)" "$u"

# --- test versions ---------------------------------------------------------------------------------
# Each with its own UKI, built as in tools/vm/updates.sh.
cat >"$u/kernel-from-uki.py" <<'EOF'
import sys
import pefile
pe = pefile.PE(sys.argv[1])
for s in pe.sections:
    name = {b".linux": "vmlinuz", b".initrd": "initramfs.img"}.get(s.Name.rstrip(b"\0"))
    if name:
        with open(f"{sys.argv[2]}/{name}", "wb") as f:
            f.write(s.get_data()[:s.Misc_VirtualSize])
EOF
version() { # version NAME VERSION [Containerfile lines]
  printf 'FROM %s\nRUN rm -rf /boot/EFI\nCOPY channel-sheet.pem /usr/lib/nyra/updates/channel-sheet.pem\nRUN echo %s > /usr/lib/nyra-test-version && echo "stage_timeout_seconds = 90" >> /usr/lib/nyra/updates/updated.conf\n%s\n' \
    "$image" "$2" "${3:-}" >"$u/Containerfile.$1"
  sudo podman build -q -t "localhost/nyra-net:$1-rootfs" -f "$u/Containerfile.$1" "$u/context" >/dev/null
  mkdir -p "$u/$1-uki"
  sudo podman run --rm --network none --tmpfs /tmp --tmpfs /var/tmp \
    --mount "type=image,source=localhost/nyra-net:$1-rootfs,target=/target" \
    -v "$u/kernel-from-uki.py:/kernel-from-uki.py:ro" -v "$u/$1-uki:/out" "$image" \
    sh -c 'u="$(ls /boot/EFI/Linux/*.efi)" && k="$(basename "$u" .efi)" && mkdir -p "/tmp/kernel/$k" &&
      python3 /kernel-from-uki.py "$u" "/tmp/kernel/$k" &&
      bootc container ukify --rootfs /target --kernel-dir "/tmp/kernel/$k" -- --output "/out/$k.efi"' >/dev/null
  printf 'FROM localhost/nyra-net:%s-rootfs\nCOPY --from=uki . /boot/EFI/Linux/\n' "$1" |
    sudo podman build -q --annotation "org.opencontainers.image.version=$2" -t "localhost/nyra-net:$1" \
      --build-context uki="$u/$1-uki" -f - "$u/context" >/dev/null
}
# The broken network: the image's wired network without DHCP and router advertisements, so the link
# has carrier and only an IPv6 link-local address. The network check and health-failed also print
# to the console, so the serial log shows each try.
broken="$(cat <<'EOF'
RUN printf '%s\n' '[Match]' 'Name=en* eth*' '[Network]' 'DHCP=no' 'IPv6AcceptRA=no' \
      > /usr/lib/systemd/network/80-nyra-wired.network && \
    for s in nyra-health-network nyra-updated-health-failed; do \
      mkdir -p "/usr/lib/systemd/system/$s.service.d" && \
      printf '%s\n' '[Service]' 'StandardOutput=journal+console' 'StandardError=journal+console' \
        > "/usr/lib/systemd/system/$s.service.d/50-test-console.conf" || exit 1; done
EOF
)"
version g1 2026.12.1
version b2 2026.12.2 "$broken"
version b3 2026.12.3 "$broken"

# A fresh registry, as in tools/vm/updates.sh.
sudo podman rm -f nyra-test-registry >/dev/null 2>&1 || true
tools/signing/local-registry.sh "$u"
sudo mkdir -p /etc/containers/registries.d
printf 'docker:\n  updates.nyraos.com:\n    use-sigstore-attachments: true\n' |
  sudo tee /etc/containers/registries.d/99-nyra-updates-test.yaml >/dev/null
push() { # push NAME TAG: signed; a push that stalls is tried again (tools/vm/updates.sh)
  local try
  for try in 1 2 3; do
    sudo timeout 120 podman push -q --tls-verify=false --format oci --digestfile "$u/$1.digest" \
      --sign-by-sigstore-private-key "$u/sigstore.private" --sign-passphrase-file "$u/pass" \
      "localhost/nyra-net:$1" "docker://updates.nyraos.com/nyra-base:$2" && break
    echo "::warning::podman push of $1 failed or took more than 2 minutes (attempt $try of 3)"
    if [ "$try" = 3 ]; then echo "::error::podman push of $1 failed 3 times"; return 1; fi
  done
  sudo chown "$(id -u):$(id -g)" "$u/$1.digest"
  [[ "$(cat "$u/$1.digest")" =~ ^sha256:[0-9a-f]{64}$ ]]
}
push g1 stable
push b2 b2
push b3 b3
g1="$(cat "$u/g1.digest")" b2="$(cat "$u/b2.digest")" b3="$(cat "$u/b3.digest")"

# --- signed channel sheets -------------------------------------------------------------------------
sheet() { # sheet NAME SEQUENCE DIGEST VERSION
  local type=application/vnd.nyra.channel-sheet.v1+json now
  now="$(date +%s)"
  jq -cnj --argjson seq "$2" --argjson t "$now" --arg d "$3" --arg v "$4" \
    '{schema: 1, repository: "nyra-base", channel: "stable", sequence: $seq, issued_at: $t,
      expires_at: ($t + 604800), current: {digest: $d, version: $v}, previous: null, percent: 100,
      halted: false, retracted: []}' >"$u/payload"
  { printf 'DSSEv1 %d %s %d ' ${#type} "$type" "$(wc -c <"$u/payload")"; cat "$u/payload"; } >"$u/pae"
  openssl pkeyutl -sign -inkey "$u/sheet.key" -rawin -in "$u/pae" -out "$u/sig"
  jq -cn --arg t "$type" --arg p "$(base64 -w0 <"$u/payload")" --arg s "$(base64 -w0 <"$u/sig")" \
    '{payloadType: $t, payload: $p, signatures: [{keyid: "", sig: $s}]}' >"$u/sheets/$1"
}
sheet s1 100 "$g1" 2026.12.1
sheet s2 200 "$b2" 2026.12.2
sheet s3 300 "$b3" 2026.12.3

cat >"$u/sheet-server.py" <<'EOF'
import http.server, os, ssl, sys
sheets, cert, key = sys.argv[1:4]
state = {"sheet": "none"}

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/_test/select/"):
            state["sheet"] = os.path.basename(self.path)
            return self.answer(b"ok\n")
        if self.path == "/channels/nyra-base/stable":
            return self.answer(open(os.path.join(sheets, state["sheet"]), "rb").read())
        self.send_error(404)
    def answer(self, body):
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 443), Handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
server.socket = ctx.wrap_socket(server.socket, server_side=True)
server.serve_forever()
EOF
sudo python3 -I "$u/sheet-server.py" "$u/sheets" "$u/server.crt" "$u/server.key" &
trap 'sudo pkill -f "$u/sheet-server.py" || true' EXIT
for _ in $(seq 30); do curl -fs --cacert "$u/ca.crt" https://updates.nyraos.com/_test/select/s1 >/dev/null && break; sleep 1; done
curl -fsS --cacert "$u/ca.crt" https://updates.nyraos.com/channels/nyra-base/stable | jq -e .payloadType >/dev/null

set +x
# --- the guest ---------------------------------------------------------------------------------------
cp "$disk" "$u/disk.qcow2"
n=0
vm() { # vm TITLE [vm-boot.py options and --command ...]
  n=$((n + 1))
  python3 -B tools/vm/vm-boot.py --autologin --persist --poweroff --disk "$u/disk.qcow2" --timeout 240 \
    --log "$logs/serial-network-health-$n.log" --summary "$summary" --title "Network health, boot $n: $1" "${@:2}"
}
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
lib='. /var/lib/nyra-test/lib.sh'
state() { # state PYTHON_EXPRESSION: true of nyra-updated's state s
  echo "python3 -c 'import json, sys; s = json.load(open(\"/var/lib/nyra-updated/state.json\")); print(s); sys.exit(not ($1))'"
}
# The network check's result and what it said on this boot.
said='systemctl show -P Result nyra-health-network.service && journalctl -b -u nyra-health-network -o cat --no-pager'
cat >"$u/policy.json" <<'EOF'
{
  "default": [{ "type": "insecureAcceptAnything" }],
  "transports": {
    "docker": {
      "updates.nyraos.com": [
        {
          "type": "sigstoreSigned",
          "keyPath": "/etc/nyra-test/sigstore.pub",
          "signedIdentity": { "type": "matchRepository" }
        }
      ]
    }
  }
}
EOF
printf '[[registry]]\nlocation = "updates.nyraos.com"\ninsecure = true\n' >"$u/99-nyra-test.conf"
mapfile -t setup < <(
  put tools/vm/updates-guest.sh /var/lib/nyra-test/lib.sh
  put "$u/policy.json" /etc/nyra-test/policy.json
  put "$u/sigstore.pub" /etc/nyra-test/sigstore.pub
  put "$u/ca.crt" /usr/local/share/ca-certificates/nyra-test.crt
  put "$u/99-nyra-test.conf" /etc/containers/registries.conf.d/99-nyra-test.conf
)

vm "installed image: test trust; switch to g1" \
  "${setup[@]}" \
  --command 'echo "10.0.2.2 updates.nyraos.com" >> /etc/hosts && update-ca-certificates >/dev/null 2>&1' \
  --command 'ln -sfn /etc/nyra-test/policy.json /etc/containers/policy.json' \
  --command "$lib; running && bootc switch --quiet updates.nyraos.com/nyra-base:stable && expect staged $g1"

vm "g1: the link recorded with its address; b2 (broken network) staged" \
  --command "$lib; expect booted $g1 && running && blessed" \
  --command "$said | grep -F 'nothing to compare' && ! test -e /var/lib/nyra-updated/network-links" \
  --command 'systemctl show -p PrivateNetwork -p RestrictAddressFamilies -p CapabilityBoundingSet nyra-health-network.service && test "$(systemctl show -P PrivateNetwork nyra-health-network.service)" = no && test "$(systemctl show -P RestrictAddressFamilies nyra-health-network.service | tr " " "\n" | sort | xargs)" = "AF_NETLINK AF_UNIX" && test -z "$(systemctl show -P CapabilityBoundingSet nyra-health-network.service)"' \
  --command "$lib; outcome s1 UpToDate" \
  --command 'cat /var/lib/nyra-updated/network-links && test -s /var/lib/nyra-updated/network-links && (for l in $(cat /var/lib/nyra-updated/network-links); do networkctl list --no-legend --no-pager "$l" | grep -w routable || exit 1; done)' \
  --command "$lib; outcome s2 Staged && expect staged $b2"

vm "b2 gets no address three times, back on g1 by itself" --boots 4 --timeout 600 \
  --command "$lib; expect booted $g1 && running && test \"\$(queued)\" = true" \
  --command "$said | grep -F 'a routable address as before' && ! test -e /var/lib/nyra-updated/network-failed" \
  --command "$lib; outcome s2 RollbackUndone && test \"\$(queued)\" = false && expect rollback $b2 && $(state "\"$b2\" in s[\"failed\"]")" \
  --command "$lib; refused s2 'this machine fell back from it' && expect staged none" \
  --command "$lib; outcome s3 Staged && expect staged $b3"
l="$logs/serial-network-health-$n.log"
grep -a -e 'no routable address after' -e 'nyra-updated health-failed:' "$l" || true
echo "kernel starts: $(grep -ac 'Linux version' "$l"), network checks failed: $(grep -ac 'no routable address after 60 s' "$l"), full reboots by nyra-updated: $(grep -ac 'nyra-updated health-failed: Reboot' "$l")"
[ "$(grep -ac 'Linux version' "$l")" = 4 ] && [ "$(grep -ac 'no routable address after 60 s' "$l")" = 3 ] &&
  [ "$(grep -ac 'nyra-updated health-failed: Reboot' "$l")" = 3 ]

# Without a carrier systemd-networkd-wait-online may fail (degraded): not this test's concern.
vm "b3 without a cable: not judged, healthy and blessed" --no-carrier \
  --command 'systemctl is-system-running --wait; systemctl --no-pager --failed; true' \
  --command "$lib; expect booted $b3 && blessed && systemctl is-active boot-complete.target" \
  --command 'networkctl list --no-legend --no-pager && networkctl list --no-legend --no-pager | grep -w no-carrier' \
  --command "$said | grep -F 'not judged' && test \"\$(systemctl show -P Result nyra-health-network.service)\" = success" \
  --command "$(state "\"$b3\" not in s[\"failed\"] and \"$b2\" in s[\"failed\"]")"
