#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: Titanic T11, version jumps and channels, on its own copy of the installed test disk
# (docs/UPDATES.md, "Channels"). Set up like tools/vm/updates.sh: everything the guest trusts is made
# for this run (an image signing key standing in for the keyless signer, two channel sheet keys
# baked only into the test versions, a CA for the sheet server), and the guest reaches the runner as
# updates.nyraos.com: the registry on port 80, a sheet server on 443 that serves whichever signed sheet
# the guest selects, at any /channels/REPOSITORY/CHANNEL, and says which one was asked for last.
#
# Test versions (2026.11.N, the version in the manifest annotation bootc reads), each with its own
# /usr/lib/nyra/updates (sheet key, repository, default channel, version floor):
#   a1 2026.11.1  key 1, nyra-base, stable, floor 2026.10.1
#   a3 2026.11.3  the same; retracted, never booted (2026.11.2 and 2026.11.4 exist only in sheets)
#   a5 2026.11.5  the same, floor 2026.11.5
#   k6 2026.11.6  key 2 only (the key rotated), floor 2026.11.5, as every version after it
#   d7 2026.11.7  default channel beta
#   s8 2026.11.8  stable's version
#   b9 2026.11.9  beta's version, default channel beta
#   r10 2026.11.10  repository nyra-next (pushed to nyra-base)
#   n11 2026.11.11  repository nyra-next (pushed to nyra-next)
# The boots:
#   1  installed image: test trust set up; switch to a1 by its channel tag
#   2  a1: a jump to a5: a sheet signed with key 2 (not trusted yet) refused; a5 staged; an older
#      sheet offering a3 refused (sequence); a later one offering the retracted a3 refused
#   3  a5: a retraction to 2026.11.4 refused (below the floor a5 raised); k6 staged
#   4  k6: a sheet signed with key 1 refused (rotated out); d7 staged with key 2
#   5  d7: follows beta (the image's default): stable's sheet refused, b9 staged
#   6  b9: an unknown channel, and set-channel by another user than root, refused; set-channel
#      stable: stable's version s8 is older. A sheet issued before the change does nothing, one below
#      the floor is refused, then s8 is staged; a replayed sheet is refused, and an even older
#      version is refused (once per change)
#   7  s8: up to date; went back to b9 by hand (bootc rollback)
#   8  b9: the choice (stable) survived the rollback and wins over b9's default (beta): stable's s8 is
#      refused as a downgrade (no new change). A setting changed in /etc; set-channel beta, then
#      stable again: s8, now the rollback deployment, is deleted and staged afresh (never bootc
#      rollback, which would boot it with its old /etc)
#   9  s8 with the setting made on b9; r10 staged
#  10  r10: follows nyra-next: nyra-base's sheet refused; n11 staged from nyra-next
#  11  n11: up to date
#   tools/vm/channels.sh IMAGE DISK.qcow2 WORKDIR LOGDIR SUMMARY
set -euo pipefail

image="$1" disk="$2" work="$3" logs="$4" summary="$5"
PS4='+ channels.sh:$LINENO: '
set -x
u="$work/channels"
mkdir -p "$u/context" "$u/sheets"

# --- keys ------------------------------------------------------------------------------------------
for k in key1 key2; do
  openssl genpkey -algorithm ed25519 -out "$u/$k.key"
  openssl pkey -in "$u/$k.key" -pubout -out "$u/context/$k.pem"
done
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 -subj /CN=nyra-test-ca \
  -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign \
  -keyout "$u/ca.key" -out "$u/ca.crt" 2>/dev/null
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj /CN=updates.nyraos.com \
  -keyout "$u/server.key" -out "$u/server.csr" 2>/dev/null
openssl x509 -req -in "$u/server.csr" -CA "$u/ca.crt" -CAkey "$u/ca.key" -CAcreateserial -days 2 \
  -extfile <(printf 'subjectAltName=DNS:updates.nyraos.com\nextendedKeyUsage=serverAuth\n') \
  -out "$u/server.crt" 2>/dev/null
