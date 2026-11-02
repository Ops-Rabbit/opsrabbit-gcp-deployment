variable "opensandbox_enabled" {
  description = "Install the private OpenSandbox Kubernetes service on GKE."
  type        = bool
  default     = false
  validation {
    condition     = !var.opensandbox_enabled || contains(["standard", "autopilot"], var.deployment_mode)
    error_message = "OpenSandbox installation requires GKE Standard or Autopilot."
  }
}

variable "opensandbox_images" {
  description = "Approved immutable images: controller, server, gateway, execd, egress and sandbox, mirrored to the installation registry."
  type        = map(string)
  default     = {}
  validation {
    condition = !var.opensandbox_enabled || alltrue([
      for component in ["controller", "server", "gateway", "execd", "egress", "sandbox"] :
      can(regex("^[a-z0-9-]+-docker[.]pkg[.]dev/[a-z0-9._-]+/[a-z0-9._-]+/[a-z0-9._/-]+@sha256:[0-9a-f]{64}$", lookup(var.opensandbox_images, component, "")))
    ])
    error_message = "Every OpenSandbox component must have an approved Artifact Registry repository@sha256:digest reference without a tag."
  }
}

locals {
  opensandbox_pod_security = {
    runAsNonRoot   = true
    runAsUser      = 10001
    runAsGroup     = 10001
    fsGroup        = 10001
    seccompProfile = { type = "RuntimeDefault" }
  }
  opensandbox_container_security = {
    allowPrivilegeEscalation = false
    readOnlyRootFilesystem   = true
    capabilities             = { drop = ["ALL"] }
  }
  opensandbox_chart_images = {
    for component in ["controller", "server", "gateway"] : component => {
      repository = try(split("@", var.opensandbox_images[component])[0], "missing")
      tag        = "release-1.1.1@${try(split("@", var.opensandbox_images[component])[1], "sha256:missing")}"
    }
  }
}

variable "opensandbox_namespace" {
  description = "Dedicated OpenSandbox control-plane namespace."
  type        = string
  default     = "opensandbox-system"
  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.opensandbox_namespace)) && length(var.opensandbox_namespace) <= 63
    error_message = "OpenSandbox namespace must be a Kubernetes DNS label."
  }
}

variable "opensandbox_workload_namespace" {
  description = "Namespace for disposable sandbox workloads; not a security boundary for the upstream controller."
  type        = string
  default     = "opensandbox"
  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.opensandbox_workload_namespace)) && length(var.opensandbox_workload_namespace) <= 63
    error_message = "OpenSandbox workload namespace must be a Kubernetes DNS label."
  }
}

variable "opensandbox_api_key_secret" {
  description = "Existing Kubernetes Secret in the OpenSandbox namespace, containing api-key."
  type        = string
  default     = "opensandbox-api-key"
}

variable "opensandbox_signing_secret" {
  description = "Existing Kubernetes Secret containing keys and active-key for gateway signing."
  type        = string
  default     = "opensandbox-signing-key"
}

resource "helm_release" "opensandbox_base" {
  count            = var.opensandbox_enabled ? 1 : 0
  name             = "opsrabbit-opensandbox-base"
  namespace        = var.opensandbox_namespace
  create_namespace = true
  chart            = "${path.module}/charts/vendor/base"
  wait             = true
  timeout          = 900
  lifecycle {
    replace_triggered_by = [terraform_data.opensandbox_cluster_identity]
  }
  values = [yamlencode({ fastSandbox = {
    crds       = { install = false }
    namespaces = { createSystem = false, create = false }
    rbac       = { create = false }
  } })]
  depends_on = [google_container_node_pool.opsrabbit, google_container_cluster.autopilot, google_artifact_registry_repository_iam_member.gke_autopilot_pull, google_project_iam_member.gke_autopilot_default_role]
}

resource "terraform_data" "opensandbox_cluster_identity" {
  count            = var.opensandbox_enabled ? 1 : 0
  triggers_replace = [local.gke_cluster_endpoint, local.gke_cluster_ca_certificate]
}

resource "terraform_data" "opensandbox_credentials" {
  count = var.opensandbox_enabled ? 1 : 0
  # Endpoint becomes unknown on cluster replacement, including replacement with
  # the same name. Recreate credentials in the new cluster in that case.
  triggers_replace = [local.gke_cluster_name, local.gke_cluster_location, try(google_container_cluster.opsrabbit[0].endpoint, google_container_cluster.autopilot[0].endpoint, ""), var.opensandbox_namespace, var.opensandbox_workload_namespace, var.opensandbox_api_key_secret, var.opensandbox_signing_secret]
  provisioner "local-exec" {
    command = "python3 \"$BOOTSTRAP_SCRIPT\" prepare --project \"$PROJECT\" --cluster \"$CLUSTER\" --location \"$LOCATION\" --namespace \"$NAMESPACE\" --workload-namespace \"$WORKLOAD_NAMESPACE\" --api-secret \"$API_SECRET\" --signing-secret \"$SIGNING_SECRET\""
    environment = {
      BOOTSTRAP_SCRIPT   = "${path.module}/scripts/bootstrap-opensandbox.py"
      PROJECT            = var.project_id
      CLUSTER            = local.gke_cluster_name
      LOCATION           = local.gke_cluster_location
      NAMESPACE          = var.opensandbox_namespace
      WORKLOAD_NAMESPACE = var.opensandbox_workload_namespace
      API_SECRET         = var.opensandbox_api_key_secret
      SIGNING_SECRET     = var.opensandbox_signing_secret
    }
  }
  depends_on = [helm_release.opensandbox_base]
}

