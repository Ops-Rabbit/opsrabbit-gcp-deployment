# Plan-only tests with isolated mock providers; never read installation state.
mock_provider "google" {}
mock_provider "google-beta" {}
mock_provider "helm" {}
mock_provider "random" {}

# Give only the backup account this email so a binding to another account fails.
override_resource {
  target          = google_service_account.backup
  override_during = plan
  values          = { email = "backup@test-project.iam.gserviceaccount.com" }
}

variables {
  project_id                        = "test-project"
  application_enabled               = false
  backend_image                     = "unused-during-cloud-run-bootstrap"
  web_image                         = "unused-during-cloud-run-bootstrap"
  postgresql_administrator_password = "test-password"
  better_auth_secret                = "test-secret"
  opsrabbit_encryption_key          = "test-key"
  backend_uid                       = 1000
  backend_gid                       = 1000
}

run "default_identity" {
  command = plan
  variables {
    name_prefix = "opsrabbit"
  }
  # Mock only the provider-computed name; role_id remains evaluated from config.
  override_resource {
    target          = google_project_iam_custom_role.backup
    override_during = plan
    values          = { name = "projects/test-project/roles/opsrabbit_backup" }
  }
  assert {
    condition     = google_project_iam_custom_role.backup.role_id == "opsrabbit_backup"
    error_message = "Backup role ID must preserve the default or use the explicit override exactly."
  }
  assert {
    condition     = google_project_iam_custom_role.backup.project == "test-project" && google_project_iam_member.backup.project == "test-project" && google_project_iam_member.backup.role == "projects/test-project/roles/opsrabbit_backup" && google_project_iam_member.backup.member == "serviceAccount:backup@test-project.iam.gserviceaccount.com"
    error_message = "The backup identity must receive the selected custom role in the same project."
  }
  assert {
    condition = toset(google_project_iam_custom_role.backup.permissions) == toset([
      "file.instances.get", "file.backups.create", "file.backups.get",
      "file.backups.list", "file.backups.delete", "file.operations.get",
    ])
    error_message = "The backup role must retain exactly the six existing permissions."
  }
  assert {
    condition     = google_service_account.backup.account_id == "opsrabbit-backup" && google_service_account.backup_scheduler.account_id == "opsrabbit-backup-trigger" && google_workflows_workflow.backup.name == "opsrabbit-filestore-backup" && google_cloud_scheduler_job.backup.name == "opsrabbit-filestore-backup"
    error_message = "Selecting a role ID must not rename backup service accounts, workflow or scheduler."
  }
}

run "null_preserves_prefix_identity" {
  command = plan
  variables {
    name_prefix              = "opsrabbit-test"
    filestore_backup_role_id = null
  }
  # Mock only the provider-computed name; role_id remains evaluated from config.
  override_resource {
    target          = google_project_iam_custom_role.backup
    override_during = plan
    values          = { name = "projects/test-project/roles/opsrabbit_test_backup" }
  }
  assert {
    condition     = google_project_iam_custom_role.backup.role_id == "opsrabbit_test_backup"
    error_message = "Backup role ID must preserve the default or use the explicit override exactly."
  }
  assert {
    condition     = google_project_iam_custom_role.backup.project == "test-project" && google_project_iam_member.backup.project == "test-project" && google_project_iam_member.backup.role == "projects/test-project/roles/opsrabbit_test_backup" && google_project_iam_member.backup.member == "serviceAccount:backup@test-project.iam.gserviceaccount.com"
    error_message = "The backup identity must receive the selected custom role in the same project."
  }
  assert {
    condition = toset(google_project_iam_custom_role.backup.permissions) == toset([
      "file.instances.get", "file.backups.create", "file.backups.get",
      "file.backups.list", "file.backups.delete", "file.operations.get",
    ])
    error_message = "The backup role must retain exactly the six existing permissions."
  }
  assert {
    condition     = google_service_account.backup.account_id == "opsrabbit-test-backup" && google_service_account.backup_scheduler.account_id == "opsrabbit-test-backup-trigger" && google_workflows_workflow.backup.name == "opsrabbit-test-filestore-backup" && google_cloud_scheduler_job.backup.name == "opsrabbit-test-filestore-backup"
    error_message = "Selecting a role ID must not rename backup service accounts, workflow or scheduler."
  }
}

