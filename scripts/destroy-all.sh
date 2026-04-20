#!/usr/bin/env bash
#
# OpenVelox Destroy — tear down all Terraform-managed resources.
# ==============================================================
#
# Destroys stacks in reverse dependency order using tf-apply.sh.
# The GCP project itself is NOT deleted (manual step for safety).
#
# Usage:
#   scripts/destroy-all.sh <env>
#
# Example:
#   scripts/destroy-all.sh prod

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV="${1:?Usage: $0 <env>}"

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

echo "OpenVelox Destroy"
echo "===================="
echo ""
echo "  Environment : ${ENV}"
echo "  Project     : ${PROJECT_ID}"
echo "  Domain      : ${DOMAIN}"
echo ""
echo "WARNING: This will destroy ALL Terraform-managed resources."
echo ""
read -p "Type 'destroy' to confirm: " confirm
if [[ "$confirm" != "destroy" ]]; then
  echo "Aborted."
  exit 1
fi

DESTROY_ORDER=(
  keycloak-realm
  dns
  argocd-bootstrap
  tls
  bootstrap-secrets
  storage
  cluster
  foundation
)

for stack in "${DESTROY_ORDER[@]}"; do
  echo ""
  echo "--- Destroying ${stack} ---"
  bash "${REPO_ROOT}/scripts/tf-apply.sh" "${stack}" "${ENV}" destroy || {
    echo "  (${stack} destroy failed or had no state — continuing)"
  }
done

echo ""
echo "All Terraform stacks destroyed."
echo ""
echo "Manual cleanup (if needed):"
echo "  - Delete TF state bucket: gcloud storage buckets delete gs://tfstate-${PROJECT_ID}"
echo "  - Delete GCP project:     gcloud projects delete ${PROJECT_ID}"
