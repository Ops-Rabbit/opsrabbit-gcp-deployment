resource "google_cloud_run_v2_service" "opsrabbit" {
  provider = google-beta
  count    = var.application_enabled ? 1 : 0

  project              = var.project_id
  name                 = "${var.name_prefix}-app"
  location             = var.region
  deletion_protection  = true
  ingress              = var.network_mode == "private" ? "INGRESS_TRAFFIC_INTERNAL_ONLY" : "INGRESS_TRAFFIC_ALL"
  default_uri_disabled = var.network_mode == "private"
  # Private clients authenticate with OpsRabbit. The ILB and Cloud Armor enforce
  # network access; the disabled default URL prevents bypassing their allowlist.
  invoker_iam_disabled = var.network_mode == "private"

  # Cloud Run returns this service-level default even when omitted. Keep it
  # explicit to avoid perpetual drift; the revision below keeps one instance warm.
  scaling {
    min_instance_count = 0
  }

  template {
    service_account                  = google_service_account.run_sa.email
    execution_environment            = "EXECUTION_ENVIRONMENT_GEN2"
    max_instance_request_concurrency = var.cloud_run_concurrency
    timeout                          = "${var.cloud_run_request_timeout_seconds}s"

    # Keep background work running and limit concurrent writers to the share.
    # Revision rollouts can still overlap; see the staging checklist in README.
    scaling {
      min_instance_count = 1
      max_instance_count = 1
    }

    # Direct VPC egress -- required to reach Filestore's private IP. No VPC
    # Connector needed. Default egress ("PRIVATE_RANGES_ONLY") still lets the
    # service reach the public internet normally for everything else.
    vpc_access {
      network_interfaces {
        network    = local.vpc_name
        subnetwork = local.subnet_self_link
      }
      egress = "PRIVATE_RANGES_ONLY"
    }

    containers {
      name  = "web"
      image = var.web_image

      command = ["/bin/sh", "-c"]
      args = [
        "sed -i \"s/listen 80;/listen 8080;/g; s/listen \\[::\\]:80;/listen [::]:8080;/g\" /etc/nginx/templates/http.conf.template; exec /docker-entrypoint.sh"
      ]

      resources {
        cpu_idle = false
        limits = {
          cpu    = var.web_cpu
          memory = var.web_memory
        }
      }

      ports {
        container_port = 8080
      }

      env {
        name  = "VITE_API_URL"
        value = "/api"
      }
      env {
        name  = "WEB_API_UPSTREAM"
        value = "http://127.0.0.1:8384"
      }
      env {
        name  = "WEB_TLS_MODE"
        value = "http"
      }
      env {
        name  = "WEB_SERVER_NAME"
        value = local.web_server_name
      }

      startup_probe {
        initial_delay_seconds = 10
        period_seconds        = 10
        timeout_seconds       = 5
        failure_threshold     = 18
        http_get {
          path = "/"
          port = 8080
        }
      }

      liveness_probe {
        period_seconds    = 30
        timeout_seconds   = 5
        failure_threshold = 5
        http_get {
          path = "/"
          port = 8080
        }
      }

      depends_on = ["backend"]
    }

    containers {
      name       = "backend"
      image      = var.backend_image
      depends_on = ["cloudsql-proxy"]

      # Runs as the image's normal (likely non-root) default user. Write
      # access to the Filestore mount is granted via the one-time chown in
      # filestore-init.tf, run manually before application_enabled = true --
      # see that file and the README for the exact command.

      resources {
        cpu_idle = false
        limits = {
          cpu    = var.backend_cpu
          memory = var.backend_memory
        }
      }

      env {
        name  = "NODE_ENV"
        value = "production"
      }
      env {
        name  = "OPSRABBIT_NODE_HOST"
        value = "0.0.0.0"
      }
      env {
        name  = "OPSRABBIT_NODE_PORT"
        value = "8384"
      }
      env {
        name  = "OPSRABBIT_WEB_ORIGIN"
        value = local.application_origin
      }
      env {
        name  = "OPSRABBIT_NODE_BASE_URL"
        value = var.application_origin == null ? null : "${local.application_origin}/api"
      }
      env {
        name  = "OPSRABBIT_NODE_DATA_DIR"
        value = "/home/opsbot/.opsrabbit"
      }
      env {
        name  = "OPSRABBIT_NODE_WORKSPACE_DIR"
        value = "/home/opsbot/git"
      }

      env {
        name = "OPSRABBIT_NODE_DATABASE_URL"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.database_url.secret_id
            version = google_secret_manager_secret_version.database_url.version
          }
        }
      }
      env {
        name = "BETTER_AUTH_SECRET"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.better_auth_secret.secret_id
            version = google_secret_manager_secret_version.better_auth_secret.version
          }
        }
      }
      env {
        name = "OPSRABBIT_NODE_ENCRYPTION_KEY"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.encryption_key.secret_id
            version = google_secret_manager_secret_version.encryption_key.version
          }
        }
      }

      volume_mounts {
        name       = "opsrabbit-data"
        mount_path = "/home/opsbot/.opsrabbit"
      }
      volume_mounts {
        name       = "git-workspace"
        mount_path = "/home/opsbot/git"
      }
      volume_mounts {
        name       = "agent-browser"
        mount_path = "/home/opsbot/.agent-browser"
      }
      # The image expects this runtime path; keep the existing persistent data.
      volume_mounts {
        name       = "agent-state"
        mount_path = "/home/opsbot/.codex"
      }

      startup_probe {
        initial_delay_seconds = 20
        period_seconds        = 10
        timeout_seconds       = 5
        failure_threshold     = 22
        http_get {
          path = "/health"
          port = 8384
        }
      }

      liveness_probe {
        period_seconds    = 30
        timeout_seconds   = 5
        failure_threshold = 5
        http_get {
          path = "/health"
          port = 8384
        }
      }
    }

    # Four separate NFS mounts, one per persistent directory the backend
    # uses -- not one shared mount at /home/opsbot. Each points at its own
    # subdirectory of the same Filestore share.
    volumes {
      name = "opsrabbit-data"
      nfs {
        server    = local.filestore_ip_address
        path      = "/${var.filestore_share_name}/application-data"
        read_only = false
      }
    }

    volumes {
      name = "git-workspace"
      nfs {
        server    = local.filestore_ip_address
        path      = "/${var.filestore_share_name}/git-workspace"
        read_only = false
      }
    }

    volumes {
      name = "agent-browser"
      nfs {
        server    = local.filestore_ip_address
        path      = "/${var.filestore_share_name}/agent-browser"
        read_only = false
      }
    }

    # Preserve the on-disk directory across upgrades; only the volume label changes.
    volumes {
      name = "agent-state"
      nfs {
        server    = local.filestore_ip_address
        path      = "/${var.filestore_share_name}/codex"
        read_only = false
      }
    }

    containers {
      name  = "cloudsql-proxy"
      image = "gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.24.1"
      args = [
        "--private-ip",
        "--address=0.0.0.0",
        "--port=5432",
        "--structured-logs",
        local.postgresql_connection_name,
      ]
      resources {
        cpu_idle = false
        limits   = { cpu = "1", memory = "256Mi" }
      }
      startup_probe {
        period_seconds    = 5
        failure_threshold = 40
        tcp_socket { port = 5432 }
      }
    }

    labels = local.common_labels
  }

  depends_on = [
    google_artifact_registry_repository_iam_member.run_sa_pull,
    google_project_iam_member.run_sa_cloudsql_client,
    google_secret_manager_secret_iam_member.run_sa_secret_accessor,
    google_filestore_instance.opsrabbit,
    google_sql_database.opsrabbit,
    google_sql_user.opsrabbit,
    google_secret_manager_secret_version.database_url,
    google_secret_manager_secret_version.better_auth_secret,
    google_secret_manager_secret_version.encryption_key,
  ]
}

resource "google_cloud_run_v2_service_iam_member" "public" {
  count = var.application_enabled && var.network_mode == "public" && var.allow_unauthenticated ? 1 : 0

  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.opsrabbit[0].name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
