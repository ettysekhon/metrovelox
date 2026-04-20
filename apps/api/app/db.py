"""Trino query client for the Iceberg lakehouse.

Authenticates to the Trino coordinator with a Keycloak-minted JWT fetched
via the client-credentials grant. Trino's `jwt` authenticator validates the
token against the realm JWKS and requires ``aud=trino`` — see
helm/trino/values-gke.yaml and the ``openvelox-api`` client in
infra/terraform/keycloak-realm/main.tf.
"""

from trino.auth import JWTAuthentication
from trino.dbapi import connect

from app.auth import get_access_token
from app.config import (
    TRINO_HOST,
    TRINO_HTTP_SCHEME,
    TRINO_PORT,
    TRINO_USER,
)


def get_connection(catalog: str = "raw", schema: str = "tube"):
    token = get_access_token()
    return connect(
        host=TRINO_HOST,
        port=TRINO_PORT,
        user=TRINO_USER,
        catalog=catalog,
        schema=schema,
        http_scheme=TRINO_HTTP_SCHEME,
        auth=JWTAuthentication(token),
    )


def query(sql: str, catalog: str = "raw", schema: str = "tube") -> list[dict]:
    conn = get_connection(catalog, schema)
    try:
        cur = conn.cursor()
        cur.execute(sql)
        columns = [desc[0] for desc in cur.description]
        return [dict(zip(columns, row)) for row in cur.fetchall()]
    finally:
        conn.close()
