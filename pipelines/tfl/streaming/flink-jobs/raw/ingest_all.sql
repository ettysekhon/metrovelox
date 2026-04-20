-- Continuous streaming: Strimzi Kafka -> Flink -> Iceberg Raw (via Polaris)
--
-- Runs as a single Flink streaming job processing all three TfL topics on
-- the openvelox Strimzi cluster. Submit against the Flink Operator-managed
-- session cluster (has the Strimzi OAuth JARs on /opt/flink/lib/ and the
-- KAFKA_* env vars bound from the kafka-flink-oauth Secret):
--
--   kubectl exec -n streaming flink-session-<pod> -- sh -c 'envsubst < /opt/flink/jobs/raw/ingest_all.sql | ./bin/sql-client.sh -f /dev/stdin'
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

-- ─── Iceberg tables (idempotent) ─────────────────────────────────

-- Iceberg REST catalogs won't auto-create namespaces when a qualified
-- CREATE TABLE is issued, so ensure every raw.<domain> namespace exists.
CREATE DATABASE IF NOT EXISTS `raw`.tube;
CREATE DATABASE IF NOT EXISTS `raw`.bus;
CREATE DATABASE IF NOT EXISTS `raw`.cycling;

CREATE TABLE IF NOT EXISTS `raw`.tube.line_status (
    line_id            STRING,
    line_name          STRING,
    mode_id            STRING,
    status_severity    INT,
    status_description STRING,
    reason             STRING,
    event_time         TIMESTAMP(6),
    ingested_at        TIMESTAMP(6)
);

CREATE TABLE IF NOT EXISTS `raw`.bus.arrivals (
    arrival_id       STRING,
    vehicle_id       STRING,
    line_id          STRING,
    line_name        STRING,
    destination_name STRING,
    stop_id          STRING,
    stop_name        STRING,
    platform_name    STRING,
    direction        STRING,
    expected_arrival STRING,
    time_to_station  INT,
    current_location STRING,
    towards          STRING,
    event_time       TIMESTAMP(6),
    ingested_at      TIMESTAMP(6)
);

CREATE TABLE IF NOT EXISTS `raw`.cycling.bike_occupancy (
    bike_point_id  STRING,
    common_name    STRING,
    lat            DOUBLE,
    lon            DOUBLE,
    nb_bikes       INT,
    nb_ebikes      INT,
    nb_empty_docks INT,
    nb_docks       INT,
    event_time     TIMESTAMP(6),
    ingested_at    TIMESTAMP(6)
);

-- ─── Kafka source tables (openvelox Strimzi, SASL OAUTHBEARER) ────

CREATE TEMPORARY TABLE kafka_line_status (
    event_type  STRING,
    data        STRING,
    ingested_at TIMESTAMP(3),
    event_time  TIMESTAMP(3) METADATA FROM 'timestamp',
    WATERMARK FOR event_time AS event_time - INTERVAL '5' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'tfl.raw.line-status',
    'properties.bootstrap.servers' = '${KAFKA_BOOTSTRAP}',
    'properties.group.id' = 'flink-raw-lines',
    'scan.startup.mode' = 'earliest-offset',
    'format' = 'json',
    'properties.security.protocol' = 'SASL_PLAINTEXT',
    'properties.sasl.mechanism' = 'OAUTHBEARER',
    'properties.sasl.login.callback.handler.class' = 'io.strimzi.kafka.oauth.client.JaasClientOauthLoginCallbackHandler',
    'properties.sasl.jaas.config' = 'org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required oauth.client.id="${KAFKA_FLINK_CLIENT_ID}" oauth.client.secret="${KAFKA_FLINK_OAUTH_CLIENT_SECRET}" oauth.token.endpoint.uri="${KAFKA_TOKEN_ENDPOINT}" ;'
);

