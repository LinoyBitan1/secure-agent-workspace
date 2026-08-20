#!/usr/bin/env bash
# Configure Gmail OAuth refresh on the integrations VM gateway.
#
# This script uploads the OAuth client JSON and refresh token to the
# integrations VM, updates the gmail-read provider profile with refresh
# support, configures the refresh material, and verifies the first token
# rotation.
#
# Prerequisites:
#   - Integrations VM deployed with gmail-read provider already created
#   - A Desktop OAuth client JSON from your GCP project
#   - A gog token export with a valid refresh_token (gmail.readonly scope)
#
# Usage:
#   ./scripts/configure-gmail-refresh.sh \
#     --client-json /path/to/client_secret.json \
#     --token-export /path/to/gog-token-export.json
#
# Environment overrides:
#   NS                 — OpenShift namespace (default: current project)
#   INTEGRATIONS_VM    — VM name (default: openshell-saw-integ)
#   SSH_KEY_PATH       — SSH private key (default: ~/.generated-ssh-keys/sandbox-ssh)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="${NS:-$(oc project -q 2>/dev/null || echo openshell-agents)}"
INTEGRATIONS_VM="${INTEGRATIONS_VM:-openshell-saw-integ}"
SSH_KEY_PATH="${SSH_KEY_PATH:-${HOME}/.generated-ssh-keys/sandbox-ssh}"
SSH_USER="${SSH_USER:-cloud-user}"
CLIENT_JSON=""
TOKEN_EXPORT=""

usage() {
  echo "Usage: $0 --client-json <path> --token-export <path>" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --client-json)  CLIENT_JSON="$2"; shift 2 ;;
    --token-export) TOKEN_EXPORT="$2"; shift 2 ;;
    --namespace)    NS="$2"; shift 2 ;;
    --vm)           INTEGRATIONS_VM="$2"; shift 2 ;;
    --ssh-key)      SSH_KEY_PATH="$2"; shift 2 ;;
    -h|--help)      usage ;;
    *)              echo "Unknown option: $1" >&2; usage ;;
  esac
done

if [[ -z "${CLIENT_JSON}" || -z "${TOKEN_EXPORT}" ]]; then
  echo "ERROR: --client-json and --token-export are required." >&2
  usage
fi

for f in "${CLIENT_JSON}" "${TOKEN_EXPORT}" "${SSH_KEY_PATH}"; do
  if [[ ! -f "${f}" ]]; then
    echo "ERROR: File not found: ${f}" >&2
    exit 1
  fi
done

for cmd in jq kubectl; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: ${cmd} not found." >&2
    exit 1
  fi
done

# Validate the client JSON has the expected structure
jq -er '.installed.client_id' "${CLIENT_JSON}" >/dev/null 2>&1 || {
  echo "ERROR: ${CLIENT_JSON} does not look like a Desktop OAuth client JSON." >&2
  exit 1
}

jq -er '.refresh_token' "${TOKEN_EXPORT}" >/dev/null 2>&1 || {
  echo "ERROR: ${TOKEN_EXPORT} does not contain a refresh_token." >&2
  exit 1
}

echo "============================================================"
echo "Configure Gmail OAuth refresh on integrations VM"
echo "============================================================"
echo "  Namespace: ${NS}"
echo "  VM:        ${INTEGRATIONS_VM}"
echo ""

# --- Set up SSH via port-forward ---
LOCAL_SSH_PORT=2222
echo "Starting port-forward to ${INTEGRATIONS_VM}..."
kubectl port-forward "svc/${INTEGRATIONS_VM}-gateway" -n "${NS}" "${LOCAL_SSH_PORT}:22" &
PF_PID=$!
trap 'kill ${PF_PID} 2>/dev/null || true' EXIT
sleep 2

ssh_cmd() {
  ssh -i "${SSH_KEY_PATH}" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -p "${LOCAL_SSH_PORT}" \
    "${SSH_USER}@127.0.0.1" "$@"
}

scp_cmd() {
  scp -i "${SSH_KEY_PATH}" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -P "${LOCAL_SSH_PORT}" \
    "$@"
}

# Verify connectivity
echo "Verifying SSH connectivity..."
ssh_cmd "echo 'Connected to \$(hostname)'"

