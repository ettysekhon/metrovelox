"""Prometheus instrumentation for the OpenVelox API.

Single purpose counter: for every domain response we can serve from
Iceberg/Trino (the lakehouse) OR as a fall-back from the upstream
public TfL API, bump `openvelox_api_data_source_total{endpoint,source}`.

Dashboards and alerts (infra/k8s/apps/base/api-monitoring.yaml) use the
ratio of the two labels to answer one question: "is the streaming
pipeline end-to-end healthy, or are we silently papering over a
Trino/Polaris/Iceberg outage by hitting TfL synchronously?"

Keep the metric cardinality deliberately low — two labels, each with a
small closed vocabulary. If we ever want per-line or per-stop breakdowns
they belong in logs, not labels.
"""

from __future__ import annotations

from prometheus_client import CONTENT_TYPE_LATEST, Counter, generate_latest
from starlette.responses import Response

# Source vocabulary — must stay in lock-step with the `source` field on
# the response models in app.main. Anything else is an instrumentation
# bug and should make the alert fire (the `source=~"lakehouse|tfl_api"`
# PromQL guards in api-monitoring.yaml depend on this closed set).
SOURCE_LAKEHOUSE = "lakehouse"
SOURCE_TFL_API = "tfl_api"

# Endpoint vocabulary — free-form but emitted from a single call site
# per route, so effectively closed too.
data_source_total = Counter(
    "openvelox_api_data_source_total",
    "Responses served per data source, by logical endpoint.",
    labelnames=("endpoint", "source"),
)


def record_source(endpoint: str, source: str) -> None:
    """Increment the per-endpoint, per-source counter.

    Call once per successfully-served response, right before returning
    the Pydantic model. Intentionally tolerant of unknown sources — the
    alert queries use a regex match and will naturally ignore anything
    we forgot to add here.
    """
    data_source_total.labels(endpoint=endpoint, source=source).inc()


def metrics_response() -> Response:
    """Render the Prometheus text exposition format for `/metrics`."""
    return Response(
        content=generate_latest(),
        media_type=CONTENT_TYPE_LATEST,
    )
