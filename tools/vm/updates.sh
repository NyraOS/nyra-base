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
# Test versions of IMAGE (v1-v14: 2026.10.1-14, the version in the manifest annotation bootc reads;
# v3 has a health check that always fails; v0 is unsigned), and the boots:
#   1  installed image: no sheet key, updates not configured (nothing fetched, unit not failed); unsigned refused by the shipped policy; test trust
#      set up; unsigned and wrongly signed refused; switch to v0 from another registry
#   2  v0: a foreign image, reported (ForeignImage); switch to v1 by its channel tag
#   3  v1: a sheet signed with another key refused; power cut while v2 downloads (throttled link)
#   4  v1: v2 staged again; power cut before the staged version is finalized
#   5  v1: v2 staged again; clean shutdown
#   6  power cut when v2's kernel starts (first try)
#   7  v2, second try, blessed; v4 staged, then retracted: discarded (never finalized); v11
#      staged by hand afterwards (discarded at shutdown too)
#   8  v2 again (boot order kept, no staged entries left); v3 staged
#   9  v3 fails its health check and reboots by itself, three times; systemd-boot falls back to v2;
#      v3 is marked failed and refused; v8 staged, then retracted: discarded, with the failed v3 as
#      rollback deployment
#  10  v2 again, v8 not finalized; v5 staged
#  11  v5, first try: captive portal, spoofed server, downgrade, replayed sheet refused; soft reboot
#      into v6: not blessed, system not degraded
#  12  v6, first full boot: signed retraction below the version floor refused; retraction to the
#      local rollback deployment (v5) uses bootc rollback
#  13  v5, registry down: refused, nothing staged
#  14  v5, a corrupted layer of v7 in the registry: refused, nothing staged
#  15  v5, a valid layer of the same size with other content served for v7's: refused (digest)
#  16  v5, registry repaired: v7 staged
#  17  v7: v9 staged; power cut before it is finalized (its staged entries stay on the ESP)
#  18  v7: v10, another version, staged: only its entries and v7's are staged (none left from v9)
#  19  v10 boots; two boot entries (v10 and v7)
#  20-24  v10: power cuts at random moments while nyra-updated pulls and stages v12 (seed printed)
#  25  v10: v12 staged
#  26  v12: another host (valid certificate for another name), a 50 kbit/s link and a registry that
#      stalls mid-pull refused, nothing staged; v13 staged
#  27  v13: the shipped signature policy linked again; then the secure defaults check (T15)
#  28  v13: v14 staged (its initramfs is broken)
#  29  v14's kernel panics and reboots by itself, three times; systemd-boot falls back to v13;
#      v14 is marked failed and refused
#   tools/vm/updates.sh IMAGE DISK.qcow2 WORKDIR LOGDIR SUMMARY
set -euo pipefail

image="$1" disk="$2" work="$3" logs="$4" summary="$5"
# The setup is traced: it boots nothing, so a failure there leaves no serial log to read.
PS4='+ updates.sh:$LINENO: '
set -x
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
# Another host's certificate from the same trusted CA: a DNS answer that points elsewhere.
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj /CN=evil.test \
  -keyout "$u/evil.key" -out "$u/evil.csr" 2>/dev/null
openssl x509 -req -in "$u/evil.csr" -CA "$u/ca.crt" -CAkey "$u/ca.key" -CAcreateserial -days 2 \
  -extfile <(printf 'subjectAltName=DNS:evil.test\nextendedKeyUsage=serverAuth\n') \
  -out "$u/evil.crt" 2>/dev/null
echo nyra-updates-test >"$u/pass"
skopeo() { # the image's own skopeo, as in tools/signing/test-policy.sh
  sudo podman run --rm --network host --tmpfs /var/tmp -v "$u:/u:z" "$image" skopeo "$@"
}
skopeo generate-sigstore-key --output-prefix /u/sigstore --passphrase-file /u/pass >/dev/null
skopeo generate-sigstore-key --output-prefix /u/attacker --passphrase-file /u/pass >/dev/null
sudo chown -R "$(id -u):$(id -g)" "$u"

