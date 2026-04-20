"""Airflow 3.x DAG: SCD Type 2 dimension maintenance for bike stations.

Asset-triggered: runs when raw bike occupancy is updated. Stages the latest
distinct station attributes, then runs the SCD2 MERGE logic to expire
changed rows and insert new versions.
"""
from __future__ import annotations

from datetime import datetime, timedelta
from pathlib import Path

from airflow.providers.common.sql.operators.sql import SQLExecuteQueryOperator
from airflow.sdk import DAG

from assets import raw_bike_occupancy, ref_bike_stations

PIPELINE_ROOT = str(Path(__file__).resolve().parent.parent)

default_args = {
    "owner": "data-platform",
    "retries": 2,
    "retry_delay": timedelta(minutes=3),
    "execution_timeout": timedelta(minutes=15),
}

with DAG(
    dag_id="reference_scd2",
    schedule=[raw_bike_occupancy],
    start_date=datetime(2026, 1, 1),
    catchup=False,
    default_args=default_args,
    tags=["reference", "scd2", "trino"],
    template_searchpath=[PIPELINE_ROOT],
):

    stage = SQLExecuteQueryOperator(
        task_id="stage_bike_stations",
        conn_id="trino_default",
        sql="""
            CREATE OR REPLACE TABLE staging.cycling.bike_stations_incoming AS
            SELECT DISTINCT bike_point_id, common_name, total_docks, lat, lon
            FROM raw.cycling.bike_occupancy
            WHERE event_time >= CAST('{{ data_interval_start }}' AS TIMESTAMP)
        """,
    )

    scd2 = SQLExecuteQueryOperator(
        task_id="scd2_merge",
        conn_id="trino_default",
        sql="sql/reference/bike_stations_scd2.sql",
        outlets=[ref_bike_stations],
    )

    stage >> scd2
