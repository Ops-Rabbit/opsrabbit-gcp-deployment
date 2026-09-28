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
    host                   = local.helm_kubernetes_host
    token                  = local.helm_kubernetes_token
    cluster_ca_certificate = local.helm_kubernetes_ca_certificate == "" ? null : base64decode(local.helm_kubernetes_ca_certificate)
  }
}
