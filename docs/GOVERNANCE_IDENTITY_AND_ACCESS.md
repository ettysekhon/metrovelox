# Identity, access, and secrets

_Last reviewed: 2026-04-19_

How people and workloads authenticate, how authorisation layers, and where
governance sits next to the technical controls. Infrastructure layout is in
[ARCHITECTURE.md](ARCHITECTURE.md).

---

## 1. Identity provider

**Keycloak** (one realm per environment, e.g. `openvelox`) is the OIDC/SSO
source for humans. Every app trusts Keycloak-issued tokens (or a session
established after the OIDC redirect flow).

| Surface                                | How users sign in                                                                                                                                                          |
| -------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ArgoCD, Grafana, Airflow UI            | Keycloak OAuth2 / OIDC (per-app client)                                                                                                                                    |
| Trino UI / CLI / JDBC                  | Native Keycloak OAuth2 — coordinator validates JWTs against JWKS                                                                                                           |
| Polaris Console                        | Keycloak OIDC (public PKCE client); token sent to Polaris, validated against realm JWKS. Console identifies the user from the nested `polaris.principal_name` claim (§5.5) |
| Flink UI                               | oauth2-proxy in front, Keycloak upstream. Gated by the `streaming-viewer` realm role (§6.4)                                                                                |
| kafka-ui (kafbat) at `kafka.${DOMAIN}` | Native Keycloak OIDC + PKCE. UI actions gated by the `kafka_ui_roles` claim (§6)                                                                                           |
| Keycloak admin                         | Direct login                                                                                                                                                               |
| OpenVelox app/API                      | OIDC or API keys, depending on caller                                                                                                                                      |

Realm roles (e.g. `airflow-admin`, `grafana-editor`) are assigned to users
or groups in Keycloak; each downstream app maps them onto its own RBAC
model.

---

## 2. Secrets and machine identity

**Vault** (`security` namespace, KV v2 under `secret/`) holds structured
secrets. **External Secrets Operator** syncs selected paths into Kubernetes
`Secret`s so pods never mount the Vault token for static config.

