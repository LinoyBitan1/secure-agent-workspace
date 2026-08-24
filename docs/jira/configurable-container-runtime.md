# Configurable container runtime: joint Docker and Podman support

**Project:** APPENG
**Type:** Story
**Epic:** Secure Agent Workspace Validated Pattern
**Priority:** High
**Component:** RH_AI_Blueprints
**Labels:** secure_agent_workspace, docker, podman, openshell, container-runtime

## Summary

Make the container runtime inside the gateway VM configurable via Helm values, supporting both Docker and Podman. Ship two golden images — the original Fedora image with Podman (the OS default) and a Docker variant. The Helm chart selects the golden image and templates all runtime commands based on a single `containerRuntime` toggle. Switching runtimes is a values change + VM recreate — no golden image rebuild needed.

## Background

The gateway VM uses a container runtime for four purposes:

1. **Binary extraction** — pull/create/cp to extract gateway and supervisor binaries from container images
2. **Sandbox lifecycle** — OpenShell gateway's `OPENSHELL_DRIVERS` env var selects the runtime for sandbox container operations
3. **Dashboard containers** — Dashboard BFF and OAuth2 proxy run as containers inside the VM via systemd services
4. **Registry authentication** — login to the container registry for image pulls

### Two runtime paths

The runtime choice depends on the sandbox agent:

**Docker path (NemoClaw):**
- NemoClaw onboarding requires Docker — it rejects Podman at preflight
- Sandbox images are built on-cluster and stored in the internal OpenShift registry
- Setup job uses `docker login` to authenticate to the internal registry
- Setup job uses `docker pull/create/cp` for binary extraction and image pre-pull

**Podman path (openclaw, opencode, other agents):**
- Agents like openclaw and opencode ship as container images on external registries (ghcr.io, quay.io)
- No internal registry needed — images are pulled directly from the external registry
- No NemoClaw onboarding — sandbox is created with `openshell sandbox create --from <image>`
- Podman is the Fedora default — no additional packages to install

## Approach: two golden images

Ship two pre-built golden images:

| Image | Tag | Runtime | Use case |
| --- | --- | --- | --- |
| Podman (default) | `openshell-gateway:latest` | Podman (Fedora default) | openclaw, opencode, any external image |
| Docker variant | `openshell-gateway:docker` | Docker CE | NemoClaw (requires Docker) |

Benefits:

- **No golden image rebuild to switch** — both images are pre-built and available
- **Clean separation** — each image has exactly one runtime, no conflicting packages
- **The Podman image is just the Fedora default** — no customization needed
- **External registry support** — Podman path pulls sandbox images from ghcr.io/quay.io directly, no internal registry setup

## Acceptance Criteria

1. Two golden images available: `openshell-gateway:latest` (Podman) and `openshell-gateway:docker` (Docker)
2. `values.yaml` exposes `containerRuntime: docker` (default) with `podman` as the alternative
3. The golden image DataSource reference changes based on `containerRuntime`
4. All hardcoded `docker` commands in templates use the configured runtime
5. Cloud-init sets `OPENSHELL_DRIVERS` from the configured runtime
6. Dashboard systemd services use the configured runtime binary
7. Setup job conditionally handles registry auth:
   - Docker: `docker login` to internal OpenShift registry (for NemoClaw images)
   - Podman: no internal registry login needed (external images only)
8. NemoClaw validation: setup job fails if `containerRuntime=podman` and `onboardCli=nemoclaw`
9. Switching runtimes requires only a values change + VM recreate

## Implementation Plan

### 1. Golden image builds

**Podman image** (`openshell-gateway:latest`):

- Restore the original Fedora golden image build — remove the Docker CE installation steps
- Keep Podman as shipped by Fedora (no `dnf remove podman`)
- Enable `podman.socket` and `loginctl enable-linger cloud-user` for rootless Podman
- Tag as `openshell-gateway:latest`

**Docker image** (`openshell-gateway:docker`):

- Current build — removes Podman, installs Docker CE, enables Docker service
- Tag as `openshell-gateway:docker`

**File:** `image-builder-charts/helm/openshell-gateway-image/`

- Add a `containerRuntime` value (default `docker`)
- BuildConfig output tag: `openshell-gateway:{{ .Values.containerRuntime }}`
- Or maintain two separate BuildConfigs / values overrides for each variant

### 2. Add `containerRuntime` to values.yaml

**File:** `charts/openshell-saw/values.yaml`

```yaml
# Container runtime inside the gateway VM: docker or podman
# docker: requires openshell-gateway:docker golden image. Required for NemoClaw.
# podman: uses openshell-gateway:latest golden image. For openclaw, opencode, or any external sandbox image.
containerRuntime: docker
```

