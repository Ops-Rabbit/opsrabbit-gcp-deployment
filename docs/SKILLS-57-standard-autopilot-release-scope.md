# SKILLS-57 staged installer release

## Scope and finishing criteria

This PR makes Cloud Run, new GKE Standard, and new GKE Autopilot the only
selectable installer runtimes. The reusable SKILLS-56 Helm chart is already
merged. Shared GKE remains part of the Jira ticket's original definition of
done, but is explicitly deferred to a separate PR; `deployment_mode = "shared"`
must fail validation until its networking, identity, storage, permissions, and
live installation behavior have been reviewed. No customer data or resources are
changed by this scope adjustment.

## Repository and release checks

- Installer: `Ops-Rabbit/opsrabbit-gcp-deployment` PR #2 targets `main`.
- Helm chart: merged in PR #3 in the same installer repository.
- Product: `applied-ai-consulting/gaurav-exp` `main` retains backend port 8384,
  web build assets at `/usr/share/nginx/html`, and the HTTP Nginx template on
  port 80. The chart adapts that template to its unprivileged port 8080. This
  source check is not a new image build, vulnerability scan, or live test.
- Local `make check` on 2026-10-22: Terraform format/validate/TFLint passed;
  68 Terraform tests and 30 Python tests passed; strict Helm lint and render
  tests passed; Trivy Terraform and rendered Kubernetes configuration scans
  reported zero findings using embedded checks (downloadable policy cache was
  unavailable).
- `shared_mode_is_deferred` verifies that Terraform rejects the deferred mode.
- Independent P1 review identified an unprefixed GKE API endpoint and an
  Artifact Registry existing-repository lookup mismatch. Both were corrected;
  Standard and Autopilot endpoint assertions and an offline image-copy fixture
  were added to the tests.
- A follow-up P1 review found that the temporary Standard initial node pool
  used the Compute default identity. It now uses the generated or supplied node
  identity after the installer-managed IAM grants; both variants have plan tests.

## Review and rollout limitations

The Jira ticket is not complete until the shared-cluster follow-up is delivered
or its acceptance scope is formally changed. Prior Standard and Autopilot live
QA evidence is recorded in this repository, but this scope change has not been
re-deployed. A merge does not publish a new product image or prove compatibility
with a newer immutable release. Before any production promotion, recheck the
approved image digests and their scan results, resolve the tracked critical
PyJWT finding, and establish backup/restore coverage for the GKE application
volume. GKE endpoint migration is an explicit outage-bearing procedure in the
README, not an ordinary image upgrade.
