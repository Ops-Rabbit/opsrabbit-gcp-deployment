mock_provider "google-beta" {}

# Structural tests: given a set of inputs, does the plan produce the
# resources it should? These catch logic bugs -- like the create_vpc=false
# null-subnetwork bug fixed in cloud-run.tf -- that fmt/validate/tflint
# don't check, because they never evaluate conditional expressions.

mock_provider "google" {}

variables {
  application_enabled               = false
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

run "bootstrap_creates_no_cloud_run_service" {
  command = plan

  variables {
    application_enabled = false
  }

  assert {
    condition     = length(google_cloud_run_v2_service.opsrabbit) == 0
    error_message = "Cloud Run service must not exist while application_enabled is false -- this is what makes the staged bootstrap-then-deploy flow safe"
  }
}

run "deploy_creates_cloud_run_service" {
  command = plan

  variables {
    application_enabled = true
  }

  assert {
    condition     = length(google_cloud_run_v2_service.opsrabbit) == 1
    error_message = "Cloud Run service must exist when application_enabled is true"
  }
}

run "create_vpc_true_provisions_dedicated_network" {
  command = plan

  variables {
    create_vpc = true
  }

  assert {
    condition     = length(google_compute_network.opsrabbit) == 1
    error_message = "A dedicated VPC should be created when create_vpc is true"
  }
}

run "create_vpc_false_creates_no_new_network" {
  command = plan

  variables {
    create_vpc                 = false
    existing_network_self_link = "projects/test-project/global/networks/existing-vpc"
    existing_subnet_self_link  = "projects/test-project/regions/us-central1/subnetworks/existing-subnet"
  }

  assert {
    condition     = length(google_compute_network.opsrabbit) == 0
    error_message = "No new VPC should be created when create_vpc is false -- an existing one should be referenced instead"
  }

  # Regression test: local.vpc_name used to fall back to null when
  # create_vpc = false, which broke Filestore provisioning (a required,
  # non-nullable argument) any time an existing VPC was used.
  assert {
    condition     = local.vpc_name == "existing-vpc"
    error_message = "vpc_name must resolve to the short network name parsed from existing_network_self_link, never null, when create_vpc is false"
  }
}

# Regression test for the bug fixed in this session: Cloud Run's
# vpc_access.network_interfaces.subnetwork used to fall back to `null`
# when create_vpc = false instead of using the existing subnet.
run "cloud_run_subnetwork_is_never_null_when_using_existing_vpc" {
  command = plan

  variables {
    application_enabled        = true
    create_vpc                 = false
    existing_network_self_link = "projects/test-project/global/networks/existing-vpc"
    existing_subnet_self_link  = "projects/test-project/regions/us-central1/subnetworks/existing-subnet"
  }

  assert {
    condition     = google_cloud_run_v2_service.opsrabbit[0].template[0].vpc_access[0].network_interfaces[0].subnetwork == "projects/test-project/regions/us-central1/subnetworks/existing-subnet"
    error_message = "Cloud Run subnetwork must resolve to the existing subnet, never null, when create_vpc is false"
  }
}

run "public_mode_creates_unauthenticated_invoker_binding" {
  command = plan

  variables {
    application_enabled   = true
    network_mode          = "public"
    allow_unauthenticated = true
  }

  assert {
    condition     = length(google_cloud_run_v2_service_iam_member.public) == 1
    error_message = "Public invoker binding should exist when network_mode=public and allow_unauthenticated=true"
  }
}
