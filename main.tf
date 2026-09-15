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

resource "google_project_iam_member" "run_sa_secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.run_sa.email}"
}

# ---------------------------------------------------------------------------
# Filestore -- mounted directly into Cloud Run as a native NFS volume
# (see cloud-run.tf). Zonal, Basic tier, 1 TB minimum capacity.
# ---------------------------------------------------------------------------

resource "google_filestore_instance" "opsrabbit" {
  project  = var.project_id
  name     = "${var.name_prefix}-fs"
  location = "${var.region}-b"
  tier     = var.filestore_tier

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

  settings {
    tier              = var.postgresql_tier
    disk_size         = var.postgresql_disk_size_gb
    disk_autoresize   = false
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

    ip_configuration {
      ipv4_enabled    = var.network_mode == "public"
      private_network = var.network_mode == "private" ? local.vpc_self_link : null

      dynamic "authorized_networks" {
        for_each = var.network_mode == "public" ? var.authorized_networks : []
        content {
          name  = authorized_networks.value.name
          value = authorized_networks.value.cidr
        }
      }
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

resource "postgresql_extension" "vector" {
  name           = "vector"
  database       = google_sql_database.opsrabbit.name
  schema         = "public"
  create_cascade = false
  drop_cascade   = false

  depends_on = [
    google_sql_database.opsrabbit,
    google_sql_user.opsrabbit,
  ]

  lifecycle {
    prevent_destroy = true
  }
}
