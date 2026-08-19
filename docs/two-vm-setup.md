# Two-VM Split Architecture Setup

This guide explains how to deploy the Secure Agent Workspace with credential isolation: an **Agent VM** runs the AI agent (OpenClaw) with no real API keys, while an **Integrations VM** runs scoped proxy services with real credentials.

## Architecture

```
┌─────────────────────┐         ┌──────────────────────┐
│     Agent VM        │         │  Integrations VM     │
│                     │         │                      │
│  OpenClaw sandbox   │         │  Inference proxy     │
│  (no real keys)     │ bearer  │  (real NVIDIA key)   │
│                     │────────>│  :18083              │
│  inference.local    │         │                      │
│  ──> openai provider│         │  gmail-read proxy    │
│      base_url=integ │         │  :18080              │
│                     │         │                      │
│  Placeholder creds  │         │  Real API keys       │
└─────────────────────┘         └──────────────────────┘
```

Both VMs use the **same Helm chart** (`charts/openshell-saw`) with different overrides, deployed as two ArgoCD applications.

## Files to Configure

### 1. `values-prod.yaml` — Register Both ArgoCD Applications

Add the integrations VM as a second application using the same chart:

```yaml
clusterGroup:
  applications:
    saw-bom:
      name: saw-bom
      namespace: openshell-agents
      path: charts/saw-bom

    openshell-saw:                          # Agent VM
      name: openshell-saw
      namespace: openshell-agents
      path: charts/openshell-saw
      extraValueFiles:
        - /overrides/openshell-saw.yaml

    openshell-saw-integ:                    # Integrations VM
      name: openshell-saw-integ
      namespace: openshell-agents
      path: charts/openshell-saw
      extraValueFiles:
        - /overrides/openshell-saw-integ.yaml
```

### 2. `overrides/openshell-saw.yaml` — Agent VM Overrides

```yaml
# Agent VM — runs OpenClaw sandbox, no real provider credentials.
accessControl:
  owner: alice                    # <-- CHANGE: your username

role: agent                       # triggers two-VM behavior
containerRuntime: docker          # or podman

openshell:
  gatewayImage: "ghcr.io/nvidia/openshell/gateway:0.0.103"
  supervisorImage: "ghcr.io/nvidia/openshell/supervisor:0.0.103"
  version: "0.0.103"
  pipIndexUrl: ""

governance:
  enabled: false                  # enable later for policy enforcement

dashboard:
  enabled: false                  # enable if you want the web UI

networkPolicy:
  peerLabel: saw-integ            # must match integrations VM sandboxName
  allowedPorts:
    - 18080                       # gmail-read proxy
    - 18081                       # slack-read proxy
    - 18082                       # slack-bot proxy
    - 18083                       # inference proxy
```

**What to change:**
- `accessControl.owner` — set to your Keycloak username
- `openshell.*` — match the OpenShell version deployed in your cluster
- `networkPolicy.allowedPorts` — add/remove ports to match integ VM services

### 3. `overrides/openshell-saw-integ.yaml` — Integrations VM Overrides

```yaml
# Integrations VM — proxy sandboxes with real credentials.
sandboxName: saw-integ            # must match agent's networkPolicy.peerLabel
role: integrations

containerRuntime: podman
onboardCli: openclaw

openshell:
  gatewayImage: "ghcr.io/nvidia/openshell/gateway:0.0.103"
  supervisorImage: "ghcr.io/nvidia/openshell/supervisor:0.0.103"
  version: "0.0.103"
  pipIndexUrl: ""

vm:
  cores: 2
  memory: 4Gi
  diskSize: 40Gi

route:
  enabled: false
  dashboard: false
  webui: false

dashboard:
  enabled: false

governance:
  enabled: false

service:
  extraPorts:
    - name: mail-read
      port: 18080
      targetPort: 18080
    - name: slack-read
      port: 18081
      targetPort: 18081
    - name: slack-bot
      port: 18082
      targetPort: 18082
    - name: inference-proxy
      port: 18083
      targetPort: 18083

networkPolicy:
  peerLabel: saw-agent            # not used yet (for future NetworkPolicy)
  allowedPorts:
    - 18080
    - 18081
    - 18082
    - 18083
```

**What to change:**
- `service.extraPorts` — add ports for additional proxy services
- `vm.*` — adjust CPU/memory/disk for your workload

### 4. `charts/saw-bom/profiles/data-science/default/providers.yaml` — BOM Provider

This defines the inference provider that `apply_bom.py` creates on the agent VM. In two-VM mode, the credential is a placeholder — the real key lives on the integ VM.

