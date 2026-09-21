# OpsRabbit GCP Terraform

Terraform for deploying OpsRabbit on Google Cloud.

## Architecture

| Component | GCP resource |
|---|---|
| Image registry | Artifact Registry (Docker) |
| Pull identity | Service account + `roles/artifactregistry.reader` |
| Persistent storage | Filestore instance, four subdirectories mounted into Cloud Run as separate NFS volumes (`.opsrabbit`, `git`, `.agent-browser`, `.codex` under `/home/opsbot`) |
| Database | Cloud SQL for PostgreSQL 16, with the `vector` extension |
| Compute | Cloud Run v2 service running `web` (ingress), `backend`, and a private-IP Cloud SQL Auth Proxy |
| File backups | Daily Workflows + Cloud Scheduler backups; 14-day retention |
| Secrets | Secret Manager (DB URL, `BETTER_AUTH_SECRET`, `OPSRABBIT_NODE_ENCRYPTION_KEY`) |
| Networking | Dedicated VPC + subnet, Direct VPC egress from Cloud Run to Filestore |

## Files

| File | Purpose |
|---|---|
| `versions.tf` | Terraform and provider version constraints |
| `providers.tf` | Google and Google Beta provider config |
| `variables.tf` | Inputs and validation |
| `locals.tf` | Computed values (DB DSN, origin URL, Filestore IP) |
| `network.tf` | VPC, subnet, private services access |
| `main.tf` | Artifact Registry, service account, Filestore, Cloud SQL |
| `filestore-init.tf` | One-time Cloud Run Job that sets Filestore share ownership |
| `secrets.tf` | Secret Manager secrets |
| `cloud-run.tf` | The Cloud Run v2 service |
| `private-ingress.tf` | Optional internal HTTPS load balancer and source allowlist |
| `PRIVATE-DEPLOYMENT.md` | Customer network, DNS and TLS responsibilities |
| `STAGING-TEARDOWN.md` | Teardown guards and managed-service cleanup delays |
| `outputs.tf` | Deployment addresses and resource names |
| `terraform.tfvars.example` | Secret-free example input |

## Prerequisites

- A GCP project with billing enabled
- A deployment identity able to enable APIs, create resources/service accounts/custom roles, manage project and secret IAM, and act as the runtime, workflow, and scheduler service accounts (`roles/editor` alone is insufficient)
- `gcloud` CLI authenticated to the target project
- Terraform `>= 1.15`; Google providers pinned by `.terraform.lock.hcl` (Google Beta 6.50.0 is required for private ingress)
- Python 3.10+ for offline workflow tests (CI uses 3.12)
- TFLint 0.64.0 and Trivy 0.74.0 for local lint/security checks
- An approved OpsRabbit release manifest and read access to OpsRabbit's ECR repositories
- Encrypted, access-controlled GCS bucket for Terraform state

## State and secrets

```hcl
# backend.tf
terraform {
  backend "gcs" {
    bucket = "my-org-terraform-state"
    prefix = "opsrabbit"
  }
}
```

`BETTER_AUTH_SECRET` and the encryption key must stay stable across
upgrades.

## Setup

### 1. Configure non-secret inputs

```bash
cp terraform.tfvars.example terraform.tfvars
```

### 2. Supply secrets

```bash
export TF_VAR_postgresql_administrator_password="..."
export TF_VAR_better_auth_secret="..."
export TF_VAR_opsrabbit_encryption_key="..."
```

### 3. Bootstrap apply

```bash
terraform init
terraform plan -out=bootstrap.tfplan
terraform apply bootstrap.tfplan
rm -f bootstrap.tfplan
```

Creates the VPC, Artifact Registry, Cloud SQL, Filestore, the service
account, the Filestore init job, and Secret Manager secrets.
`application_enabled` stays `false`.

### 4. Set Filestore permissions

```bash
docker run --rm --entrypoint sh "<backend_image>" -c "id -u; id -g"
```

Set `backend_uid` / `backend_gid` in `terraform.tfvars`, `terraform apply`,
then:

