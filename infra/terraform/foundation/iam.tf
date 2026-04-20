# GKE Node Service Account
module "gke_node_sa" {
  source = "../_modules/service-account"

  project_id   = var.project_id
  account_id   = "gke-node-sa"
  display_name = "GKE Node Service Account"

  roles = [
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/artifactregistry.reader",
    "roles/storage.objectViewer",
  ]

  depends_on = [google_project_service.apis]
}

# Airflow Orchestrator
module "airflow_sa" {
  source = "../_modules/service-account"

  project_id   = var.project_id
  account_id   = "airflow-sa"
  display_name = "Airflow Orchestrator"

  roles = [
    "roles/bigquery.dataEditor",
    "roles/bigquery.jobUser",
    "roles/storage.objectAdmin",
    "roles/secretmanager.secretAccessor",
  ]

  depends_on = [google_project_service.apis]
}

# Flink Streaming (reads from Kafka on GKE, writes to Iceberg on GCS)
module "flink_sa" {
  source = "../_modules/service-account"

  project_id   = var.project_id
  account_id   = "flink-sa"
  display_name = "Flink Streaming"

  roles = [
    "roles/storage.objectAdmin",
  ]

  depends_on = [google_project_service.apis]
}

# Polaris Iceberg REST catalog (writes table metadata/data to GCS via
# Iceberg GCSFileIO, independently of the Flink writer).  Runs as the
# `polaris` ServiceAccount in the `data` namespace and federates to
# this GSA via Workload Identity (see ../cluster/main.tf).
module "polaris_sa" {
  source = "../_modules/service-account"

  project_id   = var.project_id
  account_id   = "polaris-sa"
  display_name = "Polaris Iceberg REST Catalog"

  roles = [
    "roles/storage.objectAdmin",
  ]

  depends_on = [google_project_service.apis]
}

# API Service Account
module "api_sa" {
  source = "../_modules/service-account"

  project_id   = var.project_id
  account_id   = "api-sa"
  display_name = "OpenVelox API"

  roles = [
    "roles/secretmanager.secretAccessor",
    "roles/storage.objectViewer",
  ]

  depends_on = [google_project_service.apis]
}

# Spark Batch — SparkApplication jobs on GKE (Spark Operator)
module "spark_sa" {
  source = "../_modules/service-account"

  project_id   = var.project_id
  account_id   = "spark-sa"
  display_name = "Spark Batch (K8s Operator)"

  roles = [
    "roles/storage.objectAdmin",
  ]

  depends_on = [google_project_service.apis]
}

# Trino Coordinator (reads Iceberg tables from GCS via Application Default
# Credentials / Workload Identity).  Trino 479's `gcs.use-access-token=true`
# path runs vended OAuth2 tokens through `GoogleCredentials.fromStream()`
# which expects a service-account JSON blob, so it is incompatible with the
# raw `ya29.dr.*` bearer tokens vended by Polaris' Iceberg REST credential
# endpoint.  The pragmatic workaround is to let Trino reach GCS directly via
# Workload Identity on this GSA while Polaris still enforces catalog-level
# RBAC at the REST layer.  `objectViewer` is deliberately narrow — Trino
# does not write.  See helm/trino/values-prod.tmpl.yaml for the full
# upstream-bug rationale inline in the Helm values.
module "trino_sa" {
  source = "../_modules/service-account"

  project_id   = var.project_id
  account_id   = "trino-sa"
  display_name = "Trino Coordinator (GCS via WI)"

  roles = [
    "roles/storage.objectViewer",
  ]

  depends_on = [google_project_service.apis]
}

# Vault — auto-unseal via GCP KMS
module "vault_sa" {
  source = "../_modules/service-account"

  project_id   = var.project_id
  account_id   = "vault-sa"
  display_name = "Vault (KMS auto-unseal)"

  roles = []

  depends_on = [google_project_service.apis]
}

resource "google_kms_crypto_key_iam_member" "vault_unseal" {
  crypto_key_id = google_kms_crypto_key.vault_unseal.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${module.vault_sa.email}"
}

# Vault startup checks key existence via cloudkms.cryptoKeys.get (not in EncrypterDecrypter).
resource "google_kms_crypto_key_iam_member" "vault_unseal_viewer" {
  crypto_key_id = google_kms_crypto_key.vault_unseal.id
  role          = "roles/cloudkms.viewer"
  member        = "serviceAccount:${module.vault_sa.email}"
}

output "service_accounts" {
  value = {
    gke_node = module.gke_node_sa.email
    airflow  = module.airflow_sa.email
    flink    = module.flink_sa.email
    polaris  = module.polaris_sa.email
    spark    = module.spark_sa.email
    api      = module.api_sa.email
    trino    = module.trino_sa.email
    vault    = module.vault_sa.email
  }
}
