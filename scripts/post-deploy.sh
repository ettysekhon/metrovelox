#!/usr/bin/env bash
#
# Post-Deploy — runs after keycloak-realm TF apply to wire secrets.
# ==================================================================
#
# Extracts Keycloak client secrets from Terraform output, writes them
# to Vault and Kubernetes, and restarts Airflow to pick up changes.
#
# Usage:
#   bash scripts/post-deploy.sh <env> [--skip-restart]
#
# Prerequisites:
#   - kubectl context pointing at the target cluster
#   - keycloak-realm Terraform stack already applied
#   - vault-init-<env>.json exists (or VAULT_TOKEN env var set)
#   - GITHUB_PAT env var set (or already stored in Vault)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV="${1:?Usage: $0 <env> [--skip-restart]}"
SKIP_RESTART="${2:-}"
VAULT_NS="security"

log()  { echo "==> $*"; }
warn() { echo "  ⚠  $*"; }

# ─── Read env config ──────────────────────────────────────────────

TFVARS="${REPO_ROOT}/infra/terraform/environments/${ENV}.tfvars"
if [[ ! -f "${TFVARS}" ]]; then
  echo "ERROR: ${TFVARS} not found"
  exit 1
fi

read_tfvar() {
  grep "^${1} *=" "${TFVARS}" | sed 's/^[^=]*= *"\([^"]*\)".*/\1/' | head -1
}

PROJECT_ID=$(read_tfvar project_id)
DOMAIN=$(read_tfvar domain)
TF_BUCKET="tfstate-${PROJECT_ID}"

# ─── Vault token ──────────────────────────────────────────────────

INIT_FILE="${REPO_ROOT}/vault-init-${ENV}.json"
if [[ -f "${INIT_FILE}" ]]; then
  VAULT_TOKEN=$(python3 -c "import json; print(json.load(open('${INIT_FILE}'))['root_token'])")
elif [[ -n "${VAULT_TOKEN:-}" ]]; then
  true
else
  echo "ERROR: No Vault token. Set VAULT_TOKEN or ensure vault-init-${ENV}.json exists."
  exit 1
fi
export VAULT_TOKEN

vault_put() {
  local path="$1"; shift
  kubectl exec -n "${VAULT_NS}" vault-0 -- \
    env VAULT_TOKEN="${VAULT_TOKEN}" \
    vault kv put "${path}" "$@" 2>/dev/null
}

# ─── 1. Extract Keycloak client secrets from TF ──────────────────

log "Extracting Keycloak client secrets from Terraform state..."

KC_STACK_DIR="${REPO_ROOT}/infra/terraform/keycloak-realm"
pushd "${KC_STACK_DIR}" > /dev/null

terraform init -reconfigure \
  -backend-config="bucket=${TF_BUCKET}" \
  -backend-config="prefix=keycloak-realm" \
  -input=false > /dev/null 2>&1

SECRETS_JSON=$(terraform output -json client_secrets 2>/dev/null || echo "{}")

AIRFLOW_SECRET=$(echo "${SECRETS_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('airflow',''))")
ARGOCD_SECRET=$(echo "${SECRETS_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('argocd',''))")
GRAFANA_SECRET=$(echo "${SECRETS_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('grafana',''))")
FLINK_UI_SECRET=$(echo "${SECRETS_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('flink_ui',''))")
MLFLOW_SECRET=$(echo "${SECRETS_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('mlflow',''))")
TRINO_SECRET=$(echo "${SECRETS_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('trino',''))")
KAFKA_BROKER_SECRET=$(echo "${SECRETS_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('kafka_broker',''))")
KAFKA_UI_SECRET=$(echo "${SECRETS_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('kafka_ui',''))")
KAFKA_FLINK_SECRET=$(echo "${SECRETS_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('kafka_flink',''))")
KAFKA_TFL_PRODUCER_SECRET=$(echo "${SECRETS_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('kafka_tfl_producer',''))")
OPENVELOX_API_SECRET=$(echo "${SECRETS_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('openvelox_api',''))")

popd > /dev/null

if [[ -z "${AIRFLOW_SECRET}" ]]; then
  warn "Could not extract client secrets from Terraform. Run 'scripts/tf-apply.sh keycloak-realm ${ENV}' first."
  exit 1
fi

log "Extracted secrets for: airflow, argocd, grafana, flink-ui, mlflow, trino, kafka-broker, kafka-ui, kafka-flink, kafka-tfl-producer, openvelox-api"

# ─── 2. Write Keycloak secrets to Vault ───────────────────────────

log "Writing Keycloak client secrets to Vault..."

KC_ADMIN_PW=$(kubectl get secret keycloak-secrets -n platform -o jsonpath='{.data.admin-password}' | base64 -d 2>/dev/null || echo "")

