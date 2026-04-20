"""OAuth2 client-credentials token management.

The FastAPI backend authenticates to two upstream systems that both require
a Keycloak-issued JWT:

  - Trino coordinator (helm/trino/values-gke.yaml configures the `jwt`
    authenticator with `required-audience=trino`).
  - Kafka brokers (Strimzi `KAFKA_BROKER` listener is SASL OAUTHBEARER against
    the same realm, validated via `aud=kafka-broker`).

A single `openvelox-api` Keycloak client (access_type=CONFIDENTIAL, service
accounts enabled) mints tokens for both audiences — see the audience
protocol mappers in infra/terraform/keycloak-realm/main.tf.

This module provides:

  - ``TokenCache`` — a thread-safe, async-safe cache that fetches a token via
    the client-credentials grant and refreshes ~60 s before expiry. Reusing
    one token across many Trino queries avoids hitting Keycloak on every
    HTTP round-trip.
  - ``get_access_token()`` — sync wrapper for the Trino JWTAuthentication
    constructor, which needs a plain string.
  - ``KeycloakOAuthBearerTokenProvider`` — aiokafka's
    ``AbstractTokenProvider`` implementation used by ``KafkaFanout``.
"""

from __future__ import annotations

import asyncio
import logging
import threading
import time

import httpx
from aiokafka.abc import AbstractTokenProvider

from app.config import (
    KEYCLOAK_TOKEN_URL,
    OAUTH_CLIENT_ID,
    OAUTH_CLIENT_SECRET,
)

logger = logging.getLogger("openvelox.auth")

# Refresh this many seconds before the token actually expires so a slow
# Trino query or Kafka rebalance never runs into expiry mid-flight.
_REFRESH_SKEW_SECONDS = 60


class TokenCache:
    """Single-token cache with lazy refresh.

    The cache is shared across both sync (Trino) and async (Kafka) callers.
    Sync callers use ``get_sync()`` which blocks on ``httpx`` via a thread
    lock; async callers use ``get_async()`` which uses an ``asyncio.Lock``.
    Both read/write the same ``_token`` / ``_expires_at`` fields.
    """

    def __init__(self) -> None:
        self._token: str | None = None
        self._expires_at: float = 0.0
        self._sync_lock = threading.Lock()
        self._async_lock = asyncio.Lock()

    def _is_fresh(self) -> bool:
        return self._token is not None and time.time() < (self._expires_at - _REFRESH_SKEW_SECONDS)

    def _store(self, payload: dict) -> str:
        token = payload["access_token"]
        expires_in = int(payload.get("expires_in", 300))
        self._token = token
        self._expires_at = time.time() + expires_in
        logger.debug("Fetched new Keycloak access token (expires in %ds)", expires_in)
        return token

    def get_sync(self) -> str:
        if self._is_fresh():
            assert self._token is not None
            return self._token
        with self._sync_lock:
            if self._is_fresh():
                assert self._token is not None
                return self._token
            if not OAUTH_CLIENT_SECRET:
                raise RuntimeError("OAUTH_CLIENT_SECRET is not set; cannot fetch Keycloak token")
            resp = httpx.post(
                KEYCLOAK_TOKEN_URL,
                data={
                    "grant_type": "client_credentials",
                    "client_id": OAUTH_CLIENT_ID,
                    "client_secret": OAUTH_CLIENT_SECRET,
                },
                timeout=10.0,
            )
            resp.raise_for_status()
            return self._store(resp.json())

    async def get_async(self) -> str:
        if self._is_fresh():
            assert self._token is not None
            return self._token
        async with self._async_lock:
            if self._is_fresh():
                assert self._token is not None
                return self._token
            if not OAUTH_CLIENT_SECRET:
                raise RuntimeError("OAUTH_CLIENT_SECRET is not set; cannot fetch Keycloak token")
            async with httpx.AsyncClient(timeout=10.0) as client:
                resp = await client.post(
                    KEYCLOAK_TOKEN_URL,
                    data={
                        "grant_type": "client_credentials",
                        "client_id": OAUTH_CLIENT_ID,
                        "client_secret": OAUTH_CLIENT_SECRET,
                    },
                )
                resp.raise_for_status()
                return self._store(resp.json())


_token_cache = TokenCache()


def get_access_token() -> str:
    """Return a cached/refreshed Keycloak access token. Sync-callable."""
    return _token_cache.get_sync()


class KeycloakOAuthBearerTokenProvider(AbstractTokenProvider):
    """aiokafka token provider bridging to the shared ``TokenCache``.

    ``aiokafka`` invokes ``token()`` before each reconnect or SASL refresh;
    because the cache has ~60s skew, most calls hit the cached token and
    return immediately.
    """

    async def token(self) -> str:  # type: ignore[override]
        return await _token_cache.get_async()
