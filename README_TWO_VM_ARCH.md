# Two-VM Split Architecture

Credential isolation for the Secure Agent Workspace: an **Agent VM** runs the AI agent with no real API keys, while an **Integrations VM** runs proxy services with real credentials.

```
Agent VM (no real keys)              Integrations VM (real keys)
┌──────────────────────┐             ┌──────────────────────┐
│  OpenClaw sandbox    │   bearer    │  Inference proxy     │
│  baseUrl → integ:    │────────────>│  :18083 → NVIDIA API │
│           18083      │             │                      │
│  Placeholder creds   │             │  gmail-read proxy    │
│                      │             │  :18080              │
└──────────────────────┘             └──────────────────────┘
```

## Prerequisites

- OpenShift cluster with `oc` CLI logged in
- OpenShift Virtualization operator installed
- RHBK (Keycloak) operator installed
- Golden VM image built (`make build-gateway-docker` or `make build-gateway-podman`)
- SSH keypair generated (`make generate-keys`)
- Inference API key (e.g., NVIDIA `nvapi-...`)

---

## Option A: Manual Deployment (no ArgoCD)

### Step 1: Install operators and Keycloak

```bash
# Verify operators are installed
make check-prereqs

# Deploy Keycloak (creates realm + client)
make keycloak

# Generate SSH keys (if not done)
make generate-keys
```

### Step 2: Create the inference Secret

```bash
make inference-secret API_KEY=nvapi-YOUR-REAL-KEY
```

Defaults to `PROVIDER=nvidia MODEL=deepseek-ai/deepseek-v4-flash-0731`. Override as needed:

```bash
make inference-secret API_KEY=sk-... PROVIDER=openai MODEL=gpt-4o
```

### Step 3: Deploy the Agent VM

```bash
make deploy-agent
```

This runs:
```
helm upgrade --install openshell-saw charts/openshell-saw \
  -n openshell-agents -f overrides/openshell-saw.yaml
```

The Agent VM boots, installs OpenShell, and waits for the inter-VM bearer Secret from the Integrations VM.

### Step 4: Deploy the Integrations VM

```bash
make deploy-integ
```

This runs:
```
helm upgrade --install openshell-saw-integ charts/openshell-saw \
  -n openshell-agents -f overrides/openshell-saw-integ.yaml
```

The Integrations VM boots, installs OpenShell, creates the inter-VM bearer Secret, deploys the gmail-read proxy and inference reverse proxy.

### Step 5: Deploy BOM profiles and configure both VMs

```bash
make deploy-bom
```

This runs:
```
helm upgrade --install saw-bom charts/saw-bom -n openshell-agents
```

The BOM chart creates a ConfigMap with workspace/provider/sandbox definitions. Both setup Jobs read from it:
- Agent VM creates the OpenClaw sandbox with `baseUrl` pointing to the integ VM
- Agent VM attaches the `inference-proxy` provider for endpoint whitelisting

### Step 6: Follow setup progress

```bash
# Agent VM setup logs
make saw-logs OPENSHELL_SAW_NAME=openshell-saw

# Integrations VM setup logs
make saw-logs OPENSHELL_SAW_NAME=openshell-saw-integ
```

### Step 7: Run E2E test

```bash
./scripts/test-two-vm-e2e.sh
```

### Step 8: Use the agent

```bash
# SSH into agent VM
make saw-ssh OPENSHELL_SAW_NAME=openshell-saw

# Launch OpenClaw TUI
make saw-tui OPENSHELL_SAW_NAME=openshell-saw
```

### Teardown

```bash
make delete-vms
```

---

## Option B: Automated Deployment (ArgoCD / Validated Pattern)

### Step 1: Configure

Edit these files:

| File | What to set |
|------|------------|
| `overrides/openshell-saw.yaml` | `accessControl.owner`, `containerRuntime` |
| `overrides/openshell-saw-integ.yaml` | `service.extraPorts` (add proxy ports) |
| `values-secret.yaml` | `inference` secret with real API key |

### Step 2: Deploy

```bash
# Install the validated pattern (deploys everything via ArgoCD)
./pattern.sh make install
```

ArgoCD deploys three applications:
- `saw-bom` — BOM profiles ConfigMap
- `openshell-saw` — Agent VM (uses `overrides/openshell-saw.yaml`)
- `openshell-saw-integ` — Integrations VM (uses `overrides/openshell-saw-integ.yaml`)

### Step 3: Monitor

```bash
# Watch ArgoCD sync
oc get applications -n openshift-gitops

# Watch setup Jobs
kubectl get jobs -n openshell-agents -w
```

### Step 4: Test

```bash
./scripts/test-two-vm-e2e.sh
```

### Teardown

```bash
./pattern.sh make uninstall
```

---

## Option C: Configure Pre-existing VMs

If you already have two VMs running (created outside this repo), you can configure them as agent + integrations nodes.

### Step 1: Configure the Integrations VM

