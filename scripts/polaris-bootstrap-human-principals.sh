#!/usr/bin/env bash
#
# Polaris — provision human OIDC principals.
# ==========================================
#
# Polaris 1.3 (configured in `mixed` auth mode — see helm/polaris/values-gke.tmpl.yaml
# `advancedConfig:`) validates Keycloak-issued JWTs and expects a Polaris Principal
# row in `polaris_schema.entities` whose numeric `id` + string `name` match the
# `polaris/principal_id` and `polaris/principal_name` claims embedded in the token.
#
# The numeric id is NOT under our control: Polaris assigns it at CREATE time and
# does not expose it via the public Management API.  The only way to discover it
# is to read the row straight out of Postgres after creation.  This script closes
# the loop:
#
#   1. Ensures each principal-role in POLARIS_ROLES exists in Polaris.
#   2. For every entry in HUMAN_PRINCIPALS (username:role):
#        a. POST /api/management/v1/principals  (idempotent — 409 tolerated).
#        b. PUT  /api/management/v1/principals/<name>/principal-roles  (bind).
#        c. SELECT id FROM polaris_schema.entities  where name matches and
#           type_code = 2 (PRINCIPAL).
#        d. Write that id back onto the matching Keycloak user as the
#           `polaris_principal_id` attribute via `kcadm.sh` in the Keycloak pod,
#           so the next access token the user receives carries the right number.
#   3. Binds `polaris_admin` to the existing `catalog_writer` catalog role on
#      every warehouse in WAREHOUSES (re-uses the role created by
#      scripts/polaris-bootstrap-principals.sh for the Trino service principal).
#
# Fully re-runnable.  If Polaris is wiped and rebootstrapped the ids change;
# running this script again reconciles Keycloak back to the new values.
#
# Prerequisites:
#   - kubectl context points at the target cluster.
#   - Polaris is healthy (probe returns 200 on /q/health/ready).
#   - Keycloak is healthy and admin user bootstrapped.
#   - VAULT_TOKEN env var set, or vault-init-<env>.json available.
#
# Usage:  bash scripts/polaris-bootstrap-human-principals.sh <env>

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV="${1:?Usage: $0 <env>}"

# ─── Cluster topology (override via env vars if the layout changes) ──────────
VAULT_NS="${VAULT_NS:-security}"
POLARIS_NS="${POLARIS_NS:-data}"
POLARIS_SVC="${POLARIS_SVC:-polaris}"
POLARIS_PORT="${POLARIS_PORT:-8181}"
POSTGRES_NS="${POSTGRES_NS:-platform}"
POSTGRES_POD="${POSTGRES_POD:-postgresql-0}"
POLARIS_DB="${POLARIS_DB:-polaris}"
POLARIS_DB_USER="${POLARIS_DB_USER:-polaris}"
POLARIS_REALM="${POLARIS_REALM:-POLARIS}"
KEYCLOAK_NS="${KEYCLOAK_NS:-platform}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-openvelox}"

WAREHOUSES=("raw" "curated" "analytics")

# Polaris principal-roles we need to exist.
#
# `service_admin` is bootstrapped by Polaris itself (it holds LIST_CATALOGS /
# PRINCIPAL_LIST / etc. service-level grants and is the target of the
# polaris-admin -> service_admin rewrite in values-gke.tmpl.yaml). We do NOT
# re-create it here; POSTing over the top would change nothing but generates
# noise in the log.
#
# `polaris_viewer` is a placeholder for future per-catalog read-only access;
# currently unused.
POLARIS_ROLES=("polaris_viewer")

# Map of Keycloak username -> Polaris principal-role to bind.  Add more
# lines here (and matching users in Keycloak) to grant them console access.
#
# `service_admin` gives full Polaris admin privileges; it's the role targeted
# by the `polaris-admin` realm-role → principal-role rewrite in
# helm/polaris/values-gke.tmpl.yaml (`polaris.oidc.principal-roles-mapper
# .mappings[0].*`).
HUMAN_PRINCIPALS=("platform-admin:service_admin")