vault_put secret/platform/keycloak \
  admin-password="${KC_ADMIN_PW}" \
  airflow-client-id="airflow" \
  airflow-client-secret="${AIRFLOW_SECRET}" \
  argocd-client-secret="${ARGOCD_SECRET}" \
  grafana-client-secret="${GRAFANA_SECRET}" \
  flink-ui-client-secret="${FLINK_UI_SECRET}" \
  mlflow-client-secret="${MLFLOW_SECRET}" \
  trino-client-secret="${TRINO_SECRET}" \
  kafka-broker-client-secret="${KAFKA_BROKER_SECRET}" \
  kafka-ui-client-secret="${KAFKA_UI_SECRET}" \
  kafka-flink-client-id="kafka-flink" \
  kafka-flink-client-secret="${KAFKA_FLINK_SECRET}" \
  kafka-tfl-producer-client-id="kafka-tfl-producer" \
  kafka-tfl-producer-client-secret="${KAFKA_TFL_PRODUCER_SECRET}" \
  openvelox-api-client-id="openvelox-api" \
  openvelox-api-client-secret="${OPENVELOX_API_SECRET}"

log "Keycloak secrets written to Vault at secret/platform/keycloak"

# ─── 3. Update airflow-oauth-keycloak K8s secret ─────────────────

log "Updating airflow-oauth-keycloak secret in batch namespace..."

kubectl create secret generic airflow-oauth-keycloak \
  --namespace batch \
  --from-literal=KEYCLOAK_CLIENT_ID=airflow \
  --from-literal=KEYCLOAK_CLIENT_SECRET="${AIRFLOW_SECRET}" \
  --dry-run=client -o yaml | kubectl apply -f -

# ─── 4. Update GitHub PAT secret (if provided) ───────────────────

GITHUB_PAT="${GITHUB_PAT:-}"

if [[ -z "${GITHUB_PAT}" ]]; then
  GITHUB_PAT=$(kubectl exec -n "${VAULT_NS}" vault-0 -- \
    env VAULT_TOKEN="${VAULT_TOKEN}" \
    vault kv get -field=pat secret/platform/github 2>/dev/null || echo "")
fi

if [[ -n "${GITHUB_PAT}" && "${GITHUB_PAT}" != "REPLACE_ME" ]]; then
  log "Updating airflow-github-pat secret in batch namespace..."
  # GitDagBundle (apache-airflow-providers-git) expects a git:// connection URI,
  # not github:// — see docs/ROADMAP.md §6.
  kubectl create secret generic airflow-github-pat \
    --namespace batch \
    --from-literal=conn_uri="git://x-access-token:${GITHUB_PAT}@github.com" \
    --dry-run=client -o yaml | kubectl apply -f -

  vault_put secret/platform/github pat="${GITHUB_PAT}"
else
  warn "No GitHub PAT available. Set GITHUB_PAT env var or store in Vault first."
fi

# ─── 5. Store Cloudflare token in Vault (if provided) ─────────────

CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
if [[ -n "${CLOUDFLARE_API_TOKEN}" ]]; then
  log "Storing Cloudflare API token in Vault..."
  vault_put secret/platform/cloudflare api-token="${CLOUDFLARE_API_TOKEN}"
fi

# ─── 6a. Patch argocd-secret with OIDC client secret ─────────────

if [[ -n "${ARGOCD_SECRET}" ]]; then
  log "Patching argocd-secret with OIDC client secret..."
  kubectl patch secret argocd-secret -n argocd \
    --type merge \
    -p "{\"stringData\":{\"oidc.keycloak.clientSecret\":\"${ARGOCD_SECRET}\"}}"
fi

# ─── 6b. Update ArgoCD repo secret with GitHub PAT ───────────────

if [[ -n "${GITHUB_PAT}" && "${GITHUB_PAT}" != "REPLACE_ME" ]]; then
  log "Updating ArgoCD repo credential..."
  kubectl create secret generic repo-openvelox -n argocd \
    --from-literal=type=git \
    --from-literal=url=https://github.com/ettysekhon/openvelox.git \
    --from-literal=username=git \
    --from-literal=password="${GITHUB_PAT}" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl label secret repo-openvelox -n argocd \
    argocd.argoproj.io/secret-type=repository --overwrite
fi

# ─── 7. Force-sync ExternalSecrets so rewritten Vault values land ──

log "Forcing ExternalSecret re-sync (so new Keycloak client secrets land in pods)..."
# Annotating with a fresh timestamp makes ESO treat the ES as stale and re-read Vault.
FORCE_TS=$(date +%s)
for ns_es in \
  "streaming/flink-ui-oauth-secret" \
  "data/trino-oauth-secret" \
  "data/trino-polaris-credential" \
  "kafka/kafka-broker-oauth" \
  "kafka/kafka-ui-oauth" \
  "kafka/apicurio-db-credentials" \
  "streaming/kafka-flink-oauth" \
  "streaming/kafka-tfl-producer-oauth" \
  "apps/openvelox-api-oauth" \
  ; do
  ns="${ns_es%%/*}"; es="${ns_es##*/}"
  kubectl annotate externalsecret -n "${ns}" "${es}" \
    "force-sync=${FORCE_TS}" --overwrite 2>/dev/null \
    || warn "ExternalSecret ${ns}/${es} not found (skip)"