```bash
# Using VM IP directly
make configure-integ INTEG_HOST=10.0.1.6 API_KEY=nvapi-YOUR-KEY SSH_KEY_PATH=~/.ssh/id_rsa

# Or using a KubeVirt VM name
make configure-integ API_KEY=nvapi-YOUR-KEY
```

This SSHes into the VM and:
- Verifies OpenShell is installed
- Deploys the inference reverse proxy (systemd service)
- Generates the inter-VM bearer token
- Stores the bearer in a K8s Secret

### Step 2: Configure the Agent VM

```bash
# Using VM IP directly
make configure-agent AGENT_HOST=10.0.1.5 INTEG_HOST=10.0.1.6 SSH_KEY_PATH=~/.ssh/id_rsa

# Or using KubeVirt VM names (auto-detects integ service)
make configure-agent
```

This SSHes into the VM and:
- Retrieves the inter-VM bearer (from K8s Secret or prompts)
- Imports the `inference-proxy` provider profile
- Creates the `inference-proxy` provider
- Attaches it to all sandboxes
- Updates OpenClaw's baseUrl to point to the integ VM

### Step 3: Test

```bash
make e2e-test
```

---

## Makefile Targets Reference

**Deploy**

| Target | Description |
|--------|-------------|
| `make deploy-agent` | Deploy Agent VM |
| `make deploy-integ` | Deploy Integrations VM |
| `make deploy-bom` | Deploy BOM profiles |

**Access**

| Target | Description |
|--------|-------------|
| `make saw-ssh OPENSHELL_SAW_NAME=<vm>` | SSH into a VM |
| `make saw-logs OPENSHELL_SAW_NAME=<vm>` | Follow setup Job logs |
| `make saw-list` | List all sandboxes |
| `make tui` | Launch OpenClaw TUI (auto-configures gateway) |
| `make gui` | Open OpenClaw web UI (auto-configures gateway) |

**Configure pre-existing VMs**

| Target | Description |
|--------|-------------|
| `make configure-integ INTEG_HOST=<ip> API_KEY=<key>` | Configure existing VM as integ node |
| `make configure-agent AGENT_HOST=<ip> INTEG_HOST=<ip>` | Configure existing VM as agent node |

**Test and Teardown**

| Target | Description |
|--------|-------------|
| `make e2e-test` | Run E2E test |
| `make delete-vms` | Delete both VMs and BOM |
| `make saw-delete OPENSHELL_SAW_NAME=<vm>` | Delete a single VM |

---

## Configuration Reference

### `overrides/openshell-saw.yaml` (Agent VM)

```yaml
role: agent                       # triggers two-VM behavior
accessControl:
  owner: alice                    # your username
containerRuntime: docker          # or podman
governance:
  enabled: false
networkPolicy:
  peerLabel: saw-integ            # must match integ VM sandboxName
  allowedPorts: [18080, 18081, 18082, 18083]
```

### `overrides/openshell-saw-integ.yaml` (Integrations VM)

```yaml
sandboxName: saw-integ            # must match agent peerLabel
role: integrations
containerRuntime: podman
service:
  extraPorts:                     # each proxy gets a port
    - {name: mail-read, port: 18080, targetPort: 18080}
    - {name: inference-proxy, port: 18083, targetPort: 18083}
networkPolicy:
  peerLabel: saw-agent
  allowedPorts: [18080, 18081, 18082, 18083]
```

### Inference Secret

```bash
make inference-secret API_KEY=nvapi-YOUR-KEY
```

In the automated (ArgoCD) flow, this Secret is created by the External Secrets Operator from Vault via `values-secret.yaml`. The make target creates the same Secret shape manually for standalone deployments.

The integ VM reads `api_key` for the reverse proxy. The agent VM uses it as a placeholder.

---

## Manual Verification and Testing

### Check running sandboxes

```bash
# Agent VM — should show "notebook" sandbox in Ready state
virtctl -n openshell-agents ssh cloud-user@vm/openshell-saw \
  --identity-file=~/.generated-ssh-keys/sandbox-ssh \
  --local-ssh-opts=-oStrictHostKeyChecking=no \
  --command="export PATH=\$HOME/.local/bin:\$PATH && openshell sandbox list && echo '---' && openshell provider list"

# Integrations VM — should show "gmail-read" sandbox
virtctl -n openshell-agents ssh cloud-user@vm/openshell-saw-integ \
  --identity-file=~/.generated-ssh-keys/sandbox-ssh \
  --local-ssh-opts=-oStrictHostKeyChecking=no \
  --command="export PATH=\$HOME/.local/bin:\$PATH && openshell sandbox list && echo '---' && openshell provider list && echo '---' && systemctl --user status inference-proxy --no-pager | head -5"
```

### Set up the inference API key

The inference proxy on the integrations VM needs a real API key. If you didn't create the `inference` K8s Secret before deployment, or want to update the key:

