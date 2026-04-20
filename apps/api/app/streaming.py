"""WebSocket subscription gateway backed by a shared Kafka consumer.

KafkaFanout  – singleton that owns one AIOKafkaConsumer and dispatches
               messages to sessions that have subscribed to matching topics.
ConnectionManager – maps session_id → (WebSocket, subscribed_topics) and
                    translates subscribe/unsubscribe JSON commands into
                    topic registrations on the fanout.
"""

from __future__ import annotations

import asyncio
import json
import logging
import uuid
from collections import deque
from dataclasses import dataclass, field

from aiokafka import AIOKafkaConsumer
from fastapi import WebSocket

from app.auth import KeycloakOAuthBearerTokenProvider
from app.config import KAFKA_BROKERS, KAFKA_SASL_MECHANISM, KAFKA_SECURITY_PROTOCOL

logger = logging.getLogger("openvelox.streaming")

# Rolling-buffer depth per topic for snapshot-on-subscribe. Sized for the two
# user-facing topics we have today (`tfl.analytics.line-status-latest` emits
# at most ~12 rows per change, `tfl.curated.bike-occupancy` up to ~800 docks
# on a full scrape). 1000 keeps the most recent full sweep of either stream
# in memory while staying bounded per pod.
_SNAPSHOT_BUFFER_SIZE = 1000


# ---------------------------------------------------------------------------
# KafkaFanout
# ---------------------------------------------------------------------------