# ─── Logging helpers ─────────────────────────────────────────────────────────
log()  { echo "==> $*"; }
warn() { echo "  !! $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# ─── Vault token ─────────────────────────────────────────────────────────────
INIT_FILE="${REPO_ROOT}/vault-init-${ENV}.json"
if [[ -f "${INIT_FILE}" ]]; then
  VAULT_TOKEN=$(python3 -c "import json; print(json.load(open('${INIT_FILE}'))['root_token'])")
elif [[ -z "${VAULT_TOKEN:-}" ]]; then
  die "No Vault token. Set VAULT_TOKEN or ensure vault-init-${ENV}.json exists."
fi
export VAULT_TOKEN

vault_read() {
  kubectl exec -n "${VAULT_NS}" vault-0 -- \
    env VAULT_TOKEN="${VAULT_TOKEN}" \
    vault kv get -field="$2" "$1" 2>/dev/null
}

# ─── Port-forward to Polaris ─────────────────────────────────────────────────
LOCAL_PORT="${POLARIS_LOCAL_PORT:-18181}"
log "Opening port-forward localhost:${LOCAL_PORT} -> svc/${POLARIS_SVC}:${POLARIS_PORT}"
kubectl port-forward -n "${POLARIS_NS}" "svc/${POLARIS_SVC}" \
  "${LOCAL_PORT}:${POLARIS_PORT}" > /dev/null 2>&1 &
PF_PID=$!
trap 'kill ${PF_PID} 2>/dev/null; wait 2>/dev/null || true' EXIT

for _ in $(seq 1 20); do
  sleep 1
  curl -sf "http://localhost:${LOCAL_PORT}/q/health/ready" > /dev/null 2>&1 && break
done
POLARIS_URL="http://localhost:${LOCAL_PORT}"

# ─── Root bearer token ───────────────────────────────────────────────────────
ROOT_ID=$(vault_read "secret/platform/polaris" "root-client-id" || echo "root")
ROOT_SECRET=$(vault_read "secret/platform/polaris" "root-client-secret" \
  || echo "polaris-root-secret")

log "Exchanging root credential for a bearer token"
ROOT_TOKEN=$(curl -sf -X POST "${POLARIS_URL}/api/catalog/v1/oauth/tokens" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=${ROOT_ID}&client_secret=${ROOT_SECRET}&scope=PRINCIPAL_ROLE:ALL" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])') \
  || die "Failed to authenticate root against Polaris. Is persistence healthy?"

AUTH=(-H "Authorization: Bearer ${ROOT_TOKEN}" -H "Content-Type: application/json")

polaris_post_ok() {
  local path="$1" body="$2" code
  code=$(curl -s -o /tmp/polaris-out -w "%{http_code}" -X POST "${POLARIS_URL}${path}" "${AUTH[@]}" -d "${body}")
  case "${code}" in
    2*|409) return 0 ;;
    *) warn "POST ${path} -> ${code}: $(head -c 300 /tmp/polaris-out)"; return 1 ;;
  esac
}

polaris_put_ok() {
  local path="$1" body="$2" code
  code=$(curl -s -o /tmp/polaris-out -w "%{http_code}" -X PUT "${POLARIS_URL}${path}" "${AUTH[@]}" -d "${body}")
  case "${code}" in
    2*|409) return 0 ;;
    # Polaris 1.3 leaks Postgres unique-constraint violations as 500 when a
    # role binding already exists (it should return 409). Treat the known
    # duplicate-key fingerprint as idempotent success.
    500)
      if grep -q "grant_records_pkey" /tmp/polaris-out 2>/dev/null; then
        return 0
      fi
      warn "PUT ${path} -> 500: $(head -c 300 /tmp/polaris-out)"
      return 1
      ;;
    *) warn "PUT ${path} -> ${code}: $(head -c 300 /tmp/polaris-out)"; return 1 ;;
  esac
}

# ─── 1. Principal roles ──────────────────────────────────────────────────────
for role in "${POLARIS_ROLES[@]}"; do
  log "Ensuring principal-role '${role}'"
  polaris_post_ok "/api/management/v1/principal-roles" \
    "{\"principalRole\":{\"name\":\"${role}\"}}" || true
done

# ─── 2. Bind service_admin -> catalog_writer on every warehouse ──────────────
# catalog_writer is created by scripts/polaris-bootstrap-principals.sh for the
# trino service principal; we reuse it here so human admins with the
# service_admin principal-role can also manage catalog content (beyond the
# service-level grants service_admin already carries).
for wh in "${WAREHOUSES[@]}"; do
  log "Binding service_admin -> catalog_writer on catalog '${wh}'"
  polaris_put_ok "/api/management/v1/principal-roles/service_admin/catalog-roles/${wh}" \
    '{"catalogRole":{"name":"catalog_writer"}}' || true
done

# ─── 3. Per-user principal + id sync ─────────────────────────────────────────
PG_PASSWORD=$(vault_read "secret/platform/polaris-persistence" "password" || echo "")
[[ -n "${PG_PASSWORD}" ]] || die "Could not read polaris-persistence password from Vault"

KC_POD=$(kubectl get pods -n "${KEYCLOAK_NS}" \
  -l app.kubernetes.io/name=keycloak -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -z "${KC_POD}" ]]; then
  # Fall back to a plain name-prefix match (some charts don't set the label).
  KC_POD=$(kubectl get pods -n "${KEYCLOAK_NS}" --no-headers 2>/dev/null \
    | awk '/^keycloak-/{print $1; exit}')
fi
[[ -n "${KC_POD}" ]] || die "Keycloak pod not found in namespace ${KEYCLOAK_NS}"

KC_ADMIN_PASS=$(vault_read "secret/platform/keycloak" "admin-password" || echo "")
[[ -n "${KC_ADMIN_PASS}" ]] || die "Could not read keycloak admin-password from Vault"

# Escape single quotes in the admin password so we can embed it inside a
# bash -c 'single-quoted' string passed to kubectl exec.
KC_ADMIN_PASS_ESC=$(printf "%s" "${KC_ADMIN_PASS}" | sed "s/'/'\\\\''/g")

