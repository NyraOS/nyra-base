# Image signing

Every release image of nyra-base is signed in CI, keylessly, and Nyra machines refuse images
from our registry that do not carry that signature.

## How an image is signed

1. **Release build without cached content.** A push to `main` (or a manual run on `main`) builds the image
   from scratch: bootc compiled from its pinned commit (its Cargo.lock moved to zlink 0.7.1 for a
   reproducible build and pinned by hash, `ci/build-bootc.sh`), every Debian package downloaded from the
   pinned snapshot. The caches (compiled bootc, downloaded packages) are used only by pull
   requests, whose images are never signed. A cached file is not re-verified, so it must never
   reach a signed image. A release build does restore the bootc cache, but only to compare it with
   its own fresh compile (a difference fails the build); the image is built from the fresh one.
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
installer). It refuses unless:

- `/boot` holds exactly one file, `EFI/Linux/<kernel version>.efi`, and nothing else: no second UKI,
  no add-on (`<uki>.efi.extra.d/`), since `bootc install` installs what it finds there;
- that file is the sealed UKI (`tools/signing/uki-check.py`): exactly one `.linux` section (a kernel,
  so not an add-on or another PE file), and `.cmdline` sections that are exactly the lines of
  `ci/uki-cmdline.txt`, in order, one per profile, with one composefs digest in all of them;
- it is signed with that certificate (`sbverify --cert`).

**No certificate is committed yet** (the Nyra key does not exist yet), so the gate refuses every image:
fail closed, like the placeholder signer address in the policy.

"Exactly one UKI": the image ships one UKI file. Its three profiles (main, recovery, reset settings,
docs/BOOT.md) are sections of that one signed file, not separate UKIs. The fallback UKI
(`EFI/Linux/nyra-fallback-<digest>+0.efi`) exists only on a machine's ESP: `esp-sync` copies the UKI
bootc installed there, so it is the same signed file and nothing new is signed for it.

The same check guards the signing step itself (`ci/build-image.sh`, step 3): it signs exactly one file,
and only if `uki-check.py` accepts it, so the key that signs UKIs never signs an add-on (which would
apply to every Nyra UKI) or a UKI with another command line. A change to the sealed command line
(`kargs.d`, the profiles in `ci/ukify.sh`) therefore needs a matching change to `ci/uki-cmdline.txt`
in the same review. The composefs digest is not compared with the image here: bootc refuses a UKI whose
digest does not match at install time, and `sign` runs only after `install-boot` installed and booted
this image.

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

- accepted with that run's certificate (so the refusals below are not a gate that refuses everything);
- **refused exactly as the `sign` job runs it**, with the committed Nyra certificate: an image signed
  with a test key never gets a release signature (today because no certificate is committed; once it
  is, because the signature does not match);
- refused with a certificate that did not sign it;
- refused even when signed with the trusted key: a signed add-on in place of the UKI, the UKI with
  `systemd.import_credentials=on` in its main command line, a second UKI next to it, and an add-on in
  `<uki>.efi.extra.d/`.

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

**Rule: signing needs a protected `main`.** Anyone who can push to `main`, or start the workflow
manually on `main`, gets a signed image (see "Who can sign" below). `main` is protected: changes
reach it only through pull requests, and nobody, administrators included, can push to it directly.
Signing stays off until the two repository variables (step 2) are set; the Google Cloud setup below
can be prepared at any time. If that protection is ever lifted, remove the variables first.

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
2. With `main` protected (rule above), set the two **repository variables** (Settings › Secrets
   and variables › Actions › Variables; they are not secrets):
   ```sh
   gh variable set GCP_WIF_PROVIDER -R NyraOS/nyra-base --body "projects/<number>/locations/global/workloadIdentityPools/github/providers/nyra-base"
   gh variable set GCP_SIGNER_SA    -R NyraOS/nyra-base --body "nyra-image-signer@<project>.iam.gserviceaccount.com"
   ```
3. Run the workflow on `main` (`gh workflow run image.yml -R NyraOS/nyra-base --ref main`):
   it builds, signs and verifies. The job summary shows the signed digest.

**Who can sign:**
- **anyone who can push to `main` or start the workflow manually on `main`**: the workflow runs
  whatever is on `main`, and the attribute condition cannot tell a reviewed merge from a direct push
  by the same account. Without the protection on `main`, that would include anyone with write
  access, automated contributors too, which is why signing needs it (rule above);
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
