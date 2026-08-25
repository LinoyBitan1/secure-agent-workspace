# Secure Agent Workspace — End-to-End Deployment Guide

## Overview

The Secure Agent Workspace (SAW) deploys a per-user AI agent sandbox running inside a KubeVirt virtual machine on OpenShift. The deployment is fully GitOps-driven via Red Hat Validated Patterns and ArgoCD.

Each sandbox provides an OpenShell gateway with OIDC authentication, governance policy enforcement, and a web-based agent interface — all managed declaratively from Git.

## Architecture

```text
                         +-----------------------+
                         |  OpenShift Cluster     |
                         |                        |
   User (CLI/Browser)    |  +------------------+  |
         |               |  | Keycloak (OIDC)  |  |
         | OIDC login    |  +--------+---------+  |
         v               |           |             |
   +-----+------+        |  +--------v---------+  |
   | TLS Route  +------->|  | KubeVirt VM      |  |
   | (passthru) |        |  |  openshell-saw   |  |
   +------------+        |  |                  |  |
                         |  |  Gateway :17670  |  |
                         |  |  Dashboard :8080 |  |
                         |  |  Agent :18789    |  |
                         |  |  Docker sandboxes|  |
                         |  +--------+---------+  |
                         |           |             |
                         |  +--------v---------+  |
                         |  | Governance        |  |
                         |  | Interceptor :18081|  |
                         |  +------------------+  |
                         |                        |
                         |  +------------------+  |
                         |  | Vault + ESO      |  |
                         |  | (secrets)        |  |
                         |  +------------------+  |
                         +-----------------------+
```

## ArgoCD Applications

All applications are defined in `values-prod.yaml` and deployed by the Validated Patterns framework. ArgoCD syncs them automatically — dependencies are resolved at runtime via init containers and wait loops, not explicit ordering.

| Application | Namespace | Purpose |
| --- | --- | --- |
| `openshift-cnv` | `openshift-cnv` | KubeVirt operator for VM lifecycle |
| `vault` | `vault` | HashiCorp Vault for secret storage |
| `openshift-external-secrets` | `external-secrets` | External Secrets Operator |
| `pattern-secrets` | `openshell-agents` | ExternalSecret CRs that pull from Vault |
| `openshell-keycloak` | `openshell-agents` | Keycloak OIDC provider + realm |
| `governance-policy` | `openshell-agents` | Policy ConfigMaps (profiles + sandbox policy) |
| `governance-interceptor` | `openshell-agents` | gRPC interceptor deployment |
| `openshell-saw` | `openshell-agents` | VM + setup Job + routes + services |

**Operator Subscriptions:** OpenShift Virtualization, RHBK (Keycloak), External Secrets Operator, RHDH, OpenShift AI.

## Deployment Phases

### Phase 1: Golden VM Image

The `openshell-gateway-image` BuildConfig creates a Fedora 44 qcow2 image with:

- Docker CE (podman removed), Node.js, Python3, cloud-init, openssh, qemu-guest-agent
- `cloud-user` with sudo access and Docker group membership
- Systemd user service for the OpenShell gateway (`openshell-gateway.service`)
- First-boot setup service (`openshell-gateway-setup.service`) that starts Docker, enables the gateway, and configures mTLS certs

The image is pushed to an internal ImageStream (`openshell-gateway:latest`) and used as a DataSource for cloning VM disks.

Build trigger: `make build-gateway-docker` (Docker variant) or `make build-gateway-podman` (Podman variant), or automatically via ArgoCD.

### Phase 2: Keycloak + OIDC

RHBK operator deploys Keycloak. A `KeycloakRealmImport` creates the `openshell` realm with:

- **Clients:**
  - `openshell-cli` — public client, PKCE with S256, device code flow, 24h token lifetime
  - `openshell-dashboard` — public client, PKCE, redirect URIs registered dynamically per sandbox
- **Users:** developer, admin, alice, bob (test accounts)
- **Roles:** `openshell-user`, `openshell-admin`
- **Token mappers:** realm roles in access tokens, audience mapper so dashboard tokens are accepted by the gateway

### Phase 3: Secrets

Three ExternalSecret CRs pull from Vault:

| Secret | Vault Path | Content |
| --- | --- | --- |
| `openshell-aap-ssh` | `<prefix>/ssh` | SSH private key + public key |
| `openshell-ssh-pubkey` | `<prefix>/ssh` | SSH public key (for cloud-init) |
| `inference` | `<prefix>/inference` | Provider type, model, API key |

On the Validated Pattern path, OpenShell's Vault credential driver (enabled in
`overrides/openshell-saw.yaml`) stores a **copy** of provider API keys under
the dedicated KV mount `openshell/` after the first `openshell provider create
--credential`. Runtime resolve uses that copy. The ESO secrets
(`inference`, `web-search`) remain the first-boot seed from
`secret/data/hub/...`. Rotating only `hub/inference` does not live-update
OpenShell; either update the `openshell/` object or re-run provider
create/update with `--credential`. `./pattern.sh make install` runs
`make setup-vault-gateway-auth` after Vault is up and `load-secrets` has
finished (not ArgoCD). Rerun with `make setup-vault-gateway-auth` if the
mount or k8s role needs to be reapplied.

### Phase 4: Governance Policy

The `governance-policy` chart creates two ConfigMaps from files in the chart:

- `governance-interceptor-policy` — sandbox filesystem/process policy from `policy.yaml`
- `governance-interceptor-profiles` — all `profiles/*.yaml` auto-discovered via Helm glob

The `governance-interceptor` chart deploys the interceptor pod, which mounts both ConfigMaps and serves them over gRPC. See [governance-interceptor.md](governance-interceptor.md) for the full enforcement flow.

### Phase 5: VM Boot + Setup

