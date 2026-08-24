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

## Files to Create/Modify

### 1. Build the proxy binary/image

Create a container image that:
- Reads config from `/sandbox/.env` (dotenv format)
- Validates incoming requests against `INTER_VM_BEARER_SHA256`
- Forwards authorized requests to the real API with real credentials
- Listens on a specific port (e.g., 18081 for Slack)

Example `.env` vars your proxy should read:
```
INTER_VM_BEARER_SHA256=<64-hex-chars>
SLACK_BOT_TOKEN=xoxb-...
LISTEN_ADDR=127.0.0.1:18081
```

Push the image to a registry:
```bash
podman build -t quay.io/your-org/slack-proxy:latest .
podman push quay.io/your-org/slack-proxy:latest
```

### 2. Create the governance profile (integrations VM)

`charts/governance-policy/profiles/slack-read.yaml`:
```yaml
id: slack-read
display_name: Slack Read Proxy
description: Slack read-only proxy on the integrations VM
category: data
inference_capable: false

credentials:
  - name: bot_token
    description: Slack Bot OAuth token
    env_vars: [SLACK_BOT_TOKEN]
    required: true
    auth_style: bearer
    header_name: authorization

discovery:
  credentials: [bot_token]

endpoints:
  - host: slack.com
    port: 443
    protocol: rest
    enforcement: enforce
    access: read-only

binaries:
  - /sandbox/slack-proxy
```

### 3. Create the transport profile (agent VM)

`charts/governance-policy/profiles/slack-read-proxy.yaml`:
```yaml
id: slack-read-proxy
display_name: Slack read-only proxy transport
description: Inter-VM bearer for agent access to the integrations VM Slack proxy
category: data
inference_capable: false

credentials:
  - name: access_token
    description: Inter-VM bearer token
    env_vars: [SLACK_ACCESS_TOKEN]
    required: true
    auth_style: bearer
    header_name: authorization

discovery:
  credentials: [access_token]

endpoints:
  - host: saw-integrations-gateway.__NAMESPACE__.svc.cluster.local
    port: 18081
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
    - name: mail-proxy
      # ... existing ...
    - name: slack-proxy
      type: generic
      enabled: true
      image: quay.io/your-org/slack-proxy:latest
      command: "/sandbox/slack-proxy"
      exposePort: 18081
      providers:
        - slack-read
```

### 5. Add to the integrations BOM providers

`charts/saw-bom/profiles/integrations/default/providers.yaml`:
```yaml
spec:
  providers:
    - name: slack-read
      type: slack-read
```

### 6. Add to the agent BOM sandbox providers

`charts/saw-bom/profiles/data-science/default/sandbox.yaml`:
```yaml
spec:
  sandboxes:
    - name: notebook
      type: openclaw
      enabled: true
      providers:
        - slack-read-proxy
```

### 7. Add to the agent BOM providers

`charts/saw-bom/profiles/data-science/default/providers.yaml`:
```yaml
spec:
  providers:
    - name: nvidia
      # ... existing ...
    - name: slack-read-proxy
      type: slack-read-proxy
      credentialSecret: inter-vm-bearer
      credentialSecretKey: bearer
```

### 8. Expose the port on the integrations VM

`overrides/openshell-saw-integ.yaml`:
```yaml
service:
  extraPorts:
    - name: mail-read
      port: 18080
      targetPort: 18080
    - name: slack-read       # ADD THIS
      port: 18081
      targetPort: 18081
    - name: inference-proxy
      port: 18083
      targetPort: 18083
```

### 9. Mount the bearer secret on the agent VM

`overrides/openshell-saw.yaml`:
```yaml
additionalProviderSecrets:
  - inter-vm-bearer
```

## Deploy

```bash
# 1. Deploy governance profiles (includes new slack-read + slack-read-proxy)
make deploy-gov-profiles

# 2. Deploy BOM (includes new sandbox + provider definitions)
make deploy-bom

# 3. Deploy integrations VM (creates slack-proxy sandbox + exposes port)
make deploy-integ-vm GOVERNANCE_ENABLED=false

# 4. Deploy agent VM (creates slack-read-proxy provider + attaches to sandbox)
make deploy-agent-vm GOVERNANCE_ENABLED=false

# 5. Verify
make verify-integ
make verify-agent
```

## How It Works at Runtime

1. **Agent sandbox** calls `https://slack-read-proxy.local/api/...`
2. **Supervisor** intercepts, matches the `slack-read-proxy` provider's endpoint
3. **Supervisor** injects `Authorization: Bearer <inter-vm-bearer>` from the provider credential
4. **Request** arrives at `integ-vm:18081`
5. **Slack proxy** validates `SHA256(bearer) == INTER_VM_BEARER_SHA256`
6. **Slack proxy** forwards to `slack.com` with real `SLACK_BOT_TOKEN`
7. **Response** flows back to the agent sandbox

The agent VM never sees the real Slack token.

## Credential Setup

The proxy's API credential (e.g., `SLACK_BOT_TOKEN`) is written to `/sandbox/.env` by `apply_bom.py` at deploy time. To update it after deployment:

```bash
# Update the provider credential on the integ VM
virtctl -n openshell-agents ssh cloud-user@vm/openshell-saw-integ \
  --identity-file=$HOME/.generated-ssh-keys/sandbox-ssh \
  --local-ssh-opts=-oStrictHostKeyChecking=no \
  --command="openshell provider update slack-read --credential SLACK_BOT_TOKEN=xoxb-your-real-token"
```

For OAuth-based credentials with refresh tokens, add a `refresh` strategy to the governance profile (see `gmail-read.yaml` for an example).

## Checklist

- [ ] Proxy image built and pushed
- [ ] Governance profile: `charts/governance-policy/profiles/<service>.yaml`
- [ ] Transport profile: `charts/governance-policy/profiles/<service>-proxy.yaml`
- [ ] Integ BOM: sandbox + provider in `charts/saw-bom/profiles/integrations/default/`
- [ ] Agent BOM: provider in `charts/saw-bom/profiles/data-science/default/providers.yaml`
- [ ] Agent BOM: provider attached in sandbox's `providers` list
- [ ] Integ overrides: port in `service.extraPorts`
- [ ] Agent overrides: `inter-vm-bearer` in `additionalProviderSecrets`
- [ ] `make verify-integ` passes
- [ ] `make verify-agent` passes
