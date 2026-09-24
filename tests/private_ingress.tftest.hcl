# Offline only: no credentials, real API calls or VPN required.
mock_provider "google" {
  mock_resource "google_compute_network" {
    override_during = plan
    defaults        = { id = "projects/test-project/global/networks/opsrabbit-vpc" }
  }
  mock_data "google_compute_subnetwork" {
    defaults = {
      network = "https://www.googleapis.com/compute/v1/projects/test-project/global/networks/opsrabbit-vpc"
      region  = "https://www.googleapis.com/compute/v1/projects/test-project/regions/us-central1"
    }
  }
  mock_resource "google_compute_region_security_policy" {
    override_during = plan
    defaults        = { self_link = "projects/test-project/regions/us-central1/securityPolicies/private-clients" }
  }
}
mock_provider "google-beta" {}

variables {
  application_enabled               = true
  application_origin                = "https://opsrabbit.example.com"
  project_id                        = "test-project"
  backend_image                     = "us-central1-docker.pkg.dev/test-project/opsrabbit/backend@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  web_image                         = "us-central1-docker.pkg.dev/test-project/opsrabbit/web@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  postgresql_administrator_password = "test-password"
  better_auth_secret                = "test-secret"
  opsrabbit_encryption_key          = "test-key"
  backend_uid                       = 1000
  backend_gid                       = 1000
}


run "private_ingress_blocks_bypass_and_restricts_clients" {
  command = plan
  variables {
    network_mode = "private"
    private_ingress = {
      allowed_source_cidrs       = ["10.80.0.0/24"]
      ssl_certificate_self_links = ["projects/test-project/regions/us-central1/sslCertificates/customer-tls"]
      proxy_subnet_cidr          = "10.20.0.0/23"
    }
  }
  assert {
    condition     = google_cloud_run_v2_service.opsrabbit[0].ingress == "INGRESS_TRAFFIC_INTERNAL_ONLY" && google_cloud_run_v2_service.opsrabbit[0].default_uri_disabled && google_cloud_run_v2_service.opsrabbit[0].invoker_iam_disabled
    error_message = "Private mode must block internet and direct run.app access while allowing application-authenticated requests through the ILB."
  }
  assert {
    condition     = length(google_cloud_run_v2_service_iam_member.public) == 0 && google_compute_forwarding_rule.private_ingress[0].port_range == "443" && google_compute_forwarding_rule.private_ingress[0].load_balancing_scheme == "INTERNAL_MANAGED"
    error_message = "Private mode must expose only an internal HTTPS frontend with no public invoker binding."
  }
  assert {
    condition     = length([for rule in google_compute_region_security_policy.private_ingress[0].rules : rule if rule.action == "deny(403)" && rule.priority == 2147483647]) == 1 && length([for rule in google_compute_region_security_policy.private_ingress[0].rules : rule if rule.action == "allow" && contains(rule.match[0].config[0].src_ip_ranges, "10.80.0.0/24")]) == 1
    error_message = "Only approved sources may pass Cloud Armor; all other sources must be denied."
  }
  assert {
    condition     = google_compute_region_backend_service.private_ingress[0].security_policy == google_compute_region_security_policy.private_ingress[0].self_link
    error_message = "The allowlist must be attached to the actual load balancer backend."
  }
  assert {
    condition     = output.opsrabbit_url == var.application_origin && google_compute_subnetwork.ingress_proxy[0].purpose == "REGIONAL_MANAGED_PROXY"
    error_message = "Private users need the private origin and a dedicated proxy subnet."
  }
}
run "private_requires_inputs" {
  command = plan
  variables { network_mode = "private" }
  expect_failures = [var.private_ingress]
}
run "rejects_unrestricted_sources" {
  command = plan
  variables {
    private_ingress = {
      allowed_source_cidrs       = ["0.0.0.0/0"]
      ssl_certificate_self_links = ["projects/test-project/regions/us-central1/sslCertificates/customer-tls"]
      proxy_subnet_cidr          = "10.20.0.0/23"
    }
  }
  expect_failures = [var.private_ingress]
}
run "rejects_wrong_certificate_region" {
  command = plan
  variables {
    private_ingress = {
      allowed_source_cidrs       = ["10.80.0.0/24"]
      ssl_certificate_self_links = ["projects/test-project/regions/europe-west1/sslCertificates/customer-tls"]
      proxy_subnet_cidr          = "10.20.0.0/23"
    }
  }
  expect_failures = [var.private_ingress]
}
run "public_behavior_unchanged" {
  command = plan
  assert {
    condition     = length(google_compute_forwarding_rule.private_ingress) == 0 && length(google_compute_region_security_policy.private_ingress) == 0 && length(google_cloud_run_v2_service_iam_member.public) == 1 && !google_cloud_run_v2_service.opsrabbit[0].default_uri_disabled && !google_cloud_run_v2_service.opsrabbit[0].invoker_iam_disabled
    error_message = "Public deployments must preserve their existing ingress and IAM behavior without creating private infrastructure."
  }
}

