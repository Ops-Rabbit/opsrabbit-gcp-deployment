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
# controls exactly one thing now: Cloud Run ingress (public internet vs
# internal-only).

variable "network_mode" {
  type    = string
  default = "public"

  validation {
    condition     = contains(["public", "private"], var.network_mode)
    error_message = "network_mode must be \"public\" or \"private\"."
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
}

variable "web_image" {
  description = "Full Artifact Registry image reference, using an immutable digest."
  type        = string
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
  description = "Basic tier minimum is 1024 GB regardless of how much you actually need."
  type        = number
  default     = 1024

  validation {
    condition     = var.filestore_capacity_gb >= 1024
    error_message = "Basic-tier Filestore requires at least 1024 GB."
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
  description = "Public HTTPS origin, e.g. \"https://opsrabbit.example.com\". If null, the Cloud Run-assigned URL is used."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Encryption at rest (optional, defaults to Google-managed keys)
# ---------------------------------------------------------------------------

variable "kms_key_name" {
  description = <<-EOT
    Optional Cloud KMS key (format:
    projects/P/locations/L/keyRings/R/cryptoKeys/K) for customer-managed
    encryption at rest on Cloud SQL, Filestore, and Artifact Registry.
    Leave null (default) to use Google-managed encryption, which is the
    default for every GCP storage service here and sufficient for most
    deployments. Only set this if a customer's compliance requirements
    specifically mandate CMEK. The key must already exist, and the
    relevant Google service agent needs
    roles/cloudkms.cryptoKeyEncrypterDecrypter on it before this is set --
    see SECURITY.md for the exact service agents and setup order.
  EOT
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Staged rollout
# ---------------------------------------------------------------------------

variable "application_enabled" {
  description = "Keep false for the bootstrap apply (registry, database, Filestore, VPC only). Set true once images are imported and NFS write access is verified."
  type        = bool
  default     = false
}