class KafkaFanout:
    """Single shared Kafka consumer that fans out messages to WebSocket sessions."""

    def __init__(self, brokers: str, allowed_topics: set[str]) -> None:
        self._brokers = brokers
        self._allowed_topics = allowed_topics
        self._topic_sessions: dict[str, set[str]] = {}  # topic → {session_id}
        self._queues: dict[str, asyncio.Queue] = {}      # session_id → Queue
        # Rolling per-topic buffer replayed to new subscribers. Flink only
        # checkpoints every 60s, and TfL's state-like streams (line status,
        # bike-occupancy) don't change every second, so a just-joined client
        # could otherwise stare at "Messages received 0" for a full minute
        # before anything arrives. Keeping the last window in memory gives
        # every subscriber an immediate snapshot of recent state.
        self._snapshots: dict[str, deque[dict]] = {}
        self._consumer: AIOKafkaConsumer | None = None
        self._task: asyncio.Task | None = None
        self._lock = asyncio.Lock()

    # -- lifecycle -----------------------------------------------------------

    async def start(self) -> None:
        # Strimzi brokers only accept SASL OAUTHBEARER against Keycloak; an
        # anonymous AIOKafkaConsumer would fail the SASL handshake with
        # `UnsupportedSaslMechanism`. The token provider shares the same
        # ``TokenCache`` used by the Trino JWT auth in ``app.db``.
        consumer_kwargs: dict = dict(
            bootstrap_servers=self._brokers,
            group_id="openvelox-ws-fanout",
            auto_offset_reset="latest",
            enable_auto_commit=True,
            value_deserializer=lambda v: json.loads(v) if v else None,
        )
        if KAFKA_SASL_MECHANISM.upper() == "OAUTHBEARER":
            consumer_kwargs.update(
                security_protocol=KAFKA_SECURITY_PROTOCOL,
                sasl_mechanism="OAUTHBEARER",
                sasl_oauth_token_provider=KeycloakOAuthBearerTokenProvider(),
            )
        self._consumer = AIOKafkaConsumer(**consumer_kwargs)
        await self._consumer.start()
        self._task = asyncio.create_task(self._consume_loop(), name="kafka-fanout")
        logger.info(
            "KafkaFanout started (brokers=%s, security=%s, mechanism=%s)",
            self._brokers,
            KAFKA_SECURITY_PROTOCOL if KAFKA_SASL_MECHANISM.upper() == "OAUTHBEARER" else "PLAINTEXT",
            KAFKA_SASL_MECHANISM,
        )

    async def stop(self) -> None:
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
        if self._consumer:
            await self._consumer.stop()
        logger.info("KafkaFanout stopped")

    # -- subscription management --------------------------------------------

    async def add_session(self, session_id: str) -> asyncio.Queue:
        q: asyncio.Queue = asyncio.Queue(maxsize=256)
        self._queues[session_id] = q
        return q

    async def remove_session(self, session_id: str) -> None:
        async with self._lock:
            topics_to_check: list[str] = []
            for topic, sessions in self._topic_sessions.items():
                sessions.discard(session_id)
                if not sessions:
                    topics_to_check.append(topic)
            for t in topics_to_check:
                del self._topic_sessions[t]
            self._queues.pop(session_id, None)
            if topics_to_check:
                await self._refresh_subscription()

    async def subscribe(self, session_id: str, topics: list[str]) -> list[str]:
        """Subscribe a session to topics. Returns the list actually subscribed.

        After registration we replay any cached envelopes for the requested
        topics into the session's queue so a brand-new client sees recent
        state immediately instead of waiting out a Flink checkpoint cycle.
        The replay is best-effort: if the queue can't hold every buffered
        envelope we drop the oldest overflow rather than blocking.
        """
        valid = [t for t in topics if t in self._allowed_topics]
        if not valid:
            return []
        async with self._lock:
            changed = False
            for topic in valid:
                if topic not in self._topic_sessions:
                    self._topic_sessions[topic] = set()
                    changed = True
                self._topic_sessions[topic].add(session_id)
            if changed:
                await self._refresh_subscription()
            queue = self._queues.get(session_id)
            snapshot_topics: list[str] = []
            if queue is not None:
                for topic in valid:
                    buf = self._snapshots.get(topic)
                    if not buf:
                        continue
                    delivered = 0
                    for envelope in list(buf):
                        snap = dict(envelope)
                        snap["snapshot"] = True
                        try:
                            queue.put_nowait(snap)
                        except asyncio.QueueFull:
                            logger.warning(
                                "Snapshot replay for %s on %s dropped at %d/%d envelopes",
                                session_id[:8],
                                topic,
                                delivered,
                                len(buf),
                            )
                            break
                        delivered += 1
                    if delivered:
                        snapshot_topics.append(f"{topic}={delivered}")
            if snapshot_topics:
                logger.info(
                    "Replayed snapshot for session %s: %s",
                    session_id[:8],
                    ", ".join(snapshot_topics),
                )
        return valid

    async def unsubscribe(self, session_id: str, topics: list[str]) -> None:
        async with self._lock:
            changed = False
            for topic in topics:
                sessions = self._topic_sessions.get(topic)
                if sessions is None:
                    continue
                sessions.discard(session_id)
                if not sessions:
                    del self._topic_sessions[topic]
                    changed = True
            if changed:
                await self._refresh_subscription()

    # -- internals ----------------------------------------------------------

    async def _refresh_subscription(self) -> None:
        all_topics = set(self._topic_sessions.keys())
        if self._consumer is None:
            return
        if all_topics:
            self._consumer.subscribe(list(all_topics))
            logger.info("Kafka subscription updated: %s", all_topics)
        else:
            self._consumer.unsubscribe()
            logger.info("Kafka subscription cleared (no active subscribers)")

    async def _consume_loop(self) -> None:
        assert self._consumer is not None
        try:
            async for msg in self._consumer:
                if msg.value is None:
                    continue
                topic = msg.topic
                sessions = self._topic_sessions.get(topic)
                if not sessions:
                    continue
                domain = topic.split(".")[0] if "." in topic else "unknown"
                envelope = {
                    "domain": domain,
                    "topic": topic,
                    "timestamp": msg.timestamp,
                    "data": msg.value,
                }
                buf = self._snapshots.get(topic)
                if buf is None:
                    buf = deque(maxlen=_SNAPSHOT_BUFFER_SIZE)
                    self._snapshots[topic] = buf
                buf.append(envelope)
                dead: list[str] = []
                for sid in sessions:
                    q = self._queues.get(sid)
                    if q is None:
                        dead.append(sid)
                        continue
                    try:
                        q.put_nowait(envelope)
                    except asyncio.QueueFull:
                        logger.warning("Queue full for session %s, dropping message", sid)
                for sid in dead:
                    sessions.discard(sid)
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("KafkaFanout consume loop crashed")


