terraform {
  required_version = ">= 1.9"
  
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
  
  backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
}

variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "europe-west2"
}

# Read the foundation remote state for GSA emails so we can grant
# bucket-level IAM to the service accounts that write to these buckets.
data "terraform_remote_state" "foundation" {
  backend = "gcs"
  config = {
    bucket = "tfstate-${var.project_id}"
    prefix = "foundation"
  }
}

variable "repository_id" {
  description = "Artifact Registry repository name (defaults to short project name)"
  type        = string
  default     = ""
}

locals {
  repo_id = var.repository_id != "" ? var.repository_id : split("-", var.project_id)[0]
}

# Iceberg data lake
module "iceberg_bucket" {
  source = "../_modules/gcs-bucket"
  
  project_id    = var.project_id
  name          = "${var.project_id}-lakehouse"
  location      = var.region
  storage_class = "STANDARD"
  
  lifecycle_rules = [
    { age_days = 30,  storage_class = "NEARLINE" },
    { age_days = 90,  storage_class = "COLDLINE" },
    { age_days = 365, storage_class = "ARCHIVE" },
  ]
  
  labels = {
    purpose = "lakehouse"
  }
}

# Flink checkpoints
module "flink_bucket" {
  source = "../_modules/gcs-bucket"
  
  project_id    = var.project_id
  name          = "${var.project_id}-flink"
  location      = var.region
  storage_class = "STANDARD"
  
  lifecycle_rules = [
    { age_days = 7, storage_class = "NEARLINE" },
  ]
  
  labels = {
    purpose = "flink-state"
  }
}

# ─── Bucket-level IAM ────────────────────────────────────────────────
#
# Project-level `roles/storage.objectAdmin` (granted in foundation/iam.tf)
# does NOT include `storage.buckets.get`, which the Iceberg GCSFileIO
# bucket-validation step requires before creating any object.  Iceberg
# fails with a 403 on that check before it ever tries to PUT data.
#
# Granting `roles/storage.legacyBucketReader` at the bucket level adds
# the missing `storage.buckets.get` + `storage.buckets.list` without
# widening project-level blast radius.  Both the Flink streaming SA and
# the Polaris REST catalog SA write Iceberg metadata/data into
# `<project>-lakehouse`; only Flink uses `<project>-flink` (checkpoint
# and savepoint storage).

locals {
  flink_sa_member   = "serviceAccount:${data.terraform_remote_state.foundation.outputs.service_accounts.flink}"
  polaris_sa_member = "serviceAccount:${data.terraform_remote_state.foundation.outputs.service_accounts.polaris}"
}

resource "google_storage_bucket_iam_member" "lakehouse_flink_bucket_reader" {
  bucket = module.iceberg_bucket.name
  role   = "roles/storage.legacyBucketReader"
  member = local.flink_sa_member
}

resource "google_storage_bucket_iam_member" "lakehouse_polaris_bucket_reader" {
  bucket = module.iceberg_bucket.name
  role   = "roles/storage.legacyBucketReader"
  member = local.polaris_sa_member
}

resource "google_storage_bucket_iam_member" "flink_flink_bucket_reader" {
  bucket = module.flink_bucket.name
  role   = "roles/storage.legacyBucketReader"
  member = local.flink_sa_member
}

# Note: Pub/Sub replaced by Kafka (self-hosted on GKE via Strimzi Operator).
# Kafka topics are created via kafka-topics.sh CLI or Strimzi KafkaTopic CRDs, not Terraform.
# See 11-STREAMING.md for topic creation commands.

# Artifact Registry
resource "google_artifact_registry_repository" "containers" {
  project       = var.project_id
  location      = var.region
  repository_id = local.repo_id
  format        = "DOCKER"
}

output "buckets" {
  value = {
    lakehouse = module.iceberg_bucket.name
    flink   = module.flink_bucket.name
  }
}

output "artifact_registry" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.containers.repository_id}"
}