**Workload Identity** binds K8s service accounts to GCP SAs where needed
(e.g. Vault's `vault-sa` for KMS auto-unseal).

**Kubernetes RBAC** controls platform access — which namespaces and resources
a pod can touch. Separate from in-app user entitlements.

---

## 3. Airflow

**Auth.** Airflow 3 uses `KeycloakAuthManager` from
`apache-airflow-providers-keycloak` (configured in `helm/airflow/values-{env}.yaml`
via `AIRFLOW__CORE__AUTH_MANAGER` and `AIRFLOW__KEYCLOAK_AUTH_MANAGER__*`).
Browser SSO and `/auth/token` use the provider directly — no custom FAB
OAuth code.

**One-time post-deploy:** `scripts/airflow-keycloak-rbac.sh`. The wrapper runs

1. `airflow keycloak-auth-manager create-all` — seeds scopes, resources, and
   permissions on the `airflow` Keycloak client.
2. `scripts/airflow-keycloak-authz-attach.sh` (invokes
   `scripts/airflow_keycloak_authz_attach.py` inside the API-server pod) —
   creates `Allow-Viewer/-User/-Op/-Admin/-SuperAdmin` role policies and
   attaches them to the permissions.

Without step 2, Airflow 403s on `/api/v2/*` even with a valid SSO session:
`create-all` in singleton/no-`--teams` mode leaves permissions without any
policy attached, so every check fails closed.

**Realm roles / groups** are defined in `infra/terraform/keycloak-realm/`.
Legacy labels (`airflow-admin` / `-user` / `-op` / `-viewer`) stay for
continuity; the provider binds the UMA names `Admin`, `Viewer`, `User`, `Op`,
`SuperAdmin`. Group → role mapping:

| Group             | Roles                 |
| ----------------- | --------------------- |
| `platform-admins` | `Admin`, `SuperAdmin` |
| `developers`      | `User`, `Viewer`      |
| `operators`       | `Op`, `Viewer`        |
| `viewers`         | `Viewer`              |

Use `scripts/keycloak-assign-user.sh add-group <user> <group>` (or
`add-realm-role` for a single role), then have the user log out of Airflow
**and** Keycloak so the next access token carries the new claims.

**Execution identity.** DAG tasks run under Airflow's execution model
(KubernetesExecutor spawns per-task pods). Those pods use the service
accounts and secrets configured for Airflow — not the end-user's personal
credentials. Which user can _trigger_ a sensitive DAG is provider-managed
through Airflow RBAC, not through per-user K8s SAs.

**Automation.** Use the Airflow `/auth/token` flow from the Keycloak
provider docs. No custom JWKS shim in the image.

---

## 4. Trino

**Auth.** The coordinator runs native OAuth2
(`http-server.authentication.type=oauth2`,
`web-ui.authentication.type=oauth2` in `helm/trino/values-gke.yaml`). JWTs are
validated directly against the realm JWKS — no oauth2-proxy. The browser UI
at `https://query.${DOMAIN}` redirects unauthenticated users through the
Keycloak authorisation code flow using the `trino` confidential client
(`infra/terraform/keycloak-realm/main.tf`). The `preferred_username` claim
becomes the Trino principal.

**CLI.** `trino --server https://query.${DOMAIN} --external-authentication`
pops the browser, caches the token at `~/.trino`.

**JDBC / headless.** Either the
`io.trino.client.auth.external.ExternalAuthentication` provider, or a
pre-obtained client-credentials token — the `trino` Keycloak client has
`service_accounts_enabled = true` for Airflow DAGs that need a programmatic
token.

**Secrets.** The `trino` client secret lives in Vault at
`secret/platform/keycloak` key `trino-client-secret`, synced into the `data`
namespace as `trino-oauth-secret` by
`infra/k8s/security/external-secrets.yaml`, loaded via
`TRINO_OAUTH_CLIENT_SECRET`.

**Token → data authorisation.** The token proves _who_ is querying. Iceberg
read/write is gated by the `iceberg.rest-catalog.oauth2.*` properties on
each Trino catalog: the Trino coordinator authenticates to Polaris as the
`trino` service principal (`trino_service` role), and Polaris forwards
every authorizable operation to OPA (§5.6). End-user-level authorisation
on Iceberg objects is not wired yet — Trino-side `access-control` and a
user-propagating Polaris credential are tracked in
[ROADMAP.md](ROADMAP.md).

---

## 5. Polaris (Iceberg catalog) and OPA

Polaris exposes the Iceberg REST catalog API (Spark, Flink, Trino connect
here) plus a Management API used by the Polaris Console and admin CLIs.

### 5.1 Authentication — mixed (internal + Keycloak OIDC)

Polaris 1.3 runs in `polaris.authentication.type=mixed`
(`helm/polaris/values-gke.tmpl.yaml` `advancedConfig`). It tries the internal
token path first and falls back to Keycloak OIDC:

| Caller                                           | Path                                                                                     |
| ------------------------------------------------ | ---------------------------------------------------------------------------------------- |
| Trino coordinator (service principal)            | `client_credentials` → `POST /api/catalog/v1/oauth/tokens` → Polaris-signed opaque token |
| Bootstrap / admin scripts with Vault-seeded root | Same as Trino, `client_id=root`                                                          |
| Polaris Console (browser)                        | Keycloak PKCE against `polaris-console` → JWT validated by Polaris via JWKS              |
| Direct `curl` with a Keycloak token              | Same JWT validation path as the console                                                  |

Quarkus OIDC tenant on Polaris:

- `quarkus.oidc.auth-server-url = https://auth.${DOMAIN}/realms/openvelox`
- `quarkus.oidc.client-id = polaris-server` (bearer-only; the `aud` Polaris checks for)
- `quarkus.oidc.application-type = service` — resource-server only; never interactive

### 5.2 Keycloak clients, roles, claims

Defined in `infra/terraform/keycloak-realm/main.tf`:

- `polaris-console` — public PKCE client for the browser console at
  `catalog-console.${DOMAIN}`.
- `polaris-server` — bearer-only, exists only to be the audience target;
  no flows enabled.
- Realm roles `polaris-admin` and `polaris-viewer`, bound to
  `platform-admins` / `viewers`.
- Four protocol mappers on `polaris-console` project the claims Polaris
  needs:
  - `audience-polaris-server` → injects `polaris-server` into `aud`
  - `polaris-principal-id` → attr `polaris_principal_id` → `polaris.principal_id` (long)
  - `polaris-principal-name` → `username` → `polaris.principal_name`
  - `polaris-roles` → realm roles → `polaris.roles` (multivalued)

The realm's `unmanagedAttributePolicy` must be `ADMIN_EDIT` (or laxer) for
`polaris_principal_id` to persist; the bootstrap script enforces this
idempotently.

### 5.3 Principal-id sync — why it's not just Terraform

Polaris auto-assigns the numeric `id` on create and does not expose it via
the public Management API. Polaris's `PrincipalMapper` needs the JWT's
`polaris.principal_id` **and** `polaris.principal_name` to match a row in
`polaris_schema.entities` (type_code = 2 = PRINCIPAL).

Closed in `scripts/polaris-bootstrap-human-principals.sh`:

1. Idempotent `POST /api/management/v1/principals` + `PUT .../principal-roles`.
2. `SELECT id FROM polaris_schema.entities WHERE realm_id='POLARIS' AND name='<user>' AND type_code=2;` — direct Postgres read.
3. `kcadm.sh update users/<id> -s 'attributes.polaris_principal_id=[<id>]'` inside the Keycloak pod.
4. `post-deploy.sh` invokes the script right after the Trino SA bootstrap
   so greenfield deploys land with the link in place.

Adding another human is one line in the `HUMAN_PRINCIPALS` array plus a
re-run.

### 5.4 Role mapping — `polaris-admin` → `service_admin`

Polaris 1.3's service-level privileges (`LIST_CATALOGS`, `PRINCIPAL_LIST`,
`CATALOG_CREATE`, …) are only carried by the built-in `service_admin`
principal-role; there's no management API to grant them to an arbitrary
role. The `principal-roles-mapper` rewrites Keycloak realm roles onto the
built-in ones:

