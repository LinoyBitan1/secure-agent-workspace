#!/usr/bin/env bash
# Mirror images from quay.io to the internal registry using in-cluster skopeo Jobs.
# Use this on macOS where podman-machine TCP connections drop mid-upload for large layers.
set -euo pipefail

BUILD_NS="${BUILD_NS:-openshell-agents}"
QUAY_REPO="${QUAY_REPO:-quay.io/rh-ee-lbitan}"
VERSION="${OPENSHELL_VERSION:-0.0.116}"
# The managed NemoClaw path needs the CLI image, not the repository's optional
# custom sandbox image. Mirror nemoclaw-sandbox explicitly when testing Docker
# --from workflows.
IMAGES="${IMAGES:-openshell-gateway openshell-gateway-docker nemoclaw-cli}"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Setting up image-mirror ServiceAccount..."
oc apply -n "${BUILD_NS}" -f "${SCRIPTS_DIR}/mirror-images-rbac.yaml"
# nonroot SCC (not anyuid) is sufficient: HOME and XDG_RUNTIME_DIR are redirected
# to /tmp in the Job spec so skopeo never touches /run/containers (the root-only
# path that previously forced anyuid). The namespace's restricted PodSecurity still
# blocks root; nonroot overrides it for this SA without granting broader privileges.
oc adm policy add-scc-to-user nonroot -z image-mirror -n "${BUILD_NS}" 2>/dev/null || true

for IMAGE in ${IMAGES}; do
  export IMAGE BUILD_NS QUAY_REPO VERSION
  echo "Mirroring ${IMAGE}:${VERSION}..."
  oc delete job "mirror-${IMAGE}" -n "${BUILD_NS}" 2>/dev/null || true
  # Only substitute template vars; leave runtime shell vars (e.g. ${TOKEN}) intact
  envsubst '${IMAGE} ${BUILD_NS} ${QUAY_REPO} ${VERSION}' \
    < "${SCRIPTS_DIR}/mirror-images-job.yaml" \
    | oc apply -n "${BUILD_NS}" -f -
  oc -n "${BUILD_NS}" wait --for=condition=complete \
    job/"mirror-${IMAGE}" --timeout=600s
  oc tag "${BUILD_NS}/${IMAGE}:${VERSION}" "${BUILD_NS}/${IMAGE}:latest" 2>/dev/null || true
  echo "  ${IMAGE} done."
done

echo "All images mirrored (tag: ${VERSION}, also tagged as :latest)."
