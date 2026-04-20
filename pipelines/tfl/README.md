# TfL Pipeline — London Transport Reference Implementation

This directory contains the complete domain-specific pipeline for the
**Transport for London (TfL)** data domain. It demonstrates every layer of the
OpenVelox lakehouse: streaming ingestion, batch ingestion, curated transforms,
analytics aggregations, quality gates, and SCD2 reference tables.

## Directory Layout

```text
pipelines/tfl/
├── dags/                       # Airflow DAGs (loaded via GitDagBundle)
│   ├── assets.py               # Shared Asset definitions for this domain
│   ├── ingest_tfl_sources.py   # Cron: TfL API → raw Iceberg tables
│   ├── transform_curated.py    # Asset-triggered: raw → curated
│   ├── transform_analytics.py  # Asset-triggered: curated → analytics
│   ├── quality_gates.py        # Asset-triggered: freshness / null / completeness
│   ├── reference_scd2.py       # Asset-triggered: SCD2 bike station dimension
│   ├── flink_bridge.py         # Bridges Flink streaming → batch enrichment
│   └── spark_backfill.py       # Manual: Spark historical backfill
├── sql/                        # SQL templates (referenced from DAGs)
│   ├── curated/                # raw → curated transforms
│   ├── analytics/              # curated → analytics aggregations
│   ├── reference/              # SCD2 merge logic
│   └── quality/                # Data quality checks
├── streaming/                  # Real-time pipeline
│   ├── producer/               # Python app that publishes TfL events to Kafka (Strimzi)
│   ├── flink-jobs/             # Flink SQL (raw → curated → analytics)
│   └── schemas/avro/           # Avro schemas for Kafka topics
├── spark/                      # Spark batch jobs
│   └── k8s/                    # SparkApplication CRDs
└── scripts/                    # Domain helper scripts
    └── generate_test_data.py   # Generate synthetic data for local testing
```

## Forking for a New Domain

To create a new domain (e.g. **retail / e-commerce** — orders +
clickstream, the canonical Kafka/Flink streaming reference architecture):

```bash
cp -r pipelines/tfl pipelines/retail
```

Then make these changes inside `pipelines/retail/`:

### 1. Assets (`dags/assets.py`)

Replace TfL Asset URIs with your domain's naming convention:

```python
# Before (TfL)
raw_bike_occupancy = Asset(name="raw.cycling.bike_occupancy", ...)

# After (Retail)
raw_orders = Asset(name="raw.orders.orders", ...)
```

### 2. Ingestion DAG (`dags/ingest_*.py`)

Replace the TfL API calls with your data source. The pattern stays the same:
fetch data → transform to rows → `_insert_via_trino()`.

### 3. SQL Transforms (`sql/`)

Replace the SQL files with queries for your domain's tables and schemas.

### 4. Streaming Producer (`streaming/producer/`)

Replace `tfl_producer.py` with a producer for your data source. Update the
Avro schemas in `streaming/schemas/avro/` to match your event payloads.

### 5. Kafka Topics

Topics follow the `{domain}.raw.*` convention:

| Domain | Example Topics                                  |
| ------ | ----------------------------------------------- |
| TfL    | `tfl.raw.bike-occupancy`, `tfl.raw.line-status` |
| Retail | `retail.raw.orders`, `retail.raw.clicks`        |

### 6. Airflow Configuration

Add a new GitDagBundle in `helm/airflow/values-gke.yaml`:

```yaml
- name: openvelox-retail
  classpath: "airflow.providers.git.bundles.git.GitDagBundle"
  kwargs:
    repo_url: "https://github.com/your-org/openvelox.git"
    subdir: "pipelines/retail/dags"
    tracking_ref: "main"
    refresh_interval: 60
    git_conn_id: "github_default"
```

### 7. Delete What You Don't Need

If you're only running the retail domain, delete `pipelines/tfl/`.

**Zero changes required** to `infra/`, `helm/` (beyond the bundle), `argocd/`,
`docker/`, `scripts/`, or `apps/`.
