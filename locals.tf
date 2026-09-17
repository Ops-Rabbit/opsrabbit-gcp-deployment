locals {
  common_labels = merge(var.labels, {
    app = var.name_prefix
  })

  application_origin = coalesce(
    var.application_origin,
    "https://placeholder-until-first-apply.run.app"
  )

  # Falls back to nginx's "_" catch-all only if no real domain is set yet.
  web_server_name = var.application_origin != null ? trimprefix(var.application_origin, "https://") : "_"

  postgresql_connection_name = google_sql_database_instance.opsrabbit.connection_name

  # Cloud SQL is still reached via the Cloud Run Unix-socket volume type
  # (independent of the Filestore/Direct-VPC-egress networking below) --
  # this doesn't require the VPC at all, Google manages that path itself.
  postgresql_database_url = "postgresql://${var.postgresql_administrator_login}:${var.postgresql_administrator_password}@/${var.postgresql_database_name}?host=/cloudsql/${local.postgresql_connection_name}"

  filestore_ip_address = google_filestore_instance.opsrabbit.networks[0].ip_addresses[0]
}
