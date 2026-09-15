provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

provider "postgresql" {
  host            = local.postgresql_connect_host
  port            = 5432
  username        = google_sql_user.opsrabbit.name
  password        = var.postgresql_administrator_password
  database        = google_sql_database.opsrabbit.name
  sslmode         = "require"
  connect_timeout = 15
  superuser       = false
}
