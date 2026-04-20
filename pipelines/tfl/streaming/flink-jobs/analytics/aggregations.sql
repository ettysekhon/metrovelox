-- Analytics Layer: Business-level aggregations and materialized views
--
-- Reads from curated Iceberg, writes to analytics Iceberg + Kafka compacted
-- topics on the openvelox Strimzi cluster. Submit against the Flink
-- Operator-managed session cluster (has the Strimzi OAuth JARs on
-- /opt/flink/lib/ and the KAFKA_* env vars bound from the
-- kafka-flink-oauth Secret):
--
--   kubectl exec -n streaming flink-session-<pod> -- sh -c 'envsubst < /opt/flink/jobs/analytics/aggregations.sql | ./bin/sql-client.sh -f /dev/stdin'
--
-- The `${...}` placeholders are resolved by envsubst at submit time; Flink
-- SQL itself does NOT expand ${VAR}.

-- ─── Catalogs ─────────────────────────────────────────────────────

CREATE CATALOG `curated` WITH (
    'type' = 'iceberg',
    'catalog-type' = 'rest',
    'uri' = 'http://polaris.data.svc.cluster.local:8181/api/catalog',
    'warehouse' = 'curated',
    'credential' = 'root:polaris-root-secret',
    'scope' = 'PRINCIPAL_ROLE:ALL'
);

CREATE CATALOG `analytics` WITH (
    'type' = 'iceberg',
    'catalog-type' = 'rest',
    'uri' = 'http://polaris.data.svc.cluster.local:8181/api/catalog',
    'warehouse' = 'analytics',
    'credential' = 'root:polaris-root-secret',
    'scope' = 'PRINCIPAL_ROLE:ALL'
);

CREATE CATALOG `raw` WITH (
    'type' = 'iceberg',
    'catalog-type' = 'rest',
    'uri' = 'http://polaris.data.svc.cluster.local:8181/api/catalog',
    'warehouse' = 'raw',
    'credential' = 'root:polaris-root-secret',
    'scope' = 'PRINCIPAL_ROLE:ALL'
);

-- ─── Analytics Iceberg tables ────────────────────────────────────

-- Iceberg REST catalogs won't auto-create namespaces when a qualified
-- CREATE TABLE is issued, so ensure every analytics.<domain> namespace exists.
CREATE DATABASE IF NOT EXISTS `analytics`.cycling;
CREATE DATABASE IF NOT EXISTS `analytics`.tube;

CREATE TABLE IF NOT EXISTS `analytics`.cycling.bike_station_hourly (
    bike_point_id    STRING,
    common_name      STRING,
    window_start     TIMESTAMP(6),
    window_end       TIMESTAMP(6),
    avg_bikes        DOUBLE,
    avg_ebikes       DOUBLE,
    avg_occupancy_pct DOUBLE,
    min_bikes        INT,
    max_bikes        INT,
    empty_count      INT,
    full_count       INT,
    sample_count     BIGINT
);

-- Upsert target: `line_id` is the natural key. IF NOT EXISTS makes this
-- DDL a no-op for clusters that already have the pre-upsert version of
-- the table; see docs/ROADMAP.md §11 for the one-time cutover runbook
-- (drop + recreate with identifier-fields + write.upsert.enabled).
-- Until that cutover runs, the table is append-only and the API is kept
-- correct by the dedup window function in apps/api/app/main.py.
CREATE TABLE IF NOT EXISTS `analytics`.tube.line_status_latest (
    line_id            STRING,
    line_name          STRING,
    mode_id            STRING,
    status_severity    INT,
    status_description STRING,
    reason             STRING,
    last_updated       TIMESTAMP(6),
    PRIMARY KEY (line_id) NOT ENFORCED
) WITH (
    'format-version' = '2',
    'write.upsert.enabled' = 'true'
);

-- ─── Kafka hot-path for line status ──────────────────────────────

