# Validate M365 Read Proxy

**Project:** APPENG
**Type:** Task
**Epic:** Secure Agent Workspace — Multi-Proxy Integration
**Priority:** Medium
**Labels:** proxy, m365, microsoft, validation, two_vm

## Summary

Validate the Microsoft 365 read-only proxy on the integrations VM. The agent accesses M365 (mail, calendar) via the `m365-read-intervm` transport provider.

## Acceptance Criteria

- [ ] Integ VM: `m365-read` provider created with `credentialKey: CLIMICROSOFT365_ACCESS_TOKEN`
- [ ] Integ VM: `proxy-m365` sandbox running, listening on port 18082
- [ ] Integ VM: OAuth refresh configured (Microsoft Graph, read scopes)
- [ ] Integ VM: `__TENANT_ID__` replaced with actual Azure tenant ID in token URL
- [ ] Integ VM: proxy validates inter-VM bearer via `X-M365-Read-Bearer` header
- [ ] Integ VM: proxy can read mail, calendar events via Microsoft Graph
- [ ] Agent VM: `m365-read-intervm` provider attached to notebook sandbox
- [ ] Agent VM: M365 read forwarder running on loopback
- [ ] Agent VM: agent can read M365 mail/calendar via the forwarder
- [ ] Security: agent VM has no real Microsoft Graph credentials
- [ ] Security: proxy enforces read-only Graph operations

## Test Commands

```bash
# Verify proxy is listening (integ VM)
virtctl ... --command='openshell sandbox exec -n proxy-m365 --no-tty -- \
  curl -sS -o /dev/null -w "%{http_code}" http://127.0.0.1:18082/v1.0/me/messages'
# Expected: 401 (no bearer)

# Verify from agent VM
openshell --gateway openshell-saw --gateway-insecure sandbox exec -n notebook --no-tty -- \
  curl -sS http://127.0.0.1:18080/v1.0/me/messages
```

## Dependencies

- `quay.io/redhat-et/m365-read-proxy:demo1` image
- Azure AD app registration with Microsoft Graph read permissions
- Azure tenant ID for OAuth token URL
- M365 read forwarder baked into agent sandbox image
- `m365-read-intervm` governance profile deployed
