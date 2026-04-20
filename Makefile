# OpenVelox Makefile — barebones platform targets only

.PHONY: help check-env bootstrap deploy-infra status destroy-all opa-test opa-lint

help:
	@echo "OpenVelox Platform"
	@echo ""
	@echo "  make bootstrap     - Run full bootstrap (all phases)"
	@echo "  make deploy-infra  - Terraform only (foundation → cluster → storage)"
	@echo "  make status        - Cluster & pod status"
	@echo "  make destroy-all   - Tear down everything (interactive confirm)"
	@echo ""
	@echo "  make opa-test      - Run Polaris OPA policy unit tests"
	@echo "  make opa-lint      - Strict-lint the Polaris OPA Rego bundle"

# ─────────────────────────────────────────────────────────────────────────────
# PREREQS
# ─────────────────────────────────────────────────────────────────────────────

check-env:
ifndef PROJECT_ID
	$(error PROJECT_ID is not set. Run: source env.sh)
endif

# ─────────────────────────────────────────────────────────────────────────────
# BOOTSTRAP (runs scripts/bootstrap.sh — all phases, idempotent)
# ─────────────────────────────────────────────────────────────────────────────

bootstrap: check-env
	./scripts/bootstrap.sh

# ─────────────────────────────────────────────────────────────────────────────
# TERRAFORM ONLY
# ─────────────────────────────────────────────────────────────────────────────

TF_BUCKET = tf-state-$(PROJECT_ID)

deploy-infra: check-env
	@echo "Deploying infrastructure (foundation → cluster → storage)..."
	cd infra/terraform/foundation && \
		terraform init -backend-config="bucket=$(TF_BUCKET)" -backend-config="prefix=foundation" && \
		terraform apply -auto-approve -var="project_id=$(PROJECT_ID)"
	cd infra/terraform/cluster && \
		terraform init -backend-config="bucket=$(TF_BUCKET)" -backend-config="prefix=cluster" && \
		terraform apply -auto-approve -var="project_id=$(PROJECT_ID)"
	cd infra/terraform/storage && \
		terraform init -backend-config="bucket=$(TF_BUCKET)" -backend-config="prefix=storage" && \
		terraform apply -auto-approve -var="project_id=$(PROJECT_ID)"

# ─────────────────────────────────────────────────────────────────────────────
# STATUS
# ─────────────────────────────────────────────────────────────────────────────

status: check-env
	@echo "GKE Cluster:"
	@gcloud container clusters list --zone $(ZONE) 2>/dev/null || echo "  Not found"
	@echo ""
	@echo "Nodes:"
	@kubectl get nodes -o wide 2>/dev/null || echo "  Cannot connect"
	@echo ""
	@echo "Pods (all namespaces):"
	@kubectl get pods -A --sort-by='.metadata.namespace' 2>/dev/null || echo "  Cannot connect"

# ─────────────────────────────────────────────────────────────────────────────
# DESTROY
# ─────────────────────────────────────────────────────────────────────────────

destroy-all: check-env
	@read -p "Destroy all resources? This cannot be undone. (yes/no) " confirm && \
		[ "$$confirm" = "yes" ] || exit 1
	./scripts/destroy-all.sh

# ─────────────────────────────────────────────────────────────────────────────
# OPA POLICY TESTS
# ─────────────────────────────────────────────────────────────────────────────
# Rego policy at infra/k8s/data/opa/policies/polaris.rego is the external
# Policy Decision Point for Polaris (see helm/polaris/values-gke.tmpl.yaml
# `External authorization — Open Policy Agent` block). scripts/opa-test.sh
# downloads a pinned opa binary into tools/opa/ (gitignored) if one isn't
# already on PATH, then runs the unit suite.

opa-test:
	@./scripts/opa-test.sh

opa-lint:
	@./scripts/opa-test.sh --lint
