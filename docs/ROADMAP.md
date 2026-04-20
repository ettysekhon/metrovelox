# Roadmap — platform gaps

_Last reviewed: 2026-04-19_

Items still standing between OpenVelox and a fully automated single-command
deploy of a production environment. Each entry states the current
workaround, the proper fix, and the files it touches. Resolved issues with
forensic value live in [DEPLOYMENT_ISSUES.md](DEPLOYMENT_ISSUES.md).

---

## Status key

| Icon            | Meaning                                         |
| --------------- | ----------------------------------------------- |
| :red_circle:    | Blocking — manual step required every deploy    |
| :orange_circle: | Degraded — works but fragile or non-persistent  |
| :yellow_circle: | Tech debt — functional but should be improved   |

---

## 1. :red_circle: Container images not built in CI

**Affected:** `flink-lakehouse:2.2`, `tfl-producer:latest`, custom Airflow.

Dockerfiles exist but no pipeline builds them. A developer runs
`docker build && docker push` manually before Kustomize can deploy.
`openvelox-api` and `openvelox-dashboard` are outside this gap — they're
built + pushed by `scripts/build-and-push-apps.sh` and SHA-pinned in
`infra/k8s/apps/overlays/prod/kustomization.yaml` — but the three images
below still sit on the manual path.

| Image            | Dockerfile                                    | Registry path                                                                    |
| ---------------- | --------------------------------------------- | -------------------------------------------------------------------------------- |
| flink-lakehouse  | `platform/streaming/flink-image/Dockerfile`   | `europe-west2-docker.pkg.dev/openvelox-elt-01/openvelox/flink-lakehouse:2.2`     |
| tfl-producer     | `pipelines/tfl/streaming/producer/Dockerfile` | `europe-west2-docker.pkg.dev/openvelox-elt-01/openvelox/tfl-producer:latest`     |
| airflow (custom) | `docker/airflow/Dockerfile`                   | `europe-west2-docker.pkg.dev/openvelox-elt-01/openvelox/airflow:3.1.8-custom-v3` |

**Workaround (Apple Silicon):**

```bash
cd platform/streaming/flink-image
docker build --platform linux/amd64 \
  -t europe-west2-docker.pkg.dev/openvelox-elt-01/openvelox/flink-lakehouse:2.2 .
docker push europe-west2-docker.pkg.dev/openvelox-elt-01/openvelox/flink-lakehouse:2.2

cd pipelines/tfl/streaming/producer
docker build --platform linux/amd64 \
  -t europe-west2-docker.pkg.dev/openvelox-elt-01/openvelox/tfl-producer:latest .
docker push europe-west2-docker.pkg.dev/openvelox-elt-01/openvelox/tfl-producer:latest
```

**Fix:** fold the three builds into the existing `.github/workflows/ci.yaml`
alongside `render-check` and `opa-test`; tag with the Git SHA; update the
Kustomize overlays in the same PR so rollbacks stay in Git.

---

## 2. :red_circle: `airflow-fernet-key` not in Vault / ESO

**Affected:** Airflow (all pods in `batch`).

Airflow's Helm chart expects a Kubernetes secret `airflow-fernet-key` with
key `fernet-key` — encrypts connection credentials in the metadata DB. No
ExternalSecret syncs it from Vault; the secret does not survive a namespace
wipe.

**Workaround:**

```bash
FERNET_KEY=$(python3 -c "import base64, os; print(base64.urlsafe_b64encode(os.urandom(32)).decode())")
kubectl create secret generic airflow-fernet-key -n batch \
  --from-literal=fernet-key="$FERNET_KEY"
```

**Fix:**

1. `vault kv put secret/batch/airflow-fernet fernet-key=<KEY>` (needs the
   root token from `vault-init-prod.json`).
2. ExternalSecret in `batch` pointing at `secret/data/batch/airflow-fernet`.
3. Commit the ExternalSecret under `infra/k8s/platform/` or into the
   Airflow ArgoCD Application source.

