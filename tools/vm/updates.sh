#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: nyra-updated across real updates, on a copy of the installed test disk (docs/UPDATES.md).
# Titanic T2 (power cuts), T3 (a broken version, a good one with broken settings, a dead network), T4
# (signatures and versions), T5 (a hostile network), T9 (a wrong clock), the discard of a staged deployment
# (bootc rollback twice) and blessing after a soft reboot.
#
# Everything the guest trusts is made for this run and deleted with the runner: an image signing key
# (sigstore, the stand-in for our keyless signer: the guest's /etc/containers/policy.json is replaced
# by the shipped policy with this key), a channel sheet key (baked into the test versions'
# /usr/lib/nyra/updates/channel-sheet.pem, never into the image CI builds), and a CA for the TLS
# certificate of the sheet server. The guest reaches the runner as 10.0.2.2, which /etc/hosts on the
# test disk names updates.nyraos.com: the registry (tools/signing/local-registry.sh, plain HTTP) on
# port 80 and a sheet server on 443 that serves whichever signed sheet the guest selects.
#
# Test versions of IMAGE (v1-v17: 2026.10.1-17, the version in the manifest annotation bootc reads;
# v3 has a health check that always fails; v0 is unsigned), and the boots:
#   1  installed image: no sheet key, updates not configured (nothing fetched, unit not failed); unsigned refused by the shipped policy; test trust
#      set up; unsigned and wrongly signed refused; switch to v0 from another registry
#   2  v0: a foreign image, reported (ForeignImage); switch to v1 by its channel tag
#   3  v1: a sheet signed with another key refused; power cut while v2 downloads (throttled link)
#   4  v1: v2 staged again; power cut before the staged version is finalized
#   5  v1: v2 staged again, after a copy of /etc (nyra-updated makes one before it stages); clean
#      shutdown
#   6  power cut when v2's kernel starts (first try)
#   7  v2, second try, blessed; v4 staged, then retracted: discarded (never finalized); v11
#      staged by hand afterwards (discarded at shutdown too)
#   8  v2 again (boot order kept, no staged entries left); v3 staged
#   9  v3 fails its health check and reboots by itself, three times; systemd-boot falls back to v2;
#      v3 is marked failed, and bootc's order, which still has v3 first, is set right (rule 11); v3
#      refused; v8 staged, then retracted: discarded, with the failed v3 as rollback deployment
#  10  v2 again, v8 not finalized; v5 staged
#  11  v5, first try: captive portal, spoofed server, downgrade, replayed sheet refused; soft reboot
#      into v6: not blessed, system not degraded
#  12  v6, first full boot: signed retraction below the version floor refused; retraction to the
#      local rollback deployment (v5) uses bootc rollback, after a copy of /etc, and a second check
#      before the reboot does not run it again
#  13  v5, registry down: refused, nothing staged
#  14  v5, a corrupted layer of v7 in the registry: refused, nothing staged
#  15  v5, a valid layer of the same size with other content served for v7's: refused (digest)
#  16  v5, registry repaired: the settings broken (systemd-resolved masked, which shows at the next
#      boot); v7 staged
#  17  v7 fails its health check three times (the settings), systemd-boot falls back to v5, which
#      fails it too: it stays up, v7 is not marked failed, the console says to reset the settings;
#      the settings repaired by hand
#  18  v5 healthy: v7 offered again; its deployment, with the settings it failed with, deleted;
#      v7 staged afresh
#  19  v7 boots counted and is blessed; v9 staged; power cut before it is finalized (its staged
#      entries stay on the ESP)
#  20  v7: v10, another version, staged: only its entries and v7's are staged (none left from v9)
#  21  v10 boots; two boot entries (v10 and v7)
#  22-26  v10: power cuts at random moments while nyra-updated pulls and stages v12 (seed printed)
#  27  v10: v12 staged
#  28  v12: another host (valid certificate for another name), a 50 kbit/s link and a registry that
#      stalls mid-pull refused, nothing staged; v13 staged
#  29  v13: v14 staged (its initramfs is broken)
#  30  v14's kernel panics and reboots by itself, three times; systemd-boot falls back to v13;
#      v14 is marked failed, bootc's order set right, and v14 refused
#  31  v13, the hardware clock in 2099 (T9): ntpd-rs corrects it through NTS; v15 staged
#  32  v15, the hardware clock in 1970: the same; v16 staged
#  33  v16, the hardware clock in 2035: the same; up to date; ntpd-rs's cost measured
#  34  v16, the hardware clock in 2035, the NTS servers spoofed by a real NTS server with an
#      untrusted certificate: its times refused, the clock stays wrong (no unauthenticated NTP
#      request sent), the sheet server refused, unsigned images refused; the real servers back:
#      corrected, up to date
#  35  v16: the settings broken (systemd-resolved masked); v16 retracted, v13 (not a local
#      deployment) staged by switch
#  36  v13 fails its health check three times (the settings), systemd-boot falls back to v16, which
#      fails it too: v13 forgiven; bootc still reports v13 as the next boot; the settings repaired
#  37  v16: the retraction to the forgiven v13 deletes its deployment and stages it afresh
#  38  v13 boots counted and is blessed; the shipped signature policy linked again; then the secure
#      defaults check (T15)
#  39  v13, the test policy again; a dead network (T3): the link down before a check (it waits for the
#      network), then cut while v17 downloads: reported, the unit not failed, nothing staged or marked
#      failed; with no success for 15 days the unit fails; the link back: v17 staged
#  40  v17 boots counted and is blessed
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
for n in 0 1 4 5 6 7 8 9 10 11 12 13 15 16; do version "v$n" "2026.10.$n"; done
# v14: its UKI carries an initramfs of zeros, so the kernel panics (and reboots, panic=10).
BROKEN_INITRD=1 version v14 2026.10.14
# v2 and v17 carry 16 MiB that do not compress, so their download takes about a minute on a
# throttled link: the power cut of boot 3 and the network cut of boot 39 land in the middle of it.
version v2 2026.10.2 'RUN head -c 16777216 /dev/urandom > /usr/lib/nyra-test-payload'
version v17 2026.10.17 'RUN head -c 16777216 /dev/urandom > /usr/lib/nyra-test-payload'
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
  # A push takes seconds. One that stalls (as podman did on the loopback's 64 KiB MTU,
  # tools/signing/local-registry.sh) is stopped after 2 minutes and tried again, at most 3 times,
  # with what is needed to tell why: the TCP state of the connection and the kernel's counters.
  local try
  for try in 1 2 3; do
    sudo timeout 120 podman push -q --tls-verify=false --format oci --digestfile "$u/$1.digest" \
      ${3:+--sign-by-sigstore-private-key "$u/$3.private" --sign-passphrase-file "$u/pass"} \
      "localhost/nyra-test:$1" "docker://updates.nyraos.com/nyra-base:$2" && break
    echo "::warning::podman push of $1 failed or took more than 2 minutes (attempt $try of 3)"
    df -h / /mnt
    sudo ss -tnoiem '( sport = :80 or dport = :80 )' || true
    nstat -az 2>/dev/null | grep -E 'RcvQDrop|Prune|ZeroWindow|TCPTimeouts' || true
    sudo podman logs --tail 10 nyra-test-registry || true
    curl -sS -m 10 -o /dev/null -w 'registry /v2/: HTTP %{http_code} in %{time_total} s\n' http://updates.nyraos.com/v2/ || true
    if [ "$try" = 3 ]; then echo "::error::podman push of $1 failed 3 times"; return 1; fi
  done
  sudo chown "$(id -u):$(id -g)" "$u/$1.digest"
  [[ "$(cat "$u/$1.digest")" =~ ^sha256:[0-9a-f]{64}$ ]]
}
push v0 v0
push v1 stable sigstore
for n in 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17; do push "v$n" "v$n" sigstore; done
skopeo copy -q --dest-tls-verify=false --sign-by-sigstore-private-key /u/attacker.private \
  --sign-passphrase-file /u/pass oci-archive:/u/tiny.oci.tar docker://updates.nyraos.com/nyra-base:attacker