run "rejects_empty_sources" {
  command = plan
  variables {
    private_ingress = {
      allowed_source_cidrs       = []
      ssl_certificate_self_links = ["projects/test-project/regions/us-central1/sslCertificates/tls"]
      proxy_subnet_cidr          = "10.20.0.0/23"
    }
  }
  expect_failures = [var.private_ingress]
}

run "rejects_invalid_sources" {
  command = plan
  variables {
    private_ingress = {
      allowed_source_cidrs       = ["not-a-cidr"]
      ssl_certificate_self_links = ["projects/test-project/regions/us-central1/sslCertificates/tls"]
      proxy_subnet_cidr          = "10.20.0.0/23"
    }
  }
  expect_failures = [var.private_ingress]
}

run "rejects_small_proxy_subnet" {
  command = plan
  variables {
    private_ingress = {
      allowed_source_cidrs       = ["10.80.0.0/24"]
      ssl_certificate_self_links = ["projects/test-project/regions/us-central1/sslCertificates/tls"]
      proxy_subnet_cidr          = "10.20.0.0/28"
    }
  }
  expect_failures = [var.private_ingress]
}

run "rejects_missing_proxy_subnet" {
  command = plan
  variables {
    private_ingress = {
      allowed_source_cidrs       = ["10.80.0.0/24"]
      ssl_certificate_self_links = ["projects/test-project/regions/us-central1/sslCertificates/tls"]
    }
  }
  expect_failures = [var.private_ingress]
}

run "private_bootstrap_has_no_load_balancer" {
  command = plan
  variables {
    application_enabled = false
    network_mode        = "private"
    private_ingress = {
      allowed_source_cidrs       = ["10.80.0.0/24"]
      ssl_certificate_self_links = ["projects/test-project/regions/us-central1/sslCertificates/tls"]
      proxy_subnet_cidr          = "10.20.0.0/23"
    }
  }
  assert {
    condition     = length(google_compute_forwarding_rule.private_ingress) == 0 && length(google_cloud_run_v2_service.opsrabbit) == 0
    error_message = "Bootstrap must not expose or create the application frontend."
  }
}
run "existing_proxy_is_reused" {
  command = plan
  variables {
    network_mode               = "private"
    create_vpc                 = false
    existing_network_self_link = "projects/test-project/global/networks/opsrabbit-vpc"
    existing_subnet_self_link  = "projects/test-project/regions/us-central1/subnetworks/apps"
    private_ingress = {
      allowed_source_cidrs            = ["10.80.0.0/24"]
      ssl_certificate_self_links      = ["projects/test-project/regions/us-central1/sslCertificates/tls"]
      existing_proxy_subnet_self_link = "projects/test-project/regions/us-central1/subnetworks/proxies"
    }
  }
  override_data {
    target = data.google_compute_subnetwork.ingress_proxy[0]
    values = {
      network   = "projects/test-project/global/networks/opsrabbit-vpc"
      self_link = "projects/test-project/regions/us-central1/subnetworks/proxies"
    }
  }
  assert {
    condition     = length(google_compute_subnetwork.ingress_proxy) == 0 && length(google_compute_network.opsrabbit) == 0 && length(google_compute_subnetwork.opsrabbit) == 0 && length(google_compute_forwarding_rule.private_ingress) == 1
    error_message = "An existing proxy subnet must not be recreated or taken into Terraform ownership."
  }
}

run "rejects_disabled_run_app_origin" {
  command = plan
  variables {
    network_mode       = "private"
    application_origin = "https://example.us-central1.run.app"
    private_ingress = {
      allowed_source_cidrs       = ["10.80.0.0/24"]
      ssl_certificate_self_links = ["projects/test-project/regions/us-central1/sslCertificates/tls"]
      proxy_subnet_cidr          = "10.20.0.0/23"
    }
  }
  expect_failures = [var.private_ingress]
}
run "rejects_cross_project_frontend" {
  command = plan
  variables {
    network_mode               = "private"
    create_vpc                 = false
    existing_network_self_link = "projects/test-project/global/networks/opsrabbit-vpc"
    existing_subnet_self_link  = "projects/other-project/regions/us-central1/subnetworks/apps"
    private_ingress = {
      allowed_source_cidrs       = ["10.80.0.0/24"]
      ssl_certificate_self_links = ["projects/test-project/regions/us-central1/sslCertificates/tls"]
      proxy_subnet_cidr          = "10.20.0.0/23"
    }
  }
  expect_failures = [var.private_ingress]
}

run "rejects_invalid_private_hostname" {
  command = plan
  variables {
    network_mode       = "private"
    application_origin = "https://opsrabbit..example.com"
    private_ingress = {
      allowed_source_cidrs       = ["10.80.0.0/24"]
      ssl_certificate_self_links = ["projects/test-project/regions/us-central1/sslCertificates/tls"]
      proxy_subnet_cidr          = "10.20.0.0/23"
    }
  }
  expect_failures = [var.private_ingress]
}
run "rejects_proxy_default_route" {
  command = plan
  variables {
    private_ingress = {
      allowed_source_cidrs       = ["10.80.0.0/24"]
      ssl_certificate_self_links = ["projects/test-project/regions/us-central1/sslCertificates/tls"]
      proxy_subnet_cidr          = "0.0.0.0/0"
    }
  }
  expect_failures = [var.private_ingress]
}
