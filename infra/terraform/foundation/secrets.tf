# Secret placeholders (values set via bootstrap.sh)
resource "google_secret_manager_secret" "tfl_api_key" {
  project   = var.project_id
  secret_id = "tfl-api-key"
  
  replication {
    auto {}
  }
  
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret" "gemini_api_key" {
  project   = var.project_id
  secret_id = "gemini-api-key"
  
  replication {
    auto {}
  }
  
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret" "postgres_password" {
  project   = var.project_id
  secret_id = "postgres-password"
  
  replication {
    auto {}
  }
  
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret" "keycloak_admin_password" {
  project   = var.project_id
  secret_id = "keycloak-admin-password"
  
  replication {
    auto {}
  }
  
  depends_on = [google_project_service.apis]
}
