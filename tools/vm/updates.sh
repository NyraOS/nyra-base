#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: nyra-updated across real updates, on a copy of the installed test disk (docs/UPDATES.md).
# Titanic T2 (power cuts), T3 (a broken version), T4 (signatures and versions), T5 (a hostile
# network), the discard of a staged deployment (bootc rollback twice) and blessing after a soft reboot.
#
# Everything the guest trusts is made for this run and deleted with the runner: an image signing key
# (sigstore, the stand-in for our keyless signer: the guest's /etc/containers/policy.json is replaced
# by the shipped policy with this key), a channel sheet key (baked into the test versions'
# /usr/lib/nyra/updates/channel-sheet.pem, never into the image CI builds), and a CA for the TLS
# certificate of the sheet server. The guest reaches the runner as 10.0.2.2, which /etc/hosts on the
# test disk names updates.nyraos.com: the registry (tools/signing/local-registry.sh, plain HTTP) on
# port 80 and a sheet server on 443 that serves whichever signed sheet the guest selects.
#
# Test versions of IMAGE (v1-v7: 2026.10.1-7, the version in the manifest annotation bootc reads;
# v3 has a health check that always fails; v0 is unsigned), and the boots:
#   1  installed image: no sheet key, fail closed; unsigned refused by the shipped policy; test trust
#      set up; unsigned and wrongly signed refused; switch to v0 from another registry
#   2  v0: a foreign image, reported (ForeignImage); switch to v1 by its channel tag
#   3  v1: a sheet signed with another key refused; power cut while v2 downloads
#   4  v1: v2 staged again; power cut before the staged version is finalized
#   5  v1: v2 staged again; clean shutdown
#   6  power cut when v2's kernel starts (first try)
#   7  v2, second try, blessed; v4 staged, then retracted: discarded (bootc rollback twice)
#   8  v2 again (boot order kept); v3 staged
#   9  v3 fails its health check and reboots by itself, three times; systemd-boot falls back to v2;
#      v3 is marked failed and refused; v5 staged
#  10  v5, first try: captive portal, spoofed server, downgrade, replayed sheet refused; soft reboot
#      into v6: not blessed, system not degraded
#  11  v6, first full boot: signed retraction below the version floor refused; retraction to the
#      local rollback deployment (v5) uses bootc rollback
#  12  v5, registry down: refused, nothing staged
#  13  v5, a corrupted layer of v7 in the registry: refused, nothing staged
#  14  v5, another image's valid layer served for v7's: refused, nothing staged
#  15  v5, registry repaired: v7 staged
#   tools/vm/updates.sh IMAGE DISK.qcow2 WORKDIR LOGDIR SUMMARY
set -euo pipefail

image="$1" disk="$2" work="$3" logs="$4" summary="$5"
u="$work/updates"
mkdir -p "$u/context" "$u/sheets"

# --- keys ------------------------------------------------------------------------------------------
openssl genpkey -algorithm ed25519 -out "$u/sheet.key"
openssl pkey -in "$u/sheet.key" -pubout -out "$u/context/channel-sheet.pem"
openssl genpkey -algorithm ed25519 -out "$u/wrong.key"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 -subj /CN=nyra-test-ca \
  -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign \
  -keyout "$u/ca.key" -out "$u/ca.crt" 2>/dev/null
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj /CN=updates.nyraos.com \
  -keyout "$u/server.key" -out "$u/server.csr" 2>/dev/null
openssl x509 -req -in "$u/server.csr" -CA "$u/ca.crt" -CAkey "$u/ca.key" -CAcreateserial -days 2 \
  -extfile <(printf 'subjectAltName=DNS:updates.nyraos.com\nextendedKeyUsage=serverAuth\n') \
  -out "$u/server.crt" 2>/dev/null
