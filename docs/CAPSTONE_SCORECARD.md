# Metrovelox — Capstone Scorecard

_Last reviewed: 2026-04-19_

Self-assessment against the Data Engineering Zoomcamp 2026 capstone
rubric. Each section states what is implemented, where to find the
evidence, and what remains before the category scores its maximum.

Outstanding platform gaps (orthogonal to the rubric — HA Kafka, image
build CI, `terraform plan` gate, etc.) are tracked in
[ROADMAP.md](ROADMAP.md).

---

## 1. Problem description — 4 / 4

Three concrete operational questions answered off one platform, stated
in the [README](../README.md#problem):

1. Tube — service degradation now and over time.
2. Cycle hire — dock occupancy and borough-level rush-hour churn.
3. Buses — predicted-vs-observed ETA drift per route and stop.

Each question maps to a specific Iceberg table in the `analytics`
warehouse and a specific consumer (dashboard tile or Trino query).

**Evidence:** [README.md §Problem](../README.md#problem),
[docs/CATALOG.md](CATALOG.md).

---

## 2. Cloud — 4 / 4

Managed cloud (GCP) provisioned by Terraform. No click-ops.

- **Terraform stacks:** `foundation`, `keycloak-realm`, `wi-bindings`,
  all under [infra/terraform/](../infra/terraform/), state in a
  dedicated GCS bucket.
- **GKE cluster:** three autoscaling node pools (system, spot, stateful)
  — [docs/SCALING_AND_COST.md](SCALING_AND_COST.md).
- **Multi-environment:** `scripts/new-env.sh` scaffolds a new cluster,
  DNS prefix, Terraform state, Kustomize overlays, and ArgoCD
  Applications — [docs/ENV-SETUP.md](ENV-SETUP.md).

**Evidence:** [infra/terraform/](../infra/terraform/),
[scripts/tf-apply.sh](../scripts/tf-apply.sh),
[scripts/bootstrap.sh](../scripts/bootstrap.sh).

---

## 3. Data ingestion — batch — 4 / 4

End-to-end Airflow 3 DAG with asset-driven dependencies and Airflow-3
native `GitDagBundle` (DAGs pulled directly from Git, no git-sync
sidecar).

- **DAG chain:** `ingest_tfl_sources` → `transform_curated` →
  `transform_analytics`, plus `quality_gates` and `reference_scd2` for
  slowly-changing reference data.
- **Scheduling:** Iceberg Asset dependencies — `transform_curated`
  triggers when `ingest_tfl_sources` publishes the upstream Asset, no
  cron chaining.
- **Bundle config:** two `GitDagBundle` entries in
  [helm/airflow/values-gke.yaml](../helm/airflow/values-gke.yaml) — one
  for platform DAGs, one per domain.

**Evidence:** [pipelines/tfl/dags/](../pipelines/tfl/dags/),
[helm/airflow/values-gke.yaml](../helm/airflow/values-gke.yaml).

---

## 4. Data ingestion — streaming — 4 / 4

Live Kafka + Flink SQL path from TfL API to Iceberg and back out to the
dashboard.

- **Producer:** Strimzi Kafka client in
  [pipelines/tfl/streaming/producer/](../pipelines/tfl/streaming/producer/);
  OAUTHBEARER against Keycloak, runs as a `tfl-producer-strimzi`
  CronJob.
- **Raw → curated → analytics:** Flink SQL jobs in
  [pipelines/tfl/streaming/flink-jobs/](../pipelines/tfl/streaming/flink-jobs/),
  deployed as a `FlinkDeployment` session cluster.
- **Kafka sink for dashboard:** analytics table
  `analytics.tube.line_status_latest` mirrored to
  `tfl.analytics.line-status-latest` via Flink `upsert-kafka`, consumed
  by the FastAPI WebSocket fan-out.

**Evidence:**
[pipelines/tfl/streaming/](../pipelines/tfl/streaming/),
[infra/k8s/streaming/base/flink/](../infra/k8s/streaming/base/flink/).

---

## 5. Data warehouse — 3 / 4

Apache Iceberg on GCS, fronted by the Apache Polaris REST catalog and
queried by Trino + Flink + Spark. Three logical warehouses: `raw`,
`curated`, `analytics` (see [CATALOG.md](CATALOG.md)).

**Implemented:**

- Open table format with time-travel, snapshot expiration, and file
  compaction configured at the catalog level.
- Cross-engine reads — same table readable from Trino, Flink, and Spark
  without re-ingestion.
- Catalog authorisation delegated to OPA (see §8).

**Gap to 4/4 — partitioning and clustering justifications.**

Current tables use defaults. For the dashboard tables this is fine
(small, upsert-heavy), but the analytics fact tables
(`analytics.bus.arrival_accuracy`, `analytics.tube.line_status_history`)
are candidates for explicit partitioning on `event_date` and sort-order
on `line_id` / `route_id`. Tracked as a catalogue-level migration: adds
`partition-spec` and `sort-order` metadata plus a one-off Spark
rewrite.

**Evidence:** [pipelines/tfl/sql/](../pipelines/tfl/sql/),
[pipelines/tfl/streaming/flink-jobs/](../pipelines/tfl/streaming/flink-jobs/),
[docs/CATALOG.md](CATALOG.md).

---

## 6. Transformations — 4 / 4

Three transformation engines, one table contract.

- **Flink SQL (streaming):**
  [pipelines/tfl/streaming/flink-jobs/raw](../pipelines/tfl/streaming/flink-jobs/raw/),
  [curated](../pipelines/tfl/streaming/flink-jobs/curated/),
  [analytics](../pipelines/tfl/streaming/flink-jobs/analytics/).
  `aggregations.sql` does the line-status-latest upsert and bike-hourly
  window aggregations.
- **Trino SQL (batch / ad-hoc):** [pipelines/tfl/sql/](../pipelines/tfl/sql/).
- **Spark (heavy batch):**
  [pipelines/tfl/spark/k8s/bike-batch-pipeline.yaml](../pipelines/tfl/spark/k8s/bike-batch-pipeline.yaml)
  for the historical back-fill, submitted by the `spark_backfill` DAG.

**Evidence:** the three directories above.

---

## 7. Dashboard — 4 / 4

Live Next.js dashboard at [metrovelox.com](https://metrovelox.com),
WebSocket-backed.

**Two tiles, one temporal + one categorical:**

- **Categorical — tube & rail line status:** current severity per line
  (Good Service / Minor Delays / Part Suspended / …), rendered in
  official TfL colours with summary counts. Source topic
  `tfl.analytics.line-status-latest`, in turn written by Flink SQL
  from `analytics.tube.line_status_latest`.
- **Temporal — cycle hire dock occupancy:** live bike / dock counts per
  station with full-dock and empty-dock leaderboards plus a
  network-wide total. Source topic `tfl.curated.bike-occupancy`,
  maintained by the curated Flink job over a 5-minute tumbling window.

**Snapshot-on-subscribe:** the WebSocket fan-out replays the last N
messages per topic to every new session before going live, so the
dashboard paints immediately instead of waiting for the next update
tick.

**Evidence:** [apps/frontend/](../apps/frontend/),
[apps/api/app/streaming.py](../apps/api/app/streaming.py),
[README.md §Dashboard](../README.md#dashboard).

---

## 8. Reproducibility — 4 / 4

Clean-clone to running-platform in a documented command sequence.

- **Bootstrap:** [scripts/bootstrap.sh](../scripts/bootstrap.sh) is
  idempotent; re-runs recover from partial failures.
- **GitOps:** ArgoCD owns every runtime object — drift is visible, not
  hidden. Every change is a Git commit.
- **Walkthrough:** [docs/QUICKSTART.md](QUICKSTART.md) lists each
  phase, its timing, and the smoke test at the end of it.
- **Multi-env:** see §2.

**Evidence:** [docs/QUICKSTART.md](QUICKSTART.md),
[scripts/bootstrap.sh](../scripts/bootstrap.sh).

---

## Extras

### Makefile

`make bootstrap`, `make opa-test`, `make opa-lint`, `make status`.

**Evidence:** [Makefile](../Makefile).

### CI / CD

GitHub Actions at [.github/workflows/ci.yaml](../.github/workflows/ci.yaml):

- **render-check** — every `*.tmpl.yaml` must render cleanly to its
  committed `*.yaml` sibling; catches forgotten
  `scripts/render-manifests.sh` runs before they hit ArgoCD.
- **opa-test** — Polaris OPA policy unit tests + strict Rego lint;
  blocks merge on any regression.

**Gap to max:** container-image build job (currently manual —
[ROADMAP §1](ROADMAP.md)) and `terraform plan` drift gate
([ROADMAP §10](ROADMAP.md)) are planned additions to this same
workflow.

### Tests

OPA Rego unit tests in
[infra/k8s/data/opa/policies/polaris_test.rego](../infra/k8s/data/opa/policies/polaris_test.rego)
— cover every allow branch and the warehouse-scope helper, run in CI
via `make opa-test`. Pytest suite for the FastAPI gateway is a planned
addition; see [ROADMAP](ROADMAP.md).

### Authorisation — OPA as external PDP

Polaris 1.3+ delegates every authorizable operation to Open Policy
Agent via
`polaris.authorization.opa.policy-uri=http://opa.data.svc.cluster.local:8181/v1/data/polaris/authz`.
The Rego is default-deny with explicit allow branches per
principal-role (`service_admin`, `trino_service`, `polaris_viewer`) and
a warehouse-scope helper that walks the target-parent chain, rejecting
anything outside `{raw, curated, analytics}`. Privilege-management ops
(grant / principal / policy creation) are deliberately not in any
allow-list and fall through to deny, keeping those on Polaris-native
RBAC.

**Evidence:**
[infra/k8s/data/opa/policies/polaris.rego](../infra/k8s/data/opa/policies/polaris.rego),
[docs/GOVERNANCE_IDENTITY_AND_ACCESS.md §5.6](GOVERNANCE_IDENTITY_AND_ACCESS.md#56-opa--external-pdp-enforcing).

### Observability

`kube-prometheus-stack` (Prometheus + Alertmanager + Grafana) deployed
via ArgoCD. The FastAPI gateway exposes `/metrics` with a
`ServiceMonitor`. `PrometheusRule`
`OpenVeloxApiFallingBackToTflApi` fires when the API serves more than
a threshold ratio of requests from the TfL live API instead of the
Iceberg lakehouse — proves the streaming path is actually ahead of the
upstream.

**Evidence:**
[infra/k8s/apps/base/api-monitoring.yaml](../infra/k8s/apps/base/api-monitoring.yaml),
[argocd/apps/prometheus-stack.yaml](../argocd/apps/prometheus-stack.yaml).

---

## Summary

| Category                    | Score  | Notes                                                     |
| --------------------------- | ------ | --------------------------------------------------------- |
| Problem description         | 4 / 4  |                                                           |
| Cloud                       | 4 / 4  | Terraform + GKE + multi-env                               |
| Data ingestion — batch      | 4 / 4  | Airflow 3 + `GitDagBundle` + assets                       |
| Data ingestion — streaming  | 4 / 4  | Kafka + Flink SQL, OAUTHBEARER                            |
| Data warehouse              | 3 / 4  | Partitioning / sort-order rewrite pending                 |
| Transformations             | 4 / 4  | Flink SQL + Trino SQL + Spark                             |
| Dashboard                   | 4 / 4  | Two tiles (categorical + temporal), live WebSocket        |
| Reproducibility             | 4 / 4  | `bootstrap.sh` + ArgoCD + QUICKSTART                      |
| **Core total**              | **31 / 32** |                                                      |
| Extras — Makefile           | ✓      |                                                           |
| Extras — CI/CD              | ✓      | render-check + opa-test (image build + tf-plan pending)   |
| Extras — Tests              | partial | OPA Rego unit tests in CI; API pytest pending            |
| Extras — Authorisation      | ✓      | OPA external PDP, default-deny, unit-tested               |
| Extras — Observability      | ✓      | Prometheus + Grafana + silent-fallback alert              |

Gaps to close, in priority order: (a) table-level partitioning +
sort-order migration (warehouse 4 / 4), (b) container-image build CI
([ROADMAP §1](ROADMAP.md)), (c) API pytest suite.
