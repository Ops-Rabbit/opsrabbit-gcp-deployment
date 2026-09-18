# ---------------------------------------------------------------------------
# Required APIs
# ---------------------------------------------------------------------------

resource "google_project_service" "required" {
  for_each = toset([
    "run.googleapis.com",
    "compute.googleapis.com",
    "file.googleapis.com",
    "artifactregistry.googleapis.com",
    "sqladmin.googleapis.com",
    "secretmanager.googleapis.com",
    "servicenetworking.googleapis.com",
    "vpcaccess.googleapis.com",
    "iam.googleapis.com",
    "workflows.googleapis.com",
    "workflowexecutions.googleapis.com",
    "cloudscheduler.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# ---------------------------------------------------------------------------
# Artifact Registry
# ---------------------------------------------------------------------------

resource "google_artifact_registry_repository" "opsrabbit" {
  location      = var.region
  repository_id = var.name_prefix
  description   = "OpsRabbit backend/web images."
  format        = "DOCKER"
  kms_key_name  = var.kms_key_name # null = Google-managed encryption (default)
  labels        = local.common_labels

  depends_on = [google_project_service.required]
}

# ---------------------------------------------------------------------------
# Cloud Run runtime identity
# ---------------------------------------------------------------------------

resource "google_service_account" "run_sa" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-run"
  display_name = "OpsRabbit Cloud Run runtime identity"

  depends_on = [google_project_service.required]
}

resource "google_artifact_registry_repository_iam_member" "run_sa_pull" {
  location   = google_artifact_registry_repository.opsrabbit.location
  repository = google_artifact_registry_repository.opsrabbit.repository_id
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.run_sa.email}"
}

resource "google_project_iam_member" "run_sa_cloudsql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.run_sa.email}"
}

resource "google_secret_manager_secret_iam_member" "run_sa_secret_accessor" {
  for_each = {
    database_url = google_secret_manager_secret.database_url.secret_id
    better_auth  = google_secret_manager_secret.better_auth_secret.secret_id
    encryption   = google_secret_manager_secret.encryption_key.secret_id
  }
  project   = var.project_id
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.run_sa.email}"
}

# ---------------------------------------------------------------------------
# Filestore -- mounted directly into Cloud Run as a native NFS volume
# (see cloud-run.tf). Zonal, Basic tier, 1 TB minimum capacity.
# ---------------------------------------------------------------------------

resource "google_filestore_instance" "opsrabbit" {
  project      = var.project_id
  name         = "${var.name_prefix}-fs"
  location     = "${var.region}-b"
  tier         = var.filestore_tier
  kms_key_name = var.kms_key_name # null = Google-managed encryption (default)

  file_shares {
    capacity_gb = var.filestore_capacity_gb
    name        = var.filestore_share_name
  }

  networks {
    network      = local.vpc_name
    modes        = ["MODE_IPV4"]
    connect_mode = "PRIVATE_SERVICE_ACCESS"
  }

  labels = local.common_labels

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [
    google_project_service.required,
    google_service_networking_connection.private_services,
  ]
}

# ---------------------------------------------------------------------------
# Cloud SQL for PostgreSQL 16 + pgvector
# ---------------------------------------------------------------------------

resource "google_sql_database_instance" "opsrabbit" {
  project             = var.project_id
  name                = var.postgresql_instance_name
  region              = var.region
  database_version    = "POSTGRES_16"
  deletion_protection = true
  encryption_key_name = var.kms_key_name # null = Google-managed encryption (default)

  settings {
    tier              = var.postgresql_tier
    disk_size         = var.postgresql_disk_size_gb
    disk_autoresize   = true
    availability_type = "ZONAL"

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = 7
      backup_retention_settings {
        retained_backups = var.postgresql_backup_retention_days
        retention_unit   = "COUNT"
      }
    }

    # Trivy 0.74.0's GCP-0015 still checks removed require_ssl, not ssl_mode.
    # ENCRYPTED_ONLY enforces TLS; tests/deployment_regressions.tftest.hcl also checks it.
    #trivy:ignore:AVD-GCP-0015
    ip_configuration {
      ipv4_enabled    = false
      private_network = local.vpc_self_link
      ssl_mode        = "ENCRYPTED_ONLY"
    }

    # Postgres audit/diagnostic logging -- required for the compliance
    # posture this product needs when deployed into customer accounts,
    # not optional extras.
    database_flags {
      name  = "log_temp_files"
      value = "0" # log all temp files, not just ones above a size threshold
    }
    database_flags {
      name  = "log_connections"
      value = "on"
    }
    database_flags {
      name  = "log_disconnections"
      value = "on"
    }
    database_flags {
      name  = "log_lock_waits"
      value = "on"
    }
    database_flags {
      name  = "log_checkpoints"
      value = "on"
    }

    user_labels = local.common_labels
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [
    google_project_service.required,
    google_service_networking_connection.private_services,
  ]
}

resource "google_sql_database" "opsrabbit" {
  project  = var.project_id
  name     = var.postgresql_database_name
  instance = google_sql_database_instance.opsrabbit.name

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_sql_user" "opsrabbit" {
  project  = var.project_id
  name     = var.postgresql_administrator_login
  instance = google_sql_database_instance.opsrabbit.name
  password = var.postgresql_administrator_password
}

# No postgresql_extension resource here. The backend's own Drizzle
# migration (0000_fantastic_marvel_apes.sql) runs `create extension if
# not exists vector;` on startup, using the same DATABASE_URL credentials
# -- it's already inside the VPC via Cloud Run's Direct VPC egress by the
# time it runs. Terraform creating the extension too would be redundant,
# and having Terraform never need to open a connection into the private
# database removes an entire category of operational complexity (no
# bastion/tunnel required just to run `terraform apply`).
