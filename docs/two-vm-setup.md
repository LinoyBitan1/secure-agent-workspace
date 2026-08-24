# Two-VM Split Architecture Setup

This guide explains how to deploy the Secure Agent Workspace with credential isolation: an **Agent VM** runs the AI agent (OpenClaw) with no real API keys, while an **Integrations VM** runs scoped proxy services with real credentials.

## Architecture

```
┌───────────────────────────┐            ┌──────────────────────────┐
│        Agent VM           │            │   Integrations VM        │
│                           │            │                          │
│  ┌─────────────────────┐  │            │  Inference proxy         │
│  │ OpenClaw sandbox    │  │  bearer    │  (real NVIDIA key)       │
│  │ (no real keys)      │──┼───────────>│  :18083                  │
│  │                     │  │            │                          │
│  │ inference-proxy     │  │            │  gmail-read proxy        │
│  │ provider attached   │  │  bearer    │  (real OAuth token)      │
│  └─────────────────────┘  │───────────>│  :18080                  │
│                           │            │                          │
│  Placeholder creds only   │            │  Real API keys +         │
│  OIDC + mTLS gateway      │            │  credentials             │
│                           │            │  mTLS gateway            │
└───────────────────────────┘            └──────────────────────────┘
        │                                         │
        │           K8s NetworkPolicy             │
        │  (agent can only reach integ on         │
        │   ports 18080-18083)                    │
        └─────────────────────────────────────────┘
```

Both VMs use the **same Helm chart** (`charts/openshell-saw`) with different overrides.

## Prerequisites

- OpenShift cluster with OpenShift Virtualization installed
- RHBK (Keycloak) operator installed
- `oc`, `helm`, `virtctl` CLIs available
- Pre-built gateway images (run `make copy-images` or `make build-gateway-docker`)

## Deployment

### Option A: New VMs via OpenShift Virtualization

```bash
# 1. Verify prerequisites
make check-prereqs

# 2. Deploy Keycloak (if not using a shared instance)
make keycloak
make verify-keycloak  # verify instance, realm, clients, users, OIDC endpoint

# 3. Mirror images into the namespace
make copy-images

# 4. Generate SSH keys (or use existing: SSH_KEY_PATH=~/.ssh/my_key)
make generate-keys

# 5. Deploy BOM profiles + SSH secrets + inference secret
#    Add DEPLOY_GOV_PROFILES=true to deploy governance provider profiles
make deploy-config API_KEY=nvapi-YOUR-KEY DEPLOY_GOV_PROFILES=true

# 6. Deploy Integrations VM (creates bearer secret, inference proxy, BOM proxies)
make deploy-integ-vm
make verify-integ   # verify gateway, sandboxes, proxies, check logs for errors

# 7. Deploy Agent VM (waits for bearer, creates inference-proxy provider, BOM sandboxes)
make deploy-agent-vm
make verify-agent   # verify gateway, sandboxes, providers, dashboard, check logs

# 8. Run E2E test (inference flow across both VMs)
make e2e-test
```

### Option B: Pre-existing VMs

```bash
# 1. Deploy BOM profiles + secrets
make deploy-config API_KEY=nvapi-YOUR-KEY

# 2. Configure integrations VM
make deploy-integ-vm INTEG_HOST=10.0.1.6
make verify-integ

# 3. Configure agent VM (needs integ VM address)
make deploy-agent-vm AGENT_HOST=10.0.1.5 INTEG_HOST=10.0.1.6
make verify-agent
```

### Post-Deploy: Configure Gmail OAuth

```bash
# Guided mode (prompts for existing files or lets you prepare new ones)
make configure-gmail-refresh

# Local gog authorization mode (generates token export temporarily)
make configure-gmail-refresh \
  GCP_PROJECT_ID=sa-001 \
  GMAIL_ACCOUNT=you@gmail.com \
  AUTHORIZE_LOCAL=1 \
  CLIENT_JSON=$HOME/gog/client_secret.json

# Non-interactive mode
make configure-gmail-refresh \
  GCP_PROJECT_ID=sa-001 \
  GMAIL_ACCOUNT=you@gmail.com \
  CLIENT_JSON=/path/to/client_secret.json \
  TOKEN_EXPORT=/path/to/gog-token-export.json
```

For a complete project-owned OAuth + gog flow (including ownership checks and token export), see `docs/gmail-gog-openclaw-runbook.md`.

### Access the TUI / Web UI

```bash
# Login via OIDC (opens browser — auto-detects Keycloak issuer)
make login

# For an external OIDC provider, set OIDC_ISSUER (or add to .env):
#   make login OIDC_ISSUER=https://sso.example.com/realms/openshell

# Launch TUI
make tui

# Or web UI
make gui
```

## Files to Configure

### `overrides/openshell-saw.yaml` — Agent VM

```yaml
accessControl:
  owner: alice                    # your Keycloak username

role: agent
containerRuntime: docker

openshell:
  gatewayImage: "ghcr.io/nvidia/openshell/gateway:0.0.103"
  supervisorImage: "ghcr.io/nvidia/openshell/supervisor:0.0.103"
  version: "0.0.103"

networkPolicy:
  peerLabel: openshell-saw-integ  # must match integ VM Helm release name
  allowedPorts: [18080, 18081, 18082, 18083]
```

### `overrides/openshell-saw-integ.yaml` — Integrations VM

