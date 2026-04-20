"""Airflow 3.x DAG: Bridge Flink streaming completions → batch enrichment.

Uses AssetWatcher to monitor a Kafka signal topic for Flink curated-layer
completion events. When Flink publishes a JSON message to the signal topic,
Airflow triggers downstream batch enrichment without cron guessing.

Requires: apache-airflow-providers-apache-kafka

NOTE: Uncomment the AssetWatcher wiring once Flink jobs are configured to
publish completion signals to tfl.signals.flink-curated-done.
"""
from __future__ import annotations

from datetime import datetime, timedelta

from airflow.providers.common.sql.operators.sql import SQLExecuteQueryOperator
from airflow.sdk import DAG, Asset

# from airflow.sdk import AssetWatcher
# from airflow.providers.apache.kafka.triggers.await_message import AwaitMessageTrigger

# ── Uncomment when Flink signal topic is provisioned ─────────────────────────
# flink_curated_done = Asset(
#     name="flink.curated.completion",
#     uri="kafka://tfl.signals.flink-curated-done",
#     watchers=[
#         AssetWatcher(
#             name="flink_watcher",
#             trigger=AwaitMessageTrigger(
#                 topics=["tfl.signals.flink-curated-done"],
#                 kafka_config_id="kafka_default",
#             ),
#         ),
#     ],
# )

flink_curated_done = Asset(
    name="flink.curated.completion",
    uri="kafka://tfl.signals.flink-curated-done",
)

default_args = {
    "owner": "data-platform",
    "retries": 1,
    "retry_delay": timedelta(minutes=5),
    "execution_timeout": timedelta(minutes=20),
}

with DAG(
    dag_id="flink_bridge",
    schedule=[flink_curated_done],
    start_date=datetime(2026, 1, 1),
    catchup=False,
    default_args=default_args,
    tags=["bridge", "flink", "trino"],
):

    SQLExecuteQueryOperator(
        task_id="enrich_from_flink",
        conn_id="trino_default",
        sql="""
            INSERT INTO curated.cycling.bike_occupancy
            SELECT
                bike_point_id, common_name, total_docks,
                available_bikes, available_ebikes,
                CAST(available_bikes AS DOUBLE) / NULLIF(total_docks, 0) * 100 AS occupancy_pct,
                (available_bikes = 0) AS is_empty,
                (available_bikes = total_docks) AS is_full,
                CASE
                    WHEN CAST(available_bikes AS DOUBLE) / NULLIF(total_docks, 0) < 0.1 THEN 'critical'
                    WHEN CAST(available_bikes AS DOUBLE) / NULLIF(total_docks, 0) < 0.3 THEN 'low'
                    WHEN CAST(available_bikes AS DOUBLE) / NULLIF(total_docks, 0) > 0.9 THEN 'full'
                    ELSE 'normal'
                END AS availability_status,
                lat, lon, event_time
            FROM raw.cycling.bike_occupancy
            WHERE event_time > (
                SELECT COALESCE(MAX(event_time), TIMESTAMP '1970-01-01 00:00:00')
                FROM curated.cycling.bike_occupancy
            )
              AND total_docks > 0
              AND available_bikes >= 0
              AND available_bikes <= total_docks
        """,
    )
