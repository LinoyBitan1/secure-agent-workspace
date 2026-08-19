#!/usr/bin/env bash
# Phase: deploy proxy sandboxes on the integrations VM and expose them.
# Fetches a short-lived OIDC token from Keycloak for admin operations.
# Only runs when ROLE=integrations.
# Expects: VM_NAME, NS, SSH_USER, WORK_DIR, OIDC_ISSUER_URL, OWNER,
#          KEYCLOAK_NS, KEYCLOAK_NAME, guest_ssh, guest_scp (functions)

if [[ "${ROLE}" != "integrations" ]]; then
  return 0 2>/dev/null || true
fi

echo "============================================================"
echo "Phase: Deploy proxy sandboxes on integrations VM"
echo "============================================================"

GMAIL_READ_IMAGE="${GMAIL_READ_IMAGE:-quay.io/sallyom/forge-gmail-read-proxy@sha256:dfb6ba5c61745c564035ea49b4e95ed2b21132b49c279c046e8e15e5e9b00f20}"

# --- Step 1: Fetch OIDC token from Keycloak ---
echo "Fetching OIDC token from Keycloak..."
OIDC_TOKEN=""
if [[ -n "${OIDC_ISSUER_URL}" && -n "${OWNER}" ]]; then
  KEYCLOAK_SECRET="$(kubectl get secret ${KEYCLOAK_NAME}-initial-admin \
    -n ${KEYCLOAK_NS} \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
  if [[ -n "${KEYCLOAK_SECRET}" ]]; then
    TOKEN_RESPONSE=$(curl -sk -X POST \
      "${OIDC_ISSUER_URL}/protocol/openid-connect/token" \
      -d "grant_type=password" \
      -d "client_id=openshell-cli" \
      -d "username=${OWNER}" \
      -d "password=${OWNER}" \
      -d "scope=openid" 2>/dev/null || true)
    OIDC_TOKEN=$(echo "${TOKEN_RESPONSE}" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
    if [[ -n "${OIDC_TOKEN}" ]]; then
      echo "  OIDC token obtained for ${OWNER}"
    else
      echo "  WARN: failed to get OIDC token — proxy setup may fail"
    fi
  fi
fi

# --- Step 2: Configure gateway with OIDC token ---
echo "Configuring gateway access..."
if [[ -n "${OIDC_TOKEN}" ]]; then
  guest_ssh "
    export PATH=\"\$HOME/.local/bin:\$PATH\"
    # Write OIDC token for the OIDC gateway (same as apply_bom.py)
    TOKEN_DIR=\$HOME/.config/openshell/gateways/openshell
    mkdir -p \${TOKEN_DIR}
    cat > \${TOKEN_DIR}/oidc_token.json <<TOKEOF
{\"access_token\": \"${OIDC_TOKEN}\", \"issuer\": \"${OIDC_ISSUER_URL}\", \"client_id\": \"openshell-cli\"}
TOKEOF
    chmod 600 \${TOKEN_DIR}/oidc_token.json
    echo 'OIDC token written for gateway openshell'
    openshell gateway select openshell
    openshell settings set --global --key providers_v2_enabled --value true --yes 2>&1 || true
    openshell workspace member add --workspace default --subject openshell-client --role admin 2>&1 || true
  " || true
else
  echo "  WARN: no OIDC token — using mTLS gateway directly"
  guest_ssh "
    export PATH=\"\$HOME/.local/bin:\$PATH\"
    openshell gateway select openshell-local 2>/dev/null || true
  " || true
fi

# --- Step 3: Generate inter-VM bearer and store in K8s Secret ---
BEARER_SECRET="inter-vm-bearer"
if kubectl get secret "${BEARER_SECRET}" -n "${NS}" >/dev/null 2>&1; then
  echo "Inter-VM bearer secret already exists"
  BEARER_SHA256="$(kubectl get secret "${BEARER_SECRET}" -n "${NS}" -o jsonpath='{.data.sha256}' | base64 -d)"
else
  echo "Generating inter-VM bearer..."
  BEARER="$(openssl rand -hex 32)"
  BEARER_SHA256="$(echo -n "${BEARER}" | sha256sum | cut -d ' ' -f 1 | tr -d '\n')"
  kubectl create secret generic "${BEARER_SECRET}" -n "${NS}" \
    --from-literal=bearer="${BEARER}" \
    --from-literal=sha256="${BEARER_SHA256}"
  echo "  Bearer secret stored in secret/${BEARER_SECRET}"
fi
echo "  Bearer SHA256: ${BEARER_SHA256:0:16}..."

# --- Steps 4-6: Import profile, create provider+sandbox, expose (single SSH session) ---
echo "Setting up gmail-read: profile, provider, sandbox, forward..."
if ! guest_ssh "
  set -e
  export PATH=\"\$HOME/.local/bin:\$PATH\"

  # Import provider profile (required — OpenShell rejects unknown types)
  if ! openshell provider profile export gmail-read >/dev/null 2>&1; then
    cat > /tmp/gmail-read-profile.yaml <<'PROFEOF'
id: gmail-read
display_name: Gmail read proxy
description: Gmail read-only proxy on the integrations VM
category: data
inference_capable: false
credentials:
  - name: access_token
    env_vars: [GMAIL_ACCESS_TOKEN]
    required: true
    auth_style: bearer
    header_name: authorization
discovery:
  credentials: [access_token]
endpoints:
  - host: gmail.googleapis.com
    port: 443
    protocol: rest
    enforcement: enforce
    access: read-only
PROFEOF
    openshell provider profile lint -f /tmp/gmail-read-profile.yaml
    openshell provider profile import -f /tmp/gmail-read-profile.yaml
    echo '  Imported: gmail-read profile'
  else
    echo '  Already imported: gmail-read profile'
  fi

  # Create provider
  if ! openshell provider get gmail-read >/dev/null 2>&1; then
    openshell provider create --name gmail-read --type gmail-read \
      --credential GMAIL_ACCESS_TOKEN=poc-bootstrap-token
    echo '  Created: gmail-read provider'
  else
    echo '  Already exists: gmail-read provider'
  fi

  # Write sandbox policy
  cat > /tmp/gmail-read-policy.yaml <<'POLEOF'
version: 1
filesystem_policy:
  include_workdir: true
  read_only:
    - /usr
    - /lib
    - /lib64
    - /etc
  read_write:
    - /sandbox
    - /tmp
    - /dev/null
landlock:
  compatibility: best_effort
process:
  run_as_user: \"1001\"
  run_as_group: \"1001\"
POLEOF

  # Create sandbox
  if ! openshell sandbox get gmail-read >/dev/null 2>&1; then
    openshell sandbox create --name gmail-read \
      --from '${GMAIL_READ_IMAGE}' \
      --provider gmail-read \
      --policy /tmp/gmail-read-policy.yaml \
      --env INTER_VM_BEARER_SHA256=${BEARER_SHA256} \
      --no-tty -- /bin/sh -lc 'nohup /sandbox/rust-email-proxy >/tmp/gmail-read-proxy.log 2>&1 </dev/null &'
    echo '  Created: gmail-read sandbox'
  else
    echo '  Already exists: gmail-read sandbox'
  fi

  # Expose via service expose (declarative, survives gateway restarts)
  openshell service expose gmail-read 18080 gmail-read-svc 2>&1 || \
    echo 'WARN: service expose failed'
  openshell service list 2>&1 || true
"; then
  echo "ERROR: gmail-read proxy setup failed"
  exit 1
fi

# --- Step 7: Deploy inference reverse proxy ---
INFERENCE_PROXY_PORT="{{ .Values.inference.proxyPort | default 18083 }}"
echo "Setting up inference reverse proxy on port ${INFERENCE_PROXY_PORT}..."

# Read API key from mounted Secret first, fall back to Helm value
NVIDIA_API_KEY_VALUE=""
SECRET_PATH="/ws-secrets/{{ .Values.inference.secretName | default "inference" }}/api_key"
if [[ -f "${SECRET_PATH}" ]]; then
  NVIDIA_API_KEY_VALUE="$(cat "${SECRET_PATH}")"
  echo "  Inference API key read from Secret"
fi
if [[ -z "${NVIDIA_API_KEY_VALUE}" ]]; then
  NVIDIA_API_KEY_VALUE="{{ .Values.inference.apiKey }}"
fi
if [[ -z "${NVIDIA_API_KEY_VALUE}" ]]; then
  echo "ERROR: No inference API key — set inference.apiKey or create the inference Secret with an api_key field"
  exit 1
fi

guest_ssh "
  set -e
  mkdir -p ~/.config/secure-agent-workspace ~/.local/bin ~/.config/systemd/user

  # Store credentials for the proxy
  echo -n '${NVIDIA_API_KEY_VALUE}' > ~/.config/secure-agent-workspace/nvidia-api-key
  chmod 600 ~/.config/secure-agent-workspace/nvidia-api-key
  echo -n '${BEARER_SHA256}' > ~/.config/secure-agent-workspace/inter-vm-bearer-sha256
  chmod 600 ~/.config/secure-agent-workspace/inter-vm-bearer-sha256

  # Write inference proxy script
  cat > ~/.local/bin/inference-proxy.py << 'PYEOF'
#!/usr/bin/env python3
import hashlib, http.client, json, os, ssl, sys
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
  chmod +x ~/.local/bin/inference-proxy.py

  # Create systemd user service
  cat > ~/.config/systemd/user/inference-proxy.service << SVCEOF
[Unit]
Description=Inference Reverse Proxy
After=network.target

[Service]
ExecStart=/usr/bin/python3 %h/.local/bin/inference-proxy.py
Restart=always
RestartSec=3
Environment=PORT=${INFERENCE_PROXY_PORT}

[Install]
WantedBy=default.target
SVCEOF

  loginctl enable-linger \$(whoami) 2>/dev/null || true
  systemctl --user daemon-reload
  systemctl --user enable inference-proxy
  systemctl --user restart inference-proxy
  sleep 1
  curl -sf http://localhost:${INFERENCE_PROXY_PORT}/healthz && echo '  Inference proxy healthy' || exit 1
"
if [[ $? -ne 0 ]]; then
  echo "ERROR: inference proxy setup failed"
  exit 1
fi

echo "Integrations VM proxy setup complete."
echo "  gmail-read proxy: ${VM_NAME}-gateway.${NS}.svc.cluster.local:18080"
echo "  inference proxy:  ${VM_NAME}-gateway.${NS}.svc.cluster.local:${INFERENCE_PROXY_PORT}"
