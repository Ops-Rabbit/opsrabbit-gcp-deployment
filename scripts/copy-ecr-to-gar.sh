#!/usr/bin/env bash
# Copy the approved ECR release to Google Artifact Registry without rebuilding
# or changing its multi-platform image-index digest.
set -Eeuo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
ECR_ACCOUNT_ID="${ECR_ACCOUNT_ID:?Set ECR_ACCOUNT_ID from your deployment configuration/approved release manifest}"
ECR_REGISTRY="${ECR_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
BACKEND_ECR_REPO="${BACKEND_ECR_REPO:-vg-backend}"
WEB_ECR_REPO="${WEB_ECR_REPO:-vg-webapp}"
PROJECT_ID="${PROJECT_ID:?Set PROJECT_ID from your deployment configuration/approved release manifest}"
REGION="${REGION:-us-central1}"
REPOSITORY="${REPOSITORY:-opsrabbit}"
BACKEND_DIGEST="${BACKEND_DIGEST:?Set BACKEND_DIGEST from your deployment configuration/approved release manifest}"
WEB_DIGEST="${WEB_DIGEST:?Set WEB_DIGEST from your deployment configuration/approved release manifest}"
GAR_HOST="${REGION}-docker.pkg.dev"
DESTINATION="${GAR_HOST}/${PROJECT_ID}/${REPOSITORY}"

log() { printf '\n%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

for tool in aws gcloud crane jq; do
  command -v "$tool" >/dev/null || fail "Required tool missing: $tool"
done
for digest in "$BACKEND_DIGEST" "$WEB_DIGEST"; do
  [[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]] || fail "Invalid SHA-256 image digest."
done

log "Checking AWS, GCP and registry-copy access"
aws sts get-caller-identity --query '{Account:Account,Arn:Arn}' --output json
gcloud projects describe "$PROJECT_ID" --format='value(projectId)'

# Verify both sources before creating any destination resources.
for component in backend web; do
  digest="$BACKEND_DIGEST"
  source_repo="$BACKEND_ECR_REPO"
  if [[ "$component" == web ]]; then
    digest="$WEB_DIGEST"
    source_repo="$WEB_ECR_REPO"
  fi
  actual_source="$(aws ecr describe-images --registry-id "$ECR_ACCOUNT_ID" \
    --repository-name "$source_repo" --image-ids "imageDigest=${digest}" \
    --region "$AWS_REGION" --query 'imageDetails[0].imageDigest' --output text)"
  [[ "$actual_source" == "$digest" ]] || fail "${component} ECR digest mismatch."
done

log "Preparing ${DESTINATION}"
gcloud services enable artifactregistry.googleapis.com --project="$PROJECT_ID" --quiet
# A failed list (permissions/network) must not be mistaken for a missing repository.
repositories="$(gcloud artifacts repositories list --project="$PROJECT_ID" \
  --location="$REGION" --format='value(name)' --quiet)"
repository_path="projects/${PROJECT_ID}/locations/${REGION}/repositories/${REPOSITORY}"
if ! printf '%s\n' "$repositories" | grep -Fxq "$REPOSITORY"; then
  gcloud artifacts repositories create "$REPOSITORY" --project="$PROJECT_ID" \
    --location="$REGION" --repository-format=docker \
    --description='OpsRabbit backend/web images.' \
    --labels=app=opsrabbit --quiet
fi
format="$(gcloud artifacts repositories describe "$REPOSITORY" \
  --project="$PROJECT_ID" --location="$REGION" --format='value(format)')"
[[ "$format" == DOCKER ]] || fail "Destination repository is not a Docker repository."

# Keep registry tokens out of the user's persistent Docker configuration.
auth_dir="$(mktemp -d)"
chmod 700 "$auth_dir"
trap 'rm -rf "$auth_dir"' EXIT
export DOCKER_CONFIG="$auth_dir"
aws ecr get-login-password --region "$AWS_REGION" |
  crane auth login --username AWS --password-stdin "$ECR_REGISTRY"
gcloud auth print-access-token |
  crane auth login --username oauth2accesstoken --password-stdin "$GAR_HOST"

for component in backend web; do
  digest="$BACKEND_DIGEST"
  source_repo="$BACKEND_ECR_REPO"
  if [[ "$component" == web ]]; then
    digest="$WEB_DIGEST"
    source_repo="$WEB_ECR_REPO"
  fi
  source="${ECR_REGISTRY}/${source_repo}@${digest}"
  target="${DESTINATION}/${component}:sha256-${digest#sha256:}"
  crane config --platform=linux/amd64 "$source" |
    jq -e '.os == "linux" and .architecture == "amd64"' >/dev/null || fail "${component} source has no linux/amd64 image."
  log "Copying ${source} to ${target}"
  # Large layers can outlive a local HTTP/2 upload connection. Limit concurrency
  # and retry the idempotent copy; already committed blobs are reused by GAR.
  copied=false
  for attempt in 1 2 3; do
    if GODEBUG=http2client=0 crane cp --jobs 2 "$source" "$target"; then
      copied=true
      break
    fi
    log "${component} copy attempt ${attempt} failed; retrying"
  done
  [[ "$copied" == true ]] || fail "${component} copy failed after three attempts."
  actual="$(crane digest "$target")"
  [[ "$actual" == "$digest" ]] || fail "${component} digest mismatch: expected ${digest}, got ${actual}. Do not deploy."
  gcp_digest="$(gcloud artifacts docker images describe "${DESTINATION}/${component}@${digest}" \
    --project="$PROJECT_ID" --format='value(image_summary.digest)')"
  [[ "$gcp_digest" == "$digest" ]] || fail "${component} Artifact Registry digest mismatch. Do not deploy."
  log "Verified ${component}: ${DESTINATION}/${component}@${actual}"
done

log 'Both destination digests match. Terraform image values:'
printf 'backend_image = "%s/backend@%s"\n' "$DESTINATION" "$BACKEND_DIGEST"
printf 'web_image     = "%s/web@%s"\n' "$DESTINATION" "$WEB_DIGEST"
log "If this repository is managed by Terraform, import ${repository_path} before the next plan."
