#!/usr/bin/env bash
#
# Builds the FastAPI backend (apps/api) and Next.js dashboard (apps/frontend)
# as linux/amd64 images and pushes them to the project's Artifact Registry so
# GKE can pull them.
#
# By default, both images are built and tagged with the short git SHA plus
# `:latest`. Pass --api-only or --dashboard-only to narrow scope.
#
# Usage:
#   scripts/build-and-push-apps.sh                  # build + push both, tag=<sha> + :latest
#   scripts/build-and-push-apps.sh --api-only
#   scripts/build-and-push-apps.sh --dashboard-only
#   scripts/build-and-push-apps.sh --tag 0.1.0      # explicit tag (still also pushes :latest)
#   scripts/build-and-push-apps.sh --no-latest      # only push the specific tag
#
# Prerequisites:
#   - docker buildx (docker 20+)
#   - `gcloud auth configure-docker ${REGION}-docker.pkg.dev` has been run once
#   - env.sh sourced or PROJECT_ID / REGION / ARTIFACT_REGISTRY exported
#
# After pushing, update the tag in infra/k8s/apps/overlays/prod/kustomization.yaml
# and ArgoCD will roll the Deployments on next sync.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "${REPO_ROOT}/env.sh" ]]; then
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/env.sh" > /dev/null
fi

: "${ARTIFACT_REGISTRY:?ARTIFACT_REGISTRY not set — source env.sh first}"

REPO_SHA="$(git -C "${REPO_ROOT}" rev-parse --short=7 HEAD 2>/dev/null || echo dirty)"
DEFAULT_TAG="${REPO_SHA}"

TAG=""
PUSH_LATEST="true"
BUILD_API="true"
BUILD_DASHBOARD="true"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)             TAG="$2"; shift 2 ;;
    --no-latest)       PUSH_LATEST="false"; shift ;;
    --api-only)        BUILD_API="true";  BUILD_DASHBOARD="false"; shift ;;
    --dashboard-only)  BUILD_API="false"; BUILD_DASHBOARD="true";  shift ;;
    -h|--help)
      sed -n '1,20p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done
TAG="${TAG:-${DEFAULT_TAG}}"

PLATFORM="linux/amd64"

if ! docker buildx inspect openvelox-apps-builder >/dev/null 2>&1; then
  docker buildx create --name openvelox-apps-builder --use >/dev/null
else
  docker buildx use openvelox-apps-builder
fi

build_push() {
  local name="$1" context="$2"
  local image="${ARTIFACT_REGISTRY}/${name}:${TAG}"
  local extra=()
  if [[ "${PUSH_LATEST}" == "true" ]]; then
    extra+=(--tag "${ARTIFACT_REGISTRY}/${name}:latest")
  fi

  echo "=== Building ${name} ==="
  echo "  context: ${context}"
  echo "  image:   ${image}"
  if [[ "${PUSH_LATEST}" == "true" ]]; then
    echo "  also:    ${ARTIFACT_REGISTRY}/${name}:latest"
  fi
  echo

  docker buildx build \
    --platform "${PLATFORM}" \
    --tag "${image}" \
    "${extra[@]}" \
    --push \
    "${context}"

  echo
  echo "Pushed: ${image}"
}

if [[ "${BUILD_API}" == "true" ]]; then
  build_push openvelox-api "${REPO_ROOT}/apps/api"
fi

if [[ "${BUILD_DASHBOARD}" == "true" ]]; then
  build_push openvelox-dashboard "${REPO_ROOT}/apps/frontend"
fi

echo
echo "=== Done ==="
echo "Next: bump newTag to \"${TAG}\" in"
echo "  infra/k8s/apps/overlays/prod/kustomization.yaml"
echo "and commit. ArgoCD (apps Application) will sync automatically."