```bash
gcloud run jobs execute "$(terraform output -raw filestore_init_job_name)" \
  --project "$(terraform output -raw project_id)" \
  --region "$(terraform output -raw region)" \
  --wait
```

### 5. Import the OpsRabbit images

For the approved ECR release, use the copy script after authenticating AWS and
gcloud and starting Docker:

```bash
export PROJECT_ID=my-gcp-project ECR_ACCOUNT_ID=123456789012
export BACKEND_DIGEST=sha256:REPLACE_WITH_APPROVED_BACKEND_DIGEST
export WEB_DIGEST=sha256:REPLACE_WITH_APPROVED_WEB_DIGEST
REGION=us-central1 REPOSITORY=opsrabbit ./scripts/copy-ecr-to-gar.sh
```

Set `AWS_PROFILE` if using a named AWS profile. Supply `PROJECT_ID`, `ECR_ACCOUNT_ID`,
`BACKEND_DIGEST`, and `WEB_DIGEST` explicitly for the approved release. It checks
both ECR digests, enables Artifact Registry, creates
the Docker repository if missing, copies `linux/amd64` images, and verifies exact
destination digest equality. Temporary Docker credentials are deleted on exit.
It prints immutable Terraform image references and does not deploy the app.

If running this **before the infrastructure bootstrap**, import the newly created
repository into the initialized Terraform backend and generate a fresh plan:

```bash
terraform import google_artifact_registry_repository.opsrabbit \
  projects/my-gcp-project/locations/us-central1/repositories/opsrabbit
terraform plan -out=bootstrap.tfplan
```

Use your actual project, region, and repository in the import ID.
Terraform authentication and deployment variables are required for
import. Do not reuse a plan saved before the import.

Alternatively, copy the images manually:

```bash
export AR_REPO="$(terraform output -raw artifact_registry_repository)"
gcloud auth configure-docker "$(echo "$AR_REPO" | cut -d/ -f1)"

docker pull "<opsrabbit-ecr-registry>/<backend-repo>@<backend-digest>"
docker tag  "<opsrabbit-ecr-registry>/<backend-repo>@<backend-digest>" "${AR_REPO}/backend:<release>"
docker push "${AR_REPO}/backend:<release>"

docker pull "<opsrabbit-ecr-registry>/<web-repo>@<web-digest>"
docker tag  "<opsrabbit-ecr-registry>/<web-repo>@<web-digest>" "${AR_REPO}/web:<release>"
docker push "${AR_REPO}/web:<release>"
```

Set `backend_image` / `web_image` in `terraform.tfvars` to the resulting
`@sha256:...` digests.

### 6. Configure the origin and deploy

Set `application_origin` to the HTTPS origin clients will actually use, without
an API path or trailing slash. It is required when enabling the service. For a
custom domain, provision DNS and HTTPS routing separately; this module does not
create domain mappings or a load balancer. To use Cloud Run's deterministic URL,
obtain the project number with `gcloud projects describe PROJECT_ID
--format='value(projectNumber)'` and use
`https://NAME_PREFIX-app-PROJECT_NUMBER.REGION.run.app`.

Application image references must be Artifact Registry SHA-256 digests when
enabling the service; bootstrap placeholders are allowed only while disabled.

```bash
# terraform.tfvars
application_enabled = true
```

```bash
terraform plan -out=deployment.tfplan
terraform apply deployment.tfplan
rm -f deployment.tfplan
```

### 7. Verify

```bash
terraform output
```

The backend's own healthcheck hits `http://127.0.0.1:8384/health` directly
(no `/api` prefix) — that's what this repo's Cloud Run startup/liveness
probes use. Not yet confirmed: whether the public URL, going through the
`web` container's nginx proxy, exposes that same endpoint at `/health` or
`/api/health`. Check both when testing:

```bash
curl --fail --show-error "$(terraform output -raw opsrabbit_url)/health"
curl --fail --show-error "$(terraform output -raw opsrabbit_url)/api/health"
```

