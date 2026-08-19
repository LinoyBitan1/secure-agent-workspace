#!/usr/bin/env bash
# End-to-end test for the two-VM split architecture.
#
# Verifies the full inference flow:
#   Agent sandbox -> integ VM proxy -> NVIDIA API
#
# Prerequisites:
#   - Both VMs deployed and setup Jobs completed
#   - SSH key available at SSH_KEY_PATH
#   - oc/kubectl logged in
#
# Usage:
#   ./scripts/test-two-vm-e2e.sh
#
# Environment variables (all optional):
#   NS                 namespace (default: openshell-agents)
#   SSH_KEY_PATH        path to SSH private key
#   AGENT_VM            agent VM name (default: openshell-saw)
#   INTEG_VM            integ VM name (default: openshell-saw-integ)
#   INFERENCE_MODEL     model to test (default: deepseek-ai/deepseek-v4-flash-0731)

set -euo pipefail

NS="${NS:-openshell-agents}"
SSH_KEY_PATH="${SSH_KEY_PATH:-/tmp/saw-ssh-key}"
SSH_USER="${SSH_USER:-cloud-user}"
AGENT_VM="${AGENT_VM:-openshell-saw}"
INTEG_VM="${INTEG_VM:-openshell-saw-integ}"
INTEG_SERVICE="${INTEG_VM}-gateway"
INFERENCE_MODEL="${INFERENCE_MODEL:-deepseek-ai/deepseek-v4-flash-0731}"
INFERENCE_PORT="${INFERENCE_PORT:-18083}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

pass() { echo -e "  ${GREEN}PASS${NC}  $1"; ((PASS++)); }
fail() { echo -e "  ${RED}FAIL${NC}  $1"; ((FAIL++)); }
warn() { echo -e "  ${YELLOW}WARN${NC}  $1"; ((WARN++)); }
step() { echo -e "\n${CYAN}=== $1 ===${NC}"; }

agent_ssh() {
  virtctl -n "${NS}" ssh "${SSH_USER}@vm/${AGENT_VM}" \
    --identity-file="${SSH_KEY_PATH}" \
    --local-ssh-opts=-oStrictHostKeyChecking=no \
    --local-ssh-opts=-oUserKnownHostsFile=/dev/null \
    --command="$1" 2>/dev/null
}

integ_ssh() {
  virtctl -n "${NS}" ssh "${SSH_USER}@vm/${INTEG_VM}" \
    --identity-file="${SSH_KEY_PATH}" \
    --local-ssh-opts=-oStrictHostKeyChecking=no \
    --local-ssh-opts=-oUserKnownHostsFile=/dev/null \
    --command="$1" 2>/dev/null
}

echo "============================================="
echo " Two-VM E2E Test"
echo "============================================="
echo "  Namespace:    ${NS}"
echo "  Agent VM:     ${AGENT_VM}"
echo "  Integ VM:     ${INTEG_VM}"
echo "  Model:        ${INFERENCE_MODEL}"
echo "  SSH key:      ${SSH_KEY_PATH}"

# =============================================
# 1. Pre-flight: VMs running
# =============================================
step "1. Pre-flight: VMs running"

