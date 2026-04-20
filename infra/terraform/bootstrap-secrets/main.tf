# Bootstrap Secrets — seeds initial Kubernetes secrets that must exist
# BEFORE ArgoCD sync waves deploy PostgreSQL, Keycloak, and Airflow.
#
# Once Vault + External Secrets Operator are running, ESO takes over
# rotation. The lifecycle ignore_changes blocks prevent Terraform from
# reverting secrets that ESO has since updated.
#
# Run AFTER: cluster (GKE must exist)
# Run BEFORE: argocd-bootstrap

terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  backend "gcs" {}
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

# ─── Providers ──────────────────────────────────────────────────────

data "google_client_config" "default" {}

data "google_container_cluster" "cluster" {
  name     = var.cluster_name
  location = var.zone
  project  = var.project_id
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "kubernetes" {
  host                   = "https://${data.google_container_cluster.cluster.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(data.google_container_cluster.cluster.master_auth[0].cluster_ca_certificate)
}

# ─── Random passwords ──────────────────────────────────────────────

resource "random_password" "postgres" {
  length  = 32
  special = false
}

resource "random_password" "keycloak_admin" {
  length  = 32
  special = false
}

resource "random_password" "keycloak_db" {
  length  = 32
  special = false
}

resource "random_password" "airflow_db" {
  length  = 32
  special = false
}

resource "random_password" "polaris_db" {
  length  = 32
  special = false
}

resource "random_password" "apicurio_db" {
  length  = 32
  special = false
}

# ─── Namespaces (ensure they exist) ────────────────────────────────

resource "kubernetes_namespace" "platform" {
  metadata {
    name = "platform"
    labels = {
      "app.kubernetes.io/part-of" = "openvelox"
    }
  }

  lifecycle {
    ignore_changes = [metadata[0].labels, metadata[0].annotations]
  }
}

resource "kubernetes_namespace" "batch" {
  metadata {
    name = "batch"
    labels = {
      "app.kubernetes.io/part-of" = "openvelox"
    }
  }

  lifecycle {
    ignore_changes = [metadata[0].labels, metadata[0].annotations]
  }
}

# ─── Kubernetes Secrets ─────────────────────────────────────────────

resource "kubernetes_secret" "postgres_secrets" {
  metadata {
    name      = "postgres-secrets"
    namespace = kubernetes_namespace.platform.metadata[0].name
  }

  data = {
    password = random_password.postgres.result
  }

  lifecycle {
    ignore_changes = [data]
  }
}

resource "kubernetes_secret" "keycloak_secrets" {
  metadata {
    name      = "keycloak-secrets"
    namespace = kubernetes_namespace.platform.metadata[0].name
  }

  data = {
    "admin-password" = random_password.keycloak_admin.result
    "db-password"    = random_password.keycloak_db.result
  }

  lifecycle {
    ignore_changes = [data]
  }
}

resource "kubernetes_secret" "airflow_secrets" {
  metadata {
    name      = "airflow-secrets"
    namespace = kubernetes_namespace.platform.metadata[0].name
  }

  data = {
    "db-password" = random_password.airflow_db.result
  }

  lifecycle {
    ignore_changes = [data]
  }
}

resource "kubernetes_secret" "polaris_secrets" {
  metadata {
    name      = "polaris-secrets"
    namespace = kubernetes_namespace.platform.metadata[0].name
  }

  data = {
    "db-password" = random_password.polaris_db.result
  }

  lifecycle {
    ignore_changes = [data]
  }
}

# Apicurio Registry reuses the platform Postgres with its own role + db
# (see infra/k8s/platform/postgresql/initdb-configmap.yaml). The secret lives
# in the platform namespace so the initdb script can read it at first boot;
# the kafka-namespace copy used by Apicurio itself is synced by ESO from
# Vault (see infra/k8s/security/external-secrets.yaml).
resource "kubernetes_secret" "apicurio_secrets" {
  metadata {
    name      = "apicurio-secrets"
    namespace = kubernetes_namespace.platform.metadata[0].name
  }

  data = {
    "db-password" = random_password.apicurio_db.result
  }

  lifecycle {
    ignore_changes = [data]
  }
}

resource "kubernetes_secret" "airflow_metadata" {
  metadata {
    name      = "airflow-metadata"
    namespace = kubernetes_namespace.batch.metadata[0].name
  }

  data = {
    connection = "postgresql://airflow:${random_password.airflow_db.result}@postgresql.platform.svc.cluster.local:5432/airflow"
  }

  lifecycle {
    ignore_changes = [data]
  }
}

# ─── Airflow OAuth + GitHub PAT placeholders ───────────────────────
# These secrets must exist before Airflow pods start (referenced by
# extraEnvFrom / extraEnv in Helm values). Real values are written
# post-keycloak-realm by scripts/post-deploy.sh or manually.

resource "kubernetes_secret" "airflow_oauth_keycloak" {
  metadata {
    name      = "airflow-oauth-keycloak"
    namespace = kubernetes_namespace.batch.metadata[0].name
  }

  data = {
    KEYCLOAK_CLIENT_ID     = "airflow"
    KEYCLOAK_CLIENT_SECRET = "REPLACE_ME"
  }

  lifecycle {
    ignore_changes = [data]
  }
}

resource "kubernetes_secret" "airflow_github_pat" {
  metadata {
    name      = "airflow-github-pat"
    namespace = kubernetes_namespace.batch.metadata[0].name
  }

  data = {
    conn_uri = "REPLACE_ME"
  }

  lifecycle {
    ignore_changes = [data]
  }
}

# ─── Outputs ────────────────────────────────────────────────────────

output "postgres_password_set" {
  value     = true
  sensitive = false
}

output "note" {
  value = "Bootstrap secrets created. Passwords are in Terraform state — do NOT share the state bucket publicly."
}