echo nyra-updates-test >"$u/pass"
skopeo() { # the image's own skopeo, as in tools/signing/test-policy.sh
  sudo podman run --rm --network host --tmpfs /var/tmp -v "$u:/u:z" "$image" skopeo "$@"
}
skopeo generate-sigstore-key --output-prefix /u/sigstore --passphrase-file /u/pass >/dev/null
skopeo generate-sigstore-key --output-prefix /u/attacker --passphrase-file /u/pass >/dev/null
sudo chown -R "$(id -u):$(id -g)" "$u"

# --- test versions ---------------------------------------------------------------------------------
version() { # version NAME VERSION [Containerfile lines]
  printf 'FROM %s\nCOPY channel-sheet.pem /usr/lib/nyra/updates/channel-sheet.pem\nRUN echo %s > /usr/lib/nyra-test-version\n%s\n' \
    "$image" "$2" "${3:-}" >"$u/Containerfile.$1"
  sudo podman build -q --annotation "org.opencontainers.image.version=$2" -t "localhost/nyra-test:$1" \
    -f "$u/Containerfile.$1" "$u/context" >/dev/null
}
for n in 0 1 2 4 5 6 7; do version "v$n" "2026.10.$n"; done
version v3 2026.10.3 "$(cat <<'EOF'
RUN printf '%s\n' '[Unit]' 'Description=Test only: a health check that always fails' '[Service]' \
      'Type=oneshot' 'ExecStart=/usr/bin/false' > /usr/lib/systemd/system/nyra-health-test.service && \
    ln -s ../nyra-health-test.service /usr/lib/systemd/system/boot-complete.target.requires/ && \
    mkdir -p /usr/lib/systemd/system/nyra-updated-health-failed.service.d && \
    printf '%s\n' '[Service]' 'StandardOutput=journal+console' 'StandardError=journal+console' \
      'ExecStartPre=-/usr/lib/systemd/systemd-bless-boot status' \
      > /usr/lib/systemd/system/nyra-updated-health-failed.service.d/50-test-console.conf
EOF
)"

# The registry from the boot counting test is replaced by a fresh one.
sudo podman rm -f nyra-test-registry >/dev/null 2>&1 || true
tools/signing/local-registry.sh "$u"
sudo mkdir -p /etc/containers/registries.d
printf 'docker:\n  updates.nyraos.com:\n    use-sigstore-attachments: true\n' |
  sudo tee /etc/containers/registries.d/99-nyra-updates-test.yaml >/dev/null
push() { # push NAME TAG [SIGSTORE_KEY]
  sudo podman push -q --tls-verify=false --format oci --digestfile "$u/$1.digest" \
    ${3:+--sign-by-sigstore-private-key "$u/$3.private" --sign-passphrase-file "$u/pass"} \
    "localhost/nyra-test:$1" "docker://updates.nyraos.com/nyra-base:$2"
  sudo chown "$(id -u):$(id -g)" "$u/$1.digest"
  [[ "$(cat "$u/$1.digest")" =~ ^sha256:[0-9a-f]{64}$ ]]
}
push v0 v0
push v1 stable sigstore
for n in 2 3 4 5 6 7; do push "v$n" "v$n" sigstore; done
skopeo copy -q --dest-tls-verify=false --sign-by-sigstore-private-key /u/attacker.private \
  --sign-passphrase-file /u/pass oci-archive:/u/tiny.oci.tar docker://updates.nyraos.com/nyra-base:attacker
d0="$(cat "$u/v0.digest")" d1="$(cat "$u/v1.digest")" d2="$(cat "$u/v2.digest")" d3="$(cat "$u/v3.digest")"
d4="$(cat "$u/v4.digest")" d5="$(cat "$u/v5.digest")" d6="$(cat "$u/v6.digest")" d7="$(cat "$u/v7.digest")"
old="sha256:$(printf '%064d' 1)" # 2026.9.1, below the version floor; never pulled

