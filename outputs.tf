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
  value = var.deployment_mode == "cloud_run" ? google_cloud_run_v2_job.filestore_init[0].name : null
}

output "project_id" {
  value = var.project_id
}

output "opsrabbit_url" {
  description = "Canonical application URL for the selected runtime. Verify DNS, TLS and /api/health before declaring installation complete."
  value       = local.cloud_run_enabled || local.gke_enabled ? var.application_origin : null
}

output "public_load_balancer_ip" {
  description = "Static address for the application domain's A record; null for native Cloud Run or private access."
  value       = try(google_compute_global_address.application[0].address, null)
}

output "application_dns_record" {
  description = "Required DNS record, including whether the installer manages it. Certificate issuance requires this domain to resolve to the load balancer."
  value = local.public_endpoint_enabled ? {
    name    = local.public_endpoint_hostname
    type    = "A"
    value   = google_compute_global_address.application[0].address
    managed = var.endpoint_dns_managed_zone != null
  } : null
}

output "installation" {
  description = "Installer handoff metadata, not a live readiness assertion. Use scripts/verify-installation.py after apply."
  value = {
    url                  = local.cloud_run_enabled || local.gke_enabled ? var.application_origin : null
    deployment_mode      = var.deployment_mode
    access_mode          = var.network_mode
    verify_http_redirect = local.public_endpoint_enabled
  }
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
