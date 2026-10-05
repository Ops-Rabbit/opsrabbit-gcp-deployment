mock_provider "google-beta" {}
mock_provider "google" {
  mock_data "google_dns_managed_zone" {
    override_during = plan
    defaults        = { visibility = "public", dns_name = "example.com." }
  }
  mock_data "google_container_cluster" {
    override_during = plan
    defaults = {
      network                  = "customer-vpc"
      workload_identity_config = [{ workload_pool = "test-project.svc.id.goog" }]
      ip_allocation_policy     = [{ cluster_ipv4_cidr_block = "10.20.0.0/16" }]
      addons_config            = [{ http_load_balancing = [{ disabled = false }] }]
    }
  }
  mock_resource "google_compute_managed_ssl_certificate" {
    override_during = plan
    defaults        = { self_link = "projects/test-project/global/sslCertificates/opsrabbit-application" }
  }
}
mock_provider "helm" {}

variables {
  application_enabled               = true
  application_origin                = "https://opsrabbit.example.com"
  project_id                        = "test-project"
  backend_image                     = "us-central1-docker.pkg.dev/test-project/opsrabbit/backend@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  web_image                         = "us-central1-docker.pkg.dev/test-project/opsrabbit/web@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  postgresql_administrator_password = "test-password"
  better_auth_secret                = "test-secret"
  opsrabbit_encryption_key          = "test-key"
  backend_uid                       = 10001
  backend_gid                       = 10001
}

run "cloud_run_custom_domain_is_complete" {
  command = plan
  assert {
    condition = (
      length(google_compute_global_address.application) == 1 &&
      length(google_compute_managed_ssl_certificate.application) == 1 &&
      google_compute_managed_ssl_certificate.application[0].managed[0].domains == tolist(["opsrabbit.example.com"]) &&
      length(google_compute_global_forwarding_rule.application_https) == 1 &&
      google_compute_global_forwarding_rule.application_https[0].port_range == "443" &&
      google_compute_url_map.application_redirect[0].default_url_redirect[0].https_redirect &&
      google_compute_ssl_policy.application[0].min_tls_version == "TLS_1_2"
    )
    error_message = "The installer must provision a stable HTTPS endpoint, certificate, TLS policy and HTTP redirect."
  }
  assert {
    condition = (
      google_cloud_run_v2_service.opsrabbit[0].default_uri_disabled &&
      google_cloud_run_v2_service.opsrabbit[0].ingress == "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER" &&
      output.opsrabbit_url == var.application_origin
    )
    error_message = "The application origin must match the output, and direct Cloud Run ingress must not bypass the load balancer."
  }
}

run "native_cloud_run_needs_no_load_balancer" {
  command = plan
  variables {
    application_origin = "https://opsrabbit-app-123456.us-central1.run.app"
  }
  assert {
    condition     = length(google_compute_global_address.application) == 0 && !google_cloud_run_v2_service.opsrabbit[0].default_uri_disabled && output.opsrabbit_url == var.application_origin
    error_message = "Native Cloud Run HTTPS must remain available without a custom-domain load balancer."
  }
}

run "standard_uses_ingress_without_cloud_run" {
  command = plan
  variables {
    deployment_mode = "standard"
  }
  assert {
    condition = (
      length(google_compute_global_address.application) == 1 &&
      length(google_compute_global_forwarding_rule.application_https) == 0 &&
      length(google_cloud_run_v2_service.opsrabbit) == 0 &&
      yamldecode(helm_release.opsrabbit[0].values[1]).gkeEndpoint.enabled &&
      yamldecode(helm_release.opsrabbit[0].values[1]).service.type == "ClusterIP" &&
      yamldecode(helm_release.opsrabbit[0].values[1]).backend.env.OPSRABBIT_WEB_ORIGIN == var.application_origin &&
      yamldecode(helm_release.opsrabbit[0].values[1]).backend.env.OPSRABBIT_NODE_BASE_URL == "${var.application_origin}/api" &&
      output.opsrabbit_url == var.application_origin
    )
    error_message = "GKE must provision the endpoint through Ingress, retain private Services, and configure the same login origin."
  }
}

run "autopilot_has_same_endpoint_contract" {
  command = plan
  variables {
    deployment_mode = "autopilot"
  }
  assert {
    condition     = length(google_compute_global_address.application) == 1 && yamldecode(helm_release.opsrabbit[0].values[1]).ingress.enabled && output.opsrabbit_url == var.application_origin
    error_message = "Autopilot must expose the same application endpoint as Standard."
  }
}