# --- signed channel sheets -------------------------------------------------------------------------
sheet() { # sheet NAME KEY SEQUENCE CURRENT_DIGEST CURRENT_VERSION RETRACTED_DIGEST...
  local name="$1" key="$2" seq="$3" digest="$4" ver="$5" now type=application/vnd.nyra.channel-sheet.v1+json
  shift 5
  now="$(date +%s)"
  jq -cnj --argjson seq "$seq" --argjson now "$now" --arg d "$digest" --arg v "$ver" \
    '{schema: 1, repository: "nyra-base", channel: "stable", sequence: $seq, issued_at: $now,
      expires_at: ($now + 604800), current: {digest: $d, version: $v}, previous: null,
      percent: 100, halted: false, retracted: $ARGS.positional}' --args "$@" >"$u/payload"
  { printf 'DSSEv1 %d %s %d ' ${#type} "$type" "$(wc -c <"$u/payload")"; cat "$u/payload"; } >"$u/pae"
  openssl pkeyutl -sign -inkey "$u/$key.key" -rawin -in "$u/pae" -out "$u/sig"
  jq -cn --arg t "$type" --arg p "$(base64 -w0 <"$u/payload")" --arg s "$(base64 -w0 <"$u/sig")" \
    '{payloadType: $t, payload: $p, signatures: [{keyid: "", sig: $s}]}' >"$u/sheets/$name"
}
sheet s1 sheet 100 "$d2" 2026.10.2
sheet wrong wrong 100 "$d2" 2026.10.2
sheet s2 sheet 200 "$d4" 2026.10.4
sheet s3 sheet 300 "$d2" 2026.10.2 "$d4"
sheet s4 sheet 400 "$d3" 2026.10.3 "$d4"
sheet s5 sheet 500 "$d5" 2026.10.5 "$d4"
sheet downgrade sheet 550 "$d1" 2026.10.1 "$d4"
sheet floor sheet 600 "$old" 2026.9.1 "$d4" "$d6"
sheet retract6 sheet 700 "$d5" 2026.10.5 "$d4" "$d6"
sheet s7 sheet 800 "$d7" 2026.10.7 "$d4" "$d6"
printf '<html><body>Welcome to the hotel network. Please log in.</body></html>\n' >"$u/sheets/portal"

cat >"$u/sheet-server.py" <<'EOF'
import http.server, os, ssl, sys
sheets, cert, key = sys.argv[1:4]
current = ["none"]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/_test/select/"):
            current[0] = os.path.basename(self.path)
            body = b"ok\n"
        elif self.path == "/channels/nyra-base/stable":
            body = open(os.path.join(sheets, current[0]), "rb").read()
        else:
            return self.send_error(404)
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
trap 'sudo pkill -f sheet-server.py || true' EXIT
for _ in $(seq 30); do curl -fs --cacert "$u/ca.crt" https://updates.nyraos.com/_test/select/s1 >/dev/null && break; sleep 1; done
curl -fsS --cacert "$u/ca.crt" https://updates.nyraos.com/channels/nyra-base/stable | jq -e .payloadType >/dev/null

# --- the guest ---------------------------------------------------------------------------------------
cp "$disk" "$u/disk.qcow2"
n=0
vm() { # vm TITLE [vm-boot.py options and --command ...]
  n=$((n + 1))
  python3 -B tools/vm/vm-boot.py --autologin --persist --disk "$u/disk.qcow2" --timeout 240 \
    --log "$logs/serial-updates-$n.log" --summary "$summary" --title "Updates, boot $n: $1" "${@:2}"
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
printf '[[registry]]\nlocation = "updates.nyraos.com"\ninsecure = true\n\n[[registry]]\nlocation = "other.test"\ninsecure = true\n' \
  >"$u/99-nyra-test.conf"
mapfile -t setup < <(
  put tools/vm/updates-guest.sh /var/lib/nyra-test/lib.sh
  put "$u/policy.json" /etc/nyra-test/policy.json
  put "$u/sigstore.pub" /etc/nyra-test/sigstore.pub
  put "$u/ca.crt" /usr/local/share/ca-certificates/nyra-test.crt
  put "$u/99-nyra-test.conf" /etc/containers/registries.conf.d/99-nyra-test.conf
)

vm "installed image: fail closed, signatures, test trust" --poweroff \
  "${setup[@]}" \
  --command "$lib; running && systemctl is-active boot-complete.target && systemctl is-active nyra-health-system.service && systemctl is-active nyra-updated.timer" \
  --command 'systemd-analyze security --no-pager nyra-updated.service | tail -1; /usr/libexec/nyra-updated check-config' \
  --command 'bootc status --format json' \
  --command "$lib; ! run_check && grep -q 'no trusted channel sheet key' /var/lib/nyra-updated/last-check.json" \
  --command 'echo "10.0.2.2 updates.nyraos.com other.test" >> /etc/hosts && update-ca-certificates >/dev/null 2>&1' \
  --command "$lib; refused_switch updates.nyraos.com/nyra-base:v0 'A signature was required, but no signature exists'" \
  --command 'ln -sfn /etc/nyra-test/policy.json /etc/containers/policy.json' \
  --command "$lib; refused_switch updates.nyraos.com/nyra-base:v0 'A signature was required, but no signature exists'" \
  --command "$lib; refused_switch updates.nyraos.com/nyra-base:attacker 'cryptographic signature verification failed'" \
  --command 'bootc switch --quiet other.test/nyra-base:v0'

vm "v0 from another registry: foreign image" --poweroff \
  --command "$lib; expect booted $d0 && running" \
  --command "$lib; outcome s1 ForeignImage && journalctl -u nyra-updated -p warning -o cat | grep ForeignImage" \
  --command 'bootc switch --quiet updates.nyraos.com/nyra-base:stable'

cut=$((RANDOM % 6 + 2))
vm "v1: wrong sheet key; power cut ${cut} s into the download of v2" --power-cut-at POWERCUT \
  --command "$lib; expect booted $d1 && running && blessed" \
  --command 'bootc status --format json' \
  --command "$lib; refused wrong 'signature does not verify'" \
  --command "$lib; select_sheet s1 && systemctl start --no-block nyra-updated.service && sleep $cut && echo POWER''CUT"

vm "v1 after the power cut: v2 staged again; power cut before finalization" --power-cut-at POWERCUT \
  --command "$lib; expect booted $d1 && running && digest staged" \
  --command "$lib; outcome s1 Staged && expect staged $d2 && expect rollback $d0" \
  --command 'bootc status --format json' \
  --command 'echo POWER''CUT'

vm "v1 after the power cut: v2 staged again" --poweroff \
  --command "$lib; expect booted $d1 && running && expect staged none" \
  --command "$lib; outcome s1 Staged && expect staged $d2"

vm "power cut when v2's kernel starts" --power-cut-at 'Linux version'

vm "v2, second try: blessed; v4 staged, retracted, discarded" --poweroff \
  --command "$lib; expect booted $d2 && running && blessed" \
  --command 'journalctl -b -u systemd-bless-boot -o cat --no-pager' \
  --command "$lib; outcome s1 UpToDate" \
  --command "$lib; outcome s2 Staged && expect staged $d4" \
  --command "$lib; outcome s3 Discarded && expect staged none && expect booted $d2 && expect rollback $d1 && test \"\$(queued)\" = false" \
  --command 'bootc status --format json'

vm "v2 again: boot order kept; v3 staged" --poweroff \
  --command "$lib; expect booted $d2 && expect rollback $d1 && running" \
  --command "$lib; outcome s4 Staged && expect staged $d3"

vm "v3 fails its health check three times, back on v2 by itself" --poweroff --boots 4 \
  --command "$lib; expect booted $d2 && running && entries | grep -F +0-3" \
  --command "$lib; refused s4 'this machine fell back from it' && expect staged none" \
  --command "$lib; outcome s5 Staged && expect staged $d5"
l="$logs/serial-updates-$n.log"
grep -a 'nyra-updated health-failed:' "$l" || true
echo "kernel starts: $(grep -c 'Linux version' "$l"), full reboots by nyra-updated: $(grep -ac 'nyra-updated health-failed: Reboot' "$l")"
[ "$(grep -c 'Linux version' "$l")" = 4 ] && [ "$(grep -ac 'nyra-updated health-failed: Reboot' "$l")" = 3 ]

vm "v5: hostile network, downgrade, replay; soft reboot into v6" --poweroff \
  --command "$lib; expect booted $d5 && running && blessed" \
  --command "$lib; refused portal 'malformed channel sheet'" \
  --command "$lib; untrusted_tls s5" \
  --command "$lib; refused downgrade 'not newer than the installed'" \
  --command "$lib; refused s1 'is older than the accepted'" \
  --command 'systemctl reset-failed nyra-updated.service' \
  --command "@reboot bootc switch --quiet --soft-reboot=required --apply updates.nyraos.com/nyra-base@$d6" \
  --command 'test "$(systemctl show --property=SoftRebootsCount --value)" = 1 && grep -x 2026.10.6 /usr/lib/nyra-test-version' \
  --command ". /var/lib/nyra-test/lib.sh; running && ! systemctl is-failed --quiet systemd-bless-boot.service && entries | grep -F +3" \
  --command 'journalctl -b -u systemd-bless-boot -o cat --no-pager'

vm "v6, first full boot: retraction below the floor refused; retraction to v5 by bootc rollback" --poweroff \
  --command "$lib; expect booted $d6 && running && blessed" \
  --command "$lib; refused floor 'below the version floor'" \
  --command "$lib; outcome retract6 RolledBack && expect rollback $d5 && test \"\$(queued)\" = true" \
  --command 'bootc status --format json'

sudo podman stop -t 1 nyra-test-registry >/dev/null
vm "v5, registry down" --poweroff \
  --command "$lib; expect booted $d5 && running" \
  --command "$lib; refused s7 '' && expect staged none"
sudo podman start nyra-test-registry >/dev/null
for _ in $(seq 30); do curl -fs http://updates.nyraos.com/v2/ >/dev/null && break; sleep 1; done

top() { # the registry's file for the last layer of image $1
  local layer
  layer="$(curl -fsS -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
    "http://updates.nyraos.com/v2/nyra-base/manifests/$1" | jq -r '.layers[-1].digest')"
  echo "/var/lib/registry/docker/registry/v2/blobs/sha256/${layer:7:2}/${layer:7}/data"
}
blob="$(top "$d7")"
sudo podman exec nyra-test-registry sh -c "cp $blob $blob.orig && printf CORRUPT | dd of=$blob bs=1 seek=64 conv=notrunc 2>/dev/null"
vm "v5, a corrupted layer of v7" --poweroff \
  --command "$lib; refused s7 '' && expect staged none && expect booted $d5"
# Another valid layer (v6's) served in place of v7's, with its own size (the registry restarted, so
# it does not answer with the size it cached): only the digest check can catch it.
sudo podman exec nyra-test-registry sh -c "cp $(top "$d6") $blob"
sudo podman restart -t 1 nyra-test-registry >/dev/null
for _ in $(seq 30); do curl -fs http://updates.nyraos.com/v2/ >/dev/null && break; sleep 1; done
vm "v5, another valid layer in place of v7's" --poweroff \
  --command "$lib; refused s7 '' && expect staged none && expect booted $d5"
sudo podman exec nyra-test-registry sh -c "mv $blob.orig $blob"
sudo podman restart -t 1 nyra-test-registry >/dev/null # forget the size it cached for the blob
for _ in $(seq 30); do curl -fs http://updates.nyraos.com/v2/ >/dev/null && break; sleep 1; done

vm "v5, registry repaired: v7 staged" --poweroff \
  --command "$lib; outcome s7 Staged && expect staged $d7 && expect booted $d5"
