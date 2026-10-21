# Image signing

Every release image of nyra-base is signed in CI, keylessly, and Nyra machines refuse images
from our registry that do not carry that signature.

## How an image is signed

1. **Release build without cached content.** A push to `main` (or a manual run on `main`) builds the
   image from scratch: bootc compiled from its pinned commit (its Cargo.lock moved to zlink 0.7.1 for a
   reproducible build and pinned by hash, `ci/build-bootc.sh`), every Debian package downloaded from
   the pinned snapshot, nyra-updated's crates downloaded once, each checked against its `Cargo.lock`
   and compiled from that checked copy, without the registry index (`ci/build-image.sh`,
   `Containerfile`). The caches (compiled bootc, downloaded packages) are used only by pull requests,
   whose images are never signed. A cache is not trusted, so no job of a release unpacks one: they only
   look caches up, to save one that is missing (`ci/check-release-cache.py` checks this in CI). The
   release's bootc is compared with the build cached on `main` by a separate job, `bootc-reproducible`,
   with no permissions and no checkout; a difference stops the `sign` job. The jobs of a run can
   replace each other's artifacts, so every job that uses the image artifact (`install-boot-system`,
   `install-boot-updates`, `install-boot-updates-more`, `encryption`, `boot-repeat`, `sign`, the Titanic jobs) first checks it against the sha256 that `build` reported as
   a job output (on a release, the one `release-image` reported: `ci/check-artifact.sh`); `build` also
   reports the SBOM's.
   On a release (the "release mode", below), the release build leaves its UKI unsigned and the next
   two jobs sign it before any test runs.
2. **The `sign` job** (`.github/workflows/image.yml`) runs only for release builds, only on
   GitHub-hosted runners; `sign`, `release-sign` and `release-sign-arm64` are the only jobs with
   `id-token: write`, and
   `sign` is the only job in the GitHub environment `sign`:
   - GitHub issues an OIDC token for the workflow run;
   - Google Workload Identity Federation (the pool `github-sign`) accepts it only for this
     repository, `refs/heads/main`, the `image.yml` workflow, a `push` or `workflow_dispatch` event,
     a GitHub-hosted runner and the environment `sign`, and returns an ID token for the
     service account `GCP_SIGNER_SA`;
   - Fulcio (the public Sigstore CA) issues a 10-minute certificate for the service account's
     e-mail address; cosign signs the image manifest digest and records the signature in Rekor
     (the public Sigstore transparency log).

   No signing key exists anywhere: nothing to steal from CI, from the build server or from a
   developer. A self-hosted runner, a pull request, a fork or another workflow gets no token; who
   can still make the workflow sign is listed under "Who can sign" below.
3. **What is signed:** the manifest digest of the image, under the name
   `updates.nyraos.com/nyra-base`, the name clients use. Signing happens against a throwaway
   registry on the runner (`127.0.0.1`, reached as `updates.nyraos.com` through `/etc/hosts`);
   nothing is published.
4. **Output** (artifact `nyra-base-signature`, for publishing, see "Publishing" below): an OCI
   layout with the signature tagged `sha256-<digest>.sig`, exactly as it must appear on the
   registry, plus `image-digest`. The image itself is the `nyra-base-oci-archive` artifact (same
   digest; `nyra-base-release-oci-archive` on a release). `sign` checks that the layout holds
   exactly one manifest, tagged so, and reports `image_digest` and `signature_digest` as job
   outputs: the publish job takes every digest from those, never from the artifacts.

The signature uses cosign's older format: a `sha256-<digest>.sig` tag whose layer carries the
certificate and the Rekor v1 signed entry timestamp (SET). It is the only format that
containers/image (bootc, podman, skopeo) verifies today; cosign 3 defaults to the new bundle
format, hence `--new-bundle-format=false --use-signing-config=false`.

## The UKI release gate

A release signature says "Nyra machines may install this image". An image whose UKI is not signed
with the Nyra Secure Boot key would install and then fail to boot under Secure Boot, so it must never
get one. Before anything else, the `sign` job runs `tools/signing/uki-gate.sh` on the image's `/boot`
with the Nyra UKI certificate committed in this repository,
`files/usr/lib/nyra/secureboot/nyra.crt` (PEM; it also ships in the image, for the
installer), and the public key of the Nyra PCR policy key,
`files/usr/lib/nyra/secureboot/tpm2-pcr-public-key.pem` (see "The PCR policy key" below). It refuses
unless:

- `/boot` holds exactly one file, `EFI/Linux/<kernel version>.efi`, and nothing else: no second UKI,
  no add-on (`<uki>.efi.extra.d/`), since `bootc install` installs what it finds there;
- that file is the sealed UKI (`tools/signing/uki-check.py`), its sections read as systemd-stub reads
  them (see "Reading the UKI as systemd-stub does" below): exactly one `.linux` section (a kernel, so
  not an add-on or another PE file); one `.cmdline` in the base sections, which profile 0 inherits;
  exactly these sections in each profile, in this order: `.profile` and `.pcrsig` (its PCR policy) in
  profile 0, `.profile` and its own `.cmdline` in each further one (so no `.initrd` or anything else
  of their own), with as many profiles as lines in `ci/uki-cmdline.txt`; each command line exactly
  its line, byte for byte, with one composefs digest in all of them; and one `.sbat` section with the
  Nyra component line (docs/BOOT.md, "SBAT");
- it carries the PCR 11 policy for TPM2 unlock signed for its main profile's initrd alone, with that
  policy key (`tools/signing/pcr-policy.py check`, docs/BOOT.md "TPM2 unlock");
- it is signed with that certificate (`sbverify --cert`), and carries no other signature: exactly one
  Authenticode signature. `sbverify --cert` passes when any one of a file's signatures verifies, so a
  second one would make the UKI acceptable to whoever trusts that other key.

The certificate and both PCR policy keys are committed (see "The PCR policy key"). The
`release-sign` job signs every release UKI with the Nyra keys, and the gate refuses every other
image (pull requests, Titanic).