echo nyra-channels-test >"$u/pass"
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
version() { # version NAME VERSION KEY REPOSITORY CHANNEL FLOOR
  printf 'repository = %s\nchannel = %s\nversion_floor = %s\n' "$4" "$5" "$6" >"$u/context/$1.conf"
  printf 'FROM %s\nRUN rm -rf /boot/EFI\nCOPY %s.pem /usr/lib/nyra/updates/channel-sheet.pem\nCOPY %s.conf /usr/lib/nyra/updates/updated.conf\nRUN echo %s > /usr/lib/nyra-test-version && /usr/libexec/nyra-updated check-config\n' \
    "$image" "$3" "$1" "$2" >"$u/Containerfile.$1"
  sudo podman build -q -t "localhost/nyra-channels:$1-rootfs" -f "$u/Containerfile.$1" "$u/context" >/dev/null
  mkdir -p "$u/$1-uki"
  sudo podman run --rm --network none --tmpfs /tmp --tmpfs /var/tmp \
    --mount "type=image,source=localhost/nyra-channels:$1-rootfs,target=/target" \
    -v "$u/kernel-from-uki.py:/kernel-from-uki.py:ro" -v "$u/$1-uki:/out" "$image" \
    sh -c 'u="$(ls /boot/EFI/Linux/*.efi)" && k="$(basename "$u" .efi)" && mkdir -p "/tmp/kernel/$k" &&
      python3 /kernel-from-uki.py "$u" "/tmp/kernel/$k" &&
      bootc container ukify --rootfs /target --kernel-dir "/tmp/kernel/$k" -- --output "/out/$k.efi"' >/dev/null
  printf 'FROM localhost/nyra-channels:%s-rootfs\nCOPY --from=uki . /boot/EFI/Linux/\n' "$1" |
    sudo podman build -q --annotation "org.opencontainers.image.version=$2" -t "localhost/nyra-channels:$1" \
      --build-context uki="$u/$1-uki" -f - "$u/context" >/dev/null
}
version a1 2026.11.1 key1 nyra-base stable 2026.10.1
version a3 2026.11.3 key1 nyra-base stable 2026.10.1
version a5 2026.11.5 key1 nyra-base stable 2026.11.5
version k6 2026.11.6 key2 nyra-base stable 2026.11.5
version d7 2026.11.7 key2 nyra-base beta 2026.11.5
version s8 2026.11.8 key2 nyra-base stable 2026.11.5
version b9 2026.11.9 key2 nyra-base beta 2026.11.5
version r10 2026.11.10 key2 nyra-next stable 2026.11.5
version n11 2026.11.11 key2 nyra-next stable 2026.11.5

# A fresh registry, as in tools/vm/updates.sh.
sudo podman rm -f nyra-test-registry >/dev/null 2>&1 || true
tools/signing/local-registry.sh "$u"
sudo mkdir -p /etc/containers/registries.d
printf 'docker:\n  updates.nyraos.com:\n    use-sigstore-attachments: true\n' |
  sudo tee /etc/containers/registries.d/99-nyra-updates-test.yaml >/dev/null
push() { # push NAME REPOSITORY TAG: signed; a push that stalls is tried again (tools/vm/updates.sh)
  local try
  for try in 1 2 3; do
    sudo timeout 120 podman push -q --tls-verify=false --format oci --digestfile "$u/$1.digest" \
      --sign-by-sigstore-private-key "$u/sigstore.private" --sign-passphrase-file "$u/pass" \
      "localhost/nyra-channels:$1" "docker://updates.nyraos.com/$2:$3" && break
    echo "::warning::podman push of $1 failed or took more than 2 minutes (attempt $try of 3)"
    if [ "$try" = 3 ]; then echo "::error::podman push of $1 failed 3 times"; return 1; fi
  done
  sudo chown "$(id -u):$(id -g)" "$u/$1.digest"
  [[ "$(cat "$u/$1.digest")" =~ ^sha256:[0-9a-f]{64}$ ]]
}
push a1 nyra-base stable
for n in a3 a5 k6 d7 s8 b9 r10; do push "$n" nyra-base "$n"; done
push n11 nyra-next n11
a1="$(cat "$u/a1.digest")" a3="$(cat "$u/a3.digest")" a5="$(cat "$u/a5.digest")" k6="$(cat "$u/k6.digest")"
d7="$(cat "$u/d7.digest")" s8="$(cat "$u/s8.digest")" b9="$(cat "$u/b9.digest")"
r10="$(cat "$u/r10.digest")" n11="$(cat "$u/n11.digest")"
a4="sha256:$(printf '%064d' 4)" # 2026.11.4, only in a sheet: never pulled