#### Cloud-init

The VM boots from a clone of the golden image. Cloud-init (rendered by the `cloudinit-sandbox.yaml` template) configures:

- SSH authorized keys for `cloud-user`
- `/etc/openshell/gateway.env` — bind address, port, TLS paths, driver config
- `/etc/openshell/gateway.toml` — OIDC issuer/audience, governance interceptor endpoint and bindings; may include `[openshell.credential_drivers.vault]` when the Vault driver is enabled
- When Vault is enabled, the VM mounts a ServiceAccount token disk (`gwsa`) for Kubernetes auth
- Starts `openshell-gateway-setup.service` which bootstraps the gateway user service

#### Setup Job

A Kubernetes Job (`openshell-saw-setup`) runs after the VM boots. It:

1. **Waits for secrets** (init container) — blocks until ESO has created `openshell-aap-ssh` and `inference` secrets
2. **Bootstraps golden image** — creates DataVolume/DataSource if missing, waits for CDI import
3. **Creates cloud-init Secret** — substitutes the SSH public key into the template ConfigMap
4. **Waits for VM** — DataVolume ready, VMI running, SSH reachable, cloud-init complete
5. **Installs binaries** — pulls gateway and supervisor container images via Docker on the VM, extracts binaries, installs openshell CLI via pip
6. **Restarts gateway** with new binaries
7. **Copies scripts** to VM — `run-create.sh`, `setup-nemoclaw.sh`, `configure-vertex-user.sh`, `setup-dashboard.sh`
8. **Fetches OIDC token** from Keycloak for the sandbox owner
9. **Registers dashboard redirect URI** on the Keycloak client via Admin API
10. **Executes `run-create.sh`** on the VM, which:
    - Configures inference provider with API credentials
    - Registers mTLS local gateway (`openshell-local`) and OIDC remote gateway
    - Runs `nemoclaw onboard` in externally-supervised mode
    - Creates sandbox from the configured image
    - Starts the agent web UI (openclaw) inside the sandbox on port 18789
    - Injects SSH public key into the sandbox
    - Starts the dashboard + OAuth2 proxy as Docker containers

## Network Architecture

### Routes

| Route | Target Port | TLS | Purpose |
| --- | --- | --- | --- |
| `<name>-gateway` | 17670 | Passthrough | gRPC gateway (CLI + API) |
| `<name>-dashboard` | 18789 | Passthrough | Openclaw agent web UI |
| `<name>-webui` | 8080 | Edge | OpenShell Dashboard (via oauth2-proxy) |

### Internal Connectivity

| From | To | Protocol | Purpose |
| --- | --- | --- | --- |
| Gateway (VM) | Governance interceptor (pod) | gRPC over HTTP | Policy enforcement |
| Gateway (VM) | Keycloak (pod) | HTTPS | OIDC token validation |
| Setup Job (pod) | VM | SSH (via virtctl) | Binary install, configuration |
| Dashboard (VM) | Gateway (VM) | gRPC over TLS | Agent operations |
| Gateway (VM) | `vault.vault.svc:8200` | HTTPS/HTTP | Kubernetes auth + KV credential storage |

### Authentication Flows

- **CLI:** `openshell gateway login` triggers OIDC device code flow via Keycloak. Token is cached locally and sent as a bearer token on gRPC calls.
- **Dashboard:** OAuth2 proxy handles browser-based OIDC login, proxies authenticated requests to the dashboard backend, which connects to the gateway.
- **Internal (nemoclaw):** mTLS client certificate, registered as `openshell-local` gateway on the VM.

## Operator Quick Reference

### Prerequisites

```bash
make check-prereqs          # Verify operators and CLI tools
```

### Initial Setup

```bash
make generate-keys              # Create SSH keypair
make ssh-secret                 # Create Kubernetes secrets from keys
make build-gateway-docker       # Build Docker golden VM image (or: make copy-images)
make keycloak                   # Deploy Keycloak (if not via ArgoCD)
# Pattern path: included in `make install`. Rerun:
make setup-vault-gateway-auth
```

### Sandbox Lifecycle

```bash
# Create
make openshell-saw-create OPENSHELL_SAW_NAME=my-saw

# Access — NemoClaw sandbox
OPENSHELL_SAW_NAME=my-saw SANDBOX_NAME=cuda-sandbox make nemoclaw-tui
OPENSHELL_SAW_NAME=my-saw SANDBOX_NAME=cuda-sandbox GUI_PORT=18789 make nemoclaw-gui

# Access — OpenClaw sandbox
OPENSHELL_SAW_NAME=my-saw SANDBOX_NAME=notebook make openclaw-tui
OPENSHELL_SAW_NAME=my-saw SANDBOX_NAME=notebook GUI_PORT=18790 make openclaw-gui

# SSH into a sandbox
make openshell-saw-ssh OPENSHELL_SAW_NAME=my-saw
make login OPENSHELL_SAW_NAME=my-saw

# Monitor
make openshell-saw-list
make openshell-saw-logs OPENSHELL_SAW_NAME=my-saw
make status

# Delete
make openshell-saw-delete OPENSHELL_SAW_NAME=my-saw
make delete-all              # Remove everything
```

### Governance

```bash
make governance-demo OPENSHELL_SAW_NAME=my-saw
make governance-list-profiles OPENSHELL_SAW_NAME=my-saw
make governance-add-profile OPENSHELL_SAW_NAME=my-saw PROFILE_NAME=github
make governance-remove-profile OPENSHELL_SAW_NAME=my-saw PROFILE_NAME=github
make governance-create-profile OPENSHELL_SAW_NAME=my-saw \
  PROFILE_NAME=jira PROFILE_FILE=/path/to/jira.yaml
```

### Testing

```bash
make test                    # Headless E2E test
```
