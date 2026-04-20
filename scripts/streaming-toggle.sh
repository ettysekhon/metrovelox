#!/usr/bin/env bash
# streaming-toggle.sh — Scale the streaming/data stack on the spot pool to zero or back up.
#
# When stopped, all spot-pool pods drain and the GKE cluster autoscaler removes
# the spot node within ~10 minutes, reducing compute cost to $0 for that pool.
#
# Shutdown order (data integrity):
#   1. Flink          — triggers checkpoint to GCS before pods terminate
#   2. tfl-producer   — stop producing to Kafka
#   3. Kafka          — safe once no writers/readers remain
#   4. Trino/Polaris  — stateless, order doesn't matter
#   5. Airflow        — batch orchestrator, safe last
#   6. Spark operator — no active jobs when streaming is down
#
# Startup order (reverse — infrastructure first, then consumers):
#   1. Spark operator + Airflow
#   2. Trino, Polaris, OAuth2 proxies
#   3. Kafka          — broker must be ready before producers/consumers
#   4. tfl-producer
#   5. Flink          — last, reconnects to Kafka and restores from checkpoint
#
# Usage:
#   scripts/streaming-toggle.sh start
#   scripts/streaming-toggle.sh stop
#   scripts/streaming-toggle.sh status
set -euo pipefail

ACTION="${1:-}"

# ArgoCD Applications that manage spot-pool workloads.
# Auto-sync must be suspended during stop, otherwise selfHeal reverts replicas.
ARGO_APPS=(
  streaming-workloads
  kafka-cluster
  trino
  polaris
  airflow
  spark-operator
)

log() { echo "[$(date +%H:%M:%S)] $*"; }

suspend_argocd_sync() {
  log "Suspending ArgoCD auto-sync on spot-pool Applications..."
  for app in "${ARGO_APPS[@]}"; do
    if kubectl get application "$app" -n argocd &>/dev/null; then
      kubectl patch application "$app" -n argocd --type merge \
        -p '{"spec":{"syncPolicy":{"automated":null}}}' 2>/dev/null || true
    fi
  done
}

resume_argocd_sync() {
  log "Re-enabling ArgoCD auto-sync on spot-pool Applications..."
  for app in "${ARGO_APPS[@]}"; do
    if kubectl get application "$app" -n argocd &>/dev/null; then
      kubectl patch application "$app" -n argocd --type merge \
        -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' 2>/dev/null || true
    fi
  done
}