# --- signed channel sheets -------------------------------------------------------------------------
now="$(date +%s)"
sheet() { # sheet NAME KEY REPOSITORY CHANNEL SEQUENCE DIGEST VERSION ISSUED_IN_SECONDS RETRACTED...
  local name="$1" key="$2" repo="$3" channel="$4" seq="$5" digest="$6" ver="$7" issued=$((now + $8))
  local type=application/vnd.nyra.channel-sheet.v1+json
  shift 8
  jq -cnj --arg r "$repo" --arg c "$channel" --argjson seq "$seq" --argjson t "$issued" --arg d "$digest" \
    --arg v "$ver" '{schema: 1, repository: $r, channel: $c, sequence: $seq, issued_at: $t,
      expires_at: ($t + 604800), current: {digest: $d, version: $v}, previous: null, percent: 100,
      halted: false, retracted: $ARGS.positional}' --args "$@" >"$u/payload"
  { printf 'DSSEv1 %d %s %d ' ${#type} "$type" "$(wc -c <"$u/payload")"; cat "$u/payload"; } >"$u/pae"
  openssl pkeyutl -sign -inkey "$u/$key.key" -rawin -in "$u/pae" -out "$u/sig"
  jq -cn --arg t "$type" --arg p "$(base64 -w0 <"$u/payload")" --arg s "$(base64 -w0 <"$u/sig")" \
    '{payloadType: $t, payload: $p, signatures: [{keyid: "", sig: $s}]}' >"$u/sheets/$name"
}
# The version jump and the key rotation (nyra-base, stable).
sheet s1 key1 nyra-base stable 100 "$a1" 2026.11.1 0
sheet jump-key2 key2 nyra-base stable 500 "$a5" 2026.11.5 0 "$a3"
sheet jump key1 nyra-base stable 500 "$a5" 2026.11.5 0 "$a3"
sheet old-a3 key1 nyra-base stable 300 "$a3" 2026.11.3 0
sheet again-a3 key1 nyra-base stable 600 "$a3" 2026.11.3 0
sheet jump2 key1 nyra-base stable 650 "$a5" 2026.11.5 0 "$a3"
sheet floor key1 nyra-base stable 700 "$a4" 2026.11.4 0 "$a5"
sheet to-k6 key1 nyra-base stable 800 "$k6" 2026.11.6 0
sheet k6-key1 key1 nyra-base stable 900 "$k6" 2026.11.6 0
sheet to-d7 key2 nyra-base stable 900 "$d7" 2026.11.7 0
# The channels. stable-s8 is issued now, before the change of channel in boot 6; the sheets
# issued later (up to a day ahead is accepted, for clocks that are behind) come after it.
sheet stable-s8 key2 nyra-base stable 1000 "$s8" 2026.11.8 0
sheet beta-b9 key2 nyra-base beta 100 "$b9" 2026.11.9 0
sheet stable-floor key2 nyra-base stable 1100 "$a4" 2026.11.4 3600
sheet stable-s8-new key2 nyra-base stable 1200 "$s8" 2026.11.8 7200
sheet stable-k6 key2 nyra-base stable 1300 "$k6" 2026.11.6 10800
sheet stable-s8-last key2 nyra-base stable 1400 "$s8" 2026.11.8 14400
sheet stable-s8-again key2 nyra-base stable 1450 "$s8" 2026.11.8 18000
# Another repository.
sheet to-r10 key2 nyra-base stable 1500 "$r10" 2026.11.10 18000
sheet next-n11 key2 nyra-next stable 100 "$n11" 2026.11.11 0

cat >"$u/sheet-server.py" <<'EOF'
import http.server, os, re, ssl, sys
sheets, cert, key = sys.argv[1:4]
state = {"sheet": "none", "last": "none"}

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/_test/select/"):
            state["sheet"] = os.path.basename(self.path)
            return self.answer(b"ok\n")
        if self.path == "/_test/last":
            return self.answer(state["last"].encode() + b"\n")
        if re.fullmatch(r"/channels/[a-z0-9._/-]+/[a-z]+", self.path):
            state["last"] = self.path
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
    --log "$logs/serial-channels-$n.log" --summary "$summary" --title "Channels, boot $n: $1" "${@:2}"
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
# Many checks fail on purpose in a row: reset-failed keeps systemd's start limit of the unit out of
# the way.
lib='. /var/lib/nyra-test/lib.sh; systemctl reset-failed nyra-updated.service'
asked() { # the sheet the last check asked for: asked /channels/REPOSITORY/CHANNEL
  echo "test \"\$(curl -kfsS https://updates.nyraos.com/_test/last)\" = $1"
}
state() { # state PYTHON_EXPRESSION: true of nyra-updated's state s
  echo "python3 -c 'import json, sys; s = json.load(open(\"/var/lib/nyra-updated/state.json\")); print(s); sys.exit(not ($1))'"
}
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

vm "installed image: test trust; switch to a1" \
  "${setup[@]}" \
  --command 'echo "10.0.2.2 updates.nyraos.com" >> /etc/hosts && update-ca-certificates >/dev/null 2>&1' \
  --command 'ln -sfn /etc/nyra-test/policy.json /etc/containers/policy.json' \
  --command "$lib; running && bootc switch --quiet updates.nyraos.com/nyra-base:stable && expect staged $a1"

vm "a1: a jump over three versions to a5, one of them retracted" \
  --command "$lib; expect booted $a1 && running && blessed" \
  --command "$lib; outcome s1 UpToDate" \
  --command "$lib; refused jump-key2 'signature does not verify' && expect staged none" \
  --command "$lib; outcome jump Staged && expect staged $a5 && $(asked /channels/nyra-base/stable)" \
  --command "$lib; refused old-a3 'is older than the accepted' && expect staged $a5" \
  --command "$lib; refused again-a3 'it was retracted' && expect staged $a5" \
  --command "$lib; outcome jump2 WaitingForReboot && expect staged $a5"

vm "a5: a retraction below the floor it raised refused; k6 (a new sheet key) staged" \
  --command "$lib; expect booted $a5 && running && blessed && outcome jump2 UpToDate" \
  --command "$lib; refused floor 'below the version floor 2026.11.5' && expect staged none" \
  --command "$lib; outcome to-k6 Staged && expect staged $k6"

vm "k6: the old sheet key refused; d7 (default channel beta) staged" \
  --command "$lib; expect booted $k6 && running && blessed" \
  --command "$lib; refused k6-key1 'signature does not verify' && expect staged none" \
  --command "$lib; outcome to-d7 Staged && expect staged $d7"

vm "d7 follows beta, its default: stable's sheet refused; b9 staged" \
  --command "$lib; expect booted $d7 && running && blessed" \
  --command "$lib; refused stable-s8 'channel sheet is for nyra-base:stable, expected nyra-base:beta' && $(asked /channels/nyra-base/beta)" \
  --command "$lib; outcome beta-b9 Staged && expect staged $b9 && $(state 's["following"] == "beta" and s.get("channel") is None and s.get("channel_changed") is None')"

vm "b9: set-channel stable; stable's older s8 only with a sheet issued after the change, once" \
  --command "$lib; expect booted $b9 && running && blessed && outcome beta-b9 UpToDate" \
  --command "! /usr/libexec/nyra-updated set-channel nightly && ! /usr/libexec/nyra-updated set-channel && $(state 's.get("channel") is None')" \
  --command 'out="$(setpriv --reuid=65534 --regid=65534 --clear-groups /usr/libexec/nyra-updated set-channel stable 2>&1)"; rc=$?; echo "$out"; test $rc != 0 && echo "$out" | grep -q "Permission denied"' \
  --command "$(state 's.get("channel") is None')" \
  --command "/usr/libexec/nyra-updated set-channel stable && $(state 's["channel"] == "stable"')" \
  --command "$lib; outcome stable-s8 WaitingForSheet && expect staged none && $(asked /channels/nyra-base/stable) && $(state 's["channel_changed"]')" \
  --command "$lib; refused stable-floor 'below the version floor' && expect staged none" \
  --command "$lib; outcome stable-s8-new Staged && expect staged $s8 && $(state 's.get("channel_changed") is None')" \
  --command "$lib; refused stable-s8 'is older than the accepted' && expect staged $s8" \
  --command "$lib; refused stable-k6 'not newer than the installed' && expect staged $s8"

vm "s8, back from beta: up to date; back to b9 by hand" \
  --command "$lib; expect booted $s8 && running && blessed && outcome stable-s8-last UpToDate" \
  --command "$lib; bootc rollback && test \"\$(queued)\" = true"

vm "b9 by hand: still on stable, s8 refused; beta, then stable again: s8 staged afresh, not rolled back to" \
  --command "$lib; expect booted $b9 && expect rollback $s8 && running" \
  --command "$lib; refused stable-s8-last 'not newer than the installed' && $(asked /channels/nyra-base/stable) && expect staged none" \
  --command 'echo "made on b9" > /etc/nyra-t11-setting' \
  --command "$lib; /usr/libexec/nyra-updated set-channel beta && outcome beta-b9 UpToDate && $(asked /channels/nyra-base/beta)" \
  --command "$lib; /usr/libexec/nyra-updated set-channel stable && outcome stable-s8-again Staged && expect staged $s8 && expect rollback none && test \"\$(queued)\" = false && $(state 's.get("channel_changed") is None')"

vm "s8, staged afresh: today's settings; r10 (repository nyra-next) staged" \
  --command "$lib; expect booted $s8 && running && blessed && grep -x 'made on b9' /etc/nyra-t11-setting" \
  --command "$lib; outcome stable-s8-again UpToDate" \
  --command "$lib; outcome to-r10 Staged && expect staged $r10"

vm "r10 follows nyra-next: nyra-base's sheet refused; n11 staged from nyra-next" \
  --command "$lib; expect booted $r10 && running && blessed" \
  --command "$lib; refused to-r10 'channel sheet is for nyra-base:stable, expected nyra-next:stable' && $(asked /channels/nyra-next/stable)" \
  --command "$lib; outcome next-n11 Staged && expect staged $n11 && bootc status --format json | grep -F updates.nyraos.com/nyra-next@$n11"

vm "n11 from nyra-next: up to date" \
  --command "$lib; expect booted $n11 && running && blessed && outcome next-n11 UpToDate" \
  --command 'bootc status --booted --format json | grep -F updates.nyraos.com/nyra-next@'
