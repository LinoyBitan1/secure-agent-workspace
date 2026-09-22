# Container Runtime Support: Docker and Podman

The gateway VM supports two container runtimes, selectable at deploy time via a single Helm value.
The runtime is baked into the golden image; build the Podman variant for the default deployment, or explicitly build the Docker fallback.

## Runtimes

| Runtime | Golden image | Use case |
|---|---|---|
| `podman` (default) | `openshell-gateway` | NemoClaw managed-image onboarding and rootless workloads |
| `docker` (explicit fallback) | `openshell-gateway-docker` | Legacy/custom-image workflows and Docker-only integrations |

## Choosing a runtime

The runtime is selected by `containerRuntime`:

- **NemoClaw v0.0.127** supports native rootless Podman for standard managed-image onboarding.
- **Custom `--from Dockerfile` onboarding** remains a Docker workflow.
- **openclaw / opencode** work with either runtime. Podman is the Fedora default — no extra packages.

Set `containerRuntime` to match:

```yaml
# podman: default; NemoClaw selects NVIDIA's managed sandbox image
containerRuntime: podman
onboardCli: nemoclaw

# docker: explicit compatibility fallback, including custom --from workflows
containerRuntime: docker
onboardCli: openclaw
```

The Podman path requires the rootless socket at `/run/user/<uid>/podman/podman.sock`, cgroups v2, rootless networking, and the pinned NemoClaw/OpenShell compatibility contract.

## What changes between runtimes

### Golden image (`image-builder-charts/helm/openshell-gateway-image`)

| Step | Docker | Podman |
|---|---|---|
| Packages | Removes Podman, installs Docker CE | Keeps Fedora-default Podman |
| Runtime service | `docker.service` enabled | `podman.socket` enabled (user-level, rootless) |
| GRPC endpoint | Docker bridge address | `https://host.containers.internal:17670` |
| Sandbox driver env | `OPENSHELL_DRIVERS=docker` | `OPENSHELL_DRIVERS=podman` |
| Podman authority | Docker daemon socket | `/run/user/<uid>/podman/podman.sock` |

### Helm chart (`charts/openshell-saw`)

| Resource | Docker | Podman |
|---|---|---|
| DataSource | `openshell-gateway-docker` | `openshell-gateway` |
| cloud-init `OPENSHELL_DRIVERS` | `docker` | `podman` |
| Registry auth | `docker login` to internal OpenShift registry | Podman pull with registry TLS handling |
| Binary extraction | `docker pull/create/cp/rm` | `podman pull/create/cp/rm` |
| Dashboard systemd units | `/usr/bin/docker run` | `/usr/bin/podman run` |
| Sandbox pre-pull | `sudo docker pull` | rootless `podman pull` |

## Building the golden images

```bash
# Podman variant — default and required for native NemoClaw validation
make build-gateway-podman

# Docker variant — explicit fallback
make build-gateway-docker
```

Each produces a separate ImageStream, DataVolume, and DataSource on the cluster.
Both can coexist in the same namespace.

## Deploying a sandbox

```bash
# Podman runtime + NemoClaw managed image
make openshell-saw-create \
  OPENSHELL_SAW_NAME=my-sandbox \
  CONTAINER_RUNTIME=podman \
  ONBOARD_CLI=nemoclaw \
  PROVIDER=build MODEL=nvidia/nemotron-3-super-120b-a12b API_KEY=<nvapi-key>

# Docker runtime + legacy OpenClaw/custom-image fallback
make openshell-saw-create \
  OPENSHELL_SAW_NAME=my-sandbox \
  CONTAINER_RUNTIME=docker \
  PROVIDER=build MODEL=nvidia/nemotron-3-super-120b-a12b API_KEY=<nvapi-key>
```

Switching an existing sandbox requires a values change and VM recreate:

```bash
helm upgrade <release> charts/openshell-saw --set containerRuntime=podman
# Then delete and recreate the VM by uninstalling and reinstalling the release.
```

## Connecting to the TUI

The gateway uses mTLS. The self-signed server certificate is only valid for `127.0.0.1`, so
external route access (e.g. opening the gateway URL in a browser) won't work for the CLI.
Use a port-forward instead.

### Step 1 — Copy the mTLS client certs from the VM (once per sandbox)

```bash
SANDBOX=<your-sandbox-name>   # e.g. test-docker
NS=openshell-agents

mkdir -p ~/.config/openshell/gateways/${SANDBOX}/mtls

for f in ca.crt tls.crt tls.key; do
  [[ "$f" == "ca.crt" ]] \
    && src="/home/cloud-user/.local/state/openshell/tls/ca.crt" \
    || src="/home/cloud-user/.local/state/openshell/tls/client/${f}"
  virtctl -n ${NS} scp \
    cloud-user@vm/${SANDBOX}:${src} \
    ~/.config/openshell/gateways/${SANDBOX}/mtls/${f} \
    --identity-file=~/.generated-ssh-keys/sandbox-ssh \
    --local-ssh-opts=-oStrictHostKeyChecking=no \
    --local-ssh-opts=-oUserKnownHostsFile=/dev/null
done

chmod 600 ~/.config/openshell/gateways/${SANDBOX}/mtls/*

cat > ~/.config/openshell/gateways/${SANDBOX}/metadata.json <<EOF
{"name":"${SANDBOX}","gateway_endpoint":"https://127.0.0.1:17670","is_remote":false,"gateway_port":17670,"auth_mode":"mtls"}
EOF
```

### Step 2 — Start port-forward (keep this terminal open)

```bash
oc port-forward svc/${SANDBOX}-gateway 17670:17670 -n openshell-agents
```

### Step 3 — Verify gateway and sandbox are reachable

```bash
openshell gateway select ${SANDBOX}
openshell sandbox list
# Should show the sandbox in Ready or Unspecified phase
```

### Step 4 — Open the TUI

```bash
ssh \
  -o "ProxyCommand=openshell --gateway ${SANDBOX} ssh-proxy --gateway-name ${SANDBOX} --name ${SANDBOX}" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o LogLevel=ERROR \
  -tt sandbox@openshell-${SANDBOX}.default openclaw
```

> **Note:** The cert-copy step (Step 1) requires `virtctl`. A follow-up improvement is to
> have the setup Job publish the mTLS client cert as a k8s Secret so the local setup can be
> done with `oc extract secret/...` instead.

## Known limitations

**Managed-image onboarding** does not use the repository's `nemoclaw-sandbox` image and does not pass `--from`. NemoClaw resolves the compatible NVIDIA-managed sandbox image for the pinned release and architecture.

**Custom images** are a separate Docker fallback. Use `containerRuntime: docker` when intentionally running `nemoclaw onboard --from <Dockerfile>` or another Docker-only integration.

## Risks

- **Rootless vs rooted** — Podman runs as `cloud-user`; the exact socket path is written with that user's UID during first boot.
- **Two images to maintain** — both golden images need rebuilds when the base Fedora version or OpenShell version changes.