```properties
polaris.oidc.principal-roles-mapper.filter             = polaris-.*
polaris.oidc.principal-roles-mapper.mappings[0].regex       = polaris-admin
polaris.oidc.principal-roles-mapper.mappings[0].replacement = PRINCIPAL_ROLE:service_admin
polaris.oidc.principal-roles-mapper.mappings[1].regex       = polaris-viewer
polaris.oidc.principal-roles-mapper.mappings[1].replacement = PRINCIPAL_ROLE:polaris_viewer
```

`polaris_viewer` resolves at the OPA layer (§5.6) — its allow branch in the
Rego grants `all_read_ops` across the three OpenVelox warehouses. Polaris
itself has no service-level grants on the role; catalog-level read is
delegated entirely to the Rego.

### 5.5 Polaris Console — client-side principal resolution

The Console is vendored from `apache/polaris-tools` as a submodule pinned
to an upstream commit under `apps/polaris-console/upstream/console`, built
by `scripts/build-polaris-console.sh`, pushed to Artifact Registry.

Upstream decodes the JWT's `sub` claim and calls
`GET /api/management/v1/principals/<sub>`. With a Keycloak-issued token
`sub` is the Keycloak user UUID — the lookup 404s and the header falls back
to the literal `User`.

Fixed without forking the submodule: `apps/polaris-console/overlay/` stages
a small set of files on top of the pinned upstream tree immediately before
`docker buildx build` and reverts via the cleanup trap, so the submodule
working tree stays pristine. The overlay adjusts `src/lib/utils.ts`
`getPrincipalNameFromToken` to prefer the claims we emit, in order:

1. `polaris.principal_name` — nested custom claim (§5.2).
2. `preferred_username`.
3. `principal_name` / `principal`.
4. `sub` — last-resort, so Polaris-internal `client_credentials` tokens
   (where `sub` already equals the principal name) keep working.
5. `name`.

Add further overlays by mirroring the upstream path under `overlay/` and
listing them in `apps/polaris-console/overlay/README.md`. Drop them when
upstream converges and the submodule commit is bumped.

### 5.6 OPA — external PDP (enforcing)

