resource "google_secret_manager_secret" "database_url" {
  project   = var.project_id
  secret_id = "${var.name_prefix}-database-url"
  labels    = local.common_labels

  replication {
    auto {}
  }

  depends_on = [google_project_service.required]
}

resource "google_secret_manager_secret_version" "database_url" {
  secret = google_secret_manager_secret.database_url.id
  # Preserve old versions for revision rollback; retire them after verification.
  deletion_policy = "ABANDON"
  secret_data     = local.postgresql_database_url
}

resource "google_secret_manager_secret" "better_auth_secret" {
  project   = var.project_id
  secret_id = "${var.name_prefix}-better-auth-secret"
  labels    = local.common_labels

  replication {
    auto {}
  }

  depends_on = [google_project_service.required]
}

resource "google_secret_manager_secret_version" "better_auth_secret" {
  secret = google_secret_manager_secret.better_auth_secret.id
  # Preserve old versions for revision rollback; retire them after verification.
  deletion_policy = "ABANDON"
  secret_data     = var.better_auth_secret
}

resource "google_secret_manager_secret" "encryption_key" {
  project   = var.project_id
  secret_id = "${var.name_prefix}-encryption-key"
  labels    = local.common_labels

  replication {
    auto {}
  }

  depends_on = [google_project_service.required]
}

resource "google_secret_manager_secret_version" "encryption_key" {
  secret = google_secret_manager_secret.encryption_key.id
  # Preserve old versions for revision rollback; retire them after verification.
  deletion_policy = "ABANDON"
  secret_data     = var.opsrabbit_encryption_key
}
