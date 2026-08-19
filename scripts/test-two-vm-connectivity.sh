#!/usr/bin/env bash
# Automated connectivity test for the two-VM split architecture.
# Verifies:
#   1. Both gateways are running
#   2. Agent VM can reach the allowed proxy port on integrations VM
#   3. Agent VM CANNOT reach a denied port on integrations VM
set -euo pipefail

NS="${NS:-openshell-agents}"
SSH_KEY_PATH="${SSH_KEY_PATH:-${HOME}/.generated-ssh-keys/sandbox-ssh}"
SSH_USER="${SSH_USER:-cloud-user}"
AGENT_VM="${AGENT_VM:-saw-agent}"
INTEGRATIONS_VM="${INTEGRATIONS_VM:-saw-integ}"
ALLOWED_SERVICE="${INTEGRATIONS_VM}-gateway"
DENIED_SERVICE="${INTEGRATIONS_VM}-denied-test"

guest_ssh() {
  local vm="$1" command="$2"
  virtctl -n "${NS}" ssh "${SSH_USER}@vm/${vm}" \
    --identity-file="${SSH_KEY_PATH}" \
    --local-ssh-opts=-oStrictHostKeyChecking=no \
    --local-ssh-opts=-oUserKnownHostsFile=/dev/null \
    --command="${command}"
}

cleanup() {
  oc -n "${NS}" delete service "${DENIED_SERVICE}" --ignore-not-found >/dev/null 2>&1 || true
  guest_ssh "${INTEGRATIONS_VM}" \
    "pkill -f 'python3 -m http.server 18080' || true; pkill -f 'python3 -m http.server 18081' || true" \
    >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=== Two-VM Connectivity Test ==="
echo "Namespace: ${NS}"
echo "Agent VM: ${AGENT_VM}"
echo "Integrations VM: ${INTEGRATIONS_VM}"
echo ""

# Wait for setup Jobs
echo "Waiting for setup Jobs to complete..."
oc -n "${NS}" wait --for=condition=complete \
  "job/${AGENT_VM}-setup" "job/${INTEGRATIONS_VM}-setup" --timeout=30m

# Test 1: Both gateways running
echo ""
echo "--- Test 1: Gateway health ---"
for vm in "${AGENT_VM}" "${INTEGRATIONS_VM}"; do
  status="$(guest_ssh "${vm}" "systemctl --user is-active openshell-gateway.service" 2>/dev/null || true)"
  if [[ "${status}" == "active" ]]; then
    echo "PASS: ${vm} gateway is active"
  else
    echo "FAIL: ${vm} gateway is ${status}" >&2
    exit 1
  fi
done

# Start test HTTP servers on integrations VM
guest_ssh "${INTEGRATIONS_VM}" \
  "nohup python3 -m http.server 18080 --bind 0.0.0.0 >/tmp/test-allowed.log 2>&1 &
   nohup python3 -m http.server 18081 --bind 0.0.0.0 >/tmp/test-denied.log 2>&1 &"
sleep 2

# Create a test service on the denied port
oc -n "${NS}" apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${DENIED_SERVICE}
spec:
  selector:
    app.kubernetes.io/name: ${INTEGRATIONS_VM}
  ports:
    - name: denied-test
      port: 18081
      targetPort: 18081
      protocol: TCP
EOF

# Test 2: Allowed port reachable
echo ""
echo "--- Test 2: Allowed port (18080) ---"
allowed_url="http://${ALLOWED_SERVICE}.${NS}.svc.cluster.local:18080/"
if guest_ssh "${AGENT_VM}" "curl -fsS --connect-timeout 5 '${allowed_url}' >/dev/null" 2>/dev/null; then
  echo "PASS: Agent VM reached integrations VM on port 18080"
else
  echo "FAIL: Agent VM could not reach integrations VM on port 18080" >&2
  exit 1
fi

# Test 3: Denied port blocked (only works if NetworkPolicy is applied)
echo ""
echo "--- Test 3: Denied port (18081) ---"
denied_url="http://${DENIED_SERVICE}.${NS}.svc.cluster.local:18081/"
if guest_ssh "${AGENT_VM}" "curl -fsS --connect-timeout 3 '${denied_url}' >/dev/null" 2>/dev/null; then
  echo "FAIL: Agent VM reached a denied port — NetworkPolicy may not be applied" >&2
  exit 1
else
  echo "PASS: Agent VM blocked from denied port 18081"
fi

echo ""
echo "=== All tests passed ==="
