#!/usr/bin/env bash
#
# Polaris — provision the Trino service principal.
# =================================================
#
# On a fresh cluster Trino talks to Polaris as `root:polaris-root-secret`
# (the credential the Helm chart bootstraps into Polaris at first start,
# seeded into Vault by scripts/vault-init.sh). That's fine for "does it
# connect at all" but gives Trino admin privileges on every catalog,
# which is over-broad for a data-plane query engine.
#
# This script — safe to run repeatedly — uses the root credential once
# to call Polaris's management API and:
#
#   1. Create a service principal  `trino`
#      (→ fresh clientId / clientSecret pair).
#   2. Create a principal role     `trino_service`.
#   3. Bind 1 ↔ 2.
#   4. For each warehouse in WAREHOUSES, create a catalog role
#      `catalog_writer` and bind it to `trino_service`.
#   5. Grant that catalog role `CATALOG_MANAGE_CONTENT` on its catalog.
#   6. Stash the new principal credential in Vault at
#      `secret/platform/polaris` → keys `trino-client-id` /
#      `trino-client-secret`. The `trino-polaris-credential`
#      ExternalSecret picks them up and the Trino coordinator
#      reloads on the next rollout.
#
# Intended to be invoked from scripts/post-deploy.sh after Polaris has
# rolled out. On re-runs the principal/role/grant calls return 409
# Conflict and we skip them — but the credential is **only known at
# creation time**, so we only overwrite Vault when step 1 returns a
# fresh secret. Use `--rotate` to force deletion + re-creation.
#
# Usage:
#   bash scripts/polaris-bootstrap-principals.sh <env> [--rotate]
#
# Prerequisites:
#   - kubectl context points at the target cluster
#   - Polaris is up and its Postgres persistence works (probe returns
#     200 on GET /api/management/v1/principals with a root bearer token)
#   - VAULT_TOKEN env var is set, or vault-init-<env>.json is available

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV="${1:?Usage: $0 <env> [--rotate]}"
ROTATE="${2:-}"
VAULT_NS="security"
POLARIS_NS="data"
POLARIS_SVC="polaris"
POLARIS_PORT="8181"
WAREHOUSES=("raw" "curated" "analytics")
# Override via env var on dev clusters. We expect `${PROJECT_ID}-lakehouse`
# to exist (created by infra/terraform/storage) with one top-level prefix
# per warehouse.
LAKEHOUSE_BUCKET="${LAKEHOUSE_BUCKET:-}"

# Use single quotes in log messages — the Bash parser treats backticks
# inside double-quoted strings as command substitution, which silently
# turns "Creating principal \`trino\`" into an attempt to execute `trino`.
log()  { echo "==> $*"; }
warn() { echo "  ⚠  $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# ─── Vault token ──────────────────────────────────────────────────

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

vault_patch() {
  local path="$1"; shift
  kubectl exec -n "${VAULT_NS}" vault-0 -- \
    env VAULT_TOKEN="${VAULT_TOKEN}" \
    vault kv patch "${path}" "$@" 2>/dev/null
}

# ─── Port-forward to Polaris ──────────────────────────────────────
#
# Polaris's management + catalog APIs aren't exposed externally by design —
# only the REST catalog is fronted by an HTTPRoute. Everything this script
# does lives on the management API, which is cluster-local.

LOCAL_PORT="${POLARIS_LOCAL_PORT:-18181}"
log "Opening port-forward localhost:${LOCAL_PORT} → svc/${POLARIS_SVC}:${POLARIS_PORT}"
kubectl port-forward -n "${POLARIS_NS}" "svc/${POLARIS_SVC}" \
  "${LOCAL_PORT}:${POLARIS_PORT}" > /dev/null 2>&1 &
PF_PID=$!
trap 'kill ${PF_PID} 2>/dev/null; wait 2>/dev/null || true' EXIT

# Wait up to 20s for the port-forward to be usable.
for _ in $(seq 1 20); do
  sleep 1
  curl -sf "http://localhost:${LOCAL_PORT}/q/health/ready" > /dev/null 2>&1 && break
done

POLARIS_URL="http://localhost:${LOCAL_PORT}"

# ─── Obtain a root bearer token ───────────────────────────────────

ROOT_ID=$(vault_read "secret/platform/polaris" "root-client-id" || echo "root")
ROOT_SECRET=$(vault_read "secret/platform/polaris" "root-client-secret" \
  || echo "polaris-root-secret")

log "Exchanging root credential for a bearer token"
ROOT_TOKEN=$(curl -sf -X POST "${POLARIS_URL}/api/catalog/v1/oauth/tokens" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=${ROOT_ID}&client_secret=${ROOT_SECRET}&scope=PRINCIPAL_ROLE:ALL" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])') \
  || die "Failed to authenticate as root against Polaris. Is persistence healthy?"

AUTH=( -H "Authorization: Bearer ${ROOT_TOKEN}" -H "Content-Type: application/json" )

# ─── API helpers ──────────────────────────────────────────────────
#
# Polaris returns HTTP 409 on create when the resource already exists.
# We treat 409 as success (idempotent). Anything else non-2xx fails.

polaris_post_ok() {
  local path="$1" body="$2"
  local code
  code=$(curl -s -o /tmp/polaris-out -w "%{http_code}" -X POST "${POLARIS_URL}${path}" "${AUTH[@]}" -d "${body}")
  case "${code}" in
    2*|409) return 0 ;;
    *) warn "POST ${path} → ${code}: $(cat /tmp/polaris-out | head -c 300)"; return 1 ;;
  esac
}

