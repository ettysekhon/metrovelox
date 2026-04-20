"""OpenVelox API — FastAPI application.

Lakehouse gateway that queries Trino (Iceberg) for transport data with
real-time WebSocket streaming via Kafka (Strimzi).
"""

from __future__ import annotations

import asyncio
import logging
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Annotated

import httpx
from fastapi import FastAPI, Query, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from app.config import KAFKA_BROKERS, TFL_API_KEY
from app.db import query as trino_query
from app.mcp.server import create_mcp_server
from app.metrics import (
    SOURCE_LAKEHOUSE,
    SOURCE_TFL_API,
    metrics_response,
    record_source,
)
from app.streaming import ConnectionManager, KafkaFanout
from app.streams_config import STREAM_CATALOG, allowed_topics

# Uvicorn only installs handlers on `uvicorn.*` loggers, so every `openvelox`
# logger falls back to the un-configured root logger at WARNING. That silently
# swallowed the fanout/session telemetry we depend on when debugging stuck WS
# sessions in prod. Push everything through uvicorn's stderr handler at INFO
# so `kubectl logs` becomes useful again.
_uvicorn_handler = logging.getLogger("uvicorn").handlers
_root = logging.getLogger()
if _uvicorn_handler and not _root.handlers:
    for h in _uvicorn_handler:
        _root.addHandler(h)
_root.setLevel(logging.INFO)

logger = logging.getLogger("openvelox")
logger.setLevel(logging.INFO)

# ---------------------------------------------------------------------------
# Pydantic response models
# ---------------------------------------------------------------------------


class HealthResponse(BaseModel):
    status: str
    timestamp: str
    trino_available: bool


class LineStatusItem(BaseModel):
    id: str
    name: str
    status: str
    reason: str | None = None


class LineStatusResponse(BaseModel):
    source: str = Field(description="'lakehouse' or 'tfl_api'")
    lines: list[LineStatusItem]


class LineHistoryPoint(BaseModel):
    timestamp: str
    status: str
    reason: str | None = None


class LineHistoryResponse(BaseModel):
    line_id: str
    source: str
    history: list[LineHistoryPoint]


class BikeStation(BaseModel):
    station_id: str
    name: str
    lat: float
    lon: float
    bikes_available: int
    docks_available: int
    total_docks: int


class BikeNearbyResponse(BaseModel):
    source: str
    stations: list[BikeStation]


class BikeHourlyPoint(BaseModel):
    hour: str
    avg_bikes: float
    avg_docks: float


class BikeHourlyResponse(BaseModel):
    station_id: str
    source: str
    hourly: list[BikeHourlyPoint]


class BusArrival(BaseModel):
    line_name: str
    destination: str
    expected_arrival: str
    time_to_station_sec: int | None = None
    vehicle_id: str | None = None


class BusArrivalsResponse(BaseModel):
    stop_id: str
    source: str
    arrivals: list[BusArrival]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _trino_available() -> bool:
    """Quick connectivity check against Trino."""
    try:
        trino_query("SELECT 1", catalog="system", schema="runtime")
        return True
    except Exception:
        return False


async def _tfl_get(path: str, params: dict | None = None) -> list | dict:
    """Call the public TfL API."""
    base = "https://api.tfl.gov.uk"
    p = dict(params or {})
    if TFL_API_KEY:
        p["app_key"] = TFL_API_KEY
    async with httpx.AsyncClient(timeout=15) as client:
        resp = await client.get(f"{base}{path}", params=p)
        resp.raise_for_status()
        return resp.json()


# ---------------------------------------------------------------------------
# Streaming plumbing (shared across the process)
# ---------------------------------------------------------------------------

_fanout = KafkaFanout(brokers=KAFKA_BROKERS, allowed_topics=allowed_topics())
_connections = ConnectionManager(fanout=_fanout)


# ---------------------------------------------------------------------------
# Lifespan
# ---------------------------------------------------------------------------


@asynccontextmanager
async def lifespan(application: FastAPI):
    logger.info("OpenVelox API starting")
    await _fanout.start()
    yield
    await _fanout.stop()
    logger.info("OpenVelox API shutting down")


# ---------------------------------------------------------------------------
# Application
# ---------------------------------------------------------------------------

