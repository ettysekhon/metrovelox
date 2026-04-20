variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "gcp_service_account_email" {
  description = "GCP service account email"
  type        = string
}

variable "k8s_namespace" {
  description = "Kubernetes namespace"
  type        = string
}

variable "k8s_service_account" {
  description = "Kubernetes service account name"
  type        = string
}

resource "google_service_account_iam_member" "workload_identity" {
  service_account_id = "projects/${var.project_id}/serviceAccounts/${var.gcp_service_account_email}"
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.k8s_namespace}/${var.k8s_service_account}]"
}

output "annotation" {
  description = "Annotation to add to K8s ServiceAccount"
  value       = "iam.gke.io/gcp-service-account=${var.gcp_service_account_email}"
}
