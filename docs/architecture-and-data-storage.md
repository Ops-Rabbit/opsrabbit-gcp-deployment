# OpsRabbit architecture and data storage

Component responsibilities and deployment behavior | 18 November 2026

OpsRabbit separates the browser experience, HTTP routing, and agent execution into three logical components. Cloud SQL stores structured application records, persistent filesystem storage holds working files and runtime state, and Secret Manager protects deployment secrets. This document explains their purposes and how they work together in the supplied architecture.

## Application components

| Diagram box | What it does | How it works |
| --- | --- | --- |
| OpsRabbit UI<br>Web frontend | Lets users configure and operate OpsRabbit and view workflow results. | Runs in the user’s browser. nginx delivers its assets; the UI sends API requests and receives updates through nginx. |
| OpsRabbit Service<br>nginx | Provides the HTTP entrypoint for the application and routes browser and integration requests. | Serves frontend assets and proxies /api requests to the backend. It does not execute agent workflows. |
| OpsRabbit Platform Agent<br>Backend pod or container | Handles APIs, authorization and application logic; coordinates agent workflows, tools and integrations. | Processes requests and background work, accesses database and files, and calls configured model providers and external services. |

### Logical boxes and deployed workloads

The diagram can retain all three boxes. OpsRabbit Service and OpsRabbit UI represent different responsibilities, but nginx and the frontend assets are packaged together in the web container. On GKE, the backend is a separate pod workload. On Cloud Run, web and backend are separate containers within the same Cloud Run service.

### Optional sandbox execution

OpenSandbox provides isolated environments for agent command and code execution. The backend calls the private OpenSandbox service, which coordinates sandbox pods. The installer supports this optional component on GKE Standard and Autopilot; it is disabled by default and is not provisioned by the Cloud Run variant.

## How a request moves through the system

### Opening the application

A user reaches the application HTTPS address through the configured network and load balancer. The load balancer forwards the request to nginx, which delivers the web frontend to the browser.

### Using the interface

The frontend sends /api requests to the same application origin. nginx forwards them to the backend. The backend authenticates the request and enforces application permissions before reading or changing data.

### Running an agent workflow

The backend coordinates the workflow, retrieves permitted records and files, and calls configured tools, external systems and AI providers. If sandbox execution is enabled, execution requests go to OpenSandbox. Results and progress return to the UI through the application API and event streams.

### Receiving an integration event

An external system can call a configured inbound endpoint through the application ingress and nginx. The backend validates the inbound request and applies the configured processing rules. Each provider needs its own supported and configured integration.

## Supporting architecture components

| Diagram box | Purpose and current deployment relevance |
| --- | --- |
| GCLB | Receives HTTPS traffic and routes it to nginx. Custom domains use a load balancer; Cloud Run can alternatively use its native run.app HTTPS address. |
| Cloud Armor | Filters traffic through configured policies. The private Cloud Run path includes a source-IP allowlist; the public Terraform path does not currently attach an Armor policy. |
| GKE Gateway Controller | Represents routing management. The checked-in GKE implementation uses GKE Ingress rather than Gateway API. A controller manages routing; application requests do not pass through the controller process. |
| Gemini Enterprise | Represents the intended AI integration. Confirm the exact service and API, including whether Gemini models through Vertex AI are intended. This repository does not configure that integration. |
| OpenSandbox Service | Optional private GKE service for isolated execution. Show a backend-to-service connection and, if useful, a separate sandbox pods box. |

ForgeRock, Equinix connectivity, Jira, ServiceNow, Dynatrace, SentinelOne and external logging destinations are customer integration elements in the supplied diagram. Their presence in the diagram does not establish that this deployment provisions or configures them.

## What we store and how it is stored

### Cloud SQL

Purpose: the durable relational database for structured application records. The deployment provisions PostgreSQL 16. Depending on enabled features, records include users and authentication sessions, application and model configuration, workflow records, resource metadata, infrastructure documents, and encrypted application secret values.

Storage method: the backend reads and writes PostgreSQL tables through the application database layer. Records use structured columns and JSON where the schema requires it. Database content is distinct from the files mounted into the backend. Some sensitive application values are encrypted by the application before persistence; this does not mean every database column is individually encrypted.