d0="$(cat "$u/v0.digest")" d1="$(cat "$u/v1.digest")" d2="$(cat "$u/v2.digest")" d3="$(cat "$u/v3.digest")"
d4="$(cat "$u/v4.digest")" d5="$(cat "$u/v5.digest")" d6="$(cat "$u/v6.digest")" d7="$(cat "$u/v7.digest")"
d8="$(cat "$u/v8.digest")" d9="$(cat "$u/v9.digest")" d10="$(cat "$u/v10.digest")"
d11="$(cat "$u/v11.digest")" d12="$(cat "$u/v12.digest")" d13="$(cat "$u/v13.digest")"
d14="$(cat "$u/v14.digest")" d15="$(cat "$u/v15.digest")" d16="$(cat "$u/v16.digest")"
d17="$(cat "$u/v17.digest")"
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
sheet s15 sheet 1500 "$d15" 2026.10.15 "$d4" "$d6"
sheet s16 sheet 1600 "$d16" 2026.10.16 "$d4" "$d6"
sheet r16 sheet 1700 "$d13" 2026.10.13 "$d4" "$d6" "$d16"
sheet s17 sheet 1800 "$d17" 2026.10.17 "$d4" "$d6" "$d16"
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
  --command "$lib; outcome s1 Staged && expect staged $d2 && expect_version staged 2026.10.2 && expect rollback $d0" \
  --command 'bootc status --format json' \
  --command 'echo POWER''CUT'

