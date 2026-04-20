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

variable "domain" {
  description = "Base domain (e.g. example.com)"
  type        = string
}

# DNS authorization for the domain
resource "google_certificate_manager_dns_authorization" "domain" {
  name        = "${replace(var.domain, ".", "-")}-dns-auth"
  description = "DNS authorization for ${var.domain}"
  domain      = var.domain
}

# Wildcard certificate covering *.domain and apex
resource "google_certificate_manager_certificate" "wildcard" {
  name        = "${replace(var.domain, ".", "-")}-wildcard"
  description = "Wildcard certificate for *.${var.domain}"

  managed {
    domains = [
      var.domain,
      "*.${var.domain}",
    ]
    dns_authorizations = [
      google_certificate_manager_dns_authorization.domain.id,
    ]
  }
}

# Certificate map
resource "google_certificate_manager_certificate_map" "main" {
  name        = "${replace(var.domain, ".", "-")}-certmap"
  description = "Certificate map for ${var.domain}"
}

# Certificate map entry — wildcard covers all subdomains
resource "google_certificate_manager_certificate_map_entry" "wildcard" {
  name         = "${replace(var.domain, ".", "-")}-wildcard-entry"
  map          = google_certificate_manager_certificate_map.main.name
  certificates = [google_certificate_manager_certificate.wildcard.id]
  hostname     = "*.${var.domain}"
}

# Certificate map entry — apex domain
resource "google_certificate_manager_certificate_map_entry" "apex" {
  name         = "${replace(var.domain, ".", "-")}-apex-entry"
  map          = google_certificate_manager_certificate_map.main.name
  certificates = [google_certificate_manager_certificate.wildcard.id]
  hostname     = var.domain
}

output "certmap_name" {
  description = "Certificate map name for Gateway annotation"
  value       = google_certificate_manager_certificate_map.main.name
}

output "dns_auth_record" {
  description = "CNAME record to create in Cloudflare for DNS validation"
  value = {
    name  = google_certificate_manager_dns_authorization.domain.dns_resource_record[0].name
    type  = google_certificate_manager_dns_authorization.domain.dns_resource_record[0].type
    value = google_certificate_manager_dns_authorization.domain.dns_resource_record[0].data
  }
}
