# Refactor BOM setup into a standalone Python application

**Project:** APPENG
**Type:** Story
**Epic:** Secure Agent Workspace Validated Pattern
**Priority:** High
**Component:** RH_AI_Blueprints
**Labels:** secure_agent_workspace, bom, refactor, python

## Summary

Consolidate the BOM-driven setup flow into a single Python application that replaces the shell scripts in `configmap-scripts.yaml`. The Python app handles everything: gateway setup, CLI installation, OIDC config, credential resolution, workspace/provider/sandbox creation, and nemoclaw/openclaw onboarding.

## Current state (problems)

- `configmap-scripts.yaml` is 1400+ lines with 7 inlined shell scripts
- BOM setup logic is split between shell (gateway setup, CLI install, OIDC, credentials) and Python (`apply-bom.py`)
- Heredoc syntax breaks in Helm templates (indentation issues)
- Credential resolution uses fragile bash YAML parsing
- No error recovery or structured logging
- Adding features requires editing a massive template file

## Target state

```
charts/saw-bom/
├── app/
│   ├── __init__.py
│   ├── cli.py              # Entry point: parse args, run phases
│   ├── gateway.py           # GatewayClient: openshell CLI wrapper, gateway switching
│   ├── credentials.py       # CredentialResolver: secrets dir, env vars
│   ├── workspace.py         # WorkspaceManager: create, grant members
│   ├── provider.py          # ProviderManager: create with credentials
│   ├── sandbox.py           # SandboxManager: nemoclaw/openclaw/generic onboarding
│   ├── profile.py           # BomProfile: parse profile directories
│   └── setup.py             # SetupManager: CLI install, OIDC, mTLS gateway
├── profiles/
│   └── data-science/...
└── templates/
    └── configmap-bom.yaml
```

## Classes

### GatewayClient

Wraps `openshell` CLI calls. Handles gateway selection (OIDC vs mTLS).

```python
class GatewayClient:
    def __init__(self, oidc_gw, mtls_gw, dry_run=False)
    def select(self, gateway_name)
    def run(self, args) -> (returncode, stdout, stderr)
    def with_oidc(self, fn)   # context: switch to OIDC, run fn, switch back
    def with_mtls(self, fn)   # context: switch to mTLS, run fn, switch back
```

### SetupManager

Handles one-time VM setup before BOM apply.

```python
class SetupManager:
    def install_nemoclaw_cli(self, cli_image)
    def configure_oidc(self, token, issuer, client_id, gateway_name)
    def register_mtls_gateway(self, name, endpoint)
    def enable_providers_v2(self)
    def grant_default_workspace_access(self, subject)
```

### CredentialResolver

Resolves provider credentials from mounted secrets and env vars.

```python
class CredentialResolver:
    def __init__(self, secrets_dirs, env_prefix="PROV_")
    def resolve(self, provider_name, provider_type, secret_name, secret_key) -> str|None
```

### BomProfile

Parses a profile directory into workspaces.

```python
class BomProfile:
    def __init__(self, profile_dir)
    @property
    def workspaces(self) -> list[Workspace]

class Workspace:
    name: str
    providers: list[Provider]
    sandboxes: list[Sandbox]

class Sandbox:
    name: str
    type: str   # nemoclaw, openclaw, generic
    agent: str  # openclaw, hermes
    image: str
    providers: list[str]  # provider names to attach
```

### SandboxManager

Handles sandbox creation per type.

```python
class SandboxManager:
    def create(self, sandbox: Sandbox, providers: dict, credentials: dict)
    def _onboard_nemoclaw(self, sandbox, provider, credential)
    def _start_openclaw_gateway(self, sandbox_name, dashboard_route)
    def _create_generic(self, sandbox)
```

## Deployment

The Python app is packaged in the `saw-bom` ConfigMap alongside the profile YAML files. The setup Job mounts it, SCPs to the VM, and runs:

```bash
python3 /home/cloud-user/bom-app/cli.py \
  --profiles-dir /home/cloud-user/bom-profiles \
  --oidc-gateway openshell \
  --mtls-gateway openshell-local
```

The `configmap-scripts.yaml` BOM path becomes just:

```bash
if [[ "${BOM_ENABLED:-}" == "true" ]]; then
  python3 "${HOME}/bom-app/cli.py" \
    --profiles-dir "${BOM_PROFILES_DIR}" \
    --oidc-gateway "${OPENSHELL_GATEWAY:-openshell}" \
    --mtls-gateway "openshell-local"
  exit 0
fi
```

## Phases

1. **Extract** — move `apply-bom.py` logic into class structure, add `SetupManager`
2. **Consolidate** — move gateway setup, CLI install, OIDC config from shell into Python
3. **Test** — unit tests for profile parsing and credential resolution
4. **Deploy** — update ConfigMap template and Job to use the new app
