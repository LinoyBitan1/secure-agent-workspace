# APPENG-6276: Podman/NemoClaw Build and Validation Plan

## Scope

Validate NemoClaw `v0.0.124` with OpenShell `0.0.116` on the rootless Podman gateway path, then capture the evidence needed to complete APPENG-6276.

The current branch uses the following validation inputs:

- OpenShell: `0.0.116`
- NemoClaw source: commit `6f3cced4230ae9660c049cc11804daf37797c595` (`v0.0.124`)
- NemoClaw base image: `ghcr.io/nvidia/nemoclaw/sandbox-base:v0.0.124`
- Target architecture: `amd64`
- Gateway runtime: rootless Podman
- Gateway image: `openshell-gateway`
- Driver environment: `OPENSHELL_DRIVERS=podman`

## Progress recorded (2026-09-19)

- Built and pushed `openshell-gateway:0.0.116`, `nemoclaw-sandbox:0.0.116`,
  `nemoclaw-cli:0.0.116`, `governance-interceptor:0.0.116`, and
  `openclaw-openshell:0.0.116` to the temporary public Quay repository.
- Logged into the fresh `cluster-cnpf5` cluster and created the empty
  `openshell-agents` namespace.
- Mirrored the gateway, NemoClaw sandbox, and NemoClaw CLI images into the
  internal registry. Governance and OpenClaw images were copied temporarily
  for complete-image validation and then removed because the current test
  configuration references Quay directly.
- `make check-prereqs` was run before pattern installation and correctly
  reported that OpenShift Virtualization was not installed.
- Option A installation and sandbox validation are still pending.

## Before building

1. Confirm the personal Quay repository is public:

   ```text
   quay.io/rh-ee-lbitan
   ```

2. Authenticate locally to Quay if required for pushes:

   ```bash
   podman login quay.io
   ```

3. Confirm the OpenShift user can build in `openshell-agents` and mirror images into the internal registry.

4. Confirm the working tree and branch before starting. The personal registry
   configuration is intentionally present only on this temporary validation
   branch and must be removed before the changes are merged into the shared
   repository.

## Build and push order

The Makefile default currently points to `quay.io/rh-ee-lbitan` for this test
branch only. This is temporary test infrastructure, not a production default.

Build and push the images in this order:

```bash
make build-gateway-podman
make build-governance-interceptor
make build-nemoclaw
make build-nemoclaw-cli
make build-openclaw-openshell
```

These commands publish the following images to the personal Quay repository:

| Image | Purpose |
|---|---|
| `openshell-gateway` | Podman golden gateway image |
| `governance-interceptor` | Signed-policy interceptor |
| `nemoclaw-sandbox` | NemoClaw sandbox image |
| `nemoclaw-cli` | NemoClaw CLI installed on the gateway VM |
| `openclaw-openshell` | OpenClaw compatibility/default image |

After all pushes complete, mirror the core images into OpenShift:

```bash
make copy-images
```

Verify the internal registry has the expected image tags before deploying the
sandbox. Governance and OpenClaw images are optional for the NemoClaw-only
test and should only be copied when those paths are explicitly being tested.

## Deployment

Deploy the test sandbox with Podman and NemoClaw onboarding enabled:

```bash
make openshell-saw-create \
  OPENSHELL_SAW_NAME=nemoclaw-podman \
  CONTAINER_RUNTIME=podman \
  PROVIDER=build \
  MODEL=nvidia/nemotron-3-super-120b-a12b \
  API_KEY="$NVIDIA_API_KEY"
```

If the deployment uses a profile-specific image override, ensure it points to the personal Quay image that was just built and pushed.

## Validation checks

### Gateway and runtime

Confirm the VM is healthy and uses Podman without Docker installed:

```bash
podman info
test -S /run/user/$(id -u)/podman/podman.sock
! command -v docker
```

Confirm the gateway configuration contains:

```text
OPENSHELL_DRIVERS=podman
```

Confirm the Podman golden image/data source is selected:

```text
openshell-gateway
```

### OpenShell

```bash
openshell -V
openshell --gateway nemoclaw-podman sandbox list --workspace cuda-dev
openshell --gateway nemoclaw-podman sandbox exec \
  -n cuda-sandbox --workspace cuda-dev -- \
  sh -lc 'id; ls -l /opt/openshell/bin/openshell-sandbox'
```

Expected sandbox checks:

- Sandbox reaches `Ready`.
- Supervisor is present.
- Sandbox UID/GID behavior remains correct.
- OpenShell operations use the Podman driver.

### NemoClaw

Run the native onboarding/connect checks from the gateway VM:

```bash
nemoclaw onboard
nemoclaw <sandbox-name> connect --probe-only
```

Record whether:

- `nemoclaw onboard` completes without Docker.
- The sandbox is created through the Podman socket.
- `nemoclaw <name> connect` preserves Podman and does not switch the gateway to Docker.
- The resulting sandbox can launch the OpenClaw/NemoClaw TUI.

## Acceptance evidence

Capture command output and logs for:

- OpenShell and NemoClaw versions.
- Podman socket availability.
- Absence of Docker.
- `OPENSHELL_DRIVERS=podman`.
- Gateway/data source selection.
- Successful onboarding.
- Successful sandbox creation and connect probe.
- Final sandbox status and TUI launch.

If onboarding or connect still reports a Docker-only preflight failure, record the exact error as an APPENG-6276 blocker rather than marking the story complete.

## Cleanup before merging the validation branch

The personal Quay repository and all related image references are temporary
test infrastructure. This validation commit may contain them so Argo CD can
deploy the test branch, but they must be removed before merging or publishing
the changes as the shared default:

1. Restore every temporary `quay.io/rh-ee-lbitan` default and image reference
   back to the project’s intended shared registry configuration.

2. Do not commit personal Quay references, credentials, or test-only image URLs.

3. Verify no personal references remain:

   ```bash
   rg -n 'rh-ee-lbitan|NVIDIA_API_KEY' \
     Makefile-quickstart scripts charts image-builder-charts overrides docs
   ```

4. Review the final diff and status:

   ```bash
   git diff --check
   git status --short
   git diff
   ```

5. For the final shared-repository change, restore the approved shared image
   registry, review the diff, and only then merge. Do not copy personal Quay
   credentials or local `~/values-secret.yaml` into Git.
