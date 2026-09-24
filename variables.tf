variable "project_id" {
  description = "GCP project ID that will host OpsRabbit. The project must already exist."
  type        = string
}

variable "region" {
  description = "GCP region for all resources (Cloud Run, Cloud SQL, Filestore, Artifact Registry)."
  type        = string
  default     = "us-central1"
}

variable "name_prefix" {
  type    = string
  default = "opsrabbit"
}

variable "labels" {
  type    = map(string)
  default = {}
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------
# A VPC is always required (Filestore has no public-IP mode), and Cloud Run
# always has Direct VPC egress as a result -- so Cloud SQL is always private
# IP only too, regardless of network_mode; there's no configuration left
# where a public Cloud SQL IP would actually be needed. network_mode
# selects public Cloud Run ingress or an internal HTTPS load balancer with
# source restrictions and no direct run.app access.

variable "network_mode" {
  description = "Application exposure: public Cloud Run URL or private HTTPS ingress. VPN/private connectivity, DNS and certificates remain customer-managed."
  type        = string
  default     = "public"

  validation {
    condition     = contains(["public", "private"], var.network_mode)
    error_message = "network_mode must be \"public\" or \"private\"."
  }
}

variable "private_ingress" {
  description = "Private HTTPS ingress. Customer supplies VPN/routes, approved source IPv4 CIDRs, regional Compute SSL certificates, and DNS. Supply an existing ACTIVE proxy-only subnet or a new non-overlapping /26-or-larger CIDR."
  type = object({
    allowed_source_cidrs            = list(string)
    ssl_certificate_self_links      = list(string)
    proxy_subnet_cidr               = optional(string)
    existing_proxy_subnet_self_link = optional(string)
    allow_global_access             = optional(bool, true)
  })
  default = null

  validation {
    condition     = var.network_mode != "private" || var.private_ingress != null
    error_message = "Private mode requires private_ingress with source CIDRs, TLS certificates and a proxy-only subnet."
  }
  validation {
    condition = var.private_ingress == null ? true : (
      length(var.private_ingress.allowed_source_cidrs) >= 1 && length(var.private_ingress.allowed_source_cidrs) <= 10 &&
      alltrue([for cidr in var.private_ingress.allowed_source_cidrs : can(cidrnetmask(cidr)) && try(tonumber(split("/", cidr)[1]) > 0, false)])
    )
    error_message = "Supply 1-10 approved IPv4 CIDRs; unrestricted /0 access is not allowed. Use the client or NAT source range visible to the load balancer."
  }
  validation {
    condition = var.private_ingress == null ? true : (
      length(var.private_ingress.ssl_certificate_self_links) >= 1 && length(var.private_ingress.ssl_certificate_self_links) <= 15 &&
      alltrue([for cert in var.private_ingress.ssl_certificate_self_links : can(regex("^(https://www.googleapis.com/compute/v1/)?projects/${var.project_id}/regions/${var.region}/sslCertificates/[^/]+$", cert))])
    )
    error_message = "Supply 1-15 existing regional Compute SSL certificate references in this project and region. Their names must cover application_origin."
  }
  validation {
    condition = var.private_ingress == null ? true : (
      (var.private_ingress.proxy_subnet_cidr != null) != (var.private_ingress.existing_proxy_subnet_self_link != null)
    )
    error_message = "Supply exactly one of proxy_subnet_cidr or existing_proxy_subnet_self_link."
  }
  validation {
    condition = try(var.private_ingress.proxy_subnet_cidr, null) == null ? true : (
      can(cidrnetmask(var.private_ingress.proxy_subnet_cidr)) && try(tonumber(split("/", var.private_ingress.proxy_subnet_cidr)[1]) > 0 && tonumber(split("/", var.private_ingress.proxy_subnet_cidr)[1]) <= 26, false)
    )
    error_message = "The proxy-only subnet must be an IPv4 /26 or larger; choose an unused range that does not overlap the VPN or VPC."
  }
  validation {
    condition = try(var.private_ingress.existing_proxy_subnet_self_link, null) == null ? true : (
      !var.create_vpc && can(regex("^(https://www.googleapis.com/compute/v1/)?projects/${var.project_id}/regions/${var.region}/subnetworks/[^/]+$", var.private_ingress.existing_proxy_subnet_self_link))
    )
    error_message = "An existing proxy-only subnet requires create_vpc=false and a subnet reference in this project/region."
  }
  validation {
    condition = var.private_ingress == null || var.network_mode != "private" || (
      can(regex("^https://[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$", var.application_origin)) &&
      !try(endswith(lower(var.application_origin), ".run.app"), true)
    )
    error_message = "Private mode requires application_origin as a customer HTTPS hostname on port 443, without a path or explicit port. The disabled run.app URL cannot be used."
  }
  validation {
    condition = var.private_ingress == null || var.network_mode != "private" || var.create_vpc || (
      can(regex("^(https://www.googleapis.com/compute/v1/)?projects/${var.project_id}/global/networks/[^/]+$", var.existing_network_self_link)) &&
      can(regex("^(https://www.googleapis.com/compute/v1/)?projects/${var.project_id}/regions/${var.region}/subnetworks/[^/]+$", var.existing_subnet_self_link))
    )
    error_message = "Private mode with create_vpc=false requires network and frontend subnet references in the deployment project and region; cross-project Shared VPC is not supported."
  }
}


variable "create_vpc" {
  description = "true (default): Terraform creates a dedicated VPC + subnet for Filestore/Cloud Run direct-VPC-egress. false: supply existing_network_self_link / existing_subnet_self_link instead."
  type        = bool
  default     = true
}

variable "existing_network_self_link" {
  type    = string
  default = null
}

variable "existing_subnet_self_link" {
  type    = string
  default = null
}

variable "subnet_cidr" {
  description = "Only used when create_vpc = true."
  type        = string
  default     = "10.10.0.0/20"
}

variable "allow_unauthenticated" {
  description = "network_mode = \"public\" only. Grants roles/run.invoker to allUsers."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Container images
# ---------------------------------------------------------------------------

variable "backend_image" {
  description = "Full Artifact Registry image reference, using an immutable digest."
  type        = string

  validation {
    condition     = !var.application_enabled || can(regex("^[a-z0-9-]+-docker[.]pkg[.]dev/[^/]+/[^/]+/.+@sha256:[0-9a-f]{64}$", var.backend_image))
    error_message = "backend_image must be an Artifact Registry image pinned to a SHA-256 digest when application_enabled is true."
  }
}

variable "web_image" {
  description = "Full Artifact Registry image reference, using an immutable digest."
  type        = string

  validation {
    condition     = !var.application_enabled || can(regex("^[a-z0-9-]+-docker[.]pkg[.]dev/[^/]+/[^/]+/.+@sha256:[0-9a-f]{64}$", var.web_image))
    error_message = "web_image must be an Artifact Registry image pinned to a SHA-256 digest when application_enabled is true."
  }
}

# Event streams remain open while the UI makes other API requests.
variable "cloud_run_concurrency" {
  type        = number
  description = "Maximum simultaneous requests per instance, including open event streams."
  default     = 20

  validation {
    condition     = var.cloud_run_concurrency >= 2 && var.cloud_run_concurrency <= 1000 && floor(var.cloud_run_concurrency) == var.cloud_run_concurrency
    error_message = "cloud_run_concurrency must be an integer between 2 and 1000; event streams need room for other API requests."
  }
}

variable "cloud_run_request_timeout_seconds" {
  type        = number
  description = "Request lifetime, including event streams; clients must reconnect when it expires."
  default     = 3600

  validation {
    condition     = var.cloud_run_request_timeout_seconds >= 1 && var.cloud_run_request_timeout_seconds <= 3600 && floor(var.cloud_run_request_timeout_seconds) == var.cloud_run_request_timeout_seconds
    error_message = "cloud_run_request_timeout_seconds must be an integer between 1 and 3600."
  }
}

variable "backend_cpu" {
  type    = string
  default = "1"
}

variable "backend_memory" {
  type    = string
  default = "2Gi"
}

variable "web_cpu" {
  type    = string
  default = "1"
}

variable "web_memory" {
  type    = string
  default = "512Mi"
}

# ---------------------------------------------------------------------------
# Cloud SQL
# ---------------------------------------------------------------------------

variable "postgresql_instance_name" {
  type    = string
  default = "opsrabbit-pg"
}

variable "postgresql_tier" {
  type    = string
  default = "db-custom-2-8192"
}

variable "postgresql_disk_size_gb" {
  type    = number
  default = 50
}

variable "postgresql_database_name" {
  type    = string
  default = "opsrabbit"
}

variable "postgresql_administrator_login" {
  type    = string
  default = "opsrabbit_admin"
}

variable "postgresql_administrator_password" {
  type      = string
  sensitive = true
}

variable "postgresql_backup_retention_days" {
  type    = number
  default = 14
}

# ---------------------------------------------------------------------------
# Filestore (mounted into Cloud Run as a native NFS volume)
# ---------------------------------------------------------------------------
# UNVERIFIED so far: whether the backend's git operations tolerate no-lock
# NFS mode. See filestore-init.tf for the write-permission side of this --
# that part has a known fix (chown), it's the locking behavior that still
# needs real testing.

variable "backend_uid" {
  description = "UID the backend container's main process runs as. Determine with: docker run --rm --entrypoint sh <backend_image> -c \"id -u\". Required -- there's no safe default to guess here."
  type        = number
}

variable "backend_gid" {
  description = "GID the backend container's main process runs as. Determine with: docker run --rm --entrypoint sh <backend_image> -c \"id -g\"."
  type        = number
}

variable "filestore_tier" {
  type    = string
  default = "BASIC_HDD"

  validation {
    condition     = contains(["BASIC_HDD", "BASIC_SSD"], var.filestore_tier)
    error_message = "filestore_tier must be BASIC_HDD or BASIC_SSD."
  }
}

variable "filestore_capacity_gb" {
  description = "Capacity in GiB: Basic HDD requires 1024; Basic SSD requires 2560."
  type        = number
  default     = 1024

  validation {
    condition     = floor(var.filestore_capacity_gb) == var.filestore_capacity_gb && var.filestore_capacity_gb >= (var.filestore_tier == "BASIC_SSD" ? 2560 : 1024)
    error_message = "Filestore requires whole GiB, at least 1024 for BASIC_HDD or 2560 for BASIC_SSD."
  }
}

variable "filestore_share_name" {
  type    = string
  default = "opsrabbit"
}

# ---------------------------------------------------------------------------
# Application secrets
# ---------------------------------------------------------------------------

variable "better_auth_secret" {
  type      = string
  sensitive = true
}

variable "opsrabbit_encryption_key" {
  type      = string
  sensitive = true
}

variable "application_origin" {
  description = "HTTPS origin used by clients; required when application_enabled is true. Configure DNS/routing separately for a custom domain."
  type        = string
  default     = null

  validation {
    condition     = var.application_origin == null ? !var.application_enabled : can(regex("^https://[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?(:[0-9]+)?$", var.application_origin))
    error_message = "Set application_origin to a real HTTPS origin (no path or trailing slash) before enabling the application."
  }
}

# ---------------------------------------------------------------------------
# Encryption at rest (optional, defaults to Google-managed keys)
# ---------------------------------------------------------------------------

variable "kms_key_name" {
  description = "Reserved for a future CMEK-capable storage tier. Basic Filestore does not support CMEK; this deployment currently requires null."
  type        = string
  default     = null

  validation {
    condition     = var.kms_key_name == null
    error_message = "CMEK is not supported by the allowed Basic Filestore tiers. Leave kms_key_name null; a CMEK deployment requires a storage-tier redesign."
  }
}

# ---------------------------------------------------------------------------
# Staged rollout
# ---------------------------------------------------------------------------

variable "application_enabled" {
  description = "Keep false for the bootstrap apply (registry, database, Filestore, VPC only). Set true once images are imported and NFS write access is verified."
  type        = bool
  default     = false
}

variable "filestore_backup_retention_days" {
  description = "Daily backups retained for this many days; pruning occurs only after a successful new backup."
  type        = number
  default     = 14
  validation {
    condition     = var.filestore_backup_retention_days >= 1 && floor(var.filestore_backup_retention_days) == var.filestore_backup_retention_days
    error_message = "Backup retention must be a positive whole number of days."
  }
}
