"""Application configuration from environment variables."""

import os

TRINO_HOST = os.getenv("TRINO_HOST", "trino.data.svc.cluster.local")
TRINO_PORT = int(os.getenv("TRINO_PORT", "8080"))
TRINO_USER = os.getenv("TRINO_USER", "openvelox")
TRINO_HTTP_SCHEME = os.getenv("TRINO_HTTP_SCHEME", "http")

KAFKA_BROKERS = os.getenv("KAFKA_BROKERS", "openvelox-kafka-bootstrap.kafka.svc.cluster.local:9092")
KAFKA_SECURITY_PROTOCOL = os.getenv("KAFKA_SECURITY_PROTOCOL", "SASL_PLAINTEXT")
KAFKA_SASL_MECHANISM = os.getenv("KAFKA_SASL_MECHANISM", "OAUTHBEARER")

# Keycloak OAuth2 — the API runs the client-credentials flow against this
# endpoint to obtain a JWT that is then used as a bearer token for Trino and
# as the SASL OAUTHBEARER credential for Kafka. Matches the mappers on the
# `openvelox-api` client in infra/terraform/keycloak-realm/main.tf.
KEYCLOAK_TOKEN_URL = os.getenv(
    "KEYCLOAK_TOKEN_URL",
    "http://keycloak.platform.svc.cluster.local:8080/realms/openvelox/protocol/openid-connect/token",
)
OAUTH_CLIENT_ID = os.getenv("OAUTH_CLIENT_ID", "openvelox-api")
OAUTH_CLIENT_SECRET = os.getenv("OAUTH_CLIENT_SECRET", "")

TFL_API_KEY = os.getenv("TFL_API_KEY", "")