## Upgrades

Get the next approved release manifest, re-import both digests, update
`backend_image` / `web_image`, `plan`/`apply`. Don't touch Cloud SQL,
Filestore, `BETTER_AUTH_SECRET`, the encryption key, or `network_mode`
during a routine image upgrade.

## Private networking

For VPN-only access, see [Private deployment](PRIVATE-DEPLOYMENT.md) and
[`private.tfvars.example`](private.tfvars.example). Private mode provisions an
internal HTTPS load balancer and source allowlist while disabling direct
Cloud Run URLs. The customer supplies VPN connectivity, DNS and TLS certificates.

## Destruction protection

Cloud SQL, the database, and Filestore have `prevent_destroy` /
`deletion_protection = true`. Intentional removal requires a reviewed
change that removes those guards after backups and approval.

## Runtime and rotation

The backend connects to localhost:5432. A pinned Cloud SQL Auth Proxy sidecar
uses `--private-ip` over Direct VPC egress and encrypts/authenticates the remote
connection. `sslmode=disable` applies only to the local connection to the proxy.
All secret environment variables reference Terraform-managed numeric versions,
so changes produce a new revision. Replaced versions are retained for rollback;
disable/destroy obsolete versions after the rollout and rollback window.
Runtime secret access is limited to the three
application secrets.

A password rotation can still interrupt old instances before the new revision
is ready: schedule a maintenance window, stop new work, rotate and apply, then
verify database access and login. Do not rotate the encryption key without an
application-supported data migration; pinning versions does not re-encrypt data.

One warm instance with continuously allocated CPU supports background work and
incurs idle compute charges. `cloud_run_concurrency` defaults to 20 so long-lived
event streams leave capacity for health checks and other API calls. Setting it
to one can cause HTTP 429 responses even with low CPU and memory usage.
`cloud_run_request_timeout_seconds` defaults to 3600 (one hour); streams still
need client reconnection when that deadline expires. Tune concurrency against
staging workload measurements before adding CPU or memory.

Revision maximum instances remains one to limit independent background workers
sharing persistent files. Request concurrency is not a filesystem lock: multiple
requests and background jobs can write concurrently, and revisions can overlap
during a rollout. Cloud Run NFS has no locking support. Until the application
proves safe concurrency, quiesce jobs before upgrades and test git/browser/session
persistence in staging.

## Filestore backup and restore

Bootstrap creates a daily 02:00 UTC backup workflow. After the new backup finishes,
it deletes only backups older than `filestore_backup_retention_days` (default 14)
that carry its ownership label and match this instance and share. Failed backup
creation never triggers pruning. Backups incur storage charges and survive
removal of the schedule. Manual backups without the ownership label are retained.
These file backups and Cloud SQL PITR are separate recovery points; coordinated
application recovery requires quiescing writes and selecting compatible points.

Run an initial backup and inspect its execution before production use:

```bash
gcloud workflows run "$(terraform output -raw filestore_backup_workflow)" \
  --project "$(terraform output -raw project_id)" \
  --location "$(terraform output -raw region)"
gcloud filestore backups list \
  --project "$(terraform output -raw project_id)" \
  --region "$(terraform output -raw region)"
```

Check Workflows execution failures as well as Cloud Scheduler delivery: a
successful scheduler request only means the workflow was started. Operations
that exceed the workflow's one-hour wait fail without pruning; inspect their
Filestore operation status before retrying. Configure production alert routing
for failed executions in your monitoring system.

