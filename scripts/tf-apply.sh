#!/usr/bin/env bash
#
# Terraform Apply Wrapper — production-grade, reproducible stack execution.
# ========================================================================
#
# Reads non-sensitive config from environments/<env>.tfvars.
# Reads sensitive values (API tokens, passwords) from Vault.
# Auto-discovers dynamic values (Gateway IP, ACME target) from live infra.
#
# Usage:
#   scripts/tf-apply.sh <stack> <env> [plan|apply|destroy] [extra-tf-args...]
#
# Examples:
#   scripts/tf-apply.sh dns dev                    # terraform apply
#   scripts/tf-apply.sh dns prod plan              # terraform plan only
#   scripts/tf-apply.sh keycloak-realm dev          # terraform apply
#   scripts/tf-apply.sh foundation dev              # terraform apply
#   scripts/tf-apply.sh all dev                     # apply all stacks in order
#
# Prerequisites:
#   - kubectl context pointing to the target cluster
#   - gcloud authenticated for the target project
#   - Vault initialized with secrets (see scripts/vault-init.sh)
#   - For keycloak-realm: Keycloak must be reachable (default https://auth.<domain>).
#     Cloudflare 525 = TLS to origin failed — fix SSL or set KEYCLOAK_TERRAFORM_URL (see script body).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STACK="${1:?Usage: $0 <stack> <env> [plan|apply|destroy]}"
ENV="${2:?Usage: $0 <stack> <env> [plan|apply|destroy]}"
ACTION="${3:-apply}"
shift 3 2>/dev/null || shift $# 2>/dev/null || true
EXTRA_ARGS=("$@")

TFVARS="${REPO_ROOT}/infra/terraform/environments/${ENV}.tfvars"
VAULT_NS="security"

log()  { echo "==> $*"; }
warn() { echo "  ⚠  $*"; }

# ─── Validate inputs ──────────────────────────────────────────────

if [[ ! -f "${TFVARS}" ]]; then
  echo "ERROR: Environment file not found: ${TFVARS}"
  echo "Available: $(ls "${REPO_ROOT}/infra/terraform/environments/"*.tfvars 2>/dev/null | xargs -I{} basename {} .tfvars)"
  exit 1
fi

if [[ "${ACTION}" != "plan" && "${ACTION}" != "apply" && "${ACTION}" != "destroy" ]]; then
  echo "ERROR: Action must be 'plan', 'apply', or 'destroy'. Got: ${ACTION}"
  exit 1
fi

# ─── Read non-sensitive config from tfvars ─────────────────────────

read_tfvar() {
  grep "^${1} *=" "${TFVARS}" | sed 's/^[^=]*= *"\([^"]*\)".*/\1/' | head -1
}

PROJECT_ID=$(read_tfvar project_id)
DOMAIN=$(read_tfvar domain)
REGION=$(read_tfvar region)
ZONE=$(read_tfvar zone)
CLUSTER_NAME=$(read_tfvar cluster_name)
CLOUDFLARE_ZONE_ID=$(read_tfvar cloudflare_zone_id)
TF_BUCKET="tfstate-${PROJECT_ID}"

# ─── Vault helper ──────────────────────────────────────────────────

vault_get() {
  local path="$1"
  local key="$2"
  local init_file="${REPO_ROOT}/vault-init-${ENV}.json"
  local token=""

  if [[ -f "${init_file}" ]]; then
    token=$(python3 -c "import json; print(json.load(open('${init_file}'))['root_token'])")
  elif [[ -n "${VAULT_TOKEN:-}" ]]; then
    token="${VAULT_TOKEN}"
  else
    echo "ERROR: No Vault token found. Set VAULT_TOKEN or ensure vault-init-${ENV}.json exists." >&2
    exit 1
  fi

  kubectl exec -n "${VAULT_NS}" vault-0 -- \
    env VAULT_TOKEN="${token}" \
    vault kv get -field="${key}" "${path}" 2>/dev/null
}

# ─── Stack-specific variable builders ──────────────────────────────

build_vars_foundation() {
  TF_VARS=(-var "project_id=${PROJECT_ID}" -var "region=${REGION}")
}
build_vars_cluster() {
  TF_VARS=(-var "project_id=${PROJECT_ID}" -var "region=${REGION}" -var "zone=${ZONE}" -var "cluster_name=${CLUSTER_NAME}" -var "domain=${DOMAIN}")
}
build_vars_storage() {
  TF_VARS=(-var "project_id=${PROJECT_ID}" -var "region=${REGION}")
}
build_vars_bootstrap_secrets() {
  TF_VARS=(-var "project_id=${PROJECT_ID}" -var "region=${REGION}" -var "zone=${ZONE}" -var "cluster_name=${CLUSTER_NAME}")
}
build_vars_tls() {
  TF_VARS=(-var "project_id=${PROJECT_ID}" -var "region=${REGION}" -var "domain=${DOMAIN}")
}

