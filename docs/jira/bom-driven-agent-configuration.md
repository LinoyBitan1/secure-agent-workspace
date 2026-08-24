# BOM-driven agent configuration for SAW workspaces

**Project:** APPENG
**Type:** Story
**Epic:** Secure Agent Workspace Validated Pattern
**Priority:** High
**Component:** RH_AI_Blueprints
**Labels:** secure_agent_workspace, bom, configuration, multi_workspace, gitops

## Summary

Implement a Bill of Materials (BOM) based configuration model for Secure Agent Workspaces, where an admin defines workspace configurations as declarative YAML files and deploys them via GitOps. A BOM profile is a tenant template — it defines what workspaces, sandboxes, providers, and policies a user or group gets. Admins create profiles for different teams/users and assign them at deploy time.

## Background

From the architecture diagram:

- **Bob** (agent app user) uses multiple agents: Hermes for personal productivity, OpenClaw for CUDA development — each running in its own isolated workspace
- **Alice** (use-case builder) defines a BOM for a Hermes personal-productivity workspace
- **Charlie** (use-case builder) defines a BOM for an OpenClaw CUDA-development workspace
- **Nic** (SAW Composer) takes Alice's BOM H + Charlie's BOM P, composes a SAW deployment, and deploys it as a VM template via GitOps

### OpenShell entity model

Based on the NVIDIA/OpenShell architecture:

- **Gateway** — one per VM, top-level entity. Manages workspaces, providers, and sandboxes.
- **Providers** — registered **globally on the gateway** (not workspace-scoped). Each provider has a name, type, and credentials. The `openshell provider create` command registers them at the gateway level.
- **Workspaces** — tenant boundary within a gateway. Each workspace has members with role-based access. A "default" workspace always exists.
- **Sandboxes** — container-based execution environments managed by the gateway. A sandbox can have **providers attached** to it (`openshell sandbox provider attach <sandbox> <provider>`), which determines what network endpoints and credentials it can access.

Key relationships:

- Providers are global → sandboxes select which providers to use via attachment
- A sandbox is not explicitly scoped to a workspace in the OpenShell CLI (binding is by naming convention)
- Multiple sandboxes per gateway are supported
- Provider attachment to sandboxes controls network policy composition (via `providers_v2_enabled`)

## Personas

| Persona | Role | What they do |
| --- | --- | --- |
| **Use-case builder** (Alice, Charlie) | Defines a BOM for a specific agent use case | Creates workspace.yaml, providers.yaml, policy.yaml, sandbox.yaml |
| **SAW Composer / Admin** (Nic) | Creates BOM profiles for users/groups and deploys via GitOps | Assembles profiles, assigns to users/teams, sizes the VM |
| **Agent app user** (Bob) | Uses the provisioned agents | Logs in via SSO, works with agents in their workspaces |

## BOM Profile Model

A **BOM profile** is a tenant template that defines what a user or group of users gets on a SAW instance. An admin creates profiles for different teams and assigns them at deploy time.

### Profile structure

```
charts/saw-bom/
├── Chart.yaml
├── values.yaml              # Profile selection and gateway-level config
└── profiles/
    ├── data-science/         # Profile for data science team
    │   ├── workspace.yaml    # Workspace definition
    │   ├── providers.yaml    # Gateway-level providers for this profile
    │   ├── sandbox.yaml      # Sandboxes and their provider attachments
    │   └── policy.yaml       # Sandbox policy
    ├── platform-eng/         # Profile for platform engineering team
    │   ├── workspace.yaml
    │   ├── providers.yaml
    │   ├── sandbox.yaml
    │   └── policy.yaml
    └── personal-dev/         # Profile for individual developer
        ├── workspace.yaml
        ├── providers.yaml
        ├── sandbox.yaml
        └── policy.yaml
```

### values.yaml (profile selection)

```yaml
# Active profiles — admin selects which profiles to deploy on this SAW instance
profiles:
  - data-science
  - platform-eng

# Or assign profiles to specific users/groups
# assignments:
#   - profile: data-science
#     users: [alice, bob]
#     groups: [ml-team]
#   - profile: platform-eng
#     users: [charlie]
#     groups: [sre-team]
```

## BOM File Schemas

### workspace.yaml

Defines the workspace (tenant boundary) within the gateway.

