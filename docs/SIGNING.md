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
4. **Output** (artifact `nyra-base-signature`, for publishing in NyraOS#25): an OCI layout with
   the signature tagged `sha256-<digest>.sig`, exactly as it must appear on the registry, plus
   `image-digest`. The image itself is the `nyra-base-oci-archive` artifact (same digest).

The signature uses cosign's older format: a `sha256-<digest>.sig` tag whose layer carries the
certificate and the Rekor v1 signed entry timestamp (SET). It is the only format that
containers/image (bootc, podman, skopeo) verifies today; cosign 3 defaults to the new bundle
format, hence `--new-bundle-format=false --use-signing-config=false`.

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

**The trade-off, for the owner:** the guarantee covers the system image, which is what an attacker
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

## Setting up the signer (owner, once)

**Rule: signing stays off until `main` is protected.** Anyone who can push to `main`, or start the
workflow manually on `main`, gets a signed image (see "Who can sign" below). While this repository
is private on GitHub's free plan, `main` cannot be protected, so anyone with write access, including
automated contributors, could push to it directly. The Google Cloud setup
below can be prepared at any time, but the two repository variables (step 2) are **not** set before
`main` requires pull requests with no direct pushes: when nyra-base moves to the NyraOS organisation
as a public repository, or with GitHub Team.

Google Cloud, with the owner's account (2-step verification on). Everything below is free: IAM,
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
  --attribute-condition="assertion.repository_id == '1409437710' && assertion.repository_owner_id == '251765279' && assertion.ref == 'refs/heads/main' && assertion.workflow_ref == 'WaggSoftware/nyra-base/.github/workflows/image.yml@refs/heads/main' && assertion.event_name in ['push', 'workflow_dispatch'] && assertion.runner_environment == 'github-hosted'"

# Only identities from that provider may act as the signer.
gcloud iam service-accounts add-iam-policy-binding "$SIGNER" --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/github/attribute.repository_id/1409437710"

# Check: no user-managed keys.
gcloud iam service-accounts keys list --iam-account="$SIGNER" --managed-by=user
# If the project belongs to a Google Cloud organisation, also forbid keys outright:
#   gcloud resource-manager org-policies enable-enforce iam.disableServiceAccountKeyCreation --project="$PROJECT_ID"

echo "GCP_WIF_PROVIDER=projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/github/providers/nyra-base"
echo "GCP_SIGNER_SA=$SIGNER"
```

Then, in this order:

1. Commit the address as `subjectEmail` in `files/usr/lib/nyra/containers/policy.json` (pull
   request, normal review). The `sign` job stays skipped: the variables are not set yet.
2. Only once `main` is protected (rule above), set the two **repository variables** (Settings › Secrets
   and variables › Actions › Variables; they are not secrets):
   ```sh
   gh variable set GCP_WIF_PROVIDER -R WaggSoftware/nyra-base --body "projects/<number>/locations/global/workloadIdentityPools/github/providers/nyra-base"
   gh variable set GCP_SIGNER_SA    -R WaggSoftware/nyra-base --body "nyra-image-signer@<project>.iam.gserviceaccount.com"
   ```
3. Run the workflow on `main` (`gh workflow run image.yml -R WaggSoftware/nyra-base --ref main`):
   it builds, signs and verifies. The job summary shows the signed digest.

**Who can sign:**
- **anyone who can push to `main` or start the workflow manually on `main`**: the workflow runs
  whatever is on `main`, and the attribute condition cannot tell a reviewed merge from a direct push
  by the same account. While `main` is unprotected, that would include anyone with write access,
  automated contributors too, which is why signing stays off until then (rule above);
- any Google principal with `iam.serviceAccounts.getOpenIdToken` on the service account: `Owner`,
  `Service Account Token Creator`, `Service Account OpenID Connect Identity Token Creator`,
  `Workload Identity User`, or a custom role with that permission. Keep the project's members to
  the owner alone, with no other grants on the service account.

Every signature is public in Rekor under the signer's address, so an unexpected one is visible.

**When the repository moves** (to the NyraOS organisation), update the attribute condition and
the binding with the new repository and owner IDs. Machines do not change: they trust the service
account's address, not the repository.

## Not covered here

- The signed channel sheet (channel, version order, freshness): NyraOS#23.
- Attestations of the SBOM (mkosi package manifest, bootc `Cargo.lock`) and vulnerability
  thresholds: NyraOS#38.
- Publishing to `updates.nyraos.com`; the registry Worker must also serve the `nyra-base`
  repository and the `.sig` tags: NyraOS#25.
