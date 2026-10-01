# OpsRabbit customer installer

The customer selects one runtime: Cloud Run, a new GKE Standard cluster, a new
GKE Autopilot cluster, or an existing shared GKE cluster. Installation succeeds
only when the customer can use OpsRabbit at the advertised HTTPS origin.
Creating cloud resources or reaching a pod through port forwarding does not
meet that requirement.

## Customer inputs and installer responsibilities

Customer inputs are the project/region, runtime, approved image digests,
application domain, DNS ownership, existing-network/cluster details where
applicable, and protected application credentials. A customer may bring a
certificate; otherwise public custom domains use a Google-managed certificate.
Cloud Run may use its native HTTPS domain.

The installer owns runtime-specific routing, public IP allocation, TLS policy,
HTTP redirection, web-to-backend routing, application origin configuration and
consistent outputs. Customer configuration must not require hand-authored
Kubernetes annotations or expose the backend directly. Existing shared-cluster
infrastructure remains customer-owned and must pass compatibility checks.

Cloud DNS records can be created automatically in a supplied public zone. For
external DNS, the required record is an explicit installation handoff. An
installation awaiting that record or certificate issuance is not ready.

## Release acceptance

Each supported runtime needs a fresh-install acceptance run with the same
approved application release. Verify:

1. The selected runtime is provisioned or reused; no second runtime is created.
2. The canonical URL resolves, TLS validates, HTTP redirects where applicable,
   the web UI loads, and `/api/health` returns JSON with `ok: true`.
3. The first administrator can onboard, sign in, sign out and sign in again.
4. An authenticated workflow runs and event streaming reaches the browser.
5. Application data and credentials survive restart and an image upgrade.
6. Backup and restore cover the actual storage used by that runtime.
7. Failed provisioning can be retried without duplicate installations or
   deleting customer data. Shared-cluster installation does not modify or
   delete the cluster or unrelated namespace resources.

Local Terraform mocks, chart rendering, lint and static security scans are
required checks, but do not substitute for this live acceptance matrix.

## Current implementation boundary

Public endpoint provisioning and consistent URL/runtime configuration now cover
all four choices. `scripts/verify-installation.py` checks endpoint readiness
after apply; it does not perform administrator onboarding or application writes.
Private HTTPS currently supports Cloud Run only. Private GKE is rejected rather
than returning an unreachable application URL.

Cloud Run bootstrap/image import and Filestore initialization remain documented
installation steps. A single-command orchestration of the entire installation,
runtime-specific restore validation, and the four-runtime live acceptance matrix
are not established by the endpoint changes. Switching runtime on an existing
installation requires a migration procedure and must not be presented as an
ordinary image upgrade.