# ---------------------------------------------------------------------------
# ConnectionManager
# ---------------------------------------------------------------------------


@dataclass
class _Session:
    session_id: str
    websocket: WebSocket
    topics: set[str] = field(default_factory=set)
    queue: asyncio.Queue | None = None
    sender_task: asyncio.Task | None = None


class ConnectionManager:
    """Manages WebSocket sessions and wires them to the KafkaFanout."""

    def __init__(self, fanout: KafkaFanout) -> None:
        self._fanout = fanout
        self._sessions: dict[str, _Session] = {}

    async def connect(self, websocket: WebSocket) -> _Session:
        await websocket.accept()
        session_id = str(uuid.uuid4())
        queue = await self._fanout.add_session(session_id)
        session = _Session(session_id=session_id, websocket=websocket, queue=queue)
        session.sender_task = asyncio.create_task(
            self._sender(session), name=f"ws-sender-{session_id[:8]}"
        )
        self._sessions[session_id] = session
        await websocket.send_json({"type": "connected", "session_id": session_id})
        logger.info("Session %s connected", session_id[:8])
        return session

    async def disconnect(self, session: _Session) -> None:
        if session.sender_task:
            session.sender_task.cancel()
            try:
                await session.sender_task
            except asyncio.CancelledError:
                pass
        await self._fanout.remove_session(session.session_id)
        self._sessions.pop(session.session_id, None)
        logger.info("Session %s disconnected", session.session_id[:8])

    async def handle_message(self, session: _Session, raw: str) -> None:
        try:
            msg = json.loads(raw)
        except json.JSONDecodeError:
            await session.websocket.send_json({"type": "error", "message": "invalid JSON"})
            return

        action = msg.get("action")
        topics = msg.get("topics", [])

        if action == "subscribe" and isinstance(topics, list):
            accepted = await self._fanout.subscribe(session.session_id, topics)
            session.topics.update(accepted)
            await session.websocket.send_json({
                "type": "subscribed",
                "topics": list(session.topics),
            })
        elif action == "unsubscribe" and isinstance(topics, list):
            await self._fanout.unsubscribe(session.session_id, topics)
            session.topics -= set(topics)
            await session.websocket.send_json({
                "type": "unsubscribed",
                "topics": list(session.topics),
            })
        else:
            await session.websocket.send_json({
                "type": "error",
                "message": f"unknown action: {action}",
            })

    async def _sender(self, session: _Session) -> None:
        """Background task that drains the session queue → WebSocket.

        If the WebSocket is dead (half-closed TCP, remote hung up without a
        clean close frame, etc.), ``send_json`` raises. Without explicit
        cleanup the session's fanout queue stays registered, fills up, and
        every broadcast turns into a ``Queue full, dropping message`` log,
        starving every other subscriber until the pod is restarted. We
        observed this in prod after a Cloudflare idle-timeout kill. Drop the
        fanout registration so the next broadcast won't try to enqueue into
        a queue nobody is draining.
        """
        assert session.queue is not None
        try:
            while True:
                envelope = await session.queue.get()
                await session.websocket.send_json(envelope)
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.info(
                "Sender for %s stopped; releasing fanout registration",
                session.session_id[:8],
            )
            await self._fanout.remove_session(session.session_id)
            try:
                await session.websocket.close(code=1011)
            except Exception:
                pass