# --- Step 1: Copy credential files to the VM ---
echo "Copying credential files to VM..."
scp_cmd "${CLIENT_JSON}" "${SSH_USER}@127.0.0.1:/tmp/gog-client-secret.json"
scp_cmd "${TOKEN_EXPORT}" "${SSH_USER}@127.0.0.1:/tmp/gog-token-export.json"
ssh_cmd "chmod 600 /tmp/gog-client-secret.json /tmp/gog-token-export.json"
echo "  Files copied."

# --- Step 2: Ensure provider profile has refresh support ---
# The governance interceptor hot-pushes the profile from the
# governance-policy chart. If the profile already has the refresh
# block (via ArgoCD sync), this is a no-op. Otherwise, update it
# manually so the script works before the next ArgoCD sync.
echo "Checking gmail-read provider profile for refresh support..."
ssh_cmd 'export PATH="$HOME/.local/bin:$PATH"
if openshell provider profile export gmail-read 2>/dev/null | grep -q oauth2_refresh_token; then
  echo "  Profile already has refresh support."
else
  echo "  Updating profile with refresh block..."
  cat > /tmp/gmail-read-profile-v2.yaml << '"'"'EOF'"'"'
id: gmail-read
display_name: Gmail read proxy
description: Gmail read-only proxy on the integrations VM with gateway-managed refresh
category: data
inference_capable: false
credentials:
  - name: access_token
    description: Short-lived Google OAuth access token
    env_vars: [GMAIL_ACCESS_TOKEN]
    required: true
    auth_style: bearer
    header_name: authorization
    refresh:
      strategy: oauth2_refresh_token
      token_url: https://oauth2.googleapis.com/token
      scopes: []
      refresh_before_seconds: 300
      max_lifetime_seconds: 3600
      material:
        - name: client_id
          required: true
        - name: client_secret
          required: true
          secret: true
        - name: refresh_token
          required: true
          secret: true
discovery:
  credentials: [access_token]
endpoints:
  - host: gmail.googleapis.com
    port: 443
    protocol: rest
    enforcement: enforce
    access: read-only
binaries:
  - /usr/bin/curl
  - /usr/local/bin/curl
  - /usr/local/bin/node
  - /sandbox/rust-email-proxy
EOF
  RV=$(openshell provider profile export gmail-read 2>/dev/null | grep resource_version | awk "{print \$2}")
  if [ -n "$RV" ] && [ "$RV" != "0" ]; then
    sed -i "1a resource_version: $RV" /tmp/gmail-read-profile-v2.yaml
    openshell provider profile update --file /tmp/gmail-read-profile-v2.yaml gmail-read
  else
    openshell provider profile import -f /tmp/gmail-read-profile-v2.yaml
  fi
  rm -f /tmp/gmail-read-profile-v2.yaml
  echo "  Profile updated."
fi'

# --- Step 3: Configure refresh material ---
echo "Configuring refresh material..."
ssh_cmd 'set -e
export PATH="$HOME/.local/bin:$PATH"
GOG_CLIENT_ID="$(jq -er ".installed.client_id" /tmp/gog-client-secret.json)"
export GOG_CLIENT_SECRET="$(jq -er ".installed.client_secret" /tmp/gog-client-secret.json)"
export GOG_REFRESH_TOKEN="$(jq -er ".refresh_token" /tmp/gog-token-export.json)"
openshell provider refresh configure gmail-read \
  --credential-key GMAIL_ACCESS_TOKEN \
  --strategy oauth2-refresh-token \
  --material "client_id=${GOG_CLIENT_ID}" \
  --secret-material-env client_secret=GOG_CLIENT_SECRET \
  --secret-material-env refresh_token=GOG_REFRESH_TOKEN
echo "  Refresh configured."'

# --- Step 4: Rotate and verify ---
echo "Rotating token..."
ssh_cmd 'export PATH="$HOME/.local/bin:$PATH"
openshell provider refresh rotate gmail-read --credential-key GMAIL_ACCESS_TOKEN'

echo "Checking refresh status..."
ssh_cmd 'export PATH="$HOME/.local/bin:$PATH"
openshell provider refresh status gmail-read'

# --- Step 5: Clean up credential files on VM ---
echo "Cleaning up credential files on VM..."
ssh_cmd "rm -f /tmp/gog-client-secret.json /tmp/gog-token-export.json /tmp/gmail-read-profile-v2.yaml"

echo ""
echo "============================================================"
echo "Gmail OAuth refresh configured successfully."
echo "The gateway will auto-refresh the access token before expiry."
echo "============================================================"
