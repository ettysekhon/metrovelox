-- Smoke test: Strimzi Kafka -> Flink -> Iceberg (line-status only, batch mode)
--
-- Reads all existing messages on the openvelox Strimzi cluster then finishes.
-- Useful for verifying the end-to-end Kafka -> Flink -> Iceberg/Polaris
-- pipeline without running a continuous streaming job.
--
-- Submit against the Flink Operator-managed session cluster (has the
-- Strimzi OAuth JARs on /opt/flink/lib/ and the KAFKA_* env vars bound
-- from the kafka-flink-oauth Secret):
--
--   kubectl exec -n streaming flink-session-<pod> -- sh -c 'envsubst < /opt/flink/jobs/raw/smoke_test_line_status.sql | ./bin/sql-client.sh -f /dev/stdin'
--
-- The `${...}` placeholders are resolved by envsubst at submit time from
-- pod env vars: KAFKA_BOOTSTRAP, KAFKA_TOKEN_ENDPOINT, KAFKA_FLINK_CLIENT_ID,
-- KAFKA_FLINK_OAUTH_CLIENT_SECRET. Flink SQL does NOT expand ${} itself.

CREATE CATALOG `raw` WITH (
    'type' = 'iceberg',
    'catalog-type' = 'rest',
    'uri' = 'http://polaris.data.svc.cluster.local:8181/api/catalog',
    'warehouse' = 'raw',
    'credential' = 'root:polaris-root-secret',
    'scope' = 'PRINCIPAL_ROLE:ALL'
);

-- Iceberg REST catalogs won't auto-create namespaces when a qualified
-- CREATE TABLE is issued, so ensure `raw.tube` exists before the table.
CREATE DATABASE IF NOT EXISTS `raw`.tube;

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
    'properties.group.id' = 'flink-raw-lines-smoke',
    'scan.startup.mode' = 'earliest-offset',
    'scan.bounded.mode' = 'latest-offset',
    'format' = 'json',
    -- SASL OAUTHBEARER via Strimzi's kafka-oauth client JARs
    -- (staged onto /opt/flink/lib/ by the strimzi-oauth-download
    -- initContainer in flink-session.yaml).
    'properties.security.protocol' = 'SASL_PLAINTEXT',
    'properties.sasl.mechanism' = 'OAUTHBEARER',
    'properties.sasl.login.callback.handler.class' = 'io.strimzi.kafka.oauth.client.JaasClientOauthLoginCallbackHandler',
    'properties.sasl.jaas.config' = 'org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required oauth.client.id="${KAFKA_FLINK_CLIENT_ID}" oauth.client.secret="${KAFKA_FLINK_OAUTH_CLIENT_SECRET}" oauth.token.endpoint.uri="${KAFKA_TOKEN_ENDPOINT}" ;'
);

SET 'execution.runtime-mode' = 'batch';

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
