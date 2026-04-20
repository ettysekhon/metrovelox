#!/usr/bin/env bash
#
# OpenVelox — scaffold a new environment
# ========================================
#
# Creates the full directory structure for a new deployment environment.
# After running, fill in the TODO placeholders with actual values.
#
# Usage:
#   bash scripts/new-env.sh <env-name> <domain> <gcp-project-id>
#
# Example:
#   bash scripts/new-env.sh staging example.com my-gcp-project-staging

set -euo pipefail

ENV="${1:?Usage: $0 <env-name> <domain> <gcp-project-id>}"
DOMAIN="${2:?Usage: $0 <env-name> <domain> <gcp-project-id>}"
GCP_PROJECT="${3:?Usage: $0 <env-name> <domain> <gcp-project-id>}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${ENV}"

log() { echo "==> $*"; }

if [[ "${ENV}" == "prod" ]]; then
  PREFIX=""
fi

host() {
  if [[ -n "${PREFIX}" ]]; then
    echo "${PREFIX}.${1}.${DOMAIN}"
  else
    echo "${1}.${DOMAIN}"
  fi
}

# ─── Terraform tfvars ──────────────────────────────────────────────

log "Creating infra/terraform/environments/${ENV}.tfvars"
mkdir -p "${REPO_ROOT}/infra/terraform/environments"
cat > "${REPO_ROOT}/infra/terraform/environments/${ENV}.tfvars" <<EOF
# ${ENV^} environment — non-sensitive infrastructure configuration
# Used by: scripts/tf-apply.sh <stack> ${ENV}

project_id   = "${GCP_PROJECT}"
domain       = "${DOMAIN}"
region       = "europe-west2"
zone         = "europe-west2-a"
cluster_name = "openvelox-${ENV}"

env_prefix   = "${PREFIX}"

cloudflare_zone_id = ""  # TODO: populate

realm_name         = "openvelox"
realm_display_name = "OpenVelox ${ENV^}"
EOF

# ─── K8s overlays ──────────────────────────────────────────────────

create_kustomization() {
  local dir="$1"
  shift
  mkdir -p "${dir}"
  {
    echo "apiVersion: kustomize.config.k8s.io/v1beta1"
    echo "kind: Kustomization"
    echo "resources:"
    echo "  - ../../base"
    if [[ $# -gt 0 ]]; then
      echo "patches:"
      for patch in "$@"; do
        echo "  - path: ${patch}"
      done
    fi
  } > "${dir}/kustomization.yaml"
}

CERTMAP="${DOMAIN//./-}-certmap"

# Gateway
GW_DIR="${REPO_ROOT}/infra/k8s/gateway/overlays/${ENV}"
create_kustomization "${GW_DIR}" "patches-gateway.yaml" "patches-routes.yaml"

cat > "${GW_DIR}/patches-gateway.yaml" <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: openvelox-gateway
  namespace: platform
  annotations:
    networking.gke.io/certmap: ${CERTMAP}
EOF

SERVICES=(
  "keycloak-route:platform:auth"
  "argocd-route:argocd:argocd"
  "orchestrator-route:batch:orchestrator"
  "query-engine-route:data:query"
  "streaming-console-route:streaming:streaming"
  "vault-route:security:vault"
  "catalog-route:data:catalog"
  "authz-route:security:authz"
  "stream-processing-route:streaming:stream-processing"
  "grafana-route:monitoring:grafana"
)

{
  first=true
  for svc in "${SERVICES[@]}"; do
    IFS=: read -r name ns subdomain <<< "${svc}"
    [[ "${first}" == true ]] || echo "---"
    first=false
    cat <<YAML
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ${name}
  namespace: ${ns}
spec:
  hostnames:
    - "$(host "${subdomain}")"
YAML
  done
} > "${GW_DIR}/patches-routes.yaml"

# RBAC
RBAC_DIR="${REPO_ROOT}/infra/k8s/rbac/overlays/${ENV}"
create_kustomization "${RBAC_DIR}" "patches-service-accounts.yaml"
cat > "${RBAC_DIR}/patches-service-accounts.yaml" <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: airflow
  namespace: batch
  annotations:
    iam.gke.io/gcp-service-account: airflow-sa@${GCP_PROJECT}.iam.gserviceaccount.com
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: spark
  namespace: batch
  annotations:
    iam.gke.io/gcp-service-account: spark-sa@${GCP_PROJECT}.iam.gserviceaccount.com
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: flink
  namespace: streaming
  annotations:
    iam.gke.io/gcp-service-account: flink-sa@${GCP_PROJECT}.iam.gserviceaccount.com
EOF

# ArgoCD
ARGO_DIR="${REPO_ROOT}/infra/k8s/platform/argocd/overlays/${ENV}"
create_kustomization "${ARGO_DIR}" "patches-argocd-cm.yaml"
cat > "${ARGO_DIR}/patches-argocd-cm.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
  namespace: argocd
data:
  url: https://$(host argocd)
  oidc.config: |
    name: Keycloak
    issuer: https://$(host auth)/realms/openvelox
    clientID: argocd
    clientSecret: \$oidc.keycloak.clientSecret
    requestedScopes: ["openid", "profile", "email", "groups"]
    requestedIDTokenClaims:
      groups:
        essential: true
EOF

# Keycloak
KC_DIR="${REPO_ROOT}/infra/k8s/platform/keycloak/overlays/${ENV}"
create_kustomization "${KC_DIR}" "patches-keycloak.yaml"
cat > "${KC_DIR}/patches-keycloak.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak
  namespace: platform
spec:
  template:
    spec:
      containers:
        - name: keycloak
          env:
            - name: KC_HOSTNAME
              value: "https://$(host auth)"
            - name: KC_HOSTNAME_ADMIN
              value: "https://$(host auth)"
EOF

# ─── ArgoCD env apps ───────────────────────────────────────────────

ARGO_ENV_DIR="${REPO_ROOT}/argocd/envs/${ENV}"
PROD_DIR="${REPO_ROOT}/argocd/envs/prod"

if [[ -d "${PROD_DIR}" ]]; then
  log "Creating argocd/envs/${ENV}/ from prod template"
  mkdir -p "${ARGO_ENV_DIR}"
  for f in "${PROD_DIR}"/*.yaml; do
    fname=$(basename "$f")
    sed -e "s|overlays/prod|overlays/${ENV}|g" \
        -e "s|values-prod\.yaml|values-${ENV}.yaml|g" \
        "$f" > "${ARGO_ENV_DIR}/${fname}"
  done
fi

# ─── Helm values ───────────────────────────────────────────────────

for chart_dir in airflow kube-prometheus-stack trino vault; do
  prod_values="${REPO_ROOT}/helm/${chart_dir}/values-prod.yaml"
  dev_values="${REPO_ROOT}/helm/${chart_dir}/values-${ENV}.yaml"
  if [[ -f "${prod_values}" ]]; then
    log "Creating helm/${chart_dir}/values-${ENV}.yaml"
    cp "${prod_values}" "${dev_values}"
  fi
done

# ─── Done ──────────────────────────────────────────────────────────

log "Environment '${ENV}' scaffolded!"
echo ""
echo "Next steps:"
echo "  1. Review and fill in TODOs in infra/terraform/environments/${ENV}.tfvars"
echo "  2. Review helm values in helm/*/values-${ENV}.yaml"
echo "  3. Update GCP project IDs, domain, and image tags in K8s patches"
echo "  4. Run: scripts/tf-apply.sh all ${ENV}"
echo "  5. Bootstrap with: scripts/bootstrap.sh --env ${ENV}"
