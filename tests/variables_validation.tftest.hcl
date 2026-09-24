mock_provider "google-beta" {}

# Tests the variable validation blocks themselves -- confirms bad input
# is actually rejected at plan time, not just that valid input works.
# Fully offline: mock_provider means no real GCP/Postgres calls happen.

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

run "rejects_invalid_network_mode" {
  command = plan

  variables {
    network_mode = "invalid"
  }

  expect_failures = [var.network_mode]
}

run "rejects_invalid_filestore_tier" {
  command = plan

  variables {
    filestore_tier = "PREMIUM"
  }

  expect_failures = [var.filestore_tier]
}

run "rejects_filestore_capacity_below_basic_tier_minimum" {
  command = plan

  variables {
    filestore_capacity_gb = 512
  }

  expect_failures = [var.filestore_capacity_gb]
}

run "accepts_valid_defaults" {
  command = plan
  # No overrides -- confirms the documented defaults actually plan clean.
}

run "rejects_single_request_slot" {
  command = plan
  variables { cloud_run_concurrency = 1 }
  expect_failures = [var.cloud_run_concurrency]
}

run "rejects_fractional_concurrency" {
  command = plan
  variables { cloud_run_concurrency = 2.5 }
  expect_failures = [var.cloud_run_concurrency]
}

run "rejects_excessive_concurrency" {
  command = plan
  variables { cloud_run_concurrency = 1001 }
  expect_failures = [var.cloud_run_concurrency]
}

run "rejects_zero_request_timeout" {
  command = plan
  variables { cloud_run_request_timeout_seconds = 0 }
  expect_failures = [var.cloud_run_request_timeout_seconds]
}

run "rejects_excessive_request_timeout" {
  command = plan
  variables { cloud_run_request_timeout_seconds = 3601 }
  expect_failures = [var.cloud_run_request_timeout_seconds]
}

run "rejects_fractional_request_timeout" {
  command = plan
  variables { cloud_run_request_timeout_seconds = 1.5 }
  expect_failures = [var.cloud_run_request_timeout_seconds]
}