vm "v1 after the power cut: v2 staged again, after a copy of /etc" --poweroff \
  --command "$lib; expect booted $d1 && running && expect staged none" \
  --command "$lib; n=\$(ls /var/lib/nyra/etc-copies | grep -c -- '-update\$'); outcome s1 Staged && expect staged $d2 && m=\$(ls /var/lib/nyra/etc-copies | grep -c -- '-update\$') && echo \"copies of /etc made before an update: \$n, then \$m\" && test \"\$m\" -gt \"\$n\" && c=\$(ls /var/lib/nyra/etc-copies | grep -- '-update\$' | tail -n 1) && test -f /var/lib/nyra/etc-copies/\$c/removed && echo \"\$c: the format with the list of what was removed\""

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
  --command "$lib; expect booted $d2 && running && entries | grep -F +0-3 && test \"\$(queued)\" = true" \
  --command "$lib; outcome s4 RollbackUndone && test \"\$(queued)\" = false && expect rollback $d3 && grep -F $d3 /var/lib/nyra-updated/state.json" \
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
  --command "$lib; n=\$(ls /var/lib/nyra/etc-copies | grep -c -- '-rollback\$'); outcome retract6 RolledBack && expect rollback $d5 && test \"\$(queued)\" = true && m=\$(ls /var/lib/nyra/etc-copies | grep -c -- '-rollback\$') && echo \"copies of /etc made before a rollback: \$n, then \$m\" && test \"\$m\" -gt \"\$n\" && c=\$(ls /var/lib/nyra/etc-copies | grep -- '-rollback\$' | tail -n 1) && test -f /var/lib/nyra/etc-copies/\$c/removed && echo \"\$c: the format with the list of what was removed\"" \
  --command "$lib; outcome retract6 WaitingForReboot && expect rollback $d5 && test \"\$(queued)\" = true" \
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

# A good version and the machine's settings broken (T3, rule 12): systemd-resolved masked, as a user
# could, on a healthy boot of v5. It shows only at the next boot, and both v5 and v7 get it (v7's
# /etc is v5's, merged). v7 fails its health check three times and systemd-boot falls back to v5,
# which fails it too: the settings are to blame, not v7. v5 stays up, v7 is not marked failed, and the
# console and the login message say to reset the settings. The repair here is by hand (unmask):
# "Reset settings" would also undo this test's own trust in /etc (it is tested in T8). Then v7 is
# offered again: its deployment kept the /etc it failed with (bootc keeps one per deployment), so it
# is deleted and v7 is staged afresh, with today's settings; it boots counted and is blessed.
vm "v5, registry repaired: the settings broken (systemd-resolved masked); v7 staged" --poweroff \
  --command "$lib; expect booted $d5 && running && systemctl mask systemd-resolved.service" \
  --command "$lib; outcome s7 Staged && expect staged $d7"

