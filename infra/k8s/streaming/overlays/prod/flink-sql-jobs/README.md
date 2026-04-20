# Flink SQL Jobs (prod)

Declarative codification of the `raw -> curated -> analytics` TfL streaming
pipeline.  Replaces the ad-hoc `kubectl exec <flink-session-pod> -- sql-client.sh`
flow that was used during the initial soak (see commit history around
`Flink prod raw -> curated -> analytics 24h soak`).

## Layout

```
infra/k8s/streaming/overlays/prod/flink-sql-jobs/
├── kustomization.yaml        # ConfigMap generator + 3 Job resources
├── submit-raw.yaml           # Job: submits pipelines/.../raw/ingest_all.sql
├── submit-curated.yaml       # Job: submits pipelines/.../curated/transform.sql
├── submit-analytics.yaml     # Job: submits pipelines/.../analytics/aggregations.sql
└── README.md
```

SQL source of truth stays in `pipelines/tfl/streaming/flink-jobs/`; the
`configMapGenerator` in `kustomization.yaml` references those files
directly. Cross-tree references require
`kustomize.buildOptions: --load-restrictor=LoadRestrictionsNone` in
`infra/k8s/platform/argocd/base/argocd-config.yaml` — already set.

## Flow

1. Flink session `FlinkDeployment` comes up (wave 0, default sync).
2. Argo CD's `Sync` hook runs `flink-submit-raw` (wave 10) -> curated
   (wave 11) -> analytics (wave 12).
3. Each Job:
   - Copies the base Flink conf and overlays `rest.address` /
     `jobmanager.rpc.address` so `sql-client.sh` targets the session
     cluster instead of bootstrapping an embedded JM.
   - Queries `/jobs/overview` for a Flink job with `pipeline.name` ==
     the layer's pipeline name; if it's already `RUNNING`, exits 0
     (idempotent no-op, the common case on resync).
   - Otherwise renders `${KAFKA_*}` placeholders via `envsubst` and
     submits the SQL.  `sql-client -f` returns as soon as the
     StatementSet is accepted; streaming execution continues detached.
4. `hook-delete-policy: BeforeHookCreation` deletes the previous Job
   object on the next sync so the manifest can be re-applied (Jobs are
   immutable).

## One-time cutover from the manual soak submissions

The initial 24h soak jobs were submitted via `kubectl exec sql-client.sh`
and ran with Flink's default auto-generated job names (e.g.
`insert-into_default_catalog...`).  The idempotency guard in these
submit Jobs keys off `pipeline.name`, so the guard will NOT recognise
the pre-existing jobs and WILL submit duplicates if Argo syncs this
overlay while the old jobs are still running.

Before enabling the Argo sync on this sub-app for the first time:

```bash
# 1. List the currently-running soak jobs.
kubectl exec -n streaming deploy/flink-session -- \
  curl -fsS http://localhost:8081/jobs/overview \
  | jq '.jobs[] | {id: .jid, name: .name, state: .state}'

# 2. Cancel each of the three (raw / curated / analytics).
for jid in <raw-jid> <curated-jid> <analytics-jid>; do
  kubectl exec -n streaming deploy/flink-session -- \
    curl -fsS -XPATCH "http://localhost:8081/jobs/${jid}?mode=cancel"
done

# 3. Re-sync the streaming Argo app; the three submit Jobs fire and
#    bring the pipelines back under `pipeline.name = tfl-<layer>-*`.
```

Subsequent edits use the guard and self-deduplicate.

## Editing a pipeline

1. Edit the SQL under `pipelines/tfl/streaming/flink-jobs/<layer>/`.
2. Commit + push. Argo CD will re-run only the affected submit Job at
   next sync (the idempotency guard skips layers whose pipeline name is
   still RUNNING — for real changes, manually cancel the old Flink job
   first via the Flink UI or `curl -XPATCH .../jobs/<jid>`).

## Why not `FlinkSessionJob`?

The Flink Kubernetes Operator's `FlinkSessionJob` CRD submits a packaged
JAR to a session cluster. Running pure SQL through it requires the
`flink-sql-runner` example jar (not published to Maven Central), which
would need to be built and pushed to Artifact Registry in a separate
pipeline.  The Job-based submitter above is simpler, uses the same
`sql-client.sh` tooling operators already know, and is trivial to swap
for `FlinkSessionJob` once a runner jar is packaged.

## Manual trigger (dev loop)

```bash
kubectl -n streaming delete job flink-submit-curated --ignore-not-found
kubectl -n argocd annotate application streaming \
  argocd.argoproj.io/refresh=hard --overwrite
```

Or apply the kustomize build directly:

```bash
kustomize build --load-restrictor=LoadRestrictionsNone \
  infra/k8s/streaming/overlays/prod/flink-sql-jobs \
  | kubectl apply -f -
```
