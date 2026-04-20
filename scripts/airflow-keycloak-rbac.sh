#!/usr/bin/env bash
#
# One-time Keycloak authorization sync for Airflow KeycloakAuthManager.
# Creates scopes/resources/permissions in Keycloak for the `airflow` client.
#
# Uses the Keycloak bootstrap admin (default: user `admin` in realm `master`) to
# call Keycloak’s Admin API. Password is taken from KEYCLOAK_BOOTSTRAP_PASSWORD
# or from Secret keycloak-secrets key admin-password (platform namespace).
#
# Usage:
#   bash scripts/airflow-keycloak-rbac.sh
#   bash scripts/airflow-keycloak-rbac.sh --teams data-platform,analytics
#
# See: https://airflow.apache.org/docs/apache-airflow-providers-keycloak/stable/auth-manager/index.html

set -euo pipefail

NS="${AIRFLOW_NAMESPACE:-batch}"
DEPLOY="${AIRFLOW_API_DEPLOY:-airflow-api-server}"
KC_USER="${KEYCLOAK_BOOTSTRAP_USERNAME:-admin}"
KC_USER_REALM="${KEYCLOAK_BOOTSTRAP_USER_REALM:-master}"

if [[ -z "${KEYCLOAK_BOOTSTRAP_PASSWORD:-}" ]]; then
  KEYCLOAK_BOOTSTRAP_PASSWORD="$(
    kubectl get secret keycloak-secrets -n platform -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d || true
  )"
fi

if [[ -z "${KEYCLOAK_BOOTSTRAP_PASSWORD}" ]]; then
  echo "ERROR: No Keycloak admin password. Export KEYCLOAK_BOOTSTRAP_PASSWORD or ensure" >&2
  echo "       keycloak-secrets (key admin-password) exists in namespace platform." >&2
  exit 1
fi

# The pod's SERVER_URL may point at the public URL (Cloudflare). For admin API calls
# from inside the cluster, override to the internal Keycloak service (no TLS required).
KC_INTERNAL_URL="${KEYCLOAK_INTERNAL_URL:-http://keycloak.platform.svc.cluster.local:8080}"

kubectl exec -n "${NS}" "deploy/${DEPLOY}" -- \
  env AIRFLOW__KEYCLOAK_AUTH_MANAGER__SERVER_URL="${KC_INTERNAL_URL}" \
  airflow keycloak-auth-manager create-all \
  --username "${KC_USER}" \
  --user-realm "${KC_USER_REALM}" \
  --password "${KEYCLOAK_BOOTSTRAP_PASSWORD}" \
  "$@"

echo ""
echo "==> Linking UMA role policies to permissions (singleton mode; avoids 403 on /api/v2/*)..."
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bash "${REPO_ROOT}/scripts/airflow-keycloak-authz-attach.sh"
