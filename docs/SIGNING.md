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
   replace each other's artifacts, so every job that uses the image artifact (`install-boot`,
   `boot-repeat`, `sign`, the Titanic jobs) first checks it against the sha256 that `build` reported as
   a job output (`ci/check-artifact.sh`); `build` also reports the SBOM's.
2. **The `sign` job** (`.github/workflows/image.yml`) runs only for release builds, only on
   GitHub-hosted runners, and is the only job allowed to request an OIDC token (`id-token: write`):
   - GitHub issues an OIDC token for the workflow run;
   - Google Workload Identity Federation accepts it only for this repository, `refs/heads/main`,
     the `image.yml` workflow, a `push` or `workflow_dispatch` event and a GitHub-hosted runner,
     and returns an ID token for the
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
4. **Output** (artifact `nyra-base-signature`, for publishing later): an OCI layout with
   the signature tagged `sha256-<digest>.sig`, exactly as it must appear on the registry, plus
   `image-digest`. The image itself is the `nyra-base-oci-archive` artifact (same digest).

The signature uses cosign's older format: a `sha256-<digest>.sig` tag whose layer carries the
certificate and the Rekor v1 signed entry timestamp (SET). It is the only format that
containers/image (bootc, podman, skopeo) verifies today; cosign 3 defaults to the new bundle
format, hence `--new-bundle-format=false --use-signing-config=false`.

## The UKI release gate

