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

  filestore_ip_address = google_filestore_instance.opsrabbit.networks[0].ip_addresses[0]
}
