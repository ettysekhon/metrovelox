variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "account_id" {
  description = "Service account ID"
  type        = string
}

variable "display_name" {
  description = "Human-readable name"
  type        = string
}

variable "description" {
  description = "Service account description"
  type        = string
  default     = ""
}

variable "roles" {
  description = "IAM roles to grant"
  type        = list(string)
  default     = []
}

resource "google_service_account" "sa" {
  project      = var.project_id
  account_id   = var.account_id
  display_name = var.display_name
  description  = var.description
}

resource "google_project_iam_member" "roles" {
  for_each = toset(var.roles)
  
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.sa.email}"
}

output "email" {
  description = "Service account email"
  value       = google_service_account.sa.email
}

output "name" {
  description = "Service account full name"
  value       = google_service_account.sa.name
}
