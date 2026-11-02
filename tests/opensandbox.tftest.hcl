mock_provider "google-beta" {}
mock_provider "google" {
  mock_resource "google_service_account" {
    override_during = plan
    defaults        = { email = "opsrabbit-node@test-project.iam.gserviceaccount.com", name = "projects/test-project/serviceAccounts/opsrabbit-node@test-project.iam.gserviceaccount.com" }
  }
  mock_resource "google_container_cluster" {
    override_during = plan
    defaults        = { endpoint = "203.0.113.10" }
  }
}
mock_provider "helm" {}
variables {
  project_id                        = "test-project"
  application_enabled               = false
  application_origin                = "https://opsrabbit.example.com"
  postgresql_administrator_password = "test-password"
  better_auth_secret                = "test-secret"
  opsrabbit_encryption_key          = "test-key"
  backend_uid                       = 1000
  backend_gid                       = 1000
  backend_image                     = "us-central1-docker.pkg.dev/test-project/opsrabbit/backend@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  web_image                         = "us-central1-docker.pkg.dev/test-project/opsrabbit/web@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  opensandbox_images = {
    controller = "us-central1-docker.pkg.dev/test-project/opsrabbit/controller@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    server     = "us-central1-docker.pkg.dev/test-project/opsrabbit/server@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    gateway    = "us-central1-docker.pkg.dev/test-project/opsrabbit/gateway@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    execd      = "us-central1-docker.pkg.dev/test-project/opsrabbit/execd@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    egress     = "us-central1-docker.pkg.dev/test-project/opsrabbit/egress@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    sandbox    = "us-central1-docker.pkg.dev/test-project/opsrabbit/sandbox@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  }
}
run "disabled_installs_nothing" {
  command = plan
  assert {
    condition     = length(helm_release.opensandbox_base) == 0 && length(terraform_data.opensandbox_bootstrap) == 0
    error_message = "OpenSandbox must remain opt-in."
  }
}
run "standard_private_services_and_activation" {
  command = plan
  variables {
    deployment_mode                = "standard"
    opensandbox_enabled            = true
    opensandbox_workload_namespace = "sandbox-work"
  }
  assert {
    condition     = length(helm_release.opensandbox_base) == 1 && length(helm_release.opensandbox_controller) == 1 && length(helm_release.opensandbox_gateway) == 1 && length(helm_release.opensandbox_server) == 1 && length(terraform_data.opensandbox_bootstrap) == 1
    error_message = "All prerequisites and product bootstrap must be selected."
  }
  assert {
    condition = alltrue([
      for component in [
        yamldecode(helm_release.opensandbox_controller[0].values[0]).controller,
        yamldecode(helm_release.opensandbox_gateway[0].values[0]).gateway,
        yamldecode(helm_release.opensandbox_server[0].values[0]).server
      ] : component.podSecurityContext.runAsNonRoot && component.podSecurityContext.runAsUser > 10000 && component.podSecurityContext.seccompProfile.type == "RuntimeDefault" && component.containerSecurityContext.readOnlyRootFilesystem && !component.containerSecurityContext.allowPrivilegeEscalation && contains(component.containerSecurityContext.capabilities.drop, "ALL")
    ])
    error_message = "Control-plane components must not run as root, elevate privileges or write their image filesystem."
  }
  assert {
    condition     = yamldecode(helm_release.opensandbox_server[0].values[0]).server.service.type == "ClusterIP" && yamldecode(helm_release.opensandbox_gateway[0].values[0]).gateway.service.type == "ClusterIP"
    error_message = "Sandbox services must not have public endpoints."
  }
  assert {
    condition     = yamldecode(helm_release.opensandbox_server[0].values[0]).fullnameOverride == "opensandbox-server" && yamldecode(helm_release.opensandbox_gateway[0].values[0]).fullnameOverride == "opensandbox-ingress-gateway"
    error_message = "Service names must match bootstrap and gateway routing."
  }
  assert {
    condition     = strcontains(yamldecode(helm_release.opensandbox_server[0].values[0]).configToml, "namespace = \"sandbox-work\"") && yamldecode(helm_release.opensandbox_gateway[0].values[0]).gateway.dataplaneNamespace == "sandbox-work"
    error_message = "Workload namespace must be configurable."
  }
  assert {
    condition     = terraform_data.opensandbox_bootstrap[0].triggers_replace == null
    error_message = "Routine infrastructure updates must not repeat activation after an administrator reset."
  }
  assert {
    condition     = google_container_cluster.opsrabbit[0].ip_allocation_policy[0].stack_type == "IPV4" && strcontains(yamldecode(helm_release.opensandbox_server[0].values[0]).configToml, "isolation_profile = \"unprivileged\"") && strcontains(yamldecode(helm_release.opensandbox_server[0].values[0]).configToml, "disable_ipv6 = false")
    error_message = "The unprivileged profile requires IPv4-only networking without a privileged IPv6 init container."
  }

}
run "autopilot_private_services_and_activation" {
  command = plan
  variables {
    deployment_mode                = "autopilot"
    opensandbox_enabled            = true
    opensandbox_workload_namespace = "sandbox-work"
  }
  assert {
    condition     = length(helm_release.opensandbox_base) == 1 && length(helm_release.opensandbox_controller) == 1 && length(helm_release.opensandbox_gateway) == 1 && length(helm_release.opensandbox_server) == 1 && length(terraform_data.opensandbox_bootstrap) == 1
    error_message = "All prerequisites and product bootstrap must be selected."
  }
  assert {
    condition     = yamldecode(helm_release.opensandbox_server[0].values[0]).server.service.type == "ClusterIP" && yamldecode(helm_release.opensandbox_gateway[0].values[0]).gateway.service.type == "ClusterIP"
    error_message = "Sandbox services must not have public endpoints."
  }
  assert {
    condition     = yamldecode(helm_release.opensandbox_server[0].values[0]).fullnameOverride == "opensandbox-server" && yamldecode(helm_release.opensandbox_gateway[0].values[0]).fullnameOverride == "opensandbox-ingress-gateway"
    error_message = "Service names must match bootstrap and gateway routing."
  }
  assert {
    condition     = strcontains(yamldecode(helm_release.opensandbox_server[0].values[0]).configToml, "namespace = \"sandbox-work\"") && yamldecode(helm_release.opensandbox_gateway[0].values[0]).gateway.dataplaneNamespace == "sandbox-work"
    error_message = "Workload namespace must be configurable."
  }
  assert {
    condition     = google_container_cluster.autopilot[0].allow_net_admin
    error_message = "Autopilot must admit the egress NET_ADMIN sidecar."
  }
  assert {
    condition     = google_container_cluster.autopilot[0].ip_allocation_policy[0].stack_type == "IPV4" && strcontains(yamldecode(helm_release.opensandbox_server[0].values[0]).configToml, "isolation_profile = \"unprivileged\"") && strcontains(yamldecode(helm_release.opensandbox_server[0].values[0]).configToml, "disable_ipv6 = false")
    error_message = "Autopilot must retain workspace-only enforcement without requesting forbidden privileges."
  }
}
run "reject_cloud_run" {
  command = plan
  variables {
    opensandbox_enabled = true
  }
  expect_failures = [var.opensandbox_enabled]
}
run "reject_incomplete_images" {
  command = plan
  variables {
    deployment_mode     = "standard"
    opensandbox_enabled = true
    opensandbox_images  = {}
  }
  expect_failures = [var.opensandbox_images]
}
run "reject_tag_plus_digest" {
  command = plan
  variables {
    deployment_mode     = "standard"
    opensandbox_enabled = true
    opensandbox_images = {
      controller = "us-central1-docker.pkg.dev/test-project/opsrabbit/controller:release-1.1.1@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
      server     = "us-central1-docker.pkg.dev/test-project/opsrabbit/server@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
      gateway    = "us-central1-docker.pkg.dev/test-project/opsrabbit/gateway@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
      execd      = "us-central1-docker.pkg.dev/test-project/opsrabbit/execd@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
      egress     = "us-central1-docker.pkg.dev/test-project/opsrabbit/egress@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
      sandbox    = "us-central1-docker.pkg.dev/test-project/opsrabbit/sandbox@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    }
  }
  expect_failures = [var.opensandbox_images]
}
