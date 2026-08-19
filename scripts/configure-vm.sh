#!/usr/bin/env bash
# Configure a pre-existing VM as an agent or integrations node.
#
# Usage:
#   ./scripts/configure-vm.sh --role agent   --host 10.0.1.5 --ssh-key ~/.ssh/id_rsa
#   ./scripts/configure-vm.sh --role integ   --host 10.0.1.6 --ssh-key ~/.ssh/id_rsa
#   ./scripts/configure-vm.sh --role agent   --vm openshell-saw --ns openshell-agents --ssh-key /tmp/key
#
# Supports two connection modes:
#   --host <ip>   : direct SSH to a VM by IP/hostname
#   --vm <name>   : use virtctl SSH to a KubeVirt VM (requires --ns)

set -euo pipefail

ROLE=""
HOST=""
VM=""
NS="openshell-agents"
SSH_KEY=""
SSH_USER="cloud-user"
INTEG_HOST=""
INTEG_PORT="18083"
API_KEY=""
OPENSHELL_VERSION="0.0.103"
INFERENCE_MODEL="deepseek-ai/deepseek-v4-flash-0731"

usage() {
  cat <<EOF
Usage: $0 --role <agent|integ> [options]

Required:
  --role <agent|integ>     VM role to configure
  --ssh-key <path>         SSH private key

Connection (one of):
  --host <ip/hostname>     Direct SSH to VM
  --vm <name>              KubeVirt VM name (uses virtctl ssh)

Options:
  --ssh-user <user>        SSH user (default: cloud-user)
  --ns <namespace>         K8s namespace for virtctl (default: openshell-agents)
  --integ-host <host>      Integ VM address (required for agent role if not using K8s service)
  --integ-port <port>      Inference proxy port (default: 18083)
  --api-key <key>          Inference API key (required for integ role)
  --model <model>          Inference model (default: deepseek-ai/deepseek-v4-flash-0731)
  --openshell-version <v>  OpenShell version (default: 0.0.103)
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role)       ROLE="$2"; shift 2 ;;
    --host)       HOST="$2"; shift 2 ;;
    --vm)         VM="$2"; shift 2 ;;
    --ssh-key)    SSH_KEY="$2"; shift 2 ;;
    --ssh-user)   SSH_USER="$2"; shift 2 ;;
    --ns)         NS="$2"; shift 2 ;;
    --integ-host) INTEG_HOST="$2"; shift 2 ;;
    --integ-port) INTEG_PORT="$2"; shift 2 ;;
    --api-key)    API_KEY="$2"; shift 2 ;;
    --model)      INFERENCE_MODEL="$2"; shift 2 ;;
    --openshell-version) OPENSHELL_VERSION="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "${ROLE}" ]] && { echo "Error: --role is required"; usage; }
[[ -z "${SSH_KEY}" ]] && { echo "Error: --ssh-key is required"; usage; }
[[ -z "${HOST}" && -z "${VM}" ]] && { echo "Error: --host or --vm is required"; usage; }

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

step() { echo -e "\n${CYAN}=== $1 ===${NC}"; }
pass() { echo -e "  ${GREEN}OK${NC}  $1"; }
fail() { echo -e "  ${RED}FAIL${NC}  $1"; exit 1; }

# SSH wrapper — works with both direct and virtctl
run_ssh() {
  if [[ -n "${HOST}" ]]; then
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR -i "${SSH_KEY}" "${SSH_USER}@${HOST}" "$1" 2>/dev/null
  else
    virtctl -n "${NS}" ssh "${SSH_USER}@vm/${VM}" \
      --identity-file="${SSH_KEY}" \
      --local-ssh-opts=-oStrictHostKeyChecking=no \
      --local-ssh-opts=-oUserKnownHostsFile=/dev/null \
      --command="$1" 2>/dev/null
  fi
}

run_scp() {
  if [[ -n "${HOST}" ]]; then
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR -i "${SSH_KEY}" "$1" "${SSH_USER}@${HOST}:$2" 2>/dev/null
  else
    virtctl -n "${NS}" scp "$1" "${SSH_USER}@vm/${VM}:$2" \
      --identity-file="${SSH_KEY}" \
      --local-ssh-opts=-oStrictHostKeyChecking=no \
      --local-ssh-opts=-oUserKnownHostsFile=/dev/null 2>/dev/null
  fi
}

