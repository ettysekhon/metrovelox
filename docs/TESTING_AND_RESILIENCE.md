# Testing and resilience

_Last reviewed: 2026-04-19_ (post TfL raw → curated → analytics soak).

How to prove the end-to-end streaming pipeline is working, how to break it
on purpose, and what "healthy" looks like. Complements
[ROADMAP](ROADMAP.md).

---

## Contents

1. [Tiers at a glance](#tiers-at-a-glance)
2. [Tier 1 — smoke (every deploy)](#tier-1--smoke-every-deploy)
3. [Tier 2 — integration (weekly)](#tier-2--integration-weekly)
4. [Tier 3 — chaos (before each release)](#tier-3--chaos-before-each-release)
5. [What "healthy" looks like](#what-healthy-looks-like)
6. [Recording a run](#recording-a-run)
7. [Known gaps](#known-gaps)

---

## Tiers at a glance

| Tier | Cadence              | Goal                                                 | Duration |
| ---- | -------------------- | ---------------------------------------------------- | -------- |
| 1    | Every deploy + daily | "Data is flowing right now" smoke                    | ~3 min   |
| 2    | Weekly               | Cross-component integration (Airflow, Spark, API)    | ~30 min  |
| 3    | Before each release  | Chaos — survive TM kill, Polaris restart, broker out | ~60 min  |

All commands below assume:

```bash
export CTX=gke-openvelox-elt-01   # or your cluster context
alias k="kubectl --context=$CTX"
```

and that `jq` and `python3` are available locally. Secrets are read live
from the cluster — nothing committed.

---

## Tier 1 — smoke (every deploy)

In under three minutes, confirm producer → Kafka → Flink → Iceberg is
alive and serving fresh data. Run after every ArgoCD sync and as the first
step of any manual investigation.

### 1.1 Flink jobs `RUNNING` with recent successful checkpoints

```bash
JM=$(k -n streaming get pods -l component=jobmanager -o jsonpath='{.items[0].metadata.name}')

k -n streaming exec "$JM" -- curl -fsS http://localhost:8081/jobs/overview \
  | python3 -c "
import json, sys, time
now = int(time.time() * 1000)
for j in json.load(sys.stdin)['jobs']:
    if j['state'] == 'FINISHED':
        continue
    age_min = (now - j['start-time']) // 60000
    print(f\"  {j['state']:8s} uptime={age_min:4d}m  {j['name'][:70]}\")
"
```

Healthy: three jobs (`raw.*`, `curated.*`, `analytics.*`), all `RUNNING`,
uptime > 5 min.

Per-job checkpoint counters:

```bash
for JID in $(k -n streaming exec "$JM" -- curl -fsS http://localhost:8081/jobs/overview \
    | python3 -c "import json,sys; [print(j['jid']) for j in json.load(sys.stdin)['jobs'] if j['state']=='RUNNING']"); do
  k -n streaming exec "$JM" -- curl -fsS "http://localhost:8081/jobs/$JID/checkpoints" \
    | python3 -c "
import json, sys
d = json.load(sys.stdin); c = d['counts']
print(f\"  completed={c['completed']:4d}  failed={c['failed']:3d}  restored={c['restored']:2d}  in_progress={c['in_progress']}\")
"
done
```

Healthy: `completed` monotonic (~1 / 45 s per job), `failed` low and flat,
`in_progress` usually 0.

### 1.2 Lakehouse rows and freshness (Iceberg via Flink SQL)

Trino is OAuth2-gated for interactive users; for smoke we query Iceberg
through the Flink SQL client against the same Polaris REST catalog — same
proof, zero browser ceremony.

```bash
cat > /tmp/smoke-lakehouse.sql <<'EOF'
SET 'sql-client.execution.result-mode' = 'tableau';
SET 'execution.runtime-mode' = 'batch';

CREATE CATALOG `raw`       WITH ('type'='iceberg','catalog-type'='rest','uri'='http://polaris.data.svc.cluster.local:8181/api/catalog','warehouse'='raw','credential'='root:polaris-root-secret','scope'='PRINCIPAL_ROLE:ALL');
CREATE CATALOG `curated`   WITH ('type'='iceberg','catalog-type'='rest','uri'='http://polaris.data.svc.cluster.local:8181/api/catalog','warehouse'='curated','credential'='root:polaris-root-secret','scope'='PRINCIPAL_ROLE:ALL');
CREATE CATALOG `analytics` WITH ('type'='iceberg','catalog-type'='rest','uri'='http://polaris.data.svc.cluster.local:8181/api/catalog','warehouse'='analytics','credential'='root:polaris-root-secret','scope'='PRINCIPAL_ROLE:ALL');

SELECT 'raw.tube.line_status'                   AS t, COUNT(*) AS rows_total, MAX(event_time)  AS max_ts FROM `raw`.tube.line_status;
SELECT 'raw.bus.arrivals'                       AS t, COUNT(*) AS rows_total, MAX(event_time)  AS max_ts FROM `raw`.bus.arrivals;
SELECT 'raw.cycling.bike_occupancy'             AS t, COUNT(*) AS rows_total, MAX(event_time)  AS max_ts FROM `raw`.cycling.bike_occupancy;
SELECT 'curated.cycling.bike_occupancy'         AS t, COUNT(*) AS rows_total, MAX(event_time)  AS max_ts FROM `curated`.cycling.bike_occupancy;
SELECT 'curated.bus.arrivals'                   AS t, COUNT(*) AS rows_total, MAX(event_time)  AS max_ts FROM `curated`.bus.arrivals;
SELECT 'analytics.tube.line_status_latest'      AS t, COUNT(*) AS rows_total, MAX(last_updated) AS max_ts FROM `analytics`.tube.line_status_latest;
SELECT 'analytics.cycling.bike_station_hourly'  AS t, COUNT(*) AS rows_total, MAX(window_end)   AS max_ts FROM `analytics`.cycling.bike_station_hourly;
EOF

JM=$(k -n streaming get pods -l component=jobmanager -o jsonpath='{.items[0].metadata.name}')
k -n streaming cp /tmp/smoke-lakehouse.sql "$JM:/tmp/smoke-lakehouse.sql" -c flink-main-container
k -n streaming exec -c flink-main-container "$JM" -- /opt/flink/bin/sql-client.sh -f /tmp/smoke-lakehouse.sql 2>&1 | grep -E '^\|'
```

Healthy: all seven tables return a row, `rows_total` grows between runs,
`max_ts` ≤ 3 min behind wall-clock for raw/curated, ≤ 1 h for analytics.

### 1.3 Kafka hot-path topics have keyed, schema-valid messages

OAuth credentials live in `streaming/kafka-flink-oauth`. Shove a
`consumer.properties` into a Strimzi broker pod and use its CLI tooling:

```bash
CID=$(k -n streaming get secret kafka-flink-oauth -o jsonpath='{.data.client-id}'     | base64 -d)
CSC=$(k -n streaming get secret kafka-flink-oauth -o jsonpath='{.data.client-secret}' | base64 -d)

cat > /tmp/consumer.properties <<PROPS
security.protocol=SASL_PLAINTEXT
sasl.mechanism=OAUTHBEARER
sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required \
  oauth.client.id="${CID}" oauth.client.secret="${CSC}" \
  oauth.token.endpoint.uri="http://keycloak.platform.svc.cluster.local:8080/realms/openvelox/protocol/openid-connect/token" \
  oauth.scope="openid" ;
sasl.login.callback.handler.class=io.strimzi.kafka.oauth.client.JaasClientOauthLoginCallbackHandler
PROPS

k -n kafka cp /tmp/consumer.properties openvelox-mixed-0:/tmp/consumer.properties

for T in tfl.curated.bike-occupancy tfl.analytics.line-status-latest tfl.raw.line-status; do
  echo "=== $T ==="
  k -n kafka exec openvelox-mixed-0 -- /opt/kafka/bin/kafka-get-offsets.sh \
    --bootstrap-server openvelox-kafka-bootstrap.kafka.svc.cluster.local:9092 \
    --command-config /tmp/consumer.properties --topic "$T" 2>/dev/null | tail -3
done

for T in tfl.analytics.line-status-latest tfl.curated.bike-occupancy; do
  echo "=== sample $T ==="
  k -n kafka exec openvelox-mixed-0 -- timeout 20 /opt/kafka/bin/kafka-console-consumer.sh \
    --bootstrap-server openvelox-kafka-bootstrap.kafka.svc.cluster.local:9092 \
    --consumer.config /tmp/consumer.properties \
    --topic "$T" --from-beginning --max-messages 1 --property print.key=true 2>&1 \
    | grep -v "WARN\|Processed"
done
```

Healthy:

- Offsets on `tfl.raw.*` grow between runs (producer alive).
- `tfl.curated.bike-occupancy` messages keyed by `{"bike_point_id":...}`.
- `tfl.analytics.line-status-latest` messages keyed by `{"line_id":...}`
  and carry the full line-status envelope.

### 1.4 API path

The FastAPI backend (`openvelox-api` in `apps`) fronts the lakehouse with
HTTP + WebSocket. It mints a Keycloak JWT (client-credentials, `aud=trino`)
for Trino and uses the same token (`aud=kafka-broker`) for SASL
OAUTHBEARER against Kafka. Source:
[`apps/api/app/auth.py`](../apps/api/app/auth.py),
[`helm/trino/values-gke.tmpl.yaml`](../helm/trino/values-gke.tmpl.yaml).

Health probe (round-trips Trino with the service-account JWT):

```bash
curl -fsS "https://api.${DOMAIN}/health" | jq
```

Healthy: `{ "status": "healthy", "trino_available": true, ... }`.
`trino_available=true` confirms the token cache minted a JWT, Trino's `jwt`
authenticator validated it, and the SA principal ran `SELECT 1`.

Lakehouse read (Trino-backed):

```bash
curl -fsS "https://api.${DOMAIN}/api/v1/lines/status" | jq '.source, (.lines | length)'
```

Healthy: `"source": "lakehouse"`, ≥ 1 line. `"source": "tfl_api"` on a
healthy table means fallback fired — check pod logs; the warning now
includes exception type and message.

Hot-path stream (Kafka-backed WebSocket):

```bash
wscat -c "wss://api.${DOMAIN}/ws/streams" \
  <<< '{"action":"subscribe","topics":["tfl.analytics.line-status-latest"]}'
```

Healthy: a `{"type":"subscribed", ...}` ack followed by one or more
`{"type":"message","topic":"tfl.analytics.line-status-latest", ...}`
envelopes within 60 s.

Failure signatures:

| Symptom                                                | Root cause                                                                   |
| ------------------------------------------------------ | ---------------------------------------------------------------------------- |
| `/api/v1/lines/status` returns `source: "tfl_api"`     | Lakehouse query failed — exception now in pod log since the 0.1.1 refactor   |
| API log: `Column 'X' cannot be resolved`               | Schema drift between API SELECTs and Flink analytics SQL                     |
| API log: `Error processing metadata for table`         | Iceberg snapshot/manifest corruption in Polaris (separate lakehouse issue)   |
| API log: `403 Authentication over HTTP`                | `allow-insecure-over-http=true` missing from Trino values                    |
| API log: `unauthorized_client`                         | `openvelox-api` KC client lacks `service_accounts_enabled`                   |
| Kafka consumer log: `InvalidAuthenticationError`       | KC `aud=kafka-broker` mapper missing, or `kafka-consumer` role not granted   |
| API pod: `OAUTH_CLIENT_SECRET is not set`              | ExternalSecret `openvelox-api-oauth` hasn't synced yet                       |

---

## Tier 2 — integration (weekly)

Tier 1 proves the streaming spine. Tier 2 covers the rest.

| # | What                                            | How                                                                                                            |
| - | ----------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| 1 | Airflow quality-gate DAG passes                 | `airflow dags trigger quality_gates` → all tasks `success`                                                     |
| 2 | Airflow `reference_scd2` applies SCD2 upserts   | Trigger DAG, then `SELECT effective_to FROM reference.*` shows open-ended latest rows                          |
| 3 | Spark backfill writes a partition               | `airflow dags trigger spark_backfill` with `{"start":"2026-04-10","end":"2026-04-10"}`                         |
| 4 | Trino serves analytics to a user                | Log in at `https://query.${DOMAIN}`, run `SELECT * FROM analytics.tube.line_status_latest LIMIT 10`            |
| 5 | WebSocket hot path pushes updates               | `wscat -c "wss://api.${DOMAIN}/ws/streams"` — receive messages within 30 s                                     |
| 6 | Dashboard renders live data                     | Browser to `https://${DOMAIN}` — line-status tiles update without refresh                                      |
| 7 | ArgoCD reconciles a manifest change             | Bump a trivial annotation, commit, push — Argo sync within 3 min                                               |
| 8 | Vault template renders a new secret             | Rotate a password in Vault — dependent pod rolls and picks it up                                               |

Log results in the runbook — see [Recording a run](#recording-a-run).

---

## Tier 3 — chaos (before each release)

Break things on purpose to prove the pipeline recovers. Run against prod
**only** during a quiet window; dev any time.

> Pattern for every chaos test: **baseline → break → observe → verify
> recovered state matches baseline**. Always capture checkpoint counters,
> topic offsets, and row counts before and after.

### 3.1 TaskManager crash (state resume from GCS)

Kills one TM mid-flight. Expected: Flink reschedules tasks onto a new TM,
restores every job from its latest GCS checkpoint, no data loss or reprocess
from topic head.

```bash
# Baseline
k -n streaming exec "$JM" -- curl -fsS http://localhost:8081/jobs/overview

# Break
TM=$(k -n streaming get pods -l component=taskmanager -o jsonpath='{.items[0].metadata.name}')
k -n streaming delete pod "$TM" --grace-period=0 --force

# Observe + verify
sleep 60
k -n streaming get pods -l component=taskmanager
k -n streaming exec "$JM" -- curl -fsS http://localhost:8081/jobs/overview
# Per-job: restored++ and external_path=gs://<flink-bucket>/checkpoints/<jid>/...
```

Pass:

- New TM `Running 1/1` within 60 s.
- All jobs back to `RUNNING`.
- Each job's `restored` counter +1; `external_path` points at GCS; no extra
  `failed` > 1 per job.
- Row counts in Iceberg continue to grow on the next smoke run.

Observed 2026-04-19: TM-1-3 killed → TM-1-4 ready in 42 s; 3/3 jobs
restored from `gs://openvelox-elt-01-flink/checkpoints/…`; one in-progress
checkpoint failed (expected), no extra tail failures.

### 3.2 Polaris REST catalog restart (commit retry)

Rolls the Polaris deployment while Flink is writing. Expected: Iceberg
commit retries absorb the ~30 s outage; jobs stay `RUNNING`; new rows land
through the restarting catalog.

```bash
# Baseline — per-job completed/failed counters, row counts

# Break
k -n data rollout restart deploy/polaris
k -n data rollout status  deploy/polaris --timeout=180s

# Observe — three checkpoint windows
sleep 90
# Verify — row counts grew, max_ts advanced past the restart window
```

Pass:

- All Flink jobs stayed `RUNNING`.
- `failed` checkpoint counter +1 at most per job.
- Next smoke shows `rows_total` grew and `max_ts` is _inside_ the restart
  window — commits landed through the recovering catalog.

Observed 2026-04-19: 3/3 jobs stayed `RUNNING`; 0 new checkpoint failures;
`raw.cycling.bike_occupancy` went 299 672 → 302 063 with `max_ts = 14:35:03`
landing during the restart.

### 3.3 Kafka broker restart (not yet run on prod)

Rolls the Strimzi broker with ISR re-election. Expected: Flink clients
reconnect transparently; in-flight commits retry.

```bash
# Baseline — offsets + consumer-group lag
k -n kafka exec openvelox-mixed-0 -- /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server openvelox-kafka-bootstrap.kafka.svc.cluster.local:9092 \
  --command-config /tmp/consumer.properties --all-groups --describe

# Break
k -n kafka rollout restart strimzipodset openvelox-mixed
k -n kafka rollout status  strimzipodset openvelox-mixed --timeout=300s

# Verify — no lag permanently stuck, all three Flink jobs still RUNNING
```

Pass: consumer-group lag spikes but drains within 5 min; no Flink job
restart; row counts continue to grow.

Status: planned for next release window. Strimzi already guarantees no
partition goes offline with `min.insync.replicas=2`; we still want the
runbook-level proof.

### 3.4 Producer outage (watermark hold)

Pauses `ingest_tfl_sources` for 10 min. Expected: Flink idles cleanly —
no crashes, watermarks hold at the last event time, no spurious window
emissions. When the producer returns, Flink catches up without reprocessing
from offset 0.

```bash
# Break
k -n batch exec <airflow-scheduler-pod> -c scheduler -- airflow dags pause ingest_tfl_sources

# Wait 10 min — Flink jobs stay RUNNING, no new failed checkpoints,
# no surge in watermark-dependent operator state

# Recover
k -n batch exec <airflow-scheduler-pod> -c scheduler -- airflow dags unpause ingest_tfl_sources
k -n batch exec <airflow-scheduler-pod> -c scheduler -- airflow dags trigger  ingest_tfl_sources
```

Pass: zero new `failed` checkpoints during the outage; consumer lag bounded
(offsets advance by whatever the producer pushed _before_ the pause, then
flat, then catch up after un-pause).

Status: opportunistically observed on 2026-04-19 — the soak cluster had
been running against a paused DAG for ~45 min before un-pause; Flink kept
checkpointing cleanly.

### 3.5 JobManager crash (session-cluster HA)

```bash
k -n streaming delete pod -l component=jobmanager --grace-period=0 --force
```

Pass: Flink Operator brings up a new JM from configmap-managed HA state;
running jobs resume from their latest completed checkpoint.

Status: not yet run. Needs `high-availability: kubernetes` verified in the
`FlinkDeployment` CR first.

---

## What "healthy" looks like

Steady-state reference (2026-04-19 `openvelox-elt-01`, TfL pipelines,
~1 poll / min):

| Metric                                       | Healthy range                 | Where to read it                                        |
| -------------------------------------------- | ----------------------------- | ------------------------------------------------------- |
| Flink job `state`                            | `RUNNING`                     | `/jobs/overview`                                        |
| Checkpoint interval (completed Δ)            | 1 per ~45 s per job           | `/jobs/<jid>/checkpoints` — `completed`                 |
| Checkpoint failure ratio                     | `failed / completed < 2 %`    | same                                                    |
| Checkpoint end-to-end duration               | < 1 s                         | `latest.completed.end_to_end_duration`                  |
| Checkpoint `restored`                        | only increases on TM/JM churn | `/jobs/<jid>/checkpoints.counts.restored`               |
| `raw.*` max event_time lag                   | ≤ 2 min behind wall-clock     | Tier 1.2                                                |
| `curated.*` max event_time lag               | ≤ 3 min behind wall-clock     | Tier 1.2                                                |
| `analytics.*.bike_station_hourly` window_end | last closed hour              | Tier 1.2                                                |
| Kafka consumer-group lag (`flink-sql-*`)     | < 1 000 msgs per partition    | `kafka-consumer-groups.sh --describe`                   |
| Polaris liveness                             | HTTP 401 on `/v1/config`      | Proves process alive + serving (unauthenticated probe)  |

Anything outside these ranges warrants a look. Once the Prometheus alerts
land (below), these become alerts instead of runbook steps.

---

## Recording a run

Every Tier 3 run goes in the release checklist. Template:

```markdown
### Release X.Y.Z — chaos sweep YYYY-MM-DD

**Cluster:** openvelox-elt-01
**Operator:** @<handle>
**Duration under load:** <hh:mm>

| Test                     | Pass | Notes                                    |
| ------------------------ | ---- | ---------------------------------------- |
| 3.1 TM kill              |      | restore from gs://…, T+<n>s              |
| 3.2 Polaris restart      |      | <n> new failed ckpts                     |
| 3.3 Kafka broker restart |      | peak lag <n>, drained in <m> min         |
| 3.4 Producer outage      |      | watermark held at <ts>                   |
| 3.5 JM crash             |      | HA restore, <n> jobs restarted           |

**Baseline row counts vs final row counts:** ...
**Open issues raised:** #<ids>
```

Keep filled-in run logs under `docs/runbooks/` (directory to be created
with the first real release).

---

## Known gaps

In priority order:

1. **Dashboard (apps/frontend) E2E not in smoke.** FastAPI is wired
   end-to-end (Tier 1.4 is live). The Next.js dashboard deploys alongside
   the API from `infra/k8s/apps/overlays/prod`, but a Playwright smoke
   (hit `https://${DOMAIN}`, assert live tiles update) still needs
   automating. Tracked in [ROADMAP](ROADMAP.md).
2. **No automated CI runs Tier 1.** Today it's a manual runbook; it should
   be a `CronJob` in `monitoring` firing every 10 min and posting results
   to Grafana / failing loud.
3. **No Grafana "TfL E2E lag" panel.** Planned post-soak PR:
   - Per-layer max event_time lag (Iceberg `MAX(event_time) - now()`).
   - Checkpoint success-rate gauge per job.
   - Kafka consumer-group lag per hot-path topic.
4. **No Prometheus alert rules for Flink.** Planned under
   `infra/k8s/monitoring/base/rules/`:
   - `FlinkJobNotRunning` — `state != RUNNING` for 5 min.
   - `FlinkCheckpointFailureRateHigh` — `failed / completed > 10 %` over 30 min.
   - `FlinkCheckpointStalled` — no completed checkpoint for 10 min.
   - `IcebergFreshnessStale` — curated `max event_time` older than 5 min.
   - `KafkaHotPathTopicDry` — no messages in 10 min on
     `tfl.curated.*` / `tfl.analytics.*`.
5. **Kafka broker chaos + JM HA chaos not exercised on prod.** See §3.3 and §3.5.
6. **No load test.** Today's TfL cadence (~1 poll / min per source) is
   tiny; behaviour under bursty or sustained high throughput is unproven.
   A synthetic producer that can drive `tfl.raw.*` at 10–100× real rate
   should land before onboarding a second domain.
