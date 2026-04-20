# Environment setup

_Last reviewed: 2026-04-19_

OpenVelox supports multiple isolated environments from one codebase. Each
gets its own GCP project, GKE cluster, DNS prefix, and configuration.

## Configuration layers

Every environment touches five:

| Layer        | Path                                        | Purpose                                          |
| ------------ | ------------------------------------------- | ------------------------------------------------ |
| Terraform    | `infra/terraform/environments/{env}.tfvars` | GCP project, region, domain, cluster name        |
| K8s overlays | `infra/k8s/*/overlays/{env}/`               | Kustomize patches for domain, certs, SA bindings |
| Helm values  | `helm/*/values-{env}.yaml`                  | Chart-specific config (images, URLs, features)   |
| ArgoCD apps  | `argocd/envs/{env}/`                        | Applications with env-specific paths             |
| Vault        | `vault-init-{env}.json`                     | Recovery keys (not committed)                    |

## Creating a new environment

```bash
scripts/new-env.sh <env-name> <domain> <gcp-project-id>

# Example
scripts/new-env.sh staging example.com myco-lakehouse-staging
```

Scaffolds all config from the `prod` template with substituted values.
Review and customise before deploying.

### Manual post-scaffold

1. **Terraform tfvars** — fill `cloudflare_zone_id`, adjust region/zone.
2. **Helm values** — review image tags, resource limits, feature flags.
3. **K8s streaming patches** — update Artifact Registry paths and GCS bucket
   names.
4. **Vault secrets** — each environment needs its own secret values.

## DNS

| Environment | Hostname pattern             | Example                      |
| ----------- | ---------------------------- | ---------------------------- |
| `prod`      | `{service}.{domain}`         | `argocd.example.com`         |
| `dev`       | `dev.{service}.{domain}`     | `dev.argocd.example.com`     |
| `staging`   | `staging.{service}.{domain}` | `staging.argocd.example.com` |

The root domain (e.g. `example.com`) serves the Next.js frontend.

Services: `api`, `auth`, `argocd`, `orchestrator`, `query`, `streaming`,
`vault`, `catalog`, `authz`, `stream-processing`, `grafana`.

## Deploying

```bash
scripts/tf-apply.sh all           <env>  # infra
scripts/bootstrap.sh --env        <env>  # ArgoCD + git registration
scripts/vault-init.sh --env       <env>  # one-time
# Write secrets to Vault (see QUICKSTART.md)
scripts/tf-apply.sh dns           <env>
scripts/tf-apply.sh keycloak-realm <env>
```

## Destroying

```bash
scripts/destroy-all.sh --env <env>
```

Reverse dependency order. The GCP project is preserved (manual deletion,
for safety).

## Isolation

| Resource        | Isolation                                       |
| --------------- | ----------------------------------------------- |
| GCP project     | Full — separate billing, IAM, quotas            |
| GKE cluster     | Full — dedicated control plane and node pools   |
| Vault           | Instance — each cluster runs its own Vault      |
| Keycloak        | Realm — same or separate instance, unique realm |
| DNS             | Prefix — `{env}.{service}.{domain}`             |
| Iceberg/Polaris | Instance — each cluster runs its own catalog    |
| Terraform state | Workspace — separate state per environment      |
