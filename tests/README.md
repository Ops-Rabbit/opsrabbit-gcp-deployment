# Offline tests

Run `make test` from the repository root with Terraform 1.15+ and Python 3.10+.
No GCP project, credentials, or running service is required. Initial provider
installation can download public binaries; tests do not call Google APIs.

- `*.tftest.hcl`: mocked Google-provider plans, including invalid inputs,
  private-IP connectivity, startup budgets, secret version changes in revision
  templates, least-privilege secret bindings, and backup configuration.
- `security.tfvars.example`: synthetic inputs for Trivy static analysis, never
  deployment credentials.
- `test_offline_behavior.py`: executes the backup YAML with deterministic fake
  HTTP responses and fake sleeps. Covers creation/operation failure, timeout,
  pagination, retention boundaries, unrelated backups, and deletion failures.
  Also inspects Terraform's dependency graph to verify API/bootstrap ordering.
- `workflow_runner.py`: a deliberately limited interpreter for the workflow's
  syntax subset. Unsupported operations fail; there is no real HTTP adapter.
  This tests our control flow, not compatibility with the Google Workflows
  execution engine. YAML parsing uses Terraform console in an empty temporary
  directory with no backend or providers. Python tests use only the standard
  library and reject socket creation during workflow execution.

Run individual suites after `terraform init -backend=false`:

```sh
terraform test
python3 -m unittest discover -s tests -p 'test_*.py' -v
```

Secret tests verify the revision **template** changes when the referenced
version changes; only a deployed service could verify actual GCP revision
creation. Tests never perform that deployment. Real image startup, OAuth/login,
SQL migrations, NFS concurrency, IAM enforcement, and backup restore remain
separate, explicitly manual staging checks described in the root README.
