# GKE Autopilot targeted P0 rerun — 2026-10-05

| Field | Value |
| --- | --- |
| Observation time | `2026-10-05T13:58:40Z` |
| Deployment URL | `https://opsrabbit.appliedaiconsulting.com` |
| Client / deployment | AAIC / OpsRabbit — GKE Autopilot |
| Source chat | `01a0d3d4-2a25-7e40-97c1-918f1d062ca8` — Implement SKILLS-57 changes |
| Scope | P0-01 and P0-08 only; all other manual cases not run in this execution |

| Case | Outcome | Observed evidence |
| --- | --- | --- |
| P0-01 | **FAILED** | In the QA-A Operator browser session, the app shell loaded and the Tenants page displayed QA-A as the only active tenant with this user as Tenant Admin. Direct navigation to `/status` redirected to `/help`; the expected Status page did not load. This rerun did not establish a fresh browser *profile*; the access failure alone is sufficient for FAIL as written. |
| P0-08 | **BLOCKED** | The previously recorded QA-B fixture identifier is `tenant:dec7e07e-21f8-4e61-ae1f-8bd88956c05b:qa-20261005-autopilot-conn-b`. The QA-A UI offers no detail action for an out-of-tenant connection, and the available browser-control surface cannot issue the product's authenticated detail GET with its required tenant header. No cross-tenant request was sent; no 404 or non-disclosure result is claimed. No update, delete, connection test, or agent execution probe was attempted. |

P0-02 through P0-07 and P0-09 were **NOT RUN** in this targeted execution. Their earlier results remain only in the [prior run](2026-10-05-autopilot.md); they are not imported as fresh passes here. No new deployment-health check was run for this retest.

Fixture cleanup remains pending: the earlier run's QA-A/QA-B Custom connection fixtures and tenant-local agent fixtures remain in place; the two approved QA Operator users and QA tenants also remain. Remove only test-owned fixtures after the remaining investigation, and do not remove customer-owned data. No credentials, cookies, tokens, or full authenticated responses are stored in this record.