vm "v7 fails its health check three times (the settings), back on v5, which fails it too" --poweroff --boots 4 \
  --command "$lib; expect booted $d5 && expect rollback $d7 && entries | grep -F +0-3" \
  --command "systemctl is-failed nyra-health-system.service && ! systemctl is-active boot-complete.target && { /usr/lib/nyra/health/system; true; } && journalctl -b -u nyra-updated-health-failed -o cat --no-pager | grep -F 'Stay(Some(' | grep -F $d7" \
  --command 'cat /run/issue.d/50-nyra-health.issue && cmp /run/issue.d/50-nyra-health.issue /run/motd.d/50-nyra-health.motd && grep -qF systemd-resolved.service /run/issue.d/50-nyra-health.issue && grep -qF "Nyra OS Reset settings" /run/issue.d/50-nyra-health.issue' \
  --command "$lib; outcome s7 NotHealthy && python3 -c 'import json, sys; s = json.load(open(\"/var/lib/nyra-updated/state.json\")); d = sys.argv[1]; sys.exit(s.get(\"pending\") == d or d in s.get(\"failed\", []) or s.get(\"forgiven\") != d)' $d7 && echo 'v7 is forgiven, neither pending nor failed'" \
  --command 'systemctl unmask systemd-resolved.service'
l="$logs/serial-updates-$n.log"
echo "kernel starts: $(grep -c 'Linux version' "$l")"
[ "$(grep -c 'Linux version' "$l")" = 4 ]

vm "v5, the settings repaired: v7 offered again, its old deployment deleted, staged afresh" --poweroff \
  --command "$lib; expect booted $d5 && running && ! test -e /run/issue.d/50-nyra-health.issue" \
  --command "$lib; outcome s7 Staged && expect staged $d7 && expect rollback none && grep -F $d7 /var/lib/nyra-updated/state.json"

# Stale staged entries: a power cut between staging and finalization leaves loader/entries.staged
# on the ESP; the next update, to another version, must not carry them into its swap. The first
# check on v7 also proves that it booted with a boot counter (rule 9).
vm "v7, counted and blessed: v9 staged; power cut before it is finalized" --power-cut-at POWERCUT \
  --command "$lib; expect booted $d7 && running && blessed" \
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

# A broken kernel or initramfs (T3), on v13's first boot (rule 9 needs the first check of a new
# version in a counted boot): v14's kernel finds no initramfs, panics and reboots after 10 s
# (panic=10 on the sealed command line), three times; then systemd-boot falls back to v13.
vm "v13: v14 staged" --poweroff \
  --command "$lib; expect booted $d13 && running" \
  --command 'grep -qw panic=10 /proc/cmdline && systemctl is-active nyra-health-bootc.service && test "$(systemctl show -P RestrictSUIDSGID nyra-health-bootc.service)" = no && test "$(systemctl show -P RestrictSUIDSGID nyra-health-system.service)" = yes && echo "panic=10; bootc health check passed, the only one without RestrictSUIDSGID"' \
  --command "$lib; outcome s14 Staged && expect staged $d14"
vm "v14 panics three times, back on v13 by itself" --poweroff --boots 4 --timeout 300 \
  --command "$lib; expect booted $d13 && running && entries | grep -F +0-3 && test \"\$(queued)\" = true" \
  --command "$lib; outcome s14 RollbackUndone && test \"\$(queued)\" = false && expect rollback $d14" \
  --command "$lib; refused s14 'this machine fell back from it' && expect staged none"
l="$logs/serial-updates-$n.log"
echo "kernel starts: $(grep -c 'Linux version' "$l"), kernel panics: $(grep -ac 'Kernel panic' "$l")"
[ "$(grep -c 'Linux version' "$l")" = 4 ] && [ "$(grep -ac 'Kernel panic' "$l")" -ge 3 ]

# A wrong clock (T9). The hardware clock in 2099 and in 1970: systemd sets the clock to the image's
# date at boot (/usr/lib/clock-epoch, the Debian snapshot date; a clock more than about 15 years
# after it counts as wrong too), still before the real time;
# in 2035 systemd keeps it, years ahead, outside the validity of every certificate. Each time ntpd-rs
# corrects it through NTS by itself (our patch: docs/DEFAULTS.md, "Time") and the update works,
# without anyone setting the clock. Then, with the clock in 2035 again, a hostile network: the NTS
# servers' names point to the runner (as a spoofed DNS answer would). There a real NTS server, the
# image's own ntp-daemon, completes the key exchange with a certificate the guest does not trust and
# serves the runner's time over NTS (UDP 1123), and an NTP server on UDP 123 answers every request,
# unauthenticated, with a time in 2001. The guest takes keys from the NTS server, but refuses every
# time it gives ("the server's certificate is not valid at that time", our patch): the clock stays in
# 2035 (with the certificate check removed, four agreeing sources would move it). ntpd-rs sends not
# one unauthenticated NTP request (no fallback): the server on UDP 123 counts exactly one, a probe
# the test sends itself to show that UDP 123 reaches it from the guest and its answer comes back; the sheet server's certificate is refused (expired) and
# nothing is staged; unsigned and wrongly signed images are still refused (image signatures do not
# depend on the clock). With the real servers back (once name resolution no longer answers with the runner:
# resolved can answer from its old copy of /etc/hosts right after the edit), ntpd-rs is restarted,
# corrects the clock and the system is up to date.
# Each boot comes from a file system last mounted at another time.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 -subj /CN=time.cloudflare.com \
  -addext subjectAltName=DNS:time.cloudflare.com,DNS:nts.netnod.se,DNS:ptbtime1.ptb.de,DNS:nts.time.nl \
  -keyout "$u/time.key" -out "$u/time.crt" 2>/dev/null
