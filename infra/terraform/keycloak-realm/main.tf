# OpenVelox Keycloak Realm — full declarative config
# Follows the pattern from platform-auth/terraform/realms/meal-planner/main.tf
# Eliminates the missing-scopes bug that broke Airflow SSO when using realm JSON import

# ─────────────────────────────────────────────────────────────────────────────
# Realm
# ─────────────────────────────────────────────────────────────────────────────

resource "keycloak_realm" "openvelox" {
  realm        = var.realm_name
  enabled      = true
  display_name = var.realm_display_name

  login_with_email_allowed = true
  registration_allowed     = false
  reset_password_allowed   = true
  edit_username_allowed    = false
  login_theme              = "keycloak"

  access_token_lifespan                   = "5m"
  access_token_lifespan_for_implicit_flow = "15m"
  sso_session_idle_timeout                = "30m"
  sso_session_max_lifespan                = "10h"
  offline_session_idle_timeout            = "720h"
  access_code_lifespan                    = "1m"
  access_code_lifespan_user_action        = "5m"
  access_code_lifespan_login              = "30m"

  ssl_required                = "external"
  default_signature_algorithm = "RS256"

  security_defenses {
    headers {
      content_security_policy = "frame-src 'self'; frame-ancestors 'self' https://app.${var.domain} https://orchestrator.${var.domain} https://argocd.${var.domain} https://grafana.${var.domain}; object-src 'none';"
      x_content_type_options  = "nosniff"
      x_frame_options         = "SAMEORIGIN"
      x_xss_protection        = "1; mode=block"
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Built-in scopes (data sources — these always exist in Keycloak 26.x)
# Note: In Keycloak 26.x, "openid" is implicit and replaced by "basic" scope
# ─────────────────────────────────────────────────────────────────────────────

data "keycloak_openid_client_scope" "basic" {
  realm_id = keycloak_realm.openvelox.id
  name     = "basic"
}

data "keycloak_openid_client_scope" "profile" {
  realm_id = keycloak_realm.openvelox.id
  name     = "profile"
}

data "keycloak_openid_client_scope" "email" {
  realm_id = keycloak_realm.openvelox.id
  name     = "email"
}

data "keycloak_openid_client_scope" "roles" {
  realm_id = keycloak_realm.openvelox.id
  name     = "roles"
}



# Custom scope: groups (for ArgoCD RBAC)
resource "keycloak_openid_client_scope" "groups" {
  realm_id               = keycloak_realm.openvelox.id
  name                   = "groups"
  description            = "Group membership claim"
  include_in_token_scope = true
  consent_screen_text    = "View your group memberships"
}

resource "keycloak_openid_group_membership_protocol_mapper" "groups_mapper" {
  realm_id            = keycloak_realm.openvelox.id
  client_scope_id     = keycloak_openid_client_scope.groups.id
  name                = "groups"
  claim_name          = "groups"
  full_path           = false
  add_to_id_token     = true
  add_to_access_token = true
  add_to_userinfo     = true
}

# ─────────────────────────────────────────────────────────────────────────────
# Realm roles
# ─────────────────────────────────────────────────────────────────────────────

locals {
  realm_roles = {
    admin            = "Platform administrator — full access to all systems"
    developer        = "Developer — access to development tools and environments"
    operator         = "Operations — access to monitoring and operational tools"
    viewer           = "Viewer — read-only access across systems"
    airflow-admin    = "Airflow administrator — full DAG and user management"
    airflow-op       = "Airflow operator — manage connections, pools, variables"
    airflow-user     = "Airflow user — trigger DAGs and view logs"
    airflow-viewer   = "Airflow viewer — read-only access to DAGs"
    argocd-admin     = "ArgoCD administrator — full GitOps management"
    argocd-developer = "ArgoCD developer — sync and view applications"
    grafana-admin    = "Grafana administrator — full dashboard management"
    grafana-editor   = "Grafana editor — create and edit dashboards"
    grafana-viewer   = "Grafana viewer — read-only dashboard access"
    polaris-admin    = "Polaris administrator — full Iceberg catalog management"
    polaris-viewer   = "Polaris viewer — read-only Iceberg catalog access"
    # Kafka (Strimzi KeycloakAuthorizer) — mapped into scope permissions on
    # the kafka-broker client's Authorization Services.
    kafka-admin      = "Kafka administrator — full cluster + topic + group management"
    kafka-producer   = "Kafka producer — write + idempotent-write on topics, read on groups"
    kafka-consumer   = "Kafka consumer — read + describe on topics + groups"
    kafka-viewer     = "Kafka viewer — describe-only on topics, groups, and cluster"
    # streaming.${DOMAIN} + kafka.${DOMAIN} oauth2-proxy gate role — required
    # for any authenticated user to see the streaming / Kafka UIs at all.
    streaming-viewer = "Streaming viewer — gates access to streaming + kafka UIs"
    # apache-airflow-providers-keycloak: UMA role policies are named Allow-Admin, Allow-Viewer, …
    # and resolve realm roles with these exact names (not airflow-admin). See scripts/airflow_keycloak_authz_attach.py.
    "Admin"      = "Airflow Keycloak UMA — realm role for Allow-Admin policy"
    "Viewer"     = "Airflow Keycloak UMA — realm role for Allow-Viewer policy"
    "User"       = "Airflow Keycloak UMA — realm role for Allow-User policy"
    "Op"         = "Airflow Keycloak UMA — realm role for Allow-Op policy"
    "SuperAdmin" = "Airflow Keycloak UMA — realm role for Allow-SuperAdmin policy"
  }
}

resource "keycloak_role" "realm_roles" {
  for_each    = local.realm_roles
  realm_id    = keycloak_realm.openvelox.id
  name        = each.key
  description = each.value
}

# ─────────────────────────────────────────────────────────────────────────────
# Groups
# ─────────────────────────────────────────────────────────────────────────────

resource "keycloak_group" "platform_admins" {
  realm_id = keycloak_realm.openvelox.id
  name     = "platform-admins"
}

resource "keycloak_group_roles" "platform_admins_roles" {
  realm_id = keycloak_realm.openvelox.id
  group_id = keycloak_group.platform_admins.id
  role_ids = [
    keycloak_role.realm_roles["admin"].id,
    keycloak_role.realm_roles["airflow-admin"].id,
    keycloak_role.realm_roles["Admin"].id,
    keycloak_role.realm_roles["SuperAdmin"].id,
    keycloak_role.realm_roles["argocd-admin"].id,
    keycloak_role.realm_roles["grafana-admin"].id,
    keycloak_role.realm_roles["polaris-admin"].id,
    keycloak_role.realm_roles["kafka-admin"].id,
    keycloak_role.realm_roles["streaming-viewer"].id,
  ]
}

resource "keycloak_group" "developers" {
  realm_id = keycloak_realm.openvelox.id
  name     = "developers"
}

resource "keycloak_group_roles" "developers_roles" {
  realm_id = keycloak_realm.openvelox.id
  group_id = keycloak_group.developers.id
  role_ids = [
    keycloak_role.realm_roles["developer"].id,
    keycloak_role.realm_roles["airflow-user"].id,
    keycloak_role.realm_roles["User"].id,
    keycloak_role.realm_roles["Viewer"].id,
    keycloak_role.realm_roles["argocd-developer"].id,
    keycloak_role.realm_roles["grafana-editor"].id,
    keycloak_role.realm_roles["kafka-producer"].id,
    keycloak_role.realm_roles["kafka-consumer"].id,
    keycloak_role.realm_roles["streaming-viewer"].id,
  ]
}

resource "keycloak_group" "operators" {
  realm_id = keycloak_realm.openvelox.id
  name     = "operators"
}

resource "keycloak_group_roles" "operators_roles" {
  realm_id = keycloak_realm.openvelox.id
  group_id = keycloak_group.operators.id
  role_ids = [
    keycloak_role.realm_roles["operator"].id,
    keycloak_role.realm_roles["airflow-op"].id,
    keycloak_role.realm_roles["Op"].id,
    keycloak_role.realm_roles["Viewer"].id,
    keycloak_role.realm_roles["grafana-editor"].id,
    keycloak_role.realm_roles["kafka-consumer"].id,
    keycloak_role.realm_roles["streaming-viewer"].id,
  ]
}

resource "keycloak_group" "viewers" {
  realm_id = keycloak_realm.openvelox.id
  name     = "viewers"
}

resource "keycloak_group_roles" "viewers_roles" {
  realm_id = keycloak_realm.openvelox.id
  group_id = keycloak_group.viewers.id
  role_ids = [
    keycloak_role.realm_roles["viewer"].id,
    keycloak_role.realm_roles["airflow-viewer"].id,
    keycloak_role.realm_roles["Viewer"].id,
    keycloak_role.realm_roles["grafana-viewer"].id,
    keycloak_role.realm_roles["polaris-viewer"].id,
    keycloak_role.realm_roles["kafka-viewer"].id,
    keycloak_role.realm_roles["streaming-viewer"].id,
  ]
}

# ─────────────────────────────────────────────────────────────────────────────
# OIDC Clients
# ─────────────────────────────────────────────────────────────────────────────

# --- Airflow ---
resource "keycloak_openid_client" "airflow" {
  realm_id    = keycloak_realm.openvelox.id
  client_id   = "airflow"
  name        = "Apache Airflow"
  enabled     = true
  description = "Airflow workflow orchestration UI"

  access_type                  = "CONFIDENTIAL"
  standard_flow_enabled        = true
  direct_access_grants_enabled = true
  service_accounts_enabled     = true

  authorization {
    policy_enforcement_mode = "ENFORCING"
  }

  client_secret = var.airflow_client_secret != "" ? var.airflow_client_secret : null

  root_url = "https://orchestrator.${var.domain}"
  valid_redirect_uris = [
    "https://orchestrator.${var.domain}/*",
    # FAB / legacy callback
    "https://orchestrator.${var.domain}/oauth-authorized/keycloak",
    # Airflow 3 + KeycloakAuthManager (see apache-airflow-providers-keycloak)
    "https://orchestrator.${var.domain}/auth/oauth-authorized/keycloak",
    "https://orchestrator.${var.domain}/auth/login_callback",
    # HTTP variant — Airflow behind GKE Gateway may generate http:// redirect_uri
    # before proxy fix takes effect. Cloudflare enforces HTTPS on the browser side.
    "http://orchestrator.${var.domain}/auth/login_callback",
  ]
  # Keycloak 18+ OIDC RP-initiated logout validates post_logout_redirect_uri separately.
  # "+" mirrors valid_redirect_uris but those are mostly https://…/* ; Airflow still emits
  # http://…/auth/logout_callback behind the gateway unless proxy/proto is perfect — allow both.
  valid_post_logout_redirect_uris = [
    "+",
    "http://orchestrator.${var.domain}/auth/logout_callback",
    "https://orchestrator.${var.domain}/auth/logout_callback",
  ]
  web_origins = ["https://orchestrator.${var.domain}"]
}

resource "keycloak_openid_client_default_scopes" "airflow" {
  realm_id  = keycloak_realm.openvelox.id
  client_id = keycloak_openid_client.airflow.id
  default_scopes = [
    data.keycloak_openid_client_scope.basic.name,
    data.keycloak_openid_client_scope.profile.name,
    data.keycloak_openid_client_scope.email.name,
    data.keycloak_openid_client_scope.roles.name,
  ]
}

resource "keycloak_openid_user_realm_role_protocol_mapper" "airflow_roles" {
  realm_id            = keycloak_realm.openvelox.id
  client_id           = keycloak_openid_client.airflow.id
  name                = "realm-roles"
  claim_name          = "roles"
  multivalued         = true
  add_to_id_token     = true
  add_to_access_token = true
  add_to_userinfo     = true
}

# --- ArgoCD ---
resource "keycloak_openid_client" "argocd" {
  realm_id    = keycloak_realm.openvelox.id
  client_id   = "argocd"
  name        = "ArgoCD GitOps"
  enabled     = true
  description = "ArgoCD continuous deployment UI"

  access_type                  = "CONFIDENTIAL"
  standard_flow_enabled        = true
  direct_access_grants_enabled = false
  service_accounts_enabled     = false

  client_secret = var.argocd_client_secret != "" ? var.argocd_client_secret : null

  root_url = "https://argocd.${var.domain}"
  valid_redirect_uris = [
    "https://argocd.${var.domain}/auth/callback",
  ]
  web_origins = ["https://argocd.${var.domain}"]
}

resource "keycloak_openid_client_default_scopes" "argocd" {
  realm_id  = keycloak_realm.openvelox.id
  client_id = keycloak_openid_client.argocd.id
  default_scopes = [
    data.keycloak_openid_client_scope.basic.name,
    data.keycloak_openid_client_scope.profile.name,
    data.keycloak_openid_client_scope.email.name,
    keycloak_openid_client_scope.groups.name,
  ]
}

resource "keycloak_openid_group_membership_protocol_mapper" "argocd_groups" {
  realm_id            = keycloak_realm.openvelox.id
  client_id           = keycloak_openid_client.argocd.id
  name                = "groups"
  claim_name          = "groups"
  full_path           = false
  add_to_id_token     = true
  add_to_access_token = true
  add_to_userinfo     = true
}

# --- Grafana ---
resource "keycloak_openid_client" "grafana" {
  realm_id    = keycloak_realm.openvelox.id
  client_id   = "grafana"
  name        = "Grafana Monitoring"
  enabled     = true
  description = "Grafana observability dashboard"

  access_type                  = "CONFIDENTIAL"
  standard_flow_enabled        = true
  direct_access_grants_enabled = false
  service_accounts_enabled     = false

  client_secret = var.grafana_client_secret != "" ? var.grafana_client_secret : null

  root_url = "https://grafana.${var.domain}"
  valid_redirect_uris = [
    "https://grafana.${var.domain}/login/generic_oauth",
  ]
  web_origins = ["https://grafana.${var.domain}"]
}

resource "keycloak_openid_client_default_scopes" "grafana" {
  realm_id  = keycloak_realm.openvelox.id
  client_id = keycloak_openid_client.grafana.id
  default_scopes = [
    data.keycloak_openid_client_scope.basic.name,
    data.keycloak_openid_client_scope.profile.name,
    data.keycloak_openid_client_scope.email.name,
    data.keycloak_openid_client_scope.roles.name,
  ]
}

resource "keycloak_openid_user_realm_role_protocol_mapper" "grafana_roles" {
  realm_id            = keycloak_realm.openvelox.id
  client_id           = keycloak_openid_client.grafana.id
  name                = "realm-roles"
  claim_name          = "roles"
  multivalued         = true
  add_to_id_token     = true
  add_to_access_token = true
  add_to_userinfo     = true
}

# --- OpenVelox Web (public SPA) ---
resource "keycloak_openid_client" "web" {
  realm_id    = keycloak_realm.openvelox.id
  client_id   = "openvelox-web"
  name        = "OpenVelox Web Application"
  enabled     = true
  description = "Next.js frontend application"

  access_type                  = "PUBLIC"
  standard_flow_enabled        = true
  direct_access_grants_enabled = false

  pkce_code_challenge_method = "S256"

  root_url = "https://app.${var.domain}"
  valid_redirect_uris = [
    "https://app.${var.domain}/*",
    "https://app.${var.domain}/api/auth/callback/keycloak",
    "http://localhost:3000/*",
    "http://localhost:3000/api/auth/callback/keycloak",
  ]
  web_origins = [
    "https://app.${var.domain}",
    "http://localhost:3000",
  ]
}

resource "keycloak_openid_client_default_scopes" "web" {
  realm_id  = keycloak_realm.openvelox.id
  client_id = keycloak_openid_client.web.id
  default_scopes = [
    data.keycloak_openid_client_scope.basic.name,
    data.keycloak_openid_client_scope.profile.name,
    data.keycloak_openid_client_scope.email.name,
    data.keycloak_openid_client_scope.roles.name,
  ]
}

# --- OpenVelox API (dual-mode: bearer-only + service-account) ---
# The FastAPI backend plays two OAuth roles:
#   1. It validates JWTs minted for *end users* by other clients (bearer-only
#      behaviour — still works in CONFIDENTIAL mode since Keycloak lets any
#      client validate tokens from any other client in the same realm).
#   2. It mints its own service-account token via the client-credentials flow
#      to call downstream Trino (JWT auth) and Kafka (SASL OAUTHBEARER). The
#      same token satisfies both because the audience protocol mappers below
#      add `trino` and `kafka-broker` to `aud`.
#
# A single client keeps the secret surface small (one Vault entry, one
# ExternalSecret) and ensures rotation rotates both downstream paths in
# lockstep.
resource "keycloak_openid_client" "api" {
  realm_id    = keycloak_realm.openvelox.id
  client_id   = "openvelox-api"
  name        = "OpenVelox Backend API"
  enabled     = true
  description = "FastAPI backend — JWT validation + downstream client-credentials"

  access_type                  = "CONFIDENTIAL"
  standard_flow_enabled        = false
  direct_access_grants_enabled = false
  service_accounts_enabled     = true

  client_secret = var.openvelox_api_client_secret != "" ? var.openvelox_api_client_secret : null
}

resource "keycloak_openid_client_default_scopes" "api" {
  realm_id  = keycloak_realm.openvelox.id
  client_id = keycloak_openid_client.api.id
  default_scopes = [
    data.keycloak_openid_client_scope.basic.name,
    data.keycloak_openid_client_scope.profile.name,
    data.keycloak_openid_client_scope.roles.name,
  ]
}

# Grant the API service account permission to consume every Kafka topic the
# KeycloakAuthorizer guards — matches the pattern used by `kafka_flink` (also
# a consumer) but without the producer role, since the API is read-only for
# lakehouse/stream data.
resource "keycloak_openid_client_service_account_realm_role" "api_kafka_consumer" {
  realm_id                = keycloak_realm.openvelox.id
  service_account_user_id = keycloak_openid_client.api.service_account_user_id
  role                    = keycloak_role.realm_roles["kafka-consumer"].name
}

# Audience mapper — Kafka broker. Strimzi's JwtAuthorizer checks that incoming
# tokens carry `aud=kafka-broker`. Without this mapper the broker would reject
# the API's client-credentials token.
resource "keycloak_openid_audience_protocol_mapper" "api_kafka_audience" {
  realm_id                 = keycloak_realm.openvelox.id
  client_id                = keycloak_openid_client.api.id
  name                     = "audience-kafka-broker"
  included_client_audience = keycloak_openid_client.kafka_broker.client_id
  add_to_id_token          = false
  add_to_access_token      = true
}

# Audience mapper — Trino coordinator. The new `jwt` authenticator in
# helm/trino/values-gke.yaml validates `aud=trino`.
resource "keycloak_openid_audience_protocol_mapper" "api_trino_audience" {
  realm_id                 = keycloak_realm.openvelox.id
  client_id                = keycloak_openid_client.api.id
  name                     = "audience-trino"
  included_client_audience = keycloak_openid_client.trino.client_id
  add_to_id_token          = false
  add_to_access_token      = true
}


# --- MLflow ---
resource "keycloak_openid_client" "mlflow" {
  realm_id    = keycloak_realm.openvelox.id
  client_id   = "mlflow"
  name        = "MLflow Tracking"
  enabled     = true
  description = "MLflow experiment tracking and model registry"

  access_type                  = "CONFIDENTIAL"
  standard_flow_enabled        = true
  direct_access_grants_enabled = false
  service_accounts_enabled     = false

  root_url = "https://mlflow.${var.domain}"
  valid_redirect_uris = [
    "https://mlflow.${var.domain}/*",
    "https://mlflow.${var.domain}/oauth2/callback",
  ]
  web_origins = ["https://mlflow.${var.domain}"]
}

resource "keycloak_openid_client_default_scopes" "mlflow" {
  realm_id  = keycloak_realm.openvelox.id
  client_id = keycloak_openid_client.mlflow.id
  default_scopes = [
    data.keycloak_openid_client_scope.basic.name,
    data.keycloak_openid_client_scope.profile.name,
    data.keycloak_openid_client_scope.email.name,
  ]
}

# --- Flink UI (OAuth2 Proxy) ---
resource "keycloak_openid_client" "flink_ui" {
  realm_id  = keycloak_realm.openvelox.id
  client_id = "flink-ui"
  name      = "Flink Dashboard"
  enabled   = true

  access_type                  = "CONFIDENTIAL"
  standard_flow_enabled        = true
  direct_access_grants_enabled = false

  valid_redirect_uris = ["https://stream-processing.${var.domain}/oauth2/callback"]
  web_origins         = ["https://stream-processing.${var.domain}"]
}

resource "keycloak_openid_client_default_scopes" "flink_ui" {
  realm_id  = keycloak_realm.openvelox.id
  client_id = keycloak_openid_client.flink_ui.id
  default_scopes = [
    data.keycloak_openid_client_scope.basic.name,
    data.keycloak_openid_client_scope.profile.name,
    data.keycloak_openid_client_scope.email.name,
    # `roles` scope's built-in "realm roles" mapper emits `realm_access.roles`
    # into the ID token; oauth2-proxy uses it to enforce --allowed-role.
    data.keycloak_openid_client_scope.roles.name,
  ]
}

# Keycloak doesn't auto-populate the `aud` claim with the client_id; it only
# sets `azp`. oauth2-proxy (and most OIDC relying parties) reject an ID token
# whose `aud` doesn't include their client_id with
# `audience claims [aud] do not exist in claims`, which surfaces as a 500 on
# `/oauth2/callback`. This mapper adds the client_id to `aud` explicitly.
resource "keycloak_openid_audience_protocol_mapper" "flink_ui_aud" {
  realm_id                 = keycloak_realm.openvelox.id
  client_id                = keycloak_openid_client.flink_ui.id
  name                     = "audience-flink-ui"
  included_client_audience = keycloak_openid_client.flink_ui.client_id
  add_to_id_token          = true
  add_to_access_token      = true
}

# --- Trino (native OAuth2 — coordinator UI + CLI + JDBC) ---
# Trino coordinator validates Keycloak-issued JWT access tokens directly
# (no oauth2-proxy). See helm/trino/values-gke.yaml for the authenticator
# configuration.
resource "keycloak_openid_client" "trino" {
  realm_id    = keycloak_realm.openvelox.id
  client_id   = "trino"
  name        = "Trino Query Engine"
  enabled     = true
  description = "Trino coordinator UI, CLI, and JDBC — Keycloak OAuth2"

  access_type                  = "CONFIDENTIAL"
  standard_flow_enabled        = true # browser UI + CLI --external-authentication
  direct_access_grants_enabled = true # optional, for programmatic ROPC testing
  service_accounts_enabled     = true # client-credentials for headless JDBC / Airflow

  root_url = "https://query.${var.domain}"
  valid_redirect_uris = [
    "https://query.${var.domain}/oauth2/callback",
    "https://query.${var.domain}/ui/",
    "https://query.${var.domain}/ui/*",
  ]
  valid_post_logout_redirect_uris = [
    "https://query.${var.domain}/*",
  ]
  web_origins = ["https://query.${var.domain}"]
}

resource "keycloak_openid_client_default_scopes" "trino" {
  realm_id  = keycloak_realm.openvelox.id
  client_id = keycloak_openid_client.trino.id
  default_scopes = [
    data.keycloak_openid_client_scope.basic.name,
    data.keycloak_openid_client_scope.profile.name,
    data.keycloak_openid_client_scope.email.name,
    data.keycloak_openid_client_scope.roles.name,
  ]
}

resource "keycloak_openid_user_realm_role_protocol_mapper" "trino_roles" {
  realm_id            = keycloak_realm.openvelox.id
  client_id           = keycloak_openid_client.trino.id
  name                = "realm-roles"
  claim_name          = "roles"
  multivalued         = true
  add_to_id_token     = true
  add_to_access_token = true
  add_to_userinfo     = true
}

# --- Polaris Console (public SPA, PKCE) ---
# Upstream apache/polaris-console talks to the Polaris REST API at
# catalog.${var.domain} on behalf of the logged-in user; it is a browser-only
# SPA so the access_type is PUBLIC + PKCE (no client secret to leak).
resource "keycloak_openid_client" "polaris_console" {
  realm_id    = keycloak_realm.openvelox.id
  client_id   = "polaris-console"
  name        = "Polaris Console"
  enabled     = true
  description = "Apache Polaris browser console (Iceberg catalog UI)"

  access_type                  = "PUBLIC"
  standard_flow_enabled        = true
  direct_access_grants_enabled = false

  pkce_code_challenge_method = "S256"

  root_url = "https://catalog-console.${var.domain}"
  valid_redirect_uris = [
    "https://catalog-console.${var.domain}/auth/callback",
    "https://catalog-console.${var.domain}/*",
  ]
  valid_post_logout_redirect_uris = [
    "https://catalog-console.${var.domain}/*",
  ]
  web_origins = ["https://catalog-console.${var.domain}"]
}

resource "keycloak_openid_client_default_scopes" "polaris_console" {
  realm_id  = keycloak_realm.openvelox.id
  client_id = keycloak_openid_client.polaris_console.id
  default_scopes = [
    data.keycloak_openid_client_scope.basic.name,
    data.keycloak_openid_client_scope.profile.name,
    data.keycloak_openid_client_scope.email.name,
    data.keycloak_openid_client_scope.roles.name,
  ]
}

resource "keycloak_openid_user_realm_role_protocol_mapper" "polaris_console_roles" {
  realm_id            = keycloak_realm.openvelox.id
  client_id           = keycloak_openid_client.polaris_console.id
  name                = "realm-roles"
  claim_name          = "roles"
  multivalued         = true
  add_to_id_token     = true
  add_to_access_token = true
  add_to_userinfo     = true
}

# --- Polaris Server (bearer-only — JWT audience target) ---
# The Polaris REST catalog validates Keycloak-issued JWTs server-side
# (Quarkus OIDC). It acts as an OAuth2 resource server with no interactive
# flow: it simply verifies signatures against Keycloak's JWKS and expects
# `polaris-server` to appear in the token's `aud` claim.
#
# The audience is injected by an audience-protocol-mapper on the
# polaris-console client below, mirroring the flink-ui pattern.
resource "keycloak_openid_client" "polaris_server" {
  realm_id    = keycloak_realm.openvelox.id
  client_id   = "polaris-server"
  name        = "Polaris Server"
  enabled     = true
  description = "Apache Polaris REST catalog — JWT validation audience (bearer-only)"

  access_type                  = "BEARER-ONLY"
  standard_flow_enabled        = false
  direct_access_grants_enabled = false
  service_accounts_enabled     = false
}

# Audience — inject `polaris-server` into `aud` so Polaris can match
# `quarkus.oidc.client-id=polaris-server` during JWT validation.
resource "keycloak_openid_audience_protocol_mapper" "polaris_console_aud" {
  realm_id                 = keycloak_realm.openvelox.id
  client_id                = keycloak_openid_client.polaris_console.id
  name                     = "audience-polaris-server"
  included_client_audience = keycloak_openid_client.polaris_server.client_id
  add_to_id_token          = true
  add_to_access_token      = true
}

# Polaris principal id — numeric int64 carried as `polaris.principal_id`.
# Polaris's default PrincipalMapper requires both id and name claims to match
# a pre-existing Principal row in `polaris_schema.entities`. Because Polaris
# auto-assigns the id on CREATE and doesn't expose it via the public API,
# scripts/polaris-bootstrap-human-principals.sh reads the assigned id from
# Postgres and writes it onto the Keycloak user as the `polaris_principal_id`
# attribute — this mapper then projects it into the JWT as a JSON long.
#
# The Terraform `keycloak_user.platform_admin` resource initialises the
# attribute with a placeholder and uses `lifecycle.ignore_changes` so the
# bootstrap-assigned value isn't overwritten by subsequent `terraform apply`.
resource "keycloak_openid_user_attribute_protocol_mapper" "polaris_console_principal_id" {
  realm_id            = keycloak_realm.openvelox.id
  client_id           = keycloak_openid_client.polaris_console.id
  name                = "polaris-principal-id"
  user_attribute      = "polaris_principal_id"
  claim_name          = "polaris.principal_id"
  claim_value_type    = "long"
  add_to_id_token     = true
  add_to_access_token = true
  add_to_userinfo     = true
}

# Polaris principal name — Keycloak username projected as
# `polaris.principal_name` for Polaris's name-claim-path matcher.
resource "keycloak_openid_user_property_protocol_mapper" "polaris_console_principal_name" {
  realm_id            = keycloak_realm.openvelox.id
  client_id           = keycloak_openid_client.polaris_console.id
  name                = "polaris-principal-name"
  user_property       = "username"
  claim_name          = "polaris.principal_name"
  claim_value_type    = "String"
  add_to_id_token     = true
  add_to_access_token = true
  add_to_userinfo     = true
}

# Polaris roles — emit all realm roles under the nested `polaris.roles`
# claim. The Polaris-side `principal-roles-mapper` filters this to
# `polaris-.*` and rewrites `polaris-admin` → `PRINCIPAL_ROLE:polaris_admin`
# (see helm/polaris/values-gke.tmpl.yaml advancedConfig block).
resource "keycloak_openid_user_realm_role_protocol_mapper" "polaris_console_polaris_roles" {
  realm_id            = keycloak_realm.openvelox.id
  client_id           = keycloak_openid_client.polaris_console.id
  name                = "polaris-roles"
  claim_name          = "polaris.roles"
  multivalued         = true
  add_to_id_token     = true
  add_to_access_token = true
  add_to_userinfo     = true
}

# ─────────────────────────────────────────────────────────────────────────────
# Platform admin user
# ─────────────────────────────────────────────────────────────────────────────

resource "keycloak_user" "platform_admin" {
  count    = var.create_platform_admin ? 1 : 0
  realm_id = keycloak_realm.openvelox.id
  username = "platform-admin"
  enabled  = true

  email          = "admin@${var.domain}"
  email_verified = true
  first_name     = "Platform"
  last_name      = "Admin"

  initial_password {
    value     = var.platform_admin_password
    temporary = true
  }

  # Placeholder — scripts/polaris-bootstrap-human-principals.sh overwrites
  # this with the numeric id Polaris assigned to the matching Principal
  # row in polaris_schema.entities. The ignore_changes stanza below keeps
  # `terraform apply` from clobbering that runtime-updated value.
  attributes = {
    polaris_principal_id = "0"
  }

  lifecycle {
    ignore_changes = [attributes]
  }
}

resource "keycloak_group_memberships" "platform_admin_groups" {
  count    = var.create_platform_admin ? 1 : 0
  realm_id = keycloak_realm.openvelox.id
  group_id = keycloak_group.platform_admins.id
  members  = [keycloak_user.platform_admin[0].username]
}

# ─────────────────────────────────────────────────────────────────────────────
# Kafka (Strimzi + kafka-ui + Flink + TFL producer)
#
# Three client shapes:
#   1. kafka-broker         — CONFIDENTIAL, hosts Authorization Services that
#                             Strimzi's KeycloakAuthorizer queries over UMA.
#                             Also the audience target for every Kafka JWT.
#   2. kafka-ui             — PUBLIC + PKCE, browser front-end (kafbat).
#   3. kafka-flink /
#      kafka-tfl-producer   — CONFIDENTIAL + service_accounts_enabled, run
#                             client-credentials from inside the cluster.
#
# See docs/GOVERNANCE_IDENTITY_AND_ACCESS.md §6 for the authz model.
# ─────────────────────────────────────────────────────────────────────────────

# --- Kafka broker (bearer-audience + Authorization Services host) ---
resource "keycloak_openid_client" "kafka_broker" {
  realm_id    = keycloak_realm.openvelox.id
  client_id   = "kafka-broker"
  name        = "Kafka Broker (Strimzi)"
  enabled     = true
  description = "Strimzi Kafka broker — JWT audience + KeycloakAuthorizer authz services host"

  access_type                  = "CONFIDENTIAL"
  standard_flow_enabled        = false
  direct_access_grants_enabled = false
  # KeycloakAuthorizer authenticates to the token endpoint using the broker's
  # own client_credentials to request UMA permissions on behalf of incoming
  # principals.
  service_accounts_enabled = true

  client_secret = var.kafka_broker_client_secret != "" ? var.kafka_broker_client_secret : null

  authorization {
    policy_enforcement_mode = "ENFORCING"
    decision_strategy       = "AFFIRMATIVE"
  }
}

locals {
  # Kafka operation scopes exposed by Strimzi's KeycloakAuthorizer. Names
  # must match the Kafka ACL operations verbatim — the authorizer requests
  # these scopes at the UMA endpoint using the operation name.
  kafka_authz_scopes = [
    "Describe",
    "Read",
    "Write",
    "Create",
    "Alter",
    "Delete",
    "ClusterAction",
    "DescribeConfigs",
    "AlterConfigs",
    "IdempotentWrite",
  ]
}

resource "keycloak_openid_client_authorization_scope" "kafka" {
  for_each           = toset(local.kafka_authz_scopes)
  realm_id           = keycloak_realm.openvelox.id
  resource_server_id = keycloak_openid_client.kafka_broker.resource_server_id
  name               = each.key
}

# Cluster resource — gate the full Kafka ops set that map to Cluster
# in KIP-320: `Describe` (AdminClient describeCluster / kafka-ui's
# "is security enabled?" probe), `ClusterAction` (inter-broker +
# controller), and *Configs for dynamic config changes.
resource "keycloak_openid_client_authorization_resource" "kafka_cluster" {
  realm_id           = keycloak_realm.openvelox.id
  resource_server_id = keycloak_openid_client.kafka_broker.resource_server_id
  name               = "kafka-cluster:openvelox,Cluster:*"
  type               = "Cluster"
  scopes = [
    "Describe",
    "ClusterAction",
    "DescribeConfigs",
    "AlterConfigs",
    "Alter",
    "Create",
  ]

  depends_on = [keycloak_openid_client_authorization_scope.kafka]
}

# All topics wildcard — covers any topic not specifically scoped below.
resource "keycloak_openid_client_authorization_resource" "kafka_topic_all" {
  realm_id           = keycloak_realm.openvelox.id
  resource_server_id = keycloak_openid_client.kafka_broker.resource_server_id
  name               = "kafka-cluster:openvelox,Topic:*"
  type               = "Topic"
  scopes = [
    "Describe",
    "Read",
    "Write",
    "Create",
    "Alter",
    "Delete",
    "DescribeConfigs",
    "AlterConfigs",
    "IdempotentWrite",
  ]

  depends_on = [keycloak_openid_client_authorization_scope.kafka]
}

# tfl.* topic family — used by both the A/B tfl-producer-strimzi CronJob
# and Flink. Kept as an explicit narrower resource so a future PR can
# lock producer permissions down to `tfl.*` only.
resource "keycloak_openid_client_authorization_resource" "kafka_topic_tfl" {
  realm_id           = keycloak_realm.openvelox.id
  resource_server_id = keycloak_openid_client.kafka_broker.resource_server_id
  name               = "kafka-cluster:openvelox,Topic:tfl.*"
  type               = "Topic"
  scopes = [
    "Describe",
    "Read",
    "Write",
    "Create",
    "Alter",
    "DescribeConfigs",
    "IdempotentWrite",
  ]

  depends_on = [keycloak_openid_client_authorization_scope.kafka]
}

# Consumer groups wildcard.
resource "keycloak_openid_client_authorization_resource" "kafka_group_all" {
  realm_id           = keycloak_realm.openvelox.id
  resource_server_id = keycloak_openid_client.kafka_broker.resource_server_id
  name               = "kafka-cluster:openvelox,Group:*"
  type               = "Group"
  scopes = [
    "Read",
    "Describe",
    "Delete",
  ]

  depends_on = [keycloak_openid_client_authorization_scope.kafka]
}

# ── Role policies (one per Kafka realm role) ──
resource "keycloak_openid_client_role_policy" "kafka_admin" {
  realm_id           = keycloak_realm.openvelox.id
  resource_server_id = keycloak_openid_client.kafka_broker.resource_server_id
  name               = "kafka-admin-policy"
  logic              = "POSITIVE"
  decision_strategy  = "UNANIMOUS"
  type               = "role"

  role {
    id       = keycloak_role.realm_roles["kafka-admin"].id
    required = true
  }
}

resource "keycloak_openid_client_role_policy" "kafka_producer" {
  realm_id           = keycloak_realm.openvelox.id
  resource_server_id = keycloak_openid_client.kafka_broker.resource_server_id
  name               = "kafka-producer-policy"
  logic              = "POSITIVE"
  decision_strategy  = "UNANIMOUS"
  type               = "role"

  role {
    id       = keycloak_role.realm_roles["kafka-producer"].id
    required = true
  }
}

resource "keycloak_openid_client_role_policy" "kafka_consumer" {
  realm_id           = keycloak_realm.openvelox.id
  resource_server_id = keycloak_openid_client.kafka_broker.resource_server_id
  name               = "kafka-consumer-policy"
  logic              = "POSITIVE"
  decision_strategy  = "UNANIMOUS"
  type               = "role"

  role {
    id       = keycloak_role.realm_roles["kafka-consumer"].id
    required = true
  }
}

resource "keycloak_openid_client_role_policy" "kafka_viewer" {
  realm_id           = keycloak_realm.openvelox.id
  resource_server_id = keycloak_openid_client.kafka_broker.resource_server_id
  name               = "kafka-viewer-policy"
  logic              = "POSITIVE"
  decision_strategy  = "UNANIMOUS"
  type               = "role"

  role {
    id       = keycloak_role.realm_roles["kafka-viewer"].id
    required = true
  }
}

# ── Permissions: bind (resources × scopes × policies) ──
# kafka-admin: everything, everywhere.
resource "keycloak_openid_client_authorization_permission" "kafka_admin_all" {
  realm_id           = keycloak_realm.openvelox.id
  resource_server_id = keycloak_openid_client.kafka_broker.resource_server_id
  name               = "kafka-admin-all"
  description        = "kafka-admin → all scopes on all resources"
  decision_strategy  = "AFFIRMATIVE"
  policies           = [keycloak_openid_client_role_policy.kafka_admin.id]
  resources = [
    keycloak_openid_client_authorization_resource.kafka_cluster.id,
    keycloak_openid_client_authorization_resource.kafka_topic_all.id,
    keycloak_openid_client_authorization_resource.kafka_topic_tfl.id,
    keycloak_openid_client_authorization_resource.kafka_group_all.id,
  ]
  scopes = [
    for s in local.kafka_authz_scopes :
    keycloak_openid_client_authorization_scope.kafka[s].id
  ]
}

# kafka-producer: write-path on topics (including tfl.*), read on groups
# (producers participate in transactional state), describe on cluster.
resource "keycloak_openid_client_authorization_permission" "kafka_producer_topics" {
  realm_id           = keycloak_realm.openvelox.id
  resource_server_id = keycloak_openid_client.kafka_broker.resource_server_id
  name               = "kafka-producer-topics"
  description        = "kafka-producer → write/idempotent-write/describe/read on topics"
  decision_strategy  = "AFFIRMATIVE"
  policies           = [keycloak_openid_client_role_policy.kafka_producer.id]
  resources = [
    keycloak_openid_client_authorization_resource.kafka_topic_all.id,
    keycloak_openid_client_authorization_resource.kafka_topic_tfl.id,
  ]
  scopes = [
    keycloak_openid_client_authorization_scope.kafka["Describe"].id,
    keycloak_openid_client_authorization_scope.kafka["Read"].id,
    keycloak_openid_client_authorization_scope.kafka["Write"].id,
    keycloak_openid_client_authorization_scope.kafka["Create"].id,
    keycloak_openid_client_authorization_scope.kafka["IdempotentWrite"].id,
  ]
}

resource "keycloak_openid_client_authorization_permission" "kafka_producer_groups" {
  realm_id           = keycloak_realm.openvelox.id
  resource_server_id = keycloak_openid_client.kafka_broker.resource_server_id
  name               = "kafka-producer-groups"
  description        = "kafka-producer → read on groups (txn state)"
  decision_strategy  = "AFFIRMATIVE"
  policies           = [keycloak_openid_client_role_policy.kafka_producer.id]
  resources = [
    keycloak_openid_client_authorization_resource.kafka_group_all.id,
  ]
  scopes = [
    keycloak_openid_client_authorization_scope.kafka["Describe"].id,
    keycloak_openid_client_authorization_scope.kafka["Read"].id,
  ]
}

# kafka-consumer: read/describe on topics and groups.
resource "keycloak_openid_client_authorization_permission" "kafka_consumer_all" {
  realm_id           = keycloak_realm.openvelox.id
  resource_server_id = keycloak_openid_client.kafka_broker.resource_server_id
  name               = "kafka-consumer-all"
  description        = "kafka-consumer → read/describe on topics + groups"
  decision_strategy  = "AFFIRMATIVE"
  policies           = [keycloak_openid_client_role_policy.kafka_consumer.id]
  resources = [
    keycloak_openid_client_authorization_resource.kafka_topic_all.id,
    keycloak_openid_client_authorization_resource.kafka_topic_tfl.id,
    keycloak_openid_client_authorization_resource.kafka_group_all.id,
  ]
  scopes = [
    keycloak_openid_client_authorization_scope.kafka["Describe"].id,
    keycloak_openid_client_authorization_scope.kafka["Read"].id,
  ]
}

# kafka-viewer: describe-only — list topics, see configs, no data.
resource "keycloak_openid_client_authorization_permission" "kafka_viewer_all" {
  realm_id           = keycloak_realm.openvelox.id
  resource_server_id = keycloak_openid_client.kafka_broker.resource_server_id
  name               = "kafka-viewer-all"
  description        = "kafka-viewer → describe-only on topics, groups, cluster"
  decision_strategy  = "AFFIRMATIVE"
  policies           = [keycloak_openid_client_role_policy.kafka_viewer.id]
  resources = [
    keycloak_openid_client_authorization_resource.kafka_cluster.id,
    keycloak_openid_client_authorization_resource.kafka_topic_all.id,
    keycloak_openid_client_authorization_resource.kafka_topic_tfl.id,
    keycloak_openid_client_authorization_resource.kafka_group_all.id,
  ]
  scopes = [
    keycloak_openid_client_authorization_scope.kafka["Describe"].id,
    keycloak_openid_client_authorization_scope.kafka["DescribeConfigs"].id,
  ]
}

# --- kafka-ui (kafbat) — confidential client ---
#
# kafbat is a backend Spring Boot service, not a SPA. The browser
# authorisation-code flow terminates on the pod (not the browser), and
# the same pod also opens a server-side SASL OAUTHBEARER session to the
# broker using `client_credentials`. Both code-paths need a client
# secret, so this is CONFIDENTIAL (PKCE is for pure-browser clients
# like polaris-console).
resource "keycloak_openid_client" "kafka_ui" {
  realm_id    = keycloak_realm.openvelox.id
  client_id   = "kafka-ui"
  name        = "Kafka UI (kafbat)"
  enabled     = true
  description = "kafbat kafka-ui — Spring Boot backend OIDC client"

  access_type                  = "CONFIDENTIAL"
  client_authenticator_type    = "client-secret"
  standard_flow_enabled        = true
  service_accounts_enabled     = true
  direct_access_grants_enabled = false

  root_url = "https://kafka.${var.domain}"
  valid_redirect_uris = [
    # kafbat / Spring Security default callback
    "https://kafka.${var.domain}/login/oauth2/code/keycloak",
    "https://kafka.${var.domain}/*",
  ]
  valid_post_logout_redirect_uris = [
    "https://kafka.${var.domain}/*",
  ]
  web_origins = ["https://kafka.${var.domain}"]
}

resource "keycloak_openid_client_default_scopes" "kafka_ui" {
  realm_id  = keycloak_realm.openvelox.id
  client_id = keycloak_openid_client.kafka_ui.id
  default_scopes = [
    data.keycloak_openid_client_scope.basic.name,
    data.keycloak_openid_client_scope.profile.name,
    data.keycloak_openid_client_scope.email.name,
    data.keycloak_openid_client_scope.roles.name,
  ]
}

# kafbat's own service account (used for the SASL OAUTHBEARER session
# to the broker via client_credentials) needs kafka-admin — the UI
# enumerates every topic/group/config, tails messages, and creates
# topics on behalf of human admins. Browser users' per-action authz
# is enforced client-side via kafka_ui_roles + rbac.roles in the
# kafbat chart; broker-side authorisation on the service-account token
# has to be the union of all UI-driven actions, so admin is the
# simplest safe choice.
resource "keycloak_openid_client_service_account_realm_role" "kafka_ui_admin" {
  realm_id                = keycloak_realm.openvelox.id
  service_account_user_id = keycloak_openid_client.kafka_ui.service_account_user_id
  role                    = keycloak_role.realm_roles["kafka-admin"].name
}

# Audience — Kafka-UI forwards its browser-issued access token to the
# broker, so the token must carry `aud=kafka-broker`.
resource "keycloak_openid_audience_protocol_mapper" "kafka_ui_aud" {
  realm_id                 = keycloak_realm.openvelox.id
  client_id                = keycloak_openid_client.kafka_ui.id
  name                     = "audience-kafka-broker"
  included_client_audience = keycloak_openid_client.kafka_broker.client_id
  add_to_id_token          = true
  add_to_access_token      = true
}

# Flat `kafka_ui_roles` claim — kafbat's rbac.roles[*].subjects[role] looks
# up the role by name; its roles-field config can point at any JSON path.
# Keeping the claim name distinct from Airflow/Grafana's `roles` avoids
# accidental cross-UI privilege leaks when JWTs are reused.
resource "keycloak_openid_user_realm_role_protocol_mapper" "kafka_ui_roles" {
  realm_id            = keycloak_realm.openvelox.id
  client_id           = keycloak_openid_client.kafka_ui.id
  name                = "kafka-ui-roles"
  claim_name          = "kafka_ui_roles"
  multivalued         = true
  add_to_id_token     = true
  add_to_access_token = true
  add_to_userinfo     = true
}

# --- kafka-flink (confidential service-account client) ---
resource "keycloak_openid_client" "kafka_flink" {
  realm_id    = keycloak_realm.openvelox.id
  client_id   = "kafka-flink"
  name        = "Kafka — Flink service account"
  enabled     = true
  description = "Flink session cluster — SASL OAUTHBEARER client credentials"

  access_type                  = "CONFIDENTIAL"
  standard_flow_enabled        = false
  direct_access_grants_enabled = false
  service_accounts_enabled     = true

  client_secret = var.kafka_flink_client_secret != "" ? var.kafka_flink_client_secret : null
}

resource "keycloak_openid_client_default_scopes" "kafka_flink" {
  realm_id  = keycloak_realm.openvelox.id
  client_id = keycloak_openid_client.kafka_flink.id
  default_scopes = [
    data.keycloak_openid_client_scope.basic.name,
    data.keycloak_openid_client_scope.profile.name,
    data.keycloak_openid_client_scope.roles.name,
  ]
}

resource "keycloak_openid_client_service_account_realm_role" "kafka_flink_producer" {
  realm_id                = keycloak_realm.openvelox.id
  service_account_user_id = keycloak_openid_client.kafka_flink.service_account_user_id
  role                    = keycloak_role.realm_roles["kafka-producer"].name
}

resource "keycloak_openid_client_service_account_realm_role" "kafka_flink_consumer" {
  realm_id                = keycloak_realm.openvelox.id
  service_account_user_id = keycloak_openid_client.kafka_flink.service_account_user_id
  role                    = keycloak_role.realm_roles["kafka-consumer"].name
}

resource "keycloak_openid_audience_protocol_mapper" "kafka_flink_aud" {
  realm_id                 = keycloak_realm.openvelox.id
  client_id                = keycloak_openid_client.kafka_flink.id
  name                     = "audience-kafka-broker"
  included_client_audience = keycloak_openid_client.kafka_broker.client_id
  add_to_id_token          = false
  add_to_access_token      = true
}

# --- kafka-tfl-producer (confidential service-account client) ---
resource "keycloak_openid_client" "kafka_tfl_producer" {
  realm_id    = keycloak_realm.openvelox.id
  client_id   = "kafka-tfl-producer"
  name        = "Kafka — TFL producer service account"
  enabled     = true
  description = "tfl-producer-strimzi CronJob — SASL OAUTHBEARER client credentials"

  access_type                  = "CONFIDENTIAL"
  standard_flow_enabled        = false
  direct_access_grants_enabled = false
  service_accounts_enabled     = true

  client_secret = var.kafka_tfl_producer_client_secret != "" ? var.kafka_tfl_producer_client_secret : null
}

resource "keycloak_openid_client_default_scopes" "kafka_tfl_producer" {
  realm_id  = keycloak_realm.openvelox.id
  client_id = keycloak_openid_client.kafka_tfl_producer.id
  default_scopes = [
    data.keycloak_openid_client_scope.basic.name,
    data.keycloak_openid_client_scope.profile.name,
    data.keycloak_openid_client_scope.roles.name,
  ]
}

resource "keycloak_openid_client_service_account_realm_role" "kafka_tfl_producer_role" {
  realm_id                = keycloak_realm.openvelox.id
  service_account_user_id = keycloak_openid_client.kafka_tfl_producer.service_account_user_id
  role                    = keycloak_role.realm_roles["kafka-producer"].name
}

resource "keycloak_openid_audience_protocol_mapper" "kafka_tfl_producer_aud" {
  realm_id                 = keycloak_realm.openvelox.id
  client_id                = keycloak_openid_client.kafka_tfl_producer.id
  name                     = "audience-kafka-broker"
  included_client_audience = keycloak_openid_client.kafka_broker.client_id
  add_to_id_token          = false
  add_to_access_token      = true
}