run "gke_migration_detaches_ingress_before_reusing_static_ip" {
  command = plan
  variables {
    deployment_mode                   = "autopilot"
    gke_endpoint_detach_for_migration = true
  }
  assert {
    condition = (
      length(google_compute_global_address.application) == 1 &&
      length(google_compute_global_forwarding_rule.application_https) == 0 &&
      !yamldecode(helm_release.opsrabbit[0].values[1]).ingress.enabled &&
      !yamldecode(helm_release.opsrabbit[0].values[1]).gkeEndpoint.enabled
    )
    error_message = "The preparatory migration apply must remove GKE Ingress while retaining the reserved address."
  }
}

run "shared_installs_endpoint_without_owning_cluster" {
  command = plan
  variables {
    deployment_mode            = "shared"
    gke_cluster_name           = "customer-cluster"
    gke_cluster_location       = "us-central1"
    create_vpc                 = false
    existing_network_self_link = "projects/test-project/global/networks/customer-vpc"
    existing_subnet_self_link  = "projects/test-project/regions/us-central1/subnetworks/customer-subnet"
  }
  assert {
    condition = (
      length(google_container_cluster.opsrabbit) == 0 &&
      length(google_container_cluster.autopilot) == 0 &&
      length(google_container_node_pool.opsrabbit) == 0 &&
      length(google_compute_global_address.application) == 1 &&
      yamldecode(helm_release.opsrabbit[0].values[1]).gkeEndpoint.enabled &&
      output.opsrabbit_url == var.application_origin
    )
    error_message = "Shared mode must install the application endpoint without creating a cluster or node pool."
  }
}

run "shared_rejects_disconnected_database_network" {
  command = plan
  variables {
    deployment_mode      = "shared"
    gke_cluster_name     = "customer-cluster"
    gke_cluster_location = "us-central1"
  }
  expect_failures = [data.google_container_cluster.shared]
}

run "shared_rejects_same_network_name_in_another_project" {
  command = plan
  variables {
    deployment_mode            = "shared"
    gke_cluster_name           = "customer-cluster"
    gke_cluster_location       = "us-central1"
    create_vpc                 = false
    existing_network_self_link = "projects/wrong-host/global/networks/customer-vpc"
    existing_subnet_self_link  = "projects/wrong-host/regions/us-central1/subnetworks/customer-subnet"
  }
  expect_failures = [data.google_container_cluster.shared]
}

run "customer_dns_and_certificate_are_supported" {
  command = plan
  variables {
    endpoint_dns_managed_zone           = "customer-zone"
    endpoint_ssl_certificate_self_links = ["projects/test-project/global/sslCertificates/customer-cert"]
  }
  assert {
    condition = (
      length(google_compute_managed_ssl_certificate.application) == 0 &&
      google_compute_target_https_proxy.application[0].ssl_certificates == tolist(var.endpoint_ssl_certificate_self_links) &&
      google_dns_record_set.application[0].name == "opsrabbit.example.com." &&
      google_dns_record_set.application[0].managed_zone == "customer-zone"
    )
    error_message = "Existing certificates and customer Cloud DNS zones must be supported."
  }
}

run "rejects_wrong_dns_zone" {
  command = plan
  variables {
    endpoint_dns_managed_zone = "wrong-zone"
  }
  override_data {
    override_during = plan
    target          = data.google_dns_managed_zone.application[0]
    values          = { visibility = "public", dns_name = "other.example." }
  }
  expect_failures = [data.google_dns_managed_zone.application]
}

run "rejects_private_dns_for_public_certificate" {
  command = plan
  variables {
    endpoint_dns_managed_zone = "private-zone"
  }
  override_data {
    override_during = plan
    target          = data.google_dns_managed_zone.application[0]
    values          = { visibility = "private", dns_name = "example.com." }
  }
  expect_failures = [data.google_dns_managed_zone.application]
}

run "gke_requires_origin" {
  command = plan
  variables {
    deployment_mode    = "standard"
    application_origin = null
  }
  expect_failures = [var.application_origin]
}

run "gke_rejects_mutable_image_even_with_bootstrap_flag" {
  command = plan
  variables {
    deployment_mode     = "autopilot"
    application_enabled = false
    backend_image       = "us-central1-docker.pkg.dev/test-project/opsrabbit/backend:latest"
  }
  expect_failures = [var.backend_image]
}

run "gke_cannot_use_cloud_run_hostname" {
  command = plan
  variables {
    deployment_mode    = "standard"
    application_origin = "https://app.run.app"
  }
  expect_failures = [var.application_origin]
}
