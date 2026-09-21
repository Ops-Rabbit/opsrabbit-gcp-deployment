mock_provider "google-beta" {}

# Structural tests: given a set of inputs, does the plan produce the
# resources it should? These catch logic bugs -- like the create_vpc=false
# null-subnetwork bug fixed in cloud-run.tf -- that fmt/validate/tflint
# don't check, because they never evaluate conditional expressions.

mock_provider "google" {
  mock_resource "google_secret_manager_secret_version" {
    override_during = plan
    defaults        = { version = "7" }
  }
}

variables {
  application_enabled               = false
  application_origin                = "https://opsrabbit.example.com"
  project_id                        = "test-project"
  backend_image                     = "us-central1-docker.pkg.dev/test-project/opsrabbit/backend@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  web_image                         = "us-central1-docker.pkg.dev/test-project/opsrabbit/web@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  postgresql_administrator_password = "test-password"
  better_auth_secret                = "test-secret"
  opsrabbit_encryption_key          = "test-key"
  backend_uid                       = 1000
  backend_gid                       = 1000
}


run "postgres_custom_tier_requires_enterprise" {
  command = plan
  assert {
    condition     = google_sql_database_instance.opsrabbit.settings[0].edition == "ENTERPRISE"
    error_message = "PostgreSQL 16 custom tiers require an explicit Enterprise edition to avoid an API create failure."
  }
}

run "runtime_connections_and_probes" {
  command = plan
  variables { application_enabled = true }
  assert {
    condition     = alltrue([for c in google_cloud_run_v2_service.opsrabbit[0].template[0].containers : c.startup_probe[0].period_seconds * c.startup_probe[0].failure_threshold + coalesce(c.startup_probe[0].initial_delay_seconds, 0) <= 240])
    error_message = "Every startup probe must fit in the Cloud Run startup budget."
  }
  assert {
    condition     = contains(google_cloud_run_v2_service.opsrabbit[0].template[0].containers[2].args, "--private-ip") && contains(google_cloud_run_v2_service.opsrabbit[0].template[0].containers[1].depends_on, "cloudsql-proxy")
    error_message = "Backend must start after a private-IP proxy."
  }
  assert {
    condition     = alltrue([for v in google_cloud_run_v2_service.opsrabbit[0].template[0].volumes : length(v.cloud_sql_instance) == 0])
    error_message = "Built-in public-IP Cloud SQL integration must not return."
  }
  assert {
    condition     = alltrue([for c in google_cloud_run_v2_service.opsrabbit[0].template[0].containers : c.resources[0].cpu_idle == false]) && google_cloud_run_v2_service.opsrabbit[0].template[0].scaling[0].min_instance_count == 1 && google_cloud_run_v2_service.opsrabbit[0].template[0].scaling[0].max_instance_count == 1
    error_message = "Background tasks require CPU and a warm instance, with bounded scaling."
  }
}
run "secrets_pinned_and_scoped" {
  command = plan
  variables { application_enabled = true }
  assert {
    condition     = alltrue(flatten([for e in google_cloud_run_v2_service.opsrabbit[0].template[0].containers[1].env : [for v in e.value_source : v.secret_key_ref[0].version == "7"]]))
    error_message = "Secret references must use the managed numeric version."
  }
  assert {
    condition     = length(google_secret_manager_secret_iam_member.run_sa_secret_accessor) == 3
    error_message = "Runtime access must be scoped to exactly three secrets."
  }
}
run "uri_escapes_reserved_characters" {
  command = plan
  variables {
    postgresql_administrator_login    = "user+name"
    postgresql_administrator_password = "p@ss:/?#% +"
    postgresql_database_name          = "db name"
  }
  assert {
    condition     = nonsensitive(local.postgresql_database_url) == "postgresql://user%2Bname:p%40ss%3A%2F%3F%23%25%20%2B@127.0.0.1:5432/db%20name?sslmode=disable"
    error_message = "Database URI components must be percent-encoded, including spaces and plus signs."
  }
}
run "requires_real_origin" {
  command = plan
  variables {
    application_enabled = true
    application_origin  = null
  }
  expect_failures = [var.application_origin]
}
run "bootstrap_allows_no_origin" {
  command = plan
  variables { application_origin = null }
}
run "rejects_origin_path" {
  command = plan
  variables { application_origin = "https://example.com/api" }
  expect_failures = [var.application_origin]
}
run "rejects_backend_tag" {
  command = plan
  variables {
    application_enabled = true
    backend_image       = "us-central1-docker.pkg.dev/test-project/opsrabbit/backend:latest"
  }
  expect_failures = [var.backend_image]
}
run "rejects_web_placeholder" {
  command = plan
  variables {
    application_enabled = true
    web_image           = "us-central1-docker.pkg.dev/test-project/opsrabbit/web@sha256:REPLACE_ME"
  }
  expect_failures = [var.web_image]
}
run "rejects_small_ssd" {
  command = plan
  variables { filestore_tier = "BASIC_SSD" }
  expect_failures = [var.filestore_capacity_gb]
}
run "accepts_ssd_minimum" {
  command = plan
  variables {
    filestore_tier        = "BASIC_SSD"
    filestore_capacity_gb = 2560
  }
}
run "rejects_basic_cmek" {
  command = plan
  variables { kms_key_name = "projects/test-project/locations/us-central1/keyRings/test/cryptoKeys/test" }
  expect_failures = [var.kms_key_name]
}
run "rejects_zero_backup_retention" {
  command = plan
  variables { filestore_backup_retention_days = 0 }
  expect_failures = [var.filestore_backup_retention_days]
}
run "backups_are_scheduled_during_bootstrap" {
  command = plan
  assert {
    condition     = can(yamldecode(google_workflows_workflow.backup.source_contents))
    error_message = "The backup workflow must be valid YAML."
  }
  assert {
    condition     = google_cloud_scheduler_job.backup.schedule == "0 2 * * *" && google_workflows_workflow.backup.user_env_vars.RETENTION_DAYS == "14"
    error_message = "Bootstrap must schedule daily backups with 14-day retention."
  }
  assert {
    condition     = !contains(google_project_iam_custom_role.backup.permissions, "file.instances.delete")
    error_message = "Backup automation must never be able to delete the source instance."
  }
}

run "secret_rotation_changes_revision_template" {
  command = plan
  variables { application_enabled = true }
  override_resource {
    override_during = plan
    target          = google_secret_manager_secret_version.better_auth_secret
    values          = { version = "8" }
  }
  assert {
    condition     = one([for e in google_cloud_run_v2_service.opsrabbit[0].template[0].containers[1].env : e.value_source[0].secret_key_ref[0].version if e.name == "BETTER_AUTH_SECRET"]) == "8"
    error_message = "A new secret version must change the revision template, not leave the old version or latest."
  }
  assert {
    condition     = google_secret_manager_secret_version.better_auth_secret.deletion_policy == "ABANDON"
    error_message = "Retain previous secret versions for revision rollback."
  }
}

run "database_requires_tls" {
  command = plan
  assert {
    condition     = google_sql_database_instance.opsrabbit.settings[0].ip_configuration[0].ssl_mode == "ENCRYPTED_ONLY"
    error_message = "Cloud SQL must enforce TLS; this guards the documented Trivy GCP-0015 scanner exception."
  }
}