app = FastAPI(
    title="OpenVelox API",
    description="Lakehouse-backed API for transport data (Trino/Iceberg + Kafka live path)",
    version="0.2.0",
    lifespan=lifespan,
    openapi_tags=[
        {"name": "health", "description": "Health and readiness checks"},
        {"name": "tube", "description": "Tube / rail line status"},
        {"name": "bikes", "description": "Santander Cycles bike availability"},
        {"name": "bus", "description": "Bus arrivals"},
        {"name": "streams", "description": "Real-time streaming (WebSocket + catalog)"},
    ],
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Mount MCP server
mcp_server = create_mcp_server()

# ---------------------------------------------------------------------------
# GET /health
# ---------------------------------------------------------------------------


@app.get("/health", response_model=HealthResponse, tags=["health"])
async def health():
    trino_ok = await asyncio.to_thread(_trino_available)
    return HealthResponse(
        status="healthy",
        timestamp=datetime.now(timezone.utc).isoformat(),
        trino_available=trino_ok,
    )


# Prometheus scrape target — exposed unauthenticated on the same port
# because the Service and the NetworkPolicy boundary already constrain
# access to the `monitoring` namespace (see infra/k8s/apps/base/api-
# monitoring.yaml for the matching ServiceMonitor).
@app.get("/metrics", include_in_schema=False)
async def metrics():
    return metrics_response()


# ---------------------------------------------------------------------------
# Tube endpoints
# ---------------------------------------------------------------------------


@app.get("/api/v1/lines/status", response_model=LineStatusResponse, tags=["tube"])
async def line_status():
    """Current status for all TfL rail lines. Queries the lakehouse analytics
    layer first; falls back to the public TfL API when Trino is unreachable."""
    try:
        rows = await asyncio.to_thread(
            trino_query,
            "SELECT line_id, line_name, status_description, reason FROM ("
            "  SELECT line_id, line_name, status_description, reason, "
            "    ROW_NUMBER() OVER (PARTITION BY line_id ORDER BY last_updated DESC) AS rn "
            "  FROM line_status_latest"
            ") WHERE rn = 1",
            "analytics",
            "tube",
        )
        record_source("line_status", SOURCE_LAKEHOUSE)
        return LineStatusResponse(
            source="lakehouse",
            lines=[
                LineStatusItem(
                    id=r["line_id"],
                    name=r["line_name"],
                    status=r["status_description"],
                    reason=r.get("reason"),
                )
                for r in rows
            ],
        )
    except Exception as exc:
        logger.warning(
            "Trino unavailable for line_status (%s: %s), falling back to TfL API",
            type(exc).__name__,
            exc,
        )

    data = await _tfl_get("/Line/Mode/tube,dlr,overground,elizabeth-line/Status")
    record_source("line_status", SOURCE_TFL_API)
    return LineStatusResponse(
        source="tfl_api",
        lines=[
            LineStatusItem(
                id=line["id"],
                name=line["name"],
                status=line["lineStatuses"][0]["statusSeverityDescription"],
                reason=line["lineStatuses"][0].get("reason"),
            )
            for line in data
        ],
    )


@app.get(
    "/api/v1/lines/{line_id}/history",
    response_model=LineHistoryResponse,
    tags=["tube"],
)
async def line_history(line_id: str):
    """Status history for a single line over the last 24 hours."""
    try:
        rows = await asyncio.to_thread(
            trino_query,
            f"SELECT ingested_at, status_severity_description, disruption_reason "
            f"FROM line_status "
            f"WHERE line_id = '{line_id}' "
            f"  AND ingested_at >= current_timestamp - interval '24' hour "
            f"ORDER BY ingested_at DESC",
            "raw",
            "tube",
        )
        record_source("line_history", SOURCE_LAKEHOUSE)
        return LineHistoryResponse(
            line_id=line_id,
            source="lakehouse",
            history=[
                LineHistoryPoint(
                    timestamp=str(r["ingested_at"]),
                    status=r["status_severity_description"],
                    reason=r.get("disruption_reason"),
                )
                for r in rows
            ],
        )
    except Exception:
        logger.warning("Trino unavailable for line_history, falling back to TfL API")

    data = await _tfl_get(f"/Line/{line_id}/Status")
    record_source("line_history", SOURCE_TFL_API)
    if not data:
        return LineHistoryResponse(line_id=line_id, source="tfl_api", history=[])
    line = data[0]
    return LineHistoryResponse(
        line_id=line_id,
        source="tfl_api",
        history=[
            LineHistoryPoint(
                timestamp=datetime.now(timezone.utc).isoformat(),
                status=ls["statusSeverityDescription"],
                reason=ls.get("reason"),
            )
            for ls in line.get("lineStatuses", [])
        ],
    )


# ---------------------------------------------------------------------------
# Bikes endpoints
# ---------------------------------------------------------------------------


@app.get("/api/v1/bikes/nearby", response_model=BikeNearbyResponse, tags=["bikes"])
async def bikes_nearby(
    lat: Annotated[float, Query(description="Latitude")],
    lon: Annotated[float, Query(description="Longitude")],
    radius_km: Annotated[float, Query(description="Search radius in km")] = 0.5,
):
    """Find bike stations near a coordinate. Uses a bounding-box filter against
    the curated Iceberg table, with TfL API fallback."""
    delta = radius_km / 111.0
    try:
        rows = await asyncio.to_thread(
            trino_query,
            f"SELECT station_id, station_name, lat, lon, "
            f"       bikes_available, docks_available, total_docks "
            f"FROM bike_occupancy "
            f"WHERE lat BETWEEN {lat - delta} AND {lat + delta} "
            f"  AND lon BETWEEN {lon - delta} AND {lon + delta}",
            "curated",
            "cycling",
        )
        record_source("bikes_nearby", SOURCE_LAKEHOUSE)
        return BikeNearbyResponse(
            source="lakehouse",
            stations=[
                BikeStation(
                    station_id=r["station_id"],
                    name=r["station_name"],
                    lat=r["lat"],
                    lon=r["lon"],
                    bikes_available=r["bikes_available"],
                    docks_available=r["docks_available"],
                    total_docks=r["total_docks"],
                )
                for r in rows
            ],
        )
    except Exception:
        logger.warning("Trino unavailable for bikes_nearby, falling back to TfL API")

    data = await _tfl_get("/BikePoint", {"lat": lat, "lon": lon, "radius": int(radius_km * 1000)})
    stations: list[BikeStation] = []
    for bp in data if isinstance(data, list) else [data]:
        props = {p["key"]: p["value"] for p in bp.get("additionalProperties", [])}
        stations.append(
            BikeStation(
                station_id=bp["id"],
                name=bp.get("commonName", ""),
                lat=bp["lat"],
                lon=bp["lon"],
                bikes_available=int(props.get("NbBikes", 0)),
                docks_available=int(props.get("NbEmptyDocks", 0)),
                total_docks=int(props.get("NbDocks", 0)),
            )
        )
    record_source("bikes_nearby", SOURCE_TFL_API)
    return BikeNearbyResponse(source="tfl_api", stations=stations)


@app.get(
    "/api/v1/bikes/stations/{station_id}/hourly",
    response_model=BikeHourlyResponse,
    tags=["bikes"],
)
async def bike_station_hourly(station_id: str):
    """Hourly bike/dock averages from the analytics layer."""
    try:
        rows = await asyncio.to_thread(
            trino_query,
            f"SELECT hour_bucket, avg_bikes, avg_docks "
            f"FROM bike_station_hourly "
            f"WHERE station_id = '{station_id}' "
            f"ORDER BY hour_bucket DESC "
            f"LIMIT 48",
            "analytics",
            "cycling",
        )
        record_source("bike_station_hourly", SOURCE_LAKEHOUSE)
        return BikeHourlyResponse(
            station_id=station_id,
            source="lakehouse",
            hourly=[
                BikeHourlyPoint(
                    hour=str(r["hour_bucket"]),
                    avg_bikes=float(r["avg_bikes"]),
                    avg_docks=float(r["avg_docks"]),
                )
                for r in rows
            ],
        )
    except Exception:
        logger.warning("Trino unavailable for bike_station_hourly, falling back to TfL API")

    bp = await _tfl_get(f"/BikePoint/{station_id}")
    props = {p["key"]: p["value"] for p in bp.get("additionalProperties", [])}
    point = BikeHourlyPoint(
        hour=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:00:00"),
        avg_bikes=float(props.get("NbBikes", 0)),
        avg_docks=float(props.get("NbEmptyDocks", 0)),
    )
    record_source("bike_station_hourly", SOURCE_TFL_API)
    return BikeHourlyResponse(
        station_id=station_id,
        source="tfl_api",
        hourly=[point],
    )


# ---------------------------------------------------------------------------
# Bus endpoints
# ---------------------------------------------------------------------------


@app.get(
    "/api/v1/bus/arrivals",
    response_model=BusArrivalsResponse,
    tags=["bus"],
)
async def bus_arrivals(
    stop_id: Annotated[str, Query(description="NaPTAN stop ID")],
):
    """Latest predicted bus arrivals for a stop."""
    try:
        rows = await asyncio.to_thread(
            trino_query,
            f"SELECT line_name, destination_name, expected_arrival, "
            f"       time_to_station_sec, vehicle_id "
            f"FROM arrivals "
            f"WHERE stop_id = '{stop_id}' "
            f"ORDER BY expected_arrival "
            f"LIMIT 20",
            "curated",
            "bus",
        )
        record_source("bus_arrivals", SOURCE_LAKEHOUSE)
        return BusArrivalsResponse(
            stop_id=stop_id,
            source="lakehouse",
            arrivals=[
                BusArrival(
                    line_name=r["line_name"],
                    destination=r["destination_name"],
                    expected_arrival=str(r["expected_arrival"]),
                    time_to_station_sec=r.get("time_to_station_sec"),
                    vehicle_id=r.get("vehicle_id"),
                )
                for r in rows
            ],
        )
    except Exception:
        logger.warning("Trino unavailable for bus_arrivals, falling back to TfL API")

    data = await _tfl_get(f"/StopPoint/{stop_id}/Arrivals")
    arrivals_list = sorted(data, key=lambda a: a.get("expectedArrival", "")) if isinstance(data, list) else []
    record_source("bus_arrivals", SOURCE_TFL_API)
    return BusArrivalsResponse(
        stop_id=stop_id,
        source="tfl_api",
        arrivals=[
            BusArrival(
                line_name=a.get("lineName", ""),
                destination=a.get("destinationName", ""),
                expected_arrival=a.get("expectedArrival", ""),
                time_to_station_sec=a.get("timeToStation"),
                vehicle_id=a.get("vehicleId"),
            )
            for a in arrivals_list[:20]
        ],
    )


# ---------------------------------------------------------------------------
# Streams catalog + WebSocket subscription endpoint
# ---------------------------------------------------------------------------


@app.get("/api/v1/streams/catalog", tags=["streams"])
async def streams_catalog():
    """Available Kafka topics grouped by domain.

    The frontend reads this on startup to discover what can be subscribed to
    via the ``/ws/streams`` WebSocket.
    """
    return {
        domain_key: {
            "label": ds.label,
            "topics": [{"name": t.name, "description": t.description} for t in ds.topics],
        }
        for domain_key, ds in STREAM_CATALOG.items()
    }


@app.websocket("/ws/streams")
async def ws_streams(websocket: WebSocket):
    """Subscription-based live stream.

    After connecting the client receives a ``connected`` message with its
    ``session_id``.  It then sends JSON commands::

        {"action": "subscribe", "topics": ["tfl.analytics.line-status-latest"]}
        {"action": "unsubscribe", "topics": ["tfl.analytics.line-status-latest"]}

    The server pushes domain-tagged envelopes for subscribed topics::

        {"domain": "tfl", "topic": "...", "timestamp": ..., "data": {...}}
    """
    session = await _connections.connect(websocket)
    try:
        while True:
            raw = await websocket.receive_text()
            await _connections.handle_message(session, raw)
    except WebSocketDisconnect:
        logger.info("WebSocket session %s disconnected", session.session_id[:8])
    except Exception:
        logger.exception("WebSocket error for session %s", session.session_id[:8])
        try:
            await websocket.close(code=1011)
        except Exception:
            pass
    finally:
        await _connections.disconnect(session)