Connection and protection: Cloud SQL has a private IP and requires encrypted connections. Cloud Run uses a Cloud SQL Auth Proxy, with a local backend-to-proxy hop and an encrypted proxy-to-database connection. GKE connects directly using TLS by default. The Terraform configuration defaults to Google-managed encryption at rest and supports a supplied KMS key for Cloud SQL.

Recovery: automated database backups and point-in-time recovery are enabled. Transaction logs are retained for seven days; backup retention is configurable. The current instance is zonal, so this configuration must not be described as a regional high-availability database.

### Filestore

Purpose: a persistent filesystem for files and runtime state that must survive container replacement. Filestore is the managed NFS file service in this architecture; it is different from Firestore, Google’s document database.

| Backend directory | What it holds |
| --- | --- |
| /home/opsbot/.opsrabbit | Application data files managed under the configured data directory. |
| /home/opsbot/git | Git repositories and agent working files. |
| /home/opsbot/.agent-browser | Browser automation files and persistent browser state. |

Storage method: Cloud Run mounts three subdirectories from one Filestore share as separate NFS volumes. The backend accesses them as ordinary filesystem paths over private VPC connectivity. Browser and agent state can contain sensitive content and must be treated as protected operational data.

Legacy Codex files: the Pi backend does not require a persistent /home/opsbot/.codex mount. Removing that mount does not delete or rename the existing Filestore codex directory. Existing files stay on the share and in its backups; no cleanup is included. The GKE whole-home PVC remains unchanged and retains any existing .codex files.

Recovery and operating limits: a daily Filestore backup workflow uses a default 14-day retention period. Filesystem and database backups are separate recovery points and need coordinated restore planning. NFS locking is unavailable on the Cloud Run mount; concurrent writes and revision overlap require care during upgrades.

GKE difference: the chart uses a PersistentVolumeClaim mounted at /home/opsbot, or a configured existing claim. It is not automatically connected to the Cloud Run Filestore share. Filestore backups do not cover an unrelated GKE PVC.

## Secrets and deployment differences

### Secret Manager

Purpose: protect deployment secrets separately from normal configuration and container images. Terraform creates three managed secrets for the application.

| Secret | Purpose |
| --- | --- |
| Database URL | Connection details and database credentials used by the Cloud Run backend through its local database proxy. |
| BETTER_AUTH_SECRET | Secret used by the application authentication system. Keep it stable across normal upgrades. |
| Application encryption key | Key used to protect application-managed sensitive values. Keep it stable; changing it requires an application-supported data migration. |

Storage method: secrets are stored as versioned values with automatic replication. Cloud Run references specific numeric versions and receives them as environment values. Its runtime identity is granted access to the three application secrets. Secret values should not be placed in diagrams, documentation, images, logs or source control.

GKE difference: Terraform supplies database credentials, the authentication secret and encryption key to a Kubernetes Secret through the Helm release. The backend receives these as environment values. The current chart does not directly retrieve them from Secret Manager at runtime.

Application credentials: integration tokens and other secrets entered through OpsRabbit are not automatically separate Secret Manager entries. Supported application secret paths persist encrypted values in the database using the application encryption key. Classification must follow the particular feature’s implementation.

Rotation and recovery: previous Secret Manager versions are retained for rollback and need deliberate retirement after verification. Database password rotation can interrupt old instances. Terraform also handles sensitive values, so Terraform state and retained state versions require access control and protection. Restoring encrypted application records requires the matching encryption key.

### Deployment comparison

| Area | Cloud Run | GKE Standard and Autopilot |
| --- | --- | --- |
| Application packaging | Web and backend containers in one service, plus SQL proxy. | Separate web and backend workloads. |
| Persistent files | Direct NFS mounts from Filestore. | PVC or existing claim selected through chart configuration. |
| Application secrets | Secret Manager version references. | Kubernetes Secret supplied by Terraform. |
| Ingress | Public HTTPS or private internal HTTPS; native URL also supported. | Public custom-domain HTTPS through GKE Ingress. |
| Sandbox | Not provisioned by this variant. | Optional OpenSandbox service and sandbox pods. |

Implementation references: GCP deployment cloud-run.tf, gke.tf, main.tf, secrets.tf, ingress files, opensandbox.tf and charts/opsrabbit; product database schemas. Deployed-image verification is deferred. Live acceptance and restore validation remain separate activities.
