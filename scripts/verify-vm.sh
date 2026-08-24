#!/usr/bin/env bash
# Verify a VM's OpenShell setup: gateway, sandboxes, providers, exposed services.
# Usage: verify-vm.sh --vm <name> --role <agent|integrations> [--ns <namespace>] [--ssh-key <path>]
set -euo pipefail

NS="${NS:-openshell-agents}"
VM_NAME=""
ROLE=""
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.generated-ssh-keys/sandbox-ssh}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm)       VM_NAME="$2"; shift 2 ;;
    --role)     ROLE="$2"; shift 2 ;;
    --ns)       NS="$2"; shift 2 ;;
    --ssh-key)  SSH_KEY_PATH="$2"; shift 2 ;;
    *)          echo "Unknown arg: $1"; exit 1 ;;
  esac
done

: "${VM_NAME:?--vm is required}"
: "${ROLE:?--role is required (agent or integrations)}"

SSH_USER="cloud-user"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

guest_ssh() {
  virtctl -n "${NS}" ssh "${SSH_USER}@vm/${VM_NAME}" \
    --identity-file="${SSH_KEY_PATH}" \
    --local-ssh-opts=-oStrictHostKeyChecking=no \
    --local-ssh-opts=-oUserKnownHostsFile=/dev/null \
    --command="$1" 2>/dev/null
}

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }
info() { echo "  INFO  $1"; }

echo "============================================================"
echo "Verifying ${ROLE} VM: ${VM_NAME} (namespace: ${NS})"
echo "============================================================"
echo ""

# --- Check if setup is still in progress ---
JOB_ACTIVE=$(oc get job "${VM_NAME}-setup" -n "${NS}" -o jsonpath='{.status.active}' 2>/dev/null || true)
if [[ "${JOB_ACTIVE}" == "1" ]]; then
  JOB_DURATION=$(oc get job "${VM_NAME}-setup" -n "${NS}" -o jsonpath='{.status.startTime}' 2>/dev/null || true)
  echo "Setup Job is still running (started: ${JOB_DURATION:-unknown})."
  echo "Run 'make saw-logs OPENSHELL_SAW_NAME=${VM_NAME}' to follow progress."
  echo "Re-run this verify command after the Job completes."
  exit 0
fi

