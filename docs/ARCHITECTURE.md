# Architecture

_Last reviewed: 2026-04-19_

## System overview

```text
                   ┌─────────────────────────────────────────────────┐
                   │                  Kubernetes (GKE)               │
                   │                                                 │
  TfL APIs ──────▶ │  Producer ──▶ Kafka ──▶ Flink ──────┐           │
                   │                                     │           │
  Scheduled ─────▶ │  Airflow ──▶ Spark ─────────────────┤           │
                   │                                     ▼           │
                   │                              ┌──────────┐       │
                   │                              │  Polaris │       │
                   │                              │  (Iceberg│       │
                   │                              │  Catalog)│       │
                   │                              └────┬─────┘       │
                   │                                   │             │
                   │             Trino ◀───────────────┘             │
                   │               │                                 │
                   │         ┌─────┴──────┐                          │
                   │         ▼            ▼                          │
                   │      FastAPI      Next.js                       │
                   │                                                 │
                   │  ── Platform ──────────────────────────────     │
                   │  ArgoCD │ Vault │ Keycloak │ Grafana            │
                   └─────────────────────────────────────────────────┘
```

## Data flow

### Streaming (Flink)

```text
TfL API ──▶ Producer ──▶ Kafka Topics ──▶ Flink SQL ──▶ Polaris/Iceberg
                         tfl.raw.line-status    │
                         tfl.raw.bus-arrivals    ├──▶ raw.tube.line_status
                         tfl.raw.bike-points     ├──▶ raw.bus.arrivals
                                                 ├──▶ raw.cycling.bike_occupancy
                                                 │
                                           Flink SQL (curated)
                                                 ├──▶ curated.bus.arrivals
                                                 ├──▶ curated.cycling.bike_occupancy
                                                 │
                                           Flink SQL (analytics)
                                                 ├──▶ analytics.tube.line_status_latest
                                                 └──▶ analytics.cycling.bike_station_hourly
```

The producer polls TfL every 30 s and publishes raw JSON to Kafka. Three
Flink SQL jobs take it through the medallion layers:

1. `raw/ingest_all.sql` — Kafka → Iceberg raw (schema-on-read).
2. `curated/transform.sql` — quality, enrichment, computed fields.
3. `analytics/aggregations.sql` — business aggregations and materialised views.

Hot-path data is also published to compacted Kafka topics for low-latency
consumers.

### Batch (Airflow + Trino/Spark)

```text
Scheduled ──▶ Airflow DAG ──▶ Python @task (requests) ──▶ Trino INSERT
                                                               │
                                     ┌─────────────────────────┘
                                     │
                               SQLExecuteQueryOperator
                                     │
                                     ├──▶ raw.cycling.bike_occupancy (Iceberg)
                                     ├──▶ curated.cycling.bike_occupancy (Iceberg)
                                     └──▶ analytics.cycling.bike_station_hourly (Iceberg)

Manual ──▶ Airflow DAG ──▶ SparkKubernetesOperator ──▶ Historical backfill
```

Python `@task` handles API ingestion, `SQLExecuteQueryOperator` drives
Trino-based transforms (curated, analytics, quality, SCD2), Spark does
heavy historical backfills. Spark and Flink write the same Iceberg tables
via Polaris — one lakehouse, both paths.

Domain-specific pipeline code lives under `pipelines/` (e.g. `pipelines/tfl/`).
See `pipelines/tfl/README.md`.

## Component map

### Infrastructure

| Component    | Namespace      | Purpose                              |
| ------------ | -------------- | ------------------------------------ |
| GKE          | —              | Kubernetes runtime                   |
| Gateway API  | `platform`     | L7 load balancer + TLS termination   |
| cert-manager | `cert-manager` | Automated TLS certificate lifecycle  |

### Platform

| Component            | Namespace    | Purpose                          |
| -------------------- | ------------ | -------------------------------- |
| ArgoCD               | `argocd`     | GitOps reconciliation            |
| Vault                | `security`   | Secrets, KMS auto-unseal         |
| External Secrets     | `security`   | Vault → K8s Secret sync          |
| Keycloak             | `platform`   | OIDC SSO                         |
| Grafana + Prometheus | `monitoring` | Metrics, dashboards, alerting    |