for vm in "${AGENT_VM}" "${INTEG_VM}"; do
  phase=$(kubectl get vmi "${vm}" -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
  if [[ "${phase}" == "Running" ]]; then
    pass "${vm} is Running"
  else
    fail "${vm} is ${phase}"
  fi
done

# =============================================
# 2. SSH connectivity
# =============================================
step "2. SSH connectivity"

if agent_ssh "echo ok" | grep -q ok; then
  pass "Agent VM SSH"
else
  fail "Agent VM SSH — cannot continue"
  exit 1
fi

if integ_ssh "echo ok" | grep -q ok; then
  pass "Integ VM SSH"
else
  fail "Integ VM SSH — cannot continue"
  exit 1
fi

# =============================================
# 3. OpenShell gateway health
# =============================================
step "3. OpenShell gateway health"

for vm_name in "${AGENT_VM}" "${INTEG_VM}"; do
  if [[ "${vm_name}" == "${AGENT_VM}" ]]; then
    status=$(agent_ssh "systemctl --user is-active openshell-gateway.service" || true)
  else
    status=$(integ_ssh "systemctl --user is-active openshell-gateway.service" || true)
  fi
  if [[ "${status}" == "active" ]]; then
    pass "${vm_name} gateway active"
  else
    fail "${vm_name} gateway is ${status}"
  fi
done

# =============================================
# 4. Integ VM: inference proxy health
# =============================================
step "4. Integ VM: inference proxy"

proxy_status=$(integ_ssh "systemctl --user is-active inference-proxy.service" || true)
if [[ "${proxy_status}" == "active" ]]; then
  pass "inference-proxy service active"
else
  fail "inference-proxy service is ${proxy_status}"
fi

healthz=$(integ_ssh "curl -sf http://localhost:${INFERENCE_PORT}/healthz" || true)
if [[ "${healthz}" == "ok" ]]; then
  pass "inference proxy healthz"
else
  fail "inference proxy healthz returned: ${healthz}"
fi

# =============================================
# 5. Inter-VM bearer secret
# =============================================
step "5. Inter-VM bearer secret"

if kubectl get secret inter-vm-bearer -n "${NS}" >/dev/null 2>&1; then
  pass "inter-vm-bearer Secret exists"
  BEARER=$(kubectl get secret inter-vm-bearer -n "${NS}" -o jsonpath='{.data.bearer}' | base64 -d)
  if [[ ${#BEARER} -ge 32 ]]; then
    pass "bearer is ${#BEARER} chars"
  else
    fail "bearer too short: ${#BEARER} chars"
  fi
else
  fail "inter-vm-bearer Secret not found"
  BEARER=""
fi

# =============================================
# 6. Agent VM: providers and sandbox
# =============================================
step "6. Agent VM: providers and sandbox"

providers=$(agent_ssh "export PATH=\$HOME/.local/bin:\$PATH; openshell provider list 2>&1" || true)
if echo "${providers}" | grep -q "inference-proxy"; then
  pass "inference-proxy provider exists"
else
  fail "inference-proxy provider not found"
fi

sandbox_phase=$(agent_ssh "export PATH=\$HOME/.local/bin:\$PATH; openshell sandbox get notebook 2>&1 | grep Phase" || true)
if echo "${sandbox_phase}" | grep -q "Ready"; then
  pass "notebook sandbox is Ready"
else
  fail "notebook sandbox: ${sandbox_phase}"
fi

sandbox_providers=$(agent_ssh "export PATH=\$HOME/.local/bin:\$PATH; openshell sandbox provider list notebook 2>&1" || true)
if echo "${sandbox_providers}" | grep -q "inference-proxy"; then
  pass "inference-proxy attached to notebook"
else
  warn "inference-proxy not attached to notebook — attach it with: openshell sandbox provider attach notebook inference-proxy"
fi

# =============================================
# 7. Agent VM: OpenClaw config
# =============================================
step "7. Agent VM: OpenClaw baseUrl"

base_url=$(agent_ssh "export PATH=\$HOME/.local/bin:\$PATH; openshell sandbox exec -n notebook --no-tty -- node -e \"
const fs = require('fs');
const c = JSON.parse(fs.readFileSync('/sandbox/.openclaw/openclaw.json', 'utf8'));
const p = Object.keys(c.models?.providers || {})[0];
console.log(p ? c.models.providers[p].baseUrl : 'NOT_SET');
\" 2>/dev/null" || echo "ERROR")

if echo "${base_url}" | grep -q "${INTEG_SERVICE}"; then
  pass "baseUrl points to integ VM: $(echo "${base_url}" | tail -1)"
elif echo "${base_url}" | grep -q "inference.local"; then
  fail "baseUrl still points to inference.local (should be integ VM)"
else
  warn "baseUrl: $(echo "${base_url}" | tail -1)"
fi

# =============================================
# 8. Connectivity: agent host -> integ proxy
# =============================================
step "8. Connectivity: agent host -> integ proxy"

host_healthz=$(agent_ssh "curl -sf --max-time 5 http://${INTEG_SERVICE}.${NS}.svc.cluster.local:${INFERENCE_PORT}/healthz" || true)
if [[ "${host_healthz}" == "ok" ]]; then
  pass "agent host can reach integ proxy healthz"
else
  fail "agent host cannot reach integ proxy: ${host_healthz}"
fi

# =============================================
# 9. Connectivity: agent host -> integ inference (with bearer)
# =============================================
step "9. Inference: agent host -> integ proxy -> NVIDIA"

if [[ -n "${BEARER}" ]]; then
  host_inference=$(agent_ssh "curl -s --max-time 30 http://${INTEG_SERVICE}.${NS}.svc.cluster.local:${INFERENCE_PORT}/v1/chat/completions -H 'Content-Type: application/json' -H 'Authorization: Bearer ${BEARER}' -d '{\"model\":\"${INFERENCE_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say OK\"}],\"max_completion_tokens\":5}'" || true)

  if echo "${host_inference}" | grep -q '"content"'; then
    content=$(echo "${host_inference}" | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'])" 2>/dev/null || echo "?")
    pass "host inference returned: ${content}"
  elif echo "${host_inference}" | grep -q "Overloaded"; then
    warn "NVIDIA API overloaded — retry later"
  elif echo "${host_inference}" | grep -q "401"; then
    fail "401 — API key may be wrong on integ VM"
  else
    fail "host inference: ${host_inference:0:100}"
  fi
else
  warn "skipped — no bearer available"
fi

# =============================================
# 10. Inference: from inside sandbox (full E2E)
# =============================================
step "10. Inference: sandbox -> integ proxy -> NVIDIA (full E2E)"

if [[ -n "${BEARER}" ]]; then
  sandbox_inference=$(agent_ssh "export PATH=\$HOME/.local/bin:\$PATH; openshell sandbox exec -n notebook --no-tty -- /usr/bin/curl -s --max-time 30 http://${INTEG_SERVICE}.${NS}.svc.cluster.local:${INFERENCE_PORT}/v1/chat/completions -H 'Content-Type: application/json' -H 'Authorization: Bearer ${BEARER}' -d '{\"model\":\"${INFERENCE_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Who is the president of America? One word.\"}],\"max_completion_tokens\":5}'" || true)

  if echo "${sandbox_inference}" | grep -q '"content"'; then
    content=$(echo "${sandbox_inference}" | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'])" 2>/dev/null || echo "?")
    pass "sandbox inference returned: ${content}"
  elif echo "${sandbox_inference}" | grep -q "policy_denied"; then
    fail "policy_denied — inference-proxy provider may not be attached or enforcement is wrong"
  elif echo "${sandbox_inference}" | grep -q "Overloaded"; then
    warn "NVIDIA API overloaded — retry later"
  elif echo "${sandbox_inference}" | grep -q "401"; then
    fail "401 — real API key not configured on integ VM"
  elif echo "${sandbox_inference}" | grep -q "403"; then
    fail "403 — bearer mismatch between agent and integ VM"
  else
    fail "sandbox inference: ${sandbox_inference:0:100}"
  fi
else
  warn "skipped — no bearer available"
fi

# =============================================
# 11. Security: agent VM has no real API keys
# =============================================
step "11. Security: agent VM has no real keys"

nvidia_cred=$(agent_ssh "export PATH=\$HOME/.local/bin:\$PATH; openshell provider get nvidia -v 2>&1 | grep -c 'Credential keys' || echo 0" || echo "0")
if agent_ssh "export PATH=\$HOME/.local/bin:\$PATH; openshell provider get nvidia >/dev/null 2>&1"; then
  nvidia_type=$(agent_ssh "export PATH=\$HOME/.local/bin:\$PATH; openshell provider get nvidia 2>&1 | grep Type" || true)
  warn "nvidia provider exists on agent VM (${nvidia_type}) — has placeholder key"
else
  pass "no nvidia provider on agent VM"
fi

key_files=$(agent_ssh "find /home/${SSH_USER} -name '*nvidia*' -o -name '*api_key*' -o -name '*api-key*' 2>/dev/null | grep -v '.local/bin' | grep -v bom" || true)
if [[ -z "${key_files}" ]]; then
  pass "no API key files on agent VM"
else
  warn "potential key files found: ${key_files}"
fi

# =============================================
# Summary
# =============================================
echo ""
echo "============================================="
echo -e " Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${WARN} warnings${NC}"
echo "============================================="

if [[ ${FAIL} -gt 0 ]]; then
  echo -e "\n${RED}SOME TESTS FAILED${NC}"
  exit 1
else
  echo -e "\n${GREEN}ALL TESTS PASSED${NC}"
  exit 0
fi
