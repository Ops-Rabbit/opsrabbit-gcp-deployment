# Staging teardown

Scope: the project, region, and backend prefix selected for your staging deployment.
This procedure is for after the sanity test, not before apply.
No protection has been disabled by preparing this document.

1. Stop test traffic and pause the `NAME_PREFIX-filestore-backup` Cloud Scheduler
   job. Wait for running backup workflows and Cloud Run jobs to finish. Decide
   whether any test data or backups must be retained before deleting resources.
2. Remove the three `prevent_destroy` guards in `main.tf`: Filestore, the SQL
   instance, and the SQL database. Set the SQL instance's `deletion_protection`
   to `false`. Explicitly set `deletion_protection = false` on the Filestore
   initialization Cloud Run job in `filestore-init.tf` (the provider default is
   true). If the application was enabled, set its `deletion_protection = false`
   in `cloud-run.tf`, keeping `application_enabled = true` for this step. Also set
   `deletion_protection = false` on the backup workflow in `backups.tf`; its
   provider default is true.
3. With valid Terraform credentials, plan and apply these protection changes
   first, so Terraform state records deletion protection as disabled. Review
   that plan for unexpected changes. Do not disable the application by count
   before its protection update has been applied.
4. Generate a fresh `terraform plan -destroy -out=staging-destroy.tfplan`, review
   it, then apply that saved plan when teardown is authorized. This deletes the
   imported Artifact Registry repository and its images too. If those images
   must survive, settle that ownership/retention decision before proceeding;
   do not use an incomplete targeted destroy as the default cleanup.
5. Filestore backups created by Workflows are not Terraform resources. List
   backups in the deployment region and remove only this test instance's backups that
   are no longer needed. Inspect Cloud SQL retained/final backups as well and
   delete unwanted test backups. Retained backups can continue to incur charges.
6. Verify that SQL, Filestore, the Cloud Run job/service, Scheduler, Workflows,
   and Artifact Registry resources are gone. API enablements intentionally
   remain enabled (`disable_on_destroy = false`); they are not running instances.
   Secret versions use `ABANDON` for rotation, but deleting their parent secrets
   in the full destroy deletes their contents as well.
7. Keep the state bucket until destroy is complete and the final state is
   verified. It is outside this Terraform stack. Old state versions, local
   secrets, and saved plans contain sensitive data; retain or delete them
   deliberately. Bucket versioning/soft deletion can retain storage after normal
   object deletion. Remove local saved plans when no longer needed.
8. Restore the source-code destruction guards for future deployments, preserving
   unrelated changes. Check billing afterward for residual resources; billing
   reports can lag actual deletion.

Private service networking cleanup can require waiting for managed-service
network interfaces to disappear after SQL/Filestore deletion. If destroy fails
there, inspect the remaining users, allow cleanup to complete, and re-plan the
remaining destroy. Do not force-delete a connection still in use.

Cloud Run Direct VPC egress can retain managed IP reservations for 1–2 hours
and block subnet deletion after the service/job is gone. Cloud SQL producer
resources can block private-services connection deletion for four days. Keep
state and retry a fresh destroy plan once Google releases these dependencies;
do not run a normal full apply, which would recreate deleted resources.

- https://docs.cloud.google.com/run/docs/configuring/vpc-direct-vpc#troubleshooting
- https://docs.cloud.google.com/vpc/docs/configure-private-services-access