```yaml
apiVersion: saw.redhat.com/v1alpha1
kind: Workspace
metadata:
  name: data-science-ws
  description: "Data science workspace with Gemini and web search"
spec:
  owner: alice
  members:
    - subject: openshell-client
      role: admin
```

### providers.yaml

Defines providers to register **globally on the gateway**. These are available for attachment to any sandbox in this profile.

```yaml
apiVersion: saw.redhat.com/v1alpha1
kind: Providers
metadata:
  profile: data-science
spec:
  providers:
    - name: inference
      type: gemini
      model: gemini-2.5-flash
      credentialSecret: inference-api-key
      credentialSecretKey: api_key
    - name: brave
      type: brave
      credentialSecret: web-search
      credentialSecretKey: api_key
    - name: github
      type: github
      credentialSecret: github-token
      credentialSecretKey: api_key
```

Providers are registered at the gateway level via `openshell provider create`. For non-default workspaces, provider names are prefixed with the workspace name to avoid collisions (e.g., `data-science-ws-inference`).

### sandbox.yaml

Defines sandboxes within the workspace and specifies which providers to attach to each sandbox. A workspace can have multiple sandboxes.

```yaml
apiVersion: saw.redhat.com/v1alpha1
kind: Sandboxes
metadata:
  workspace: data-science-ws
spec:
  sandboxes:
    - name: notebook
      agent: openclaw
      image: ghcr.io/nvidia/openshell-community/sandboxes/base:latest
      providers:
        - inference
        - brave
    - name: code-assistant
      agent: opencode
      image: ghcr.io/nvidia/openshell-community/sandboxes/base:latest
      providers:
        - inference
        - github
```

Each sandbox lists the provider names to attach. The setup flow:

1. Creates the sandbox: `openshell sandbox create --name <name> --from <image>`
2. Attaches each provider: `openshell sandbox provider attach <sandbox> <provider>`

This controls which network endpoints and credentials the sandbox can access — a sandbox with only `inference` attached cannot reach `api.github.com`, even if the `github` provider exists on the gateway.

### policy.yaml

Defines the sandbox policy for the workspace. Applied via the governance interceptor during sandbox creation.

```yaml
apiVersion: saw.redhat.com/v1alpha1
kind: Policy
metadata:
  workspace: data-science-ws
spec:
  filesystem:
    readOnly: ["/etc", "/usr"]
    readWrite: ["/sandbox", "/tmp"]
  network:
    allowOutbound: true
    allowedHosts:
      - "*.googleapis.com"
      - "api.search.brave.com"
    blockedHosts:
      - "*.internal"
  tools:
    allowed: [web-search, file-read, file-write, code-execution]
    blocked: [shell-exec, network-scan]
  approvalMode: manual
```

## Deployment Flow

```
Use-case builders          Admin / SAW Composer          GitOps / Cluster

Alice creates               Nic selects profiles
  data-science profile ──┐  for this SAW instance
                         ├──▶ values.yaml:           ──▶ Git ──▶ ArgoCD
Charlie creates          │     profiles:                          │
  platform-eng profile ──┘       - data-science                  ▼
                                 - platform-eng        ┌──────────────────┐
                                                       │ SAW VM           │
                                                       │                  │
                                                       │ Gateway :17670   │
                                                       │ ├─ Providers:    │
                                                       │ │  inference     │
                                                       │ │  brave         │
                                                       │ │  github        │
                                                       │ │                │
                                                       │ ├─ WS: data-sci │
                                                       │ │  ├─ notebook   │
                                                       │ │  │  ├ inference│
                                                       │ │  │  └ brave    │
                                                       │ │  └─ code-asst  │
                                                       │ │     ├ inference│
                                                       │ │     └ github   │
                                                       │ └─ WS: plat-eng │
                                                       │    └─ sandbox    │
                                                       │       └ inference│
                                                       └──────────────────┘
```

1. **Use-case builder** creates a BOM profile (set of YAML files) for their team's use case
2. **Admin** selects which profiles to deploy on this SAW instance via `values.yaml`
3. **ArgoCD** syncs the repo to the cluster
4. **Setup Job** reads the profile BOMs, creates gateway providers, workspaces, sandboxes, and attaches providers to sandboxes
5. **Agent app user** logs in via SSO and sees their workspaces with the appropriate sandboxes

