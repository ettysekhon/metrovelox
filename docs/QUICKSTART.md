# Quickstart

_Last reviewed: 2026-04-19_

Clean-clone to running platform. ~45–60 min.

## Prerequisites

- GCP account with billing enabled.
- `gcloud`, `kubectl`, `terraform`, `helm`, `jq`.
- A domain you control (DNS).
- Cloudflare account (DNS + proxy).
- Docker (to build the custom Airflow image; Apple Silicon — see note below).
- A GitHub PAT with repo read (for Airflow GitDagBundle).

## 1. Configure

```bash
cp env.sh.template env.sh
```

| Variable           | Example            | Description                       |
| ------------------ | ------------------ | --------------------------------- |
| `PROJECT_ID`       | `openvelox-elt-01` | GCP project ID                    |
| `DOMAIN`           | `metrovelox.com`   | Root domain                       |
| `ENV`              | `prod`             | Environment name                  |
| `REGION`           | `europe-west2`     | GCP region                        |
| `ZONE`             | `europe-west2-a`   | GCP zone (for zonal clusters)     |
| `GKE_CLUSTER_NAME` | `openvelox`        | GKE cluster name                  |
| `GITHUB_REPO`      | `openvelox`        | GitHub repository name            |

```bash
source env.sh
```

> Zonal vs regional: `bootstrap.sh` uses `--zone $ZONE`. For a regional
> cluster, switch to `--region`.

## 2. Terraform — foundation, cluster, storage

```bash
scripts/tf-apply.sh foundation $ENV
scripts/tf-apply.sh cluster    $ENV
scripts/tf-apply.sh storage    $ENV
```

DNS and TLS are applied later — after the Gateway has an IP.

## 3. Build the custom Airflow image

Airflow needs `apache-airflow-providers-keycloak` for SSO:

```bash
source env.sh

# Apple Silicon: cross-compile for GKE (amd64 nodes)
docker build --platform linux/amd64 \
  -t "${REGION}-docker.pkg.dev/${PROJECT_ID}/openvelox/airflow:3.1.8-custom-v3" \
  docker/airflow/

docker push "${REGION}-docker.pkg.dev/${PROJECT_ID}/openvelox/airflow:3.1.8-custom-v3"
```

> `exec /usr/bin/dumb-init: exec format error` on GKE → wrong arch.
> Rebuild with `--platform linux/amd64`.

## 4. Bootstrap the platform

```bash
scripts/bootstrap.sh --env $ENV
```

Idempotent. Phases:

| Phase | Provisions                                                     |
| ----- | -------------------------------------------------------------- |
| 0     | GCP project, billing, Terraform state bucket                   |
| 1     | Terraform foundation + cluster + storage                       |
| 2     | Namespaces, ArgoCD, ArgoCD OIDC/RBAC overlay                   |
| 3     | PostgreSQL, secrets, Keycloak (env overlay)                    |
| 4     | Vault (GCP KMS auto-unseal on prod)                            |
| 5     | Polaris                                                        |
| 6     | Spark Operator, Airflow (`--no-hooks`)                         |
| 7     | Trino, cert-manager                                            |
| 8     | Strimzi Kafka (operator + `openvelox` cluster + topics)        |
| 9     | Flink Operator                                                 |
| 10    | Gateway + HTTPRoutes (env overlay)                             |

## 5. Initialise Vault

```bash
scripts/vault-init.sh --env $ENV
```

Enables KV v2 + Kubernetes auth, uploads policies, creates roles, seeds
placeholders. Recovery keys land in `vault-init-$ENV.json` —
**store securely; never commit**.

Write real secrets:

```bash
kubectl port-forward -n security svc/vault 8200:8200 &
export VAULT_ADDR=http://localhost:8200
export VAULT_TOKEN=$(jq -r .root_token vault-init-$ENV.json)

vault kv put secret/platform/tfl-api-key value=<YOUR_TFL_KEY>
vault kv put secret/platform/cloudflare  api-token=<YOUR_CF_TOKEN>
```

## 6. TLS + DNS

Once the Gateway has an external IP:

```bash
kubectl get gateway openvelox-gateway -n platform -o jsonpath='{.status.addresses[0].value}'

scripts/tf-apply.sh tls $ENV
scripts/tf-apply.sh dns $ENV
```

Verify the certificate (5–15 min for DNS-01):

```bash
gcloud certificate-manager certificates describe <domain>-wildcard --project=$PROJECT_ID
```

> Cloudflare SSL: set to **Full (strict)**. A `525` means the edge-to-origin
> handshake is failing — check the certificate map entry and the Gateway
> annotation.

