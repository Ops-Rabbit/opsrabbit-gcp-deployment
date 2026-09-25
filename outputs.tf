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
  value = local.cloud_run_enabled ? (var.network_mode == "private" ? var.application_origin : google_cloud_run_v2_service.opsrabbit[0].uri) : null
}

output "private_load_balancer_ip" {
  description = "Private frontend address for customer-managed DNS and VPN routes; null in public/bootstrap mode."
  value       = try(google_compute_address.private_ingress[0].address, null)
}

output "cloud_run_service_name" {
  value = local.cloud_run_enabled ? google_cloud_run_v2_service.opsrabbit[0].name : null
}

output "filestore_backup_workflow" {
  value = google_workflows_workflow.backup.name
}

output "region" {
  value = var.region
}

output "gke_cluster_name" {
  description = "GKE cluster used by the Helm deployment, or null when GKE is disabled."
  value       = local.gke_enabled ? local.gke_cluster_name : null
}

output "gke_cluster_self_link" {
  description = "GKE cluster self-link, or null when GKE is disabled."
  value       = local.gke_enabled ? local.gke_cluster_self_link : null
}

output "gke_helm_release_name" {
  description = "OpsRabbit Helm release name, or null when GKE is disabled."
  value       = local.gke_enabled ? helm_release.opsrabbit[0].name : null
}
