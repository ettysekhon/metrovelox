"""Stream catalog — single source of truth for exposed Kafka topics.

Used by both the REST ``/api/v1/streams/catalog`` endpoint and the
WebSocket topic allow-list in :class:`streaming.KafkaFanout`.

To add a new domain, append an entry to ``STREAM_CATALOG``.  The frontend
discovers available topics at startup via the REST endpoint and the
subscription gateway rejects any topic not listed here.
"""

from __future__ import annotations

from pydantic import BaseModel


class TopicInfo(BaseModel):
    name: str
    description: str


class DomainStreams(BaseModel):
    label: str
    topics: list[TopicInfo]


STREAM_CATALOG: dict[str, DomainStreams] = {
    "tfl": DomainStreams(
        label="London Transport",
        topics=[
            TopicInfo(
                name="tfl.analytics.line-status-latest",
                description="Live tube line status (compacted)",
            ),
            TopicInfo(
                name="tfl.curated.bike-occupancy",
                description="Enriched bike station availability (compacted)",
            ),
            TopicInfo(
                name="tfl.raw.line-status",
                description="Raw line status events",
            ),
            TopicInfo(
                name="tfl.raw.bus-arrivals",
                description="Raw bus arrival predictions",
            ),
            TopicInfo(
                name="tfl.raw.bike-points",
                description="Raw bike point snapshots",
            ),
        ],
    ),
}


def allowed_topics() -> set[str]:
    """Flat set of every topic name in the catalog (used as allow-list)."""
    return {
        topic.name
        for domain in STREAM_CATALOG.values()
        for topic in domain.topics
    }