printf '%s\n' '[synchronization]' 'local-stratum = 1' '[[server]]' 'listen = "127.0.0.1:1123"' \
  '[[nts-ke-server]]' 'listen = "127.0.0.1:4460"' 'certificate-chain-path = "/k/time.crt"' \
  'private-key-path = "/k/time.key"' 'ntp-port = 1123' >"$u/fake-nts.toml"
sudo podman run -d --rm --name nyra-fake-nts --network host -v "$u/time.crt:/k/time.crt:ro" \
  -v "$u/time.key:/k/time.key:ro" -v "$u/fake-nts.toml:/k/fake-nts.toml:ro" "$image" \
  /usr/bin/ntp-daemon --config /k/fake-nts.toml >/dev/null
cat >"$u/fake-time.py" <<'EOF'
import socket, struct, sys
log = sys.argv[1]

def note(what):
    with open(log, "a") as f:
        f.write(what + "\n")

ntp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
ntp.bind(("127.0.0.1", 123))
t = 3187296000  # 2001-01-01 in NTP seconds
while True:  # UDP 123: every request answered without authentication, with the time in 2001
    req, addr = ntp.recvfrom(2048)
    note("ntp")
    if len(req) >= 48:
        ntp.sendto(struct.pack("!BBbbIII", 0x24, 1, 6, -20, 0, 0, 0x4c4f434c) +
                   struct.pack("!II", t, 0) + req[40:48] + struct.pack("!IIII", t, 0, t, 0), addr)
EOF
: >"$u/fake-time.log"
sudo python3 -I "$u/fake-time.py" "$u/fake-time.log" &
timeout 30 sh -c 'until ss -Htln "sport = :4460" | grep -q . && ss -Huln "sport = :1123" | grep -q . && ss -Huln "sport = :123" | grep -qF 127.0.0.1:123; do sleep 1; done'
trap 'sudo pkill -f sheet-server.py || true; sudo pkill -f fake-time.py || true; sudo podman rm -f -t 0 nyra-fake-nts >/dev/null 2>&1 || true; sudo tc qdisc del dev lo root 2>/dev/null || true' EXIT
tls_time='SSL certificate .*certificate (has expired|is not yet valid)'
unsigned="refused_switch updates.nyraos.com/nyra-base:v0 'A signature was required, but no signature exists' && refused_switch updates.nyraos.com/nyra-base:attacker 'cryptographic signature verification failed'"
vm "v13, the hardware clock in 2099: corrected through NTS; v15 staged" --poweroff \
  --rtc 2099-06-01T00:00:00 \
  --command "$lib; expect booted $d13 && running && synced $(date +%s)" \
  --command "$lib; outcome s15 Staged && expect staged $d15"
vm "v15, the hardware clock in 1970: corrected through NTS; v16 staged" --poweroff \
  --rtc 1970-01-01T00:00:00 \
  --command "$lib; expect booted $d15 && running && blessed && synced $(date +%s)" \
  --command "$lib; outcome s16 Staged && expect staged $d16"