TARGET="${HOST:-${VM}}"
echo "============================================="
echo " Configure VM: ${TARGET} (role=${ROLE})"
echo "============================================="

# =============================================
# Step 1: Verify SSH connectivity
# =============================================
step "1. Verify SSH connectivity"
if run_ssh "echo ssh-ok" | grep -q "ssh-ok"; then
  pass "SSH to ${TARGET}"
else
  fail "Cannot SSH to ${TARGET}"
fi

# =============================================
# Step 2: Check OpenShell is installed
# =============================================
step "2. Check OpenShell"
os_version=$(run_ssh "export PATH=\$HOME/.local/bin:\$PATH; openshell --version 2>/dev/null" || true)
if [[ -n "${os_version}" ]]; then
  pass "OpenShell installed: ${os_version}"
else
  echo "  OpenShell not found — installing..."
  run_ssh "pip3 install --user openshell==${OPENSHELL_VERSION} 2>&1 | tail -3"
  os_version=$(run_ssh "export PATH=\$HOME/.local/bin:\$PATH; openshell --version 2>/dev/null" || true)
  if [[ -n "${os_version}" ]]; then
    pass "OpenShell installed: ${os_version}"
  else
    fail "Could not install OpenShell"
  fi
fi

# =============================================
# Step 3: Check gateway is running
# =============================================
step "3. Check gateway"
gw_status=$(run_ssh "systemctl --user is-active openshell-gateway.service 2>/dev/null" || true)
if [[ "${gw_status}" == "active" ]]; then
  pass "Gateway is active"
else
  echo "  Gateway not running — check openshell-gateway.service"
  echo "  You may need to run: openshell gateway start"
fi

# =============================================
# Role-specific configuration
# =============================================

if [[ "${ROLE}" == "integ" ]]; then
  # =============================================
  # Integ: Deploy inference proxy
  # =============================================
  step "4. Deploy inference proxy"

  if [[ -z "${API_KEY}" ]]; then
    # Try reading from K8s secret
    API_KEY=$(kubectl get secret inference -n "${NS}" -o jsonpath='{.data.api_key}' 2>/dev/null | base64 -d || true)
  fi
  if [[ -z "${API_KEY}" ]]; then
    fail "API key required: pass --api-key or create the inference K8s Secret"
  fi

  # Generate bearer token
  BEARER=$(openssl rand -hex 32)
  BEARER_SHA256=$(echo -n "${BEARER}" | sha256sum | cut -d ' ' -f 1 | tr -d '\n')

  # Store bearer in K8s secret (if we have kubectl access)
  if command -v kubectl >/dev/null 2>&1; then
    kubectl create secret generic inter-vm-bearer -n "${NS}" \
      --from-literal=bearer="${BEARER}" \
      --from-literal=sha256="${BEARER_SHA256}" \
      --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null && \
      pass "inter-vm-bearer Secret created" || \
      echo "  WARN: Could not create K8s secret (no kubectl access)"
  fi

  # Deploy proxy to VM
  run_ssh "
    set -e
    mkdir -p ~/.config/secure-agent-workspace ~/.local/bin ~/.config/systemd/user
    echo -n '${API_KEY}' > ~/.config/secure-agent-workspace/nvidia-api-key
    chmod 600 ~/.config/secure-agent-workspace/nvidia-api-key
    echo -n '${BEARER_SHA256}' > ~/.config/secure-agent-workspace/inter-vm-bearer-sha256
    chmod 600 ~/.config/secure-agent-workspace/inter-vm-bearer-sha256
    echo 'Credentials stored'
  "

  # Copy the proxy script
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

  # Write proxy inline (it's embedded in setup-integ-proxies.sh but we need it standalone)
  cat > /tmp/inference-proxy.py << 'PYEOF'
#!/usr/bin/env python3
import hashlib, http.client, os, ssl, sys
from http.server import HTTPServer, BaseHTTPRequestHandler

NVIDIA_HOST = os.environ.get('INFERENCE_HOST', 'integrate.api.nvidia.com')
KEY_PATH = os.path.expanduser('~/.config/secure-agent-workspace/nvidia-api-key')
SHA_PATH = os.path.expanduser('~/.config/secure-agent-workspace/inter-vm-bearer-sha256')

