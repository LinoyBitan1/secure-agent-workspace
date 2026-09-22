# BOM-Driven Agent Configuration — Architecture

## End-to-End Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        GitOps (ArgoCD)                                  │
│                                                                         │
│  values-prod.yaml ──► saw-bom chart ──► ConfigMap (saw-bom-profiles)    │
│  overrides/*.yaml ──► openshell-saw chart ──► Setup Job + VM            │
└─────────────────────────┬───────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     Setup Job (Fedora Pod)                              │
│                                                                         │
│  1. Install deps (openssh-clients, jq, openssl)                         │
│  2. Wait for VM ready (SSH accessible)                                  │
│  3. Upgrade OpenShell binaries (gateway/supervisor/CLI → 0.0.99)        │
│  4. Patch OIDC issuer + restart gateway                                 │
│  5. Extract BOM profiles from ConfigMap                                 │
│  6. Resolve credentials from K8s secrets                                │
│  7. Fetch OIDC token (alice/alice via Keycloak)                         │
│  8. SSH into VM → run apply_bom.py                                      │
│  9. Dashboard setup (Keycloak redirect URI + systemd services)          │
└─────────────────────────┬───────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────────────────┐
│              apply_bom.py (runs on Gateway VM)                          │
│                                                                         │
│  Phase 1: Gateway Setup                                                 │
│  ├── Configure OIDC token                                               │
│  ├── Register mTLS gateway (openshell-local)                            │
│  ├── Grant workspace access (openshell-client → admin)                  │
│  └── Enable providers_v2                                                │
│                                                                         │
│  Phase 2: Deploy Profiles                                               │
│  ├── For each workspace:                                                │
│  │   ├── Create workspace (via OIDC gateway)                            │
│  │   ├── Create providers (nvidia, brave, etc.)                         │
│  │   └── Create sandboxes (nemoclaw, openclaw, generic)                 │
│  │       ├── nemoclaw: onboard → sandbox create                         │
│  │       │             → openclaw gateway start                         │
│  │       ├── openclaw: sandbox create → wait Ready                      │
│  │       │             → openclaw onboard (custom NVIDIA provider)      │
│  │       │             → openclaw gateway start                         │
│  │       └── generic:  sandbox create                                   │
│  │                                                                      │
│  Phase 3: Verify                                                        │
│  └── Check all workspaces, providers, sandboxes → PASS/FAIL             │
└─────────────────────────────────────────────────────────────────────────┘
```

## Component Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                    OpenShift Cluster                                 │
│                                                                      │
│  ┌─────────────┐   ┌──────────────┐  ┌────────────────┐              │
│  │  Keycloak    │  │  Vault +     │  │  Governance    │              │
│  │  (OIDC/SSO)  │  │  ESO         │  │  Interceptor   │              │
│  │              │  │  (Secrets)   │  │  (Policy Sign) │              │
│  └──────┬───────┘  └──────┬───────┘  └───────┬────────┘              │
│         │                 │                  │                       │
│         ▼                 ▼                  ▼                       │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │              Gateway VM (KubeVirt / openshell-saw)             │  │
│  │                                                                │  │
│  │  ┌─────────────────────────────────────┐                       │  │
│  │  │  OpenShell Gateway (port 17670)     │                       │  │
│  │  │  ├── Provider management            │                       │  │
│  │  │  ├── Sandbox lifecycle              │                       │  │
│  │  │  ├── Inference routing              │                       │  │
│  │  │  ├── Governance policy enforcement  │                       │  │
│  │  │  └── Network proxy (per sandbox)    │                       │  │
│  │  └──────────┬──────────────────────────┘                       │  │
│  │             │                                                  │  │
│  │     ┌───────┴────────────────────────────────┐                 │  │
│  │     │           Docker Containers            │                 │  │
│  │     │                                        │                 │  │
│  │     │  ┌─────────────────────────────────┐   │                 │  │
│  │     │  │  cuda-sandbox (nemoclaw)        │   │                 │  │
│  │     │  │  Image: nemoclaw-sandbox:latest │   │                 │  │
│  │     │  │  Workspace: cuda-dev            │   │                 │  │
│  │     │  │  Provider: nvidia               │   │                 │  │
│  │     │  │  OpenClaw Gateway (:18789)      │   │                 │  │
│  │     │  │  ├── TUI: make nemoclaw-tui     │   │                 │  │
│  │     │  │  └── GUI: make nemoclaw-gui     │   │                 │  │
│  │     │  └─────────────────────────────────┘   │                 │  │
│  │     │                                        │                 │  │
│  │     │  ┌─────────────────────────────────┐   │                 │  │
│  │     │  │  notebook (openclaw)             │  │                 │  │
│  │     │  │  Image: openclaw-openshell:latest│  │                 │  │
│  │     │  │  Workspace: default              │  │                 │  │
│  │     │  │  Provider: nvidia                │  │                 │  │
│  │     │  │  OpenClaw Gateway (:18789)       │  │                 │  │
│  │     │  │  ├── TUI: make openclaw-tui      │  │                 │  │
│  │     │  │  └── GUI: make openclaw-gui      │  │                 │  │
│  │     │  └─────────────────────────────────┘   │                 │  │
│  │     │                                        │                 │  │
│  │     │  ┌─────────────────────────────────┐   │                 │  │
│  │     │  │  toolbox (generic)              │   │                 │  │
│  │     │  │  Image: base                    │   │                 │  │
│  │     │  │  Workspace: cuda-dev            │   │                 │  │
│  │     │  │  Provider: nvidia               │   │                 │  │
│  │     │  └─────────────────────────────────┘   │                 │  │
│  │     └────────────────────────────────────────┘                 │  │
│  └────────────────────────────────────────────────────────────────┘  │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │  Routes (OpenShift)                                            │  │
│  │  ├── openshell-saw-gateway  → VM:17670  (OpenShell API)        │  │
│  │  ├── openshell-saw-dashboard → VM:8090  (Dashboard UI)         │  │
│  │  └── openshell-saw-webui    → VM:8080  (OAuth2 Proxy)          │  │
│  └────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
```

## BOM Profile Structure

```
charts/saw-bom/profiles/
└── data-science/                    # Profile name
    ├── cuda-dev/                    # Workspace
    │   ├── workspace.yaml           # Workspace metadata + enabled flag
    │   ├── providers.yaml           # Provider definitions (nvidia)
    │   └── sandbox.yaml             # Sandbox definitions (nemoclaw, generic)
    └── default/                     # Workspace
        ├── workspace.yaml           # Uses existing 'default' workspace
        ├── providers.yaml           # Provider definitions (nvidia, brave)
        └── sandbox.yaml             # Sandbox definitions (openclaw)
```

## Sandbox Types

| Type | Image | Use Case | Gateway | Entrypoint |
|------|-------|----------|---------|------------|
| nemoclaw | nemoclaw-sandbox:latest | NemoClaw-managed agent with inference | OpenClaw via sandbox exec | NemoClaw supervisor |
| openclaw | openclaw-openshell:latest | Standalone OpenClaw agent | OpenClaw via sandbox exec | CSB entrypoint (wrapped) |
| generic | base | Plain sandbox for tools/scripts | None | OpenShell supervisor |

## Inference Routing

```
User → OpenClaw TUI/GUI
         │
         ▼
  OpenClaw Gateway (inside sandbox, port 18789)
         │
         │ model: nvidia/nvidia/nemotron-3-super-120b-a12b
         │ baseUrl: https://inference.local/v1
         │
         ▼
  OpenShell Network Proxy (10.200.0.1:3128)
         │
         │ Injects NVIDIA_API_KEY from provider credential
         │ Enforces governance network policy
         │
         ▼
  integrate.api.nvidia.com:443
```

## Security Boundaries

```
┌─────────────────────────────────────────────────┐
│ Governance Layer                                │
│ ├── Signed policy per sandbox                   │
│ ├── Network policies (endpoint allowlist)       │
│ ├── Filesystem policies (read-only / read-write)│
│ ├── Process policies (run_as_user: sandbox)     │
│ └── Landlock enforcement (best_effort)          │
├─────────────────────────────────────────────────┤
│ Credential Boundary                             │
│ ├── API keys in Vault / K8s secrets             │
│ ├── OpenShell provider stores credentials       │
│ ├── Proxy injects credentials at request time   │
│ └── No credentials inside sandbox containers    │
├─────────────────────────────────────────────────┤
│ Identity Boundary                               │
│ ├── OIDC via Keycloak (alice/alice)             │
│ ├── mTLS for internal gateway communication     │
│ ├── Gateway token for OpenClaw Control UI       │
│ └── Sandbox user (UID 65532) — non-root         │
└─────────────────────────────────────────────────┘
```

## Make Targets

| Target | Description | Example |
|--------|-------------|---------|
| `nemoclaw-tui` | NemoClaw sandbox TUI | `OPENSHELL_SAW_NAME=openshell-saw SANDBOX_NAME=cuda-sandbox make nemoclaw-tui` |
| `openclaw-tui` | OpenClaw sandbox TUI | `OPENSHELL_SAW_NAME=openshell-saw SANDBOX_NAME=notebook make openclaw-tui` |
| `nemoclaw-gui` | NemoClaw sandbox GUI | `... GUI_PORT=18789 make nemoclaw-gui` |
| `openclaw-gui` | OpenClaw sandbox GUI | `... GUI_PORT=18790 make openclaw-gui` |
| `openshell-saw-tui` | Alias for nemoclaw-tui | `make openshell-saw-tui` |
| `openshell-saw-gui` | Alias for nemoclaw-gui | `make openshell-saw-gui` |