> Rotating the Fernet key after data has been encrypted with the old key
> makes existing Airflow connections unreadable. Follow Airflow's
> [Fernet-key rotation](https://airflow.apache.org/docs/apache-airflow/stable/security/secrets/fernet.html#rotating-encryption-keys).

---

## 3. :orange_circle: Vault root token only on the operator's laptop

**Affected:** every Vault `kv put` or policy update.

Lives in `vault-init-prod.json` on the operator's machine. Scripts that
need it must run with that file present, which blocks fully automated
secret seeding (e.g. the Fernet key above).

**Workaround:** operator keeps `vault-init-prod.json` locally and passes the
token manually.

**Fix:** store the root token in GCP Secret Manager (or a password manager
with CLI access). Update `scripts/vault-init.sh` and
`scripts/post-deploy.sh` to pull from there. Also cut a less-privileged
Vault token for day-to-day operations.

---

## 4. :orange_circle: ServerSideApply field ownership blocks field removal

**Affected:** any Helm release deployed with `ServerSideApply=true` in
ArgoCD.

Removing a field from Helm values (`nodeSelector`, `tolerations`, …) does
not strip it from the live resource — the field manager that originally
set the value still owns it, so the old value persists silently.

**Workaround:**

1. Set explicit empty values (`nodeSelector: {}`, `tolerations: []`) in the
   Helm values file. Applied to `helm/kube-prometheus-stack/values-gke.yaml`
   on the Prometheus `prometheusSpec`.
2. Or delete the resource and let ArgoCD recreate it.

**Fix:** remove fields by setting explicit empty values, not by deleting
keys. For charts where field removal is common, consider `Replace=true`
without `ServerSideApply=true`.

---

## 5. :yellow_circle: `tfl-producer:latest` not SHA-pinned

**Affected:** `infra/k8s/streaming/overlays/{dev,prod}/patches-tfl-producer-strimzi.yaml`.

`:latest` breaks reproducibility — a registry push changes what every new
CronJob pod pulls without any code change, and there's no Git SHA in the
manifest to bisect to. `openvelox-api` / `openvelox-dashboard` solved this
with an `images:` block + `newTag:` in the prod overlay; `tfl-producer` has
not been migrated yet.

**Fix:** tag `tfl-producer` with the Git SHA in the CI job that solves §1,
then pin via `images:` / `newTag:` in the overlays. Keep
`imagePullPolicy: Always` only for dev.

---

## 6. :orange_circle: `airflow-github-pat` URI format

**Affected:** Airflow DAG processor — `GitDagBundle` clone.

`airflow-github-pat` stores `AIRFLOW_CONN_GITHUB_DEFAULT`. The legacy format
`github://PAT_TOKEN@` is not recognised by
`airflow.providers.git.bundles.git.GitDagBundle`, which expects `git://`
with the token as the password.

**Fix:** `scripts/post-deploy.sh` writes the correct URI:

```text
git://x-access-token:<PAT_TOKEN>@github.com
```

The PAT is **not** in Git. Bootstrap Terraform creates the secret with
`REPLACE_ME`. Supply the token via `GITHUB_PAT` when running post-deploy,
or store it in Vault at `secret/platform/github` key `pat` (raw token only;
post-deploy assembles the URI).

> Only the token string belongs in Vault — never a full URI. If a
> wrong-format URI was stored, replace it with the raw PAT.

---

## 7. :orange_circle: Strimzi single-broker (RF=1, min-ISR=1)

**Affected:** `infra/k8s/kafka/base/kafka-nodepool.yaml`,
`infra/k8s/kafka/base/kafka.tmpl.yaml`,
`infra/k8s/kafka/overlays/prod/kustomization.yaml`.

The `KafkaNodePool` runs one mixed (controller + broker) replica to fit
the spot-pool footprint. Every replication knob is pinned to 1. Losing the
pod means losing the bus until the spot instance reschedules.

**Workaround:** adequate for current workload. Monitor broker restart
frequency in kafka-ui / Prometheus; if it exceeds a few per day, bring
forward the HA roll-out.

**Fix:**

1. `replicas: 3` on the `mixed` `KafkaNodePool`; add a separate broker-only
   pool if load justifies splitting roles.
2. Flip `default.replication.factor=3`, `min.insync.replicas=2`,
   `offsets.topic.replication.factor=3`,
   `transaction.state.log.replication.factor=3` in `kafka.tmpl.yaml` (or in
   the prod overlay).
3. Run `kafka-reassign-partitions.sh` inside a broker pod to migrate the
   existing `__consumer_offsets` partitions — Strimzi will CrashLoop if
   defaults are flipped while RF=1 partitions remain.
4. Switch the listener from `plain` to `tls` once cert-manager has issued
   a broker cert; add a matching internal listener entry and retire the
   plain one after every client has rolled.

---

## 8. :yellow_circle: Apicurio Registry without auth

**Affected:** `infra/k8s/apicurio/base/deployment.yaml`.

Apicurio launches with `APICURIO_AUTH_ENABLED=false` so the Strimzi rollout
can proceed without a separate Keycloak-client round-trip. Service is
reachable only from inside `kafka` (no `HTTPRoute`), but any pod in the
namespace can write schemas.

**Fix:** OIDC against a new `apicurio` Keycloak client with
`aud=apicurio`, wire `APICURIO_AUTH_ENABLED=true`,
`APICURIO_AUTH_URL_CONFIGURED`,
`APICURIO_AUTH_CLIENT_ID` / `APICURIO_AUTH_CLIENT_SECRET` before the TfL
pipeline starts validating schemas on produce.

---

## 9. :yellow_circle: Flink OAuth JARs pulled from Maven Central at boot

**Affected:** `infra/k8s/streaming/overlays/{dev,prod}/patches-flink-session.yaml`.

A two-stage init-container copies Flink's built-in libs into an overlay
and downloads the Strimzi OAuth JARs
(`kafka-oauth-client`, `kafka-oauth-common`, `jackson`, `nimbus-jose-jwt`,
`json-path`, `gson`) over HTTPS from `repo1.maven.org` every time a pod
starts. Works, but (a) breaks in egress-restricted environments and
(b) adds 5–10 s to cold start. Pinned JAR versions live in the
init-container spec.

**Fix:** extend `pipelines/tfl/streaming/Dockerfile` (or add a new Flink
image) that bakes the JARs into `/opt/flink/lib/` at build time. Push
to Artifact Registry and drop the init-containers.

---

## 10. :yellow_circle: No CI gate for `terraform plan`

**Affected:** every stack under `infra/terraform/`, most painfully
`keycloak-realm` (applied only when a new client is added).

Infrequently applied stacks accumulate silent drift: admin-UI edits,
provider-version upgrades with new defaults, orphan state from retired
subsystems. When a developer finally runs `terraform plan` to add one
resource, the plan contains their change **plus** everything that drifted
— a mixed-intent changeset for the reviewer to reason about.

A real example from the `openvelox-api` OAuth rollout: the plan showed
`4 to add, 2 to change, 3 to destroy` when only five were intended — the
three destroys were orphan Redpanda state; one of the two changes was
`keycloak_openid_client.airflow.authorization.allow_remote_resource_management`
drifting from `true` to the Terraform-declared default of `false`.

**Workaround:** run `scripts/tf-apply.sh <stack> <env> plan` and eyeball
the output before every apply. Catches drift per-apply but not as it
occurs — the queue grows until someone trips over it.

**Fix:** a GitHub Action (or Cloud Build trigger) that, on every push to
`main`:

1. Runs `terraform init` + `terraform plan` for each stack under
   `infra/terraform/`.
2. Fails the build if any plan is non-empty for a stack the commit did not
   touch.
3. Posts the plan output as a check annotation so reviewers see the diff
   inline.

This forces live changes through the repo (or at least reconciled back
within one commit) and keeps the blast radius of any future client-add PR
narrow.

---

## 11. :yellow_circle: `analytics.tube.line_status_latest` upsert cutover pending

**Affected:** Flink analytics streaming job, Iceberg analytics table, the
`openvelox-api` tube endpoint.

Written by `pipelines/tfl/streaming/flink-jobs/analytics/aggregations.sql`
via plain `INSERT INTO` — an append log, not a snapshot. Currently ~8 000
rows across 18 distinct `line_id`s, growing by ~5 500 rows/day.

The Flink DDL at `aggregations.sql:71-82` already declares
`PRIMARY KEY (line_id) NOT ENFORCED` and `write.upsert.enabled = 'true'`,
but the target table was created before those properties were added and
`CREATE TABLE IF NOT EXISTS` will not retrofit them. The one-time
drop-and-recreate is the blocker.

**Workaround:** `apps/api/app/main.py` and `apps/api/app/tools/tfl.py`
dedup at query time using
`ROW_NUMBER() OVER (PARTITION BY line_id ORDER BY last_updated DESC)`.
Users see the correct 18 rows; the underlying table grows.

**Fix:** drop + recreate with upsert properties, reinsert the 18-row
snapshot, restart the Flink job.

1. Back up the deduped latest snapshot into `..._bak`.
2. `flink cancel` the `aggregations` job (bike-hourly and
   `kafka_line_status_latest` come down with it — same `STATEMENT SET`).
3. `DROP TABLE` + `CREATE TABLE` with
   `extra_properties['write.upsert.enabled'] = 'true'` and
   `extra_properties['identifier-field-ids'] = '1'` (ordinal of `line_id`).
4. `INSERT INTO … SELECT * FROM …_bak` then drop the bak.
5. `scripts/streaming-toggle.sh on` to restart the Flink job.

Full runbook in [DEPLOYMENT_ISSUES.md §41](DEPLOYMENT_ISSUES.md). Expected
impact: roughly two minutes of API `source=tfl_api` fallback on the tube
endpoint. The `OpenVeloxApiFallingBackToTflApi` `PrometheusRule`
(`infra/k8s/apps/base/api-monitoring.yaml`) has `for: 10m`, so this will
not page.

Keep the query-time dedup in place even after the cutover — cheap
defence-in-depth against any future regression.

---

## 12. :yellow_circle: End-user identity doesn't propagate Trino → Polaris

**Affected:** Trino catalogs, Polaris OPA policy, Iceberg object-level
authorisation.

The Trino coordinator authenticates to Polaris as a single service
principal (`trino`, role `trino_service`) configured via
`iceberg.rest-catalog.oauth2.*` on each catalog. OPA (§5.6 in
[GOVERNANCE](GOVERNANCE_IDENTITY_AND_ACCESS.md)) then decides what
`trino_service` can do — which is "full CRUD inside `raw`/`curated`/
`analytics`". Result: the Rego knows Trino-as-a-whole, not the human
behind the SQL.

**Impact:** every signed-in user has the same Iceberg-level permissions.
Row/column masking, per-user table bans, audit-by-user — all unavailable.

**Fix:** two-part, can land independently but both are needed for
per-user enforcement.

1. Trino access-controller (`file` or `oauth2`) that consumes the
   Keycloak token's `preferred_username` / realm roles and gates catalog,
   schema, and table access before the query ever hits Polaris. Config
   lives in `helm/trino/values-*.tmpl.yaml` → `accessControl.type`.
2. User-propagating Polaris credential — either OAuth2 token passthrough
   on the Iceberg REST connector (Trino 460+ / Polaris 1.3+) or a
   short-lived per-user Polaris principal minted by the coordinator. The
   Rego then receives `actor.principal = <human>` and can gate against
   Keycloak roles directly.

Until this lands, `polaris_viewer`-style read-only access for humans
still has to be enforced at the Trino layer, not at Polaris.
