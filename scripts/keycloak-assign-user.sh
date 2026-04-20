#!/usr/bin/env bash
#
# Assign an OpenVelox realm user to a group or realm role (Keycloak Admin REST API).
# Avoids manual clicks for the common case: platform-admin → platform-admins / airflow-admin.
#
# Prerequisites: curl, jq; kubectl context pointed at the cluster (for default password).
#
# Keycloak URL (pick one):
#   - In-cluster / CI:  http://keycloak.platform.svc.cluster.local:8080
#   - From laptop:      kubectl port-forward -n platform svc/keycloak 8080:8080
#                       then:  export KEYCLOAK_ADMIN_URL=http://127.0.0.1:8080
#   - Public (if TLS OK): KEYCLOAK_ADMIN_URL=https://auth.<your-domain>
#
# Usage:
#   bash scripts/keycloak-assign-user.sh add-group <username> <group-name>
#   bash scripts/keycloak-assign-user.sh add-realm-role <username> <realm-role-name>
#
# Examples:
#   KEYCLOAK_ADMIN_URL=http://127.0.0.1:8080 bash scripts/keycloak-assign-user.sh add-group platform-admin platform-admins
#   KEYCLOAK_ADMIN_URL=http://127.0.0.1:8080 bash scripts/keycloak-assign-user.sh add-realm-role platform-admin airflow-admin

set -euo pipefail

REALM="${KEYCLOAK_REALM:-openvelox}"
KC_USER="${KEYCLOAK_BOOTSTRAP_USERNAME:-admin}"
KC_USER_REALM="${KEYCLOAK_BOOTSTRAP_USER_REALM:-master}"

if [[ -z "${KEYCLOAK_BOOTSTRAP_PASSWORD:-}" ]]; then
  KEYCLOAK_BOOTSTRAP_PASSWORD="$(
    kubectl get secret keycloak-secrets -n platform -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d || true
  )"
fi

KC_URL="${KEYCLOAK_ADMIN_URL:-${KEYCLOAK_INTERNAL_URL:-http://keycloak.platform.svc.cluster.local:8080}}"
KC_URL="${KC_URL%/}"

log() { echo "==> $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }

command -v curl >/dev/null || die "curl required"
command -v jq >/dev/null || die "jq required (brew install jq)"

[[ -n "${KEYCLOAK_BOOTSTRAP_PASSWORD}" ]] || die "Set KEYCLOAK_BOOTSTRAP_PASSWORD or ensure secret keycloak-secrets (platform) has admin-password"

get_token() {
  local resp http
  resp="$(curl -sS -w "\n%{http_code}" -X POST "${KC_URL}/realms/${KC_USER_REALM}/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "client_id=admin-cli" \
    --data-urlencode "username=${KC_USER}" \
    --data-urlencode "password=${KEYCLOAK_BOOTSTRAP_PASSWORD}" \
    --data-urlencode "grant_type=password")"
  http="$(echo "$resp" | tail -n1)"
  body="$(echo "$resp" | sed '$d')"
  if [[ "$http" != "200" ]]; then
    die "Keycloak token request failed HTTP $http: $body"
  fi
  echo "$body" | jq -r .access_token
}

user_id() {
  local username="$1" tok="$2" resp
  resp="$(curl -sS -H "Authorization: Bearer ${tok}" \
    "${KC_URL}/admin/realms/${REALM}/users?username=${username}&exact=true")"
  local n
  n="$(echo "$resp" | jq 'length')"
  [[ "$n" -eq 1 ]] || die "Expected exactly one user '${username}' in realm ${REALM}, got ${n}"
  echo "$resp" | jq -r '.[0].id'
}

add_to_group() {
  local username="$1" group_name="$2"
  local tok gid uid
  tok="$(get_token)"
  uid="$(user_id "$username" "$tok")"

  local groups_json
  groups_json="$(curl -sS -H "Authorization: Bearer ${tok}" \
    "${KC_URL}/admin/realms/${REALM}/groups?search=${group_name}&max=50")"
  gid="$(echo "$groups_json" | jq -r --arg n "$group_name" '[.[] | select(.name == $n)][0].id // empty')"
  [[ -n "$gid" ]] || die "Group '${group_name}' not found in realm ${REALM}"

  local code
  code="$(curl -sS -o /dev/null -w "%{http_code}" -X PUT \
    -H "Authorization: Bearer ${tok}" \
    "${KC_URL}/admin/realms/${REALM}/users/${uid}/groups/${gid}")"
  if [[ "$code" == "204" ]]; then
    log "User '${username}' added to group '${group_name}'."
  else
    die "PUT group membership failed HTTP ${code}"
  fi
}

add_realm_role() {
  local username="$1" role_name="$2"
  local tok uid role_json
  tok="$(get_token)"
  uid="$(user_id "$username" "$tok")"

  role_json="$(curl -sS -H "Authorization: Bearer ${tok}" \
    "${KC_URL}/admin/realms/${REALM}/roles/${role_name}")"
  [[ "$(echo "$role_json" | jq -r .name)" == "$role_name" ]] || die "Realm role '${role_name}' not found"

  local code body out
  body="$(echo "$role_json" | jq -c '[.]')"
  out="$(curl -sS -w "\n%{http_code}" -X POST \
    -H "Authorization: Bearer ${tok}" -H "Content-Type: application/json" \
    -d "$body" \
    "${KC_URL}/admin/realms/${REALM}/users/${uid}/role-mappings/realm")"
  code="$(echo "$out" | tail -n1)"
  if [[ "$code" == "204" ]]; then
    log "Realm role '${role_name}' mapped to user '${username}'."
  else
    echo "$out" | sed '$d' >&2
    die "POST realm role mapping failed HTTP ${code}"
  fi
}

case "${1:-}" in
  add-group)
    [[ $# -eq 3 ]] || die "Usage: $0 add-group <username> <group-name>"
    log "Keycloak: ${KC_URL}  realm=${REALM}"
    add_to_group "$2" "$3"
    ;;
  add-realm-role)
    [[ $# -eq 3 ]] || die "Usage: $0 add-realm-role <username> <realm-role-name>"
    log "Keycloak: ${KC_URL}  realm=${REALM}"
    add_realm_role "$2" "$3"
    ;;
  *)
    die "Usage: $0 add-group <username> <group-name> | add-realm-role <username> <realm-role-name>"
    ;;
esac

log "Done. Log out of Airflow and sign in again so the access token includes the new roles."
