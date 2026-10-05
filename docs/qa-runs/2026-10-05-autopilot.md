# GKE Autopilot P0 smoke run — 2026-10-05

This record belongs to the fresh GKE Autopilot installation; prior GKE Standard results are not carried forward. Do not record credentials, cookies, tokens, or full authenticated responses here.

| Field | Value |
| --- | --- |
| Run ID | `qa-20261005-autopilot` |
| URL | `https://opsrabbit.appliedaiconsulting.com` |
| GCP project / cluster | `opsrabbit-gcp-deployment` / `opsrabbit-gke` |
| Intended release | `run-37211894105-1` |
| Backend image | `us-central1-docker.pkg.dev/opsrabbit-gcp-deployment/opsrabbit/backend@sha256:463a10f452fb1014592aa504ae44be1c5bbd8224bd9d0c196ce674433dae80a5` |
| Web image | `us-central1-docker.pkg.dev/opsrabbit-gcp-deployment/opsrabbit/web@sha256:9489a41365cb54db5e94d038ddf7165cb9dc3de54a0f2e57138e3bb137b62724` |
| QA-A admin | `atharvaraj.shivudkar@appliedaiconsulting.com` — Operator, QA-A Tenant Admin only |
| QA-B admin | `chinmay.bhosale@appliedaiconsulting.com` — Operator, QA-B Tenant Admin only |
| License | User reports installed; entitlement verification pending |

The public endpoint prerequisite passed: valid managed TLS, web HTML, `/api/health` with `ok: true` and intended backend build, and HTTP-to-HTTPS redirect. A transient 502 occurred when Autopilot moved the sole web pod; chart 0.2.3 revision 4 now runs two web pods with a disruption budget, and the endpoint verifier passes again. QA-A and QA-B tenants and the two scoped Operator accounts were created. License entitlement and tenant isolation still require this run's observations.

| ID | Test | Expected result | Status | Observed result / evidence |
| --- | --- | --- | --- | --- |
| P0-01 | Fresh QA-A login, shell and Status | Active QA-A; pages load | FAIL as written | QA-A Operator signed in, app shell loaded, and QA-A was selected. Direct `/status` redirected to `/help`; deployed role model reserves Status for deployment Admin. Verify Status separately as release admin or revise the test identity/expectation. |
| P0-02 | Refresh, sign out, bookmarked route, sign in again | Tenant persists; old session rejected; direct route loads | PASS | QA-A and its Custom fixture persisted after refresh. Sign-out redirected to `/login`; bookmarked `/configuration/connections` redirected to `/login?next=%2Fconfiguration%2Fconnections`. QA-A re-login restored that route with QA-A selected and the fixture still present. |
| P0-03 | Status, versions, migrations, crashes | Healthy backend and intended matching release | NOT RUN | Endpoint prerequisite alone is insufficient |
| P0-04 | Chat, Agents, Connections, Plugins, Scheduler, Forms, Knowledge, Configuration | Every entitled page loads real content | NOT RUN | |
| P0-05 | Create Custom connection in each tenant; refresh | Only owner sees own non-secret fixture | NOT RUN | Use `qa-20261005-autopilot-conn-a` and `qa-20261005-autopilot-conn-b` |
| P0-06 | QA-A search Connections and agent picker for conn-b | Zero results, no QA-B disclosure | NOT RUN | |
| P0-07 | QA-B search Connections and agent picker for conn-a | Zero results, no QA-A disclosure | NOT RUN | |
| P0-08 | QA-A normal read for QA-B connection identifier | Resource hiding, normally 404; no metadata | NOT RUN | No write or delete probes |
| P0-09 | Release admin switch QA-A → QA-B → QA-A, refresh each time | Tenant-scoped connection and agent lists, no stale rows | NOT RUN | |

See [prerequisites and detailed steps](../qa-p0-smoke-prerequisites.md). Mark PASS only after observed evidence; use BLOCKED for missing entitlement or required user intervention.
