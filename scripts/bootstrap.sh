#!/usr/bin/env bash
#
# OpenVelox Bootstrap — fully idempotent
# ========================================
# Every command is safe to re-run. Uses guard checks, --dry-run | apply,
# helm upgrade --install, and terraform -reconfigure throughout.
#
# Usage:
#   scripts/bootstrap.sh --env <env>             # reads from tfvars + env.sh
#   source env.sh && bash scripts/bootstrap.sh   # legacy (env vars only)
#
# To resume after a failure, just re-run — it skips completed steps.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Parse --env flag to load config from tfvars
if [[ "${1:-}" == "--env" ]]; then
  ENV="${2:?Usage: $0 --env <env-name>}"
  TFVARS="${REPO_ROOT}/infra/terraform/environments/${ENV}.tfvars"
  if [[ ! -f "${TFVARS}" ]]; then
    echo "ERROR: ${TFVARS} not found"
    exit 1
  fi
  _read_tfvar() {
    grep "^${1} *=" "${TFVARS}" | sed 's/^[^=]*= *"\([^"]*\)".*/\1/' | head -1
  }
  export PROJECT_ID="${PROJECT_ID:-$(_read_tfvar project_id)}"
  export REGION="${REGION:-$(_read_tfvar region)}"
  export ZONE="${ZONE:-$(_read_tfvar zone)}"
  export GKE_CLUSTER_NAME="${GKE_CLUSTER_NAME:-$(_read_tfvar cluster_name)}"
  export DOMAIN="${DOMAIN:-$(_read_tfvar domain)}"
  export GCS_BUCKET="${GCS_BUCKET:-${PROJECT_ID}-lakehouse}"
fi

: "${PROJECT_ID:?PROJECT_ID not set. Run: source env.sh or use --env <env>}"
: "${BILLING_ACCOUNT_ID:=${BILLING_ACCOUNT_ID:-}}"
: "${REGION:?REGION not set}"
: "${ZONE:?ZONE not set}"
: "${GKE_CLUSTER_NAME:?GKE_CLUSTER_NAME not set}"
: "${GCS_BUCKET:?GCS_BUCKET not set}"

TF_BUCKET="tfstate-${PROJECT_ID}"

log()  { echo "==> $*"; }
skip() { echo "    (already exists — skipping)"; }

# ─── Phase 0: GCP project ────────────────────────────────────────────

log "Phase 0.1: GCP project"
if gcloud projects describe "$PROJECT_ID" &>/dev/null; then
  skip
else
  gcloud projects create "$PROJECT_ID" --name="OpenVelox"
fi
gcloud config set project "$PROJECT_ID"

log "Phase 0.2: Link billing"
gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT_ID" 2>/dev/null || true

log "Phase 0.3: Terraform state bucket"
if gcloud storage buckets describe "gs://${TF_BUCKET}" &>/dev/null; then
  skip
else
  gcloud storage buckets create "gs://${TF_BUCKET}" --location="$REGION"
fi
gcloud storage buckets update "gs://${TF_BUCKET}" --versioning

# ─── Phase 1: Terraform ──────────────────────────────────────────────

tf_apply() {
  local stack="$1"; shift
  log "Phase 1: Terraform — ${stack}"
  cd "${REPO_ROOT}/infra/terraform/${stack}"
  terraform init -reconfigure \
    -backend-config="bucket=${TF_BUCKET}" \
    -backend-config="prefix=${stack}"
  terraform apply -auto-approve "$@"
  cd "${REPO_ROOT}"
}

tf_apply foundation \
  -var="project_id=${PROJECT_ID}" \
  -var="region=${REGION}"

tf_apply cluster \
  -var="project_id=${PROJECT_ID}" \
  -var="region=${REGION}" \
  -var="zone=${ZONE}"

tf_apply storage \
  -var="project_id=${PROJECT_ID}" \
  -var="region=${REGION}"

log "Phase 1: Fetching GKE credentials"
gcloud container clusters get-credentials "$GKE_CLUSTER_NAME" \
  --zone "$ZONE" --project "$PROJECT_ID"

# ─── Phase 2: Namespaces + Argo CD ───────────────────────────────────

log "Phase 2.1: Namespaces"
for ns in argocd platform security data batch streaming monitoring; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

log "Phase 2.2: Argo CD"
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --set server.service.type=ClusterIP \
  --wait --timeout=300s

log "Phase 2.3: ArgoCD config overlay (OIDC + RBAC)"
kubectl apply -k "${REPO_ROOT}/infra/k8s/platform/argocd/overlays/${ENV:-prod}"
kubectl rollout restart deployment argocd-server -n argocd

# ─── Phase 3: PostgreSQL + Keycloak ──────────────────────────────────

log "Phase 3.1: Create all secrets required by PostgreSQL StatefulSet"
kubectl get secret postgres-secrets -n platform &>/dev/null || \
  kubectl create secret generic postgres-secrets \
    --namespace platform \
    --from-literal=password="$(openssl rand -hex 16)"

