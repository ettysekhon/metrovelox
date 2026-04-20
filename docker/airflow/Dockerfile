# GKE nodes are linux/amd64. On Apple Silicon, build with:
#   docker build --platform linux/amd64 ...
FROM apache/airflow:3.1.8

# No FAB API JWT monkey-patch — use native KeycloakAuthManager (see helm/airflow/values-*.yaml).
USER airflow

ARG AIRFLOW_VERSION=3.1.8
ARG CONSTRAINTS="https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-3.12.txt"

# Airflow providers — versions come from the official constraints file (e.g. keycloak 0.5.3 for 3.1.8).
# Do not pin a newer keycloak provider here; it will conflict with --constraint.
RUN pip install --no-cache-dir \
    "apache-airflow-providers-fab" \
    "apache-airflow-providers-keycloak" \
    "apache-airflow-providers-git" \
    "apache-airflow-providers-google" \
    "apache-airflow-providers-common-sql" \
    "apache-airflow-providers-trino" \
    "apache-airflow-providers-cncf-kubernetes" \
    "apache-airflow-providers-apache-kafka" \
    --constraint "${CONSTRAINTS}"

# Minimal data deps — Trino handles SQL execution, no dbt/dlt needed
RUN pip install --no-cache-dir \
    "requests" \
    "google-cloud-storage" \
    "pyarrow"