build_vars_dns() {
  log "Fetching Cloudflare API token from Vault..."
  local cf_token
  cf_token=$(vault_get secret/platform/cloudflare api-token)

  log "Discovering Gateway IP from cluster..."
  local gateway_ip
  gateway_ip=$(kubectl get gateway openvelox-gateway -n platform -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "")
  if [[ -z "${gateway_ip}" ]]; then
    warn "Gateway has no IP yet. Checking GKE forwarding rules..."
    gateway_ip=$(kubectl get gateway openvelox-gateway -n platform -o jsonpath='{.metadata.annotations.networking\.gke\.io/addresses}' 2>/dev/null || echo "")
  fi
  if [[ -z "${gateway_ip}" ]]; then
    echo "ERROR: Gateway IP not available. Ensure the Gateway is Programmed." >&2
    exit 1
  fi

  log "Discovering ACME challenge target from TLS stack..."
  local acme_target=""
  pushd "${REPO_ROOT}/infra/terraform/tls" > /dev/null
  terraform init -reconfigure -backend-config="bucket=${TF_BUCKET}" -backend-config="prefix=tls" -input=false > /dev/null 2>&1
  acme_target=$(terraform output -json dns_auth_record 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['value'])" 2>/dev/null || echo "")
  popd > /dev/null

  TF_VARS=(-var "cloudflare_api_token=${cf_token}" -var "cloudflare_zone_id=${CLOUDFLARE_ZONE_ID}" -var "domain=${DOMAIN}" -var "gateway_ip=${gateway_ip}")
  if [[ -n "${acme_target}" ]]; then
    TF_VARS+=(-var "acme_challenge_cname_target=${acme_target}")
  fi
}

build_vars_argocd_bootstrap() {
  TF_VARS=(-var "project_id=${PROJECT_ID}" -var "region=${REGION}" -var "zone=${ZONE}" -var "cluster_name=${CLUSTER_NAME}" -var "domain=${DOMAIN}" -var "env=${ENV}")
}

build_vars_keycloak_realm() {
  log "Fetching Keycloak admin password from Vault..."
  local kc_password
  kc_password=$(vault_get secret/platform/keycloak admin-password)
  if [[ "${kc_password}" == "REPLACE_ME" ]]; then
    log "Keycloak admin-password in Vault is placeholder. Reading from K8s secret..."
    kc_password=$(kubectl get secret keycloak-secrets -n platform -o jsonpath='{.data.admin-password}' | base64 -d)
  fi

  local realm_name realm_display_name
  realm_name=$(read_tfvar realm_name)
  realm_display_name=$(read_tfvar realm_display_name)

  # Default: public URL (needs healthy TLS from Cloudflare → GKE). If you see Cloudflare 525,
  # fix origin SSL or bypass the edge temporarily, e.g.:
  #   kubectl port-forward -n platform svc/keycloak 8080:8080
  #   KEYCLOAK_TERRAFORM_URL=http://127.0.0.1:8080 scripts/tf-apply.sh keycloak-realm prod plan
  local kc_url="https://auth.${DOMAIN}"
  if [[ -n "${KEYCLOAK_TERRAFORM_URL:-}" ]]; then
    kc_url="${KEYCLOAK_TERRAFORM_URL}"
    log "Using KEYCLOAK_TERRAFORM_URL for Keycloak provider (bypasses public auth URL)."
  fi

  TF_VARS=(-var "keycloak_url=${kc_url}" -var "keycloak_admin_password=${kc_password}" -var "domain=${DOMAIN}" -var "realm_name=${realm_name:-openvelox}" -var "realm_display_name=${realm_display_name:-OpenVelox}" -var "platform_admin_password=ChangeMeOnFirstLogin123!" -var "create_platform_admin=true")
}

# ─── Run Terraform ─────────────────────────────────────────────────

run_stack() {
  local stack="$1"
  local stack_dir="${REPO_ROOT}/infra/terraform/${stack}"

  if [[ ! -d "${stack_dir}" ]]; then
    echo "ERROR: Stack directory not found: ${stack_dir}"
    exit 1
  fi

  log "Stack: ${stack} | Env: ${ENV} | Action: ${ACTION}"

  # Build stack-specific variables (sets TF_VARS array)
  TF_VARS=()
  local build_fn="build_vars_${stack//-/_}"
  if declare -f "${build_fn}" > /dev/null 2>&1; then
    ${build_fn}
  else
    warn "No variable builder for '${stack}' — using tfvars file only"
    TF_VARS=(-var-file="${TFVARS}")
  fi

  cd "${stack_dir}"

  log "Initializing backend (bucket=${TF_BUCKET}, prefix=${stack})..."
  terraform init -reconfigure \
    -backend-config="bucket=${TF_BUCKET}" \
    -backend-config="prefix=${stack}" \
    -input=false

  log "Running terraform ${ACTION}..."
  if [[ "${ACTION}" == "apply" || "${ACTION}" == "destroy" ]]; then
    terraform "${ACTION}" -auto-approve "${TF_VARS[@]}" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
  else
    terraform "${ACTION}" "${TF_VARS[@]}" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
  fi

  cd "${REPO_ROOT}"
  log "Stack '${stack}' ${ACTION} complete."

  if [[ "${stack}" == "keycloak-realm" && "${ACTION}" == "apply" ]]; then
    echo ""
    log "Next: run 'GITHUB_PAT=<token> bash scripts/post-deploy.sh ${ENV}'"
    log "This wires Keycloak client secrets to Vault and K8s."
  fi

  echo ""
}

# ─── Ordered stack execution (for "all") ───────────────────────────

STACK_ORDER=(
  foundation
  cluster
  storage
  bootstrap-secrets
  tls
  argocd-bootstrap
  dns
  keycloak-realm
)

if [[ "${STACK}" == "all" ]]; then
  log "Applying ALL stacks for '${ENV}' in dependency order..."
  echo ""
  for s in "${STACK_ORDER[@]}"; do
    run_stack "${s}"
  done
  log "All stacks applied successfully."
else
  run_stack "${STACK}"
fi
