# Secure Agent Workspace — Status Report (Aug 6, 2026)

## Completed

1. **Short-term Docker runtime solution** — Replaced Podman with Docker CE in the gateway VM to unblock NemoClaw CLI onboarding. NemoClaw explicitly requires Docker Engine and rejects Podman. This is a temporary measure until NemoClaw adds native Podman support (upstream epic #7744).

2. **End-to-end deployment of NemoClaw working with GUI and TUI** — Full automated provisioning flow via Validated Pattern: golden image build → VM boot → OpenShell gateway/supervisor install → provider configuration → sandbox creation from pre-built image → TUI and GUI accessible via NemoClaw CLI and OpenClaw dashboard.

3. **Integrated the OpenShell UI (dashboard)** — OpenClaw web dashboard accessible via OpenShift route with token-based authentication. TUI accessible via `openshell sandbox exec` and `make openshell-saw-tui`.

4. **Dual-gateway authentication** — Gateway supports both mTLS (internal/NemoClaw) and OIDC (external CLI access via route) simultaneously, enabling secure local operations and remote management.

5. **Image versioning and traceability** — All images (gateway, sandbox, CLI) tagged with OpenShell version in quay.io for supply chain traceability. `copy-images` mirrors versioned tags to internal registry.


## Blockers

1. **Red Hat OpenShell build (ODH) missing Docker-driver binaries** — The ODH builds (`quay.io/opendatahub/odh-openshell-gateway`) do not include Docker-driver binaries, preventing NemoClaw from recognizing the installed OpenShell version. NemoClaw's preflight check fails and attempts to downgrade to OpenShell 0.0.85. Currently using upstream NVIDIA OpenShell images (`ghcr.io/nvidia/openshell/gateway:0.0.96`) as a workaround. Investigating with the ODH team to include Docker-driver support in future RHAIV builds.

2. **NemoClaw inference route API incompatibility** — NemoClaw's inference route validation expects `"Gateway inference:"` output format but OpenShell 0.0.96+ outputs `"Inference:"`. Patched in our NemoClaw CLI build; upstream fix needed. This causes NemoClaw onboard step 4 to fail, falling back to `openshell provider create` (functional but loses NemoClaw-managed inference routing).

3. **NemoClaw does not support pre-built sandbox images** — NemoClaw onboard always builds the sandbox image from a Dockerfile (upstream issue #6402). Cannot use our pre-built images directly through NemoClaw. Sandbox is created separately via `openshell sandbox create --from <image>`.
