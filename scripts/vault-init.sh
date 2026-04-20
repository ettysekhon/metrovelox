#!/usr/bin/env bash
#
# Vault Initialization — run ONCE per environment after first deploy.
# ====================================================================
#
# With GCP KMS auto-unseal configured, Vault automatically unseals on
# pod restart. This script handles the one-time initialization and
# sets up the KV secrets engine + Kubernetes auth method.
#
# Prerequisites:
#   - kubectl context pointed at the target cluster
#   - Vault pod running in security namespace (may show 0/1 Ready)
#   - GCP KMS auto-unseal configured (see helm/vault/values-{env}.yaml)
#
# Usage:
#   bash scripts/vault-init.sh [--env dev|prod]
#
# Outputs vault-init-{env}.json with recovery keys + root token.
# STORE THIS FILE SECURELY AND DO NOT COMMIT IT.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV="${1:---env}"

# Parse --env flag
if [[ "$ENV" == "--env" ]]; then
  ENV="${2:-dev}"
fi

VAULT_NS="security"
INIT_FILE="${REPO_ROOT}/vault-init-${ENV}.json"

log()  { echo "==> $*"; }
warn() { echo "  ⚠  $*"; }

# ─── Wait for Vault pod ────────────────────────────────────────────

log "Waiting for vault-0 pod in ${VAULT_NS} namespace..."
kubectl wait --for=condition=Initialized pod/vault-0 -n "${VAULT_NS}" --timeout=300s 2>/dev/null || true
sleep 5

# ─── Check if already initialized ──────────────────────────────────

INIT_STATUS=$(kubectl exec -n "${VAULT_NS}" vault-0 -- vault status -format=json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('initialized', False))" 2>/dev/null || echo "false")

if [[ "$INIT_STATUS" == "True" ]] || [[ "$INIT_STATUS" == "true" ]]; then
  log "Vault is already initialized."

  SEAL_STATUS=$(kubectl exec -n "${VAULT_NS}" vault-0 -- vault status -format=json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('sealed', True))" 2>/dev/null || echo "true")

  if [[ "$SEAL_STATUS" == "False" ]] || [[ "$SEAL_STATUS" == "false" ]]; then
    log "Vault is unsealed (KMS auto-unseal working). Proceeding to configure..."
  else
    warn "Vault is sealed. If using KMS auto-unseal, check KMS permissions."
    warn "For Shamir unseal, run: kubectl exec -n ${VAULT_NS} vault-0 -- vault operator unseal <KEY>"
    exit 1
  fi
else
  # ─── Initialize Vault ───────────────────────────────────────────

  log "Initializing Vault (recovery-shares=1, recovery-threshold=1)..."

  # With KMS auto-unseal, use recovery keys instead of unseal keys
  kubectl exec -n "${VAULT_NS}" vault-0 -- vault operator init \
    -recovery-shares=1 \
    -recovery-threshold=1 \
    -format=json > "${INIT_FILE}"

  ROOT_TOKEN=$(python3 -c "import json; print(json.load(open('${INIT_FILE}'))['root_token'])")
  log "Vault initialized. Root token and recovery keys saved to: ${INIT_FILE}"
  warn "STORE ${INIT_FILE} SECURELY. DO NOT COMMIT TO GIT."

  sleep 10

  SEAL_STATUS=$(kubectl exec -n "${VAULT_NS}" vault-0 -- vault status -format=json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('sealed', True))" 2>/dev/null || echo "true")
  if [[ "$SEAL_STATUS" == "False" ]] || [[ "$SEAL_STATUS" == "false" ]]; then
    log "KMS auto-unseal confirmed — Vault is unsealed."
  else
    warn "Vault is still sealed after init. KMS auto-unseal may not be configured correctly."
    exit 1
  fi
fi

# ─── Authenticate ──────────────────────────────────────────────────

if [[ -f "${INIT_FILE}" ]]; then
  ROOT_TOKEN=$(python3 -c "import json; print(json.load(open('${INIT_FILE}'))['root_token'])")
else
  echo ""
  echo "Enter Vault root token (from vault-init-${ENV}.json):"
  read -rs ROOT_TOKEN
fi

# ─── Enable KV v2 secrets engine ──────────────────────────────────

log "Enabling KV v2 secrets engine at secret/ ..."
kubectl exec -n "${VAULT_NS}" vault-0 -- env VAULT_TOKEN="${ROOT_TOKEN}" \
  vault secrets enable -path=secret -version=2 kv 2>/dev/null \
  || log "KV v2 engine already enabled at secret/"

# ─── Enable Kubernetes auth ────────────────────────────────────────

log "Enabling Kubernetes auth method..."
kubectl exec -n "${VAULT_NS}" vault-0 -- env VAULT_TOKEN="${ROOT_TOKEN}" \
  vault auth enable kubernetes 2>/dev/null \
  || log "Kubernetes auth already enabled"