with open(KEY_PATH) as f: NVIDIA_API_KEY = f.read().strip()
with open(SHA_PATH) as f: BEARER_SHA256 = f.read().strip()
print(f'Loaded API key: {NVIDIA_API_KEY[:12]}...', file=sys.stderr)
print(f'Loaded bearer SHA256: {BEARER_SHA256[:16]}...', file=sys.stderr)

class InferenceProxy(BaseHTTPRequestHandler):
    def do_POST(self):
        auth = self.headers.get('Authorization', '')
        if not auth.startswith('Bearer '):
            self.send_error(401, 'Bearer token required')
            return
        token_hash = hashlib.sha256(auth[7:].encode()).hexdigest()
        if token_hash != BEARER_SHA256:
            self.send_error(403, 'Invalid bearer')
            return
        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length) if length else b''
        ctx = ssl.create_default_context()
        conn = http.client.HTTPSConnection(NVIDIA_HOST, context=ctx, timeout=120)
        headers = {'Content-Type': self.headers.get('Content-Type', 'application/json'),
                   'Authorization': f'Bearer {NVIDIA_API_KEY}', 'Content-Length': str(len(body))}
        conn.request(self.command, self.path, body, headers)
        resp = conn.getresponse()
        resp_body = resp.read()
        self.send_response(resp.status)
        for k, v in resp.getheaders():
            if k.lower() not in ('transfer-encoding', 'connection', 'content-length', 'content-encoding'):
                self.send_header(k, v)
        self.send_header('Content-Length', str(len(resp_body)))
        self.end_headers()
        self.wfile.write(resp_body)
        conn.close()
    def do_GET(self):
        if self.path == '/healthz':
            self.send_response(200)
            self.send_header('Content-Length', '2')
            self.end_headers()
            self.wfile.write(b'ok')
            return
        self.send_error(404)
    def log_message(self, fmt, *args): print(f'[proxy] {fmt % args}', file=sys.stderr)

if __name__ == '__main__':
    port = int(os.environ.get('PORT', '18083'))
    print(f'Inference proxy listening on 0.0.0.0:{port}', file=sys.stderr)
    HTTPServer(('0.0.0.0', port), InferenceProxy).serve_forever()
PYEOF

  run_scp /tmp/inference-proxy.py ".local/bin/inference-proxy.py"

  run_ssh "
    chmod +x ~/.local/bin/inference-proxy.py
    cat > ~/.config/systemd/user/inference-proxy.service << SVCEOF
[Unit]
Description=Inference Reverse Proxy
After=network.target
[Service]
ExecStart=/usr/bin/python3 %h/.local/bin/inference-proxy.py
Restart=always
RestartSec=3
Environment=PORT=${INTEG_PORT}
[Install]
WantedBy=default.target
SVCEOF
    loginctl enable-linger \$(whoami) 2>/dev/null || true
    systemctl --user daemon-reload
    systemctl --user enable inference-proxy
    systemctl --user restart inference-proxy
    sleep 1
    curl -sf http://localhost:${INTEG_PORT}/healthz && echo 'Inference proxy healthy' || echo 'WARN: healthz failed'
  "
  pass "Inference proxy deployed on port ${INTEG_PORT}"

  echo ""
  echo "  Bearer token: ${BEARER:0:16}..."
  echo "  Bearer SHA256: ${BEARER_SHA256:0:16}..."
  echo ""
  echo "  Save this bearer — you'll need it for the agent VM configuration."

