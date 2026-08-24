#!/usr/bin/env bash
# Open the OpenClaw web UI via openshell ssh-proxy port-forward.
# Uses the local openshell CLI with fresh OIDC token — no virtctl needed.

set -euo pipefail

GATEWAY_NAME="${GATEWAY_NAME:?GATEWAY_NAME is required}"
SANDBOX_NAME="${SANDBOX_NAME:-${OPENSHELL_SAW_NAME:-${GATEWAY_NAME}}}"
WORKSPACE="${WORKSPACE:-default}"
GUI_PORT="${GUI_PORT:-18789}"
SSH_USER="${SSH_USER:-sandbox}"

command -v openshell >/dev/null 2>&1 || {
  echo "Error: openshell CLI not found. Install from https://github.com/NVIDIA/OpenShell/releases"
  exit 1
}

# Kill any existing port-forward on this port
pids=$(lsof -ti :"${GUI_PORT}" 2>/dev/null || true)
if [[ -n "${pids}" ]]; then
  kill "${pids}" 2>/dev/null || true
  sleep 1
fi

# Fetch dashboard token via openshell sandbox exec.
# Support both legacy /sandbox OpenClaw home and /tmp home.
echo "Fetching dashboard token..."
TOKEN="$(
  openshell --gateway "${GATEWAY_NAME}" --gateway-insecure sandbox exec --workspace "${WORKSPACE}" -n "${SANDBOX_NAME}" --no-tty -- \
    sh -lc '
      for p in \
        /sandbox/.openclaw/openclaw.json \
        "/tmp/openclaw-home-'"${SANDBOX_NAME}"'/.openclaw/openclaw.json" \
        /tmp/openclaw/openclaw.json; do
        if [ -r "$p" ]; then
          cat "$p"
          exit 0
        fi
      done
      exit 1
    ' 2>/dev/null \
  | grep -v "TLS certificate verification is disabled" \
  | python3 -c "import sys,json; c=json.load(sys.stdin); print((c.get('gateway',{}).get('auth',{}).get('token','')))" 2>/dev/null \
  | grep -oE '^[a-f0-9]+$' || true
)"

if [[ -z "${TOKEN}" ]]; then
  TOKEN="$(
    openshell --gateway "${GATEWAY_NAME}" --gateway-insecure sandbox exec --workspace "${WORKSPACE}" -n "${SANDBOX_NAME}" --no-tty -- \
      sh -lc '
        for p in /tmp/auth-token "/tmp/openclaw-home-'"${SANDBOX_NAME}"'/auth-token"; do
          if [ -r "$p" ]; then
            cat "$p"
            exit 0
          fi
        done
        exit 1
      ' 2>/dev/null | grep -oE '[a-f0-9]{32,}' || true
  )"
fi

if [[ -z "${TOKEN}" ]]; then
  echo "Error: Could not extract dashboard token."
  echo "  Make sure the sandbox setup has completed and openclaw is configured."
  echo ""
  echo "  Try: openshell --gateway ${GATEWAY_NAME} --gateway-insecure sandbox list --workspace ${WORKSPACE}"
  exit 1
fi

# Discover a reachable host from the same ssh-proxy context used by the tunnel.
# This avoids false positives when `sandbox exec` and `ssh-proxy` land in
# different runtime contexts.
probe_remote_host() {
  ssh -o "ProxyCommand=openshell --gateway-insecure ssh-proxy --gateway-name ${GATEWAY_NAME} --name ${SANDBOX_NAME}" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    "${SSH_USER}@openshell-${SANDBOX_NAME}.${WORKSPACE}" \
    'if curl -sf -m 2 http://127.0.0.1:18789/health >/dev/null 2>&1; then
       echo 127.0.0.1
       exit 0
     fi
     for cidr in $(ip -o -4 addr show scope global 2>/dev/null | awk "{print \$4}"); do
       addr=${cidr%/*}
       if curl -sf -m 2 "http://${addr}:18789/health" >/dev/null 2>&1; then
         echo "${addr}"
         exit 0
       fi
     done' 2>/dev/null || true
}

REMOTE_HOST="${OPENCLAW_GUI_REMOTE_HOST:-}"
if [[ -z "${REMOTE_HOST}" ]]; then
  REMOTE_HOST_RAW="$(probe_remote_host)"
  REMOTE_HOST="$(
    printf '%s\n' "${REMOTE_HOST_RAW}" | python3 -c 'import re,sys; s=sys.stdin.read(); m=re.search(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", s); print(m.group(0) if m else "")'
  )"
fi

if [[ -z "${REMOTE_HOST}" ]]; then
  REMOTE_HOST="127.0.0.1"
  echo "Warning: gateway reachability probe was inconclusive; using ${REMOTE_HOST}:18789."
fi

echo ""
echo "OpenClaw UI: http://localhost:${GUI_PORT}/#token=${TOKEN}"
echo "Tunnel target: ${REMOTE_HOST}:18789"
echo "Press Ctrl-C to stop."
echo ""

# Port-forward via openshell ssh-proxy — uses local OIDC token
ssh -o "ProxyCommand=openshell --gateway-insecure ssh-proxy --gateway-name ${GATEWAY_NAME} --name ${SANDBOX_NAME}" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o LogLevel=ERROR \
  -L "${GUI_PORT}:${REMOTE_HOST}:18789" \
  -N "${SSH_USER}@openshell-${SANDBOX_NAME}.${WORKSPACE}"
