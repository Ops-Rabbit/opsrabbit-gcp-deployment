# OpsRabbit GCP Terraform

Terraform for deploying OpsRabbit on Google Cloud.

## Architecture

| Component | GCP resource |
|---|---|
| Image registry | Artifact Registry (Docker) |
| Pull identity | Service account + `roles/artifactregistry.reader` |
| Persistent storage | Filestore instance, four subdirectories mounted into Cloud Run as separate NFS volumes (`.opsrabbit`, `git`, `.agent-browser`, `.codex` under `/home/opsbot`) |
| Database | Cloud SQL for PostgreSQL 16, with the `vector` extension |
| Compute | Cloud Run v2 service running `web` (ingress) + `backend` (sidecar) containers |
| Secrets | Secret Manager (DB URL, `BETTER_AUTH_SECRET`, `OPSRABBIT_NODE_ENCRYPTION_KEY`) |
| Networking | Dedicated VPC + subnet, Direct VPC egress from Cloud Run to Filestore |

## Files

| File | Purpose |
|---|---|
| `versions.tf` | Terraform and provider version constraints |
| `providers.tf` | google provider config |
| `variables.tf` | Inputs and validation |
| `locals.tf` | Computed values (DB DSN, origin URL, Filestore IP) |
| `network.tf` | VPC, subnet, private services access |
| `main.tf` | Artifact Registry, service account, Filestore, Cloud SQL |
| `filestore-init.tf` | One-time Cloud Run Job that sets Filestore share ownership |
| `secrets.tf` | Secret Manager secrets |
| `cloud-run.tf` | The Cloud Run v2 service |
| `outputs.tf` | Deployment addresses and resource names |
| `terraform.tfvars.example` | Secret-free example input |

## Prerequisites

- A GCP project with billing enabled
- `roles/editor` or equivalent for the identity running Terraform
- `gcloud` CLI authenticated to the target project
- Terraform `>= 1.15`, `google` provider `>= 6.15`
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
  --region "$REGION" \
  --wait
```

### 5. Import the OpsRabbit images

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

### 6. Deploy

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

## Destruction protection

Cloud SQL, the database, and Filestore have `prevent_destroy` /
`deletion_protection = true`. Intentional removal requires a reviewed
change that removes those guards after backups and approval.
