# OpsRabbit P0 smoke test prerequisites and runbook

Use this runbook for each fresh OpsRabbit installation before recording P0-01 through P0-09. It defines the QA identities, tenant-scoped connection fixtures, safe credential handling, and evidence needed to repeat the tests without relying on the customer to create test data. Previous PASS results are historical; every installation starts with all nine statuses as **NOT RUN**.

This file contains no passwords, session cookies, API tokens, or recovery codes. Keep it in the repository; keep credentials only in a local password manager or macOS Keychain. Base64 is reversible encoding, not protection, and must not be used as a credential store.

## Deployment entry criteria

1. Confirm the selected runtime (Cloud Run, GKE Standard, GKE Autopilot, or shared GKE), the canonical HTTPS origin, intended release identifier and image digests, license entitlements, and a working deployment-admin account. Do not reuse a release identifier from a previous installation.
2. Run `python3 scripts/verify-installation.py --url https://<origin> --timeout 300` from the installer repository. Record TLS, web HTML, `/api/health` with `ok: true`, and HTTP redirect results; a native `run.app` URL does not need the HTTP redirect. This check is a prerequisite, not a substitute for authenticated smoke tests.
3. Create a unique non-secret run ID, for example `qa-YYYYMMDD-HHMM`. Record the run ID, deployment URL, runtime, intended release, test time, tester, and evidence links in the test record. Do not put credentials or full authenticated HTTP responses in that record.
4. Use separate Chrome profiles or isolated browser sessions for QA-A, QA-B, and the deployment admin. OpsRabbit allows one interactive session per user; logging in elsewhere can invalidate an earlier session.

For the October 5 Autopilot run, the new installation is deployed and the endpoint verifier passes. The user reports installing the signed offline license; record agent-pack checks as BLOCKED until entitlement is independently confirmed.

## Local test credentials

Create dedicated, approved QA mailboxes or test-only local accounts for each run. A deployment admin may create users through **Users and Groups** after first-admin bootstrap. Do not reset or take over a real employee account merely to make a test autonomous. If a user must receive an invitation, verify that the mailbox is controlled by QA before creating it.

Generate a unique random password of at least 24 characters for each local test account, satisfying the application's 15–128 character password policy. Save it in the local password manager or macOS Keychain under a label containing the run ID, tenant, and account email. Use browser autofill or a trusted local credential helper for account creation and sign-in. Never paste the password into chat, a tool response, a shell command line, a screenshot, a HAR file, the runbook, Git, or Terraform state. Avoid reading password values into the assistant's context. If the account form requires the assistant to type a password through a tool call, stop and have the user enter or autofill it locally; do not request the password in chat.

Do not create a base64 file or an `.env` file for passwords. If a CLI-based account setup is later added, it must generate the secret locally, pass it to the application without logging or command-line arguments, and store it in Keychain before reporting only the account label and success or failure. A password reset or rotation requires updating that local entry and revoking old sessions. Remove test-only credentials from the local vault during fixture cleanup.

## Tenant and user prerequisites

As the deployment admin, create two active tenants named **QA-A** and **QA-B** unless approved active tenants with those names already exist. Record their IDs, but do not recreate a tenant just because it is not selected in the current browser. Create or verify one test administrator for each tenant with a deployment-level **Operator** role and **Tenant Admin** membership in that tenant only. Confirm neither account has membership in the opposite QA tenant. Keep the deployment admin separate for tenant-switch checks and recovery.

| Identity | Deployment role | QA-A membership | QA-B membership | Purpose |
| --- | --- | --- | --- | --- |
| Release admin | Admin | May access | May access | Create tenants and users; perform P0-09 |
| QA-A test admin | Operator | Admin | None | P0-01, P0-02, P0-05, P0-06, P0-08 |
| QA-B test admin | Operator | None | Admin | P0-05, P0-07 |

The earlier run used named employee accounts for some tenant roles. Treat those as historical, not automatic fixtures for a new deployment. Use dedicated QA accounts or obtain explicit approval before assigning an existing person's account. Verify membership in **Tenants** and global role in **Users and Groups**. If license entitlements hide a page, record **BLOCKED** with the entitlement evidence rather than marking it PASS.

The deployed role model reserves **Status** and global **Plugins** and **Scheduler** for the deployment Admin. A tenant's Operator + Tenant Admin can manage tenant Connections but cannot use Status. From the updated P0-01 definition onward, verify QA-A login and tenant context, then verify that direct `/status` navigation falls back to `/help` without exposing deployment Status. P0-03 checks Status separately as the release admin. Historical P0-01 failures under the older definition remain unchanged; do not retroactively relabel them. For P0-04, use a suitably entitled identity for each page and record which identity was used; do not silently grant the QA Operators deployment Admin or claim a protected page passed under their identity.

## Connection fixtures

