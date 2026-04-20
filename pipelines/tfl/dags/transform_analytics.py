"""Airflow 3.x DAG: Curated → Analytics aggregations via Trino SQL.

Asset-triggered: runs when curated bike occupancy is updated.
"""
from __future__ import annotations

from datetime import datetime, timedelta
from pathlib import Path

from airflow.providers.common.sql.operators.sql import SQLExecuteQueryOperator
from airflow.sdk import DAG

from assets import (
    analytics_bike_hourly,
    curated_bike_occupancy,
)

PIPELINE_ROOT = str(Path(__file__).resolve().parent.parent)

default_args = {
    "owner": "data-platform",
    "retries": 2,
    "retry_delay": timedelta(minutes=3),
    "execution_timeout": timedelta(minutes=30),
}

with DAG(
    dag_id="transform_analytics",
    schedule=[curated_bike_occupancy],
    start_date=datetime(2026, 1, 1),
    catchup=False,
    default_args=default_args,
    tags=["analytics", "trino", "transform"],
    template_searchpath=[PIPELINE_ROOT],
):

    # NOTE: `analytics.tube.line_status_latest` is intentionally NOT scheduled
    # here. The Flink streaming job (pipelines/tfl/streaming/flink-jobs/
    # analytics/aggregations.sql) writes that table directly with upsert
    # semantics, so there is nothing for Airflow to transform. The earlier
    # line_status_latest task pointed at `curated.tube.line_status` which
    # does not exist (Flink sinks the raw->analytics hop in one step) and
    # had never produced a successful run. Removing the task also removes
    # the misleading `curated_line_status` asset dependency from this DAG
    # so it no longer waits on an asset that Airflow never receives.
    SQLExecuteQueryOperator(
        task_id="bike_station_hourly",
        conn_id="trino_default",
        sql="sql/analytics/bike_station_hourly.sql",
        outlets=[analytics_bike_hourly],
    )
