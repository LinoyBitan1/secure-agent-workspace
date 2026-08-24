#!/usr/bin/env bash
# Phase: deploy proxy sandboxes on the integrations VM and expose them.
# Reads BOM profiles from saw-bom-integ-profiles ConfigMap (same pattern as
# setup-bom-profiles.sh on the agent side) and deploys them via apply_bom.py.
# Also deploys the inference reverse proxy and generates the inter-VM bearer.
# Only runs when ROLE=integrations.
# Expects: VM_NAME, NS, SSH_USER, WORK_DIR, OIDC_ISSUER_URL, OWNER,
#          KEYCLOAK_NS, KEYCLOAK_NAME, guest_ssh, guest_scp (functions)

if [[ "${ROLE}" != "integrations" ]]; then
  return 0 2>/dev/null || true
fi

echo "============================================================"
echo "Phase: Deploy proxy sandboxes on integrations VM"
echo "============================================================"

# All admin operations use mTLS with OU=openshell-admin cert — no OIDC token needed.
# OIDC is enabled on the gateway by patch-oidc.sh at the end of run-setup.sh.

# --- Step 1: Register mTLS gateway for internal operations ---
echo "Registering mTLS gateway..."
guest_ssh "
  export PATH=\"\$HOME/.local/bin:\$PATH\"
  openshell gateway remove openshell-local 2>/dev/null || true
  openshell gateway add https://127.0.0.1:17670 --name openshell-local --local
  openshell gateway select openshell-local
  echo 'mTLS gateway openshell-local registered'
" || true

# --- Step 3: Generate inter-VM bearer and store in K8s Secret ---
BEARER_SECRET="inter-vm-bearer"
if kubectl get secret "${BEARER_SECRET}" -n "${NS}" >/dev/null 2>&1; then
  echo "Inter-VM bearer secret already exists"
  _bearer_json="$(kubectl get secret "${BEARER_SECRET}" -n "${NS}" -o json)"
  BEARER="$(echo "${_bearer_json}" | jq -r '.data.bearer' | base64 -d)"
  BEARER_SHA256="$(echo "${_bearer_json}" | jq -r '.data.sha256' | base64 -d)"
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

# --- Step 4: Deploy BOM profiles (workspaces, providers, sandboxes) ---
BOM_CM="saw-bom-integ-profiles"
BOM_MOUNT="/tmp/bom-integ-profiles"
if kubectl get configmap "${BOM_CM}" -n "${NS}" >/dev/null 2>&1; then
  echo "BOM integ profiles detected (ConfigMap ${BOM_CM}) — applying profiles"

  mkdir -p "${BOM_MOUNT}"

  _cm_json="$(kubectl get configmap "${BOM_CM}" -n "${NS}" -o json)"
  for key in $(echo "${_cm_json}" | jq -r '.data | keys[]'); do
    echo "${_cm_json}" | jq -r --arg k "${key}" '.data[$k]' > "${BOM_MOUNT}/${key}"
  done

  # Transfer BOM app + profiles to VM (clean old data first)
  BOM_DIR="/home/${SSH_USER}/bom-profiles"
  guest_ssh "rm -rf ${BOM_DIR} && mkdir -p ${BOM_DIR}"
  for file in ${BOM_MOUNT}/*; do
    key="$(basename "$file")"
    if [[ "${key}" == "apply_bom.py" ]]; then
      guest_scp "$file" "/home/${SSH_USER}/apply_bom.py"
      continue
    fi
    IFS_OLD="${IFS}"; IFS='|'
    read -ra parts <<< "$(echo "${key}" | sed 's/__/|/g')"
    IFS="${IFS_OLD}"
    if [[ ${#parts[@]} -ge 4 ]]; then
      profile="${parts[1]}"
      ws="${parts[2]}"
      ws_file="${parts[3]}"
      guest_ssh "mkdir -p ${BOM_DIR}/${profile}/${ws}"
      guest_scp "$file" "${BOM_DIR}/${profile}/${ws}/${ws_file}"
    fi
  done

  # Resolve credentials — integ VM uses placeholder credentials
  # (real keys are injected by the proxy services, not the BOM providers)
  BOM_ENV="${WORK_DIR}/bom-integ.env"
  echo "Role=integrations: injecting placeholder credentials for BOM providers"
  for file in ${BOM_MOUNT}/*; do
    key="$(basename "$file")"
    IFS_OLD="${IFS}"; IFS='|'
    read -ra p <<< "$(echo "${key}" | sed 's/__/|/g')"
    IFS="${IFS_OLD}"
    if [[ ${#p[@]} -ge 4 && "${p[3]}" == "providers.yaml" ]]; then
      while IFS= read -r line; do
        if echo "${line}" | grep -q '^\s*- name:'; then
          pname="$(echo "${line}" | sed 's/.*name: *//' | tr -d '"' | tr -d "'")"
          env_var="$(echo "PROV_${pname}_KEY" | tr '[:lower:]' '[:upper:]' | tr '-' '_')"
          echo "${env_var}=placeholder-api-key" >> "${BOM_ENV}"
          echo "  Placeholder: ${pname}"
        fi
      done < "$file"
    fi
  done

  # Pass inter-VM bearer SHA256 so sandboxes can use it
  echo "INTER_VM_BEARER_SHA256=${BEARER_SHA256}" >> "${BOM_ENV}"
  # Optional raw bearer for BOM-level auth verification checks.
  echo "INTER_VM_BEARER=${BEARER}" >> "${BOM_ENV}"

  echo "NAMESPACE=${NS}" >> "${BOM_ENV}"

  guest_scp "${BOM_ENV}" "/home/${SSH_USER}/bom-integ.env"

  # Transfer governance profiles to VM (for provider profile import)
  GOV_PROFILES_VM="/home/${SSH_USER}/governance-profiles"
  guest_ssh "mkdir -p ${GOV_PROFILES_VM}"
  if [[ -d /governance-profiles ]]; then
    for file in /governance-profiles/*.yaml; do
      [[ -f "$file" ]] && guest_scp "$file" "${GOV_PROFILES_VM}/$(basename "$file")"
    done
    echo "Governance profiles transferred to VM"
  fi

  # Build apply_bom.py args — same pattern as agent VM's setup-bom-profiles.sh
  BOM_ARGS="--profiles-dir ${BOM_DIR} --mtls-gateway openshell-local --governance-profiles-dir ${GOV_PROFILES_VM}"

  echo "Running BOM setup on vm/${VM_NAME}..."
  guest_ssh "
    set -a; source /home/${SSH_USER}/bom-integ.env 2>/dev/null; set +a
    python3 /home/${SSH_USER}/apply_bom.py ${BOM_ARGS}
  " 2>&1

  echo "BOM integ profiles applied."
else
  echo "WARNING: No BOM integ profiles ConfigMap (${BOM_CM}) found — skipping proxy sandbox provisioning."
fi

# --- Step 5: Deploy inference reverse proxy ---
INFERENCE_PROXY_PORT="{{ .Values.inference.proxyPort | default 18083 }}"
echo "Setting up inference reverse proxy on port ${INFERENCE_PROXY_PORT}..."

# Read API key from mounted Secret first, fall back to Helm value
NVIDIA_API_KEY_VALUE=""
SECRET_PATH='/ws-secrets/{{ .Values.inference.secretName | default "inference" }}/api_key'
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
echo "  inference proxy:  ${VM_NAME}-gateway.${NS}.svc.cluster.local:${INFERENCE_PROXY_PORT}"