# --- test versions ---------------------------------------------------------------------------------
# A test version changes /usr, so its composefs digest changes and it needs its own UKI, built as in
# tools/vm/boot-counting.sh: from the committed root filesystem, with the kernel and initramfs taken
# out of IMAGE's UKI. Unsigned: these boots run without Secure Boot.
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
  sudo podman build -q -t "localhost/nyra-test:$1-rootfs" -f "$u/Containerfile.$1" "$u/context" >/dev/null
  mkdir -p "$u/$1-uki"
  sudo podman run --rm --network none --tmpfs /tmp --tmpfs /var/tmp \
    --mount "type=image,source=localhost/nyra-test:$1-rootfs,target=/target" \
    -v "$u/kernel-from-uki.py:/kernel-from-uki.py:ro" -v "$u/$1-uki:/out" -e BROKEN_INITRD="${BROKEN_INITRD:-}" "$image" \
    sh -c 'u="$(ls /boot/EFI/Linux/*.efi)" && k="$(basename "$u" .efi)" && mkdir -p "/tmp/kernel/$k" &&
      python3 /kernel-from-uki.py "$u" "/tmp/kernel/$k" &&
      { [ -z "$BROKEN_INITRD" ] || head -c 4096 /dev/zero > "/tmp/kernel/$k/initramfs.img"; } &&
      bootc container ukify --rootfs /target --kernel-dir "/tmp/kernel/$k" -- --output "/out/$k.efi"' >/dev/null
  printf 'FROM localhost/nyra-test:%s-rootfs\nCOPY --from=uki . /boot/EFI/Linux/\n' "$1" |
    sudo podman build -q --annotation "org.opencontainers.image.version=$2" -t "localhost/nyra-test:$1" \
      --build-context uki="$u/$1-uki" -f - "$u/context" >/dev/null
}
for n in 0 1 4 5 6 7 8 9 10 11 12 13; do version "v$n" "2026.10.$n"; done
# v14: its UKI carries an initramfs of zeros, so the kernel panics (and reboots, panic=10).
BROKEN_INITRD=1 version v14 2026.10.14
# v2 carries 16 MiB that do not compress, so its download takes about a minute on the throttled link
# of boot 3 and the power cut lands in the middle of it.
version v2 2026.10.2 'RUN head -c 16777216 /dev/urandom > /usr/lib/nyra-test-payload'
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
for n in 2 3 4 5 6 7 8 9 10 11 12 13 14; do push "v$n" "v$n" sigstore; done
skopeo copy -q --dest-tls-verify=false --sign-by-sigstore-private-key /u/attacker.private \
  --sign-passphrase-file /u/pass oci-archive:/u/tiny.oci.tar docker://updates.nyraos.com/nyra-base:attacker
d0="$(cat "$u/v0.digest")" d1="$(cat "$u/v1.digest")" d2="$(cat "$u/v2.digest")" d3="$(cat "$u/v3.digest")"
d4="$(cat "$u/v4.digest")" d5="$(cat "$u/v5.digest")" d6="$(cat "$u/v6.digest")" d7="$(cat "$u/v7.digest")"
d8="$(cat "$u/v8.digest")" d9="$(cat "$u/v9.digest")" d10="$(cat "$u/v10.digest")"
d11="$(cat "$u/v11.digest")" d12="$(cat "$u/v12.digest")" d13="$(cat "$u/v13.digest")"
d14="$(cat "$u/v14.digest")"
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
sheet s8 sheet 450 "$d8" 2026.10.8 "$d4"
sheet s8r sheet 460 "$d2" 2026.10.2 "$d4" "$d8"
sheet s5 sheet 500 "$d5" 2026.10.5 "$d4"
sheet downgrade sheet 550 "$d1" 2026.10.1 "$d4"
sheet floor sheet 600 "$old" 2026.9.1 "$d4" "$d6"
sheet retract6 sheet 700 "$d5" 2026.10.5 "$d4" "$d6"
sheet s7 sheet 800 "$d7" 2026.10.7 "$d4" "$d6"
sheet s9 sheet 900 "$d9" 2026.10.9 "$d4" "$d6"
sheet s10 sheet 1000 "$d10" 2026.10.10 "$d4" "$d6"
sheet s12 sheet 1200 "$d12" 2026.10.12 "$d4" "$d6"
sheet s13 sheet 1300 "$d13" 2026.10.13 "$d4" "$d6"
sheet s14 sheet 1400 "$d14" 2026.10.14 "$d4" "$d6"
printf '<html><body>Welcome to the hotel network. Please log in.</body></html>\n' >"$u/sheets/portal"