"Exactly one UKI": the image ships one UKI file. Its three profiles (main, recovery, reset settings,
docs/BOOT.md) are sections of that one signed file, not separate UKIs. The fallback UKI
(`EFI/Linux/nyra-fallback-<digest>+0.efi`) exists only on a machine's ESP: `esp-sync` copies the UKI
bootc installed there, so it is the same signed file and nothing new is signed for it.

The same checks guard the signing step itself (`tools/signing/sign-uki.sh IN_DIR OUT_DIR --key KEY
--cert CERT [--engine ENGINE]`, called by step 3 of `ci/build-image.sh`; KEY is a file, or a `pkcs11:`
URI with `--engine`; no other option, repeated option or missing `--key`/`--cert` is accepted). It is
the only script that signs a UKI (a lint in `shellcheck.yml` refuses `sbsign` with an engine or a
`pkcs11` key anywhere else), and `tools/signing/test-sign-uki.sh` tests it with stub `sbsign` and
`sbverify`. It signs exactly one regular file (a symlink is refused) of IN_DIR, read once into a private
copy that is checked and signed; the input must carry no signature yet, OUT_DIR must not exist, and
after signing `sbverify --cert CERT` and `uki-check.py` (exactly one signature) must accept the output.
It signs only if `uki-check.py` accepts the copy and, once its PCR policy is signed,
`pcr-policy.py check` too, so the key that signs UKIs never signs an add-on (which would
apply to every Nyra UKI) or a UKI with another command line. A change to the sealed command line
(`kargs.d`, the profiles in `ci/ukify.sh`) therefore needs a matching change to `ci/uki-cmdline.txt`
in the same review. The composefs digest is not compared with the image here: bootc refuses a UKI whose
digest does not match at install time, and `sign` runs only after `install-boot` installed and booted
this image (and after the `encryption` job's tests passed on it).

### Reading the UKI as systemd-stub does

The checks are only as good as their reading of the file, and pefile, which they use, reads a PE file
differently from systemd-stub in places. The stub, in turn, reads the sections in memory, as the
loader put them there: shim's loader (shim replaces the firmware's), or the firmware's for a key in
`db`. Both `uki-check.py` and `pcr-policy.py` therefore read the sections through
`tools/signing/pe_sections.py`, which reads them the way the stub does after the loader, and refuses
any file where the two readings could differ:

- sections in the order of the section table, the order the stub reads them in and groups them into
  profiles by (pefile's own list is sorted by address);
- a section name ends at its first NUL, as the stub compares it (`.linux\0x` is a `.linux`);
- a section's data is what the loader puts in memory: VirtualSize bytes, the file's data up to
  SizeOfRawData, then zeros;
- refused: any pefile warning, and a section header pefile did not read (it stops at some malformed
  headers with only a warning, while the stub reads on); a section the loader does not copy as it is
  in the file: one without `IMAGE_SCN_MEM_READ` or with `IMAGE_SCN_MEM_DISCARDABLE` (shim does not
  copy it; only `.reloc` may be discardable, and shim reads it from the file) or with
  `IMAGE_SCN_CNT_UNINITIALIZED_DATA` (shim fills it with zeros); a section empty in memory,
  overlapping the headers or another section in memory, or reaching beyond SizeOfImage (the stub
  ignores it); section data that is not in the file before the certificate table (the signature does
  not cover it); a base relocation that changes anything but the stub's own code and data (`.text`,
  `.rodata`, `.data`: the loader applies them in memory, after the signature check), and a relocation
  table anywhere but at the start of the `.reloc` section (where shim reads it); two sections of one
  name in the base sections or in one profile (the stub takes the first); a certificate table other
  than none (before signing) or one PKCS#7 entry at the end of the file, DER with one-byte tags, with
  one signer, no unsigned attributes (a nested signature is one) and nothing after it in the entry.

A command line is compared byte for byte, without trimming whitespace; only trailing NULs are cut,
since the stub stops at the first NUL, and every byte must be printable ASCII (0x20 to 0x7e). Under
Secure Boot a profile without its own `.cmdline` boots with the base one, or, with no base one, with
whatever the boot loader passes: hence the exact layout above.

## How a machine verifies it

The policy ships in `/usr` (read-only, verified by fs-verity, updated with every image):

| File | Content |
|---|---|
| `/usr/lib/nyra/containers/policy.json` | for `docker://updates.nyraos.com/*`: `sigstoreSigned`, Fulcio certificate issued by Google's OIDC (`https://accounts.google.com`) to the signer's e-mail address, Rekor SET required, `signedIdentity: matchRepository` |
| `/usr/lib/nyra/containers/registries.d/nyra.yaml` | `use-sigstore-attachments` for `updates.nyraos.com` |
| `/usr/lib/nyra/sigstore/fulcio-ca.pem`, `rekor.pub` | the Sigstore trust roots |

containers/image reads only `/etc/containers`, so the image puts two symlinks there
(`/etc/containers/policy.json`, `/etc/containers/registries.d/nyra.yaml`) and nothing else. An
untouched symlink keeps pointing at the current `/usr` content after every update; root can replace
it, as root can change anything in `/etc`.

`matchRepository`: cosign signs the repository name without a tag, while clients pull a channel tag
(`:stable`). The policy therefore checks the repository, so a signature for one repository cannot be
reused for another.

**The signer address is committed in `policy.json`, not taken from a CI variable.** It is the trust
anchor of every Nyra machine, so it changes only through a reviewed commit, and anyone can rebuild
the image with the same policy. The address is now committed as
`nyra-image-signer@nyra-signing-3076.iam.gserviceaccount.com`. From this commit on, Nyra machines
accept images from `updates.nyraos.com` signed by this identity. The `sign` job stays skipped until
`GCP_WIF_PROVIDER` and `GCP_SIGNER_SA` are set, and refuses to sign if the committed address differs
from `GCP_SIGNER_SA`. The variables only switch the job on: who can obtain a signature for this
identity is decided by "Who can sign" below, not by the variables.