CREATE TEMPORARY TABLE kafka_bus_arrivals (
    event_type  STRING,
    data        STRING,
    ingested_at TIMESTAMP(3),
    event_time  TIMESTAMP(3) METADATA FROM 'timestamp',
    WATERMARK FOR event_time AS event_time - INTERVAL '5' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'tfl.raw.bus-arrivals',
    'properties.bootstrap.servers' = '${KAFKA_BOOTSTRAP}',
    'properties.group.id' = 'flink-raw-bus',
    'scan.startup.mode' = 'earliest-offset',
    'format' = 'json',
    'properties.security.protocol' = 'SASL_PLAINTEXT',
    'properties.sasl.mechanism' = 'OAUTHBEARER',
    'properties.sasl.login.callback.handler.class' = 'io.strimzi.kafka.oauth.client.JaasClientOauthLoginCallbackHandler',
    'properties.sasl.jaas.config' = 'org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required oauth.client.id="${KAFKA_FLINK_CLIENT_ID}" oauth.client.secret="${KAFKA_FLINK_OAUTH_CLIENT_SECRET}" oauth.token.endpoint.uri="${KAFKA_TOKEN_ENDPOINT}" ;'
);

CREATE TEMPORARY TABLE kafka_bike_points (
    event_type  STRING,
    data        STRING,
    ingested_at TIMESTAMP(3),
    event_time  TIMESTAMP(3) METADATA FROM 'timestamp',
    WATERMARK FOR event_time AS event_time - INTERVAL '5' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'tfl.raw.bike-points',
    'properties.bootstrap.servers' = '${KAFKA_BOOTSTRAP}',
    'properties.group.id' = 'flink-raw-bikes',
    'scan.startup.mode' = 'earliest-offset',
    'format' = 'json',
    'properties.security.protocol' = 'SASL_PLAINTEXT',
    'properties.sasl.mechanism' = 'OAUTHBEARER',
    'properties.sasl.login.callback.handler.class' = 'io.strimzi.kafka.oauth.client.JaasClientOauthLoginCallbackHandler',
    'properties.sasl.jaas.config' = 'org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required oauth.client.id="${KAFKA_FLINK_CLIENT_ID}" oauth.client.secret="${KAFKA_FLINK_OAUTH_CLIENT_SECRET}" oauth.token.endpoint.uri="${KAFKA_TOKEN_ENDPOINT}" ;'
);

-- ─── Streaming inserts (STATEMENT SET) ───────────────────────────

SET 'execution.runtime-mode' = 'streaming';
SET 'execution.checkpointing.interval' = '60s';

EXECUTE STATEMENT SET
BEGIN

INSERT INTO `raw`.tube.line_status
SELECT
    JSON_VALUE(data, '$.line_id'),
    JSON_VALUE(data, '$.line_name'),
    JSON_VALUE(data, '$.mode_id'),
    CAST(JSON_VALUE(data, '$.status_severity') AS INT),
    JSON_VALUE(data, '$.status_description'),
    JSON_VALUE(data, '$.reason'),
    CAST(event_time AS TIMESTAMP(6)),
    CAST(ingested_at AS TIMESTAMP(6))
FROM kafka_line_status;

INSERT INTO `raw`.bus.arrivals
SELECT
    JSON_VALUE(data, '$.id'),
    JSON_VALUE(data, '$.vehicleId'),
    JSON_VALUE(data, '$.lineId'),
    JSON_VALUE(data, '$.lineName'),
    JSON_VALUE(data, '$.destinationName'),
    JSON_VALUE(data, '$.naptanId'),
    JSON_VALUE(data, '$.stationName'),
    JSON_VALUE(data, '$.platformName'),
    JSON_VALUE(data, '$.direction'),
    JSON_VALUE(data, '$.expectedArrival'),
    CAST(JSON_VALUE(data, '$.timeToStation') AS INT),
    JSON_VALUE(data, '$.currentLocation'),
    JSON_VALUE(data, '$.towards'),
    CAST(event_time AS TIMESTAMP(6)),
    CAST(ingested_at AS TIMESTAMP(6))
FROM kafka_bus_arrivals;

INSERT INTO `raw`.cycling.bike_occupancy
SELECT
    JSON_VALUE(data, '$.bike_point_id'),
    JSON_VALUE(data, '$.common_name'),
    CAST(JSON_VALUE(data, '$.lat') AS DOUBLE),
    CAST(JSON_VALUE(data, '$.lon') AS DOUBLE),
    CAST(JSON_VALUE(data, '$.nb_bikes') AS INT),
    CAST(JSON_VALUE(data, '$.nb_ebikes') AS INT),
    CAST(JSON_VALUE(data, '$.nb_empty_docks') AS INT),
    CAST(JSON_VALUE(data, '$.nb_docks') AS INT),
    CAST(event_time AS TIMESTAMP(6)),
    CAST(ingested_at AS TIMESTAMP(6))
FROM kafka_bike_points;

END;