cat >"$u/sheet-server.py" <<'EOF'
import http.server, os, ssl, subprocess, sys
sheets, cert, key, evil_cert, evil_key = sys.argv[1:6]
state = {"sheet": "none", "cert": "good"}

def rate(kbit):  # the registry's answers (port 80 on lo) at kbit/s; 0: at full speed
    subprocess.run(["tc", "qdisc", "del", "dev", "lo", "root"], stderr=subprocess.DEVNULL)
    if kbit:
        for cmd in (["qdisc", "add", "dev", "lo", "root", "handle", "1:", "htb", "default", "10"],
                    ["class", "add", "dev", "lo", "parent", "1:", "classid", "1:10", "htb", "rate", "10gbit"],
                    ["class", "add", "dev", "lo", "parent", "1:", "classid", "1:20", "htb",
                     "rate", f"{kbit}kbit", "ceil", f"{kbit}kbit"],
                    ["filter", "add", "dev", "lo", "parent", "1:", "protocol", "ip", "prio", "1", "u32",
                     "match", "ip", "sport", "80", "0xffff", "flowid", "1:20"]):
            subprocess.run(["tc", *cmd], check=True)

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path
        if path.startswith("/_test/select/"):
            state["sheet"] = os.path.basename(path)
        elif path.startswith("/_test/rate/") and path[len("/_test/rate/"):].isdigit():
            rate(int(path[len("/_test/rate/"):]))
        elif path in ("/_test/stall", "/_test/resume"):
            subprocess.run(["podman", "pause" if path.endswith("stall") else "unpause",
                            "nyra-test-registry"], check=True, stdout=subprocess.DEVNULL)
        elif path in ("/_test/cert/evil", "/_test/cert/good"):
            state["cert"] = os.path.basename(path)
        elif path == "/channels/nyra-base/stable":
            body = open(os.path.join(sheets, state["sheet"]), "rb").read()
            return self.answer(body)
        else:
            return self.send_error(404)
        self.answer(b"ok\n")
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
evil = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
evil.load_cert_chain(evil_cert, evil_key)
def sni(sock, name, _):  # another host answers in place of the update server
    if state["cert"] == "evil":
        sock.context = evil
ctx.sni_callback = sni
server.socket = ctx.wrap_socket(server.socket, server_side=True)
server.serve_forever()
EOF
sudo python3 -I "$u/sheet-server.py" "$u/sheets" "$u/server.crt" "$u/server.key" "$u/evil.crt" "$u/evil.key" &
trap 'sudo pkill -f sheet-server.py || true; sudo tc qdisc del dev lo root 2>/dev/null || true' EXIT
for _ in $(seq 30); do curl -fs --cacert "$u/ca.crt" https://updates.nyraos.com/_test/select/s1 >/dev/null && break; sleep 1; done
curl -fsS --cacert "$u/ca.crt" https://updates.nyraos.com/channels/nyra-base/stable | jq -e .payloadType >/dev/null

