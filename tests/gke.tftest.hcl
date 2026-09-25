mock_provider "google-beta" {}
mock_provider "google" {}
mock_provider "helm" {}

variables {
  application_enabled               = false
  project_id                        = "test-project"
  backend_image                     = "us-central1-docker.pkg.dev/test-project/opsrabbit/backend@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  web_image                         = "us-central1-docker.pkg.dev/test-project/opsrabbit/web@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  postgresql_administrator_password = "test-password"
  better_auth_secret                = "test-secret"
  opsrabbit_encryption_key          = "test-key"
  backend_uid                       = 1000
  backend_gid                       = 1000
}

run "gke_is_disabled_by_default" {
  command = plan

  assert {
    condition     = length(google_container_cluster.opsrabbit) == 0 && length(google_container_cluster.autopilot) == 0 && length(helm_release.opsrabbit) == 0
    error_message = "GKE and Helm must remain disabled unless a GKE deployment mode is selected."
  }
}

run "standard_creates_cluster_and_node_pool" {
  command = plan

  variables {
    gke_deployment_mode = "standard"
  }

  assert {
    condition     = length(google_container_cluster.opsrabbit) == 1 && length(google_container_node_pool.opsrabbit) == 1
    error_message = "Standard mode must create a non-Autopilot cluster and managed node pool."
  }

  assert {
    condition     = length(helm_release.opsrabbit) == 1 && helm_release.opsrabbit[0].namespace == "opsrabbit"
    error_message = "Standard mode must install the OpsRabbit Helm release into the configured namespace."
  }

  assert {
    condition     = endswith(helm_release.opsrabbit[0].chart, "/charts/opsrabbit")
    error_message = "GKE must use the bundled OpsRabbit chart by default."
  }
}

run "autopilot_does_not_create_node_pool" {
  command = plan

  variables {
    gke_deployment_mode = "autopilot"
  }

  assert {
    condition     = length(google_container_cluster.autopilot) == 1 && length(google_container_node_pool.opsrabbit) == 0
    error_message = "Autopilot mode must let GKE manage nodes instead of creating a node pool."
  }
}

run "shared_requires_explicit_cluster_identity" {
  command = plan

  variables {
    gke_deployment_mode = "shared"
  }

  expect_failures = [var.gke_cluster_name, var.gke_cluster_location]
}

run "rejects_unpinned_external_gke_chart" {
  command = plan

  variables {
    gke_deployment_mode = "standard"
    gke_helm_repository = "https://charts.example.com"
  }

  expect_failures = [var.gke_helm_chart_version]
}

run "accepts_shared_cluster_database_host_override" {
  command = plan

  variables {
    gke_deployment_mode    = "standard"
    gke_helm_repository    = "https://charts.example.com"
    gke_helm_chart_version = "1.2.3"
    gke_postgresql_host    = "postgres.internal.example.com"
  }

  assert {
    condition     = local.gke_postgresql_host == "postgres.internal.example.com"
    error_message = "GKE deployments must support a customer-provided database host for shared network topologies."
  }
}
