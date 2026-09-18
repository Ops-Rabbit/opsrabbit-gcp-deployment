# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------
# Filestore is inherently VPC-only (it has no public-IP mode), so a VPC is
# required regardless of network_mode. Cloud Run reaches it via Direct VPC
# egress -- no VPC Connector, no NAT needed for the default egress setting
# (only RFC1918-range traffic is routed through the VPC; everything else,
# like pulling from Artifact Registry, still goes out normally).

resource "google_compute_network" "opsrabbit" {
  count = var.create_vpc ? 1 : 0

  project                 = var.project_id
  name                    = "${var.name_prefix}-vpc"
  auto_create_subnetworks = false

  depends_on = [google_project_service.required["compute.googleapis.com"]]
}

resource "google_compute_subnetwork" "opsrabbit" {
  count = var.create_vpc ? 1 : 0

  project                  = var.project_id
  name                     = "${var.name_prefix}-subnet"
  region                   = var.region
  network                  = google_compute_network.opsrabbit[0].id
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

locals {
  vpc_self_link = var.create_vpc ? google_compute_network.opsrabbit[0].id : var.existing_network_self_link

  # google_filestore_instance needs the network's short NAME, not a full
  # self-link. When create_vpc=true, the created resource's .name attribute
  # already is that. When false, the existing self-link (e.g.
  # "projects/P/global/networks/my-vpc") has to be parsed to pull out
  # just "my-vpc" -- falling back to null here (as this used to) breaks
  # Filestore provisioning any time create_vpc = false, since networks.network
  # is a required, non-nullable argument.
  vpc_name = var.create_vpc ? google_compute_network.opsrabbit[0].name : (
    var.existing_network_self_link != null
    ? element(split("/", var.existing_network_self_link), length(split("/", var.existing_network_self_link)) - 1)
    : null
  )

  subnet_self_link = var.create_vpc ? google_compute_subnetwork.opsrabbit[0].id : var.existing_subnet_self_link
}

# ---------------------------------------------------------------------------
# Private services access -- used by both Filestore and Cloud SQL.
# ---------------------------------------------------------------------------

resource "google_compute_global_address" "private_services_range" {
  name          = "${var.name_prefix}-psa-range"
  project       = var.project_id
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 20
  network       = local.vpc_self_link

  depends_on = [google_project_service.required["compute.googleapis.com"]]
}

resource "google_service_networking_connection" "private_services" {
  network                 = local.vpc_self_link
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_services_range.name]

  depends_on = [google_project_service.required]
}
