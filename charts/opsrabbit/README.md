# OpsRabbit Helm chart

This chart deploys the OpsRabbit web and backend workloads on Kubernetes,
including GKE Standard, Autopilot, and shared clusters.

## Prerequisites

- Helm 3.14+
- A Kubernetes cluster with a default or selected storage class
- Immutable backend and web image references accessible from the cluster
- A reachable PostgreSQL endpoint using TLS

## Install

Create a private values file outside version control. Prefer an existing
Kubernetes Secret in production:

```yaml
image:
  backend: us-central1-docker.pkg.dev/example/opsrabbit/backend@sha256:...
  web: us-central1-docker.pkg.dev/example/opsrabbit/web@sha256:...
secrets:
  existingSecret: opsrabbit-runtime
```

The existing Secret must contain `DATABASE_URL`, `BETTER_AUTH_SECRET`, and
`OPSRABBIT_NODE_ENCRYPTION_KEY`, unless the key names are overridden in values.

```bash
helm upgrade --install opsrabbit ./charts/opsrabbit \
  --namespace opsrabbit --create-namespace \
  --values /secure/path/opsrabbit-values.yaml
```

For a non-production smoke test, the three secret values can be supplied in a
temporary access-controlled values file. Never commit credentials or pass them
through shell history with `--set`.

## Configuration

The chart exposes independent `backend` and `web` image, resource, command,
argument, and environment settings. `service.type` controls both Services;
`ingress.enabled` creates a networking.k8s.io/v1 Ingress for the web Service.

Persistent application state is stored in one configurable PVC and mounted
under `/home/opsbot` using the `.opsrabbit`, `git`, `.agent-browser`, and
`.codex` subdirectories. Set `persistence.existingClaim` to use a customer-
managed PVC.

Use `serviceAccount.annotations` for provider-specific workload identity. The
Terraform integration supplies the GKE workload identity project value and can
be extended with an explicit service-account annotation when required by the
customer's IAM setup.

## Validation

```bash
helm lint charts/opsrabbit
helm template opsrabbit charts/opsrabbit \
  --set image.backend=example/backend@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --set image.web=example/web@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  --set secrets.existingSecret=opsrabbit-runtime
```
