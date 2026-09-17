resource "google_cloud_run_v2_service" "opsrabbit" {
  count = var.application_enabled ? 1 : 0

  project             = var.project_id
  name                = "${var.name_prefix}-app"
  location            = var.region
  deletion_protection = true
  ingress             = var.network_mode == "private" ? "INGRESS_TRAFFIC_INTERNAL_ONLY" : "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.run_sa.email

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
      name  = "backend"
      image = var.backend_image

      # Runs as the image's normal (likely non-root) default user. Write
      # access to the Filestore mount is granted via the one-time chown in
      # filestore-init.tf, run manually before application_enabled = true --
      # see that file and the README for the exact command.

      resources {
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
        value = "${local.application_origin}/api"
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
            version = "latest"
          }
        }
      }
      env {
        name = "BETTER_AUTH_SECRET"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.better_auth_secret.secret_id
            version = "latest"
          }
        }
      }
      env {
        name = "OPSRABBIT_NODE_ENCRYPTION_KEY"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.encryption_key.secret_id
            version = "latest"
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
      volume_mounts {
        name       = "codex"
        mount_path = "/home/opsbot/.codex"
      }
      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }

      startup_probe {
        initial_delay_seconds = 20
        period_seconds        = 10
        timeout_seconds       = 5
        failure_threshold     = 30
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

    volumes {
      name = "codex"
      nfs {
        server    = local.filestore_ip_address
        path      = "/${var.filestore_share_name}/codex"
        read_only = false
      }
    }

    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [local.postgresql_connection_name]
      }
    }

    labels = local.common_labels
  }

  depends_on = [
    google_artifact_registry_repository_iam_member.run_sa_pull,
    google_project_iam_member.run_sa_cloudsql_client,
    google_project_iam_member.run_sa_secret_accessor,
    google_filestore_instance.opsrabbit,
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
