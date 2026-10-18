#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI only: Titanic T10, updates through nyra-updated on an encrypted disk with a TPM (docs/BOOT.md,
# "Disk encryption"; docs/UPDATES.md). Test versions of IMAGE, each with its UKI built and signed as
# in tools/vm/encryption-rotation.sh (ci/ukify.sh, the PCR 11 policy signed with policy key A, the
# next key B in /usr, the UKI signed for Secure Boot with a key made here, a MOK), and with a channel
# sheet key, as in tools/vm/updates.sh:
#   u0  2026.10.0  installed (for the VM's swtpm, tools/vm/install-encrypted.sh)
#   u1  2026.10.1  N, the stable tag
#   u2  2026.10.2  N+1
#   u3  2026.10.3  a health check that always fails
# All keys are made here; the private halves of the policy and Secure Boot keys are deleted once the
# versions are built. As in tools/vm/updates.sh, the guest reaches the runner as updates.nyraos.com:
# a registry on port 80, with the versions signed with a sigstore key the guest trusts, and on 443 a
# server that serves whichever signed channel sheet the guest selects. Secure Boot on, one firmware
# variable store, the test console add-on on the ESP (part of the enrolled PCR 12). The boots, none of
# which may ask for the disk (nothing is ever typed):
#   1. u0's first boot unlocks by itself and enrolls the disk; test trust set up; switch to N by its
#      channel tag;
#   2. N unlocks by itself; nyra-updated stages N+1 from the signed sheet;
#   3. N+1 unlocks by itself and is blessed; back to N by hand (bootc rollback, "go back to the
#      previous version");
#   4. N unlocks by itself; N+1 is held back; a sheet offers u3, which nyra-updated stages;
#   5. u3 fails its health check and reboots by itself, three times, each boot unlocked by the TPM;
#      systemd-boot falls back to N, which unlocks by itself; u3 marked failed and refused;
#   6. read offline: the recovery key slot and the two TPM2 enrollments of the first boot, unchanged;
#      one enrollment and no re-enrollment in the disk's journal.
#   tools/vm/encryption-updates.sh IMAGE WORKDIR LOGDIR SUMMARY
set -euo pipefail

image="$1" work="$2/encryption-updates" logs="$3" summary="$4"
# swtpm's state under LOGDIR (RUNNER_TEMP): Ubuntu's AppArmor profile for swtpm allows no other place.
tpm="$logs/encryption-updates-state"
secrets="$work/secrets" keys="$work/keys" ctx="$work/context"
mnt="$work/esp"
loop=""
mkdir -p "$work" "$tpm" "$mnt" "$ctx" "$work/sheets"
mkdir -m 0700 "$secrets" "$keys"
cleanup() {
  sudo umount -q "$mnt" 2>/dev/null || true
  [ -z "$loop" ] || sudo losetup -d "$loop" || true
  sudo pkill -f encryption-sheet-server.py || true
  sudo podman rm -f nyra-test-registry >/dev/null 2>&1 || true
  local v
  for v in u0 u1 u2 u3; do
    sudo podman rmi -f "localhost/nyra-test:enc-$v" "localhost/nyra-test:enc-$v-rootfs" >/dev/null 2>&1 || true
  done
  sudo rm -rf "$secrets" "$keys" "$tpm" "$work"
}
trap cleanup EXIT

start=$SECONDS
# --- keys ------------------------------------------------------------------------------------------
for k in A B; do
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$keys/$k.key" 2>/dev/null
  openssl pkey -in "$keys/$k.key" -pubout -out "$keys/$k.pem"
done
openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=Nyra CI update test key" \
  -keyout "$keys/sb.key" -out "$work/sb.crt" 2>/dev/null
openssl genpkey -algorithm ed25519 -out "$keys/sheet.key"
openssl pkey -in "$keys/sheet.key" -pubout -out "$ctx/channel-sheet.pem"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 -subj /CN=nyra-test-ca \
  -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign \
  -keyout "$keys/ca.key" -out "$work/ca.crt" 2>/dev/null
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj /CN=updates.nyraos.com \
  -keyout "$keys/server.key" -out "$work/server.csr" 2>/dev/null