## Setup Job Flow (per profile)

```bash
# 1. Register providers globally on the gateway
for provider in profile.providers:
    openshell provider create --name <prefix>-<provider.name> \
        --type <provider.type> \
        --credential "<KEY>=<VALUE>"

# 2. Create workspace
openshell workspace create --name <workspace.name>
openshell workspace member add --workspace <workspace.name> \
    --subject openshell-client --role admin

# 3. Create sandboxes and attach providers
for sandbox in profile.sandboxes:
    openshell sandbox create --name <sandbox.name> \
        --from <sandbox.image> --no-tty -- sh -c "echo ready"

    for provider in sandbox.providers:
        openshell sandbox provider attach <sandbox.name> <prefix>-<provider>

# 4. Set default inference
openshell inference set --provider <first-provider> --model <model> --no-verify
```

## Helm Chart Structure

```
charts/saw-bom/
├── Chart.yaml
├── values.yaml
├── profiles/
│   ├── data-science/
│   │   ├── workspace.yaml
│   │   ├── providers.yaml
│   │   ├── sandbox.yaml
│   │   └── policy.yaml
│   └── platform-eng/
│       ├── workspace.yaml
│       ├── providers.yaml
│       ├── sandbox.yaml
│       └── policy.yaml
└── templates/
    ├── configmap-profiles.yaml    # Packages profile YAML files into ConfigMap
    └── _helpers.tpl
```

The `configmap-profiles.yaml` template globs profile files:

```yaml
{{- range $profile := .Values.profiles }}
{{- $files := $.Files.Glob (printf "profiles/%s/*.yaml" $profile) }}
{{- range $path, $_ := $files }}
  {{ $path | replace "/" "__" }}: |
{{ $.Files.Get $path | indent 4 }}
{{- end }}
{{- end }}
```

The setup Job mounts this ConfigMap and iterates over the active profiles.

## Acceptance Criteria

1. Admin can define a BOM profile as a directory of YAML files (workspace, providers, sandbox, policy)
2. Multiple profiles can be composed into a single SAW deployment via `values.yaml`
3. Providers are registered globally on the gateway; sandboxes specify which providers to attach
4. Each sandbox only has access to its attached providers (network policy enforced via `providers_v2_enabled`)
5. Different agent types (openclaw, opencode, hermes) can coexist in the same SAW via different sandboxes
6. Profiles are version-controlled in git and deployed via GitOps
7. Adding a new profile is: create a directory with YAML files, add profile name to `values.yaml`, push to git

## Implementation Plan

### Phase 1: Helm chart and BOM schema

- Create `charts/saw-bom/` chart with profile directory structure
- Define and validate BOM YAML schemas (workspace, providers, sandbox, policy)
- Create example profiles (data-science, platform-eng, personal-dev)
- ConfigMap template to package active profiles

### Phase 2: Setup Job integration

- Update setup Job to mount the BOM ConfigMap
- Implement profile iteration: create providers → create workspace → create sandboxes → attach providers
- Provider name prefixing for non-default workspaces
- Credential resolution from Kubernetes secrets

### Phase 3: Policy integration

- Wire policy.yaml to the governance interceptor
- Per-profile policy enforcement during sandbox creation
- Policy hot-reload via GitOps

### Phase 4: Tooling

- BOM validation CLI or pre-commit hook
- Profile scaffolding command (`make create-profile NAME=my-team`)
- Documentation for use-case builders creating profiles

## Open Questions

- **Shared providers**: Can two profiles share the same provider (e.g., both use Gemini) without duplicating credentials? Option: allow a `shared-providers.yaml` at the top level.
- **Profile assignment**: How does the admin assign profiles to specific users vs. groups? Is this handled at the OIDC/Keycloak level or in the BOM?
- **Sandbox naming**: With multiple sandboxes per workspace, how do we handle the 19-character sandbox name limit? Truncation strategy needed.
- **Hot-reload**: Can we update a profile (e.g., add a provider) without recreating the VM? The setup Job currently runs once at VM creation.

## Dependencies

- OpenShell multi-workspace support (gateway manages multiple workspaces)
- `sandbox provider attach/detach` support (confirmed working)
- `providers_v2_enabled` for network policy composition via provider profiles
- Governance interceptor for policy enforcement
