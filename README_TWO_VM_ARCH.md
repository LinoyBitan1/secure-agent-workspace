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

### Step 1: Prerequisites and Keycloak

```bash
# Verify operators are installed
make check-prereqs

# Deploy Keycloak (creates realm + clients + test users)
make keycloak
make verify-keycloak   # verify instance, realm, clients, users, OIDC endpoint

# Mirror images into the namespace
make copy-images

# Generate SSH keys (if not done)
make generate-keys
```

### Step 2: Deploy BOM profiles + secrets

```bash
# Creates SSH secrets, BOM ConfigMap, and inference secret
make deploy-config API_KEY=nvapi-YOUR-REAL-KEY

# To also deploy governance provider profiles (for sandbox policy enforcement):
make deploy-config API_KEY=nvapi-YOUR-REAL-KEY DEPLOY_GOV_PROFILES=true
```

Defaults to `PROVIDER=nvidia MODEL=deepseek-ai/deepseek-v4-flash-0731`. Override as needed:

```bash
make deploy-config API_KEY=sk-... PROVIDER=openai MODEL=gpt-4o DEPLOY_GOV_PROFILES=true
```

Governance profiles define per-sandbox network and binary policies (e.g., `gmail-read` restricts the mail proxy to `gmail.googleapis.com:443`). When enabled, BOM sandboxes with `providerProfile: gmail-read` will automatically have the profile imported and attached.

To deploy the full governance interceptor (optional):

```bash
make deploy-governance
```

If you are **not** deploying the interceptor, set `GOVERNANCE_ENABLED=false` to skip the interceptor health check during VM setup:

```bash
export GOVERNANCE_ENABLED=false
# Or add to .env file
```

### Step 3: Deploy the Integrations VM

```bash
make deploy-integ-vm
make verify-integ      # verify gateway, sandboxes, proxies, check logs
```

The Integrations VM boots, installs OpenShell, creates the inter-VM bearer Secret, deploys the inference reverse proxy.

### Step 4: Deploy the Agent VM

```bash
make deploy-agent-vm
make verify-agent      # verify gateway, sandboxes, providers, dashboard, check logs
```

The Agent VM boots, installs OpenShell, waits for the inter-VM bearer Secret, creates the inference-proxy provider, and runs BOM profiles.

### Step 5: Verify and test

```bash
# Follow setup logs (if still running)
make saw-logs OPENSHELL_SAW_NAME=openshell-saw
make saw-logs OPENSHELL_SAW_NAME=openshell-saw-integ

# Run E2E test
make e2e-test
```

### Step 6: Use the agent

```bash
# Login via OIDC (opens browser)
make login

# Launch TUI
make tui

# Or web UI
make gui
```

### Teardown

```bash
# Delete both VMs + BOM + secrets
make delete-all
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

### Step 3: Verify and test

```bash
make verify-integ
make verify-agent
make e2e-test
```

---

## Makefile Targets Reference

**Deploy**

| Target | Description |
|--------|-------------|
| `make deploy-config API_KEY=...` | Deploy BOM + SSH secrets + inference secret |
| `make deploy-config ... DEPLOY_GOV_PROFILES=true` | Also deploy governance provider profiles |
| `make deploy-agent-vm` | Deploy Agent VM |
| `make deploy-integ-vm` | Deploy Integrations VM |
| `make deploy-bom` | Deploy BOM profiles only |
| `make deploy-gov-profiles` | Deploy governance profiles only |

**Verify**

| Target | Description |
|--------|-------------|
| `make verify-keycloak` | Verify Keycloak: instance, realm, clients, users, OIDC |
| `make verify-integ` | Verify Integrations VM: gateway, sandboxes, proxies, logs |
| `make verify-agent` | Verify Agent VM: gateway, sandboxes, providers, dashboard, logs |
| `make verify` | Verify both VMs |

**Access**

| Target | Description |
|--------|-------------|
| `make login` | Authenticate via OIDC (opens browser) |
| `make tui` | Launch OpenClaw TUI (auto-configures gateway) |
| `make gui` | Open OpenClaw web UI (auto-configures gateway) |
| `make saw-ssh OPENSHELL_SAW_NAME=<vm>` | SSH into a VM |
| `make saw-logs OPENSHELL_SAW_NAME=<vm>` | Follow setup Job logs |

**Configure pre-existing VMs**

| Target | Description |
|--------|-------------|
| `make deploy-integ-vm INTEG_HOST=<ip>` | Configure existing VM as integ node |
| `make deploy-agent-vm AGENT_HOST=<ip>` | Configure existing VM as agent node |

**Test and Teardown**

| Target | Description |
|--------|-------------|
| `make e2e-test` | Run E2E test |
| `make delete-vms` | Delete both VMs + BOM + bearer secret |
| `make delete-all` | Delete everything (VMs + Keycloak + images + secrets) |
| `make status` | Show all OpenShell resources |

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

## Verification

Use the built-in verify targets to check each component after deployment:

```bash
# Verify Keycloak: instance health, realm, clients, users, OIDC endpoint
make verify-keycloak

# Verify Integrations VM: gateway, sandboxes, exposed services, inference proxy, logs
make verify-integ

# Verify Agent VM: gateway, sandboxes, providers, dashboard, logs
make verify-agent

# Verify both VMs at once
make verify

# Full E2E test (inference flow across both VMs)
make e2e-test
```

### Use the agent

```bash
# Login via OIDC
make login

# Launch TUI or web UI
make tui
make gui
```

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