vm "v16, the hardware clock in 2035: corrected through NTS; up to date" --poweroff \
  --rtc 2035-06-01T00:00:00 \
  --command "$lib; expect booted $d16 && running && blessed && synced $(date +%s)" \
  --command "$lib; outcome s16 UpToDate && expect staged none" \
  --command 'p="$(systemctl show -P MainPID ntpd-rs.service)" && ps -o rss=,vsz= -p "$p" && systemctl show -P MemoryCurrent ntpd-rs.service && c() { awk "/ctxt_switches/ {s += \$2} END {print s}" "/proc/$p/task/"*/status; } && a="$(c)" && sleep 60 && echo "ntpd-rs: $(( $(c) - a )) context switches in 60 s, CPU time $(systemctl show -P CPUUsageNSec ntpd-rs.service) ns since start"' \
  --command 'echo "10.0.2.2 time.cloudflare.com nts.netnod.se ptbtime1.ptb.de nts.time.nl" >> /etc/hosts'
vm "v16, the hardware clock in 2035, the NTS servers spoofed: the clock stays wrong, certificate refused, unsigned refused; the real servers back: corrected, up to date" --poweroff \
  --rtc 2035-06-01T00:00:00 \
  --command "$lib; expect booted $d16 && running && not_synced && date -u && test \"\$(date +%Y)\" = 2035" \
  --command 'for _ in $(seq 60); do journalctl -b -u ntpd-rs -o cat | grep -F "the server'"'"'s certificate is not valid at that time" && break; sleep 1; done && journalctl -b -u ntpd-rs -o cat | grep -qF "the server'"'"'s certificate is not valid at that time" && date -u && test "$(date +%Y)" = 2035' \
  --command "python3 -c 'import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(5); s.sendto(bytes([0x23]) + bytes(47), (\"10.0.2.2\", 123)); print(\"NTP probe: answer of\", len(s.recv(512)), \"bytes\")'" \
  --command "$lib; refused s16 '$tls_time' && expect staged none" \
  --command "$lib; $unsigned" \
  --command 'date -u && test "$(date +%Y)" = 2035 && sed -i "/ time.cloudflare.com /d" /etc/hosts && for _ in $(seq 10); do getent ahosts time.cloudflare.com nts.netnod.se ptbtime1.ptb.de nts.time.nl | grep -q "^10\.0\.2\.2 " || break; sleep 1; done && getent ahostsv4 time.cloudflare.com nts.netnod.se ptbtime1.ptb.de nts.time.nl && ! getent ahosts time.cloudflare.com nts.netnod.se ptbtime1.ptb.de nts.time.nl | grep -q "^10\.0\.2\.2 " && systemctl restart ntpd-rs.service' \
  --command "$lib; synced $(date +%s) && outcome s16 UpToDate && expect staged none"
sudo podman logs nyra-fake-nts 2>&1 | tail -5
sudo podman rm -f -t 0 nyra-fake-nts >/dev/null
ntp="$(grep -c '^ntp$' "$u/fake-time.log" || true)"
echo "spoofed time servers: $ntp unauthenticated NTP requests (1 expected: the test's own probe)"
if [ "$ntp" != 1 ]; then
  echo "::error::ntpd-rs must never send the spoofed servers an unauthenticated NTP request; the probe must reach the NTP server"
  exit 1
fi

# A retraction to a forgiven version (rule 12, then rule 6): v16 retracted, v13 is no longer a local
# deployment and is staged by switch, and the settings are broken as in boot 16. v13 fails its tries,
# systemd-boot falls back to v16, which fails too: v13 is forgiven. bootc does not see boot counting,
# so it still reports v13 as the next boot (rollbackQueued), with the /etc v13 failed with. Once the
# settings are repaired, the retraction must not wait for a reboot that would boot v16 again: v13's
# deployment is deleted and v13 staged afresh; it boots counted and is blessed.
vm "v16: the settings broken (systemd-resolved masked); v16 retracted, v13 staged by switch" --poweroff \
  --command "$lib; expect booted $d16 && expect rollback $d15 && running && systemctl mask systemd-resolved.service" \
  --command "$lib; outcome r16 Staged && expect staged $d13"

vm "v13 fails its health check three times (the settings), back on v16, which fails it too" --poweroff --boots 4 \
  --command "$lib; expect booted $d16 && expect rollback $d13 && test \"\$(queued)\" = true && entries | grep -F +0-3" \
  --command "systemctl is-failed nyra-health-system.service && journalctl -b -u nyra-updated-health-failed -o cat --no-pager | grep -F 'Stay(Some(' | grep -F $d13" \
  --command "$lib; outcome r16 NotHealthy && python3 -c 'import json, sys; s = json.load(open(\"/var/lib/nyra-updated/state.json\")); d = sys.argv[1]; sys.exit(s.get(\"pending\") == d or d in s.get(\"failed\", []) or s.get(\"forgiven\") != d)' $d13 && echo 'v13 is forgiven, neither pending nor failed'" \
  --command 'systemctl unmask systemd-resolved.service'
