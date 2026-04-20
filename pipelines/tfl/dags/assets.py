"""Shared Asset definitions for all OpenVelox batch pipelines.

Every DAG imports from here — single source of truth for asset names and URIs.
Streaming (Flink) writes to the same Iceberg tables via Polaris; these Assets
represent the batch-side view used by Airflow's data-aware scheduling.
"""
from __future__ import annotations

from airflow.sdk import Asset

# ── Raw layer (immutable event log) ─────────────────────────────────────────
raw_bike_occupancy = Asset(
    name="raw.cycling.bike_occupancy",
    uri="iceberg://raw/cycling/bike_occupancy",
)
raw_line_status = Asset(
    name="raw.tube.line_status",
    uri="iceberg://raw/tube/line_status",
)
raw_bus_arrivals = Asset(
    name="raw.bus.arrivals",
    uri="iceberg://raw/bus/arrivals",
)

# ── Curated layer (cleaned, enriched, validated) ────────────────────────────
curated_bike_occupancy = Asset(
    name="curated.cycling.bike_occupancy",
    uri="iceberg://curated/cycling/bike_occupancy",
)
curated_bus_arrivals = Asset(
    name="curated.bus.arrivals",
    uri="iceberg://curated/bus/arrivals",
)
curated_line_status = Asset(
    name="curated.tube.line_status",
    uri="iceberg://curated/tube/line_status",
)

# ── Analytics layer (business aggregations) ──────────────────────────────────
analytics_bike_hourly = Asset(
    name="analytics.cycling.bike_station_hourly",
    uri="iceberg://analytics/cycling/bike_station_hourly",
)
# NB: `analytics.tube.line_status_latest` is not defined as an Airflow Asset
# because the Flink streaming job owns the sink — Airflow never produces or
# consumes snapshots of it and never receives an emission event. Adding it
# here would dead-lock any DAG scheduled on the asset.

# ── Reference layer (slowly-changing dimensions) ────────────────────────────
ref_bike_stations = Asset(
    name="reference.cycling.bike_stations",
    uri="iceberg://reference/cycling/bike_stations",
)