wait_for_replicas() {
  local ns="$1" resource="$2" target="$3" timeout="${4:-120}"
  local elapsed=0
  while (( elapsed < timeout )); do
    local current
    current=$(kubectl get "$resource" -n "$ns" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?")
    local ready
    ready=$(kubectl get "$resource" -n "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    [[ "$ready" == "" ]] && ready=0
    if (( target == 0 )); then
      local avail
      avail=$(kubectl get "$resource" -n "$ns" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
      [[ "$avail" == "" ]] && avail=0
      (( avail == 0 )) && return 0
    else
      (( ready >= target )) && return 0
    fi
    sleep 5
    (( elapsed += 5 ))
  done
  log "  WARN: $ns/$resource did not reach $target replicas within ${timeout}s"
}

scale_deploy() {
  local ns="$1" name="$2" replicas="$3"
  if kubectl get deployment "$name" -n "$ns" &>/dev/null; then
    log "  Scale $ns/$name → $replicas"
    kubectl scale deployment "$name" -n "$ns" --replicas="$replicas"
  fi
}

scale_sts() {
  local ns="$1" name="$2" replicas="$3"
  if kubectl get statefulset "$name" -n "$ns" &>/dev/null; then
    log "  Scale $ns/$name → $replicas"
    kubectl scale statefulset "$name" -n "$ns" --replicas="$replicas"
  fi
}

suspend_cronjob() {
  local ns="$1" name="$2" suspend="$3"
  if kubectl get cronjob "$name" -n "$ns" &>/dev/null; then
    log "  $([ "$suspend" = "true" ] && echo "Suspend" || echo "Unsuspend") $ns/$name"
    kubectl patch cronjob "$name" -n "$ns" -p "{\"spec\":{\"suspend\":$suspend}}"
  fi
}

# Scale Strimzi Kafka by setting spec.kafka.replicas on the Kafka CR.
# Strimzi reconciles and rolls the openvelox-mixed StatefulSet accordingly.
scale_strimzi_kafka() {
  local replicas="$1"
  if kubectl get kafkanodepool mixed -n kafka &>/dev/null; then
    log "  Scale KafkaNodePool kafka/mixed → ${replicas}"
    kubectl patch kafkanodepool mixed -n kafka --type merge \
      -p "{\"spec\":{\"replicas\":${replicas}}}" 2>/dev/null || true
  fi
}

do_stop() {
  log "=== Stopping streaming stack (spot pool → scale to zero) ==="

  suspend_argocd_sync

  log "Phase 1/6: Flink (checkpoint + drain)"
  # Operator-managed FlinkDeployment — scale via spec patch.
  if kubectl get flinkdeployment flink-session -n streaming &>/dev/null; then
    log "  Patch flink-session jobManager replicas → 0"
    kubectl patch flinkdeployment flink-session -n streaming --type merge \
      -p '{"spec":{"job":{"parallelism":0},"taskManager":{"replicas":0}}}' 2>/dev/null || true
    scale_deploy streaming flink-session 0
  fi
  sleep 10  # allow checkpoint flush

  log "Phase 2/6: Producers"
  for cj in $(kubectl get cronjobs -n streaming -l app=tfl-producer -o name 2>/dev/null); do
    suspend_cronjob streaming "$(basename "$cj")" true
  done
  for cj in $(kubectl get cronjobs -n streaming -o name 2>/dev/null | grep tfl-producer); do
    suspend_cronjob streaming "$(basename "$cj")" true
  done

  log "Phase 3/6: Kafka (Strimzi KafkaNodePool → 0)"
  scale_strimzi_kafka 0

  log "Phase 4/6: Trino, Polaris, OAuth2 proxies"
  scale_deploy data trino-coordinator 0
  scale_deploy data polaris 0
  scale_deploy streaming oauth2-proxy-flink 0

  log "Phase 5/6: Airflow"
  scale_deploy batch airflow-api-server 0
  scale_deploy batch airflow-scheduler 0
  scale_deploy batch airflow-dag-processor 0
  scale_deploy batch airflow-triggerer 0
  scale_deploy batch airflow-statsd 0

  log "Phase 6/6: Spark operator"
  scale_deploy batch spark-operator-controller 0
  scale_deploy batch spark-operator-webhook 0

  log "=== Streaming stack stopped. Spot pool will scale to zero in ~10 minutes. ==="
}

do_start() {
  log "=== Starting streaming stack (spot pool will auto-provision) ==="

  log "Phase 1/6: Spark operator + Airflow"
  scale_deploy batch spark-operator-controller 1
  scale_deploy batch spark-operator-webhook 1
  scale_deploy batch airflow-statsd 1
  scale_deploy batch airflow-scheduler 1
  scale_deploy batch airflow-dag-processor 1
  scale_deploy batch airflow-triggerer 1
  scale_deploy batch airflow-api-server 1

  log "Phase 2/6: Trino, Polaris, OAuth2 proxies"
  scale_deploy data trino-coordinator 1
  scale_deploy data polaris 1
  scale_deploy streaming oauth2-proxy-flink 1

  log "Phase 3/6: Kafka (Strimzi KafkaNodePool → 1 and wait)"
  scale_strimzi_kafka 1
  log "  Waiting for Strimzi broker..."
  wait_for_replicas kafka statefulset/openvelox-mixed 1 240

  log "Phase 4/6: Producers"
  for cj in $(kubectl get cronjobs -n streaming -o name 2>/dev/null | grep tfl-producer); do
    suspend_cronjob streaming "$(basename "$cj")" false
  done

  log "Phase 5/6: Flink (restore from checkpoint)"
  if kubectl get flinkdeployment flink-session -n streaming &>/dev/null; then
    log "  Patch flink-session taskManager replicas → 1"
    kubectl patch flinkdeployment flink-session -n streaming --type merge \
      -p '{"spec":{"taskManager":{"replicas":1}}}' 2>/dev/null || true
    scale_deploy streaming flink-session 1
  fi

  log "Phase 6/6: Waiting for key services..."
  wait_for_replicas data deployment/trino-coordinator 1 120
  wait_for_replicas streaming deployment/flink-session 1 180

  resume_argocd_sync

  log "=== Streaming stack started. ==="
}

do_status() {
  log "=== Spot pool workload status ==="
  echo ""
  printf "%-12s %-15s %-50s %-8s %-10s\n" "POOL" "NAMESPACE" "WORKLOAD" "READY" "REPLICAS"
  printf "%-12s %-15s %-50s %-8s %-10s\n" "----" "---------" "--------" "-----" "--------"

  for ns in streaming kafka data batch monitoring; do
    for deploy in $(kubectl get deployments -n "$ns" -o name 2>/dev/null); do
      local name; name=$(basename "$deploy")
      local ready; ready=$(kubectl get "$deploy" -n "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
      local replicas; replicas=$(kubectl get "$deploy" -n "$ns" -o jsonpath='{.spec.replicas}' 2>/dev/null)
      local node; node=$(kubectl get pods -n "$ns" -l "app.kubernetes.io/name=$name" -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || echo "—")
      local pool="—"
      [[ "$node" == *spot* ]] && pool="spot"
      [[ "$node" == *system* ]] && pool="system"
      [[ "$node" == *standard* ]] && pool="standard"
      printf "%-12s %-15s %-50s %-8s %-10s\n" "$pool" "$ns" "$name" "${ready:-0}" "${replicas:-0}"
    done
    for sts in $(kubectl get statefulsets -n "$ns" -o name 2>/dev/null); do
      local name; name=$(basename "$sts")
      local ready; ready=$(kubectl get "$sts" -n "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
      local replicas; replicas=$(kubectl get "$sts" -n "$ns" -o jsonpath='{.spec.replicas}' 2>/dev/null)
      printf "%-12s %-15s %-50s %-8s %-10s\n" "—" "$ns" "$name" "${ready:-0}" "${replicas:-0}"
    done
  done

  echo ""
  log "Node pool status:"
  kubectl get nodes -o custom-columns="NAME:.metadata.name,STATUS:.status.conditions[-1:].type,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory" 2>/dev/null
}

case "${ACTION}" in
  start)  do_start ;;
  stop)   do_stop ;;
  status) do_status ;;
  *)
    echo "Usage: $0 {start|stop|status}"
    echo ""
    echo "  start   — Scale streaming stack to 1 (spot node auto-provisions)"
    echo "  stop    — Scale streaming stack to 0 (spot node auto-removes)"
    echo "  status  — Show current replica counts and node distribution"
    exit 1
    ;;
esac