KC_DB_PASS=""
kubectl get secret keycloak-secrets -n platform &>/dev/null || {
  KC_DB_PASS="$(openssl rand -hex 16)"
  kubectl create secret generic keycloak-secrets \
    --namespace platform \
    --from-literal=admin-password="$(openssl rand -hex 16)" \
    --from-literal=db-password="$KC_DB_PASS"
}

AIRFLOW_DB_PASS=""
kubectl get secret airflow-secrets -n platform &>/dev/null || {
  AIRFLOW_DB_PASS="$(openssl rand -hex 16)"
  kubectl create secret generic airflow-secrets \
    --namespace platform \
    --from-literal=db-password="$AIRFLOW_DB_PASS"
}

log "Phase 3.2: PostgreSQL ConfigMap + StatefulSet"
kubectl apply -f "${REPO_ROOT}/infra/k8s/platform/postgresql/initdb-configmap.yaml"
kubectl apply -f "${REPO_ROOT}/infra/k8s/platform/postgresql/statefulset.yaml"
kubectl wait --for=condition=Ready pod/postgresql-0 -n platform --timeout=300s

log "Phase 3.3: Create databases + roles"
for db in keycloak airflow polaris; do
  kubectl exec -n platform postgresql-0 -- \
    psql -U openvelox -d openvelox -tc \
    "SELECT 1 FROM pg_database WHERE datname='${db}'" 2>/dev/null \
  | grep -q 1 \
  || kubectl exec -n platform postgresql-0 -- \
    psql -U openvelox -d openvelox -c "CREATE DATABASE ${db};" \
  || true
done

if [[ -n "${KC_DB_PASS}" ]]; then
  log "Phase 3.3: Keycloak PostgreSQL user"
  kubectl exec -n platform postgresql-0 -- \
    psql -U openvelox -d openvelox -c \
    "DO \$\$ BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'keycloak') THEN
        CREATE ROLE keycloak WITH LOGIN PASSWORD '${KC_DB_PASS}';
      END IF;
    END \$\$;
    GRANT ALL PRIVILEGES ON DATABASE keycloak TO keycloak;"

  kubectl exec -n platform postgresql-0 -- \
    psql -U openvelox -d keycloak -c \
    "GRANT ALL ON SCHEMA public TO keycloak;
     ALTER SCHEMA public OWNER TO keycloak;"
fi

log "Phase 3.3: Keycloak Deployment (via ${ENV:-prod} overlay)"
kubectl apply -k "${REPO_ROOT}/infra/k8s/platform/keycloak/overlays/${ENV:-prod}"
kubectl wait --for=condition=Available deployment/keycloak -n platform --timeout=300s

# ─── Phase 4: Vault ───────────────────────────────────────────────────

log "Phase 4: Vault"
helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
helm repo update
VAULT_VALUES=("-f" "${REPO_ROOT}/helm/vault/values-gke.yaml")
if [[ -f "${REPO_ROOT}/helm/vault/values-${ENV:-prod}.yaml" ]]; then
  VAULT_VALUES+=("-f" "${REPO_ROOT}/helm/vault/values-${ENV:-prod}.yaml")
fi
helm upgrade --install vault hashicorp/vault \
  --namespace security \
  "${VAULT_VALUES[@]}" \
  --wait --timeout=300s

log "Phase 4: Vault init (first time only)"
if ! kubectl exec -n security vault-0 -- vault status 2>/dev/null | grep -q "Sealed.*false"; then
  if [ ! -f "${REPO_ROOT}/vault-init.json" ]; then
    kubectl exec -n security vault-0 -- vault operator init \
      -key-shares=1 -key-threshold=1 -format=json > "${REPO_ROOT}/vault-init.json"
  fi
  VAULT_UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' "${REPO_ROOT}/vault-init.json")
  kubectl exec -n security vault-0 -- vault operator unseal "$VAULT_UNSEAL_KEY" || true
fi

# ─── Phase 5: Polaris (Iceberg REST Catalog) ─────────────────────────

log "Phase 5: Polaris — deployed via Helm (helm/polaris/values-gke.yaml)"

# ─── Phase 6: Spark Operator + Airflow ────────────────────────────────

log "Phase 6.1: Spark Operator"
helm repo add spark-operator https://kubeflow.github.io/spark-operator 2>/dev/null || true
helm repo update
helm upgrade --install spark-operator spark-operator/spark-operator \
  --namespace batch \
  --set webhook.enable=true \
  --set-string "tolerations[0].key=cloud.google.com/gke-spot" \
  --set-string "tolerations[0].operator=Equal" \
  --set-string "tolerations[0].value=true" \
  --set-string "tolerations[0].effect=NoSchedule" \
  --wait --timeout=300s

log "Phase 6.2: Spark KSA with Workload Identity"
SPARK_GSA="spark-sa@${PROJECT_ID}.iam.gserviceaccount.com"
kubectl create serviceaccount spark --namespace batch --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate serviceaccount spark --namespace batch \
  "iam.gke.io/gcp-service-account=${SPARK_GSA}" --overwrite

