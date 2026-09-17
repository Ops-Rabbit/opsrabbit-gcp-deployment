# ---------------------------------------------------------------------------
# One-time Filestore permission fix.
# ---------------------------------------------------------------------------
# Filestore's default share permissions only allow uid 0 (root) to write.
# Rather than forcing the OpsRabbit backend container to run as root, this
# job mounts the share once as root and chowns it to the backend's actual
# UID/GID, so the backend can keep running as its normal non-root user.
#
# You must determine backend_uid / backend_gid yourself before applying --
# this repo doesn't know them:
#   docker run --rm --entrypoint sh <backend_image> -c "id -u; id -g"
#
# Terraform creates this job but does NOT execute it (running a Cloud Run
# Job is an explicit action, not something that should happen silently on
# every apply). Run it once, manually, after the bootstrap apply and
# before setting application_enabled = true:
#   gcloud run jobs execute opsrabbit-fs-init --project <project> --region <region> --wait

resource "google_cloud_run_v2_job" "filestore_init" {
  project  = var.project_id
  name     = "${var.name_prefix}-fs-init"
  location = var.region

  template {
    template {
      max_retries = 0

      vpc_access {
        network_interfaces {
          network    = local.vpc_name
          subnetwork = local.subnet_self_link
        }
        egress = "PRIVATE_RANGES_ONLY"
      }

      containers {
        image   = "docker.io/library/busybox:latest"
        command = ["sh", "-c"]
        args = [
          "mkdir -p /mnt/share/application-data /mnt/share/git-workspace /mnt/share/agent-browser /mnt/share/codex && chown -R ${var.backend_uid}:${var.backend_gid} /mnt/share && chmod -R u+rwX /mnt/share && echo 'permissions set'"
        ]

        volume_mounts {
          name       = "share"
          mount_path = "/mnt/share"
        }
      }

      volumes {
        name = "share"
        nfs {
          server    = local.filestore_ip_address
          path      = "/${var.filestore_share_name}"
          read_only = false
        }
      }
    }
  }

  depends_on = [google_filestore_instance.opsrabbit]
}
