#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

podman_gateway="$(helm template openshell-gateway-image \
  "$repo_root/image-builder-charts/helm/openshell-gateway-image" \
  --namespace openshell-agents)"
docker_gateway="$(helm template openshell-gateway-image \
  "$repo_root/image-builder-charts/helm/openshell-gateway-image" \
  --namespace openshell-agents --set containerRuntime=docker)"

grep -q '^  name: openshell-gateway$' <<<"$podman_gateway"
grep -q 'podman.socket' <<<"$podman_gateway"
grep -q 'host.containers.internal' <<<"$podman_gateway"
! grep -q 'docker-ce' <<<"$podman_gateway"
! grep -q 'systemctl enable docker' <<<"$podman_gateway"

grep -q '^  name: openshell-gateway-docker$' <<<"$docker_gateway"
grep -q 'docker-ce,docker-ce-cli,containerd.io' <<<"$docker_gateway"
grep -q 'systemctl enable docker' <<<"$docker_gateway"

podman_saw="$(helm template podman-sandbox \
  "$repo_root/charts/openshell-saw" \
  --set sandboxName=podman-sandbox \
  --set sshPublicKey=ssh-ed25519\ AAAA-test \
  --set inference.provider=build \
  --set inference.model=test-model \
  --set inference.apiKey=test-key)"
docker_saw="$(helm template docker-sandbox \
  "$repo_root/charts/openshell-saw" \
  --set sandboxName=docker-sandbox \
  --set sshPublicKey=ssh-ed25519\ AAAA-test \
  --set inference.provider=build \
  --set inference.model=test-model \
  --set inference.apiKey=test-key \
  --set containerRuntime=docker)"

grep -q 'OPENSHELL_DRIVERS=podman' <<<"$podman_saw"
grep -q 'name: openshell-gateway$' <<<"$podman_saw"
grep -q 'ONBOARD_CLI=nemoclaw' <<<"$podman_saw"
grep -q 'OPENSHELL_PODMAN_SOCKET=' <<<"$podman_saw"
grep -q 'NEMOCLAW_GATEWAY_RUNTIME=podman' <<<"$podman_saw"
grep -q '\[openshell.drivers.podman\]' <<<"$podman_saw"
! grep -q 'requires Docker' <<<"$podman_saw"

! grep -q 'nemoclaw-sandbox' \
  "$repo_root/charts/saw-bom/profiles/data-science/cuda-dev/sandbox.yaml"

grep -q 'OPENSHELL_DRIVERS=docker' <<<"$docker_saw"
grep -q 'name: openshell-gateway-docker$' <<<"$docker_saw"

echo "container runtime template checks passed"
