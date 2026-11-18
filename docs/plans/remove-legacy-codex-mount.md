# Remove the legacy Codex mount

## Scope and finishing criteria

Remove the unused Cloud Run `/home/opsbot/.codex` NFS mount and volume, stop
creating its legacy Filestore directory for new installations, and correct the
README, chart documentation, and architecture document. Preserve the Filestore
instance/share and every existing directory and file. GKE keeps its existing
whole-home PVC mount; no PVC migration or deletion is included. No deployment
apply, database change, resource deletion, or stored-data cleanup is authorized.

Image verification was initially requested, then explicitly deferred by the
user on 18 November 2026 in favor of inspecting and cleaning the Dockerfiles.
Do not claim that a deployed/approved image has been verified. The product
Dockerfile/Compose cleanup belongs in a companion change in the product repo.

## Design and authorization impact

The backend runtime uses Pi; a local-development Codex proxy is not a production
storage requirement. Remove only the obsolete Cloud Run mount/volume blocks.
Keep the three active data, Git workspace and browser mounts and the existing
Filestore resource unchanged. Correct the chart's descriptive subdirectory list;
it does not create per-directory mounts. No user roles, grants, IAM permissions,
application authorization paths, or public interfaces change.

## Lifecycle inventory

- Existing `codex` Filestore directory: retained, unmounted, no rename/copy/delete.
- Existing `.codex` directory on a GKE home PVC: retained by the unchanged PVC.
- Active application, Git and browser directories: existing paths and backups stay.
- New installations: initialize only the three active Filestore directories.
- Backups: no retention, pruning, restore, or deletion behavior changes. Retained
  legacy files remain subject to the existing storage/backup administration.

## Prior art

- `applied-ai-consulting/claude-code`, `README.md` on `develop`, blob
  `f212cade73f79fe0e1fd151145525c8d52944c91`: contains only the repository title;
  no useful storage guidance. Do not infer an architecture or runtime dependency.
- `openai/codex`, `README.md` on `main`, blob
  `06b02fced7db972084bf0188cb03f60375b51c1c`: Codex CLI is a separately installed
  and authenticated local agent. Keep its optional CLI state distinct from the
  OpsRabbit Pi backend; reject treating CLI installation as a required shared
  application-state mount. No Codex authentication or provider changes are needed.

## Verification and closeout

The mount regression and fresh-share initializer test failed before the fix
and passed afterward. Existing legacy and active files survived repeated
initialization in disposable fixtures. All 74 Terraform mock tests and all 45
offline Python/Helm tests pass using Terraform 1.15.9, Helm 4.3.0 and Python
3.12.14. Terraform validate/fmt pass. The revised four-page Word document was
rendered and every page inspected. Two independent reviews found no actionable
issues. Configuration scanning and autoreview results are recorded in the PR
closeout. No live image/deployment check or apply was run.