```bash
# Option 1: Create/update the K8s Secret (used on next Job run)
kubectl create secret generic inference -n openshell-agents \
  --from-literal=api_key=nvapi-YOUR-REAL-KEY \
  --from-literal=provider=nvidia \
  --from-literal=model=deepseek-ai/deepseek-v4-flash-0731 \
  --dry-run=client -o yaml | kubectl apply -f -

# Option 2: Set the key directly on the running integ VM (immediate, no redeploy)
virtctl -n openshell-agents ssh cloud-user@vm/openshell-saw-integ \
  --identity-file=~/.generated-ssh-keys/sandbox-ssh \
  --local-ssh-opts=-oStrictHostKeyChecking=no \
  --command="echo -n 'nvapi-YOUR-REAL-KEY' > ~/.config/secure-agent-workspace/nvidia-api-key && chmod 600 ~/.config/secure-agent-workspace/nvidia-api-key && systemctl --user restart inference-proxy && sleep 1 && curl -sf http://localhost:18083/healthz && echo ' OK'"
```

### Verify the inference proxy is working

```bash
# Get the inter-VM bearer token
BEARER=$(kubectl get secret inter-vm-bearer -n openshell-agents -o jsonpath='{.data.bearer}' | base64 -d)

# Test from the agent VM host (bypasses sandbox, tests proxy directly)
virtctl -n openshell-agents ssh cloud-user@vm/openshell-saw \
  --identity-file=~/.generated-ssh-keys/sandbox-ssh \
  --local-ssh-opts=-oStrictHostKeyChecking=no \
  --command="curl -s --max-time 30 http://openshell-saw-integ-gateway.openshell-agents.svc.cluster.local:18083/v1/chat/completions -H 'Content-Type: application/json' -H 'Authorization: Bearer ${BEARER}' -d '{\"model\":\"deepseek-ai/deepseek-v4-flash-0731\",\"messages\":[{\"role\":\"user\",\"content\":\"Say OK\"}],\"max_completion_tokens\":5}'"
```

You should see a JSON response with `"content":"OK"`.

### Launch the OpenClaw TUI

```bash
make tui
```

This auto-configures the gateway and connects to the agent VM's sandbox. No SSH, no gateway login needed.

For the web UI:

```bash
make gui
```

Or manually:

```bash
# SSH into the agent VM
virtctl -n openshell-agents ssh cloud-user@vm/openshell-saw \
  --identity-file=~/.generated-ssh-keys/sandbox-ssh \
  --local-ssh-opts=-oStrictHostKeyChecking=no

# Inside the VM:
export PATH=$HOME/.local/bin:$PATH
openshell sandbox connect notebook
# Inside the sandbox:
export PATH=/opt/openclaw/node_modules/.bin:$PATH
openclaw
```

Type a question like "Who is the president of America?" — the request routes through the integrations VM proxy to NVIDIA. The agent VM never sees the real API key.

### Run the automated E2E test

```bash
make e2e-test
```

This runs 11 checks: VM health, gateway, proxy, bearer, providers, sandbox connectivity, inference E2E, and security (no real keys on agent VM).

---

## How Inference Routing Works

```
OpenClaw (agent sandbox)
  curl http://integ-gateway:18083/v1/chat/completions
    → Agent supervisor (matches inference-proxy provider endpoint)
    → Integ VM K8s Service :18083
      → Python reverse proxy
        validates inter-VM bearer
        swaps Authorization header for real NVIDIA API key
      → https://integrate.api.nvidia.com/v1/chat/completions
        → response flows back
```

The agent VM has zero real API keys. The inter-VM bearer is only for proxy authentication.

---

## Switching Inference Provider

To switch from NVIDIA to OpenAI (or any OpenAI-compatible API):

```bash
# On the integ VM:
ssh cloud-user@integ-vm

# Update the API key
echo -n 'sk-your-openai-key' > ~/.config/secure-agent-workspace/nvidia-api-key

# Update the systemd service to point to OpenAI
systemctl --user edit inference-proxy.service
# Add: Environment=INFERENCE_HOST=api.openai.com

# Restart
systemctl --user restart inference-proxy
```

No changes needed on the agent VM.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Agent Job stuck "waiting for bearer" | Integ VM Job hasn't created the Secret yet | Wait — agent retries via `backoffLimit`. Check integ Job logs |
| Inference returns 401 | Real API key not set | Update the `inference` K8s Secret with your real key |
| Inference returns 403 | Bearer mismatch | Delete `inter-vm-bearer` Secret, restart both Jobs |
| `policy_denied` from sandbox | Provider not attached or wrong enforcement | Run `openshell sandbox provider attach notebook inference-proxy` on agent VM |
| Integ proxy port unreachable | Port not in VM masquerade spec | Check `service.extraPorts` matches, restart VM |
| OpenClaw baseUrl is inference.local | apply_bom.py didn't get INFERENCE_BASE_URL | Redeploy with updated BOM ConfigMap |