## 7. Keycloak realm + OIDC clients

```bash
# If Cloudflare 525 persists, port-forward the admin API
kubectl port-forward -n platform svc/keycloak 8080:8080 &
export KEYCLOAK_TERRAFORM_URL=http://127.0.0.1:8080

scripts/tf-apply.sh keycloak-realm $ENV
```

## 8. Wire secrets + restart

```bash
GITHUB_PAT=<your-github-pat> scripts/post-deploy.sh $ENV
```

Reads Keycloak client secrets from Terraform, writes Vault + K8s Secrets,
restarts Airflow / ArgoCD / Grafana.

## 9. Airflow Keycloak RBAC

```bash
bash scripts/airflow-keycloak-rbac.sh
```

Wraps two steps that must both run on a fresh install:

1. `airflow keycloak-auth-manager create-all` inside the API-server pod —
   creates authorisation **scopes / resources / permissions** on the
   `airflow` Keycloak client (uses the in-cluster URL
   `http://keycloak.platform.svc.cluster.local:8080`).
2. `scripts/airflow-keycloak-authz-attach.sh` — creates the
   `Allow-Viewer` / `-User` / `-Op` / `-Admin` / `-SuperAdmin` role policies
   and attaches them to the permissions. Without this Airflow 403s on
   `/api/v2/*` even with a valid SSO session (singleton mode leaves
   permissions unpoliced).

The realm roles and groups behind those policies are created by
`scripts/tf-apply.sh keycloak-realm $ENV` in step 7.

### Assigning a user (optional)

```bash
# Port-forward Keycloak if public URL is not reachable
kubectl port-forward -n platform svc/keycloak 8080:8080 &
export KEYCLOAK_ADMIN_URL=http://127.0.0.1:8080

# Terraform-managed group (preferred)
bash scripts/keycloak-assign-user.sh add-group <username> platform-admins

# Or map a single realm role directly
bash scripts/keycloak-assign-user.sh add-realm-role <username> Admin
```

After a role/group change, log out of Airflow and Keycloak (or clear cookies
for `auth.$DOMAIN` and `orchestrator.$DOMAIN`) so a fresh access token
carries the new claims.

## 10. Verify

```bash
kubectl get pods -A | grep -v kube-system
kubectl get applications -n argocd
kubectl get externalsecrets -A

open https://auth.${DOMAIN}              # Keycloak admin
open https://orchestrator.${DOMAIN}      # Airflow (SSO)
open https://argocd.${DOMAIN}            # ArgoCD (SSO)
open https://grafana.${DOMAIN}           # Grafana
open https://query.${DOMAIN}             # Trino (native Keycloak OAuth2)
open https://catalog-console.${DOMAIN}   # Polaris Console (SSO)
open https://kafka.${DOMAIN}             # kafka-ui (native Keycloak OIDC + PKCE)
open https://stream-processing.${DOMAIN} # Flink Dashboard (oauth2-proxy)
```

> Trino CLI: `trino --server https://query.${DOMAIN} --external-authentication`
> — pops the browser for Keycloak, caches the token under `~/.trino`.

## Destroy

```bash
scripts/destroy-all.sh $ENV
```

Reverse dependency order: Terraform stacks, Helm releases, PVCs, namespaces,
GKE cluster, state bucket.

## Troubleshooting

Known gaps and workarounds: [ROADMAP.md](ROADMAP.md). Quick fixes:

| Symptom                              | Likely cause                          | Fix                                                    |
| ------------------------------------ | ------------------------------------- | ------------------------------------------------------ |
| Vault `CrashLoopBackOff`             | Missing `cloudkms.viewer` role        | Re-apply `foundation` Terraform                        |
| Airflow `exec format error`          | Wrong Docker architecture             | Rebuild with `--platform linux/amd64`                  |
| Cloudflare `525`                     | Certificate not ACTIVE yet            | Wait for DNS-01, check cert status                     |
| Keycloak redirects to `example.com`  | Base overlay applied instead of prod  | `kubectl apply -k .../keycloak/overlays/prod`          |
| Airflow `redirect_uri` rejected      | `http://` instead of `https://`       | Check `enable_proxy_fix` + `BASE_URL` in Helm values   |

## Next

- Pipelines — [ARCHITECTURE.md](ARCHITECTURE.md)
- Identity — [GOVERNANCE_IDENTITY_AND_ACCESS.md](GOVERNANCE_IDENTITY_AND_ACCESS.md)
- New environment — `scripts/new-env.sh staging $DOMAIN $NEW_PROJECT_ID`
- Catalog — [CATALOG.md](CATALOG.md)
