# Scaling, cost, and performance

_Last reviewed: 2026-04-19_

GKE node-pool topology, workload placement, cost, scale-to-zero toggle, and
tuning notes.

## Node-pool topology

Three pools, each with a distinct purpose and taint:

| Pool              | Machine        | vCPU | RAM   | Taint                                       | Purpose                                                             |
| ----------------- | -------------- | ---- | ----- | ------------------------------------------- | ------------------------------------------------------------------- |
| **spot-pool**     | e2-standard-4  | 4    | 16 GB | `cloud.google.com/gke-spot=true:NoSchedule` | Streaming, batch, data workloads (preemptible)                      |
| **standard-pool** | e2-medium      | 2    | 4 GB  | `openvelox/stateful=true:NoSchedule`        | PostgreSQL (stateful, stable)                                       |
| **system-pool**   | n2d-standard-4 | 4    | 16 GB | —                                           | Platform services, kube-system, anything without a taint toleration |

The spot pool autoscales `min=0, max=2`. When no spot-tolerating pods are
pending, the node is removed entirely — compute cost for that pool is zero.
See [Streaming toggle](#streaming-toggle).

## Workload placement

Every workload needs **both** a toleration (to be _allowed_ onto a tainted
pool) and a nodeSelector (to be _forced_ there). Tolerations without
selectors schedule on the untainted system pool instead, which defeats the
split topology.

### Spot pool — streaming + batch + data

| Workload                       | CPU req   | Mem req       | File                                                                  |
| ------------------------------ | --------- | ------------- | --------------------------------------------------------------------- |
| Flink JobManager (standalone)  | 250m      | 2560Mi        | `infra/k8s/streaming/base/flink/flink-standalone.yaml`                |
| Flink TaskManager (standalone) | 250m      | 2560Mi        | `infra/k8s/streaming/base/flink/flink-standalone.yaml`                |
| Flink Session (operator)       | 500m+250m | 2560Mi+2560Mi | `infra/k8s/streaming/base/flink/flink-session.yaml`                   |
| Strimzi Kafka broker           | 250m      | 1536Mi        | `infra/k8s/kafka/base/kafka.tmpl.yaml`                                |
| kafka-ui (kafbat)              | 100m      | 256Mi         | `helm/kafka-ui/values-gke.yaml`                                       |
| Apicurio Registry              | 100m      | 384Mi         | `infra/k8s/apicurio/base/deployment.yaml`                             |
| Trino coordinator              | 500m      | 2048Mi        | `helm/trino/values-gke.yaml`                                          |
| Polaris                        | 100m      | 256Mi         | `helm/polaris/values-gke.yaml`                                        |
| OAuth2 proxy (Flink)           | 50m       | 32Mi          | `infra/k8s/streaming/base/oauth2-proxy.yaml`                          |
| Airflow (all components)       | varies    | varies        | `helm/airflow/values-gke.yaml`                                        |
| Spark operator                 | —         | —             | `helm/spark-operator/values-gke.yaml`                                 |
| tfl-producer-strimzi (CronJob) | 100m      | 128Mi         | `infra/k8s/streaming/base/tfl-producer-strimzi-cronjob.yaml`          |

All tolerate `gke-spot` and select `spot-pool`.

### System pool — platform services

| Workload                  | Why here                                        |
| ------------------------- | ----------------------------------------------- |
| Keycloak                  | SSO provider; outage blocks all users           |
| Vault + injector          | Secrets engine; ESO depends on it               |
| Grafana                   | Monitoring + SSO integration                    |
| Prometheus + Operator     | Needs persistence, stability                    |
| kube-state-metrics        | Lightweight, stable                             |
| ArgoCD (all components)   | GitOps controller                               |
| External Secrets Operator | Vault-to-K8s sync                               |
| cert-manager              | TLS certificate lifecycle                       |
| Flink Kubernetes Operator | Lightweight controller for `FlinkDeployment`    |

### Standard pool — stateful

| Workload   | Why here                                           |
| ---------- | -------------------------------------------------- |
| PostgreSQL | Stateful DB, PVC-bound, cannot tolerate preemption |

## Capacity

Allocatable per pool (after kubelet + system reservation):

| Pool              | Allocatable CPU | Allocatable Mem | Requested CPU | Requested Mem | Headroom      |
| ----------------- | --------------- | --------------- | ------------- | ------------- | ------------- |
| **spot-pool**     | 3920m           | ~13.3Gi         | ~2370m        | ~12.2Gi       | 1550m / 1.1Gi |
| **system-pool**   | 3920m           | ~13.3Gi         | ~3100m        | ~11.8Gi       | 820m / 1.5Gi  |
| **standard-pool** | 940m            | ~2.8Gi          | ~500m         | ~768Mi        | 440m / 2.0Gi  |

The system pool sits at ~89 % memory, the spot pool at ~92 % when fully
deployed — tight. Adding workloads without checking headroom risks OOMKills.
Spark running alongside Flink will push the autoscaler to provision a
second spot node (max=2).

### Sizing rationale

- Global vCPU quota of 12. At 4+2+4 = 10, there is headroom for one more
  spot node (10+4 = 14 would exceed it; either rely on the first being
  preempted, or raise quota).
- System pool uses `n2d-standard-4` because `e2-standard-4` was unavailable
  in `europe-west2-a` at deploy time. n2d (AMD EPYC) is ~5–7 % more
  expensive but was the only 4-vCPU option available.

## Unbounded workloads

Keycloak has no resource limits in its base manifest
(`infra/k8s/platform/keycloak/base/deployment.yaml`). It requests 500m /
1Gi but is limited to 2000m / 2Gi. On a system pool at 89 % memory a spike
could OOM co-located pods (ArgoCD, Vault, Grafana). Watch Keycloak's
steady-state in Grafana and consider tightening if it stabilises below
1.5 Gi.

## Cost

GCP `europe-west2` (London), on-demand unless noted. Approximate.

### Compute

| Pool                 | Machine        | Spot?                  | Monthly   |
| -------------------- | -------------- | ---------------------- | --------- |
| spot-pool (1 node)   | e2-standard-4  | Yes (~60–70 % discount)| ~$52      |
| standard-pool        | e2-medium      | No                     | ~$27      |
| system-pool          | n2d-standard-4 | No                     | ~$115     |
| **Compute subtotal** |                |                        | **~$194** |

### Other

| Item                                    | Monthly         |
| --------------------------------------- | --------------- |
| Persistent disks (PD-SSD + PD-Balanced) | ~$29            |
| Load balancer + egress + misc           | ~$30            |
| **Total**                               | **~$253/month** |

### Cost profiles

| Mode                           | Pools active               | Monthly                           |
| ------------------------------ | -------------------------- | --------------------------------- |
| **Idle** (streaming stopped)   | system + standard          | ~$201                             |
| **Active** (streaming running) | system + standard + 1 spot | ~$253                             |
| **Burst** (Spark jobs)         | system + standard + 2 spot | ~$305                             |
| **Fully stopped** (no cluster) | —                          | ~$0 (only Terraform state bucket) |

### Comparison

- **EKS (AWS):** ~$100/month more. EKS control plane is $74/month (GKE is
  free for the first zonal cluster), and EC2 spot in `eu-west-2` is ~10–15 %
  higher than GCE for equivalent instance types.
- **AKS (Azure):** roughly equivalent. AKS control plane is free; Azure spot
  in `uksouth` is competitive with GCE; disk and egress are similar.

## Streaming toggle

`scripts/streaming-toggle.sh` starts/stops the entire streaming + data stack
on the spot pool.

```bash
scripts/streaming-toggle.sh stop    # spot pool scales to zero in ~10 min
scripts/streaming-toggle.sh start   # spot node provisions in ~2 min
scripts/streaming-toggle.sh status
```

### Shutdown order

The stop sequence is ordered to protect in-flight data:

1. **Flink** — triggers checkpoint/savepoint to GCS before pods terminate.
2. **tfl-producer-strimzi** — suspend CronJobs, stop writing to Kafka.
3. **Kafka (Strimzi)** — scale `KafkaNodePool/mixed` to 0 once writers/readers
   are gone.
4. **Trino, Polaris, oauth2 proxies** — stateless, order doesn't matter.
5. **Airflow** — batch orchestrator.
6. **Spark operator** — no active jobs.

Startup is the reverse: infrastructure first (Airflow, Spark, Trino, Polaris),
then Kafka, then producers, then Flink last so it can reconnect and restore
from its GCS checkpoint.

### Single-broker caveat

The Strimzi `openvelox` cluster runs one mixed (controller + broker) replica
with every replication knob pinned to 1 to fit the spot-pool footprint. The
Kafka PVC survives spot-node reclaim, but topic data can be inconsistent
after a hard kill.

Mitigations:

- Flink checkpoints to GCS (`state.checkpoints.dir: gs://...`) are the
  source of truth for stream state — not Kafka offsets.
- The toggle script does a clean ordered shutdown (Flink first).
- Spot preemption mid-flight is the residual risk, accepted for dev/demo.
  For production, scale `mixed` to ≥3 (or split controller/broker pools)
  and flip replication defaults — see [ROADMAP §7](ROADMAP.md).

## Autoscaling

```hcl
autoscaling {
  total_min_node_count = 0
  total_max_node_count = 2
  location_policy      = "ANY"
}
```

- **Scale to zero** — when all spot-tolerating pods are at 0 replicas (via
  `streaming-toggle.sh stop`), the node is removed in ~10 min.
- **Scale up** — a Pending pod selecting `spot-pool` provisions a new spot
  VM in ~2 min.
- **Scale to 2** — when total requests exceed one node's capacity
  (e.g. Spark alongside Flink).
- Standard and system pools are fixed `node_count = 1` — always-on platform
  services.

## Tuning

### Flink

| Setting                             | Value                                    | Rationale                                             |
| ----------------------------------- | ---------------------------------------- | ----------------------------------------------------- |
| `execution.checkpointing.interval`  | 60s                                      | Recovery granularity vs I/O overhead                  |
| `execution.checkpointing.min-pause` | 30s                                      | Prevents checkpoint storms under backpressure         |
| `state.backend`                     | rocksdb (standalone) / hashmap (session) | RocksDB for large state, hashmap for SQL exploration  |
| `taskmanager.numberOfTaskSlots`     | 4                                        | Matches e2-standard-4 cores                           |
| `taskmanager.memory.process.size`   | 2400m-6g                                 | Standalone 6g (prod), session 2560m (dev)             |

Do not run standalone (`deployment.yaml`) and the operator-managed session
cluster (`flink-session.yaml`) simultaneously in prod — they compete for the
same resources. Standalone is a fallback when the Flink Operator is unhealthy.

### Trino

| Setting                       | Value     | Rationale                                                               |
| ----------------------------- | --------- | ----------------------------------------------------------------------- |
| `coordinator.jvm.maxHeapSize` | 1G        | JVM heap — the 512M ReservedCodeCacheSize is hard-coded by the chart    |
| `query.maxMemory`             | 1GB       | Total memory for distributed queries                                    |
| `query.maxMemoryPerNode`      | 512MB     | Per-node limit with single coordinator                                  |
| Memory request / limit        | 2Gi / 4Gi | 1G heap + 512M code cache + metaspace + direct buffers = ~2G floor      |
| `workers`                     | 0         | Coordinator-only — executes queries itself to halve resource usage      |

### Prometheus

| Setting         | Value                                          | Rationale                                            |
| --------------- | ---------------------------------------------- | ---------------------------------------------------- |
| `retention`     | 48h                                            | Short retention for dev                              |
| `retentionSize` | 4GB                                            | Hard cap to prevent PVC overflow on the 5 Gi volume  |
| Storage         | 5Gi PD (standard-rwo)                          | Minimal — increase for production retention          |
| Scrape targets  | Airflow StatsD (+ TODO: kafka-exporter, Flink) | Data plane only; add more as services stabilise      |

### Sizing philosophy

Requests = observed steady-state + ~20 % headroom. Limits are higher to
absorb temporary spikes. Goal is to pack workloads onto the smallest node
that fits while keeping enough headroom to avoid OOMKills during GC pauses
or startup spikes.

JVM workloads (Flink, Trino) need limits well above requests — the JVM
allocates large contiguous regions at startup that don't show in
steady-state RSS.
