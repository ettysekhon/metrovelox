"""Airflow 3.x DAG: Raw → Curated transforms via Trino SQL.

Asset-triggered: runs automatically when all three raw assets are updated
by the ingest_tfl_sources DAG. No cron schedule.
"""
from __future__ import annotations

from datetime import datetime, timedelta
from pathlib import Path

from airflow.providers.common.sql.operators.sql import SQLExecuteQueryOperator
from airflow.sdk import DAG

from assets import (
    curated_bike_occupancy,
    curated_bus_arrivals,
    curated_line_status,
    raw_bike_occupancy,
    raw_bus_arrivals,
    raw_line_status,
)

PIPELINE_ROOT = str(Path(__file__).resolve().parent.parent)

default_args = {
    "owner": "data-platform",
    "retries": 2,
    "retry_delay": timedelta(minutes=3),
    "execution_timeout": timedelta(minutes=30),
}

with DAG(
    dag_id="transform_curated",
    schedule=[raw_bike_occupancy, raw_bus_arrivals, raw_line_status],
    start_date=datetime(2026, 1, 1),
    catchup=False,
    default_args=default_args,
    tags=["curated", "trino", "transform"],
    template_searchpath=[PIPELINE_ROOT],
):

    SQLExecuteQueryOperator(
        task_id="curate_bike_occupancy",
        conn_id="trino_default",
        sql="sql/curated/bike_occupancy.sql",
        outlets=[curated_bike_occupancy],
    )

    SQLExecuteQueryOperator(
        task_id="curate_line_status",
        conn_id="trino_default",
        sql="sql/curated/line_status.sql",
        outlets=[curated_line_status],
    )

    SQLExecuteQueryOperator(
        task_id="curate_bus_arrivals",
        conn_id="trino_default",
        sql="sql/curated/bus_arrivals.sql",
        outlets=[curated_bus_arrivals],
    )
