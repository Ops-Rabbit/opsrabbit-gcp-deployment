locals {
  # Public custom domains use the same installer contract for every runtime.
  # Cloud Run's native HTTPS URL remains usable without provisioning a load balancer.
  public_endpoint_enabled      = var.network_mode == "public" && (local.cloud_run_enabled || local.gke_enabled) && var.application_origin != null && !try(endswith(var.application_origin, ".run.app"), false)
  public_cloud_run_endpoint    = local.public_endpoint_enabled && local.cloud_run_enabled
  public_gke_endpoint          = local.public_endpoint_enabled && local.gke_enabled && !var.gke_endpoint_detach_for_migration
  public_endpoint_hostname     = var.application_origin == null ? "" : trimprefix(var.application_origin, "https://")
  public_endpoint_certificates = length(var.endpoint_ssl_certificate_self_links) > 0 ? var.endpoint_ssl_certificate_self_links : google_compute_managed_ssl_certificate.application[*].self_link
}

resource "google_compute_global_address" "application" {
  count      = local.public_endpoint_enabled ? 1 : 0
  project    = var.project_id
  name       = "${var.name_prefix}-application"
  depends_on = [google_project_service.required]
}

resource "google_compute_managed_ssl_certificate" "application" {
  count   = local.public_endpoint_enabled && length(var.endpoint_ssl_certificate_self_links) == 0 ? 1 : 0
  project = var.project_id
  name    = "${var.name_prefix}-app-${substr(sha256(local.public_endpoint_hostname), 0, 8)}"
  managed {
    domains = [local.public_endpoint_hostname]
  }
  lifecycle {
    create_before_destroy = true
  }
  depends_on = [google_project_service.required]
}

resource "google_compute_ssl_policy" "application" {
  count           = local.public_endpoint_enabled ? 1 : 0
  project         = var.project_id
  name            = "${var.name_prefix}-application"
  min_tls_version = "TLS_1_2"
  profile         = "MODERN"
  depends_on      = [google_project_service.required]
}

data "google_dns_managed_zone" "application" {
  count   = local.public_endpoint_enabled && var.endpoint_dns_managed_zone != null ? 1 : 0
  project = var.project_id
  name    = var.endpoint_dns_managed_zone
  lifecycle {
    postcondition {
      condition = self.visibility == "public" && (
        "${local.public_endpoint_hostname}." == self.dns_name ||
        endswith("${local.public_endpoint_hostname}.", ".${self.dns_name}")
      )
      error_message = "The endpoint DNS zone must be public and authoritative for application_origin."
    }
  }
}

resource "google_dns_record_set" "application" {
  count        = local.public_endpoint_enabled && var.endpoint_dns_managed_zone != null ? 1 : 0
  project      = var.project_id
  managed_zone = data.google_dns_managed_zone.application[0].name
  name         = "${local.public_endpoint_hostname}."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.application[0].address]
}

resource "google_compute_region_network_endpoint_group" "application" {
  count                 = local.public_cloud_run_endpoint ? 1 : 0
  project               = var.project_id
  name                  = "${var.name_prefix}-application"
  region                = var.region
  network_endpoint_type = "SERVERLESS"
  cloud_run {
    service = google_cloud_run_v2_service.opsrabbit[0].name
  }
}

resource "google_compute_backend_service" "application" {
  count                 = local.public_cloud_run_endpoint ? 1 : 0
  project               = var.project_id
  name                  = "${var.name_prefix}-application"
  protocol              = "HTTP"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  backend {
    group = google_compute_region_network_endpoint_group.application[0].id
  }
  log_config {
    enable      = true
    sample_rate = 1
  }
}

resource "google_compute_url_map" "application" {
  count           = local.public_cloud_run_endpoint ? 1 : 0
  project         = var.project_id
  name            = "${var.name_prefix}-application"
  default_service = google_compute_backend_service.application[0].id
}

resource "google_compute_target_https_proxy" "application" {
  count            = local.public_cloud_run_endpoint ? 1 : 0
  project          = var.project_id
  name             = "${var.name_prefix}-application"
  url_map          = google_compute_url_map.application[0].id
  ssl_certificates = local.public_endpoint_certificates
  ssl_policy       = google_compute_ssl_policy.application[0].id
}

resource "google_compute_url_map" "application_redirect" {
  count   = local.public_cloud_run_endpoint ? 1 : 0
  project = var.project_id
  name    = "${var.name_prefix}-application-redirect"
  default_url_redirect {
    https_redirect         = true
    strip_query            = false
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
  }
}

resource "google_compute_target_http_proxy" "application_redirect" {
  count   = local.public_cloud_run_endpoint ? 1 : 0
  project = var.project_id
  name    = "${var.name_prefix}-application-redirect"
  url_map = google_compute_url_map.application_redirect[0].id
}

resource "google_compute_global_forwarding_rule" "application_https" {
  count                 = local.public_cloud_run_endpoint ? 1 : 0
  project               = var.project_id
  name                  = "${var.name_prefix}-application-https"
  ip_address            = google_compute_global_address.application[0].address
  port_range            = "443"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  target                = google_compute_target_https_proxy.application[0].id
}

resource "google_compute_global_forwarding_rule" "application_http" {
  count                 = local.public_cloud_run_endpoint ? 1 : 0
  project               = var.project_id
  name                  = "${var.name_prefix}-application-http"
  ip_address            = google_compute_global_address.application[0].address
  port_range            = "80"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  target                = google_compute_target_http_proxy.application_redirect[0].id
}
