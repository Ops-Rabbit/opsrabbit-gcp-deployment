provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

data "google_client_config" "current" {}

provider "helm" {
  kubernetes {
    host                   = try(local.gke_cluster_endpoint, "https://127.0.0.1")
    token                  = try(data.google_client_config.current.access_token, "")
    cluster_ca_certificate = try(base64decode(local.gke_cluster_ca_certificate), null)
  }
}