l="$logs/serial-updates-$n.log"
echo "kernel starts: $(grep -c 'Linux version' "$l")"
[ "$(grep -c 'Linux version' "$l")" = 4 ]

vm "v16, the settings repaired: the retraction to the forgiven v13 deletes its deployment, stages it afresh" --poweroff \
  --command "$lib; expect booted $d16 && running && expect rollback $d13 && test \"\$(queued)\" = true" \
  --command "$lib; outcome r16 Staged && expect staged $d13 && expect rollback none" \
  --command 'bootc status --format json'

# The secure defaults (tools/vm/security-defaults.sh, T15) after these updates: on v13, with the
# shipped signature policy linked again. The first check on v13 also proves that it booted with a
# boot counter (rule 9).
vm "v13, counted and blessed; the shipped signature policy again, for the secure defaults check" --poweroff \
  --command "$lib; expect booted $d13 && running && blessed && outcome r16 UpToDate && expect staged none" \
  --command 'ln -sfn /usr/lib/nyra/containers/policy.json /etc/containers/policy.json && readlink /etc/containers/policy.json'
mkdir -p "$u/t15"
tools/vm/security-defaults.sh "$u/disk.qcow2" "$u/t15" "$summary"
cp "$u/t15/serial-security-defaults.log" "$logs/serial-security-defaults-after-updates.log"

# A dead network (T3): the guest's network link goes down (tools/vm/updates-guest.sh, network), as a
# cable pulled out or a lost Wi-Fi would take it, first before a check, then while nyra-updated pulls
# v17 on a throttled link (the pull fails, or hangs until its time limit: 90 s here). A check started
# without a network waits for it (nyra-updated-wait-online.service; tools/vm/no-network.sh shows that
# it runs once the link is back): it has not started after 20 s, and is cancelled here, so the pull
# below starts when the test says. Each time the running version stays, nothing is staged, nothing is
# marked failed and nothing fails; the cut pull reports "no network connection" as a warning. Unless no
# check has succeeded for 14 days or more (the last success moved 15 days back, the link still down; the
# check started at once, not after the network): then it is an error and the unit fails.
# With the link back, the next check stages v17, which boots counted and is blessed. The test policy
# comes back first: boot 38 linked the shipped one.
vm "v13: a dead network, before a check and in the middle of the download of v17; the link back: v17 staged" --poweroff \
  --command "$lib; expect booted $d13 && running && ln -sfn /etc/nyra-test/policy.json /etc/containers/policy.json" \
  --command "$lib; select_sheet s17 && network down && systemctl start --no-block nyra-updated.service && sleep 20 && test \"\$(systemctl show -P ExecMainStartTimestampMonotonic nyra-updated.service)\" = 0 && systemctl list-jobs --no-legend --no-pager nyra-updated.service | grep -w start && systemctl stop nyra-updated.service && expect staged none && expect booted $d13 && running" \
  --command "$lib; network up && curl -fsS https://updates.nyraos.com/_test/rate/2000 && systemctl start --no-block nyra-updated.service && sleep 10 && test \"\$(systemctl show -P ActiveState nyra-updated.service)\" = activating && expect staged none && network down && { while test \"\$(systemctl show -P ActiveState nyra-updated.service)\" = activating; do sleep 2; done; cat /var/lib/nyra-updated/last-check.json; offline_reported $d17; }" \
  --command "$lib; no_success_since 15 && ! systemctl start --job-mode=ignore-dependencies nyra-updated.service; cat /var/lib/nyra-updated/last-check.json; grep -qF 'no successful check for 15 days: no network connection' /var/lib/nyra-updated/last-check.json && systemctl is-failed --quiet nyra-updated.service && systemctl reset-failed nyra-updated.service" \
  --command "$lib; expect staged none && expect booted $d13 && network up && curl -fsS https://updates.nyraos.com/_test/rate/0 && outcome s17 Staged && expect staged $d17 && running"
vm "v17 boots counted and is blessed" --poweroff \
  --command "$lib; expect booted $d17 && running && blessed && outcome s17 UpToDate && expect staged none"