### 3. Golden image selection

**File:** `charts/openshell-saw/templates/` (VM and DataSource references)

The VM's DataSource or golden image reference resolves based on the runtime:

```yaml
{{- if eq .Values.containerRuntime "docker" }}
  dataSource: openshell-gateway-docker
{{- else }}
  dataSource: openshell-gateway
{{- end }}
```

### 4. Template cloud-init

**File:** `charts/openshell-saw/templates/cloudinit-sandbox.yaml`

```yaml
OPENSHELL_DRIVERS={{ .Values.containerRuntime }}
```

### 5. Template setup scripts

**File:** `charts/openshell-saw/templates/configmap-scripts.yaml`

Introduce a shell variable at the top of each script section:

```bash
RUNTIME="{{ .Values.containerRuntime }}"
```

Replace all hardcoded `docker` commands with `${RUNTIME}`:

- `docker pull` → `${RUNTIME} pull`
- `docker create` → `${RUNTIME} create`
- `docker cp` → `${RUNTIME} cp`
- `docker rm` → `${RUNTIME} rm`
- `docker login` → `${RUNTIME} login`
- `sudo docker pull` → `sudo ${RUNTIME} pull`
- `/usr/bin/docker run` → `/usr/bin/${RUNTIME} run` (dashboard services)
- `/usr/bin/docker stop` → `/usr/bin/${RUNTIME} stop`
- `docker logs` → `${RUNTIME} logs`

Conditional registry auth:

```bash
if [[ "${RUNTIME}" == "docker" ]]; then
  # Docker path: login to internal OpenShift registry for NemoClaw images
  sudo tee /etc/docker/daemon.json <<DAEMON
  { "insecure-registries": ["${REGISTRY_SVC}"] }
DAEMON
  sudo systemctl restart docker
  docker login -u "${SA_USER}" -p "${SA_TOKEN}" "${REGISTRY_SVC}"
else
  # Podman path: no internal registry needed — sandbox images come from external registries
  echo "Podman runtime: skipping internal registry login (external images only)"
fi
```

### 6. Template gateway startup script

**File:** `image-builder-charts/helm/openshell-gateway-image/templates/buildconfig.yaml` (user-setup.sh)

The bridge network inspection for the GRPC endpoint differs by runtime:

- Docker: `docker network inspect bridge` → default gateway `172.17.0.1`
- Podman: `podman network inspect podman` → default gateway `10.88.0.1`

### 7. NemoClaw validation guard

**File:** `charts/openshell-saw/templates/configmap-scripts.yaml`

```bash
if [[ "${RUNTIME}" == "podman" && "{{ .Values.onboardCli }}" == "nemoclaw" ]]; then
  echo "ERROR: NemoClaw onboarding requires Docker. Set containerRuntime=docker or use onboardCli=openclaw."
  exit 1
fi
```

### 8. Fix stale test assertions

- `scripts/e2e-test.sh` line 304 — change `podman --version` check to use the configured runtime
- `tests/test-bootc-e2e.sh` line 346 — same fix

### 9. Add Helm template tests

- Assert `containerRuntime=docker` renders `OPENSHELL_DRIVERS=docker` in cloud-init
- Assert `containerRuntime=podman` renders `OPENSHELL_DRIVERS=podman` in cloud-init
- Assert Podman path skips internal registry login
- Assert NemoClaw + Podman triggers the validation guard

## Risks

- **Podman + NemoClaw incompatibility** — NemoClaw onboarding will fail with Podman. The validation guard (step 7) catches this at deploy time.
- **Network namespace differences** — Docker uses `172.17.0.0/16` bridge, Podman uses `10.88.0.0/16`. The GRPC endpoint configuration must match.
- **Rootless vs rooted** — Podman runs rootless by default; dashboard containers may need adjustment (e.g., `--userns=keep-id`). Docker daemon runs as root.
- **Two images to maintain** — both golden images need rebuilds when the base Fedora version or OpenShell version changes. Mitigated by sharing the same BuildConfig with a runtime parameter.

## Dependencies

- NemoClaw Podman support (upstream #7883) — once landed, NemoClaw can use the Podman path too
- OpenShell gateway supports both `OPENSHELL_DRIVERS=docker` and `OPENSHELL_DRIVERS=podman`

## References

- [Switch sandbox runtime from Podman to Docker](switch-podman-to-docker.md) — original Docker migration story
- NemoClaw upstream: issue #7883 (Podman support), epic #7744
