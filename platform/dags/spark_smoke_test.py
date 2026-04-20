"""Airflow DAG: trigger Spark smoke test via SparkApplication CRD.

Proves: Airflow -> Spark Operator -> Polaris -> Iceberg on GCS -> Trino.
Uses the Kubernetes Python client (always available with KubernetesExecutor)
to create and monitor a SparkApplication CRD.
"""

from __future__ import annotations

import time
from datetime import timedelta

from airflow.decorators import dag, task

SPARK_APP_NAME = "smoke-test"
SPARK_NAMESPACE = "batch"


@dag(
    dag_id="spark_smoke_test",
    schedule=None,
    catchup=False,
    tags=["smoke-test", "spark", "iceberg"],
    default_args={"retries": 0, "execution_timeout": timedelta(minutes=12)},
)
def spark_smoke_test():

    @task()
    def submit_and_wait():
        from kubernetes import client, config

        config.load_incluster_config()
        api = client.CustomObjectsApi()
        core = client.CoreV1Api()

        try:
            api.delete_namespaced_custom_object(
                group="sparkoperator.k8s.io",
                version="v1beta2",
                namespace=SPARK_NAMESPACE,
                plural="sparkapplications",
                name=SPARK_APP_NAME,
            )
            print(f"Deleted previous SparkApplication '{SPARK_APP_NAME}'")
            time.sleep(5)
        except client.exceptions.ApiException as e:
            if e.status != 404:
                raise
            print("No previous SparkApplication to clean up")

        spark_app = {
            "apiVersion": "sparkoperator.k8s.io/v1beta2",
            "kind": "SparkApplication",
            "metadata": {"name": SPARK_APP_NAME, "namespace": SPARK_NAMESPACE},
            "spec": {
                "type": "Python",
                "pythonVersion": "3",
                "mode": "cluster",
                "image": "apache/spark:4.1.0-scala2.13-java21-python3-r-ubuntu",
                "imagePullPolicy": "IfNotPresent",
                "mainApplicationFile": "local:///opt/spark/scripts/smoke_test.py",
                "sparkVersion": "4.1.0",
                "sparkConf": {
                    "spark.driver.cores": "1",
                    "spark.driver.memory": "512m",
                    "spark.kubernetes.driver.request.cores": "250m",
                    "spark.kubernetes.executor.request.cores": "250m",
                    "spark.sql.extensions": "org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions",
                    "spark.sql.catalog.lakehouse": "org.apache.iceberg.spark.SparkCatalog",
                    "spark.sql.catalog.lakehouse.type": "rest",
                    "spark.sql.catalog.lakehouse.uri": "http://polaris.data.svc.cluster.local:8181/api/catalog",
                    "spark.sql.catalog.lakehouse.warehouse": "raw",
                    "spark.sql.catalog.lakehouse.credential": "root:polaris-root-secret",
                    "spark.sql.catalog.lakehouse.scope": "PRINCIPAL_ROLE:ALL",
                    "spark.sql.catalog.lakehouse.token-refresh-enabled": "true",
                    "spark.sql.defaultCatalog": "lakehouse",
                    "spark.jars.packages": "org.apache.iceberg:iceberg-spark-runtime-4.0_2.13:1.10.0,com.google.cloud.bigdataoss:gcs-connector:hadoop3-2.2.25",
                    "spark.sql.catalog.lakehouse.io-impl": "org.apache.iceberg.hadoop.HadoopFileIO",
                    "spark.jars.ivy": "/tmp/.ivy2",
                    "spark.hadoop.fs.gs.impl": "com.google.cloud.hadoop.fs.gcs.GoogleHadoopFileSystem",
                    "spark.hadoop.google.cloud.auth.type": "APPLICATION_DEFAULT",
                },
                "driver": {
                    "cores": 1,
                    "memory": "512m",
                    "serviceAccount": "spark",
                    "labels": {"app": "smoke-test"},
                    "tolerations": [{
                        "key": "cloud.google.com/gke-spot",
                        "operator": "Equal",
                        "value": "true",
                        "effect": "NoSchedule",
                    }],
                    "configMaps": [{"name": "smoke-test-script", "path": "/opt/spark/scripts"}],
                },
                "executor": {
                    "cores": 1,
                    "instances": 1,
                    "memory": "512m",
                    "serviceAccount": "spark",
                    "labels": {"app": "smoke-test"},
                    "tolerations": [{
                        "key": "cloud.google.com/gke-spot",
                        "operator": "Equal",
                        "value": "true",
                        "effect": "NoSchedule",
                    }],
                },
                "restartPolicy": {"type": "Never"},
            },
        }

        api.create_namespaced_custom_object(
            group="sparkoperator.k8s.io",
            version="v1beta2",
            namespace=SPARK_NAMESPACE,
            plural="sparkapplications",
            body=spark_app,
        )
        print(f"Created SparkApplication '{SPARK_APP_NAME}'")

        for attempt in range(60):
            time.sleep(10)
            obj = api.get_namespaced_custom_object(
                group="sparkoperator.k8s.io",
                version="v1beta2",
                namespace=SPARK_NAMESPACE,
                plural="sparkapplications",
                name=SPARK_APP_NAME,
            )
            state = obj.get("status", {}).get("applicationState", {}).get("state", "UNKNOWN")
            print(f"Attempt {attempt + 1}: state={state}")

            if state == "COMPLETED":
                try:
                    logs = core.read_namespaced_pod_log(
                        name=f"{SPARK_APP_NAME}-driver",
                        namespace=SPARK_NAMESPACE,
                        tail_lines=10,
                    )
                    print(f"Driver logs (tail):\n{logs}")
                except Exception:
                    pass
                return {"status": "COMPLETED"}

            if state == "FAILED":
                try:
                    logs = core.read_namespaced_pod_log(
                        name=f"{SPARK_APP_NAME}-driver",
                        namespace=SPARK_NAMESPACE,
                        tail_lines=30,
                    )
                    print(f"Driver logs (tail):\n{logs}")
                except Exception:
                    pass
                raise RuntimeError(f"SparkApplication failed: {obj.get('status', {})}")

        raise TimeoutError("SparkApplication did not complete within 10 minutes")

    submit_and_wait()


spark_smoke_test()
