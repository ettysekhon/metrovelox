"""Airflow 3.x DAG: Manual Spark backfill for heavy historical loads.

schedule=None — triggered manually from the Airflow UI when you need to
reprocess months of data that would be too slow for Trino.

Uses SparkKubernetesOperator to submit SparkApplication CRDs to the
batch namespace via the Spark Operator.
"""
from __future__ import annotations

from datetime import datetime, timedelta

from airflow.providers.cncf.kubernetes.operators.spark_kubernetes import SparkKubernetesOperator
from airflow.sdk import DAG

from assets import raw_bike_occupancy

default_args = {
    "owner": "data-platform",
    "retries": 1,
    "retry_delay": timedelta(minutes=10),
    "execution_timeout": timedelta(hours=4),
}

with DAG(
    dag_id="spark_backfill",
    schedule=None,
    start_date=datetime(2026, 1, 1),
    catchup=False,
    default_args=default_args,
    tags=["spark", "backfill", "manual"],
):

    SparkKubernetesOperator(
        task_id="historical_backfill",
        application_file="pipelines/tfl/spark/k8s/bike-batch-pipeline.yaml",
        namespace="batch",
        outlets=[raw_bike_occupancy],
    )
