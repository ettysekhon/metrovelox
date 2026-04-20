# Data catalog

_Last reviewed: 2026-04-19_

## Naming

Three-tier semantic catalog, medallion-aligned:

```text
{catalog}.{schema}.{table_name}
```

| Component   | Convention                   | Example                              |
| ----------- | ---------------------------- | ------------------------------------ |
| **Catalog** | Semantic tier                | `raw`, `curated`, `analytics`        |
| **Schema**  | Business domain              | `tube`, `bus`, `cycling`             |
| **Table**   | `{entity}_{grain}_{variant}` | `line_status`, `bike_station_hourly` |

## Catalogs (Polaris warehouses)

| Catalog     | Purpose                                   | Retention  | Writers             |
| ----------- | ----------------------------------------- | ---------- | ------------------- |
| `raw`       | Immutable event log, schema-on-read       | Indefinite | Flink, Spark        |
| `curated`   | Cleaned, enriched, quality-validated      | Indefinite | Flink, Spark        |
| `analytics` | Business aggregations, materialised views | Indefinite | Flink, Spark        |
| `reference` | Slowly-changing dimensions (SCD2)         | —          | Airflow (Trino SQL) |
| `sandbox`   | Ad-hoc exploration (future)               | 7 days     | Any                 |

## Schemas (business domains)

| Schema    | Domain                                | Source          |
| --------- | ------------------------------------- | --------------- |
| `tube`    | London Underground line status        | TfL Unified API |
| `bus`     | Bus arrival predictions               | TfL Unified API |
| `cycling` | Santander Cycles bike point occupancy | TfL Unified API |

## Tables

### Raw

| Table                        | Description                 | Writer        | Grain             |
| ---------------------------- | --------------------------- | ------------- | ----------------- |
| `raw.tube.line_status`       | Raw line status events      | Flink         | Per-poll snapshot |
| `raw.bus.arrivals`           | Raw bus arrival predictions | Flink         | Per-arrival event |
| `raw.cycling.bike_occupancy` | Raw bike point snapshots    | Flink / Spark | Per-poll snapshot |

### Curated

| Table                            | Description                              | Writer | Transformations                                 |
| -------------------------------- | ---------------------------------------- | ------ | ----------------------------------------------- |
| `curated.bus.arrivals`           | Cleaned arrivals with quality filters    | Flink  | Null filter, range clamp, boolean enrichment    |
| `curated.cycling.bike_occupancy` | Enriched occupancy with computed metrics | Flink  | Geo filter, occupancy %, is_empty/is_full flags |

### Analytics

| Table                                   | Description                           | Writer | Aggregation            |
| --------------------------------------- | ------------------------------------- | ------ | ---------------------- |
| `analytics.tube.line_status_latest`     | Latest status per line (materialised) | Flink  | Dedup by line_id       |
| `analytics.cycling.bike_station_hourly` | Hourly station statistics             | Flink  | 1-hour tumbling window |

## Kafka topics

`{domain}.{tier}.{entity}` — prefix per domain so multiple domains coexist
without collision.

| Segment  | Examples                                  |
| -------- | ----------------------------------------- |
| `domain` | `tfl`, `retail`, `rail`                   |
| `tier`   | `raw`, `curated`, `analytics`, `signals`  |
| `entity` | `line-status`, `bike-occupancy`, `orders` |

### TfL topics

| Topic                              | Format | Key             | Compaction  |
| ---------------------------------- | ------ | --------------- | ----------- |
| `tfl.raw.line-status`              | JSON   | —               | Delete (7d) |
| `tfl.raw.bus-arrivals`             | JSON   | —               | Delete (7d) |
| `tfl.raw.bike-points`              | JSON   | —               | Delete (7d) |
| `tfl.curated.bike-occupancy`       | JSON   | `bike_point_id` | Compact     |
| `tfl.analytics.line-status-latest` | JSON   | `line_id`       | Compact     |
| `tfl.signals.flink-curated-done`   | JSON   | —               | Delete (1d) |

### Onboarding a new domain — retail / e-commerce example

Orders + clickstream is the canonical Kafka/Flink reference workload.

| Topic                             | Format | Key        | Compaction  |
| --------------------------------- | ------ | ---------- | ----------- |
| `retail.raw.orders`               | JSON   | —          | Delete (7d) |
| `retail.raw.clicks`               | JSON   | —          | Delete (7d) |
| `retail.raw.inventory`            | JSON   | —          | Delete (7d) |
| `retail.curated.orders`           | JSON   | `order_id` | Compact     |
| `retail.curated.inventory`        | JSON   | `sku`      | Compact     |
| `retail.analytics.revenue-hourly` | JSON   | `store_id` | Compact     |

## Querying

```sql
-- Raw events
SELECT * FROM raw.tube.line_status LIMIT 10;

-- Curated with computed fields
SELECT bike_point_id, common_name, occupancy_pct, is_empty
FROM curated.cycling.bike_occupancy
WHERE event_time > CURRENT_TIMESTAMP - INTERVAL '1' HOUR;

-- Analytics
SELECT common_name, avg_occupancy_pct, sample_count
FROM analytics.cycling.bike_station_hourly
WHERE window_start > CURRENT_DATE;
```

## Stack

| Component          | Role                                                                            |
| ------------------ | ------------------------------------------------------------------------------- |
| **Apache Polaris** | Iceberg REST catalog — metadata, schema evolution, access control               |
| **Apache Iceberg** | Open table format — ACID, time travel, partition evolution                      |
| **Apache Flink**   | Streaming SQL writer — raw + curated + analytics                                |
| **Apache Spark**   | Batch writer — historical backfills                                             |
| **Apache Trino**   | Interactive SQL across all catalogs                                             |

## Adding a new domain

Pipeline code lives under `pipelines/`. To add `retail`:

1. `cp -r pipelines/tfl pipelines/retail`
2. Create Polaris schemas: `raw.orders`, `curated.orders`, `analytics.revenue`, …
3. Create Kafka topics: `retail.raw.orders`, `retail.raw.clicks`, …
4. Replace pipeline code: DAGs, SQL, Flink jobs, producer, Avro schemas.
5. Update `pipelines/retail/dags/assets.py` with the domain tables.
6. Add a `GitDagBundle` in `helm/airflow/values-gke.yaml` pointing at
   `pipelines/retail/dags`.
7. Update this document.

See `pipelines/tfl/README.md` for the step-by-step fork.