log "Configuring Kubernetes auth..."
kubectl exec -n "${VAULT_NS}" vault-0 -- env VAULT_TOKEN="${ROOT_TOKEN}" \
  vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443"

# ─── Create policies ──────────────────────────────────────────────

log "Creating Vault policies..."

# kubectl exec must use -i so heredoc stdin reaches `vault policy write ... -` in the pod.
kubectl exec -i -n "${VAULT_NS}" vault-0 -- env VAULT_TOKEN="${ROOT_TOKEN}" \
  vault policy write platform-read - <<'POLICY'
path "secret/data/platform/*" {
  capabilities = ["read", "list"]
}
POLICY

kubectl exec -i -n "${VAULT_NS}" vault-0 -- env VAULT_TOKEN="${ROOT_TOKEN}" \
  vault policy write streaming-read - <<'POLICY'
path "secret/data/streaming/*" {
  capabilities = ["read", "list"]
}
POLICY

kubectl exec -i -n "${VAULT_NS}" vault-0 -- env VAULT_TOKEN="${ROOT_TOKEN}" \
  vault policy write batch-read - <<'POLICY'
path "secret/data/batch/*" {
  capabilities = ["read", "list"]
}
POLICY

kubectl exec -i -n "${VAULT_NS}" vault-0 -- env VAULT_TOKEN="${ROOT_TOKEN}" \
  vault policy write eso-read-all - <<'POLICY'
path "secret/data/*" {
  capabilities = ["read", "list"]
}
path "secret/metadata/*" {
  capabilities = ["read", "list"]
}
POLICY

# ─── Create Kubernetes auth roles ──────────────────────────────────

log "Creating Kubernetes auth roles..."

kubectl exec -n "${VAULT_NS}" vault-0 -- env VAULT_TOKEN="${ROOT_TOKEN}" \
  vault write auth/kubernetes/role/eso \
  bound_service_account_names=external-secrets-operator \
  bound_service_account_namespaces=security \
  policies=eso-read-all \
  ttl=1h

kubectl exec -n "${VAULT_NS}" vault-0 -- env VAULT_TOKEN="${ROOT_TOKEN}" \
  vault write auth/kubernetes/role/platform \
  bound_service_account_names=default \
  bound_service_account_namespaces=platform \
  policies=platform-read \
  ttl=1h

kubectl exec -n "${VAULT_NS}" vault-0 -- env VAULT_TOKEN="${ROOT_TOKEN}" \
  vault write auth/kubernetes/role/batch \
  bound_service_account_names=airflow,spark \
  bound_service_account_namespaces=batch \
  policies=batch-read \
  ttl=1h

kubectl exec -n "${VAULT_NS}" vault-0 -- env VAULT_TOKEN="${ROOT_TOKEN}" \
  vault write auth/kubernetes/role/streaming \
  bound_service_account_names=flink,default \
  bound_service_account_namespaces=streaming \
  policies=streaming-read \
  ttl=1h

# ─── Seed initial secrets ─────────────────────────────────────────

log "Seeding placeholder secrets (update with real values later)..."

kubectl exec -n "${VAULT_NS}" vault-0 -- env VAULT_TOKEN="${ROOT_TOKEN}" \
  vault kv put secret/platform/tfl-api-key \
  value="REPLACE_ME" 2>/dev/null || true

kubectl exec -n "${VAULT_NS}" vault-0 -- env VAULT_TOKEN="${ROOT_TOKEN}" \
  vault kv put secret/platform/gemini-api-key \
  value="REPLACE_ME" 2>/dev/null || true

kubectl exec -n "${VAULT_NS}" vault-0 -- env VAULT_TOKEN="${ROOT_TOKEN}" \
  vault kv put secret/platform/cloudflare \
  api-token="REPLACE_ME" 2>/dev/null || true

kubectl exec -n "${VAULT_NS}" vault-0 -- env VAULT_TOKEN="${ROOT_TOKEN}" \
  vault kv put secret/platform/keycloak \
  admin-password="REPLACE_ME" \
  airflow-client-id="REPLACE_ME" \
  airflow-client-secret="REPLACE_ME" \
  argocd-client-secret="REPLACE_ME" \
  grafana-client-secret="REPLACE_ME" \
  flink-ui-client-secret="REPLACE_ME" \
  kafka-ui-client-secret="REPLACE_ME" \
  kafka-flink-client-secret="REPLACE_ME" \
  kafka-tfl-producer-client-secret="REPLACE_ME" \
  openvelox-api-client-secret="REPLACE_ME" 2>/dev/null || true

kubectl exec -n "${VAULT_NS}" vault-0 -- env VAULT_TOKEN="${ROOT_TOKEN}" \
  vault kv put secret/platform/github \
  pat="REPLACE_ME" 2>/dev/null || true

