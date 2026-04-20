# Enable required APIs
locals {
  required_apis = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "storage.googleapis.com",
    "artifactregistry.googleapis.com",
    "pubsub.googleapis.com",             # GCS OBJECT_FINALIZE notifications → Airflow AssetWatcher
    "secretmanager.googleapis.com",
    "iamcredentials.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "certificatemanager.googleapis.com",
    "cloudkms.googleapis.com",
  ]
}

resource "google_project_service" "apis" {
  for_each = toset(local.required_apis)
  
  project            = var.project_id
  service            = each.key
  disable_on_destroy = false
}
