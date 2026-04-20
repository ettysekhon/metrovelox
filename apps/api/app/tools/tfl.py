"""TfL tool implementations — lakehouse-first with TfL API fallback."""

from __future__ import annotations

import logging

import httpx

from app.config import TFL_API_KEY
from app.db import query as trino_query

logger = logging.getLogger("openvelox.tools.tfl")


async def _tfl_get(path: str, params: dict | None = None) -> list | dict:
    base = "https://api.tfl.gov.uk"
    p = dict(params or {})
    if TFL_API_KEY:
        p["app_key"] = TFL_API_KEY
    async with httpx.AsyncClient(timeout=15) as client:
        resp = await client.get(f"{base}{path}", params=p)
        resp.raise_for_status()
        return resp.json()


async def get_line_status(line_id: str | None = None) -> dict:
    """Get line status from the lakehouse analytics layer, falling back to the
    public TfL API when Trino is unreachable."""
    try:
        sql = (
            "SELECT line_id, line_name, status_description, reason FROM ("
            "  SELECT line_id, line_name, status_description, reason, "
            "    ROW_NUMBER() OVER (PARTITION BY line_id ORDER BY last_updated DESC) AS rn "
            "  FROM line_status_latest"
            ") WHERE rn = 1"
        )
        if line_id:
            sql += f" AND line_id = '{line_id}'"

        import asyncio

        rows = await asyncio.to_thread(trino_query, sql, "analytics", "tube")
        return {
            "source": "lakehouse",
            "lines": [
                {
                    "id": r["line_id"],
                    "name": r["line_name"],
                    "status": r["status_description"],
                    "reason": r.get("reason"),
                }
                for r in rows
            ],
        }
    except Exception as exc:
        logger.warning(
            "Trino unavailable for get_line_status (%s: %s), falling back to TfL API",
            type(exc).__name__,
            exc,
        )

    data = await _tfl_get("/Line/Mode/tube,dlr,overground,elizabeth-line/Status")
    if line_id:
        data = [l for l in data if l["id"] == line_id]

    return {
        "source": "tfl_api",
        "lines": [
            {
                "id": line["id"],
                "name": line["name"],
                "status": line["lineStatuses"][0]["statusSeverityDescription"],
            }
            for line in data
        ],
    }


async def get_bike_availability(
    station_id: str | None = None,
    lat: float | None = None,
    lon: float | None = None,
    radius: int = 500,
) -> dict:
    """Get bike availability from the curated lakehouse layer, falling back to
    the public TfL API when Trino is unreachable."""
    try:
        import asyncio

        if station_id:
            sql = (
                f"SELECT station_id, station_name, lat, lon, "
                f"bikes_available, docks_available, total_docks "
                f"FROM bike_occupancy WHERE station_id = '{station_id}'"
            )
        elif lat is not None and lon is not None:
            delta = radius / 111_000.0
            sql = (
                f"SELECT station_id, station_name, lat, lon, "
                f"bikes_available, docks_available, total_docks "
                f"FROM bike_occupancy "
                f"WHERE lat BETWEEN {lat - delta} AND {lat + delta} "
                f"  AND lon BETWEEN {lon - delta} AND {lon + delta}"
            )
        else:
            sql = (
                "SELECT station_id, station_name, lat, lon, "
                "bikes_available, docks_available, total_docks "
                "FROM bike_occupancy LIMIT 50"
            )

        rows = await asyncio.to_thread(trino_query, sql, "curated", "cycling")
        return {
            "source": "lakehouse",
            "stations": [
                {
                    "id": r["station_id"],
                    "name": r["station_name"],
                    "lat": r["lat"],
                    "lon": r["lon"],
                    "bikes": r["bikes_available"],
                    "docks": r["docks_available"],
                    "total": r["total_docks"],
                }
                for r in rows
            ],
        }
    except Exception:
        logger.warning("Trino unavailable for get_bike_availability, falling back to TfL API")

    if station_id:
        data = await _tfl_get(f"/BikePoint/{station_id}")
        data = [data] if isinstance(data, dict) else data
    else:
        params: dict = {}
        if lat is not None and lon is not None:
            params = {"lat": lat, "lon": lon, "radius": radius}
        data = await _tfl_get("/BikePoint", params)
        if not isinstance(data, list):
            data = [data]

    stations = []
    for bp in data:
        props = {p["key"]: p["value"] for p in bp.get("additionalProperties", [])}
        stations.append(
            {
                "id": bp["id"],
                "name": bp.get("commonName", ""),
                "lat": bp["lat"],
                "lon": bp["lon"],
                "bikes": int(props.get("NbBikes", 0)),
                "docks": int(props.get("NbEmptyDocks", 0)),
                "total": int(props.get("NbDocks", 0)),
            }
        )
    return {"source": "tfl_api", "stations": stations}


async def plan_journey(
    from_location: str,
    to_location: str,
    mode: str = "any",
) -> dict:
    """Plan a journey using the TfL Journey Planner API (no lakehouse equivalent)."""
    data = await _tfl_get(
        f"/Journey/JourneyResults/{from_location}/to/{to_location}",
        {"mode": mode},
    )
    return data if isinstance(data, dict) else {"journeys": data}