resource "helm_release" "opensandbox_controller" {
  count     = var.opensandbox_enabled ? 1 : 0
  name      = "opsrabbit-opensandbox-controller"
  namespace = var.opensandbox_namespace
  chart     = "${path.module}/charts/vendor/opensandbox-controller"
  wait      = true
  atomic    = true
  timeout   = 900
  lifecycle {
    replace_triggered_by = [terraform_data.opensandbox_cluster_identity]
  }
  values = [yamlencode({ namespaceOverride = var.opensandbox_namespace, controller = {
    image                    = local.opensandbox_chart_images.controller
    podSecurityContext       = local.opensandbox_pod_security
    containerSecurityContext = local.opensandbox_container_security
  } })]
  depends_on = [helm_release.opensandbox_base]
}

resource "helm_release" "opensandbox_gateway" {
  count     = var.opensandbox_enabled ? 1 : 0
  name      = "opsrabbit-opensandbox-gateway"
  namespace = var.opensandbox_namespace
  chart     = "${path.module}/charts/vendor/ingress-gateway"
  wait      = true
  atomic    = true
  timeout   = 900
  lifecycle {
    replace_triggered_by = [terraform_data.opensandbox_cluster_identity]
  }
  values = [yamlencode({
    namespaceOverride = var.opensandbox_namespace
    fullnameOverride  = "opensandbox-ingress-gateway"
    gateway = {
      podSecurityContext       = local.opensandbox_pod_security
      containerSecurityContext = local.opensandbox_container_security
      dataplaneNamespace       = var.opensandbox_workload_namespace
      image                    = local.opensandbox_chart_images.gateway
      service                  = { type = "ClusterIP" }
      secureAccess             = { existingSecret = var.opensandbox_signing_secret }
    }
  })]
  depends_on = [helm_release.opensandbox_controller, terraform_data.opensandbox_credentials]
}

resource "helm_release" "opensandbox_server" {
  count     = var.opensandbox_enabled ? 1 : 0
  name      = "opsrabbit-opensandbox-server"
  namespace = var.opensandbox_namespace
  chart     = "${path.module}/charts/vendor/opensandbox-server"
  wait      = true
  atomic    = true
  timeout   = 900
  lifecycle {
    replace_triggered_by = [terraform_data.opensandbox_cluster_identity]
  }
  values = [yamlencode({
    namespaceOverride = var.opensandbox_namespace
    fullnameOverride  = "opensandbox-server"
    configToml        = <<-TOML
      [server]
      host = "0.0.0.0"
      port = 80
      api_key = ""
      [log]
      level = "INFO"
      [store]
      type = "sqlite"
      path = "/tmp/opensandbox/snapshots.db"
      [runtime]
      type = "kubernetes"
      execd_image = ${jsonencode(lookup(var.opensandbox_images, "execd", "missing"))}
      [kubernetes]
      kubeconfig_path = ""
      namespace = ${jsonencode(var.opensandbox_workload_namespace)}
      informer_resync_seconds = 300
      informer_watch_timeout_seconds = 60
      workload_provider = "batchsandbox"
      isolation_profile = "unprivileged"
      batchsandbox_template_file = "/etc/opensandbox/example.batchsandbox-template.yaml"
      sandbox_create_timeout_seconds = 300
      [egress]
      image = ${jsonencode(lookup(var.opensandbox_images, "egress", "missing"))}
      mode = "dns+nft"
      # Both managed cluster modes are explicitly IPv4-only. Avoid the
      # upstream privileged init container used to disable Pod IPv6.
      disable_ipv6 = false
    TOML
    server = {
      podSecurityContext       = local.opensandbox_pod_security
      containerSecurityContext = local.opensandbox_container_security
      volumes                  = [{ name = "tmp", emptyDir = { sizeLimit = "256Mi" } }]
      volumeMounts             = [{ name = "tmp", mountPath = "/tmp" }]
      image                    = local.opensandbox_chart_images.server
      service                  = { type = "ClusterIP" }
      env = [{ name = "OPENSANDBOX_SERVER_API_KEY", valueFrom = {
        secretKeyRef = { name = var.opensandbox_api_key_secret, key = "api-key" }
      } }]
      gateway = {
        enabled          = true
        host             = "opensandbox-ingress-gateway.${var.opensandbox_namespace}.svc"
        gatewayRouteMode = "header"
        secureAccess     = { existingSecret = var.opensandbox_signing_secret }
      }
    }
  })]
  depends_on = [helm_release.opensandbox_gateway]
}

resource "terraform_data" "opensandbox_bootstrap" {
  count = var.opensandbox_enabled ? 1 : 0
  # Activation is first-install only. In-place upgrades and credential/cluster
  # reconciliation must not reactivate a configuration reset by an admin.
  # Explicit reinitialization uses Terraform's -replace after operator review.
  provisioner "local-exec" {
    command = "python3 \"$BOOTSTRAP_SCRIPT\" configure --project \"$PROJECT\" --cluster \"$CLUSTER\" --location \"$LOCATION\" --namespace \"$NAMESPACE\" --api-secret \"$API_SECRET\" --app-namespace \"$APP_NAMESPACE\" --release \"$RELEASE\" --image \"$SANDBOX_IMAGE\""
    environment = {
      BOOTSTRAP_SCRIPT = "${path.module}/scripts/bootstrap-opensandbox.py"
      PROJECT          = var.project_id
      CLUSTER          = local.gke_cluster_name
      LOCATION         = local.gke_cluster_location
      NAMESPACE        = var.opensandbox_namespace
      API_SECRET       = var.opensandbox_api_key_secret
      APP_NAMESPACE    = var.gke_namespace
      RELEASE          = helm_release.opsrabbit[0].name
      SANDBOX_IMAGE    = lookup(var.opensandbox_images, "sandbox", "missing")
    }
  }
  depends_on = [helm_release.opensandbox_server, helm_release.opsrabbit]
}
