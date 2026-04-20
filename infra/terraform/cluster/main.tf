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

variable "zone" {
  type    = string
  default = "europe-west2-a"
}

variable "cluster_name" {
  type    = string
  default = "openvelox"
}

variable "spot_machine_type" {
  type    = string
  default = "e2-standard-4"
}

variable "spot_min_node_count" {
  type    = number
  default = 1
}

variable "spot_max_node_count" {
  type    = number
  default = 3
}

variable "standard_machine_type" {
  type    = string
  default = "e2-medium"
}

variable "system_machine_type" {
  type    = string
  default = "n2d-standard-4"
}

variable "domain" {
  description = "Base domain for the platform (e.g. example.com)"
  type        = string
  default     = ""
}

data "terraform_remote_state" "foundation" {
  backend = "gcs"
  config = {
    bucket = "tfstate-${var.project_id}"
    prefix = "foundation"
  }
}

module "gke" {
  source = "../_modules/gke-cluster"
  
  project_id             = var.project_id
  cluster_name           = var.cluster_name
  region                 = var.region
  zone                   = var.zone
  node_service_account   = data.terraform_remote_state.foundation.outputs.service_accounts.gke_node
  spot_machine_type      = var.spot_machine_type
  spot_min_node_count    = var.spot_min_node_count
  spot_max_node_count    = var.spot_max_node_count
  standard_machine_type  = var.standard_machine_type
  system_machine_type    = var.system_machine_type
}

# Workload Identity bindings
module "wif_airflow" {
  source = "../_modules/wif-binding"
  
  project_id                = var.project_id
  gcp_service_account_email = data.terraform_remote_state.foundation.outputs.service_accounts.airflow
  k8s_namespace             = "batch"
  k8s_service_account       = "airflow"
  
  depends_on = [module.gke]
}

module "wif_flink" {
  source = "../_modules/wif-binding"
  
  project_id                = var.project_id
  gcp_service_account_email = data.terraform_remote_state.foundation.outputs.service_accounts.flink
  k8s_namespace             = "streaming"
  k8s_service_account       = "flink"
  
  depends_on = [module.gke]
}

# Polaris acts as the Iceberg REST catalog and performs its own GCS
# writes (table metadata + optional data via Iceberg GCSFileIO), so it
# needs a GSA of its own instead of piggy-backing on the node SA.
module "wif_polaris" {
  source = "../_modules/wif-binding"

  project_id                = var.project_id
  gcp_service_account_email = data.terraform_remote_state.foundation.outputs.service_accounts.polaris
  k8s_namespace             = "data"
  k8s_service_account       = "polaris"

  depends_on = [module.gke]
}

# Trino reads Iceberg tables directly from GCS via WI — see
# foundation/iam.tf `trino_sa` for the rationale (Trino 479 incompatibility
# with Polaris vended OAuth2 tokens).  The K8s SA `trino` is created by the
# Trino Helm chart in the `data` namespace.
module "wif_trino" {
  source = "../_modules/wif-binding"

  project_id                = var.project_id
  gcp_service_account_email = data.terraform_remote_state.foundation.outputs.service_accounts.trino
  k8s_namespace             = "data"
  k8s_service_account       = "trino"

  depends_on = [module.gke]
}

module "wif_spark" {
  source = "../_modules/wif-binding"

  project_id                = var.project_id
  gcp_service_account_email = data.terraform_remote_state.foundation.outputs.service_accounts.spark
  k8s_namespace             = "batch"
  k8s_service_account       = "spark"

  depends_on = [module.gke]
}

module "wif_vault" {
  source = "../_modules/wif-binding"

  project_id                = var.project_id
  gcp_service_account_email = data.terraform_remote_state.foundation.outputs.service_accounts.vault
  k8s_namespace             = "security"
  k8s_service_account       = "vault"

  depends_on = [module.gke]
}

module "wif_api" {
  source = "../_modules/wif-binding"

  project_id                = var.project_id
  gcp_service_account_email = data.terraform_remote_state.foundation.outputs.service_accounts.api
  k8s_namespace             = "apps"
  k8s_service_account       = "api"

  depends_on = [module.gke]
}

output "cluster_name" {
  value = module.gke.cluster_name
}

output "get_credentials_command" {
  value = "gcloud container clusters get-credentials ${module.gke.cluster_name} --zone ${var.zone} --project ${var.project_id}"
}