CREATE TEMPORARY TABLE kafka_line_status_latest (
    line_id            STRING,
    line_name          STRING,
    status_severity    INT,
    status_description STRING,
    reason             STRING,
    last_updated       TIMESTAMP(3),
    PRIMARY KEY (line_id) NOT ENFORCED
) WITH (
    'connector' = 'upsert-kafka',
    'topic' = 'tfl.analytics.line-status-latest',
    'properties.bootstrap.servers' = '${KAFKA_BOOTSTRAP}',
    'key.format' = 'json',
    'value.format' = 'json',
    -- SASL OAUTHBEARER via Strimzi's kafka-oauth client JARs
    -- (staged onto /opt/flink/lib/ by the strimzi-oauth-download
    -- initContainer in flink-session.yaml).
    'properties.security.protocol' = 'SASL_PLAINTEXT',
    'properties.sasl.mechanism' = 'OAUTHBEARER',
    'properties.sasl.login.callback.handler.class' = 'io.strimzi.kafka.oauth.client.JaasClientOauthLoginCallbackHandler',
    'properties.sasl.jaas.config' = 'org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required oauth.client.id="${KAFKA_FLINK_CLIENT_ID}" oauth.client.secret="${KAFKA_FLINK_OAUTH_CLIENT_SECRET}" oauth.token.endpoint.uri="${KAFKA_TOKEN_ENDPOINT}" ;'
);

-- ─── Streaming aggregations ──────────────────────────────────────
--
-- STATEMENT SET fuses the three sinks into one Flink job.  The Kafka
-- sink pins the Iceberg sources into streaming mode so tumbling-window
-- aggregations keep firing for the full soak.
--
-- Iceberg table columns come through the catalog as plain TIMESTAMP(6)
-- with no time attribute, so TUMBLE() can't use them directly.  Wrap
-- the curated read in a temporary table that inherits the schema via
-- LIKE, adds a computed TIMESTAMP(3) column (watermarks require
-- precision ≤ 3), and declares a WATERMARK over it.
--
-- Iceberg sources default to bounded mode — flip on incremental
-- streaming via OPTIONS on the LIKE so the table acts as an unbounded
-- source, and mirror the hint on the raw.tube.line_status reads below.

SET 'execution.runtime-mode' = 'streaming';
SET 'execution.checkpointing.interval' = '60s';

CREATE TEMPORARY TABLE bike_occupancy_rt (
    event_time_wm AS CAST(event_time AS TIMESTAMP(3)),
    WATERMARK FOR event_time_wm AS event_time_wm - INTERVAL '5' MINUTE
) WITH (
    'streaming' = 'true',
    'monitor-interval' = '30s'
) LIKE `curated`.cycling.bike_occupancy (
    OVERWRITING OPTIONS
);

EXECUTE STATEMENT SET
BEGIN

INSERT INTO `analytics`.cycling.bike_station_hourly
SELECT
    bike_point_id,
    common_name,
    CAST(TUMBLE_START(event_time_wm, INTERVAL '1' HOUR) AS TIMESTAMP(6)),
    CAST(TUMBLE_END(event_time_wm, INTERVAL '1' HOUR) AS TIMESTAMP(6)),
    AVG(CAST(nb_bikes AS DOUBLE)),
    AVG(CAST(nb_ebikes AS DOUBLE)),
    AVG(occupancy_pct),
    MIN(nb_bikes),
    MAX(nb_bikes),
    SUM(CASE WHEN is_empty THEN 1 ELSE 0 END),
    SUM(CASE WHEN is_full THEN 1 ELSE 0 END),
    COUNT(*)
FROM bike_occupancy_rt
GROUP BY
    bike_point_id,
    common_name,
    TUMBLE(event_time_wm, INTERVAL '1' HOUR);

INSERT INTO `analytics`.tube.line_status_latest
-- (read from raw.tube.line_status in streaming mode, see note above)
SELECT
    line_id, line_name, mode_id,
    status_severity, status_description, reason,
    event_time
FROM `raw`.tube.line_status
    /*+ OPTIONS('streaming'='true','monitor-interval'='30s') */;

INSERT INTO kafka_line_status_latest
SELECT
    line_id, line_name,
    status_severity, status_description, reason,
    CAST(event_time AS TIMESTAMP(3))
FROM `raw`.tube.line_status
    /*+ OPTIONS('streaming'='true','monitor-interval'='30s') */;

END;