set +x
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
  --command "$lib; run_check && grep -q '\"ok\":false' /var/lib/nyra-updated/last-check.json && grep -q 'updates are not configured' /var/lib/nyra-updated/last-check.json && ! systemctl is-failed --quiet nyra-updated.service" \
  --command 'echo "10.0.2.2 updates.nyraos.com other.test" >> /etc/hosts && update-ca-certificates >/dev/null 2>&1' \
  --command 'mkdir -p /etc/systemd/system/systemd-networkd.service.d && printf "[Service]\nEnvironment=SYSTEMD_LOG_LEVEL=debug\n" > /etc/systemd/system/systemd-networkd.service.d/50-ci-debug.conf' \
  --command "$lib; refused_switch updates.nyraos.com/nyra-base:v0 'A signature was required, but no signature exists'" \
  --command 'ln -sfn /etc/nyra-test/policy.json /etc/containers/policy.json' \
  --command "$lib; refused_switch updates.nyraos.com/nyra-base:v0 'A signature was required, but no signature exists'" \
  --command "$lib; refused_switch updates.nyraos.com/nyra-base:attacker 'cryptographic signature verification failed'" \
  --command 'bootc switch --quiet other.test/nyra-base:v0'

vm "v0 from another registry: foreign image" --poweroff \
  --command "$lib; expect booted $d0 && running" \
  --command "$lib; outcome s1 ForeignImage && journalctl -u nyra-updated -p warning -o cat | grep ForeignImage" \
  --command 'bootc switch --quiet updates.nyraos.com/nyra-base:stable'

# The registry's answers (port 80) at 2 Mbit/s for this boot only: the power cut comes while
# nyra-updated is still pulling v2 (the unit is still activating, nothing is staged yet).
sudo tc qdisc add dev lo root handle 1: htb default 10
sudo tc class add dev lo parent 1: classid 1:10 htb rate 10gbit
sudo tc class add dev lo parent 1: classid 1:20 htb rate 2mbit ceil 2mbit
sudo tc filter add dev lo parent 1: protocol ip prio 1 u32 match ip sport 80 0xffff flowid 1:20
cut=$((RANDOM % 9 + 4))
vm "v1: wrong sheet key; power cut ${cut} s into the download of v2" --power-cut-at POWERCUT \
  --command "$lib; expect booted $d1 && running && blessed" \
  --command 'bootc status --format json' \
  --command "$lib; refused wrong 'signature does not verify'" \
  --command "$lib; select_sheet s1 && systemctl start --no-block nyra-updated.service && sleep $cut && systemctl is-active nyra-updated.service | grep -x activating && expect staged none && echo POWER''CUT"
sudo tc qdisc del dev lo root

vm "v1 after the power cut: v2 staged again; power cut before finalization" --power-cut-at POWERCUT \
  --command "$lib; expect booted $d1 && running && expect staged none" \
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
  --command "$lib; outcome s3 Discarded && test -e /run/nyra-updated/discarded && ! test -e /boot/loader/entries.staged && expect booted $d2 && expect rollback $d1 && test \"\$(queued)\" = false" \
  --command 'bootc status --format json' \
  --command "$lib; bootc switch --quiet other.test/nyra-base:v11 && expect staged $d11 && ls /boot/loader/entries.staged"

vm "v2 again: boot order kept; v3 staged" --poweroff \
  --command "$lib; expect booted $d2 && expect rollback $d1 && expect staged none && ! test -e /boot/loader/entries.staged && running" \
  --command "$lib; outcome s4 Staged && expect staged $d3"

vm "v3 fails its health check three times, back on v2 by itself" --poweroff --boots 4 \
  --command "$lib; expect booted $d2 && running && entries | grep -F +0-3" \
  --command "$lib; refused s4 'this machine fell back from it' && expect staged none" \
  --command "$lib; outcome s8 Staged && expect staged $d8 && expect rollback $d3" \
  --command "$lib; outcome s8r Discarded && test -e /run/nyra-updated/discarded && ! test -e /boot/loader/entries.staged && expect rollback $d3"
l="$logs/serial-updates-$n.log"
grep -a 'nyra-updated health-failed:' "$l" || true
echo "kernel starts: $(grep -c 'Linux version' "$l"), full reboots by nyra-updated: $(grep -ac 'nyra-updated health-failed: Reboot' "$l")"
[ "$(grep -c 'Linux version' "$l")" = 4 ] && [ "$(grep -ac 'nyra-updated health-failed: Reboot' "$l")" = 3 ]