polaris_put_ok() {
  local path="$1" body="$2"
  local code
  code=$(curl -s -o /tmp/polaris-out -w "%{http_code}" -X PUT "${POLARIS_URL}${path}" "${AUTH[@]}" -d "${body}")
  case "${code}" in
    2*|409) return 0 ;;
    *) warn "PUT ${path} → ${code}: $(cat /tmp/polaris-out | head -c 300)"; return 1 ;;
  esac
}

polaris_delete_ok() {
  curl -s -X DELETE "${POLARIS_URL}$1" "${AUTH[@]}" > /dev/null
}

# ─── 0. Catalogs (warehouses) ─────────────────────────────────────
#
# The downstream grants attach roles to catalogs named after each entry
# in WAREHOUSES. If any of them are missing — e.g. on a freshly
# bootstrapped Polaris — the grants 404 and the Trino service principal
# ends up with no catalog access. Create them idempotently.
#
# Polaris requires a storageConfigInfo even for INTERNAL catalogs; for
# GCS we set `storageType=GCS` and point `allowedLocations` at
# gs://${LAKEHOUSE_BUCKET}/<warehouse>/. Workload Identity on the Trino
# service account supplies the credentials at runtime, so no inline
# token is needed in the storage config.

if [[ -z "${LAKEHOUSE_BUCKET}" ]]; then
  PROJECT_ID=$(kubectl config view --minify -o jsonpath='{..namespace}' >/dev/null 2>&1 ; \
    gcloud config get-value project 2>/dev/null || echo "")
  LAKEHOUSE_BUCKET="${PROJECT_ID:+${PROJECT_ID}-lakehouse}"
fi

if [[ -n "${LAKEHOUSE_BUCKET}" ]]; then
  for wh in "${WAREHOUSES[@]}"; do
    log "Ensuring catalog '${wh}' exists (backed by gs://${LAKEHOUSE_BUCKET}/${wh}/)"
    polaris_post_ok "/api/management/v1/catalogs" "$(cat <<JSON
{
  "catalog": {
    "type": "INTERNAL",
    "name": "${wh}",
    "properties": {
      "default-base-location": "gs://${LAKEHOUSE_BUCKET}/${wh}/"
    },
    "storageConfigInfo": {
      "storageType": "GCS",
      "allowedLocations": ["gs://${LAKEHOUSE_BUCKET}/${wh}/"]
    }
  }
}
JSON
)" || warn "Catalog '${wh}' create failed — continuing"
  done
else
  warn "LAKEHOUSE_BUCKET not set and gcloud project unknown; skipping catalog creation"
fi

