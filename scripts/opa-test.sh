#!/usr/bin/env bash
#
# Run the Polaris OPA policy test suite.
# =======================================
#
# Validates infra/k8s/data/opa/policies/polaris.rego against
# polaris_test.rego. Safe to run locally and in CI — any failure here
# means the Rego that's about to ship would either (a) deny a caller that
# must work today or (b) widen access beyond what the tests enforce.
#
# If `opa` isn't on PATH we download the pinned binary into tools/opa/
# (gitignored) rather than fighting with brew/apt. The binary version is
# pinned to keep test behaviour reproducible across dev laptops and CI.
#
# Usage:  scripts/opa-test.sh          # run the tests
#         scripts/opa-test.sh --check  # same as above, CI-friendly alias
#         scripts/opa-test.sh --lint   # opa check --strict instead of tests

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLICIES_DIR="${REPO_ROOT}/infra/k8s/data/opa/policies"
OPA_VERSION="${OPA_VERSION:-0.70.0}"
TOOLS_DIR="${REPO_ROOT}/tools/opa"
OPA_BIN="${TOOLS_DIR}/opa-${OPA_VERSION}"

mode="test"
case "${1:-}" in
  --check)  mode="test" ;;
  --lint)   mode="lint" ;;
  --help|-h) sed -n '1,20p' "$0"; exit 0 ;;
  "") ;;
  *) echo "Unknown argument: $1" >&2; exit 2 ;;
esac

# ─── Locate an opa binary ────────────────────────────────────────────────
if command -v opa >/dev/null 2>&1; then
  OPA="$(command -v opa)"
else
  mkdir -p "${TOOLS_DIR}"
  if [[ ! -x "${OPA_BIN}" ]]; then
    case "$(uname -s)-$(uname -m)" in
      Darwin-arm64)  PKG="opa_darwin_arm64_static" ;;
      Darwin-x86_64) PKG="opa_darwin_amd64_static" ;;
      Linux-x86_64)  PKG="opa_linux_amd64_static" ;;
      Linux-aarch64) PKG="opa_linux_arm64_static" ;;
      *) echo "ERROR: unsupported platform $(uname -sm)" >&2; exit 3 ;;
    esac
    echo "==> Downloading opa ${OPA_VERSION} (${PKG}) into tools/opa/"
    curl -fsSL -o "${OPA_BIN}" \
      "https://openpolicyagent.org/downloads/v${OPA_VERSION}/${PKG}"
    chmod +x "${OPA_BIN}"
  fi
  OPA="${OPA_BIN}"
fi

# ─── Run ─────────────────────────────────────────────────────────────────
if [[ "${mode}" == "lint" ]]; then
  echo "==> opa check --strict ${POLICIES_DIR#${REPO_ROOT}/}"
  exec "${OPA}" check --strict "${POLICIES_DIR}"
else
  echo "==> opa test ${POLICIES_DIR#${REPO_ROOT}/}"
  exec "${OPA}" test --verbose "${POLICIES_DIR}"
fi
