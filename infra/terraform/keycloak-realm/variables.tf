variable "keycloak_url" {
  type        = string
  description = "Keycloak base URL (use kubectl port-forward or in-cluster URL)"
  default     = ""
}

variable "keycloak_admin_username" {
  type    = string
  default = "admin"
}

variable "keycloak_admin_password" {
  type      = string
  sensitive = true
}

variable "domain" {
  type        = string
  description = "Base domain for redirect URIs and web origins"
  default     = ""
}

variable "realm_name" {
  type    = string
  default = "openvelox"
}

variable "realm_display_name" {
  type    = string
  default = "OpenVelox"
}

variable "platform_admin_password" {
  type      = string
  sensitive = true
  default   = ""
}

variable "create_platform_admin" {
  type    = bool
  default = true
}

variable "airflow_client_secret" {
  type      = string
  sensitive = true
  default   = ""
  description = "Leave empty to auto-generate"
}

variable "argocd_client_secret" {
  type      = string
  sensitive = true
  default   = ""
  description = "Leave empty to auto-generate"
}

variable "grafana_client_secret" {
  type      = string
  sensitive = true
  default   = ""
  description = "Leave empty to auto-generate"
}

variable "kafka_broker_client_secret" {
  type        = string
  sensitive   = true
  default     = ""
  description = "Strimzi KeycloakAuthorizer client secret. Leave empty to auto-generate."
}

variable "kafka_flink_client_secret" {
  type        = string
  sensitive   = true
  default     = ""
  description = "Flink SASL OAUTHBEARER client secret. Leave empty to auto-generate."
}

variable "kafka_tfl_producer_client_secret" {
  type        = string
  sensitive   = true
  default     = ""
  description = "tfl-producer-strimzi SASL OAUTHBEARER client secret. Leave empty to auto-generate."
}

variable "openvelox_api_client_secret" {
  type        = string
  sensitive   = true
  default     = ""
  description = "FastAPI backend client-credentials secret (used for Trino JWT + Kafka OAUTHBEARER). Leave empty to auto-generate."
}