openssl x509 -req -in "$work/server.csr" -CA "$work/ca.crt" -CAkey "$keys/ca.key" -CAcreateserial -days 2 \
  -extfile <(printf 'subjectAltName=DNS:updates.nyraos.com\nextendedKeyUsage=serverAuth\n') \
  -out "$work/server.crt" 2>/dev/null
echo nyra-updates-test > "$keys/pass"
sudo podman run --rm --network none --tmpfs /var/tmp -v "$keys:/k:z" "$image" \
  skopeo generate-sigstore-key --output-prefix /k/sigstore --passphrase-file /k/pass >/dev/null
sudo chown -R "$(id -u):$(id -g)" "$keys"
cp "$keys/sigstore.pub" "$work/sigstore.pub"

# --- versions --------------------------------------------------------------------------------------
cat > "$work/kernel-from-uki.py" <<'EOF'
import sys
import pefile
pe = pefile.PE(sys.argv[1])
for s in pe.sections:
    name = {b".linux": "vmlinuz", b".initrd": "initramfs.img"}.get(s.Name.rstrip(b"\0"))
    if name:
        with open(f"{sys.argv[2]}/{name}", "wb") as f:
            f.write(s.get_data()[:s.Misc_VirtualSize])
EOF
cp "$keys/B.pem" "$ctx/next.pem"
# The health check of u3, one of nyra-updated's (nyra-health-*.service: OnFailure= reboots).
unhealthy="RUN printf '%s\\n' '[Unit]' 'Description=Test only: a health check that always fails' \\
      '[Service]' 'Type=oneshot' 'ExecStart=/usr/bin/false' > /usr/lib/systemd/system/nyra-health-test.service && \\
    ln -s ../nyra-health-test.service /usr/lib/systemd/system/boot-complete.target.requires/"
version() { # version NAME VERSION [unhealthy]: as in tools/vm/encryption-rotation.sh, with key A
  local name="$1" d="$work/$1" f b
  { echo "FROM $image"; echo "RUN rm -rf /boot/EFI"
    echo "COPY next.pem /usr/lib/nyra/secureboot/tpm2-pcr-public-key-next.pem"
    echo "COPY channel-sheet.pem /usr/lib/nyra/updates/channel-sheet.pem"
    echo "RUN echo $name > /usr/lib/nyra-test-version"
    [ "${3:-}" != unhealthy ] || echo "$unhealthy"
  } | sudo podman build -q -t "localhost/nyra-test:enc-$name-rootfs" -f - "$ctx" >/dev/null
  mkdir -p "$d/pcr" "$d/unsigned" "$d/policy" "$d/signed"
  cp "$keys/A.pem" "$d/pcr/tpm2-pcr-public-key.pem"
  sudo podman run --rm --network none --tmpfs /tmp --tmpfs /var/tmp --tmpfs /kernel \
    --mount "type=image,source=localhost/nyra-test:enc-$name-rootfs,target=/target" \
    -v "$work/kernel-from-uki.py:/kernel-from-uki.py:ro" -v "$PWD/ci/ukify.sh:/ukify.sh:ro" \
    -v "$d/pcr:/pcr:ro" -v "$d/unsigned:/out" "$image" \
    sh -c 'u="$(ls /boot/EFI/Linux/*.efi)" && k="$(basename "$u" .efi)" && mkdir -p "/kernel/$k" &&
      python3 /kernel-from-uki.py "$u" "/kernel/$k" && sh /ukify.sh' >/dev/null
  sudo chown -R "$(id -u):$(id -g)" "$d"
  f="$(ls "$d"/unsigned/*.efi)" && b="${f##*/}"
  python3 -I tools/signing/uki-check.py "$f" ci/uki-cmdline.txt
  python3 -I tools/signing/pcr-policy.py sign "$f" "$keys/A.key" > "$d/pcr/pcrsig.json"
  sudo podman run --rm --network none --tmpfs /tmp --tmpfs /var/tmp -v "$d/unsigned:/in:ro" \
    -v "$d/pcr:/pcr:ro" -v "$d/policy:/out" "$image" \
    ukify build --join-pcrsig "/in/$b" --pcrsig @/pcr/pcrsig.json --output "/out/$b" >/dev/null
  sudo chown -R "$(id -u):$(id -g)" "$d"
  python3 -I tools/signing/pcr-policy.py check "$d/policy/$b" "$keys/A.pem"
  sbsign --key "$keys/sb.key" --cert "$work/sb.crt" --output "$d/signed/$b" "$d/policy/$b" >/dev/null
  printf 'FROM localhost/nyra-test:enc-%s-rootfs\nCOPY --from=uki . /boot/EFI/Linux/\n' "$name" |
    sudo podman build -q --annotation "org.opencontainers.image.version=$2" -t "localhost/nyra-test:enc-$name" \
      --build-context uki="$d/signed" -f - "$ctx" >/dev/null
}
version u0 2026.10.0
version u1 2026.10.1
version u2 2026.10.2
version u3 2026.10.3 unhealthy
tools/vm/test-addon.sh "$image" "$work/console.addon.efi" systemd.import_credentials=yes "$keys/sb.key" "$work/sb.crt"
rm -f "$keys"/A.key "$keys"/B.key "$keys"/sb.key