elif [[ "${ROLE}" == "agent" ]]; then
  # =============================================
  # Agent: Create inference-proxy provider
  # =============================================
  step "4. Determine integ VM address"

  if [[ -z "${INTEG_HOST}" ]]; then
    # Try K8s service name
    if [[ -n "${VM}" ]]; then
      INTEG_HOST="openshell-saw-integ-gateway.${NS}.svc.cluster.local"
      echo "  Using K8s service: ${INTEG_HOST}:${INTEG_PORT}"
    else
      echo "Error: --integ-host is required for direct SSH mode"
      echo "  Pass the integ VM's IP or hostname: --integ-host 10.0.1.6"
      exit 1
    fi
  fi

  INFERENCE_URL="http://${INTEG_HOST}:${INTEG_PORT}/v1"

  step "5. Get inter-VM bearer"
  BEARER=""
  if command -v kubectl >/dev/null 2>&1; then
    BEARER=$(kubectl get secret inter-vm-bearer -n "${NS}" -o jsonpath='{.data.bearer}' 2>/dev/null | base64 -d || true)
  fi
  if [[ -z "${BEARER}" ]]; then
    echo "  inter-vm-bearer Secret not found in K8s."
    read -rp "  Enter the bearer token from the integ VM setup: " BEARER
    if [[ -z "${BEARER}" ]]; then
      fail "Bearer token is required"
    fi
  else
    pass "Bearer retrieved from K8s Secret"
  fi

  # Store bearer on agent VM
  run_ssh "
    install -d -m 700 /home/${SSH_USER}/.config/secure-agent-workspace
    umask 077
    echo -n '${BEARER}' > /home/${SSH_USER}/.config/secure-agent-workspace/inter-vm-bearer
    chmod 600 /home/${SSH_USER}/.config/secure-agent-workspace/inter-vm-bearer
    echo 'Bearer stored'
  "

  step "6. Create inference-proxy provider"
  run_ssh "
    set -e
    export PATH=\$HOME/.local/bin:\$PATH

    # Import custom profile
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
  - host: ${INTEG_HOST}
    port: ${INTEG_PORT}
    protocol: rest
    access: read-write
    enforcement: passthrough
binaries:
  - /usr/bin/curl
  - /usr/local/bin/curl
PROFEOF
      openshell provider profile lint -f /tmp/inference-proxy-profile.yaml
      openshell provider profile import -f /tmp/inference-proxy-profile.yaml
      echo 'Imported: inference-proxy profile'
    else
      echo 'Already imported: inference-proxy profile'
    fi

    # Create provider
    if ! openshell provider get inference-proxy >/dev/null 2>&1; then
      INFERENCE_API_KEY='${BEARER}' openshell provider create \
        --name inference-proxy \
        --type inference-proxy \
        --credential INFERENCE_API_KEY
      echo 'Created: inference-proxy provider'
    else
      echo 'Already exists: inference-proxy provider'
    fi

    # Attach to all sandboxes
    for SB in \$(openshell sandbox list --output json 2>/dev/null | python3 -c 'import sys,json;[print(s[\"name\"]) for s in json.load(sys.stdin)]' 2>/dev/null); do
      openshell sandbox provider attach \${SB} inference-proxy 2>/dev/null || true
      echo \"Attached inference-proxy to \${SB}\"
    done
  "
  pass "inference-proxy provider configured"

  step "7. Update OpenClaw baseUrl"
  run_ssh "
    export PATH=\$HOME/.local/bin:\$PATH
    BEARER=\$(cat /home/${SSH_USER}/.config/secure-agent-workspace/inter-vm-bearer)
    for SB in \$(openshell sandbox list --output json 2>/dev/null | python3 -c 'import sys,json;[print(s[\"name\"]) for s in json.load(sys.stdin)]' 2>/dev/null); do
      openshell sandbox exec -n \${SB} --no-tty -- node -e \"
        const fs = require('fs');
        const p = '/sandbox/.openclaw/openclaw.json';
        try {
          const c = JSON.parse(fs.readFileSync(p, 'utf8'));
          const prov = Object.keys(c.models?.providers || {})[0];
          if (prov) {
            c.models.providers[prov].baseUrl = '${INFERENCE_URL}';
            c.models.providers[prov].apiKey = '\${BEARER}';
            fs.writeFileSync(p, JSON.stringify(c, null, 2));
            console.log('Updated ' + prov + ': baseUrl=${INFERENCE_URL}');
          }
        } catch(e) { console.log('Skip:', e.message); }
      \" 2>/dev/null || echo \"WARN: config update for \${SB} skipped (no openclaw sandbox?)\"
    done
  " || true
  pass "OpenClaw configured for integ VM inference"

  step "8. Verify connectivity"
  healthz=$(run_ssh "curl -sf --max-time 5 http://${INTEG_HOST}:${INTEG_PORT}/healthz" || true)
  if [[ "${healthz}" == "ok" ]]; then
    pass "Agent can reach integ VM proxy"
  else
    echo "  WARN: Cannot reach ${INTEG_HOST}:${INTEG_PORT} — check network connectivity"
  fi
fi

echo ""
echo "============================================="
echo -e " ${GREEN}Configuration complete: ${TARGET} (${ROLE})${NC}"
echo "============================================="
