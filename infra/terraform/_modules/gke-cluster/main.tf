variable "project_id" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "region" {
  type = string
}

variable "zone" {
  type = string
}

variable "network" {
  type    = string
  default = "default"
}

variable "subnetwork" {
  type    = string
  default = "default"
}

variable "node_service_account" {
  type = string
}

variable "spot_machine_type" {
  type    = string
  default = "e2-standard-4"
}

variable "standard_machine_type" {
  type    = string
  default = "e2-medium"
}

variable "system_machine_type" {
  type    = string
  default = "n2d-standard-4"
}

variable "spot_min_node_count" {
  type    = number
  default = 0
}

variable "spot_max_node_count" {
  type    = number
  default = 2
}

variable "standard_node_count" {
  type    = number
  default = 1
}

variable "system_node_count" {
  type    = number
  default = 1
}

# GKE Cluster (Zonal = free control plane)
resource "google_container_cluster" "cluster" {
  name     = var.cluster_name
  location = var.zone
  project  = var.project_id
  
  remove_default_node_pool = true
  initial_node_count       = 1
  
  network    = var.network
  subnetwork = var.subnetwork
  
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }
  
  release_channel {
    channel = "REGULAR"
  }
  
  addons_config {
    http_load_balancing {
      disabled = false  # Required for GKE Gateway API
    }
    horizontal_pod_autoscaling {
      disabled = false
    }
    gce_persistent_disk_csi_driver_config {
      enabled = true
    }
  }
  
  maintenance_policy {
    daily_maintenance_window {
      start_time = "03:00"
    }
  }
  
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS"]
  }
  
  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
    managed_prometheus {
      enabled = false
    }
  }
  
  gateway_api_config {
    channel = "CHANNEL_STANDARD"
  }

  deletion_protection = false
}

# Spot node pool (stateless workloads) — autoscales 0-2 for scale-to-zero
resource "google_container_node_pool" "spot" {
  name       = "spot-pool"
  location   = var.zone
  cluster    = google_container_cluster.cluster.name
  project    = var.project_id

  autoscaling {
    total_min_node_count = var.spot_min_node_count
    total_max_node_count = var.spot_max_node_count
    location_policy      = "ANY"
  }

  node_config {
    machine_type    = var.spot_machine_type
    disk_size_gb    = 100
    disk_type       = "pd-balanced"
    service_account = var.node_service_account
    spot            = true
    
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
    
    workload_metadata_config {
      mode = "GKE_METADATA"
    }
    
    labels = {
      "openvelox/node-type" = "spot"
      "workload"             = "stateless"
    }
    
    taint {
      key    = "cloud.google.com/gke-spot"
      value  = "true"
      effect = "NO_SCHEDULE"
    }
  }
  
  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

# Standard node pool (stateful workloads)
resource "google_container_node_pool" "standard" {
  name       = "standard-pool"
  location   = var.zone
  cluster    = google_container_cluster.cluster.name
  project    = var.project_id
  node_count = var.standard_node_count
  
  node_config {
    machine_type    = var.standard_machine_type
    disk_size_gb    = 50
    disk_type       = "pd-ssd"
    service_account = var.node_service_account
    spot            = false
    
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
    
    workload_metadata_config {
      mode = "GKE_METADATA"
    }
    
    labels = {
      "openvelox/node-type" = "stateful"
      "workload"             = "stateful"
    }
    
    taint {
      key    = "openvelox/stateful"
      value  = "true"
      effect = "NO_SCHEDULE"
    }
  }
  
  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

# System pool — untainted, runs kube-dns, konnectivity-agent, metrics-server.
# Without this pool, all GKE system pods remain Pending when other pools
# carry taints (spot, stateful), breaking kubectl exec/logs and DNS.
resource "google_container_node_pool" "system" {
  name       = "system-pool"
  location   = var.zone
  cluster    = google_container_cluster.cluster.name
  project    = var.project_id
  node_count = var.system_node_count
  
  node_config {
    machine_type    = var.system_machine_type
    disk_size_gb    = 30
    disk_type       = "pd-balanced"
    service_account = var.node_service_account
    spot            = false
    
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
    
    workload_metadata_config {
      mode = "GKE_METADATA"
    }
    
    labels = {
      "openvelox/node-type" = "system"
    }
  }
  
  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

output "cluster_name" {
  value = google_container_cluster.cluster.name
}

output "cluster_endpoint" {
  value     = google_container_cluster.cluster.endpoint
  sensitive = true
}

output "cluster_ca_certificate" {
  value     = google_container_cluster.cluster.master_auth[0].cluster_ca_certificate
  sensitive = true
}
