#!/usr/bin/env bash
# Copy the approved ECR release to Google Artifact Registry without rebuilding.
set -Eeuo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
ECR_ACCOUNT_ID="${ECR_ACCOUNT_ID:?Set ECR_ACCOUNT_ID from your deployment configuration/approved release manifest}"
ECR_REGISTRY="${ECR_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
PROJECT_ID="${PROJECT_ID:?Set PROJECT_ID from your deployment configuration/approved release manifest}"
REGION="${REGION:-us-central1}"
REPOSITORY="${REPOSITORY:-opsrabbit}"
BACKEND_DIGEST="${BACKEND_DIGEST:?Set BACKEND_DIGEST from your deployment configuration/approved release manifest}"
WEB_DIGEST="${WEB_DIGEST:?Set WEB_DIGEST from your deployment configuration/approved release manifest}"
GAR_HOST="${REGION}-docker.pkg.dev"
DESTINATION="${GAR_HOST}/${PROJECT_ID}/${REPOSITORY}"

log() { printf '\n%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

for tool in aws gcloud docker; do
  command -v "$tool" >/dev/null || fail "Required tool missing: $tool"
done
for digest in "$BACKEND_DIGEST" "$WEB_DIGEST"; do
  [[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]] || fail "Invalid SHA-256 image digest."
done

log "Checking AWS, GCP and Docker access"
aws sts get-caller-identity --query '{Account:Account,Arn:Arn}' --output json
gcloud projects describe "$PROJECT_ID" --format='value(projectId)'
docker info >/dev/null

# Verify both sources before creating any destination resources.
for component in backend web; do
  digest="$BACKEND_DIGEST"
  [[ "$component" != web ]] || digest="$WEB_DIGEST"
  aws ecr describe-images --registry-id "$ECR_ACCOUNT_ID" \
    --repository-name "opsrabbit/${component}" --image-ids "imageDigest=${digest}" \
    --region "$AWS_REGION" --query 'imageDetails[0].imageDigest' --output text
done

log "Preparing ${DESTINATION}"
gcloud services enable artifactregistry.googleapis.com --project="$PROJECT_ID" --quiet
# A failed list (permissions/network) must not be mistaken for a missing repository.
repositories="$(gcloud artifacts repositories list --project="$PROJECT_ID" \
  --location="$REGION" --format='value(name)' --quiet)"
repository_path="projects/${PROJECT_ID}/locations/${REGION}/repositories/${REPOSITORY}"
if ! printf '%s\n' "$repositories" | grep -Fxq "$repository_path"; then
  gcloud artifacts repositories create "$REPOSITORY" --project="$PROJECT_ID" \
    --location="$REGION" --repository-format=docker \
    --description='OpsRabbit backend/web images.' \
    --labels=app=opsrabbit --quiet
fi
format="$(gcloud artifacts repositories describe "$REPOSITORY" \
  --project="$PROJECT_ID" --location="$REGION" --format='value(format)')"
[[ "$format" == DOCKER ]] || fail "Destination repository is not a Docker repository."

# Keep registry tokens out of the user's persistent Docker configuration.
# Preserve the active daemon endpoint when using an isolated Docker config.
daemon_host="${DOCKER_HOST:-$(docker context inspect --format '{{.Endpoints.docker.Host}}')}"
auth_dir="$(mktemp -d)"
chmod 700 "$auth_dir"
trap 'rm -rf "$auth_dir"' EXIT
docker_auth() { docker --config "$auth_dir" --host "$daemon_host" "$@"; }
aws ecr get-login-password --region "$AWS_REGION" |
  docker_auth login --username AWS --password-stdin "$ECR_REGISTRY"
gcloud auth print-access-token |
  docker_auth login --username oauth2accesstoken --password-stdin "$GAR_HOST"

for component in backend web; do
  digest="$BACKEND_DIGEST"
  [[ "$component" != web ]] || digest="$WEB_DIGEST"
  source="${ECR_REGISTRY}/opsrabbit/${component}@${digest}"
  target="${DESTINATION}/${component}:sha256-${digest#sha256:}"
  log "Copying ${source} to ${target}"
  docker_auth pull --platform linux/amd64 "$source"
  platform="$(docker_auth image inspect "$source" --format '{{.Os}}/{{.Architecture}}')"
  [[ "$platform" == linux/amd64 ]] || fail "Unexpected platform: ${platform}"
  docker_auth tag "$source" "$target"
  docker_auth push "$target"
  actual="$(gcloud artifacts docker images describe "$target" \
    --project="$PROJECT_ID" --format='value(image_summary.digest)')"
  [[ "$actual" == "$digest" ]] || fail "${component} digest mismatch: expected ${digest}, got ${actual}. Do not deploy."
  log "Verified ${component}: ${DESTINATION}/${component}@${actual}"
done

log 'Both destination digests match. Terraform image values:'
printf 'backend_image = "%s/backend@%s"\n' "$DESTINATION" "$BACKEND_DIGEST"
printf 'web_image     = "%s/web@%s"\n' "$DESTINATION" "$WEB_DIGEST"
log "If this repository is managed by Terraform, import ${repository_path} before the next plan."
