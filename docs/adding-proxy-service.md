# Adding a New Proxy Service

This guide explains how to add a new proxy service (e.g., Slack, GitHub, Jira) to the two-VM split architecture, following the same pattern as the Gmail read proxy.

## Architecture

```
Agent VM                          Integrations VM
+-----------------------+         +-------------------------+
| OpenClaw sandbox      |         | proxy sandbox           |
|   calls proxy.local   | bearer  |   validates bearer      |
|   via provider profile|-------->|   calls real API with   |
|                       |         |   real credentials      |
+-----------------------+         +-------------------------+
```

- **Agent VM**: has a transport provider profile (endpoint + bearer credential)
- **Integrations VM**: has a governance provider profile (endpoint restrictions + API credentials) and runs the proxy sandbox

## Port Assignments

| Port  | Service       | Direction |
|-------|---------------|-----------|
| 18080 | Gmail read    | read-only |
| 18081 | Gmail write   | relay     |
| 18082 | M365 read     | read-only |
| 18083 | Inference     | proxy     |
| 18084 | Slack read    | read-only |
| 18085 | Slack write   | relay     |
| 18086 | M365 write    | relay     |

Pick the next available port for your new service.

## Files to Create/Modify

### 1. Build the proxy binary/image

Create a container image that:
- Reads credentials from environment variables (injected by OpenShell provider credential binding)
- Validates incoming requests against `INTER_VM_BEARER_SHA256` (for read proxies) or a front-door bearer SHA256 (for write proxies)
- Forwards authorized requests to the real API with real credentials
- Listens on a specific port (e.g., 18087 for your new service)

Example env vars your proxy should read:
```
INTER_VM_BEARER_SHA256=<64-hex-chars>   # for read proxies
FRONT_DOOR_BEARER_SHA256=<64-hex-chars> # for write proxies (relay)
YOUR_API_TOKEN=<real-credential>        # injected by provider credentialKey
LISTEN_ADDR=127.0.0.1:18087
```

Push the image to a registry:
```bash
podman build -t quay.io/your-org/your-proxy:latest .
podman push quay.io/your-org/your-proxy:latest
```

### 2. Create the governance profile (integrations VM)

`charts/governance-policy/profiles/your-service.yaml`:
```yaml
id: your-service
display_name: Your Service Proxy
description: Your service proxy on the integrations VM
category: data
inference_capable: false

credentials:
  - name: api_token
    description: Your service API token
    env_vars: [YOUR_API_TOKEN]
    required: true
    auth_style: bearer
    header_name: authorization

discovery:
  credentials: [api_token]

endpoints:
  - host: api.your-service.com
    port: 443
    protocol: rest
    enforcement: enforce
    access: read-only

binaries:
  - /sandbox/your-proxy
```

### 3. Create the transport profile (agent VM)

`charts/governance-policy/profiles/your-service-proxy.yaml`:
```yaml
id: your-service-proxy
display_name: Your Service proxy transport
description: Inter-VM bearer for agent access to the integrations VM proxy
category: data
inference_capable: false

credentials:
  - name: access_token
    description: Inter-VM bearer token
    env_vars: [YOUR_SERVICE_ACCESS_TOKEN]
    required: true
    auth_style: bearer
    header_name: authorization

discovery:
  credentials: [access_token]

endpoints:
  - host: saw-integrations-gateway.__NAMESPACE__.svc.cluster.local
    port: 18087
    protocol: rest
    enforcement: enforce
    access: read-only

binaries:
  - /usr/local/bin/curl
```

> **Note**: `__NAMESPACE__` is replaced with the actual namespace at Helm render time.

### 4. Add to the integrations BOM sandbox definition

`charts/saw-bom/profiles/integrations/default/sandbox.yaml`:
```yaml
spec:
  sandboxes:
    # ... existing sandboxes ...
    - name: your-proxy
      type: generic
      enabled: true
      image: quay.io/your-org/your-proxy:latest
      command: "/sandbox/your-proxy"
      env:
        INTER_VM_BEARER_SHA256: "${INTER_VM_BEARER_SHA256}"
        LISTEN_ADDR: "127.0.0.1:18087"
      exposePort: 18087
      providers:
        - your-service
```

The `env` block passes environment variables to the sandbox process. `${INTER_VM_BEARER_SHA256}` is resolved from `bom.env` at deploy time.

### 5. Add to the integrations BOM providers

`charts/saw-bom/profiles/integrations/default/providers.yaml`:
```yaml
spec:
  providers:
    # ... existing providers ...
    - name: your-service
      type: your-service
      credentialKey: YOUR_API_TOKEN
```

