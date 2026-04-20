FROM flink:2.2.0-scala_2.12-java17

# Hadoop classes (required by Iceberg REST catalog for Configuration, FileSystem)
RUN wget -q -P /opt/flink/lib/ \
  https://repo1.maven.org/maven2/org/apache/flink/flink-shaded-hadoop-2-uber/2.8.3-10.0/flink-shaded-hadoop-2-uber-2.8.3-10.0.jar

# Kafka connector (non-shaded variant, pairs with unshaded kafka-clients).
# The shaded uber JAR (flink-sql-connector-kafka) would be more convenient but
# it relocates kafka-clients into org.apache.flink.kafka.shaded.*, which makes
# it impossible for the Strimzi OAuth login handler to extend the unshaded
# org.apache.kafka.common.security.auth.AuthenticateCallbackHandler that the
# Kafka client resolves via Class.forName() at SASL negotiation time.
RUN wget -q -P /opt/flink/lib/ \
  https://repo1.maven.org/maven2/org/apache/flink/flink-connector-kafka/4.0.1-2.0/flink-connector-kafka-4.0.1-2.0.jar \
  && wget -q -P /opt/flink/lib/ \
  https://repo1.maven.org/maven2/org/apache/kafka/kafka-clients/3.9.1/kafka-clients-3.9.1.jar

# Strimzi OAuth client + transitive runtime deps.
# Versions pulled from io.strimzi:oauth:0.16.1 parent pom properties
# (jackson 2.15.3, nimbus-jose-jwt 9.37.2, jsonpath 2.9.0, json-smart 2.5.2).
# These are what kafka-oauth-client needs when Class.forName()-loaded at
# SASL OAUTHBEARER negotiation time; without them the login handler loads
# but dies with NoClassDefFoundError the instant it POSTs to the token
# endpoint (jackson-databind / nimbus / json-path all chained in there).
RUN for url in \
    https://repo1.maven.org/maven2/io/strimzi/kafka-oauth-client/0.16.1/kafka-oauth-client-0.16.1.jar \
    https://repo1.maven.org/maven2/io/strimzi/kafka-oauth-common/0.16.1/kafka-oauth-common-0.16.1.jar \
    https://repo1.maven.org/maven2/com/fasterxml/jackson/core/jackson-core/2.15.3/jackson-core-2.15.3.jar \
    https://repo1.maven.org/maven2/com/fasterxml/jackson/core/jackson-databind/2.15.3/jackson-databind-2.15.3.jar \
    https://repo1.maven.org/maven2/com/fasterxml/jackson/core/jackson-annotations/2.15.3/jackson-annotations-2.15.3.jar \
    https://repo1.maven.org/maven2/com/jayway/jsonpath/json-path/2.9.0/json-path-2.9.0.jar \
    https://repo1.maven.org/maven2/net/minidev/json-smart/2.5.2/json-smart-2.5.2.jar \
    https://repo1.maven.org/maven2/net/minidev/accessors-smart/2.5.2/accessors-smart-2.5.2.jar \
    https://repo1.maven.org/maven2/com/google/code/gson/gson/2.10.1/gson-2.10.1.jar \
  ; do wget -q -P /opt/flink/lib/ "$url"; done \
  # flink-shaded-hadoop-2-uber ships a stale com.nimbusds.jose.Payload that
  # pre-dates toType(PayloadTransformer); prefix our modern copy with aa- so
  # it sorts first in Flink's alphabetical classpath enumeration.
  && wget -q -O /opt/flink/lib/aa-nimbus-jose-jwt-9.37.2.jar \
    https://repo1.maven.org/maven2/com/nimbusds/nimbus-jose-jwt/9.37.2/nimbus-jose-jwt-9.37.2.jar

# Iceberg Flink runtime (Iceberg connector + REST catalog support)
RUN wget -q -P /opt/flink/lib/ \
  https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-flink-runtime-2.0/1.10.1/iceberg-flink-runtime-2.0-1.10.1.jar

# Iceberg GCP bundle (GCSFileIO + google-api-client deps for writing to GCS)
RUN wget -q -P /opt/flink/lib/ \
  https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-gcp-bundle/1.10.1/iceberg-gcp-bundle-1.10.1.jar

# GCS filesystem plugin (checkpoints + Iceberg data on GCS)
RUN mkdir -p /opt/flink/plugins/gs-fs-hadoop && \
  wget -q -P /opt/flink/plugins/gs-fs-hadoop/ \
  https://repo1.maven.org/maven2/org/apache/flink/flink-gs-fs-hadoop/2.2.0/flink-gs-fs-hadoop-2.2.0.jar

# Prometheus metrics reporter (exposes /metrics on port 9249)
RUN mkdir -p /opt/flink/plugins/metrics-prometheus && \
  wget -q -P /opt/flink/plugins/metrics-prometheus/ \
  https://repo1.maven.org/maven2/org/apache/flink/flink-metrics-prometheus/2.2.0/flink-metrics-prometheus-2.2.0.jar