# The Postgres *superuser* password — actual k8s secret name is
# `postgres-secrets` (created by infra/terraform/bootstrap-secrets). Older
# revisions of this script looked for `postgres-password`, which never
# existed, so the fallback below silently seeded `REPLACE_ME` into Vault.
PG_PASS=$(kubectl get secret -n platform postgres-secrets -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "REPLACE_ME")
kubectl exec -n "${VAULT_NS}" vault-0 -- env VAULT_TOKEN="${ROOT_TOKEN}" \
  vault kv put secret/platform/postgres \
  password="${PG_PASS}" 2>/dev/null || true

# The `trino-client-id` / `trino-client-secret` keys are seeded with the
# root credential so Trino can connect on a fresh cluster *before*
# scripts/polaris-bootstrap-principals.sh has run. That script replaces
# them with a per-service principal minted via Polaris's management API.
# The ExternalSecret `trino-polaris-credential` (see external-secrets.yaml)
# reads these two keys and surfaces them to the Trino pod as the env var
# POLARIS_TRINO_CREDENTIAL (format: `clientId:clientSecret`).
kubectl exec -n "${VAULT_NS}" vault-0 -- env VAULT_TOKEN="${ROOT_TOKEN}" \
  vault kv put secret/platform/polaris \
  root-client-id="root" \
  root-client-secret="polaris-root-secret" \
  trino-client-id="root" \
  trino-client-secret="polaris-root-secret" 2>/dev/null || true

# Polaris talks to Postgres as a **dedicated** `polaris` role (created by
# the postgresql-initdb ConfigMap on fresh clusters). Credentials live in
# the `polaris-secrets` k8s secret in `platform`, written by the
# bootstrap-secrets Terraform alongside postgres/keycloak/airflow. We
# mirror that password into Vault so the `polaris-persistence-vault`
# ExternalSecret in the `data` namespace can surface it to the Polaris
# pod. Falling back to REPLACE_ME keeps this script non-fatal on partial
# bootstraps but Polaris will crash-loop until the real password is in.
POLARIS_DB_PASS=$(kubectl get secret -n platform polaris-secrets -o jsonpath='{.data.db-password}' 2>/dev/null | base64 -d 2>/dev/null || echo "REPLACE_ME")
kubectl exec -n "${VAULT_NS}" vault-0 -- env VAULT_TOKEN="${ROOT_TOKEN}" \
  vault kv put secret/platform/polaris-persistence \
  username="polaris" \
  password="${POLARIS_DB_PASS}" \
  jdbcUrl="jdbc:postgresql://postgresql.platform.svc.cluster.local:5432/polaris" 2>/dev/null || true

# Apicurio Registry uses its own `apicurio` Postgres role (also created by
# the postgresql-initdb ConfigMap). Mirror the bootstrap-seeded password
# from platform → Vault so the `apicurio-db-credentials` ExternalSecret in
# the `kafka` namespace resolves. Same REPLACE_ME fallback behaviour as
# polaris — Apicurio crash-loops until a real password is in.
APICURIO_DB_PASS=$(kubectl get secret -n platform apicurio-secrets -o jsonpath='{.data.db-password}' 2>/dev/null | base64 -d 2>/dev/null || echo "REPLACE_ME")
kubectl exec -n "${VAULT_NS}" vault-0 -- env VAULT_TOKEN="${ROOT_TOKEN}" \
  vault kv put secret/platform/apicurio \
  db-password="${APICURIO_DB_PASS}" 2>/dev/null || true

COOKIE_SECRET=$(python3 -c "import secrets,base64; print(base64.b64encode(secrets.token_bytes(16)).decode())" 2>/dev/null)
kubectl exec -n "${VAULT_NS}" vault-0 -- env VAULT_TOKEN="${ROOT_TOKEN}" \
  vault kv put secret/platform/oauth2-proxy \
  cookie-secret="${COOKIE_SECRET}" 2>/dev/null || true

# ─── Done ──────────────────────────────────────────────────────────

log "Vault initialization complete!"
echo ""
echo "Summary:"
echo "  - KV v2 engine enabled at secret/"
echo "  - Kubernetes auth configured"
echo "  - Policies: platform-read, streaming-read, batch-read, eso-read-all"
echo "  - Auth roles: eso, platform, batch, streaming"
echo "  - Placeholder secrets seeded (update with real values)"
echo ""
echo "Next steps:"
echo "  1. Store ${INIT_FILE} securely (e.g. password manager)"
echo "  2. Write real secrets to Vault:"
echo "     vault kv put secret/platform/tfl-api-key value=<KEY>"
echo "     vault kv put secret/platform/gemini-api-key value=<KEY>"
echo "     vault kv put secret/platform/cloudflare api-token=<TOKEN>"
echo "     vault kv put secret/platform/github pat=<GITHUB_PAT>"
echo "  3. Run: scripts/tf-apply.sh dns ${ENV}"
echo "  4. Verify ESO can read: kubectl get externalsecrets -A"
