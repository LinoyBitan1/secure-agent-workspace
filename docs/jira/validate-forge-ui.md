# Validate Forge UI + Relay

**Project:** APPENG
**Type:** Task
**Epic:** Secure Agent Workspace — Multi-Proxy Integration
**Priority:** High
**Labels:** forge-ui, relay, validation, two_vm

## Summary

Validate the Forge UI deployment with its relay connecting to the OpenClaw agent and bridging write operations to proxy services.

## Acceptance Criteria

- [ ] Forge UI Deployment running (injector + relay containers)
- [ ] OpenShift Route created with TLS edge termination
- [ ] `forge-secrets` K8s Secret created with all credentials
- [ ] `forge-relay-identity` K8s Secret created
- [ ] Relay PVC provisioned (`rh-forge-ui-relay-store`)
- [ ] Relay connects to agent VM OpenClaw gateway via WebSocket
- [ ] Relay device approved on OpenClaw gateway
- [ ] `/api/status` returns `gateway: connected`
- [ ] UI loads in browser via the Route URL
- [ ] Chat works: user message → OpenClaw agent → response displayed
- [ ] Gmail write: relay can create/send drafts via gmail-write proxy
- [ ] M365 write: relay can create/send via m365-write proxy
- [ ] Slack write: relay can send messages via slack-write proxy
- [ ] All write operations use front-door bearers (not agent credentials)
- [ ] Write proxies are NOT accessible from the agent VM

## Test Commands

```bash
# Deploy
make deploy-forge-ui \
  UI_IMAGE=image-registry.../rh-forge-ui:demo1 \
  RELAY_IMAGE=image-registry.../rh-forge-ui-relay:demo1 \
  DEMO_USER_EMAIL=alice@example.com

# Verify deployment
oc get deployment rh-forge-ui -n openshell-agents
oc get route rh-forge-ui -n openshell-agents -o jsonpath='https://{.spec.host}'

# Check relay status
oc exec deployment/rh-forge-ui -c injector -- curl -fsS http://127.0.0.1:8888/api/status

# Verify write boundaries from relay container
oc exec deployment/rh-forge-ui -c relay -- sh -c '
  gmail_unauth=$(curl -sS -o /dev/null -w "%{http_code}" "$FORGE_MAIL_POST_URL/pending")
  test "$gmail_unauth" = 401 && echo "Gmail write boundary: OK"
'

# Cleanup
make delete-forge-ui
```

## Dependencies

- Agent VM deployed with OpenClaw sandbox + gateway
- Integ VM deployed with all write proxies (gmail-write, m365-write, slack-write)
- Front-door secrets created (gmail-write-frontdoor, m365-write-frontdoor, slack-write-frontdoor)
- `forge-agent-ingest` secret created
- `rh-forge-ui` and `rh-forge-ui-relay` container images built and available
