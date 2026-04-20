terraform {
  required_version = ">= 1.9"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }

  backend "gcs" {}
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

variable "cloudflare_api_token" {
  type      = string
  sensitive = true
}

variable "cloudflare_zone_id" {
  type        = string
  description = "Cloudflare zone ID for the domain"
}

variable "domain" {
  type        = string
  description = "Base domain (e.g. example.com)"
}

variable "gateway_ip" {
  type        = string
  description = "GKE Gateway external IP address"
}

variable "acme_challenge_cname_target" {
  type        = string
  description = "CNAME target for _acme-challenge DNS validation"
  default     = ""
}

locals {
  subdomains = [
    "api",
    "auth",
    "orchestrator",
    "grafana",
    "query",
    "catalog",
    "catalog-console",
    "streaming",
    "stream-processing",
    "kafka",
    "argocd",
    "vault",
    "mlflow",
  ]
}

# Apex A record — Next.js frontend on the root domain
resource "cloudflare_dns_record" "apex" {
  zone_id = var.cloudflare_zone_id
  name    = "@"
  content = var.gateway_ip
  type    = "A"
  ttl     = 1
  proxied = true
}

# Proxied A records for each subdomain
resource "cloudflare_dns_record" "subdomains" {
  for_each = toset(local.subdomains)

  zone_id = var.cloudflare_zone_id
  name    = each.value
  content = var.gateway_ip
  type    = "A"
  ttl     = 1
  proxied = true
}

# ACME challenge CNAME for Certificate Manager DNS validation (DNS-only, not proxied)
resource "cloudflare_dns_record" "acme_challenge" {
  count = var.acme_challenge_cname_target != "" ? 1 : 0

  zone_id = var.cloudflare_zone_id
  name    = "_acme-challenge"
  content = var.acme_challenge_cname_target
  type    = "CNAME"
  ttl     = 120
  proxied = false
}

output "dns_records" {
  value = merge(
    { apex = var.domain },
    { for k, v in cloudflare_dns_record.subdomains : k => "${v.name}.${var.domain}" },
  )
}