```yaml
sandboxName: saw-integ
role: integrations
containerRuntime: podman

vm:
  cores: 2
  memory: 4Gi
  diskSize: 40Gi

route:
  enabled: false

service:
  extraPorts:
    - { name: mail-read, port: 18080, targetPort: 18080 }
    - { name: slack-read, port: 18081, targetPort: 18081 }
    - { name: slack-bot, port: 18082, targetPort: 18082 }
    - { name: inference-proxy, port: 18083, targetPort: 18083 }

networkPolicy:
  peerLabel: openshell-saw        # must match agent VM Helm release name
  allowedPorts: [18080, 18081, 18082, 18083]
```

### `charts/saw-bom/values.yaml` — BOM Profiles

```yaml
profiles:
  - data-science                  # agent VM sandboxes

integrationsProfiles:
  - integrations                  # integ VM proxy sandboxes
```

### `charts/saw-bom/profiles/integrations/default/sandbox.yaml` — Integ Sandboxes

Each sandbox can specify `command` (process to start) and `exposePort` (port to expose via `openshell service expose`):

```yaml
spec:
  sandboxes:
    - name: mail-proxy
      type: generic
      enabled: true
      image: quay.io/sallyom/gmail-read-proxy:latest
      command: "/sandbox/rust-email-proxy"
      exposePort: 18080
    - name: slack-read
      enabled: false
      ...
```

## How It Works

### Setup Sequence

**Step 0: BOM profiles deployed** (before any VM)
- `deploy-bom` creates the `saw-bom-profiles` and `saw-bom-integ-profiles` ConfigMaps
- These define workspaces, providers, and sandbox configurations the VM Jobs will consume

**Integrations VM Job:**
1. Boots VM, installs OpenShell, upgrades binaries
2. Generates inter-VM bearer token → K8s Secret `inter-vm-bearer`
3. Reads BOM integ profiles from `saw-bom-integ-profiles` ConfigMap
4. Runs `apply_bom.py` → creates sandboxes, starts commands, exposes ports
5. Deploys inference reverse proxy (Python systemd service on port 18083)
6. Enables OIDC on gateway (`patch-oidc.sh`)

**Agent VM Job:**
1. Boots VM, installs OpenShell, upgrades binaries
2. Waits for gateway health check (port ready after restart)
3. Waits for `inter-vm-bearer` K8s Secret (up to 300s)
4. Registers mTLS gateway, imports `inference-proxy` provider profile
5. Creates `inference-proxy` provider with bearer credential
6. Reads BOM profiles from `saw-bom-profiles` ConfigMap
7. Runs `apply_bom.py` → creates nvidia provider (placeholder), OpenClaw sandbox
8. Attaches `inference-proxy` provider to all sandboxes
9. Enables OIDC on gateway with `OPENSHELL_ENABLE_MTLS_AUTH=true` (`patch-oidc.sh`)

### Authentication Model

The gateway supports dual auth after setup completes:

| Client | Auth Method | How |
|--------|------------|-----|
| Laptop (external) | OIDC | `openshell gateway login` → browser flow |
| VM admin (internal) | mTLS | `openshell gateway select openshell-local` |
| Setup Job | mTLS | Runs before OIDC is enabled |

This is enabled by three gateway env vars:
```
OPENSHELL_TLS_CLIENT_CA=...          # validates client certs if presented
OPENSHELL_OIDC_ISSUER=...            # enables OIDC auth
OPENSHELL_ENABLE_MTLS_AUTH=true      # re-enables mTLS alongside OIDC
```

### Inference Flow (E2E)

```
OpenClaw (agent sandbox)
  → inference-proxy provider (enforcement: passthrough)
  → http://openshell-saw-integ-gateway.openshell-agents:18083/v1/chat/completions
    Authorization: Bearer <inter-vm-bearer>
  → Integ VM Python proxy
    validates bearer SHA256, swaps for real NVIDIA API key
  → https://integrate.api.nvidia.com/v1/chat/completions
    Authorization: Bearer nvapi-...
  → response flows back
```

The agent VM never sees the real NVIDIA API key.

## Makefile Targets

| Target | Description |
|--------|-------------|
| `deploy-config` | Create SSH secrets + BOM configmap + inference secret |
| `deploy-agent-vm` | Deploy agent VM (`AGENT_HOST=` for pre-existing) |
| `deploy-integ-vm` | Deploy integ VM (`INTEG_HOST=` for pre-existing) |
| `deploy-bom` | Deploy BOM profiles configmap only |
| `delete-vms` | Delete both VMs + BOM + bearer secret |
| `e2e-test` | Run two-VM E2E verification |
| `configure-gmail-refresh` | Configure Gmail OAuth on integ VM |
| `status` | Show all OpenShell resources |

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Agent Job stuck waiting for bearer | Integ VM Job hasn't run yet | Check integ VM Job logs |
| Inference returns 401 | Bearer mismatch | Delete `inter-vm-bearer` Secret, redeploy both VMs |
| Inference returns 403 | Invalid bearer SHA256 | Same as above |
| `policy_denied` from sandbox | Provider not attached or stale policy | Detach + reattach provider |
| `CertificateRequired` from laptop | `OPENSHELL_ENABLE_MTLS_AUTH` not set | Check `patch-oidc.sh` ran |
| `missing authorization header` | OIDC enabled but no mTLS auth | Set `OPENSHELL_ENABLE_MTLS_AUTH=true` |
| Keycloak not found | Keycloak not deployed | Run `make keycloak` or set `OIDC_ISSUER` for external provider |
| `openshell gateway login` fails | OIDC issuer URL wrong | Check `make keycloak-issuer` output |
