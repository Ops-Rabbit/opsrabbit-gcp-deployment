locals {
  common_labels = merge(var.labels, {
    app = var.name_prefix
  })

  # Deployment requires an explicit origin; bootstrap does not create the service.
  application_origin = var.application_origin
  web_server_name    = var.application_origin == null ? "_" : trimprefix(var.application_origin, "https://")

  postgresql_connection_name = google_sql_database_instance.opsrabbit.connection_name

  # Only the local hop is plaintext. The private-IP Auth Proxy authenticates
  # the server and encrypts the connection to Cloud SQL.
  postgresql_database_url = "postgresql://${replace(urlencode(var.postgresql_administrator_login), "+", "%20")}:${replace(urlencode(var.postgresql_administrator_password), "+", "%20")}@127.0.0.1:5432/${replace(urlencode(var.postgresql_database_name), "+", "%20")}?sslmode=disable"

  gke_postgresql_host         = coalesce(var.gke_postgresql_host, google_sql_database_instance.opsrabbit.private_ip_address)
  gke_postgresql_database_url = "postgresql://${replace(urlencode(var.postgresql_administrator_login), "+", "%20")}:${replace(urlencode(var.postgresql_administrator_password), "+", "%20")}@${local.gke_postgresql_host}:5432/${replace(urlencode(var.postgresql_database_name), "+", "%20")}?sslmode=require"

  filestore_ip_address = google_filestore_instance.opsrabbit.networks[0].ip_addresses[0]

  cloud_run_enabled          = var.deployment_mode == "cloud_run" && var.application_enabled
  gke_enabled                = var.deployment_mode != "cloud_run"
  gke_cluster_endpoint       = var.deployment_mode == "shared" ? try(data.google_container_cluster.shared[0].endpoint, null) : var.deployment_mode == "autopilot" ? try(google_container_cluster.autopilot[0].endpoint, null) : try(google_container_cluster.opsrabbit[0].endpoint, null)
  gke_cluster_ca_certificate = var.deployment_mode == "shared" ? try(data.google_container_cluster.shared[0].master_auth[0].cluster_ca_certificate, null) : var.deployment_mode == "autopilot" ? try(google_container_cluster.autopilot[0].master_auth[0].cluster_ca_certificate, null) : try(google_container_cluster.opsrabbit[0].master_auth[0].cluster_ca_certificate, null)
  gke_cluster_self_link      = var.deployment_mode == "shared" ? try(data.google_container_cluster.shared[0].self_link, null) : var.deployment_mode == "autopilot" ? try(google_container_cluster.autopilot[0].self_link, null) : try(google_container_cluster.opsrabbit[0].self_link, null)
}
