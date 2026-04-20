"""TfL API → Strimzi Kafka producer (SASL OAUTHBEARER).

Parallel sibling to `tfl_producer.py`. The business logic (TfL fetches +
message shape) is reused verbatim; the only thing that changes is the
Kafka client: we use confluent-kafka (librdkafka) here because it
supports OAUTHBEARER out of the box via `oauth_cb`, whereas kafka-python
only covers SASL PLAIN / SCRAM.

The Keycloak `kafka-tfl-producer` client is a confidential service
account — we fetch its access_token with client-credentials on startup
and on every librdkafka oauth refresh (every ~token-expiry / 2).

Publishes to Strimzi topics:
  tfl.raw.bike-points
  tfl.raw.bus-arrivals
  tfl.raw.line-status
"""
from __future__ import annotations

import json
import logging
import os
import sys
import time
from datetime import datetime, timezone

import httpx
from confluent_kafka import Producer

import tfl_producer as base  # reuse fetchers + message shape

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

BOOTSTRAP_SERVERS = os.environ["KAFKA_BOOTSTRAP_SERVERS"]
CLIENT_ID = os.environ["KAFKA_CLIENT_ID"]
CLIENT_SECRET = os.environ["KAFKA_CLIENT_SECRET"]
TOKEN_ENDPOINT = os.environ["KAFKA_TOKEN_ENDPOINT"]


def _fetch_token(_config: str) -> tuple[str, float]:
    """librdkafka oauth_cb — returns (access_token, expiry_epoch_seconds)."""
    resp = httpx.post(
        TOKEN_ENDPOINT,
        data={"grant_type": "client_credentials"},
        auth=(CLIENT_ID, CLIENT_SECRET),
        timeout=10.0,
    )
    resp.raise_for_status()
    body = resp.json()
    access_token = body["access_token"]
    expires_in = int(body.get("expires_in", 300))
    expiry = time.time() + expires_in
    log.info("Fetched access_token (expires in %ds)", expires_in)
    return access_token, expiry


def _on_delivery(err, msg):
    if err is not None:
        log.error("Delivery failed for %s: %s", msg.topic(), err)


def _make_producer() -> Producer:
    return Producer({
        "bootstrap.servers": BOOTSTRAP_SERVERS,
        "security.protocol": "SASL_PLAINTEXT",
        "sasl.mechanisms": "OAUTHBEARER",
        "oauth_cb": _fetch_token,
        # Reasonable defaults — mirror what kafka-python used to default to
        # so behaviour is consistent with the historical producer.
        "acks": "all",
        "retries": 3,
        "compression.type": "snappy",
        "client.id": f"tfl-producer-strimzi-{os.environ.get('HOSTNAME', 'local')}",
    })


def main() -> int:
    producer = _make_producer()
    producer.poll(0)

    with httpx.Client(timeout=60.0) as client:
        total = 0

        log.info("Fetching bike points...")
        for record in base.fetch_bike_points(client):
            producer.produce(
                "tfl.raw.bike-points",
                value=base.make_message("bike-points", record),
                on_delivery=_on_delivery,
            )
            total += 1
        log.info("Published %d bike point records", total)

        count = 0
        log.info("Fetching bus arrivals...")
        for record in base.fetch_bus_arrivals(client):
            producer.produce(
                "tfl.raw.bus-arrivals",
                value=base.make_message("bus-arrivals", record),
                on_delivery=_on_delivery,
            )
            count += 1
        total += count
        log.info("Published %d bus arrival records", count)

        count = 0
        log.info("Fetching line status...")
        for record in base.fetch_line_status(client):
            producer.produce(
                "tfl.raw.line-status",
                value=base.make_message("line-status", record),
                on_delivery=_on_delivery,
            )
            count += 1
        total += count
        log.info("Published %d line status records", count)

    remaining = producer.flush(30)
    if remaining:
        log.error("%d messages still in queue after 30s flush — giving up", remaining)
        return 1
    log.info("Done. Total %d messages published.", total)
    return 0


if __name__ == "__main__":
    sys.exit(main())