### Other registries and local images

Only `updates.nyraos.com` requires a signature. Every other source keeps the usual default
(`insecureAcceptAnything`):

- **User containers** (Distrobox, podman, toolbox) pull from Docker Hub, Quay, GHCR and others. They
  are not signed by us, and a signature requirement there would only stop people from using them.
  Pulling a user container is the same act of trust as downloading a program; it does not touch the
  system image.
- **Local transports** (`containers-storage`, `oci`, `oci-archive`, `dir`) are not network sources:
  their content is already on the machine, put there by root or by the user. `bootc install` reads
  the image from local storage this way.

**The trade-off:** the guarantee covers the system image, which is what an attacker
on the network or on our servers would target. It holds as long as the system image is always
referenced exactly as `updates.nyraos.com/...`: lowercase, no port, no other host name. The policy
scope is compared as written, so `UPDATES.NYRAOS.COM/...` or `updates.nyraos.com:443/...` reach the
same server but fall under the default and are accepted unsigned. `nyra-updated` and the
installer must use exactly that name. An image referenced any other way is not checked. Changing the
reference of the system image needs root, and root can also edit the policy.

**What the installer guarantees** (`tools/install/nyra-install.sh`, docs/INSTALL.md). Not
`--enforce-container-sigpolicy`: that flag has no effect with the composefs backend, and a live
system's own policy accepts anything. The guarantee is made by the installer itself:
- the image is pulled by `tools/install/verified-pull.sh` under the policy and trust roots of the
  checkout, never `--insecure-policy`, from `updates.nyraos.com/nyra-base:<version>`;
- the digest the owner took from the release is mandatory and must be the pulled one, and the signed
  labels `org.opencontainers.image.version` and `org.opencontainers.image.revision` must be the
  version and the commit of the checkout (the policy's `matchRepository` binds a signature to the
  repository, not to the tag: a validly signed older image under the tag would pass it alone);
- everything that touches the disk runs from that image by its ID, with `--pull=never` and
  `--network none`, so nothing can be pulled again under another policy; `bootc install` is given
  `--target-imgref updates.nyraos.com/nyra-base:<version>`, and the reference and manifest digest it
  recorded are read back from the disk before the installer says it is done.

## Testing

On every build (pull requests included), `tools/signing/test-policy.sh` runs the image's own skopeo
(the containers/image code bootc uses) with the shipped policy against a local registry reachable
as `updates.nyraos.com`:

- an image with no signature is refused;
- an image signed with someone else's key, attached the way we attach ours, is refused;
- another registry and a local `oci-archive` are accepted.

The `verified-pull` job (`tools/install/test-verified-pull.sh`, no secrets) runs the verified-pull
script itself against the same kind of registry, with test images signed by a key made for the run and
a copy of the checkout whose policy trusts that key: a signed image is accepted; a tag re-pointed to an
older, validly signed image, an image with another revision label and an unsigned image are refused
and leave nothing in the storage; a name that was never pulled does not run
(`podman run --pull=never`). Then `bootc install to-disk --target-imgref` from the image ID, and
`bootc status` in the booted system shows that reference and digest; `bootc switch` to a second signed
version works.

In the `sign` job, the same script also checks that:

- the freshly signed image is accepted;
- its signature attached to another image is refused;
- the image and its signature copied to another repository are refused.

These positive checks first run on the first release build after GCP is configured (below).

The UKI release gate is tested on every build too (`tools/signing/test-uki-gate.sh`), on the image just
built, whose UKI is signed with that run's throwaway key; on the x86_64 image in `image.yml` and on the
AArch64 UKI (PE machine `0xAA64`) in `arm64.yml`, whose pull request runs also cover changes to
`tools/signing/`:

- accepted with that run's certificate and policy key (so the refusals below are not a gate that
  refuses everything);
- **refused exactly as the `sign` job runs it**, with the committed Nyra certificate and policy key:
  an image signed with test keys never gets a release signature (today because nothing is committed;
  once it is, because the signatures do not match);
- refused with a certificate that did not sign it, and with a policy key that is not the UKI's;
- refused even when signed with the trusted key: a signed add-on in place of the UKI, the UKI with
  `systemd.import_credentials=on` in its main command line, a second UKI next to it, an add-on in
  `<uki>.efi.extra.d/`, the UKI without its Nyra SBAT component, without its PCR policy, with a
  policy signature changed by one character, and with the policy moved into the recovery profile (the
  layout check refuses the second and the last; `pcr-policy.py check` alone refuses them too);
- refused even when signed with the trusted key, each for its own reason, for every rule of "Reading
  the UKI as systemd-stub does" and of the exact layout, on variants of the image's UKI: a zeroed
  section header followed by one more `.profile`, a section misaligned in the file (a pefile warning),
  a section named `.linux\0s`, a fourth profile without a command line, a profile with two, an
  `.initrd` of its own in the reset profile, the recovery and reset command lines swapped in the
  section table, a `\x1c` or a space in front of a command line, two command lines at the same
  address, the base command line beyond SizeOfImage, an empty `.profile`, a command line without
  `IMAGE_SCN_MEM_READ`, one with `IMAGE_SCN_MEM_DISCARDABLE`, one with
  `IMAGE_SCN_CNT_UNINITIALIZED_DATA`, a base relocation moved onto the base command line, a second
  signature, and a nested one (made with `osslsigncode -nest`; the trusted signature still verifies),
  also with its tag written in the high tag number form, and two bytes after the signature in its
  certificate entry;
- refused, signed with the trusted key and then changed (so its signature no longer holds, but the
  reading refuses it first): command line data inside the certificate table.

The PCR policy signing is tested on every build too (`tools/signing/test-pcr-policy.sh`), on a UKI
that `ci/ukify.sh` builds from the image just built, with a policy key made by the test:

- signed, joined and checked as in the signing step (the control), and systemd-measure, given the
  main profile's sections, makes the same signature byte for byte;