log "Phase 6.3: Airflow PostgreSQL user"
AIRFLOW_DB_PASS="$(openssl rand -hex 16)"
kubectl exec -n platform postgresql-0 -- \
  psql -U openvelox -d openvelox -c \
  "DO \$\$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'airflow') THEN
      CREATE ROLE airflow WITH LOGIN PASSWORD '${AIRFLOW_DB_PASS}';
    ELSE
      ALTER ROLE airflow WITH PASSWORD '${AIRFLOW_DB_PASS}';
    END IF;
  END \$\$;
  GRANT ALL PRIVILEGES ON DATABASE airflow TO airflow;"

kubectl exec -n platform postgresql-0 -- \
  psql -U openvelox -d airflow -c \
  "GRANT ALL ON SCHEMA public TO airflow;
   ALTER SCHEMA public OWNER TO airflow;"

# Keep platform/airflow-secrets and batch/airflow-metadata aligned with ${AIRFLOW_DB_PASS}
# (otherwise Helm values using metadataSecretName + airflow-secrets disagree with Postgres).
kubectl create secret generic airflow-secrets \
  --namespace platform \
  --from-literal=db-password="${AIRFLOW_DB_PASS}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic airflow-metadata \
  --namespace batch \
  --from-literal=connection="postgresql://airflow:${AIRFLOW_DB_PASS}@postgresql.platform.svc.cluster.local:5432/airflow" \
  --dry-run=client -o yaml | kubectl apply -f -

log "Phase 6.3: Airflow Helm install"
helm repo add apache-airflow https://airflow.apache.org 2>/dev/null || true
helm repo update
helm upgrade --install airflow apache-airflow/airflow \
  --namespace batch \
  -f "${REPO_ROOT}/helm/airflow/values-gke.yaml" \
  -f "${REPO_ROOT}/helm/airflow/values-${ENV:-prod}.yaml" \
  --no-hooks \
  --timeout=600s

# ─── Phase 7: Trino ──────────────────────────────────────────────────

log "Phase 7: Trino"
helm repo add trino https://trinodb.github.io/charts 2>/dev/null || true
helm repo update
helm uninstall trino --namespace data 2>/dev/null || true
kubectl delete pods -n data --all --force --grace-period=0 2>/dev/null || true
sleep 5
helm upgrade --install trino trino/trino \
  --namespace data \
  -f "${REPO_ROOT}/helm/trino/values-gke.yaml" \
  --wait --timeout=600s

# ─── Phase 7b: cert-manager ──────────────────────────────────────────

log "Phase 7b: cert-manager"
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
kubectl rollout status deployment/cert-manager -n cert-manager --timeout=120s
kubectl rollout status deployment/cert-manager-webhook -n cert-manager --timeout=120s

# ─── Phase 8: Strimzi Kafka (installed via ArgoCD strimzi-operator + kafka-cluster apps) ───
# No imperative helm install here — ArgoCD reconciles both the operator and
# the Kafka/KafkaNodePool CRs from Git.  See:
#   argocd/envs/prod/strimzi-operator.yaml   (Helm chart)
#   argocd/envs/prod/kafka-cluster.yaml      (Kustomize overlay with topics)

# ─── Phase 9: Flink Operator ─────────────────────────────────────────

log "Phase 9: Flink Operator"
helm repo add flink-operator https://downloads.apache.org/flink/flink-kubernetes-operator-1.14.0/ 2>/dev/null || true
helm repo update
helm upgrade --install flink-operator flink-operator/flink-kubernetes-operator \
  --namespace streaming \
  --set-string "tolerations[0].key=cloud.google.com/gke-spot" \
  --set-string "tolerations[0].operator=Equal" \
  --set-string "tolerations[0].value=true" \
  --set-string "tolerations[0].effect=NoSchedule" \
  --wait --timeout=300s

# ─── Phase 10: Gateway + HTTPRoutes ──────────────────────────────────

log "Phase 10: Gateway + HTTPRoutes (via ${ENV:-prod} overlay)"
kubectl apply -k "${REPO_ROOT}/infra/k8s/gateway/overlays/${ENV:-prod}" || true

# ─── Done ─────────────────────────────────────────────────────────────

log "Bootstrap complete!"
echo ""
echo "Verify:"
echo "  kubectl get ns"
echo "  kubectl get pods -A | grep -v kube-system"
echo ""
echo "Next:"
echo "  1. Run: scripts/vault-init.sh --env ${ENV:-prod}"
echo "  2. Run: scripts/tf-apply.sh tls ${ENV:-prod}"
echo "  3. Run: scripts/tf-apply.sh dns ${ENV:-prod}"
echo "  4. Run: scripts/tf-apply.sh keycloak-realm ${ENV:-prod}"
echo "  5. Run: scripts/airflow-keycloak-rbac.sh"
echo "  6. Run: GITHUB_PAT=<token> scripts/post-deploy.sh ${ENV:-prod}"
echo "  7. See docs/QUICKSTART.md for full deployment guide"