A release signature says "Nyra machines may install this image". An image whose UKI is not signed
with the Nyra Secure Boot key would install and then fail to boot under Secure Boot, so it must never
get one. Before anything else, the `sign` job runs `tools/signing/uki-gate.sh` on the image's `/boot`
with the Nyra UKI certificate committed in this repository,
`files/usr/lib/nyra/secureboot/nyra.crt` (PEM; once committed, it also ships in the image, for the
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

**Neither the certificate nor the policy key is committed yet** (the Nyra keys do not exist yet), so
the gate refuses every image: fail closed, like the placeholder signer address in the policy.

"Exactly one UKI": the image ships one UKI file. Its three profiles (main, recovery, reset settings,
docs/BOOT.md) are sections of that one signed file, not separate UKIs. The fallback UKI
(`EFI/Linux/nyra-fallback-<digest>+0.efi`) exists only on a machine's ESP: `esp-sync` copies the UKI
bootc installed there, so it is the same signed file and nothing new is signed for it.

The same checks guard the signing step itself (`ci/build-image.sh`, step 3): it signs exactly one file,
and only if `uki-check.py` accepts it and, once its PCR policy is signed, `pcr-policy.py check` too, so the key that signs UKIs never signs an add-on (which would
apply to every Nyra UKI) or a UKI with another command line. A change to the sealed command line
(`kargs.d`, the profiles in `ci/ukify.sh`) therefore needs a matching change to `ci/uki-cmdline.txt`
in the same review. The composefs digest is not compared with the image here: bootc refuses a UKI whose
digest does not match at install time, and `sign` runs only after `install-boot` installed and booted
this image.

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
the image with the same policy. Until it is set, the placeholder `signer-not-configured@nyra.invalid`
refuses every image from our registry (fail closed). The `sign` job refuses to sign if the
committed address differs from `GCP_SIGNER_SA`.

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
installer (`bootc install --target-imgref updates.nyraos.com/... --enforce-container-sigpolicy`)
must use exactly that name. An image referenced any other way is not checked. Changing the reference of
the system image needs root, and root can also edit the policy.

## Testing

On every build (pull requests included), `tools/signing/test-policy.sh` runs the image's own skopeo
(the containers/image code bootc uses) with the shipped policy against a local registry reachable
as `updates.nyraos.com`:

- an image with no signature is refused;
- an image signed with someone else's key, attached the way we attach ours, is refused;
- another registry and a local `oci-archive` are accepted.

In the `sign` job, the same script also checks that:

- the freshly signed image is accepted;
- its signature attached to another image is refused;
- the image and its signature copied to another repository are refused.

These positive checks first run on the first release build after GCP is configured (below).

The UKI release gate is tested on every build too (`tools/signing/test-uki-gate.sh`), on the image just
built, whose UKI is signed with that run's throwaway key:

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
  next to `nyra.crt`; the release gate refuses any other. Nothing is created yet.
- **The next key's public half is committed too**, as
  `files/usr/lib/nyra/secureboot/tpm2-pcr-public-key-next.pem`, and goes into the image
  (`/usr/lib/nyra/secureboot`, by `ci/build-image.sh`; in CI, a next key made for the run, whose private
  half is deleted at once). The release gate refuses an image whose next key is not that file, or is the
  current key. Nothing is created yet.
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
     release's initrd still runs (the `enter-initrd` phase, the disk open), it enrolls the new next key.
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

The Google Cloud setup below can be prepared at any time. If the condition stops holding, remove the
variables first.

Google Cloud, with a maintainer's account (2-step verification on). Everything below is free: IAM,
Workload Identity Federation and the token service need no paid product.

```sh
PROJECT_ID=nyra-signing          # pick a globally unique project ID
gcloud projects create "$PROJECT_ID" --name="Nyra signing"
gcloud config set project "$PROJECT_ID"
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
gcloud services enable iam.googleapis.com iamcredentials.googleapis.com sts.googleapis.com

# The signer: a service account with no keys, ever.
gcloud iam service-accounts create nyra-image-signer --display-name="Nyra image signer (keyless)"
SIGNER="nyra-image-signer@$PROJECT_ID.iam.gserviceaccount.com"

# GitHub OIDC, accepted only for: this repository (by ID, so a renamed or re-created repository does
# not match), main, the image workflow, a push or manual run, a GitHub-hosted runner.
gcloud iam workload-identity-pools create github --location=global --display-name="GitHub Actions"
gcloud iam workload-identity-pools providers create-oidc nyra-base \
  --location=global --workload-identity-pool=github --display-name="nyra-base image workflow" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository_id=assertion.repository_id" \
  --attribute-condition="assertion.repository_id == '1412332787' && assertion.repository_owner_id == '339787017' && assertion.ref == 'refs/heads/main' && assertion.workflow_ref == 'NyraOS/nyra-base/.github/workflows/image.yml@refs/heads/main' && assertion.event_name in ['push', 'workflow_dispatch'] && assertion.runner_environment == 'github-hosted'"

# Only identities from that provider may act as the signer.
gcloud iam service-accounts add-iam-policy-binding "$SIGNER" --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/github/attribute.repository_id/1412332787"

# Check: no user-managed keys.
gcloud iam service-accounts keys list --iam-account="$SIGNER" --managed-by=user
# If the project belongs to a Google Cloud organisation, also forbid keys outright:
#   gcloud resource-manager org-policies enable-enforce iam.disableServiceAccountKeyCreation --project="$PROJECT_ID"

echo "GCP_WIF_PROVIDER=projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/github/providers/nyra-base"
echo "GCP_SIGNER_SA=$SIGNER"
```

Then, in this order:

0. Commit the Nyra UKI certificate as `files/usr/lib/nyra/secureboot/nyra.crt`, together with the
   signing of the UKI with the Nyra key (docs/BOOT.md, "What remains for the real Nyra key"). Until
   then the `sign` job refuses every image (the UKI release gate above).
1. Commit the address as `subjectEmail` in `files/usr/lib/nyra/containers/policy.json` (pull
   request, normal review). The `sign` job stays skipped: the variables are not set yet.
2. Only once the rule above holds, set the two **repository variables** (Settings › Secrets and
   variables › Actions › Variables; they are not secrets):
   ```sh
   gh variable set GCP_WIF_PROVIDER -R NyraOS/nyra-base --body "projects/<number>/locations/global/workloadIdentityPools/github/providers/nyra-base"
   gh variable set GCP_SIGNER_SA    -R NyraOS/nyra-base --body "nyra-image-signer@<project>.iam.gserviceaccount.com"
   ```
3. Run the workflow on `main` (`gh workflow run image.yml -R NyraOS/nyra-base --ref main`):
   it builds, signs and verifies. The job summary shows the signed digest.

**Who can sign:**
- **anyone who can get a change onto `main` or start the workflow manually on `main`**: the workflow
  runs whatever is on `main`, and the attribute condition cannot tell a reviewed merge from an
  unreviewed one. The branch protection only stops direct pushes. Without a required approval from
  another account, anyone with write access, automated contributors too, can merge their own pull
  request, a change to the workflow itself included, and get a signature (rule above);
- any Google principal with `iam.serviceAccounts.getOpenIdToken` on the service account: `Owner`,
  `Service Account Token Creator`, `Service Account OpenID Connect Identity Token Creator`,
  `Workload Identity User`, or a custom role with that permission. Keep the Google Cloud project's
  members to one maintainer account, with no other grants on the service account.

Every signature is public in Rekor under the signer's address, so an unexpected one is visible.

**If the repository moves** (another organisation, or a re-created repository), update the
attribute condition and the binding with the new repository and owner IDs. Machines do not change:
they trust the service account's address, not the repository.

## Not covered here

- The signed channel sheet (channel, version order, freshness): docs/UPDATES.md.
- Attestations of the SBOM (mkosi package manifest, bootc `Cargo.lock`): later. The vulnerability
  gate on the SBOM is in docs/SBOM.md.
- Publishing to `updates.nyraos.com`; the update server must also serve the `nyra-base`
  repository and the `.sig` tags: later.