# --- VM status ---
echo "--- VM Status ---"
VM_STATUS=$(oc get vm "${VM_NAME}" -n "${NS}" -o jsonpath='{.status.printableStatus}' 2>/dev/null || true)
VM_READY=$(oc get vm "${VM_NAME}" -n "${NS}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
if [[ "${VM_STATUS}" == "Running" ]]; then
  pass "VM is Running"
elif [[ "${VM_STATUS}" == "Starting" || "${VM_STATUS}" == "Provisioning" ]]; then
  echo "VM is ${VM_STATUS} — setup is not complete yet."
  echo "Re-run this verify command after the VM is Running."
  exit 0
else
  fail "VM status: ${VM_STATUS:-not found}"
fi

# --- SSH access ---
echo ""
echo "--- SSH Access ---"
if guest_ssh "echo ok" >/dev/null 2>&1; then
  pass "SSH accessible"
else
  fail "SSH not accessible"
  echo ""
  echo "Results: ${PASS} passed, ${FAIL} failed"
  exit 1
fi

# --- OpenShell versions ---
echo ""
echo "--- OpenShell Versions ---"
VERSIONS=$(guest_ssh "openshell-gateway --version 2>/dev/null; openshell-supervisor --version 2>/dev/null; openshell --version 2>/dev/null" || true)
if [[ -n "${VERSIONS}" ]]; then
  echo "${VERSIONS}" | while read -r line; do
    [[ -n "${line}" ]] && info "${line}"
  done
  pass "OpenShell binaries installed"
else
  fail "OpenShell binaries not found"
fi

# --- Gateway status ---
echo ""
echo "--- Gateway ---"
GW_ACTIVE=$(guest_ssh "systemctl --user is-active openshell-gateway.service 2>/dev/null" || true)
if [[ "${GW_ACTIVE}" == "active" ]]; then
  pass "Gateway service is active"
else
  fail "Gateway service: ${GW_ACTIVE:-not found}"
fi

# Gateways registered
GATEWAYS=$(guest_ssh "openshell gateway list 2>/dev/null" || true)
if [[ -n "${GATEWAYS}" ]]; then
  echo "${GATEWAYS}" | while read -r line; do
    [[ -n "${line}" ]] && info "${line}"
  done
else
  info "No gateways listed"
fi

# --- Determine which gateway to query ---
# Use openshell-local (mTLS) without --gateway-insecure so the client cert is sent.
GW_FLAG="--gateway openshell-local"
if ! guest_ssh "openshell gateway list 2>/dev/null | grep -q openshell-local" 2>/dev/null; then
  GW_FLAG=""
fi

# Helper: strip ANSI color codes
strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

# --- Providers ---
echo ""
echo "--- Providers ---"
PROVIDERS=$(guest_ssh "openshell ${GW_FLAG} provider list 2>/dev/null" | strip_ansi || true)
PROV_LINES=$(echo "${PROVIDERS}" | awk 'NR>1 && NF>=2 && $1 !~ /^(WARN|Error|No)/' || true)
if [[ -n "${PROV_LINES}" ]]; then
  while read -r line; do
    NAME=$(echo "${line}" | awk '{print $1}')
    TYPE=$(echo "${line}" | awk '{print $2}')
    info "Provider: ${NAME} (type: ${TYPE})"
  done <<< "${PROV_LINES}"
  PROV_COUNT=$(echo "${PROV_LINES}" | wc -l | tr -d ' ')
  pass "${PROV_COUNT} provider(s) configured"
else
  info "No providers configured"
fi

# --- Sandboxes ---
echo ""
echo "--- Sandboxes ---"
SANDBOXES=$(guest_ssh "openshell ${GW_FLAG} sandbox list 2>/dev/null" | strip_ansi || true)
SB_LINES=$(echo "${SANDBOXES}" | awk 'NR>1 && NF>=2 && $1 !~ /^(WARN|Error|No)/' || true)
SB_ALL_READY=true
if [[ -n "${SB_LINES}" ]]; then
  while read -r line; do
    NAME=$(echo "${line}" | awk '{print $1}')
    PHASE=$(echo "${line}" | awk '{print $NF}')
    if [[ "${PHASE}" == "Ready" ]]; then
      pass "Sandbox: ${NAME} (${PHASE})"
    else
      fail "Sandbox: ${NAME} (${PHASE})"
      SB_ALL_READY=false
    fi
  done <<< "${SB_LINES}"
else
  info "No sandboxes found"
fi

# --- Exposed services (integrations VM only) ---
if [[ "${ROLE}" == "integrations" ]]; then
  echo ""
  echo "--- Exposed Services ---"
  SERVICES=$(guest_ssh "openshell ${GW_FLAG} service list 2>/dev/null" | strip_ansi || true)
  SVC_LINES=$(echo "${SERVICES}" | awk 'NR>1 && NF>=2 && $1 !~ /^(WARN|Error|No|SANDBOX)/' || true)
  if [[ -n "${SVC_LINES}" ]]; then
    while read -r line; do
      SB_NAME=$(echo "${line}" | awk '{print $1}')
      SVC_NAME=$(echo "${line}" | awk '{print $2}')
      PORT=$(echo "${line}" | awk '{print $3}')
      info "Service: ${SB_NAME} → ${SVC_NAME} (port ${PORT})"
    done <<< "${SVC_LINES}"
    SVC_COUNT=$(echo "${SVC_LINES}" | wc -l | tr -d ' ')
    pass "${SVC_COUNT} service(s) exposed"
  else
    info "No services exposed"
  fi

  echo ""
  echo "--- Inference Proxy ---"
  PROXY_ACTIVE=$(guest_ssh "systemctl --user is-active inference-proxy.service 2>/dev/null" || true)
  if [[ "${PROXY_ACTIVE}" == "active" ]]; then
    PROXY_PORT=$(guest_ssh "systemctl --user show inference-proxy.service -p ExecStart 2>/dev/null" | grep -oE '[0-9]{5}' | head -1 || true)
    pass "Inference proxy is active${PROXY_PORT:+ (port ${PROXY_PORT})}"
  else
    fail "Inference proxy: ${PROXY_ACTIVE:-not found}"
  fi
fi

# --- Dashboard (agent VM only, skip if not deployed) ---
if [[ "${ROLE}" == "agent" ]]; then
  DASH_ACTIVE=$(guest_ssh "systemctl --user is-active openshell-dashboard.service 2>/dev/null" || true)
  if [[ "${DASH_ACTIVE}" == "inactive" || "${DASH_ACTIVE}" == "not found" || -z "${DASH_ACTIVE}" ]]; then
    echo ""
    echo "--- Dashboard ---"
    info "Dashboard not deployed (dashboard.enabled=false)"
  else
    echo ""
    echo "--- Dashboard ---"
    PROXY_ACTIVE=$(guest_ssh "systemctl --user is-active openshell-dashboard-proxy.service 2>/dev/null" || true)
    if [[ "${DASH_ACTIVE}" == "active" ]]; then
      pass "Dashboard service is active"
    else
      fail "Dashboard service: ${DASH_ACTIVE}"
    fi
    if [[ "${PROXY_ACTIVE}" == "active" ]]; then
      pass "Dashboard proxy is active"
    else
      fail "Dashboard proxy: ${PROXY_ACTIVE:-not found}"
    fi
  fi
fi

# --- K8s resources ---
echo ""
echo "--- K8s Resources ---"
JOB_STATUS=$(oc get job "${VM_NAME}-setup" -n "${NS}" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)
if [[ "${JOB_STATUS}" == "True" ]]; then
  pass "Setup Job completed"
else
  fail "Setup Job: ${JOB_STATUS:-not complete}"
fi

ROUTE=$(oc get route "${VM_NAME}-gateway" -n "${NS}" -o jsonpath='{.spec.host}' 2>/dev/null || true)
if [[ -n "${ROUTE}" ]]; then
  info "Gateway route: https://${ROUTE}"
fi

# --- Setup Job Logs ---
echo ""
echo "--- Setup Job Log Issues ---"
JOB_LOGS=$(oc logs job/"${VM_NAME}-setup" -n "${NS}" 2>/dev/null || true)
if [[ -n "${JOB_LOGS}" ]]; then
  # Only flag real failures — skip expected "not found" from cleanup operations,
  # non-fatal warnings, and sandbox remove/delete attempts on first run.
  ERRORS=$(echo "${JOB_LOGS}" | \
    grep -iE '^ERROR|exit status [1-9]|FAIL ' | \
    grep -v 'not found\|already exists\|ignored\|non-fatal\|continuing\|WARN\|gateway remove\|sandbox delete' | \
    head -5 || true)
  # Only show warnings that indicate real problems
  WARNINGS=$(echo "${JOB_LOGS}" | \
    grep -iE '^WARN:.*failed|^WARN:.*error|^WARNING:.*failed' | \
    grep -v 'lsof\|non-fatal' | \
    head -5 || true)
  if [[ -n "${ERRORS}" ]]; then
    echo "${ERRORS}" | while read -r line; do
      [[ -n "${line}" ]] && fail "Log: ${line}"
    done
  fi
  if [[ -n "${WARNINGS}" ]]; then
    echo "${WARNINGS}" | while read -r line; do
      [[ -n "${line}" ]] && info "Log: ${line}"
    done
  fi
  # Check final status line from apply_bom.py
  BOM_STATUS=$(echo "${JOB_LOGS}" | grep -oE 'Results: [0-9]+ passed, [0-9]+ failed' | tail -1 || true)
  if [[ -n "${BOM_STATUS}" ]]; then
    BOM_FAILS=$(echo "${BOM_STATUS}" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+')
    if [[ "${BOM_FAILS}" -gt 0 ]]; then
      fail "BOM: ${BOM_STATUS}"
    else
      pass "BOM: ${BOM_STATUS}"
    fi
  fi
  if [[ -z "${ERRORS}" && -z "${WARNINGS}" && -z "${BOM_STATUS}" ]]; then
    pass "No issues found in Job logs"
  elif [[ -z "${ERRORS}" && -z "${BOM_STATUS}" ]]; then
    pass "No critical errors in Job logs"
  fi
else
  info "Job logs not available (may have been cleaned up)"
fi

# --- Gateway Journal ---
echo ""
echo "--- Gateway Journal Issues ---"
GW_ERRORS=$(guest_ssh "journalctl --user -u openshell-gateway.service --no-pager -p err 2>/dev/null | tail -5" || true)
if [[ -n "${GW_ERRORS}" ]] && echo "${GW_ERRORS}" | grep -q '[a-z]'; then
  echo "${GW_ERRORS}" | while read -r line; do
    [[ -n "${line}" ]] && info "Gateway: ${line}"
  done
else
  pass "No errors in gateway journal"
fi

# --- Summary ---
echo ""
echo "============================================================"
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "${FAIL}" -eq 0 ]]; then
  echo "STATUS: ALL PASSED"
else
  echo "STATUS: INCOMPLETE"
fi
echo "============================================================"
exit "${FAIL}"