# --- registry and sheets ---------------------------------------------------------------------------
sudo podman rm -f nyra-test-registry >/dev/null 2>&1 || true
tools/signing/local-registry.sh "$work"
sudo mkdir -p /etc/containers/registries.d
printf 'docker:\n  updates.nyraos.com:\n    use-sigstore-attachments: true\n' |
  sudo tee /etc/containers/registries.d/99-nyra-updates-test.yaml >/dev/null
push() { # push NAME TAG: signed with the test sigstore key; prints the digest
  local try
  for try in 1 2 3; do
    sudo timeout 300 podman push -q --tls-verify=false --format oci --digestfile "$work/$1.digest" \
      --sign-by-sigstore-private-key "$keys/sigstore.private" --sign-passphrase-file "$keys/pass" \
      "localhost/nyra-test:enc-$1" "docker://updates.nyraos.com/nyra-base:$2" >&2 && break
    echo "::warning::podman push of $1 failed or took more than 5 minutes (attempt $try of 3)" >&2
    [ "$try" != 3 ] || return 1
  done
  sudo cat "$work/$1.digest"
}
d1="$(push u1 stable)"
d2="$(push u2 u2)"
d3="$(push u3 u3)"
for d in "$d1" "$d2" "$d3"; do [[ "$d" =~ ^sha256:[0-9a-f]{64}$ ]]; done
sheet() { # sheet NAME SEQUENCE DIGEST VERSION: a channel sheet signed as in tools/vm/updates.sh
  local type=application/vnd.nyra.channel-sheet.v1+json now
  now="$(date +%s)"
  jq -cnj --argjson seq "$2" --argjson now "$now" --arg d "$3" --arg v "$4" \
    '{schema: 1, repository: "nyra-base", channel: "stable", sequence: $seq, issued_at: $now,
      expires_at: ($now + 604800), current: {digest: $d, version: $v}, previous: null,
      percent: 100, halted: false, retracted: []}' > "$work/payload"
  { printf 'DSSEv1 %d %s %d ' ${#type} "$type" "$(wc -c < "$work/payload")"; cat "$work/payload"; } > "$work/pae"
  openssl pkeyutl -sign -inkey "$keys/sheet.key" -rawin -in "$work/pae" -out "$work/sig"
  jq -cn --arg t "$type" --arg p "$(base64 -w0 < "$work/payload")" --arg s "$(base64 -w0 < "$work/sig")" \
    '{payloadType: $t, payload: $p, signatures: [{keyid: "", sig: $s}]}' > "$work/sheets/$1"
}
sheet s2 200 "$d2" 2026.10.2
sheet s3 300 "$d3" 2026.10.3
# The sheet server: /_test/select/NAME picks the sheet that /channels/nyra-base/stable serves.
cat > "$work/encryption-sheet-server.py" <<'EOF'
import http.server, os, ssl, sys
sheets, cert, key = sys.argv[1:4]
state = {"sheet": "none"}

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/_test/select/"):
            state["sheet"] = os.path.basename(self.path)
            body = b"ok\n"
        elif self.path == "/channels/nyra-base/stable" and os.path.exists(os.path.join(sheets, state["sheet"])):
            body = open(os.path.join(sheets, state["sheet"]), "rb").read()
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
sudo python3 -I "$work/encryption-sheet-server.py" "$work/sheets" "$work/server.crt" "$keys/server.key" &
for _ in $(seq 30); do curl -fs --cacert "$work/ca.crt" https://updates.nyraos.com/_test/select/s2 > /dev/null && break; sleep 1; done
curl -fsS --cacert "$work/ca.crt" https://updates.nyraos.com/channels/nyra-base/stable | jq -e .payloadType > /dev/null

# --- the disk --------------------------------------------------------------------------------------
tools/vm/install-encrypted.sh localhost/nyra-test:enc-u0 "$work" "$secrets" "$tpm"
virt-fw-vars --input /usr/share/OVMF/OVMF_VARS_4M.ms.fd --output "$work/vars.fd" \
  --add-mok 605dab50-e046-4300-abb6-3dd810dd8b23 "$work/sb.crt"
loop="$(sudo losetup -P --show -f "$work/disk.raw")"
sudo mount "$(tools/vm/esp-of.sh "$loop")" "$mnt"
sudo mkdir -p "$mnt/loader/addons"
sudo cp "$work/console.addon.efi" "$mnt/loader/addons/nyra-test-console.addon.efi"
sudo umount "$mnt" && sudo losetup -d "$loop" && loop=""
{
  echo "## Updates through nyra-updated on an encrypted disk (Titanic T10)"
  echo
  echo "Four test versions (policy key A, next key B), built, pushed and u0 installed for a TPM in $((SECONDS - start)) s; swtpm, Secure Boot on; N is u1."
  echo
} >> "$summary"

# --- the guest -------------------------------------------------------------------------------------
put() { # guest commands that write the local file $1 to $2, in pieces the console takes
  local b64 i
  b64="$(base64 -w0 < "$1")"
  echo "--command"
  echo "mkdir -p \"\$(dirname $2)\" && : > $2.b64"
  for ((i = 0; i < ${#b64}; i += 1500)); do
    echo "--command"
    echo "printf %s ${b64:i:1500} >> $2.b64"
  done
  echo "--command"
  echo "base64 -d $2.b64 > $2 && rm $2.b64"
}
cat > "$work/policy.json" <<'EOF'
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
printf '[[registry]]\nlocation = "updates.nyraos.com"\ninsecure = true\n' > "$work/99-nyra-test.conf"
mapfile -t setup < <(
  put tools/vm/updates-guest.sh /var/lib/nyra-test/lib.sh
  put "$work/policy.json" /etc/nyra-test/policy.json
  put "$work/sigstore.pub" /etc/nyra-test/sigstore.pub
  put "$work/ca.crt" /usr/local/share/ca-certificates/nyra-test.crt
  put "$work/99-nyra-test.conf" /etc/containers/registries.conf.d/99-nyra-test.conf
)
lib='. /var/lib/nyra-test/lib.sh'
is() { echo "test \"\$(cat /usr/lib/nyra-test-version)\" = $1 && echo 'version: $1'"; }
enrolled='journalctl -b -o cat -u nyra-tpm-enroll.service | grep nyra-tpm-enroll:'
fail=0
n=0
vm() { # vm TITLE ARGS...
  local title="$1"
  shift
  n=$((n + 1))
  python3 -B tools/vm/vm-boot.py --secure-boot "$work/vars.fd" --keep-vars --tpm "$tpm" --disk "$work/disk.raw" \
    --persist --poweroff --autologin --timeout 240 --log "$logs/serial-encryption-updates-$n.log" \
    --summary "$summary" --title "Encrypted updates, boot $n: $title" "$@" || fail=1
  # Nothing is typed in this test: a boot that asks for the disk did not unlock with the TPM.
  if grep -q -a -E "Please enter (passphrase or )?recovery key for disk" "$logs/serial-encryption-updates-$n.log"; then
    echo "::error::encrypted updates, boot $n asked for the disk"
    fail=1
  fi
}

vm "u0 unlocks by itself and enrolls the disk; test trust; switch to N" \
  "${setup[@]}" \
  --command "$(is u0)" --command "$lib; running" --command "$enrolled | grep 'enrolled with the TPM'" \
  --command 'echo "10.0.2.2 updates.nyraos.com" >> /etc/hosts && update-ca-certificates >/dev/null 2>&1' \
  --command 'ln -sfn /etc/nyra-test/policy.json /etc/containers/policy.json' \
  --command 'bootc switch --quiet updates.nyraos.com/nyra-base:stable'
vm "N unlocks by itself; N+1 staged from the signed sheet" \
  --command "$(is u1)" --command "$lib; expect booted $d1 && running" \
  --command "$lib; outcome s2 Staged && expect staged $d2"
vm "N+1 unlocks by itself; back to N by hand" \
  --command "$(is u2)" --command "$lib; expect booted $d2 && running && blessed" \
  --command "$lib; outcome s2 UpToDate" \
  --command "$lib; bootc rollback && test \"\$(queued)\" = true"
vm "N by hand unlocks by itself; N+1 held back; u3 staged" \
  --command "$(is u1)" --command "$lib; expect booted $d1 && expect rollback $d2 && running" \
  --command "$lib; outcome s2 HeldBack && expect staged none" \
  --command "$lib; outcome s3 Staged && expect staged $d3"
vm "u3 fails its health check three times, each boot unlocked by the TPM; back on N by itself" --boots 4 \
  --command "$(is u1)" --command "$lib; expect booted $d1 && running && entries | grep -F +0-3 && test \"\$(queued)\" = true" \
  --command "$lib; outcome s3 RollbackUndone && test \"\$(queued)\" = false && expect rollback $d3" \
  --command "$lib; refused s3 'this machine fell back from it' && expect staged none"
l="$logs/serial-encryption-updates-$n.log"
starts="$(grep -c 'Linux version' "$l" || true)"
echo "kernel starts: ${starts:-none (no serial log)}"
[ "$starts" = 4 ] || { echo "::error::the fallback from u3 took ${starts:-no} kernel starts, not 4"; fail=1; }

# Read offline: the header and the disk's journal (with the recovery key).
root_start="$(sfdisk -J "$work/disk.raw" | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["partitiontable"]["partitions"][1]["start"])')"
check() { # check WHAT EXPECTED GOT
  local mark=OK
  if [ "$2" != "$3" ]; then mark=WRONG; fail=1; fi
  echo "encryption-updates: $1: expected $2, got $3 [$mark]"
  printf '| %s | `%s` | %s |\n' "$1" "$3" "$mark" >> "$summary"
}
{ echo "| Check | Result | |"; echo "|---|---|---|"; } >> "$summary"
dd if="$work/disk.raw" of="$work/header" bs=512 skip="$root_start" count=32768 status=none
check "Key slots at the end" "1 systemd-recovery, 2 systemd-tpm2" \
  "$(sudo podman run --rm --network none -v "$work/header:/header:ro" "$image" cryptsetup luksDump --dump-json-metadata /header |
    python3 -I -c 'import json, sys, collections; c = collections.Counter(t["type"] for t in json.load(sys.stdin)["tokens"].values()); print(", ".join(f"{n} {t}" for t, n in sorted(c.items())))')"
loop="$(sudo losetup -P --show -f "$work/disk.raw")"
for _ in $(seq 50); do [ -b "${loop}p2" ] && break; udevadm settle --timeout=10 || true; sleep 0.2; done
lines="$(timeout 600 sudo podman run --rm -i --privileged --network none -e DM_DISABLE_UDEV=1 -v /dev:/dev -v "$secrets:/secrets:ro" "$image" \
  bash -s "${loop}p2" <<'EOF' || true
set -euo pipefail
cryptsetup open --readonly --key-file /secrets/recovery-key "$1" nyra-check-root
trap 'umount -q /target 2>/dev/null || true; cryptsetup close nyra-check-root' EXIT
mkdir -p /target && mount -o ro,noload /dev/mapper/nyra-check-root /target
journalctl --directory="$(dirname "$(find /target/state -name 'system.journal' -print -quit)")" -o cat \
  -u nyra-tpm-enroll.service --no-pager | grep '^nyra-tpm-enroll:'
EOF
)"
sudo losetup -d "$loop" && loop=""
printf '%s\n' "$lines"
# No line at all (the root could not be read) is not "no other line".
[ -n "$lines" ] || lines="(nothing read from the disk's journal)"
check "Enrollments in the disk's journal (boot 1)" 1 "$(printf '%s\n' "$lines" | grep -c '^nyra-tpm-enroll: enrolled with the TPM (' || true)"
check "Other lines of nyra-tpm-enroll in the disk's journal" 0 "$(printf '%s\n' "$lines" | grep -vc '^nyra-tpm-enroll: enrolled with the TPM (' || true)"
echo >> "$summary"
exit "$fail"