# Keycloak 24+ refuses to store arbitrary user attributes unless the realm
# user profile has an `unmanagedAttributePolicy` set. We use ADMIN_EDIT so
# only admins (i.e. this script) can write attributes and normal self-service
# account flows still can't inject arbitrary metadata. Idempotent.
log "Ensuring realm user-profile unmanagedAttributePolicy=ADMIN_EDIT"
kubectl exec -n "${KEYCLOAK_NS}" "${KC_POD}" -- bash -c "
  set -e
  /opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 \
    --realm master --user admin --password '${KC_ADMIN_PASS_ESC}' >/dev/null
  /opt/keycloak/bin/kcadm.sh get realms/${KEYCLOAK_REALM}/users/profile > /tmp/up.json
  if grep -q '\"unmanagedAttributePolicy\"[[:space:]]*:[[:space:]]*\"ADMIN_EDIT\"' /tmp/up.json; then
    exit 0
  fi
  if grep -q unmanagedAttributePolicy /tmp/up.json; then
    sed -i 's/\"unmanagedAttributePolicy\"[[:space:]]*:[[:space:]]*\"[A-Z_]*\"/\"unmanagedAttributePolicy\":\"ADMIN_EDIT\"/' /tmp/up.json
  else
    sed -i 's/^{/{\"unmanagedAttributePolicy\":\"ADMIN_EDIT\",/' /tmp/up.json
  fi
  /opt/keycloak/bin/kcadm.sh update realms/${KEYCLOAK_REALM}/users/profile -f /tmp/up.json >/dev/null
" || warn "Failed to enforce unmanagedAttributePolicy — user attribute writes may fail"

for entry in "${HUMAN_PRINCIPALS[@]}"; do
  name="${entry%%:*}"
  role="${entry##*:}"

  log "Ensuring Polaris principal '${name}' bound to '${role}'"
  polaris_post_ok "/api/management/v1/principals" \
    "{\"principal\":{\"name\":\"${name}\"}}" || true
  polaris_put_ok "/api/management/v1/principals/${name}/principal-roles" \
    "{\"principalRole\":{\"name\":\"${role}\"}}" || true

  log "Looking up assigned numeric id in Postgres"
  # type_code = 2 is PRINCIPAL in Polaris 1.3.  Scope by realm so we don't
  # accidentally match an identically-named principal in another realm.
  PID=$(kubectl exec -n "${POSTGRES_NS}" "${POSTGRES_POD}" -- \
    env PGPASSWORD="${PG_PASSWORD}" psql -U "${POLARIS_DB_USER}" -d "${POLARIS_DB}" -tAc \
    "SELECT id FROM polaris_schema.entities WHERE realm_id='${POLARIS_REALM}' AND name='${name}' AND type_code=2;" \
    2>/dev/null | tr -d '[:space:]' || true)

  if [[ -z "${PID}" ]]; then
    warn "No Polaris id found for principal '${name}'; skipping Keycloak sync"
    continue
  fi
  log "  Polaris id=${PID}"

  log "Syncing id=${PID} onto Keycloak user '${name}' attribute 'polaris_principal_id'"
  # kcadm.sh is bundled in the Keycloak container image.  We authenticate
  # against the local instance as `admin` (master realm), look up the target
  # user id, then PATCH the attribute.  Re-running with the same value is a
  # no-op.
  kubectl exec -n "${KEYCLOAK_NS}" "${KC_POD}" -- bash -c "
    set -e
    /opt/keycloak/bin/kcadm.sh config credentials \
      --server http://localhost:8080 \
      --realm master --user admin --password '${KC_ADMIN_PASS_ESC}' >/dev/null
    KID=\$(/opt/keycloak/bin/kcadm.sh get users -r ${KEYCLOAK_REALM} -q username=${name} --fields id --format csv --noquotes | head -1 | tr -d '[:space:]')
    if [ -z \"\${KID}\" ]; then
      echo 'ERROR: no Keycloak user named ${name} in realm ${KEYCLOAK_REALM}' >&2
      exit 1
    fi
    /opt/keycloak/bin/kcadm.sh update users/\${KID} -r ${KEYCLOAK_REALM} \
      -s 'attributes.polaris_principal_id=[\"${PID}\"]' >/dev/null
    echo \"  keycloak-user ${name} (id=\${KID}) <- polaris_principal_id=${PID}\"
  " || warn "Failed to update Keycloak attribute for '${name}'"
done

log "Done."
echo
echo "Verify:"
echo "  kubectl -n ${POLARIS_NS} logs deployment/polaris --tail=50 | grep -iE 'oidc|auth'"
echo "  # Grab a Keycloak token for platform-admin and decode it:"
echo "  curl -sfX POST https://auth.\${DOMAIN}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token \\"
echo "    -d 'grant_type=password&client_id=polaris-console&username=platform-admin&password=<pw>' \\"
echo "    | jq -r .access_token | cut -d. -f2 | base64 -d | jq '.polaris, .aud'"