Polaris 1.3+ delegates every `PolarisAuthorizableOperation` to an external
HTTP PDP. We run Open Policy Agent in-cluster and point Polaris at it.
Keycloak still says _who_ the principal is; OPA decides _what_ they can do
on Iceberg metadata.

**Runtime.** 2-replica Deployment + Service + PodDisruptionBudget in the
`data` namespace (`infra/k8s/data/opa/opa.yaml`,
`opa:0.70.0-static`, port 8181, spot-pool with topology spread). Policy is
a `polaris-opa-policy` ConfigMap generated by kustomize from
`infra/k8s/data/opa/policies/polaris.rego`.

**Polaris wiring.** `helm/polaris/values-gke.tmpl.yaml`:

```yaml
polaris.authorization.type: "opa"
polaris.authorization.opa.policy-uri: "http://opa.data.svc.cluster.local:8181/v1/data/polaris/authz"
polaris.authorization.opa.http.timeout: "PT2S"
```

Polaris queries the **package** (`.../polaris/authz`) and reads the `allow`
boolean from the returned document. The rule-level URI (`.../authz/allow`)
returns a plain boolean Polaris can't parse, and the call fails closed.

**Policy shape.** Default-deny, package `polaris.authz`:

- Operation sets mirror `PolarisAuthorizableOperation`:
  `catalog_read_ops`, `namespace_read_ops`, `table_read_ops`, `view_read_ops`
  and their `_write_` counterparts, plus `table_metadata_write_ops` for the
  fine-grained Iceberg committer ops (`ADD_TABLE_SNAPSHOT`,
  `SET_TABLE_SNAPSHOT_REF`, `SET_TABLE_PROPERTIES`, …) that Flink's
  `IcebergFilesCommitter` emits on every checkpoint.
- Allow branches:
  - `service_admin` — full `all_data_ops` (used by `root` and by humans
    mapped from Keycloak `polaris-admin`).
  - `trino_service` — `catalog_read_ops | namespace_* | table_* |
table_metadata_write_ops | view_*`, gated by
    `target_inside_openvelox_warehouses` which walks the target-parent
    chain and rejects anything outside `{raw, curated, analytics}`.
  - `polaris_viewer` — `all_read_ops`, same warehouse gate.
- Privilege-management ops (`ADD_*_GRANT_TO_*`, `CREATE_PRINCIPAL`,
  `CREATE_POLICY`, …) are deliberately in no allow-list, so they fall
  through to `default allow := false` and stay on Polaris-native RBAC,
  per the upstream "Important Policy Considerations" guidance.

**CI.** `make opa-test` (unit tests in `polaris_test.rego`) and
`make opa-lint` (strict-lint) both block merges — `.github/workflows/ci.yaml`
job `opa-test`. `scripts/opa-test.sh` pulls a pinned `opa` binary into
`tools/opa/` if one isn't on the runner.

**Bootstrap break-glass.** `scripts/polaris-bootstrap-*.sh` needs
privilege-management ops that OPA denies by design. To add a new principal
after enforcement is on: comment the three `polaris.authorization.*` lines
in `helm/polaris/values-gke.tmpl.yaml`, re-render, let ArgoCD roll Polaris,
run the bootstrap script, restore the lines, re-render, re-roll. Grants
installed by the script persist in the metastore and take effect
immediately after OPA is re-enabled.

**Rollback.** Same mechanism — comment the three lines. Polaris reverts to
native RBAC, which is still intact (the Rego is additive; it never mutated
Polaris grants).

**Gateway.** `authz.metrovelox.com` is reserved in the prod Gateway overlay
but not exposed — all Polaris→OPA traffic stays in-cluster on
`opa.data.svc.cluster.local`, which is the correct default for a PDP.

---

## 6. Strimzi Kafka (OAUTHBEARER + KeycloakAuthorizer)

Strimzi-managed Apache Kafka. The operator speaks SASL OAUTHBEARER natively
via `io.strimzi:kafka-oauth-*`; `KeycloakAuthorizer` resolves every
principal / operation / topic tuple against Keycloak Authorization Services
(UMA). Redpanda has been fully retired.

### 6.1 Cluster layout

