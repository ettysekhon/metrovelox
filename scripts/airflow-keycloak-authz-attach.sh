#!/usr/bin/env bash
#
# After `airflow keycloak-auth-manager create-all`, link Keycloak UMA role policies to permissions.
# Required for singleton (no --teams) installs — otherwise every /api/v2/* call returns 403.
#
# Prerequisites: realm roles Admin, Viewer, User, Op, SuperAdmin (see keycloak-realm Terraform).
#
# Usage:
#   bash scripts/airflow-keycloak-authz-attach.sh
#
set -euo pipefail

NS="${AIRFLOW_NAMESPACE:-batch}"
DEPLOY="${AIRFLOW_API_DEPLOY:-airflow-api-server}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PY="${SCRIPT_DIR}/airflow_keycloak_authz_attach.py"

if [[ ! -f "${PY}" ]]; then
  echo "ERROR: Missing ${PY}" >&2
  exit 1
fi

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

KC_INTERNAL_URL="${KEYCLOAK_INTERNAL_URL:-http://keycloak.platform.svc.cluster.local:8080}"
CONTAINER="${AIRFLOW_API_CONTAINER:-api-server}"

# kubectl cp does not accept deploy/<name>; resolve a running pod from the deployment.
POD="$(kubectl get pod -n "${NS}" -l "component=api-server" \
  -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null | awk '{print $1}')"

if [[ -z "${POD}" ]]; then
  # Fallback: resolve via the deployment's pod-template-hash (works across chart label conventions).
  HASH="$(kubectl get deploy -n "${NS}" "${DEPLOY}" -o jsonpath='{.metadata.labels.pod-template-hash}' 2>/dev/null || true)"
  if [[ -n "${HASH}" ]]; then
    POD="$(kubectl get pod -n "${NS}" -l "pod-template-hash=${HASH}" \
      -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null | awk '{print $1}')"
  fi
fi

if [[ -z "${POD}" ]]; then
  # Last resort: pick the first running pod whose name starts with the deployment name.
  POD="$(kubectl get pod -n "${NS}" -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' \
    | grep -E "^${DEPLOY}-" | head -n1 || true)"
fi

if [[ -z "${POD}" ]]; then
  echo "ERROR: Could not find a running pod for deployment ${DEPLOY} in namespace ${NS}." >&2
  echo "       Export AIRFLOW_API_DEPLOY or run: kubectl get pods -n ${NS}" >&2
  exit 1
fi

echo "==> Using pod ${NS}/${POD} (container ${CONTAINER})"

kubectl cp "${PY}" "${NS}/${POD}:/tmp/airflow_keycloak_authz_attach.py" -c "${CONTAINER}"

exec kubectl exec -n "${NS}" -c "${CONTAINER}" "${POD}" -- \
  env \
  AIRFLOW__KEYCLOAK_AUTH_MANAGER__SERVER_URL="${KC_INTERNAL_URL}" \
  KEYCLOAK_BOOTSTRAP_PASSWORD="${KEYCLOAK_BOOTSTRAP_PASSWORD}" \
  KEYCLOAK_BOOTSTRAP_USERNAME="${KEYCLOAK_BOOTSTRAP_USERNAME:-admin}" \
  KEYCLOAK_BOOTSTRAP_USER_REALM="${KEYCLOAK_BOOTSTRAP_USER_REALM:-master}" \
  python3 /tmp/airflow_keycloak_authz_attach.py
