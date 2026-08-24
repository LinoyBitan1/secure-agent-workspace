# Replace upstream NVIDIA OpenShell images with ODH/quay.io builds

**Project:** APPENG
**Type:** Story
**Epic:** Secure Agent Workspace Validated Pattern
**Priority:** High
**Component:** RH_AI_Blueprints
**Labels:** secure_agent_workspace, openshell, odh, images, supply_chain

## Summary

Replace the upstream NVIDIA OpenShell images (`ghcr.io/nvidia/openshell/*`) and upstream PyPI CLI package with the Red Hat ODH builds from `quay.io/opendatahub/odh-openshell-*` and the RHAIV pip index. This aligns the pattern with Red Hat's supported supply chain and enables consistent versioning across the stack.

## Background

The Secure Agent Workspace currently uses upstream NVIDIA images as a workaround for NemoClaw's Docker-driver binary check. However, **OpenShell itself does not require Docker-driver binaries** — the gateway, supervisor, and CLI work correctly with any driver (Docker, Podman, Kubernetes) via `OPENSHELL_DRIVERS` env var.

The "missing Docker-driver binaries" error is a **NemoClaw-specific preflight check** in `install-openshell.sh`, not an OpenShell limitation. Since the current setup flow uses `openshell provider create` + `openshell sandbox create` as the primary path (with nemoclaw onboard as a non-fatal attempt that falls back), ODH images can be used directly.

### Current state

| Component | Current (upstream) | Target (ODH) |
|-----------|-------------------|--------------|
| Gateway | `ghcr.io/nvidia/openshell/gateway:0.0.96` | `quay.io/opendatahub/odh-openshell-gateway:<latest>` |
| Supervisor | `ghcr.io/nvidia/openshell/supervisor:0.0.96` | `quay.io/opendatahub/odh-openshell-supervisor:<latest>` |
| CLI (pip) | `openshell==0.0.96` (PyPI) | `openshell==<latest>+rhaiv.0` (RHAIV pip index) |

### What works with ODH images today

- `openshell-gateway` — works, no Docker-driver binaries needed
- `openshell-supervisor` — works, no Docker-driver binaries needed
- `openshell` CLI (pip) — works, no Docker-driver binaries needed
- `openshell provider create` — works
- `openshell sandbox create --from <image>` — works
- TUI, GUI, dashboard — all work

### Known blocker with ODH images

The ODH supervisor (v0.0.96-rhaiv.0) has a **Permission denied** issue on `/sandbox/.openclaw/openclaw.json` and `/sandbox/.profile`:

```
read failed: Error: EACCES: permission denied, open '/sandbox/.openclaw/openclaw.json'
```

The ODH supervisor's privilege-dropping mechanism prevents the sandbox process from reading root-owned config files inside `/sandbox/`. This blocks:
- OpenClaw from starting (can't read its config)
- NemoClaw onboard (can't configure the sandbox)
- The TUI/GUI dashboard (openclaw gateway can't start)

The upstream NVIDIA supervisor (0.0.96 and 0.0.99) does not have this issue — the Docker-driver handles privilege dropping differently.

**This must be resolved in the ODH supervisor build before switching.** Options:
1. ODH team fixes the supervisor privilege-dropping to match upstream behavior
2. The nemoclaw sandbox image build adds `RUN chown -R sandbox:sandbox /sandbox` (already in our chained BuildConfig but does not fully fix the issue — the supervisor re-creates files as root at runtime)
3. Use upstream supervisor image alongside ODH gateway/CLI (hybrid — not ideal for supply chain)

### Other differences with ODH images

- `nemoclaw onboard` preflight will fail with "missing Docker-driver binaries" and downgrade attempt
- The `NEMOCLAW_OPENSHELL_GATEWAY_BIN` env var workaround prevents the downgrade
- nemoclaw onboard still fails at step 4 (inference route API incompatibility) — same as today
- Fallback to `openshell provider create` handles it — setup completes as PARTIAL

## Acceptance Criteria

1. All three OpenShell components (gateway, supervisor, CLI) use ODH/quay.io builds
2. `openshell-gateway --version` shows the RHAIV version
3. `openshell --version` shows the RHAIV version
4. All existing functionality works: provider create, sandbox create, TUI, GUI, dashboard
5. Version is configurable via `values.yaml` for upgrades
6. Setup completes successfully (OK or PARTIAL — same as today)

## Implementation

This is a **values-only change** — no code changes required.

### Files to update

| File | Change |
|------|--------|
| `charts/openshell-saw/values.yaml` | Update `openshell.gatewayImage`, `openshell.supervisorImage`, `openshell.version`, `openshell.pipIndexUrl` |

### Target values.yaml

Use the **latest available ODH build**. Check `quay.io/opendatahub` for the most recent tags.

```yaml
openshell:
  # Check: https://quay.io/repository/opendatahub/odh-openshell-gateway?tab=tags
  #        https://quay.io/repository/opendatahub/odh-openshell-supervisor?tab=tags
  gatewayImage: "quay.io/opendatahub/odh-openshell-gateway:<latest-tag>"
  supervisorImage: "quay.io/opendatahub/odh-openshell-supervisor:<latest-tag>"
  version: "<matching-pip-version>"
  pipIndexUrl: "https://packages.redhat.com/api/pypi/public-rhai/rhoai/3.6-EA1/cpu-ubi9-test/simple/"
```

## Verification Steps

1. Update `values.yaml` with latest ODH images
2. Deploy on cluster (`make pattern-install` or ArgoCD sync)
3. Verify `openshell-gateway --version` shows RHAIV version inside the VM
4. Verify `openshell --version` shows RHAIV version inside the VM
5. Verify setup completes (OK or PARTIAL)
6. Verify `openshell provider list` shows configured provider
7. Verify `openshell sandbox list` shows Ready sandbox
8. Verify TUI works (`make openshell-saw-tui`)
9. Verify GUI works (`make openshell-saw-gui`)
10. Verify external CLI works (`openshell --gateway-insecure sandbox list`)

## Notes

- The `NEMOCLAW_OPENSHELL_GATEWAY_BIN` and `NEMOCLAW_OPENSHELL_SANDBOX_BIN` env vars should remain in the setup script — they prevent NemoClaw from downgrading when it runs its preflight check
- The supervisor binary path may differ between upstream (`/openshell-sandbox`) and ODH images — verify during implementation
- The RHAIV pip index URL may change across RHOAI releases — parameterize it in values.yaml (already done)