- **Operator:** `strimzi-kafka-operator` Helm chart v0.51.0, cluster-scoped,
  in `kafka` (`argocd/envs/prod/strimzi-operator.tmpl.yaml`, values in
  `helm/strimzi-operator/values-gke.yaml`).
- **Cluster:** one `Kafka` CR `openvelox`, one `KafkaNodePool` `mixed`
  (controller + broker, KRaft, 1 replica on the spot pool) —
  `infra/k8s/kafka/base/`.
- **Topics:** `KafkaTopic` CRs under `infra/k8s/kafka/base/topics/`.
  `auto.create.topics.enable=false`.
- **Internal bootstrap:**
  `openvelox-kafka-bootstrap.kafka.svc.cluster.local:9092` (plain, SASL
  OAUTHBEARER).
- **Schema registry:** Apicurio Registry 3 in `kafka`, with its own
  `apicurio` Postgres DB. OIDC auth is off this cycle — see
  [ROADMAP §8](ROADMAP.md).

### 6.2 Keycloak clients and roles

From `infra/terraform/keycloak-realm/main.tf`:

- `kafka-broker` — confidential, service-accounts on, **authorisation on**
  (UMA). Owns the Kafka Authorization Services graph:
  - Scopes: `Describe`, `Read`, `Write`, `Alter`, `Delete`, `Create`,
    `DescribeConfigs`, `AlterConfigs`, `ClusterAction`, `IdempotentWrite`.
  - Resources: `kafka-cluster:openvelox`, `Cluster:*`, `Topic:*`,
    `Topic:tfl.*`, `Group:*`.
  - Role policies: one per `kafka-admin` / `-producer` / `-consumer` /
    `-viewer`.
  - Permissions bind policies → resources → scopes (e.g. `kafka-admin` gets
    every scope on every resource; `kafka-producer` gets `Write` + `Describe`
    on `Topic:tfl.*`; `kafka-consumer` gets `Read` + `Describe` on `Topic:*`
    and `Group:*`; `kafka-viewer` gets `Describe` only).
- `kafka-ui` — public PKCE client. Adds `kafka_ui_roles` (realm-roles mapper)
  and a `kafka-broker` audience mapper so the SASL side validates its tokens.
- `kafka-flink` — confidential SA client; SA user has
  `kafka-producer` + `kafka-consumer`. Tokens carry `aud=kafka-broker`.
- `kafka-tfl-producer` — confidential SA client, `kafka-producer` only. Used
  by the `tfl-producer-strimzi` CronJob so the batch producer can't
  consume or admin.

Role → group map:

| Role               | `platform-admins` | `developers` | `operators` | `viewers` |
| ------------------ | :---------------: | :----------: | :---------: | :-------: |
| `kafka-admin`      |         ✓         |              |             |           |
| `kafka-producer`   |         ✓         |      ✓       |      ✓      |           |
| `kafka-consumer`   |         ✓         |      ✓       |      ✓      |     ✓     |
| `kafka-viewer`     |         ✓         |      ✓       |      ✓      |     ✓     |
| `streaming-viewer` |         ✓         |      ✓       |      ✓      |     ✓     |

### 6.3 Broker enforcement (Strimzi `Kafka` CR)

`infra/k8s/kafka/base/kafka.tmpl.yaml`:

- Listener auth `type: oauth` with `validIssuerUri` and `jwksEndpointUri`
  pointing at in-cluster Keycloak — JWT validation never leaves the cluster
  on the hot path. `checkAudience: true` forces `aud=kafka-broker`.
- `clientId/clientSecret` reference `kafka-broker-oauth` (ESO-synced from
  Vault `secret/platform/keycloak:kafka-broker-client-secret`). Strimzi
  projects these into the broker env so `KeycloakAuthorizer` can fetch UMA
  grants.
- `authorization: type: keycloak`, `clientId: kafka-broker`,
  `delegateToKafkaAcls: false`, `superUsers: [service-account-kafka-flink]`
  as break-glass while the UMA graph is still young.
- `maxSecondsWithoutReauthentication: 3600` so role revocations land within
  an hour without killing long-running producers.

### 6.4 Client wiring

