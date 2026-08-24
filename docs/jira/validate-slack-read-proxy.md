# Validate Slack Read Proxy

**Project:** APPENG
**Type:** Task
**Epic:** Secure Agent Workspace — Multi-Proxy Integration
**Priority:** Medium
**Labels:** proxy, slack, validation, two_vm

## Summary

Validate the Slack read-only proxy on the integrations VM. The agent accesses Slack via the `slack-read-proxy` transport provider.

## Acceptance Criteria

- [ ] Integ VM: `slack-read` provider created with `credentialKey: SLACK_READ_USER_TOKEN`
- [ ] Integ VM: `slack-read` sandbox running, listening on port 18084
- [ ] Integ VM: xoxp user token configured (read-scoped)
- [ ] Integ VM: proxy validates inter-VM bearer (401 without)
- [ ] Integ VM: proxy can list conversations, read messages
- [ ] Integ VM: proxy enforces GET-only allowlist (blocks POST/PUT/DELETE)
- [ ] Agent VM: `slack-read-proxy` provider attached to notebook sandbox
- [ ] Agent VM: Slack read forwarder running on loopback
- [ ] Agent VM: agent can read Slack messages via the forwarder
- [ ] Security: agent VM has no real Slack xoxp token
- [ ] Security: proxy only allows read-class Slack Web API methods

## Test Commands

```bash
# Verify proxy is listening (integ VM)
virtctl ... --command='openshell sandbox exec -n slack-read --no-tty -- \
  curl -sS -o /dev/null -w "%{http_code}" http://127.0.0.1:18084/conversations.list'
# Expected: 401 (no bearer)

# Verify from agent VM (with inter-VM bearer through supervisor)
openshell --gateway openshell-saw --gateway-insecure sandbox exec -n notebook --no-tty -- \
  curl -sS http://127.0.0.1:18082/conversations.list
```

## Dependencies

- `quay.io/redhat-et/slack-read-proxy:demo1` image
- Slack workspace with xoxp user token (read-scoped)
- `slack-read-proxy` governance profile deployed
- Slack read forwarder baked into agent sandbox image
