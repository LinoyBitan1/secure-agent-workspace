#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

saw_render="$(helm template openshell-saw "$repo_root/charts/openshell-saw" \
  --namespace openshell-agents \
  --set sandboxName=compatibility-test \
  --set sshPublicKey='ssh-ed25519 AAAA-test' \
  --set inference.provider=build \
  --set inference.model=test-model \
  --set inference.apiKey=test-key)"

# The compatibility wrapper must apply even when the downstream CLI image is
# selected, because that image exposes the rhaiv suffix in openshell-sandbox.
grep -q 'if \[\[ "\$1" == "--version" \]\]' <<<"$saw_render"
! grep -q 'if \[\[ -z "\${CLI_IMAGE}" \]\]' <<<"$saw_render"
grep -q 'openshell-supervisor-wrapper' <<<"$saw_render"

policy_render="$(helm template governance-policy "$repo_root/charts/governance-policy" \
  --namespace openshell-agents)"

# The governed NVIDIA profile must declare the credential that BOM setup
# passes to openshell provider create.
grep -q 'name: api_key' <<<"$policy_render"
grep -q 'NVIDIA_API_KEY' <<<"$policy_render"
grep -q 'auth_style: bearer' <<<"$policy_render"
grep -q 'discovery:' <<<"$policy_render"

echo "NemoClaw compatibility template checks passed"