```yaml
apiVersion: saw.redhat.com/v1alpha1
kind: Providers
metadata:
  profile: data-science
spec:
  providers:
    - name: nvidia
      type: nvidia
      model: deepseek-ai/deepseek-v4-flash-0731   # <-- CHANGE: your model
      credentialSecret: inference
      credentialSecretKey: api_key
```

**What to change:**
- `model` — the model ID your inference provider serves

### 5. Inference Secret — `values-secret.yaml` or K8s Secret

Both VMs read from the same `inference` K8s Secret (mounted at `/ws-secrets/inference/`):

- **Integrations VM**: reads `api_key` as the real inference API key for the reverse proxy
- **Agent VM**: reads `api_key` as a placeholder (BOM provider creation requires it, but the real key is on the integ VM)

Create it with the **real** API key:

```bash
kubectl create secret generic inference -n openshell-agents \
  --from-literal=api_key=nvapi-YOUR-REAL-KEY \    # <-- CHANGE: your real API key
  --from-literal=provider=nvidia \
  --from-literal=model=deepseek-ai/deepseek-v4-flash-0731
```

The integ VM's inference proxy reads this key. The agent VM's BOM setup also reads it but only uses it as a placeholder credential for the nvidia provider (inference is routed through the integ VM proxy instead).

## How It Works

### Deployment Flow

1. `git push` triggers ArgoCD sync
2. ArgoCD deploys two instances of `charts/openshell-saw`:
   - `openshell-saw` (agent) with `overrides/openshell-saw.yaml`
   - `openshell-saw-integ` (integrations) with `overrides/openshell-saw-integ.yaml`
3. Each instance creates a VM, Service, and setup Job

### Setup Job Sequence

**Integrations VM Job** (runs first or in parallel):
1. Boots VM, installs OpenShell
2. Fetches OIDC token from Keycloak (only if non-default workspaces exist)
3. Generates inter-VM bearer token, stores in K8s Secret `inter-vm-bearer`
4. Creates gmail-read proxy sandbox (profile, provider, sandbox, service expose)
5. Deploys inference reverse proxy (Python systemd service on port 18083)

**Agent VM Job:**
1. Boots VM, installs OpenShell
2. Waits for `inter-vm-bearer` K8s Secret (up to 300s, retries via backoffLimit)
3. Stores bearer on the VM
4. Imports custom `inference-proxy` provider profile (whitelists integ VM endpoint, `enforcement: passthrough`)
5. Creates `inference-proxy` provider with inter-VM bearer credential
6. Runs `apply_bom.py` (no OIDC needed for default workspace) — creates nvidia provider (placeholder), OpenClaw sandbox
7. Attaches `inference-proxy` provider to all sandboxes
### Inference Flow (E2E)

```
OpenClaw (agent sandbox)
  → http://saw-integ-gateway:18083/v1/chat/completions
    (baseUrl points directly to integ VM, not inference.local)
  → Agent supervisor (matches inference-proxy provider endpoint, enforcement: passthrough)
  → http://saw-integ-gateway.openshell-agents:18083/v1/chat/completions
    Authorization: Bearer <inter-vm-bearer>
  → Integ VM Python proxy
    validates bearer, swaps for real NVIDIA API key
  → https://integrate.api.nvidia.com/v1/chat/completions
    Authorization: Bearer nvapi-...
  → response flows back
```

The agent VM never sees the real NVIDIA API key.

## Post-Setup (Optional)

### Apply NetworkPolicy

After both VMs are running, apply network isolation:

```bash
oc apply -n openshell-agents -f deploy/two-vm/networkpolicy.yaml
```

This restricts:
- Agent VM egress: only integ VM proxy ports + DNS
- Integ VM ingress: only agent VM on proxy ports + SSH

### Switching Inference Provider

To switch from NVIDIA to OpenAI (or any OpenAI-compatible API):

1. On the integ VM, update `~/.config/secure-agent-workspace/nvidia-api-key` with the new key
2. Set the `INFERENCE_HOST` environment variable in the systemd service to the new host (e.g., `api.openai.com`)
3. Restart: `systemctl --user restart inference-proxy`

No changes needed on the agent VM.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Agent Job stuck waiting for bearer | Integ VM Job hasn't run yet | Check integ VM Job logs; ensure ArgoCD synced both apps |
| Inference returns 401 | Real API key not set on integ VM | Set `inference.apiKey` in integ overrides and redeploy |
| Inference returns 403 (Invalid bearer) | Bearer mismatch between VMs | Delete `inter-vm-bearer` Secret, restart both Jobs |
| `policy_denied` from sandbox | Provider not attached to sandbox | Run `openshell sandbox provider attach <sb> inference-proxy` |
| Integ VM port unreachable | Port not in VM masquerade spec | Check `service.extraPorts` matches the proxy port, restart VM |