- `sign` refuses, and prints no signature, for a key that is not the UKI's `.pcrpkey`, a `.pcrsig`
  that asks for a later phase, a measured section changed after ukify wrote the digest, and a UKI
  already signed;
- `check` refuses a later phase signed as well as `enter-initrd`, a later phase alone,
  `enter-initrd` without the reference, the policy twice, PCRs 7 and 11, a SHA-1 bank, another
  reference, data to sign that is not the policy and its reference, another key's fingerprint, and
  a signature by another key.

## The PCR policy key

TPM2 unlock binds to a PCR 11 policy signed with a Nyra key (docs/BOOT.md, "TPM2 unlock"): the main
profile's, for the `enter-initrd` phase only, with the policy reference `initrd`, so the disk unlocks
in the initrd and nowhere later. Its signature is part of the UKI, under the Secure Boot signature, so
it is made in the same signing step.

- **In CI:** an RSA key made for the run in step 3 of `ci/build-image.sh`, deleted after signing, like
  the UKI key. Only its public half leaves the step (into the UKI as `.pcrpkey`, and for the tests).
- **The real key** is kept like the UKI key, never in CI or on a developer machine: a working key in a
  KMS/HSM, certified by the hardware root that also stands behind the UKI key. Signing a policy is a
  plain signature over a SHA-256 digest: `pcr-policy.py sign` runs `openssl dgst -sha256 -sign` over
  the policy digest and its reference, which a KMS or a PKCS#11 provider can do instead. **The signer
  never signs a digest it has not computed.** Whatever holds the real key runs `pcr-policy.py sign`'s
  check first: it computes the main profile's `enter-initrd` policy from the UKI and refuses a UKI
  that asks for anything else (docs/BOOT.md). A signature over PCR 11 is a credential that unlocks
  every boot with that PCR value until the key is rotated, so a wrong one cannot be taken back.
- **Only the public half is committed**, as `files/usr/lib/nyra/secureboot/tpm2-pcr-public-key.pem`
  next to `nyra.crt`; the release gate refuses any other. It is `pcr-policy-1` in Cloud KMS (key ring
  `nyra`, RSA 2048, HSM, PKCS#1 v1.5 SHA-256), the **current** key; its file's SHA-256 is
  `e8baddbcbd70accf5525644bc766a5e79f9fcffdac69890348307f363793d0f1`.
- **The next key's public half is committed too**, as
  `files/usr/lib/nyra/secureboot/tpm2-pcr-public-key-next.pem`, and goes into the image
  (`/usr/lib/nyra/secureboot`, by `ci/build-image.sh`, CI images included). Images also carry the
  committed current key at `/usr/lib/nyra/secureboot/tpm2-pcr-public-key.pem`, which nothing reads at
  runtime (`tpm-enroll` takes the current key from the UKI); in CI images it differs from the UKI's
  `.pcrpkey`, which is the key made for the run. The release gate refuses an image whose next key is not that file, or is the
  current key (compared as DER, so not even in another encoding). It is `pcr-policy-2` in the same key
  ring and kind, the **next** key; its file's SHA-256 is
  `677ff7820feb0c1eb0c606fced968cfe7f5cdf905bdc0321cd4ee1689e4299ae`. CI's signing identity may sign
  only with `pcr-policy-1` (IAM on that key); `pcr-policy-2` has no signer until a rotation. Builds
  and tests do not need either private half: the build job and the encryption tests use their own
  per-run keys for the current key, and the tests that need a private next key (rotation, updates)
  replace the image's next key with one of their own.
- **A key is known by the SHA-256 of its PEM file**, on every disk (the record of its enrollments). So
  the release gate also requires the UKI's `.pcrpkey` to be the committed key's file byte for byte:
  the same key in another encoding would leave the disk unable to tell that it is the key it was
  enrolled for, and the old key would never be retired.
- **Retired keys are listed** in `files/usr/lib/nyra/secureboot/tpm2-pcr-retired-keys` (one SHA-256
  per line), which every image carries: a disk is never enrolled for them again, and once a version
  is confirmed good, `nyra-tpm-retire` removes their enrollments and marks them retired on the disk.
  A key goes there in the release after its rotation is confirmed, or at once when it is no longer
  trusted (a next key that leaked before it signed anything, for example: an old image that carries it
  as next would otherwise enroll it after a downgrade). The release gate refuses an image whose list
  is not that file, has a line that is neither a comment nor a key's SHA-256, or lists the current or
  the next key.
- **Rotation** is how an old UKI stops unlocking the disk (docs/BOOT.md, "Rotating the policy key"):
  **once a year, planned, and at once when a boot-chain vulnerability means old versions must lose
  unlock**. A machine's TPM enrollment names the key. Since the policy unlocks only in the initrd, the
  running system cannot open the TPM enrollment to add a key. So **the next key is enrolled in
  advance**, next to the current one, so that a rotation never needs the recovery key:
  1. **At the first boot** (and at every re-enrollment), the disk gets two TPM2 enrollments: the
     current key and the next one (two key pairs exist at any time; the next one has signed nothing
     yet).
  2. **A rotation** is a release signed with the next key only, whose image carries a new next key,
     and whose `.pcrpkey` is byte for byte the previous image's next-key file (a key is known by the
     SHA-256 of its PEM file). It unlocks through the enrollment that was waiting for it. While that
     release's initrd still runs (the `enter-initrd` phase, the disk open), it enrolls the new next key
     (on a disk with a PIN, with the PIN typed at that boot: docs/BOOT.md, "A PIN at boot").
  3. **Once that release is confirmed good** (its boot completes, as boot counting confirms it), the
     enrollment of the old key is removed. Until then a fallback to the previous version still unlocks
     by itself; after it, versions signed with the old key still boot, but ask for the disk password or
     the recovery key, and are never enrolled again. A fallback to the previous release that is
     confirmed good removes nothing newer than its own key.

  A machine that never booted a release of one rotation before the next rotation came has neither
  enrollment and asks for the recovery key once; with a rotation a year, that is a machine off for
  about a year.

