#!/usr/bin/env bash
# Phase: configure agent VM to route through the integrations VM.
# Reads the inter-VM bearer from the K8s Secret created by the integ VM's
# setup Job, stores it on the agent VM, creates the transport provider.
# Only runs when ROLE=agent.

if [[ "${ROLE}" != "agent" || -z "${PEER_LABEL}" ]]; then
  return 0 2>/dev/null || true
fi

echo "============================================================"
echo "Phase: Agent VM → integrations VM routing"
echo "============================================================"

INTEG_SERVICE="${PEER_LABEL}-gateway.${NS}.svc.cluster.local"
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
    echo "  The Job will retry (backoffLimit=${JOB_BACKOFF_LIMIT})."
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

# Inference goes directly through the agent VM's provider (created by apply_bom.py).
# The inference-proxy provider for two-VM routing is handled by apply_bom.py when needed.
echo "Agent routing configured (bearer stored)."