vm "v2 again, the retracted v8 was not finalized although the rollback deployment failed; v5 staged" --poweroff \
  --command "$lib; expect booted $d2 && expect rollback $d3 && expect staged none && ! test -e /boot/loader/entries.staged && running" \
  --command "$lib; outcome s5 Staged && expect staged $d5"

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
  --command "$lib; refused s7 'connect: connection refused' && expect staged none"
sudo podman start nyra-test-registry >/dev/null
for _ in $(seq 30); do curl -fs http://updates.nyraos.com/v2/ >/dev/null && break; sleep 1; done

top() { # the registry's file for the layer of image $1 with its version marker (the last layer
  # holds its UKI, see version())
  local layer
  layer="$(curl -fsS -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
    "http://updates.nyraos.com/v2/nyra-base/manifests/$1" | jq -r '.layers[-2].digest')"
  echo "/var/lib/registry/docker/registry/v2/blobs/sha256/${layer:7:2}/${layer:7}/data"
}
blob="$(top "$d7")"
sudo podman exec nyra-test-registry sh -c "cp $blob $blob.orig && printf CORRUPT | dd of=$blob bs=1 seek=64 conv=notrunc 2>/dev/null"
# Bytes changed inside the compressed layer: refused when the layer is read (its digest, or the
# decompression or unpacking that runs alongside).
vm "v5, a corrupted layer of v7" --poweroff \
  --command "$lib; refused s7 'Unable to pull container image.*(corrupted blob|decompression error|header error|unexpected end of file)' && expect staged none && expect booted $d5"
# A valid layer with other content and exactly the same size (tools/vm/same-size-layer.py): only the
# layer digest, checked by the image proxy against the signed manifest, can refuse it.
sudo podman cp "nyra-test-registry:$blob.orig" "$u/v7-top.orig"
sudo chown "$(id -u):$(id -g)" "$u/v7-top.orig"
python3 -I tools/vm/same-size-layer.py "$u/v7-top.orig" 2026.10.7 000000000 "$u/v7-top.same-size"
sudo podman cp "$u/v7-top.same-size" "nyra-test-registry:$blob"
vm "v5, a layer of the same size with other content in place of v7's" --poweroff \
  --command "$lib; refused s7 'Unable to pull container image.*FinishPipe.*corrupted blob, expecting' && expect staged none && expect booted $d5"
sudo podman exec nyra-test-registry sh -c "mv $blob.orig $blob"

vm "v5, registry repaired: v7 staged" --poweroff \
  --command "$lib; outcome s7 Staged && expect staged $d7 && expect booted $d5"

# Stale staged entries: a power cut between staging and finalization leaves loader/entries.staged
# on the ESP; the next update, to another version, must not carry them into its swap.
vm "v7: v9 staged; power cut before it is finalized" --power-cut-at POWERCUT \
  --command "$lib; expect booted $d7 && running" \
  --command "$lib; outcome s9 Staged && expect staged $d9 && ls /boot/loader/entries.staged && echo POWER''CUT"

vm "v7 after the power cut: v10 staged, nothing left from v9" --poweroff \
  --command "$lib; expect booted $d7 && running && expect staged none" \
  --command "$lib; outcome s10 Staged && expect staged $d10 && ls /boot/loader/entries.staged && test \"\$(ls /boot/loader/entries.staged | wc -l)\" = 2"

vm "v10 boots, with only its own entry and v7's" --poweroff \
  --command "$lib; expect booted $d10 && running && entries && test \"\$(entries | grep -c '^bootc_.*\.conf\$')\" = 2 && ! entries | grep -i '^nyra-recovery.*+'"

