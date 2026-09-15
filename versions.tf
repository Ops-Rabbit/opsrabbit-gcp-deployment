terraform {
  required_version = ">= 1.15.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      # Cloud Run NFS volume mounts are a newer, Pre-GA feature. If `terraform
      # plan` errors on the `nfs` block inside google_cloud_run_v2_service's
      # volumes, you likely need a newer provider release than this pins --
      # check the provider changelog for "Cloud Run NFS volume" support.
      version = "~> 6.15"
    }
    postgresql = {
      source  = "cyrilgdn/postgresql"
      version = "~> 1.21"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