As QA-A test admin in QA-A, create `<run-id>-conn-a` under **Connections**. As QA-B test admin in QA-B, create `<run-id>-conn-b`. For both, select the built-in **Custom** provider (`generic_env`), set description to `Release isolation fixture`, add only non-secret environment value `FEATURE_FLAG=enabled`, add no secret or file values, leave **Test Connection** unused, and save. These fixtures store metadata only; they do not validate an AWS account or provider connectivity. Do not add AWS or GCP credentials to these P0 isolation fixtures.

Record each saved connection's name and current-version identifier in the non-secret test record. Refresh both tenant views and verify that each fixture remains visible only to its owner. Inspect only the ordinary UI or safe response fields to confirm no secret value was stored. The current UI exposes the connection picker from **Agents → New agent → Connections → Configure** without saving an agent; use its exact-name search for P0-06 and P0-07. If a later release requires an entitled agent or attachment, create a minimal tenant-local test agent with the same scope in each tenant and record that prerequisite; do not grant cross-tenant access to make the picker test pass.

## Test execution and status record

For each test, set status to **NOT RUN**, **IN PROGRESS**, **PASS**, **FAIL**, or **BLOCKED**. Use IN PROGRESS only when part of a test has been observed but its full pass criteria have not been met. Record the actual result and evidence reference before marking PASS. Stop immediately if any test exposes another tenant's name, metadata, owner, status, or secret field. Do not perform update, delete, or provider execution probes for P0-08.

| ID | Test steps | Pass criteria | Status |
| --- | --- | --- | --- |
| P0-01 | In a fresh profile, sign in as QA-A Operator/Tenant Admin, verify QA-A active, then navigate directly to `/status`. | Login and app shell load with QA-A active; the UI falls back to `/help` without exposing deployment Status. | NOT RUN |
| P0-02 | Refresh, sign out, open a bookmarked authenticated route, then sign in again as QA-A. | Tenant survives refresh; old session is rejected after sign-out; bookmarked route loads after re-login. | NOT RUN |
| P0-03 | As deployment Admin, check Status and the deployed release against the installation record. | Backend ready; web/backend release matches intended version; no migration failure or repeated crashes. A CI run ID is acceptable only if it is the intended release identifier. | NOT RUN |
| P0-04 | Open Chat, Agents, Connections, Plugins, Scheduler, Forms, Knowledge, and Configuration as an entitled account. | Each entitled page loads real content without error banner, redirect loop, or stale-tenant shell. Record genuinely unentitled pages as BLOCKED, not PASS. | NOT RUN |
| P0-05 | Create the two Custom-provider fixtures above; refresh each Connections page. | Each fixture appears only in its owning tenant; saved data has no secret value. No provider test is run. | NOT RUN |
| P0-06 | In QA-A, search Connections and the agent connection picker for the exact `conn-b` name. | Zero results; no QA-B name, metadata, owner, status, or secret fields disclosed. | NOT RUN |
| P0-07 | In QA-B, search Connections and the agent connection picker for the exact `conn-a` name. | Same zero-result, non-disclosure behavior. | NOT RUN |
| P0-08 | From the QA-A session, perform only the product's normal non-mutating detail GET for QA-B's fixture identifier. | Resource-hiding response, normally 404, with no QA-B metadata. The current backend route is name-keyed under `/configuration/integrations/targets/:name`; verify the actual routed URL for the deployed release rather than assuming an opaque-ID API. | NOT RUN |
| P0-09 | As release admin, switch QA-A → QA-B → QA-A and refresh after each switch. | Connections and agents reflect the selected tenant each time; no rows from the prior tenant remain cached. | NOT RUN |

For P0-08, use the authenticated browser's normal read request and record only status code plus whether cross-tenant fields were absent. Do not copy cookies, authorization headers, or full responses into the test record. For P0-03, compare against the build or image metadata captured before testing; do not infer release correctness from a healthy `/api/health` response alone.

## Evidence and cleanup

Keep a per-run record with the deployment URL, timestamp, run ID, tenant IDs, test-account emails, fixture names and IDs, intended release, per-test status, concise observed result, and redacted screenshot or log reference. Redact cookies, tokens, passwords, and user data before sharing evidence. Treat a missing observation as NOT RUN or BLOCKED, never PASS.

After tests, remove only the fixtures and dedicated accounts created for that run, revoke their sessions, and remove their local credential entries. Preserve customer-owned tenants, users, agents, and connections. Record any cleanup that could not be completed; do not delete a tenant solely because it was used for QA if it predates the run.

Source of truth for behavior: the application repository's `docs/auth.md`, `web/src/content/user-guides/en/access-control-and-sharing.md`, and `web/src/content/user-guides/en/connections.md`; the installer repository's `docs/installer-contract.md` and `scripts/verify-installation.py`. Recheck these against the deployed release before using this runbook if the application changes.
