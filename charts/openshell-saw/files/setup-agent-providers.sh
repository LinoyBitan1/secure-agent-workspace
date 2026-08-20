#!/usr/bin/env bash
# Phase: configure agent VM to route through the integrations VM.
# Reads the inter-VM bearer from the K8s Secret created by the integ VM's
# setup Job, stores it on the agent VM, creates the transport provider.
# Only runs when ROLE=agent.

if [[ "${ROLE}" != "agent" ]]; then
  return 0 2>/dev/null || true
fi

echo "============================================================"
echo "Phase: Agent VM → integrations VM routing"
echo "============================================================"

{{- $peerLabel := .Values.networkPolicy.peerLabel }}
INTEG_SERVICE="{{ $peerLabel }}-gateway.${NS}.svc.cluster.local"
BEARER_SECRET="inter-vm-bearer"

# --- Wait for the inter-VM bearer (created by integ VM setup Job) ---
echo "Waiting for inter-VM bearer secret..."
deadline=$((SECONDS + 300))
while true; do
  if kubectl get secret "${BEARER_SECRET}" -n "${NS}" >/dev/null 2>&1; then
    break
  fi
  if (( SECONDS > deadline )); then
    echo "ERROR: inter-VM bearer secret not found after 300s — integ VM setup may still be running."
    echo "  The Job will retry (backoffLimit={{ .Values.job.backoffLimit | default 3 }})."
    exit 1
  fi
  echo "  waiting for secret/${BEARER_SECRET}... ($(( deadline - SECONDS ))s remaining)"
  sleep 10
done

BEARER="$(kubectl get secret "${BEARER_SECRET}" -n "${NS}" -o jsonpath='{.data.bearer}' | base64 -d)"
echo "  Bearer retrieved from secret/${BEARER_SECRET}"

# --- Store bearer on the agent VM ---
guest_ssh "
  install -d -m 700 /home/${SSH_USER}/.config/secure-agent-workspace
  umask 077
  cat > /home/${SSH_USER}/.config/secure-agent-workspace/inter-vm-bearer <<< '${BEARER}'
  chmod 600 /home/${SSH_USER}/.config/secure-agent-workspace/inter-vm-bearer
  echo 'Inter-VM bearer stored on agent VM'
"

# --- Create inference-proxy provider (custom profile + endpoint whitelist) ---
INFERENCE_PROXY_PORT="{{ .Values.inference.proxyPort | default 18083 }}"
INFERENCE_BASE_URL="http://${INTEG_SERVICE}:${INFERENCE_PROXY_PORT}/v1"
echo "Creating inference-proxy provider on agent VM (-> ${INFERENCE_BASE_URL})..."
if ! guest_ssh "
  set -e
  export PATH=\"\$HOME/.local/bin:\$PATH\"

  # Use mTLS gateway for admin operations
  openshell gateway select openshell-local 2>/dev/null || true

  BEARER=\$(cat /home/${SSH_USER}/.config/secure-agent-workspace/inter-vm-bearer)

  # Import inference-proxy profile (whitelists integ VM endpoint for sandbox policy)
  if ! openshell provider profile export inference-proxy >/dev/null 2>&1; then
    cat > /tmp/inference-proxy-profile.yaml <<PROFEOF
id: inference-proxy
display_name: Inference via integration VM
description: Routes inference through the integrations VM reverse proxy
category: inference
inference_capable: true
credentials:
  - name: api_key
    env_vars:
      - INFERENCE_API_KEY
    required: true
    auth_style: bearer
    header_name: authorization
endpoints:
  - host: ${INTEG_SERVICE}
    port: ${INFERENCE_PROXY_PORT}
    protocol: rest
    access: read-write
    enforcement: passthrough
binaries:
  - /usr/bin/curl
  - /usr/local/bin/curl
PROFEOF
    openshell provider profile lint -f /tmp/inference-proxy-profile.yaml
    openshell provider profile import -f /tmp/inference-proxy-profile.yaml
    echo '  Imported: inference-proxy profile'
  else
    echo '  Already imported: inference-proxy profile'
  fi

  # Create provider with inter-VM bearer credential
  if ! openshell provider get inference-proxy >/dev/null 2>&1; then
    INFERENCE_API_KEY=\"\${BEARER}\" openshell provider create \
      --name inference-proxy \
      --type inference-proxy \
      --credential INFERENCE_API_KEY
    echo '  Created: inference-proxy provider'
  else
    echo '  Already exists: inference-proxy provider'
  fi
"; then
  echo "ERROR: failed to create inference-proxy provider"
  exit 1
fi

echo "Agent routing configured."
echo "  inference: ${INFERENCE_BASE_URL} (via inter-VM bearer)"