# Power cuts at random moments while nyra-updated pulls and stages v12 (not during finalization,
# which bootc does at shutdown): every time the running version comes back, and v12 is staged in the
# end. The seed is printed, so a failure can be replayed.
seed="${UPDATES_SEED:-$RANDOM}"
RANDOM="$seed"
echo "power cut seed: $seed"
for r in 1 2 3 4 5; do
  cut=$((RANDOM % 20))
  vm "v10: power cut $cut s after nyra-updated starts on v12 (round $r of 5, seed $seed)" --power-cut-at POWERCUT \
    --command "$lib; expect booted $d10 && running && expect staged none" \
    --command "$lib; select_sheet s12 && systemctl start --no-block nyra-updated.service && sleep $cut && echo POWER''CUT"
done
vm "v10 after the power cuts: v12 staged" --poweroff \
  --command "$lib; expect booted $d10 && running && expect staged none" \
  --command "$lib; outcome s12 Staged && expect staged $d12"

# A hostile network, on v12: a DNS answer that points to another host (a valid certificate, but for
# another name), a 50 kbit/s link, and a registry that stops answering in the middle of a pull. The
# test versions stop a pull after 90 s (stage_timeout_seconds); production keeps 2 hours.
vm "v12: another host for the update server, a slow link, a stalled registry; then v13 staged" --poweroff \
  --command "$lib; expect booted $d12 && running" \
  --command "$lib; select_sheet s13 && curl -fsS https://updates.nyraos.com/_test/cert/evil && { run_check; r=\$?; curl -kfsS https://updates.nyraos.com/_test/cert/good; test \$r != 0 && grep -q 'subject name matches' /var/lib/nyra-updated/last-check.json; }" \
  --command "$lib; curl -fsS https://updates.nyraos.com/_test/rate/50 && { refused s13 'timed out and was stopped'; r=\$?; curl -fsS https://updates.nyraos.com/_test/rate/0; test \$r = 0 && expect staged none; }" \
  --command "$lib; curl -fsS https://updates.nyraos.com/_test/rate/2000 && systemctl start --no-block nyra-updated.service && sleep 5 && test \"\$(systemctl show -P ActiveState nyra-updated.service)\" = activating && expect staged none && curl -fsS https://updates.nyraos.com/_test/stall && { while test \"\$(systemctl show -P ActiveState nyra-updated.service)\" = activating; do sleep 2; done; cat /var/lib/nyra-updated/last-check.json; r=0; grep -q 'timed out and was stopped' /var/lib/nyra-updated/last-check.json || r=1; curl -fsS https://updates.nyraos.com/_test/resume; curl -fsS https://updates.nyraos.com/_test/rate/0; test \$r = 0 && expect staged none; }" \
  --command "$lib; outcome s13 Staged && expect staged $d13"

# The secure defaults (tools/vm/security-defaults.sh, T15) after these updates: on v13, with the
# shipped signature policy linked again.
vm "v13: the shipped signature policy again, for the secure defaults check" --poweroff \
  --command "$lib; expect booted $d13 && running" \
  --command 'ln -sfn /usr/lib/nyra/containers/policy.json /etc/containers/policy.json && readlink /etc/containers/policy.json'
mkdir -p "$u/t15"
tools/vm/security-defaults.sh "$u/disk.qcow2" "$u/t15" "$summary"
cp "$u/t15/serial-security-defaults.log" "$logs/serial-security-defaults-after-updates.log"

# A broken kernel or initramfs (T3): v14's kernel finds no initramfs, panics and reboots after 10 s
# (panic=10 on the sealed command line), three times; then systemd-boot falls back to v13.
vm "v13: v14 staged" --poweroff \
  --command "$lib; expect booted $d13 && running" \
  --command "$lib; outcome s14 Staged && expect staged $d14"
vm "v14 panics three times, back on v13 by itself" --poweroff --boots 4 --timeout 300 \
  --command "$lib; expect booted $d13 && running && entries | grep -F +0-3" \
  --command "$lib; refused s14 'this machine fell back from it' && expect staged none"
l="$logs/serial-updates-$n.log"
echo "kernel starts: $(grep -c 'Linux version' "$l"), kernel panics: $(grep -ac 'Kernel panic' "$l")"
[ "$(grep -c 'Linux version' "$l")" = 4 ] && [ "$(grep -ac 'Kernel panic' "$l")" -ge 3 ]
