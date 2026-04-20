variable "project_id" {
  type = string
}

variable "name" {
  type = string
}

variable "location" {
  type = string
}

variable "storage_class" {
  type    = string
  default = "STANDARD"
}

variable "versioning" {
  type    = bool
  default = false
}

variable "lifecycle_rules" {
  type = list(object({
    age_days      = number
    storage_class = string
  }))
  default = []
}

variable "labels" {
  type    = map(string)
  default = {}
}

resource "google_storage_bucket" "bucket" {
  project       = var.project_id
  name          = var.name
  location      = var.location
  storage_class = var.storage_class
  
  uniform_bucket_level_access = true
  
  versioning {
    enabled = var.versioning
  }
  
  dynamic "lifecycle_rule" {
    for_each = var.lifecycle_rules
    content {
      condition {
        age = lifecycle_rule.value.age_days
      }
      action {
        type          = "SetStorageClass"
        storage_class = lifecycle_rule.value.storage_class
      }
    }
  }
  
  labels = var.labels
}

output "name" {
  value = google_storage_bucket.bucket.name
}

output "url" {
  value = google_storage_bucket.bucket.url
}
