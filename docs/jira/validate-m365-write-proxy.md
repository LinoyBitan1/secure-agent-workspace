# Validate M365 Write Proxy

**Project:** APPENG
**Type:** Task
**Epic:** Secure Agent Workspace — Multi-Proxy Integration
**Priority:** Medium
**Labels:** proxy, m365, microsoft, write, validation, two_vm

## Summary

Validate the Microsoft 365 write proxy (draft create + send) on the integrations VM. The write proxy is called by the Forge UI relay only, NOT the agent.

## Acceptance Criteria

- [ ] Integ VM: `m365-write` provider created with `credentialKey: CLIMICROSOFT365_ACCESS_TOKEN`
- [ ] Integ VM: `proxy-m365-write` sandbox running, listening on port 18086
- [ ] Integ VM: `m365-write-frontdoor` K8s Secret created
- [ ] Integ VM: OAuth refresh configured (Microsoft Graph, Mail.ReadWrite scope)
- [ ] Integ VM: proxy validates front-door bearer (401 without)
- [ ] Integ VM: proxy can create draft and send identified draft only
- [ ] Integ VM: proxy blocks `/sendMail` (direct send without draft)
- [ ] Integ VM: undo window works (configurable, default 60s)
- [ ] Agent VM: NO `m365-write` provider or capability present
- [ ] Agent VM: agent cannot reach m365-write port directly
- [ ] Forge UI relay: can create/send drafts via front-door bearer
- [ ] Security: restricted to `POST /v1.0/me/messages` (create draft) and `POST /v1.0/me/messages/{id}/send`
- [ ] Security: `/sendMail` endpoint blocked

## Test Commands

```bash
# Front-door enforcement (integ VM)
virtctl ... --command='curl -sS -o /dev/null -w "%{http_code}" http://127.0.0.1:18086/v1.0/me/messages'
# Expected: 401

# Agent VM cannot reach write proxy
virtctl ... --command='curl --noproxy "*" --connect-timeout 2 -s -o /dev/null -w "%{http_code}" \
  http://openshell-saw-integ-gateway.openshell-agents.svc.cluster.local:18086/v1.0/me/messages'
# Expected: 000
```

## Dependencies

- `quay.io/redhat-et/m365-write-proxy:demo1` image
- Azure AD app registration with Mail.ReadWrite permission
- `m365-write-frontdoor` K8s Secret
- Forge UI relay (for end-to-end write testing)
