# Backups are independent API objects: removing the schedule does not delete them.
resource "google_service_account" "backup" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-backup"
  display_name = "Filestore scheduled backups"
  depends_on   = [google_project_service.required]
}

resource "google_project_iam_custom_role" "backup" {
  project = var.project_id
  role_id = "${replace(var.name_prefix, "-", "_")}_backup"
  title   = "OpsRabbit Filestore backup maintenance"
  permissions = [
    "file.instances.get", "file.backups.create", "file.backups.get",
    "file.backups.list", "file.backups.delete", "file.operations.get",
  ]
  depends_on = [google_project_service.required]
}

resource "google_project_iam_member" "backup" {
  project = var.project_id
  role    = google_project_iam_custom_role.backup.name
  member  = "serviceAccount:${google_service_account.backup.email}"
}

resource "google_workflows_workflow" "backup" {
  project         = var.project_id
  region          = var.region
  name            = "${var.name_prefix}-filestore-backup"
  service_account = google_service_account.backup.id
  source_contents = file("${path.module}/workflows/filestore-backup.yaml")
  user_env_vars = {
    BACKUP_PARENT   = "projects/${var.project_id}/locations/${var.region}"
    SOURCE_INSTANCE = google_filestore_instance.opsrabbit.id
    SOURCE_SHARE    = var.filestore_share_name
    RETENTION_DAYS  = tostring(var.filestore_backup_retention_days)
  }
  depends_on = [google_project_iam_member.backup]
}

resource "google_service_account" "backup_scheduler" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-backup-trigger"
  display_name = "Invoke Filestore backup workflow"
  depends_on   = [google_project_service.required]
}

resource "google_project_iam_member" "backup_scheduler" {
  project = var.project_id
  role    = "roles/workflows.invoker"
  member  = "serviceAccount:${google_service_account.backup_scheduler.email}"
}

resource "google_cloud_scheduler_job" "backup" {
  project   = var.project_id
  region    = var.region
  name      = "${var.name_prefix}-filestore-backup"
  schedule  = "0 2 * * *"
  time_zone = "Etc/UTC"
  http_target {
    http_method = "POST"
    uri         = "https://workflowexecutions.googleapis.com/v1/${google_workflows_workflow.backup.id}/executions"
    headers     = { "Content-Type" = "application/json" }
    body        = base64encode("{}")
    oauth_token {
      service_account_email = google_service_account.backup_scheduler.email
    }
  }
  depends_on = [google_project_iam_member.backup_scheduler]
}
