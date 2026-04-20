-- Curated Layer: Data quality, enrichment, and fan-out to Kafka compacted topics
--
-- Reads from raw Iceberg, writes to curated Iceberg + Kafka hot-path topics
-- on the openvelox Strimzi cluster. Submit against the Flink Operator-
-- managed session cluster (has the Strimzi OAuth JARs on /opt/flink/lib/
-- and the KAFKA_* env vars bound from the kafka-flink-oauth Secret):
--
--   kubectl exec -n streaming flink-session-<pod> -- sh -c 'envsubst < /opt/flink/jobs/curated/transform.sql | ./bin/sql-client.sh -f /dev/stdin'
--
-- The `${...}` placeholders are resolved by envsubst at submit time; Flink
-- SQL itself does NOT expand ${VAR}.

-- ─── Catalogs ─────────────────────────────────────────────────────

CREATE CATALOG `raw` WITH (
    'type' = 'iceberg',
    'catalog-type' = 'rest',
    'uri' = 'http://polaris.data.svc.cluster.local:8181/api/catalog',
    'warehouse' = 'raw',
    'credential' = 'root:polaris-root-secret',
    'scope' = 'PRINCIPAL_ROLE:ALL'
);

CREATE CATALOG `curated` WITH (
    'type' = 'iceberg',
    'catalog-type' = 'rest',
    'uri' = 'http://polaris.data.svc.cluster.local:8181/api/catalog',
    'warehouse' = 'curated',
    'credential' = 'root:polaris-root-secret',
    'scope' = 'PRINCIPAL_ROLE:ALL'
);

-- ─── Curated Iceberg tables ──────────────────────────────────────

-- Iceberg REST catalogs won't auto-create namespaces when a qualified
-- CREATE TABLE is issued, so ensure every curated.<domain> namespace exists.
CREATE DATABASE IF NOT EXISTS `curated`.cycling;
CREATE DATABASE IF NOT EXISTS `curated`.bus;

CREATE TABLE IF NOT EXISTS `curated`.cycling.bike_occupancy (
    bike_point_id  STRING,
    common_name    STRING,
    lat            DOUBLE,
    lon            DOUBLE,
    nb_bikes       INT,
    nb_ebikes      INT,
    nb_empty_docks INT,
    nb_docks       INT,
    occupancy_pct  DOUBLE,
    is_empty       BOOLEAN,
    is_full        BOOLEAN,
    event_time     TIMESTAMP(6),
    processed_at   TIMESTAMP(6)
);

CREATE TABLE IF NOT EXISTS `curated`.bus.arrivals (
    arrival_id              STRING,
    vehicle_id              STRING,
    line_id                 STRING,
    line_name               STRING,
    destination_name        STRING,
    stop_id                 STRING,
    stop_name               STRING,
    direction               STRING,
    time_to_station_seconds INT,
    has_arrived             BOOLEAN,
    event_time              TIMESTAMP(6),
    processed_at            TIMESTAMP(6)
);

-- ─── Kafka hot-path outputs ──────────────────────────────────────

CREATE TEMPORARY TABLE kafka_curated_bike_occupancy (
    bike_point_id  STRING,
    common_name    STRING,
    nb_bikes       INT,
    nb_ebikes      INT,
    nb_empty_docks INT,
    occupancy_pct  DOUBLE,
    is_empty       BOOLEAN,
    is_full        BOOLEAN,
    event_time     TIMESTAMP(3),
    PRIMARY KEY (bike_point_id) NOT ENFORCED
) WITH (
    'connector' = 'upsert-kafka',
    'topic' = 'tfl.curated.bike-occupancy',
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

-- ─── Streaming transforms ────────────────────────────────────────
--
-- All three sinks share the raw Iceberg source, so STATEMENT SET fuses
-- them into a single Flink job (1 slot instead of 3).
--
-- Iceberg sources default to bounded/batch reads (the job finishes as
-- soon as the current snapshot is consumed), so each FROM `raw`.* uses
-- an OPTIONS hint to flip on incremental streaming mode with a 30s
-- snapshot poll.  Without this the soak would terminate after one
-- pass, regardless of the Kafka sink.

SET 'execution.runtime-mode' = 'streaming';
SET 'execution.checkpointing.interval' = '60s';

EXECUTE STATEMENT SET
BEGIN

INSERT INTO `curated`.cycling.bike_occupancy
SELECT
    bike_point_id,
    common_name,
    lat,
    lon,
    nb_bikes,
    nb_ebikes,
    nb_empty_docks,
    nb_docks,
    ROUND((nb_bikes + nb_ebikes) * 100.0 / NULLIF(nb_docks, 0), 1),
    (nb_bikes + nb_ebikes = 0),
    (nb_empty_docks = 0),
    event_time,
    CAST(CURRENT_TIMESTAMP AS TIMESTAMP(6))
FROM `raw`.cycling.bike_occupancy
    /*+ OPTIONS('streaming'='true','monitor-interval'='30s') */
WHERE
    bike_point_id IS NOT NULL
    -- Explicit CAST to DOUBLE — iceberg-flink-runtime 1.10.1's filter
    -- pushdown can't coerce BigDecimal literals into Iceberg DOUBLE columns.
    AND lat BETWEEN CAST(51.28 AS DOUBLE) AND CAST(51.69 AS DOUBLE)
    AND lon BETWEEN CAST(-0.51 AS DOUBLE) AND CAST(0.33 AS DOUBLE)
    AND nb_bikes >= 0
    AND nb_docks > 0;

INSERT INTO `curated`.bus.arrivals
SELECT
    arrival_id,
    vehicle_id,
    line_id,
    line_name,
    destination_name,
    stop_id,
    stop_name,
    direction,
    CASE WHEN time_to_station < 0 THEN 0 ELSE time_to_station END,
    (time_to_station <= 0),
    event_time,
    CAST(CURRENT_TIMESTAMP AS TIMESTAMP(6))
FROM `raw`.bus.arrivals
    /*+ OPTIONS('streaming'='true','monitor-interval'='30s') */
WHERE
    arrival_id IS NOT NULL
    AND vehicle_id IS NOT NULL
    AND time_to_station BETWEEN -60 AND 3600;

INSERT INTO kafka_curated_bike_occupancy
SELECT
    bike_point_id, common_name, nb_bikes, nb_ebikes, nb_empty_docks,
    ROUND((nb_bikes + nb_ebikes) * 100.0 / NULLIF(nb_docks, 0), 1),
    (nb_bikes + nb_ebikes = 0),
    (nb_empty_docks = 0),
    CAST(event_time AS TIMESTAMP(3))
FROM `raw`.cycling.bike_occupancy
    /*+ OPTIONS('streaming'='true','monitor-interval'='30s') */
WHERE
    bike_point_id IS NOT NULL
    AND nb_bikes >= 0
    AND nb_docks > 0
    -- Match the filter on the Iceberg insert above so the same rows reach Kafka
    -- (and CAST to DOUBLE to satisfy Iceberg-Flink filter pushdown).
    AND lat BETWEEN CAST(51.28 AS DOUBLE) AND CAST(51.69 AS DOUBLE)
    AND lon BETWEEN CAST(-0.51 AS DOUBLE) AND CAST(0.33 AS DOUBLE);

END;