For a restore drill, select a READY backup and restore it to a **new** Basic-tier
instance using `gcloud filestore instances create RESTORE_INSTANCE
--project=PROJECT_ID --zone=ZONE --tier=BASIC_HDD
--file-share=name=SHARE,capacity=1TB,source-backup=BACKUP_NAME,source-backup-region=BACKUP_REGION
--network=name=VPC,connect-mode=PRIVATE_SERVICE_ACCESS` (use the source's actual
tier, sufficient capacity, share, and network). Mount it from an isolated client
and verify file contents and ownership before planning any production cutover.
Do not overwrite the live share for a drill. Follow [Google's restore
instructions](https://cloud.google.com/filestore/docs/restore-data)
for in-place disaster recovery, with application writes stopped and a fresh
backup of the current state. Record the backup ID, restore duration, and checks.

## Validation before deployment

`make check` runs formatting, schema validation, Google-specific lint rules,
security checks, mocked Terraform regression tests, and offline Python workflow
and dependency tests. Test initialization disables the remote backend. It does
not deploy or require GCP credentials. Provider/plugin installation may download
public binaries. See [tests/README.md](tests/README.md) for test boundaries.
The mock tests do not validate image entrypoints or call Google APIs.

Before promotion, use a disposable staging project to verify:

1. Bootstrap with APIs initially disabled; execute the Filestore init job.
2. Both release images start, nginx proxies API calls, and migrations create
   the expected database schema and vector extension.
3. Login and redirects work at the configured HTTPS origin.
4. A background job progresses after its HTTP request finishes.
5. Data, git workspaces, browser sessions, and credentials survive an instance
   restart; concurrent work and revision replacement do not corrupt the share.
6. Secret rotation creates a new revision with the intended versions.
7. A backup completes, expired owned backups are pruned, unrelated backups are
   preserved, and an isolated restore recovers the expected files.

Basic SSD requires at least 2560 GiB; Basic HDD requires 1024 GiB. The supported
Basic tiers cannot use CMEK, so non-null `kms_key_name` values are rejected.
Cloud SQL storage grows automatically; monitor capacity and cost.

## Local and CI checks

CI uses the same Make targets as local development:

| Command | Purpose |
|---|---|
| `make fmt-check` | Check Terraform formatting without changing files |
| `make validate` | Initialize without a backend and validate configuration |
| `make lint` | Initialize the pinned Google ruleset and run TFLint |
| `make security` | Scan Terraform with Trivy; findings of any severity fail |
| `make test` | Run mocked Terraform plans and offline Python tests |
| `make check` | Run all of the above |

Install the tool versions listed above; Terraform remains pinned to 1.15.9 in CI.
`TRIVY=/path/to/trivy` and `PYTHON=/path/to/python3` can override local executable
paths, for example `make check TRIVY=/path/to/trivy`.

Checks initialize Terraform with `-backend=false -input=false -lockfile=readonly`.
The committed lockfile includes Linux x86_64 and macOS ARM64 package hashes.
After changing provider versions, run `make lock-providers` and commit the
updated `.terraform.lock.hcl` before running CI. This downloads signed provider
packages from the public registry, without connecting to GCP.
They do not authenticate to GCP or read remote state. Provider/plugin/tool
installation may download public binaries. `make init`, `make plan`, and
`make apply` remain separate deployment commands and are never called by CI.

Trivy replaces tfsec and scans configuration only, using synthetic inputs in
`tests/security.tfvars.example`. It does not pull application images or query
GCP. `--skip-check-update` avoids network downloads of policy updates; a fresh
installation falls back to checks embedded in the pinned Trivy binary. Trivy
logs this fallback at ERROR level even though scanning succeeds. Existing
cached policy bundles can be used locally; use a clean Trivy cache when comparing
to CI. Upgrade the pinned scanner periodically to refresh embedded checks.

The one resource-scoped `AVD-GCP-0015` exception documents the scanner's failure
to recognise `ssl_mode = "ENCRYPTED_ONLY"`. A mocked regression test verifies that
TLS remains required; there is no global rule suppression.

The workflow uses Node 24 actions pinned to commit SHAs, explicit tool versions,
a fixed Ubuntu release, 15-minute job timeouts, and cancellation of superseded
runs. It runs on pushes to main and feature/gcp-deployment, PRs targeting main,
and manual dispatch. Weekly Dependabot PRs update action pins; executable
versions in the workflow environment are maintained separately. No GCP secrets
or authentication steps are present.