# ─── 1. Service principal ─────────────────────────────────────────

if [[ "${ROTATE}" == "--rotate" ]]; then
  log "Rotate requested — deleting existing trino principal"
  polaris_delete_ok "/api/management/v1/principals/trino" || true
fi

log "Creating principal 'trino'"
CREATE_RESP=$(curl -s -X POST "${POLARIS_URL}/api/management/v1/principals" \
  "${AUTH[@]}" -d '{"principal":{"name":"trino"}}')

NEW_CLIENT_ID=$(echo "${CREATE_RESP}" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("credentials",{}).get("clientId",""))' 2>/dev/null || echo "")
NEW_CLIENT_SECRET=$(echo "${CREATE_RESP}" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("credentials",{}).get("clientSecret",""))' 2>/dev/null || echo "")

if [[ -z "${NEW_CLIENT_ID}" ]]; then
  # 409 Conflict — principal already exists and we didn't rotate. The
  # credential is **not recoverable** from Polaris after creation; the
  # previous run must have persisted it to Vault. Leave Vault alone.
  log "Principal 'trino' already exists. Leaving Vault values in place."
  log "Re-run with --rotate to mint a fresh credential."
else
  log "Minted new credential for 'trino' (clientId=${NEW_CLIENT_ID:0:8}…)"
  log "Writing credential to Vault secret/platform/polaris"
  vault_patch "secret/platform/polaris" \
    trino-client-id="${NEW_CLIENT_ID}" \
    trino-client-secret="${NEW_CLIENT_SECRET}" > /dev/null
fi

# ─── 2. Principal role ────────────────────────────────────────────

log "Creating principal role 'trino_service'"
polaris_post_ok "/api/management/v1/principal-roles" \
  '{"principalRole":{"name":"trino_service"}}' || true

log "Binding principal 'trino' → role 'trino_service'"
polaris_put_ok "/api/management/v1/principals/trino/principal-roles" \
  '{"principalRole":{"name":"trino_service"}}' || true

# ─── 3. Per-catalog role + grant ──────────────────────────────────

for wh in "${WAREHOUSES[@]}"; do
  log "Catalog '${wh}': creating catalog role 'catalog_writer'"
  polaris_post_ok "/api/management/v1/catalogs/${wh}/catalog-roles" \
    '{"catalogRole":{"name":"catalog_writer"}}' || \
    warn "Catalog ${wh} missing — create it first (set LAKEHOUSE_BUCKET and re-run)"

  log "Catalog '${wh}': binding role to principal-role 'trino_service'"
  polaris_put_ok "/api/management/v1/principal-roles/trino_service/catalog-roles/${wh}" \
    '{"catalogRole":{"name":"catalog_writer"}}' || true

  log "Catalog '${wh}': granting CATALOG_MANAGE_CONTENT"
  polaris_put_ok "/api/management/v1/catalogs/${wh}/catalog-roles/catalog_writer/grants" \
    '{"grant":{"type":"catalog","privilege":"CATALOG_MANAGE_CONTENT"}}' || true
done

# ─── 4. Force ESO refresh + Trino restart ─────────────────────────

log "Annotating trino-polaris-credential ExternalSecret to force ESO re-read"
kubectl annotate externalsecret -n "${POLARIS_NS}" trino-polaris-credential \
  "force-sync=$(date +%s)" --overwrite 2>/dev/null \
  || warn "ExternalSecret trino-polaris-credential not present yet — skipping force-sync"

log "Restarting Trino coordinator so it picks up the new credential"
kubectl rollout restart statefulset trino-coordinator -n "${POLARIS_NS}" 2>/dev/null \
  || kubectl rollout restart deployment trino-coordinator -n "${POLARIS_NS}" 2>/dev/null \
  || warn "Trino coordinator workload not found — skipping restart"

log "Done."
echo
echo "Verify:"
echo "  kubectl -n ${POLARIS_NS} get secret trino-polaris-credential -o jsonpath='{.data.credential}' | base64 -d"
echo "  kubectl -n ${POLARIS_NS} logs statefulset/trino-coordinator --tail=50 | grep -i polaris"