## Trust roots

`fulcio-ca.pem` and `rekor.pub` come from `trusted_root.json` in
[sigstore/root-signing](https://github.com/sigstore/root-signing), at a pinned commit, checked against
its SHA-256 (`tools/signing/trust-roots.sh`). CI regenerates them on every build and fails if the
committed files differ.

They are fixed in the image, not fetched over TUF like cosign does. When Sigstore rotates the
Fulcio CA or the Rekor v1 key, or retires Rekor v1, a new image with the new roots (or both old
and new) must ship **before** the first image signed under the new ones. Otherwise machines that
missed the transition can no longer verify updates. Watch the Sigstore announcements; update the
pinned commit in `trust-roots.sh` and run it.

## Setting up the signer (once)

**Rule: signing stays off while one account can put a change on `main` alone.** Anyone who can get
a change onto `main`, or start the workflow manually on `main`, gets a signed image (see "Who can
sign" below). Today `main` requires a pull request and passing checks, and nobody, administrators
included, can push to it directly. It requires **no approval**, though: the author of a pull request,
with write access, can merge it alone once the checks pass. Set the two repository variables (step 2)
only when one of these holds:

- merging into `main` requires an approval from an account other than the author (a required
  review that also covers the most recent push, or a code owner review from another account);
- or the maintainers accept, in writing and recorded in this document, that any account with write
  access can sign.

**Acceptance, 2026-10-18.** The owner (the repository's maintainer, Wagg Software) accepted that any
account with write access to `main` can obtain signatures. Today that is the owner's account, which
the project's automated contributors (AI agents and GitHub Copilot) also use. The reason: automatic,
signed updates, without a manual step per release. The mitigations: the Google identity accepts only
this repository's image workflow on `main` from GitHub-hosted runners; the keys are not exportable
(Cloud KMS, HSM); the release gate's checks, staged rollouts and signed retractions; and the Cloud
KMS audit logs of every signature, once enabled (see "Who can sign").

The Google Cloud setup below can be prepared at any time. If the condition stops holding, remove the
variables first.

Google Cloud, with a maintainer's account (2-step verification on). Everything below is free: IAM,
Workload Identity Federation and the token service need no paid product.

Two identities, two service accounts, two pools: `nyra-image-signer` signs images keylessly and
should hold no Cloud KMS role; `nyra-release-signer` (below, "Release mode") holds the KMS roles and
signs nothing keyless. The final state is that the image signer is reachable only from the pool
`github-sign`, whose provider also requires the GitHub environment `sign`, which only the `sign`
job declares (`shellcheck.yml` checks it). Getting there is a split in two phases: the commands
below are the first (the new pool and binding; the release signer's own roles and binding); the
second removes the image signer's binding on the pool `github` and its KMS roles. Create the
environment `sign` first (Settings › Environments): deployment branches `main` only, no required
reviewers, **no secrets and no variables** (an environment variable `GCP_*` would override the
repository one). Signing stays automatic, as accepted below.

```sh
PROJECT_ID=nyra-signing          # pick a globally unique project ID
gcloud projects create "$PROJECT_ID" --name="Nyra signing"
gcloud config set project "$PROJECT_ID"
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
gcloud services enable iam.googleapis.com iamcredentials.googleapis.com sts.googleapis.com

# The two signers: service accounts with no keys, ever.
gcloud iam service-accounts create nyra-image-signer --display-name="Nyra image signer (keyless)"
gcloud iam service-accounts create nyra-release-signer --display-name="Nyra release signer (KMS)"
SIGNER="nyra-image-signer@$PROJECT_ID.iam.gserviceaccount.com"
RELEASE_SIGNER="nyra-release-signer@$PROJECT_ID.iam.gserviceaccount.com"

# The release signer holds the KMS roles: sign with `uki` and `pcr-policy-1` only, and view the ring
# (see "Release mode").
for k in uki pcr-policy-1; do
  gcloud kms keys add-iam-policy-binding "$k" --location=europe-west3 --keyring=nyra \
    --role=roles/cloudkms.signerVerifier --member="serviceAccount:$RELEASE_SIGNER"
done
for role in roles/cloudkms.viewer roles/cloudkms.publicKeyViewer; do
  gcloud kms keyrings add-iam-policy-binding nyra --location=europe-west3 \
    --role="$role" --member="serviceAccount:$RELEASE_SIGNER"
done

# GitHub OIDC, accepted only for: this repository (by ID, so a renamed or re-created repository does
# not match), main, the image workflow, a push or manual run, a GitHub-hosted runner.
gcloud iam workload-identity-pools create github --location=global --display-name="GitHub Actions"
gcloud iam workload-identity-pools providers create-oidc nyra-base \
  --location=global --workload-identity-pool=github --display-name="nyra-base image workflow" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository_id=assertion.repository_id" \
  --attribute-condition="assertion.repository_id == '1412332787' && assertion.repository_owner_id == '339787017' && assertion.ref == 'refs/heads/main' && assertion.workflow_ref == 'NyraOS/nyra-base/.github/workflows/image.yml@refs/heads/main' && assertion.event_name in ['push', 'workflow_dispatch'] && assertion.runner_environment == 'github-hosted'"

# Only identities from that provider may act as the release signer.
gcloud iam service-accounts add-iam-policy-binding "$RELEASE_SIGNER" --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/github/attribute.repository_id/1412332787"

# The same, plus the job's environment `sign`, in a separate pool for the image signer.
gcloud iam workload-identity-pools create github-sign --location=global --display-name="GitHub Actions (image signature)"
gcloud iam workload-identity-pools providers create-oidc nyra-base-sign \
  --location=global --workload-identity-pool=github-sign --display-name="nyra-base image signature" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.signer=assertion.environment" \
  --attribute-condition="assertion.repository_id == '1412332787' && assertion.repository_owner_id == '339787017' && assertion.ref == 'refs/heads/main' && assertion.workflow_ref == 'NyraOS/nyra-base/.github/workflows/image.yml@refs/heads/main' && assertion.event_name in ['push', 'workflow_dispatch'] && assertion.runner_environment == 'github-hosted' && assertion.environment == 'sign'"

# Only identities from that provider, in the environment `sign`, may act as the image signer.
gcloud iam service-accounts add-iam-policy-binding "$SIGNER" --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/github-sign/attribute.signer/sign"

# Check: no user-managed keys.
gcloud iam service-accounts keys list --iam-account="$SIGNER" --managed-by=user
# If the project belongs to a Google Cloud organisation, also forbid keys outright:
#   gcloud resource-manager org-policies enable-enforce iam.disableServiceAccountKeyCreation --project="$PROJECT_ID"

echo "GCP_WIF_PROVIDER=projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/github-sign/providers/nyra-base-sign"
echo "GCP_SIGNER_SA=$SIGNER"
```

Then, in this order:

0. Done: the Nyra UKI certificate and the PCR policy keys are committed (see "Making the UKI
   certificate" and "The PCR policy key"), and releases are signed with them.
1. Commit the address as `subjectEmail` in `files/usr/lib/nyra/containers/policy.json` (pull
   request, normal review). The `sign` job stays skipped: the variables are not set yet.
2. Only once the rule above holds, set the two **repository variables** (Settings › Secrets and
   variables › Actions › Variables; they are not secrets):
   ```sh
   gh variable set GCP_WIF_PROVIDER -R NyraOS/nyra-base --body "projects/<number>/locations/global/workloadIdentityPools/github-sign/providers/nyra-base-sign"
   gh variable set GCP_SIGNER_SA    -R NyraOS/nyra-base --body "nyra-image-signer@<project>.iam.gserviceaccount.com"
   ```
3. Run the workflow on `main` (`gh workflow run image.yml -R NyraOS/nyra-base --ref main`):
   it builds, signs and verifies. The job summary shows the signed digest.

**Who can sign:**
- **image signatures: only a job in the environment `sign` of `image.yml` on `main`**, that is, the
  `sign` job. The KMS keys: **any job of `image.yml` on `main`**, the `sign` job included, until the
  `nyra-base` provider also refuses tokens that carry an environment; the jobs meant to use them are
  `release-sign` and `release-sign-arm64`, the only ones besides `sign` with `id-token: write`
  (`ci/check-credential-jobs.py`);
- until the second phase of the split (removing `nyra-image-signer`'s binding on the pool `github`
  and its KMS roles), the image signer is still reachable through the pool `github`, so also from
  `release-sign`, and still holds the KMS roles;
- **anyone who can get a change onto `main` or start the workflow manually on `main`**: the workflow
  runs whatever is on `main`, and the attribute condition cannot tell a reviewed merge from an
  unreviewed one. The branch protection only stops direct pushes. Without a required approval from
  another account, anyone with write access, automated contributors too, can merge their own pull
  request, a change to the workflow itself included, and get a signature (rule above);
- any Google principal with `iam.serviceAccounts.getOpenIdToken` on either service account: `Owner`,
  `Service Account Token Creator`, `Service Account OpenID Connect Identity Token Creator`,
  `Workload Identity User`, or a custom role with that permission. Keep the Google Cloud project's
  members to one maintainer account, with no other grants on either service account.

The same goes for the Cloud KMS keys (`uki`: the UKI's Secure Boot signature; `pcr-policy-1`: the
TPM2 policy): whoever can get a change onto `main`, or can act as the release signer, can obtain those
signatures.

Every keyless image signature is public in Rekor under the signer's address, so an unexpected one is
visible. KMS signatures are **not** recorded in Rekor. Their record is Cloud Audit Logs: Data Access
logging for `cloudkms.googleapis.com` must be enabled (a maintainer action). A release run has one
`release-sign` job, and a second one, `release-sign-arm64`, when the arm64 release is on
(docs/ARM64.md, "Releases"); each makes two `AsymmetricSign` calls (`pcr-policy-1`, then `uki`). An
`AsymmetricSign` that matches no `release-sign` or `release-sign-arm64` job is an incident.

**If the repository moves** (another organisation, or a re-created repository), update the
attribute condition and the binding with the new repository and owner IDs. Machines do not change:
they trust the service account's address, not the repository.

## Release mode: the Nyra keys sign the UKI before the tests

Two **repository variables** are needed:
```sh
gh variable set KMS_WIF_PROVIDER -R NyraOS/nyra-base --body "projects/<number>/locations/global/workloadIdentityPools/github/providers/nyra-base"
gh variable set KMS_SIGNER_SA    -R NyraOS/nyra-base --body "nyra-release-signer@<project>.iam.gserviceaccount.com"
```
Only the jobs `release-sign`, `release-sign-arm64` and `sign` of `image.yml` may have `id-token: write`, only `sign` may be in the environment `sign`, and a job that calls a reusable workflow must have exactly `permissions: {contents: read}` and pass no secrets (`ci/check-credential-jobs.py`, run on every pull request), because the identity providers check `workflow_ref`, which for a called workflow names its caller.

A run is a release (`build`'s `release` output) when it is this workflow (`image`, not Titanic's call
of it) on `main` by push or manual run. Then, in one run:

- `build` makes the UKI with the committed PCR policy key and stops there: unjoined, unsigned
  (`NYRA_RELEASE=1`, `ci/build-image.sh`). It uploads that UKI and the sealed image it was made from
  (`nyra-base-unsigned-uki`, `nyra-base-sealed-oci-archive`), not the image archive, and takes the
  committed `nyra.crt` as the certificate the tests enrol.
- `release-sign` (with `release-sign-arm64`, the only jobs with `id-token: write` besides `sign`)
  checks both artifacts against `build`'s hashes, authenticates through Workload Identity
  Federation, has the key `pcr-policy-1` sign the main profile's PCR policy (`pcr-policy.py
  sign-kms` first checks the UKI as the sealed UKI, then verifies the signature with the committed public key), joins it into the UKI with the sealed
  image's own `ukify`, and has the key `uki` sign the result for Secure Boot (`sign-uki.sh`, with the
  committed certificate). If `KMS_WIF_PROVIDER` or `KMS_SIGNER_SA` is unset the job fails (red, not
  skipped), so a release can never go on with an unsigned image.
- `release-image` has no token: it checks the signed UKI and the sealed image against the hashes
  their jobs reported, builds the final image (`ci/final-image.sh`, as `build-image.sh` does), requires
  that its layers are those of the image `build` checked (setuid files, lint, SBOM) except the one
  that holds the UKI, runs the UKI release gate, and uploads `nyra-base-release-oci-archive`.
- The tests boot that image, so what is tested, signed with `nyra.crt` and the real policy, is what
  `sign` signs. They are skipped, and the run fails, if `release-image` did not succeed.

**Why two jobs.** Building an image runs code from it (the last stage's `RUN`) and reads the workspace,
where the authentication step writes the credentials file; with it, anything in the job signs until the
job ends. So `release-sign` runs no image build. The one piece of image code near the credentials is
the join: a container of the sealed image with no network and no environment, and only three fresh
directories mounted, never the workspace. A container escape would reach the credentials; that risk is
accepted. `.containerignore` still keeps the credentials file out of any build context.
For the arm64 UKI (`release-sign-arm64`) that container runs the sealed arm64 image's `ukify` on the
x86_64 runner under qemu-user (`tools/signing/join-pcrsig.sh`): Ubuntu's `qemu-user-static`,
installed from Ubuntu's archive and registered for binfmt_misc with the F flag in the apt step, before
the auth step; never `docker/setup-qemu-action`, `tonistiigi/binfmt` or a container that registers an
emulator, and the script refuses an emulator that is not that package's. qemu-user is not a boundary:
it passes the guest's system calls straight to the host kernel, inside the container. The container
(by image ID, `--pull=never --platform linux/arm64 --network none`, no environment, the three fresh
directories) stays the only boundary, the same accepted risk as for x86_64.

**Every KMS signature counts as a release.** A run that signs gives a UKI that boots and unlocks
enrolled disks, also when a test then fails. The signed UKI and the release image are kept one day
(`retention-days: 1`), but a copy taken in that time stays valid: treat every `release-sign` and
`release-sign-arm64` run as a release when revoking (raise the Nyra generation in SBAT, "SBAT" in
docs/BOOT.md; both architectures share it, so raising it revokes the older UKIs of both), and match the
audit log's `AsymmetricSign` entries against those runs, not against published releases.

**arm64.** With the repository variable `ARM64_RELEASE` set to `on`, the same run also makes an arm64
release in jobs of `image.yml` (docs/ARM64.md, "Releases"): `build-arm64` (release mode, on an arm64
runner), `release-sign-arm64` (the same keys, service account and steps as `release-sign`, on x86_64,
the join under qemu-user, above), `release-image-arm64` (the same gate, plus the architecture and
repository check of `ci/check-image-repository.sh`) and `boot-arm64`. One certificate and one MOK for
both architectures: Authenticode and the PCR policy signature cover bytes, not a CPU, and the PCR
policy signs measurements an x86_64 machine never makes. The jobs are in `image.yml`, never in a
workflow it calls: the identity providers check `workflow_ref`, which names the caller, so any called
workflow could otherwise sign. `arm64.yml` builds without `NYRA_RELEASE` and gets no token. The arm64
image is not signed for the registry nor published yet; when it is, it goes to its own repository,
`nyra-base-arm64`, whose signatures the policy's `matchRepository` does not accept for `nyra-base`.

A third party can check a release: rebuild, and the release's UKI equals the rebuilt unsigned UKI except
for the `.pcrsig` signature and the Secure Boot signature.

The KMS roles are on the release signer (`KMS_SIGNER_SA`); the image signer has none. The release
signer needs `roles/cloudkms.signerVerifier` on the keys `uki` and `pcr-policy-1` only,
plus `roles/cloudkms.viewer` and `roles/cloudkms.publicKeyViewer` on the key ring (libkmsp11 lists
the ring and reads every key's public half at start; public halves are public anyway). The ring
also holds `channel-sheet` (signed by its own service account): the release signer may
view it through those ring-level roles, but has no signing role on it, nor on `pcr-policy-2`. The
verification against the committed public keys proves the right key version signed. The release
mode cannot run before it is on `main` (the federation accepts nothing else). There is no switch:
the rollback for a broken release path is reverting the change on `main`.

## Making the UKI certificate

The Secure Boot key lives in Cloud KMS (HSM, not exportable). Shim and the installer need a
certificate for it, made once: in Cloud Shell, as the account that may use the key, run

    sudo apt-get install -y libengine-pkcs11-openssl
    tools/signing/kms-uki-cert.sh > nyra.crt

The script downloads Google's PKCS#11 library for Cloud KMS (a pinned release, checked against its
SHA-256; the pin lives in `tools/signing/kms-pkcs11.sh`), has KMS sign a self-signed certificate (`CN=Nyra OS Secure Boot 2026, O=Wagg Software`,
15 years, `CA:FALSE`, digital signature, code signing), checks that its public key is the KMS key's
and that it verifies against itself, and prints only the PEM. No secret is written anywhere. Run it
from a fresh clone of `main`, not from a branch. The PEM is committed as
`files/usr/lib/nyra/secureboot/nyra.crt` in a separate pull request (docs/BOOT.md, "What remains for
the real Nyra key"). That pull request states the SHA-256 fingerprint the script printed on stderr.
Its reviewer checks the certificate's public key
independently against `gcloud kms keys versions get-public-key 1 --key=uki ...`, not against the PEM
alone.

The committed certificate was made this way on 2026-10-18; its SHA-256 fingerprint is
`6F:3E:51:F4:0B:61:A4:71:CE:49:C0:95:E1:57:27:BA:F1:75:10:80:4B:31:C3:50:16:56:97:97:68:75:44:F9`
(`openssl x509 -noout -fingerprint -sha256 -in files/usr/lib/nyra/secureboot/nyra.crt`).

## Publishing

Each signed release can be published to `updates.nyraos.com` (repository `nyra-base`) by the job
`publish` of `image.yml`. It is **off** unless the repository variable `PUBLISH_ENABLED` is `on`.
It runs for a release (`build`'s `release` output) after `sign` succeeded, one at a time
(`concurrency: publish-nyra-base`), and then `verify-published` reads the result back.

### What `publish` does

1. Fetches `NyraOS/nyra-updates` at the commit pinned in the job (`UPDATES_PIN`) into the runner's
   temp directory, not the workspace, and refuses it unless it is an ancestor of that repository's
   `main` (GitHub serves a commit by SHA from every fork of a repository network, so the SHA alone
   proves nothing). The pin moves only by a reviewed pull request here, whose reviewer reads the
   `nyra-updates` diff from the old pin to the new one; Dependabot does not move it.
2. Downloads the image and the signature artifacts, each into its own empty directory, and checks
   the image archive with `ci/check-artifact.sh` against `release-image`'s hash. The archive is
   unpacked with `tar` (podman's `oci-archive` is an OCI layout), as no one, never through the
   image or podman: **no image code runs in `publish`**.
3. Checks, with every value from a job output matched by a strict regex first: the image layout's
   one manifest is `sign`'s `image_digest`; the signature layout's one manifest is `sign`'s
   `signature_digest`, tagged `sha256-<hex>.sig` of that image digest; the image config's
   `org.opencontainers.image.version` is `build`'s version and `org.opencontainers.image.revision`
   is the commit. The labels tie the version tag to signed content, so a re-pointed tag shows (bootc
   reports the label). The `image-digest` file in the artifact is never a source of a tag or digest.
4. Runs `registry/scripts/publish-image.sh --remote` of `nyra-updates` twice, in one step that is the
   only one with the secrets: the signature (tag `sha256-<hex>.sig`) first, then the image (tag = the
   version). The script refuses a version whose signature is not published.
5. Writes the line `"<version>": "sha256:..."` into the step summary: a pull request to
   `channels/nyra-base/releases.json` in `nyra-updates` adds it by hand.

`verify-published` (no secrets, no environment, `contents: read`) runs
`tools/install/verified-pull.sh <version> <image_digest>`, the pull the installer makes too: `skopeo`
with the committed `policy.json` (its trust-root paths pointed at the checkout) and the committed
`registries.d`, never `--insecure-policy`, from `docker://updates.nyraos.com/nyra-base:<version>`
into a container storage. It requires acceptance, the digest of `sign`, and the signed labels
`org.opencontainers.image.version` (the version) and `org.opencontainers.image.revision` (the commit
of the checkout). It then pulls `docker://updates.nyraos.com/nyra-base@<image_digest>` into the same
storage under the same policy, the reference machines update by (`bootc switch`), and fails if that is
refused. It retries for about 2 minutes, as the tag takes a moment to show, but only failures that
may pass (exit code 1): a pulled image with the wrong digest or labels (exit code 2) fails at once. **A red
`verify-published` is an incident to look into, not a reason to publish again.**

### Settings (owner)

- The secrets `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` and `CLOUDFLARE_KV_TOKEN` exist **only** in
  the environment `publish`, not at repository level. `publish` fails, not skips, when one is
  missing (the script's `:?` checks).
- The environment `publish`: deployment branches = the selected branch `main` only (no tag rule),
  no required reviewer, administrators may not bypass. No reviewer is needed because a published
  version reaches no machine by itself: machines update only through signed channel sheets, or by
  hand to a version tag after checking the digest. A reviewer would also not stop an automated
  contributor using the owner's account.
- `ci/check-publish-job.py` (the `shellcheck` workflow) keeps the invariants: `publish` has
  `permissions: {contents: read}` and nothing else, no job with `id-token: write` (`sign`,
  `release-sign`, `release-sign-arm64`) uses the environment `publish`, no other job names `R2_*` or `CLOUDFLARE_*`
  secrets, and `verify-published` has no environment.

### Re-runs, concurrency and what is not immutable

- A pending `publish` can be cancelled by the `publish` of a newer release (one group, not
  cancelled while running). Recovery: "Re-run failed jobs" within 1 day, otherwise a new release.
- A full re-run can rebuild the identical image digest. Its new signature has another `.sig` digest
  and is refused. That is expected: the published signature stays valid.
- The immutability of a version tag is a rule of the publishing script, **not of the storage**. Every
  holder of a KV-write token can re-point any tag to any manifest in R2: this repository's `publish`,
  `nyra-updates`' `channel-publish` (and its deploy token, if that has KV), and the Cloudflare
  dashboard. Effect: a machine that follows a tag by hand can be moved to another *signed* image (a
  downgrade). `nyra-updated` is not affected: it pins digests from the signed channel sheet.

### The tokens

Set up `R2_ACCESS_KEY_ID` and `R2_SECRET_ACCESS_KEY` to write the `nyra-images` bucket only (the
job does not check it).
`CLOUDFLARE_KV_TOKEN` writes Workers KV, and that permission is **account-wide** unless the dashboard
shows a namespace selector for it. A holder of a KV token can re-point tags to signed manifests, and
overwrite or replay channel sheets (refused by their signature and sequence number; a sheet is fresh
for 7 days). It cannot make a machine accept an unsigned or foreign image: that needs a signature
from the signer in `policy.json`.

## Not covered here

- The signed channel sheet (channel, version order, freshness): docs/UPDATES.md.
- Attestations of the SBOM (mkosi package manifest, bootc `Cargo.lock`): later. The vulnerability
  gate on the SBOM is in docs/SBOM.md.
- The update server side of publishing (`nyra-updates`: the registry, the channel sheets).
