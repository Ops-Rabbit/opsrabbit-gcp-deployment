terraform {
  required_version = ">= 1.15.0"

  required_providers {
    google = {
      source = "hashicorp/google"
      # Cloud Run NFS volume mounts are a newer, Pre-GA feature. If `terraform
      # plan` errors on the `nfs` block inside google_cloud_run_v2_service's
      # volumes, you likely need a newer provider release than this pins --
      # check the provider changelog for "Cloud Run NFS volume" support.
      version = "~> 6.15"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    google-beta = {
      source = "hashicorp/google-beta"
      # Matches the locked stable provider; required for default_uri_disabled
      # and the regional backend service's Cloud Armor attachment.
      version = "6.50.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
  }
}