run "override_preserves_backup_contract" {
  command = plan
  variables {
    name_prefix              = "opsrabbit-test"
    filestore_backup_role_id = "Recovery_2.backup"
  }
  # Mock only the provider-computed name; role_id remains evaluated from config.
  override_resource {
    target          = google_project_iam_custom_role.backup
    override_during = plan
    values          = { name = "projects/test-project/roles/Recovery_2.backup" }
  }
  assert {
    condition     = google_project_iam_custom_role.backup.role_id == "Recovery_2.backup"
    error_message = "Backup role ID must preserve the default or use the explicit override exactly."
  }
  assert {
    condition     = google_project_iam_custom_role.backup.project == "test-project" && google_project_iam_member.backup.project == "test-project" && google_project_iam_member.backup.role == "projects/test-project/roles/Recovery_2.backup" && google_project_iam_member.backup.member == "serviceAccount:backup@test-project.iam.gserviceaccount.com"
    error_message = "The backup identity must receive the selected custom role in the same project."
  }
  assert {
    condition = toset(google_project_iam_custom_role.backup.permissions) == toset([
      "file.instances.get", "file.backups.create", "file.backups.get",
      "file.backups.list", "file.backups.delete", "file.operations.get",
    ])
    error_message = "The backup role must retain exactly the six existing permissions."
  }
  assert {
    condition     = google_service_account.backup.account_id == "opsrabbit-test-backup" && google_service_account.backup_scheduler.account_id == "opsrabbit-test-backup-trigger" && google_workflows_workflow.backup.name == "opsrabbit-test-filestore-backup" && google_cloud_scheduler_job.backup.name == "opsrabbit-test-filestore-backup"
    error_message = "Selecting a role ID must not rename backup service accounts, workflow or scheduler."
  }
}

run "accepts_minimum_length" {
  command = plan
  variables { filestore_backup_role_id = "A_." }
  assert {
    condition     = google_project_iam_custom_role.backup.role_id == "A_."
    error_message = "A valid boundary-length ID must be accepted unchanged."
  }
}

run "accepts_maximum_length" {
  command = plan
  variables { filestore_backup_role_id = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" }
  assert {
    condition     = google_project_iam_custom_role.backup.role_id == "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    error_message = "A valid boundary-length ID must be accepted unchanged."
  }
}

run "rejects_empty" {
  command = plan
  variables { filestore_backup_role_id = "" }
  expect_failures = [var.filestore_backup_role_id]
}

run "rejects_too_short" {
  command = plan
  variables { filestore_backup_role_id = "ab" }
  expect_failures = [var.filestore_backup_role_id]
}

run "rejects_too_long" {
  command = plan
  variables { filestore_backup_role_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }
  expect_failures = [var.filestore_backup_role_id]
}

run "rejects_hyphen" {
  command = plan
  variables { filestore_backup_role_id = "backup-role" }
  expect_failures = [var.filestore_backup_role_id]
}

run "rejects_resource_path" {
  command = plan
  variables { filestore_backup_role_id = "projects/test-project/roles/backup" }
  expect_failures = [var.filestore_backup_role_id]
}

run "rejects_space" {
  command = plan
  variables { filestore_backup_role_id = "backup role" }
  expect_failures = [var.filestore_backup_role_id]
}

run "rejects_non_ascii" {
  command = plan
  variables { filestore_backup_role_id = "bäckup" }
  expect_failures = [var.filestore_backup_role_id]
}

run "rejects_newline" {
  command = plan
  variables { filestore_backup_role_id = "backup\n" }
  expect_failures = [var.filestore_backup_role_id]
}

