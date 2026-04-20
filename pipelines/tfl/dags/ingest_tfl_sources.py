"""Airflow 3.x DAG: Ingest TfL API sources → Iceberg raw layer via Trino.

The only cron-scheduled DAG. Downstream curated/analytics/quality DAGs
trigger automatically via Asset events — no time gaps, no polling.

Each task calls the TfL Unified API with plain `requests`, then batch-inserts
rows into Iceberg tables through Trino. No dlt, no GCS landing zone.
"""
from __future__ import annotations

import logging
import os
from datetime import datetime, timedelta, timezone

import requests as http
from airflow.providers.trino.hooks.trino import TrinoHook
from airflow.sdk import DAG, task

from assets import (
    raw_bike_occupancy,
    raw_bus_arrivals,
    raw_line_status,
    ref_bike_stations,
)

log = logging.getLogger(__name__)

TFL_BASE = "https://api.tfl.gov.uk"
TRINO_CONN = "trino_default"
BUS_STOP_IDS = os.environ.get(
    "TFL_BUS_STOP_IDS",
    "490000091D,490000091E,490000091F",
).split(",")

default_args = {
    "owner": "data-platform",
    "retries": 2,
    "retry_delay": timedelta(minutes=5),
    "execution_timeout": timedelta(minutes=30),
}


def _fetch_tfl(endpoint: str, params: dict | None = None) -> list[dict]:
    """Call TfL Unified API and return JSON response."""
    api_key = os.environ.get("TFL_API_KEY", "")
    all_params = {}
    if api_key:
        all_params["app_key"] = api_key
    if params:
        all_params.update(params)
    resp = http.get(f"{TFL_BASE}/{endpoint}", params=all_params, timeout=30)
    resp.raise_for_status()
    return resp.json()


def _insert_via_trino(table: str, columns: list[str], rows: list[tuple]) -> int:
    """Batch INSERT into Iceberg table via Trino. Returns row count."""
    if not rows:
        log.warning("No rows to insert into %s", table)
        return 0
    hook = TrinoHook(trino_conn_id=TRINO_CONN)
    hook.insert_rows(table=table, rows=rows, target_fields=columns)
    log.info("Inserted %d rows into %s", len(rows), table)
    return len(rows)


with DAG(
    dag_id="ingest_tfl_sources",
    schedule="0 5 * * *",
    start_date=datetime(2026, 1, 1),
    catchup=False,
    max_active_runs=1,
    default_args=default_args,
    tags=["ingestion", "tfl", "raw"],
):

    @task(outlets=[raw_bike_occupancy, ref_bike_stations])
    def ingest_bike_occupancy() -> dict:
        """TfL BikePoint API → raw.cycling.bike_occupancy."""
        data = _fetch_tfl("BikePoint")
        now = datetime.now(timezone.utc).isoformat()
        rows = []
        for bp in data:
            props = {p["key"]: p["value"] for p in bp.get("additionalProperties", [])}
            rows.append((
                bp["id"],
                bp["commonName"],
                int(props.get("NbDocks", 0)),
                int(props.get("NbBikes", 0)),
                int(props.get("NbEBikes", 0)),
                float(bp["lat"]),
                float(bp["lon"]),
                now,
            ))
        count = _insert_via_trino(
            "raw.cycling.bike_occupancy",
            [
                "bike_point_id", "common_name", "total_docks",
                "available_bikes", "available_ebikes", "lat", "lon",
                "event_time",
            ],
            rows,
        )
        return {"table": "raw.cycling.bike_occupancy", "rows": count}

    @task(outlets=[raw_line_status])
    def ingest_line_status() -> dict:
        """TfL Line/Mode/tube/Status API → raw.tube.line_status."""
        data = _fetch_tfl("Line/Mode/tube/Status")
        now = datetime.now(timezone.utc).isoformat()
        rows = []
        for line in data:
            status = line.get("lineStatuses", [{}])[0]
            rows.append((
                line["id"],
                line["name"],
                status.get("statusSeverityDescription", "Unknown"),
                status.get("reason", ""),
                now,
            ))
        count = _insert_via_trino(
            "raw.tube.line_status",
            ["line_id", "line_name", "status", "reason", "event_time"],
            rows,
        )
        return {"table": "raw.tube.line_status", "rows": count}

    @task(outlets=[raw_bus_arrivals])
    def ingest_bus_arrivals() -> dict:
        """TfL StopPoint Arrivals API → raw.bus.arrivals."""
        now = datetime.now(timezone.utc).isoformat()
        rows = []
        for stop_id in BUS_STOP_IDS:
            try:
                data = _fetch_tfl(f"StopPoint/{stop_id.strip()}/Arrivals")
            except http.HTTPError:
                log.warning("Failed to fetch arrivals for stop %s", stop_id)
                continue
            for arr in data:
                rows.append((
                    arr.get("id", ""),
                    arr.get("naptanId", stop_id.strip()),
                    arr.get("stationName", ""),
                    arr.get("lineName", ""),
                    arr.get("destinationName", ""),
                    arr.get("timeToStation", 0),
                    arr.get("expectedArrival", now),
                    now,
                ))
        count = _insert_via_trino(
            "raw.bus.arrivals",
            [
                "arrival_id", "stop_id", "station_name", "line_name",
                "destination_name", "time_to_station", "expected_arrival",
                "event_time",
            ],
            rows,
        )
        return {"table": "raw.bus.arrivals", "rows": count}

    ingest_bike_occupancy()
    ingest_line_status()
    ingest_bus_arrivals()
