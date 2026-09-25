locals {
  private_ingress_enabled = var.network_mode == "private" && local.cloud_run_enabled && var.private_ingress != null
  create_proxy_subnet     = local.private_ingress_enabled && try(var.private_ingress.proxy_subnet_cidr, null) != null
  existing_proxy_subnet   = local.private_ingress_enabled && try(var.private_ingress.existing_proxy_subnet_self_link, null) != null
}

# Managed load-balancer proxies only: no customer workloads need Private Google Access.
# Proxy-only subnets do not support VPC Flow Logs; backend request logging is enabled below.
# https://docs.cloud.google.com/load-balancing/docs/proxy-only-subnets
# https://docs.cloud.google.com/vpc/docs/using-flow-logs
#trivy:ignore:AVD-GCP-0075
#trivy:ignore:AVD-GCP-0076
resource "google_compute_subnetwork" "ingress_proxy" {
  count         = local.create_proxy_subnet ? 1 : 0
  project       = var.project_id
  name          = "${var.name_prefix}-ingress-proxy"
  region        = var.region
  network       = local.vpc_self_link
  ip_cidr_range = var.private_ingress.proxy_subnet_cidr
  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"
}

data "google_compute_subnetwork" "ingress_proxy" {
  count   = local.existing_proxy_subnet ? 1 : 0
  project = var.project_id
  region  = var.region
  name    = basename(var.private_ingress.existing_proxy_subnet_self_link)
}

# The frontend shares the regular Cloud Run subnet, never the proxy-only subnet.
data "google_compute_subnetwork" "ingress_frontend" {
  count     = local.private_ingress_enabled ? 1 : 0
  self_link = local.subnet_self_link
}

resource "google_compute_address" "private_ingress" {
  count        = local.private_ingress_enabled ? 1 : 0
  project      = var.project_id
  name         = "${var.name_prefix}-private-ingress"
  region       = var.region
  address_type = "INTERNAL"
  subnetwork   = local.subnet_self_link

  lifecycle {
    precondition {
      condition = (
        trimprefix(data.google_compute_subnetwork.ingress_frontend[0].network, "https://www.googleapis.com/compute/v1/") == trimprefix(local.vpc_self_link, "https://www.googleapis.com/compute/v1/") &&
        basename(data.google_compute_subnetwork.ingress_frontend[0].region) == var.region
      )
      error_message = "The frontend must use a regular subnet in the selected VPC and region."
    }
    precondition {
      condition = !local.existing_proxy_subnet ? true : (
        trimprefix(data.google_compute_subnetwork.ingress_proxy[0].network, "https://www.googleapis.com/compute/v1/") == trimprefix(local.vpc_self_link, "https://www.googleapis.com/compute/v1/") &&
        basename(data.google_compute_subnetwork.ingress_proxy[0].self_link) != basename(local.subnet_self_link)
      )
      error_message = "The existing proxy subnet must be in the selected VPC and distinct from the frontend subnet. Check ACTIVE/REGIONAL_MANAGED_PROXY with gcloud before apply."
    }
  }
}

resource "google_compute_region_network_endpoint_group" "private_ingress" {
  count                 = local.private_ingress_enabled ? 1 : 0
  project               = var.project_id
  name                  = "${var.name_prefix}-private-run"
  region                = var.region
  network_endpoint_type = "SERVERLESS"
  cloud_run {
    service = google_cloud_run_v2_service.opsrabbit[0].name
  }
}

resource "google_compute_region_security_policy" "private_ingress" {
  count   = local.private_ingress_enabled ? 1 : 0
  project = var.project_id
  name    = "${var.name_prefix}-private-clients"
  region  = var.region
  type    = "CLOUD_ARMOR"

  rules {
    priority = 1000
    action   = "allow"
    match {
      versioned_expr = "SRC_IPS_V1"
      config { src_ip_ranges = var.private_ingress.allowed_source_cidrs }
    }
  }
  rules {
    priority = 2147483647
    action   = "deny(403)"
    match {
      versioned_expr = "SRC_IPS_V1"
      config { src_ip_ranges = ["*"] }
    }
  }
}

resource "google_compute_region_backend_service" "private_ingress" {
  provider              = google-beta
  count                 = local.private_ingress_enabled ? 1 : 0
  project               = var.project_id
  name                  = "${var.name_prefix}-private-backend"
  region                = var.region
  load_balancing_scheme = "INTERNAL_MANAGED"
  protocol              = "HTTP"
  security_policy       = google_compute_region_security_policy.private_ingress[0].self_link
  backend {
    group = google_compute_region_network_endpoint_group.private_ingress[0].id
  }
  log_config {
    enable      = true
    sample_rate = 1
  }
  # Serverless NEGs do not use Compute health checks or configurable timeouts.
}

resource "google_compute_region_url_map" "private_ingress" {
  count           = local.private_ingress_enabled ? 1 : 0
  project         = var.project_id
  name            = "${var.name_prefix}-private"
  region          = var.region
  default_service = google_compute_region_backend_service.private_ingress[0].id
}

resource "google_compute_region_ssl_policy" "private_ingress" {
  count           = local.private_ingress_enabled ? 1 : 0
  project         = var.project_id
  name            = "${var.name_prefix}-private-tls"
  region          = var.region
  min_tls_version = "TLS_1_2"
  profile         = "MODERN"
}

resource "google_compute_region_target_https_proxy" "private_ingress" {
  count            = local.private_ingress_enabled ? 1 : 0
  project          = var.project_id
  name             = "${var.name_prefix}-private-https"
  region           = var.region
  url_map          = google_compute_region_url_map.private_ingress[0].id
  ssl_certificates = var.private_ingress.ssl_certificate_self_links
  ssl_policy       = google_compute_region_ssl_policy.private_ingress[0].id
}

resource "google_compute_forwarding_rule" "private_ingress" {
  count                 = local.private_ingress_enabled ? 1 : 0
  project               = var.project_id
  name                  = "${var.name_prefix}-private-https"
  region                = var.region
  ip_address            = google_compute_address.private_ingress[0].address
  ip_protocol           = "TCP"
  port_range            = "443"
  load_balancing_scheme = "INTERNAL_MANAGED"
  network               = local.vpc_self_link
  subnetwork            = local.subnet_self_link
  target                = google_compute_region_target_https_proxy.private_ingress[0].id
  allow_global_access   = var.private_ingress.allow_global_access
  depends_on            = [google_compute_subnetwork.ingress_proxy, data.google_compute_subnetwork.ingress_proxy]
}
