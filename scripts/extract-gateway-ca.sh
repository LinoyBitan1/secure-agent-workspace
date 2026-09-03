#!/usr/bin/env bash
# Extract the gateway CA certificate from the sandbox VM to the CLI config.
# The openshell CLI reads this CA (at ~/.config/openshell/gateways/<name>/mtls/ca.crt)
# to verify the gateway's TLS certificate, removing the need for --gateway-insecure.
# Expects: NS, VM_NAME, SSH_KEY_PATH, OUT_FILE
set -euo pipefail

NS="${NS:-openshell-agents}"
SSH_KEY_PATH="${SSH_KEY_PATH:-.generated-ssh-keys/sandbox-ssh}"
VM_NAME="${VM_NAME:?VM_NAME is required}"
OUT_FILE="${OUT_FILE:?OUT_FILE is required}"

echo "Extracting CA certificate from VM '${VM_NAME}'..."
mkdir -p "$(dirname "${OUT_FILE}")"

virtctl -n "${NS}" ssh "cloud-user@vm/${VM_NAME}" \
  --identity-file="${SSH_KEY_PATH}" \
  --local-ssh-opts="-oStrictHostKeyChecking=no" \
  --local-ssh-opts="-oUserKnownHostsFile=/dev/null" \
  --local-ssh-opts="-oLogLevel=ERROR" \
  --local-ssh-opts="-oConnectTimeout=5" \
  --command='cat $HOME/.local/state/openshell/tls/ca.crt' \
  > "${OUT_FILE}"

if [[ ! -s "${OUT_FILE}" ]]; then
  echo "Error: CA certificate not found on VM. The gateway may not have started yet." >&2
  echo "  Run 'make openshell-saw-logs' to check, then re-run this target." >&2
  rm -f "${OUT_FILE}"
  exit 1
fi

echo "CA certificate installed."
