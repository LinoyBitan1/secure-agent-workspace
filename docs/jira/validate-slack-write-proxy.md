# Validate Slack Write Proxy

**Project:** APPENG
**Type:** Task
**Epic:** Secure Agent Workspace — Multi-Proxy Integration
**Priority:** Medium
**Labels:** proxy, slack, write, validation, two_vm

## Summary

Validate the Slack approval-bound write proxy on the integrations VM. The write proxy is called by the Forge UI relay only, NOT the agent.

## Acceptance Criteria

- [ ] Integ VM: `slack-write` provider created with `credentialKey: SLACK_WRITE_USER_TOKEN`
- [ ] Integ VM: `slack-write` sandbox running, listening on port 18085
- [ ] Integ VM: xoxp write token configured (chat:write scope)
- [ ] Integ VM: `slack-write-frontdoor` K8s Secret created
- [ ] Integ VM: proxy validates front-door bearer (401 without)
- [ ] Integ VM: proxy enforces channel ID allowlist (`SLACK_ALLOWED_CHANNEL_IDS`)
- [ ] Integ VM: proxy supports undo window (configurable, default 60s)
- [ ] Integ VM: `/pending` returns list of pending sends
- [ ] Agent VM: NO `slack-write` provider or capability present
- [ ] Agent VM: agent cannot reach slack-write port directly
- [ ] Forge UI relay: can send messages via front-door bearer
- [ ] Security: write-scoped xoxp only
- [ ] Security: channel ID allowlist enforced server-side

## Test Commands

```bash
# Front-door enforcement (integ VM)
virtctl ... --command='curl -sS -o /dev/null -w "%{http_code}" http://127.0.0.1:18085/pending'
# Expected: 401

# Agent VM cannot reach write proxy
virtctl ... --command='curl --noproxy "*" --connect-timeout 2 -s -o /dev/null -w "%{http_code}" \
  http://openshell-saw-integ-gateway.openshell-agents.svc.cluster.local:18085/pending'
# Expected: 000
```

## Dependencies

- `quay.io/redhat-et/slack-write-proxy:demo1` image
- Slack workspace with xoxp write token (chat:write)
- `slack-write-frontdoor` K8s Secret
- `SLACK_ALLOWED_CHANNEL_IDS` configured
- Forge UI relay (for end-to-end write testing)
