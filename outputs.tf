output "artifact_registry_repository" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.opsrabbit.repository_id}"
}

output "run_service_account_email" {
  value = google_service_account.run_sa.email
}

output "postgresql_instance_connection_name" {
  value = google_sql_database_instance.opsrabbit.connection_name
}

output "postgresql_host" {
  value = google_sql_database_instance.opsrabbit.private_ip_address
}

output "filestore_ip_address" {
  value = local.filestore_ip_address
}

output "filestore_share_name" {
  value = var.filestore_share_name
}

output "filestore_init_job_name" {
  value = google_cloud_run_v2_job.filestore_init.name
}

output "project_id" {
  value = var.project_id
}

output "opsrabbit_url" {
  value = var.application_enabled ? google_cloud_run_v2_service.opsrabbit[0].uri : null
}

output "cloud_run_service_name" {
  value = var.application_enabled ? google_cloud_run_v2_service.opsrabbit[0].name : null
}
