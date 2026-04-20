#!/usr/bin/env bash
#
# Builds apache/polaris-tools/console into a container image and pushes it
# to your GCP Artifact Registry.
#
# Why we build our own: the Apache Polaris project does not publish a
# multi-arch container image yet (November 2025 / incubator stage).  The only
# community image on Docker Hub is linux/arm64 only, which won't schedule on
# our amd64 GKE nodes.  The upstream source under apps/polaris-console/upstream
# (vendored as a git submodule) already ships a production-ready Dockerfile
# with nginx + runtime ${VITE_*} config, so all we have to do is buildx and
# push to our registry.
#
# Usage:
#   scripts/build-polaris-console.sh               # tag = <upstream-sha>
#   scripts/build-polaris-console.sh --tag v1      # explicit tag
#   scripts/build-polaris-console.sh --latest      # also push :latest
#
# Prerequisites:
#   - docker buildx  (docker 20+ ships this by default)
#   - gcloud auth configure-docker europe-west2-docker.pkg.dev
#   - env.sh sourced so PROJECT_ID, REGION, ARTIFACT_REGISTRY are set

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_DIR="${REPO_ROOT}/apps/polaris-console/upstream/console"

if [[ ! -d "${UPSTREAM_DIR}" ]] || [[ -z "$(ls -A "${UPSTREAM_DIR}" 2>/dev/null)" ]]; then
  echo "Submodule apps/polaris-console/upstream is empty — initialising..." >&2
  git -C "${REPO_ROOT}" submodule update --init --recursive apps/polaris-console/upstream
fi

if [[ ! -f "${UPSTREAM_DIR}/docker/Dockerfile" ]]; then
  echo "ERROR: ${UPSTREAM_DIR}/docker/Dockerfile still missing after submodule init." >&2
  exit 1
fi

# Load env.sh if available — we need ARTIFACT_REGISTRY.
if [[ -f "${REPO_ROOT}/env.sh" ]]; then
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/env.sh"
fi

: "${ARTIFACT_REGISTRY:?ARTIFACT_REGISTRY not set — source env.sh first}"

# Tag defaults to a composite of upstream commit SHA + our repo commit SHA so
# every image is uniquely traceable back to reproducible inputs.
UPSTREAM_SHA="$(git -C "${REPO_ROOT}/apps/polaris-console/upstream" rev-parse --short=7 HEAD)"
REPO_SHA="$(git -C "${REPO_ROOT}" rev-parse --short=7 HEAD 2>/dev/null || echo dirty)"
DEFAULT_TAG="${UPSTREAM_SHA}-${REPO_SHA}"

TAG=""
ALSO_LATEST="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)     TAG="$2"; shift 2 ;;
    --latest)  ALSO_LATEST="true"; shift ;;
    *)         echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done
TAG="${TAG:-${DEFAULT_TAG}}"

IMAGE="${ARTIFACT_REGISTRY}/polaris-console:${TAG}"

echo "=== Building polaris-console ==="
echo "  upstream: ${UPSTREAM_DIR}"
echo "  upstream SHA: ${UPSTREAM_SHA}"
echo "  repo SHA: ${REPO_SHA}"
echo "  image: ${IMAGE}"
echo

# Ensure a buildx builder exists.  Create an ephemeral one if none.
if ! docker buildx inspect polaris-console-builder >/dev/null 2>&1; then
  docker buildx create --name polaris-console-builder --use >/dev/null
else
  docker buildx use polaris-console-builder
fi

cd "${UPSTREAM_DIR}"

# Upstream Dockerfile does `COPY DISCLAIMER /DISCLAIMER` but the Apache
# Polaris repo has never committed that file into console/ (tracked in
# apache/polaris-tools#??? — still missing as of the pinned SHA).  We keep a
# canonical Apache Incubator disclaimer alongside this build script and
# stage it into the build context just for the build, then remove it so
# the submodule working tree stays pristine.
DISCLAIMER_SRC="${REPO_ROOT}/apps/polaris-console/DISCLAIMER"
DISCLAIMER_DST="${UPSTREAM_DIR}/DISCLAIMER"
if [[ ! -f "${DISCLAIMER_SRC}" ]]; then
  echo "ERROR: ${DISCLAIMER_SRC} missing — restore it from Git." >&2
  exit 1
fi
cp "${DISCLAIMER_SRC}" "${DISCLAIMER_DST}"

# Stage overlay files on top of the pinned submodule (see
# apps/polaris-console/overlay/README.md).  Anything under overlay/ is
# copied over the equivalent path in upstream/console/, then reverted
# in the cleanup trap via `git checkout --` so the submodule working
# tree stays pristine.
OVERLAY_DIR="${REPO_ROOT}/apps/polaris-console/overlay"
OVERLAY_FILES=()
if [[ -d "${OVERLAY_DIR}" ]]; then
  while IFS= read -r -d '' src; do
    rel="${src#${OVERLAY_DIR}/}"
    # skip overlay-internal docs
    case "${rel}" in README.md|*/README.md) continue ;; esac
    dst="${UPSTREAM_DIR}/${rel}"
    mkdir -p "$(dirname "${dst}")"
    cp "${src}" "${dst}"
    OVERLAY_FILES+=("${rel}")
    echo "  overlay: ${rel}"
  done < <(find "${OVERLAY_DIR}" -type f -print0)
fi

cleanup() {
  rm -f "${DISCLAIMER_DST}"
  if [[ ${#OVERLAY_FILES[@]} -gt 0 ]]; then
    # Restore any overlaid files from the submodule's pristine index so
    # repeated builds remain idempotent.
    ( cd "${UPSTREAM_DIR}" && git checkout -- "${OVERLAY_FILES[@]}" 2>/dev/null || true )
  fi
}
trap cleanup EXIT

PLATFORM="linux/amd64"
EXTRA_TAGS=()
if [[ "${ALSO_LATEST}" == "true" ]]; then
  EXTRA_TAGS+=(--tag "${ARTIFACT_REGISTRY}/polaris-console:latest")
fi

docker buildx build \
  --platform "${PLATFORM}" \
  --file docker/Dockerfile \
  --tag "${IMAGE}" \
  "${EXTRA_TAGS[@]}" \
  --push \
  .

echo
echo "=== Done ==="
echo "Pushed: ${IMAGE}"
if [[ "${ALSO_LATEST}" == "true" ]]; then
  echo "Pushed: ${ARTIFACT_REGISTRY}/polaris-console:latest"
fi
echo
echo "Next: update infra/k8s/data/polaris-console.tmpl.yaml with:"
echo "  image: ${IMAGE}"
echo "then run scripts/render-manifests.sh and commit."