done

# ─── 8. Restart dependants to pick up new secrets ────────────────

if [[ "${SKIP_RESTART}" != "--skip-restart" ]]; then
  log "Restarting Airflow components..."
  kubectl rollout restart deployment airflow-api-server -n batch 2>/dev/null || true
  kubectl rollout restart deployment airflow-scheduler -n batch 2>/dev/null || true
  kubectl rollout restart deployment airflow-triggerer -n batch 2>/dev/null || true
  kubectl rollout restart deployment airflow-dag-processor -n batch 2>/dev/null || true
  log "Airflow restart triggered."

  log "Restarting ArgoCD server (OIDC config refresh)..."
  kubectl rollout restart deployment argocd-server -n argocd 2>/dev/null || true

  log "Restarting oauth2-proxy-flink..."
  kubectl rollout restart deployment oauth2-proxy-flink -n streaming 2>/dev/null || true

  # kafka-ui picks its OIDC client secret up via envFrom; restart so the new
  # ESO-synced Secret is projected into the pod.
  log "Restarting kafka-ui (kafka ns)..."
  kubectl rollout restart deployment kafka-ui -n kafka 2>/dev/null || true

  # Strimzi projects listener-auth clientSecret refs into the broker pod
  # via its own config-providers, but the simpler path is to bounce the
  # pods so Strimzi re-reads the secret on boot.
  log "Rolling Strimzi Kafka broker pods (kafka-broker-oauth rotation)..."
  kubectl rollout restart statefulset openvelox-mixed -n kafka 2>/dev/null || true

  log "Restarting Trino coordinator (OAuth2 client-secret refresh)..."
  kubectl rollout restart statefulset trino-coordinator -n data 2>/dev/null \
    || kubectl rollout restart deployment trino-coordinator -n data 2>/dev/null \
    || true
fi

# ─── 9. Polaris service principal for Trino ──────────────────────
#
# Mint (or re-use) a per-service Polaris principal so the Trino coordinator
# stops querying the catalog as `root`. Safe to fail on fresh clusters
# where Polaris isn't up yet — the Trino pods still work because the
# trino-polaris-credential Vault keys are seeded with the root credential
# as a fallback (see scripts/vault-init.sh).

log "Provisioning Polaris service principal for Trino (best-effort)..."
if kubectl -n data rollout status deployment/polaris --timeout=10s > /dev/null 2>&1; then
  bash "${REPO_ROOT}/scripts/polaris-bootstrap-principals.sh" "${ENV}" \
    || warn "polaris-bootstrap-principals.sh failed — Trino will fall back to root credential via Vault seed."

  # Human OIDC principals — provisions Polaris Principals (e.g. platform-admin)
  # whose numeric ids are synced back to Keycloak so the Polaris Console's
  # "Sign in with OIDC" button resolves against a real Principal row.
  # Safe to re-run; no-op when nothing has changed.
  log "Provisioning Polaris human OIDC principals (best-effort)..."
  bash "${REPO_ROOT}/scripts/polaris-bootstrap-human-principals.sh" "${ENV}" \
    || warn "polaris-bootstrap-human-principals.sh failed — Polaris Console OIDC login will 401 until resolved."
else
  warn "Polaris deployment not Ready. Skipping principal rotation."
  warn "Re-run manually once Polaris is up:"
  warn "  bash scripts/polaris-bootstrap-principals.sh ${ENV}"
  warn "  bash scripts/polaris-bootstrap-human-principals.sh ${ENV}"
fi

# ─── Done ──────────────────────────────────────────────────────────

echo ""
log "Post-deploy complete!"
echo ""
echo "Summary:"
echo "  - Keycloak client secrets → Vault (secret/platform/keycloak)"
echo "  - airflow-oauth-keycloak → K8s secret (batch namespace)"
if [[ -n "${GITHUB_PAT}" && "${GITHUB_PAT}" != "REPLACE_ME" ]]; then
  echo "  - GitHub PAT → Vault + ArgoCD repo + airflow-github-pat"
fi
echo "  - Airflow pods restarted"
echo ""
echo "Remaining manual steps:"
echo "  1. Store real API keys in Vault:"
echo "     vault kv put secret/platform/tfl-api-key value=<KEY>"
echo "     vault kv put secret/platform/gemini-api-key value=<KEY>"
echo "  2. Verify ESO syncs: kubectl get externalsecrets -A"
echo "  3. Run smoke tests: see docs/QUICKSTART.md"