- **Flink.** `FlinkDeployment` (and the standalone fallback) has two
  init-containers: the first copies Flink's `/opt/flink/lib/` into an
  `emptyDir` overlay; the second downloads
  `kafka-oauth-client-0.16.1.jar`,
  `kafka-oauth-common-0.16.1.jar`, and `gson-2.10.1.jar` into that overlay.
  The main container mounts it back over `/opt/flink/lib/` so the Strimzi
  login-callback is on the system classpath. Pod env exposes
  `KAFKA_BOOTSTRAP`, `KAFKA_TOKEN_ENDPOINT`, `KAFKA_FLINK_CLIENT_ID`,
  `KAFKA_FLINK_OAUTH_CLIENT_SECRET`; Flink SQL references them via
  `${…}` interpolation.
- **TfL producer.** `tfl-producer-strimzi` CronJob runs a
  confluent-kafka-python producer
  (`pipelines/tfl/streaming/producer/tfl_producer_strimzi.py`) —
  `kafka-python` does not speak OAUTHBEARER. Client-credentials against
  Keycloak are refreshed in `oauth_cb` each time librdkafka asks for a
  fresh token.
- **kafka-ui (kafbat).** Browser OIDC (public PKCE); kafka-ui proxies
  authenticated actions to the broker using its own `kafka-ui` client's
  client-credentials SASL OAUTHBEARER session. RBAC is native: `kafka-admin`
  → `admins`, `kafka-producer` → `producer`, `kafka-viewer` → `readonly`.
- **oauth2-proxy (Flink UI).** `--allowed-role=streaming-viewer` so
  authenticated users with e.g. Airflow or Grafana access can't reach the
  Flink JobManager UI.

### 6.5 Secrets

Keycloak → Vault → K8s Secret → pod env via the standard ESO pattern
(`infra/k8s/security/external-secrets.yaml`). `scripts/post-deploy.sh`
pulls `kafka_broker`, `kafka_ui`, `kafka_flink`, `kafka_tfl_producer` from
the `keycloak-realm` Terraform output and writes them to
`secret/platform/keycloak` after every realm apply.

---

## 7. End-to-end

```text
Human  ──OIDC──▶ Keycloak ──tokens/roles──▶ ArgoCD / Grafana / Airflow / oauth2-proxy UIs
                                      │
                                      └── role mapping per app (each app's RBAC)

Vault KV ──ESO──▶ K8s Secrets ──▶ Pods (batch, streaming, platform)

Spark / Flink / Trino ──▶ Polaris (REST) ──[future]──▶ OPA Rego for catalog authz
                              ▲
                              └── IdP tokens (Keycloak) when integrated
```

---

## 8. Governance vs technical controls

Governance = data ownership, classification, retention, quality, access
review, auditability. Usually lives in process and org policy, not YAML.

This document covers technical identity, access, and secrets. Governance
consumes those controls and adds intent:

| Concern                          | Organisational layer                     | Platform hooks                                                                         |
| -------------------------------- | ---------------------------------------- | -------------------------------------------------------------------------------------- |
| Dataset / pipeline access        | Data owners, stewardship, access reviews | Keycloak groups → roles; Airflow DAG perms; future OPA/Rego on catalog operations      |
| Separation of duties             | Prod changes vs data access              | ArgoCD/Git PR review; distinct Keycloak roles for ops vs analysts                      |
| Auditability                     | Who did what, when                       | Vault audit devices; K8s/API audit logs; Airflow run history; Iceberg snapshot lineage |
| Consistency of naming and layers | Standards for schemas, zones             | [CATALOG.md](CATALOG.md) conventions; catalog + Git for pipelines                      |

OPA is a policy engine — you still need agreed Rego rules and ownership of
who may change them (that's governance). Identity alone does not replace
classification, retention, or legal basis; it only enforces what's encoded.

For deeper data-governance programmes (stewardship workflows, business
glossaries, enterprise catalogue tools), extend this repo with org-specific
docs or link to your enterprise standard.

---

## 9. Related

- [ROADMAP.md](ROADMAP.md) — outstanding platform gaps.
- [QUICKSTART.md](QUICKSTART.md) — bootstrap, Vault init, DNS.
- [ARCHITECTURE.md](ARCHITECTURE.md) — components and data flow.
- [CATALOG.md](CATALOG.md) — naming and semantic layers.