### Data

| Component       | Namespace   | Purpose                                                      |
| --------------- | ----------- | ------------------------------------------------------------ |
| Strimzi Kafka   | `kafka`     | Apache Kafka (`openvelox`, KRaft mixed node pool)            |
| Apicurio        | `kafka`     | Schema registry (Avro/JSON/Protobuf)                         |
| kafka-ui        | `kafka`     | Browser UI for the Kafka cluster                             |
| Flink           | `streaming` | Real-time SQL stream processing                              |
| Airflow         | `batch`     | Orchestration (Airflow 3 + Assets)                           |
| Spark           | `batch`     | Distributed processing (historical backfill)                 |
| Polaris         | `data`      | Iceberg REST catalog                                         |
| Polaris Console | `data`      | Browser UI (separate Deployment on `catalog-console.<domain>`) |
| Trino           | `data`      | Interactive SQL (Keycloak OAuth2 for UI/CLI/JDBC)            |
| PostgreSQL      | `platform`  | Metadata store (Polaris, Keycloak, Airflow)                  |

The Polaris Console is cross-origin to the Polaris API by design; see
`infra/k8s/data/polaris-console.yaml`.

### Applications

| Component        | Namespace | Purpose                                            |
| ---------------- | --------- | -------------------------------------------------- |
| FastAPI          | `apps`    | REST + WebSocket streaming gateway (Trino + Kafka) |
| Next.js frontend | `apps`    | Real-time dashboard (React + Tailwind + MapLibre)  |

The API exposes a subscription-based WebSocket at `/ws/streams` backed by
a shared Kafka consumer fan-out, plus topic discovery at
`GET /api/v1/streams/catalog`. Source under `apps/api/`.

## Technology versions

| Component      | Version                     | Notes                                   |
| -------------- | --------------------------- | --------------------------------------- |
| GKE            | 1.31+                       | Gateway API enabled                     |
| Airflow        | 3.x                         | Assets, GitDagBundle, SQLExecuteQueryOp |
| Flink          | 2.x                         | Flink SQL, Iceberg connector            |
| Spark          | 4.1+                        | Native Iceberg, SparkKubeOp             |
| Iceberg        | 1.7+                        | V2/V3 table format                      |
| Polaris        | 0.9+                        | Iceberg REST catalog                    |
| Trino          | 460+                        | Iceberg connector, Polaris catalog      |
| Strimzi Kafka  | operator 0.51 / Kafka 4.1.1 | KRaft mixed node pool                   |
| Keycloak       | 26.x                        | OIDC SSO                                |
| Vault          | 1.18+                       | GCP KMS auto-unseal                     |
| ArgoCD         | 2.13+                       | GitOps reconciliation                   |
| FastAPI        | 0.115+                      | Python 3.12, aiokafka, trino client     |
| Next.js        | 15.x                        | React 19, Tailwind, MapLibre            |
| Terraform      | 1.9+                        | GCP provider                            |

## GitOps model

```text
argocd/
├── apps/                    # Environment-agnostic templates
│   ├── gateway.yaml
│   ├── keycloak.yaml
│   └── ...
└── envs/
    ├── prod/                # Production overrides (path + values)
    └── dev/                 # Development overrides
```

Templates define the Application shape; `envs/<env>/` files override
`spec.source.path` to point at the correct Kustomize overlay or Helm values.

## Multi-environment strategy

Each environment is isolated by:

1. **GCP project** — separate billing, IAM, resources.
2. **GKE cluster** — dedicated control plane.
3. **DNS prefix** — e.g. `dev.auth.domain.com`, `auth.domain.com`.
4. **Kustomize overlays** — `infra/k8s/*/overlays/{env}/`.
5. **Helm values** — `helm/*/values-{env}.yaml`.
6. **Terraform state** — `infra/terraform/environments/{env}.tfvars`.
