locals {
  gke_cluster_name         = coalesce(var.gke_cluster_name, "${var.name_prefix}-gke")
  gke_cluster_location     = coalesce(var.gke_cluster_location, var.region)
  gke_network              = coalesce(var.gke_network_self_link, local.vpc_self_link)
  gke_subnetwork           = coalesce(var.gke_subnetwork_self_link, local.subnet_self_link)
  gke_helm_chart_source    = var.gke_helm_repository == null ? "${path.module}/charts/opsrabbit" : var.gke_helm_chart
  gke_node_service_account = var.gke_node_service_account != null ? var.gke_node_service_account : try(google_service_account.gke_node[0].email, null)
  gke_ksa_name             = trimsuffix(substr("${local.gke_cluster_name}-${var.gke_namespace}-opsrabbit", 0, 63), "-")
}

resource "google_service_account" "gke_node" {
  count = var.gke_deployment_mode == "standard" && var.gke_node_service_account == null ? 1 : 0

  project      = var.project_id
  account_id   = "${var.name_prefix}-gke-node"
  display_name = "OpsRabbit GKE node image-pull identity"

  depends_on = [google_project_service.required]
}

resource "google_artifact_registry_repository_iam_member" "gke_node_pull" {
  count = var.gke_deployment_mode == "standard" && var.gke_node_service_account == null ? 1 : 0

  location   = google_artifact_registry_repository.opsrabbit.location
  repository = google_artifact_registry_repository.opsrabbit.repository_id
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.gke_node[0].email}"
}

resource "google_service_account_iam_member" "gke_workload_identity" {
  count = local.gke_enabled ? 1 : 0

  service_account_id = google_service_account.run_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.gke_namespace}/${local.gke_ksa_name}]"
}

data "google_container_cluster" "shared" {
  count    = var.gke_deployment_mode == "shared" ? 1 : 0
  project  = var.project_id
  name     = local.gke_cluster_name
  location = local.gke_cluster_location
}

resource "google_container_cluster" "opsrabbit" {
  count = var.gke_deployment_mode == "standard" ? 1 : 0

  project  = var.project_id
  name     = local.gke_cluster_name
  location = local.gke_cluster_location

  network    = local.gke_network
  subnetwork = local.gke_subnetwork

  remove_default_node_pool    = true
  initial_node_count          = 1
  deletion_protection         = true
  enable_shielded_nodes       = true
  enable_intranode_visibility = true

  release_channel {
    channel = "REGULAR"
  }

  ip_allocation_policy {}

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  resource_labels = local.common_labels

  depends_on = [google_project_service.required]
}

resource "google_container_cluster" "autopilot" {
  count = var.gke_deployment_mode == "autopilot" ? 1 : 0

  project  = var.project_id
  name     = local.gke_cluster_name
  location = local.gke_cluster_location

  network    = local.gke_network
  subnetwork = local.gke_subnetwork

  enable_autopilot    = true
  deletion_protection = true

  ip_allocation_policy {}

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  resource_labels = local.common_labels

  depends_on = [google_project_service.required]
}

resource "google_container_node_pool" "opsrabbit" {
  count = var.gke_deployment_mode == "standard" ? 1 : 0

  project  = var.project_id
  name     = "${local.gke_cluster_name}-nodes"
  location = local.gke_cluster_location
  cluster  = google_container_cluster.opsrabbit[0].name

  node_count = var.gke_node_count

  node_config {
    machine_type    = var.gke_node_machine_type
    disk_size_gb    = var.gke_node_disk_size_gb
    disk_type       = "pd-balanced"
    service_account = local.gke_node_service_account
    oauth_scopes = [
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
      "https://www.googleapis.com/auth/monitoring.write",
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/servicecontrol",
      "https://www.googleapis.com/auth/service.management.readonly",
      "https://www.googleapis.com/auth/trace.append",
    ]

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    labels = local.common_labels
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  depends_on = [google_container_cluster.opsrabbit, google_artifact_registry_repository_iam_member.gke_node_pull]
}

resource "helm_release" "opsrabbit" {
  count = local.gke_enabled ? 1 : 0

  name             = "${local.gke_cluster_name}-${var.gke_namespace}"
  namespace        = var.gke_namespace
  create_namespace = true
  repository       = var.gke_helm_repository
  chart            = local.gke_helm_chart_source
  version          = var.gke_helm_repository == null ? null : var.gke_helm_chart_version
  atomic           = true
  cleanup_on_fail  = true
  wait             = true
  timeout          = 900
  values           = [yamlencode(var.gke_helm_values)]

  set {
    name  = "image.backend"
    value = var.backend_image
  }

  set {
    name  = "image.web"
    value = var.web_image
  }

  set {
    name  = "serviceAccount.gkeWorkloadIdentity.projectId"
    value = var.project_id
  }

  set {
    name  = "serviceAccount.gkeWorkloadIdentity.gcpServiceAccount"
    value = google_service_account.run_sa.account_id
  }

  set {
    name  = "podSecurityContext.runAsUser"
    value = tostring(var.backend_uid)
  }

  set {
    name  = "podSecurityContext.runAsGroup"
    value = tostring(var.backend_gid)
  }

  set {
    name  = "podSecurityContext.fsGroup"
    value = tostring(var.backend_gid)
  }

  set_sensitive {
    name  = "secrets.databaseUrl"
    value = local.gke_postgresql_database_url
  }

  set_sensitive {
    name  = "secrets.betterAuthSecret"
    value = var.better_auth_secret
  }

  set_sensitive {
    name  = "secrets.encryptionKey"
    value = var.opsrabbit_encryption_key
  }

  depends_on = [google_container_node_pool.opsrabbit, data.google_container_cluster.shared, google_service_account_iam_member.gke_workload_identity]
}
