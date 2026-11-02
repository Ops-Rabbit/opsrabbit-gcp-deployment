# Install OpenSandbox with OpsRabbit

This option installs the OpenSandbox 1.1.1 Kubernetes components and configures
a fresh OpsRabbit database to use them. It is for a dedicated Standard or
Autopilot cluster owned by this installer. It is disabled by default.

## Before applying

- Follow the main README's GKE installation steps, including state isolation,
  immutable application images, database migration and HTTPS configuration.
- Use an OpsRabbit backend release whose `initialize-opensandbox.js --capabilities`
  reports `contractVersion: 1`, `activation: true`, and `verification: true`. Older images fail the
  bootstrap check; they are never silently accepted as enabled.
- Install Python 3.10+, kubectl, gcloud and the GKE auth plugin on the machine
  running Terraform. Its identity needs cluster administration for the upstream
  CRDs and RBAC and permission to read/create the selected Kubernetes Secrets.
- Use the OpsRabbit Kubernetes server image built with `Dockerfile.kubernetes`
  (version `1.1.1-opsrabbit-k8s.1`), not the unmodified upstream server or the
  Docker runtime image. It supplies the `unprivileged` Kubernetes isolation profile.
- Mirror that server, the approved controller, ingress-gateway, execd and egress
  release-1.1.1 images, and the compatible OpsRabbit sandbox image into your
  Artifact Registry. Supply their destination SHA-256 digests below. The nodes
  need reader access to every selected repository; the installer grants access
  to its own repository. A supplied custom Standard node identity must already
  have that access. No customer workload pulls from private AWS ECR.
- Review the [upstream permissions](SKILLS-143-installer-security-decision.md).
  The controller and server have cluster-wide privileges. Namespaces do not
  restrict those privileges. Autopilot additionally enables `allow_net_admin`
  so the network-filtering sidecar can enforce the requested egress policy.
  This option is not supported for shared clusters.
- Both managed cluster modes use IPv4-only Pod ranges. The server therefore
  disables the upstream privileged IPv6-disable init container. Workload
  containers drop all capabilities and run non-root without privilege escalation;
  explicit Unconfined AppArmor/seccomp permit the Bubblewrap user namespaces.
  This remains workspace-only execution, not unrestricted filesystem access.

## Configuration

Add to the same private input file as the installation:

```hcl
deployment_mode = "standard" # or "autopilot"
opensandbox_enabled = true
opensandbox_namespace = "opensandbox-system"
opensandbox_workload_namespace = "opensandbox"
opensandbox_images = {
  controller = "REGION-docker.pkg.dev/PROJECT/REPOSITORY/controller@sha256:DIGEST"
  server     = "REGION-docker.pkg.dev/PROJECT/REPOSITORY/server@sha256:DIGEST"
  gateway    = "REGION-docker.pkg.dev/PROJECT/REPOSITORY/gateway@sha256:DIGEST"
  execd      = "REGION-docker.pkg.dev/PROJECT/REPOSITORY/execd@sha256:DIGEST"
  egress     = "REGION-docker.pkg.dev/PROJECT/REPOSITORY/egress@sha256:DIGEST"
  sandbox    = "REGION-docker.pkg.dev/PROJECT/REPOSITORY/sandbox@sha256:DIGEST"
}
```

Replace every placeholder with an approved immutable image. Run the README's
`terraform plan` and apply sequence. Terraform installs the base/CRDs,
controller, private gateway and private lifecycle server. It creates missing
API/signing Secrets with random keys through stdin, outside Terraform state.
Existing keys are preserved. No key is printed or passed on a command line.
The helper uses a temporary kubeconfig without changing your selected context.

After the application release is ready, bootstrap probes the authenticated
lifecycle endpoint from the backend, then runs the product's `--verify` command
through stdin. For fresh settings it verifies a workspace-only command, a file
round trip and sandbox retirement before invoking the initializer. Verification
failure prevents activation. Fresh settings use enabled/all mode, session scope,
workspace-only filesystem policy, no host mounts and normal tool approvals.
Product settings contain no GCP-specific configuration contract.

## Verify execution

A Helm-ready status alone does not prove command execution. Bootstrap verifies
the basic execution path; the following acceptance checks cover the wider product.
With an active license and approved provider, use a disposable test agent to
verify a cold first command, a file write/read round trip, nonzero exit reporting,
and sandbox retirement. Check that workload Pods have no service-account token,
the configured image digest is used, and denied egress is actually denied.
Repeat independently on Standard and Autopilot. Never report skipped checks as
passing. Workspace-only execution requires the sandbox image's Bubblewrap
runtime to work under the cluster's admission and node security policies.

## Retry, upgrade and recovery

Reapply a failed plan after correcting its reported prerequisite. Keys are stable
across retries. A failed or incomplete Secret is not replaced automatically.
Keep all OpenSandbox component images aligned with the pinned chart release.
Backend updates must retain support for the initializer contract.
Routine upgrades do not rerun activation. After an intentional configuration
reset, reinitialization requires explicitly replacing the bootstrap Terraform
resource after reviewing the intended settings.

Do not replace a cluster and its Helm releases in one apply. Remove the app and
OpenSandbox releases while the old cluster is reachable, replace the cluster,
then reinstall the releases. Review each plan and preserve the database and
credentials according to the recovery plan. Cluster identity changes force the
OpenSandbox releases to be recreated; they do not make a one-pass provider
transition safe or automatically reinitialize a restored database.

Existing sandbox settings, including an administrator disable, always win.
The helper explicitly reports preservation; it does not imply the existing
endpoint, image or activation matches the proposed inputs. Update existing
settings through Configuration → Sandbox. Restored databases also preserve
their settings and encrypted keys. Do not reset configuration to force an upgrade.

For rotation, update the selected Secret through your approved secret-management
process, roll the server/gateway to load it, and update the endpoint-bound API key
in OpsRabbit. Bootstrap never rotates keys. Back up both application encryption
keys and sandbox credentials using your approved recovery process.

## Disable or uninstall

First disable sandbox execution in OpsRabbit and retire active sandboxes. Then
set `opensandbox_enabled = false` and review/apply the plan. Helm removes the
component releases; upstream CRDs are retained. The helper-created namespaces
and Secrets are also retained to prevent accidental key loss. After verifying
there are no workloads or other users of those resources, the cluster owner may
remove the exact installation namespaces and retained CRDs explicitly.
Destroying the dedicated cluster removes them with the cluster. Never delete
shared platform resources or another installation's registry/state/backups.

## Validation status

Local Terraform, chart and helper tests do not establish live compatibility.
Record the release digests and independent Standard/Autopilot execution results
before describing a release as validated for customer use.
