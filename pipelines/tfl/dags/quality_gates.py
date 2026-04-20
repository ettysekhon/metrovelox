"""Airflow 3.x DAG: Data quality checks via Trino SQL.

Asset-triggered: runs after curated and analytics layers are updated.
Each check is a SQL query that returns a scalar; a Python validator
asserts it meets the threshold.
"""
from __future__ import annotations

from datetime import datetime, timedelta
from pathlib import Path

from airflow.providers.common.sql.operators.sql import SQLExecuteQueryOperator
from airflow.providers.standard.operators.python import PythonOperator
from airflow.sdk import DAG

from assets import analytics_bike_hourly, curated_bike_occupancy

PIPELINE_ROOT = str(Path(__file__).resolve().parent.parent)

default_args = {
    "owner": "data-platform",
    "retries": 1,
    "retry_delay": timedelta(minutes=2),
    "execution_timeout": timedelta(minutes=10),
}


def _check_result(ti, task_ids: str, min_value: int | None = None, max_value: int | None = None):
    """Validate a scalar query result against thresholds."""
    result = ti.xcom_pull(task_ids=task_ids)
    value = result[0][0] if result else None
    if min_value is not None and (value is None or value < min_value):
        raise ValueError(f"Quality check failed: {task_ids} returned {value}, expected >= {min_value}")
    if max_value is not None and (value is not None and value > max_value):
        raise ValueError(f"Quality check failed: {task_ids} returned {value}, expected <= {max_value}")


with DAG(
    dag_id="quality_gates",
    schedule=[curated_bike_occupancy, analytics_bike_hourly],
    start_date=datetime(2026, 1, 1),
    catchup=False,
    default_args=default_args,
    tags=["quality", "trino"],
    template_searchpath=[PIPELINE_ROOT],
):

    freshness_query = SQLExecuteQueryOperator(
        task_id="check_freshness_query",
        conn_id="trino_default",
        sql="sql/quality/check_freshness.sql",
        handler=list,
    )

    freshness_validate = PythonOperator(
        task_id="check_freshness_validate",
        python_callable=_check_result,
        op_kwargs={"task_ids": "check_freshness_query", "min_value": 1},
    )

    null_query = SQLExecuteQueryOperator(
        task_id="check_nulls_query",
        conn_id="trino_default",
        sql="sql/quality/check_nulls.sql",
        handler=list,
    )

    null_validate = PythonOperator(
        task_id="check_nulls_validate",
        python_callable=_check_result,
        op_kwargs={"task_ids": "check_nulls_query", "max_value": 0},
    )

    completeness_query = SQLExecuteQueryOperator(
        task_id="check_completeness_query",
        conn_id="trino_default",
        sql="sql/quality/check_completeness.sql",
        handler=list,
    )

    completeness_validate = PythonOperator(
        task_id="check_completeness_validate",
        python_callable=_check_result,
        op_kwargs={"task_ids": "check_completeness_query", "min_value": 100},
    )

    freshness_query >> freshness_validate
    null_query >> null_validate
    completeness_query >> completeness_validate