The `credentialKey` field determines which environment variable name the credential is exposed under inside the sandbox. This must match what your proxy binary reads.

### 6. Add to the agent BOM sandbox providers

`charts/saw-bom/profiles/data-science/default/sandbox.yaml`:
```yaml
spec:
  sandboxes:
    - name: notebook
      type: openclaw
      enabled: true
      providers:
        # ... existing providers ...
        - your-service-proxy
```

### 7. Add to the agent BOM providers

`charts/saw-bom/profiles/data-science/default/providers.yaml`:
```yaml
spec:
  providers:
    # ... existing providers ...
    - name: your-service-proxy
      type: your-service-proxy
      credentialSecret: inter-vm-bearer
      credentialSecretKey: bearer
```

The `credentialSecret` and `credentialSecretKey` tell `apply_bom.py` where to find the bearer token in K8s Secrets. The resolved value becomes the provider's credential.

### 8. Expose the port on the integrations VM

`overrides/openshell-saw-integ.yaml`:
```yaml
service:
  extraPorts:
    - {name: mail-read, port: 18080, targetPort: 18080}
    - {name: mail-write, port: 18081, targetPort: 18081}
    - {name: m365-read, port: 18082, targetPort: 18082}
    - {name: inference-proxy, port: 18083, targetPort: 18083}
    - {name: slack-read, port: 18084, targetPort: 18084}
    - {name: slack-write, port: 18085, targetPort: 18085}
    - {name: m365-write, port: 18086, targetPort: 18086}
    - {name: your-service, port: 18087, targetPort: 18087}  # ADD THIS
```

### 9. Mount the bearer secret on the agent VM

`overrides/openshell-saw.yaml`:
```yaml
additionalProviderSecrets:
  - inter-vm-bearer
```

> This is usually already configured. Only add if not present.

## Deploy

```bash
# 1. Deploy governance profiles (includes new your-service + your-service-proxy)
make deploy-gov-profiles

# 2. Deploy BOM (includes new sandbox + provider definitions)
make deploy-bom

# 3. Deploy integrations VM (creates your-proxy sandbox + exposes port)
make deploy-integ-vm GOVERNANCE_ENABLED=false

# 4. Deploy agent VM (creates your-service-proxy provider + attaches to sandbox)
make deploy-agent-vm GOVERNANCE_ENABLED=false

# 5. Verify
make verify-integ
make verify-agent
```

## How It Works at Runtime

1. **Agent sandbox** calls `https://your-service-proxy.local/api/...`
2. **Supervisor** intercepts, matches the `your-service-proxy` provider's endpoint
3. **Supervisor** injects `Authorization: Bearer <inter-vm-bearer>` from the provider credential
4. **Request** arrives at `integ-vm:18087`
5. **Proxy** validates `SHA256(bearer) == INTER_VM_BEARER_SHA256`
6. **Proxy** forwards to `api.your-service.com` with real `YOUR_API_TOKEN`
7. **Response** flows back to the agent sandbox

The agent VM never sees the real API token.

## Write Proxies (Relay Pattern)

For write proxies (Gmail write, Slack write, M365 write), the pattern is slightly different:

- Use a **front-door bearer** instead of the inter-VM bearer (separate secret per write proxy)
- The front-door bearer is generated by `setup-integ-proxies.sh` and stored in K8s
- The relay component on the agent VM calls the write proxy with the front-door bearer

In `sandbox.yaml`, use `FRONT_DOOR_BEARER_SHA256` instead of `INTER_VM_BEARER_SHA256`:
```yaml
env:
  FRONT_DOOR_BEARER_SHA256: "${YOUR_SERVICE_WRITE_FRONTDOOR_SHA256}"
```

## Checklist

- [ ] Proxy image built and pushed
- [ ] Governance profile: `charts/governance-policy/profiles/<service>.yaml`
- [ ] Transport profile: `charts/governance-policy/profiles/<service>-proxy.yaml`
- [ ] Integ BOM sandbox: `charts/saw-bom/profiles/integrations/default/sandbox.yaml`
- [ ] Integ BOM provider (with `credentialKey`): `charts/saw-bom/profiles/integrations/default/providers.yaml`
- [ ] Agent BOM provider (with `credentialSecret`): `charts/saw-bom/profiles/data-science/default/providers.yaml`
- [ ] Agent BOM sandbox `providers` list updated
- [ ] Integ overrides: port in `service.extraPorts`
- [ ] Agent overrides: `inter-vm-bearer` in `additionalProviderSecrets`
- [ ] `make verify-integ` passes
- [ ] `make verify-agent` passes
