# Validate Gmail Write Proxy

**Project:** APPENG
**Type:** Task
**Epic:** Secure Agent Workspace — Multi-Proxy Integration
**Priority:** High
**Labels:** proxy, gmail, write, validation, two_vm

## Summary

Validate the Gmail write proxy (draft create/send/cancel) on the integrations VM. The write proxy is called by the Forge UI relay, NOT the agent.

## Acceptance Criteria

- [ ] Integ VM: `gmail-write` provider created with `credentialKey: GMAIL_WRITE_TOKEN`
- [ ] Integ VM: `gmail-write` sandbox running, listening on port 18081
- [ ] Integ VM: `gmail-write-frontdoor` K8s Secret created with SHA256 digest passed to sandbox
- [ ] Integ VM: OAuth refresh configured (gmail.compose scope)
- [ ] Integ VM: proxy validates front-door bearer (401 without, passes with correct bearer)
- [ ] Integ VM: `/healthz` returns 200
- [ ] Integ VM: proxy can create draft, send draft, cancel pending send
- [ ] Integ VM: undo window (60s default) works — send can be cancelled within window
- [ ] Agent VM: NO `gmail-write` provider or capability present
- [ ] Agent VM: agent cannot reach gmail-write port directly (NetworkPolicy)
- [ ] Forge UI relay: can reach proxy using front-door bearer from K8s Secret
- [ ] Security: write-scoped OAuth (gmail.compose only)
- [ ] Security: proxy only allows POST/PUT/DELETE on `/gmail/v1/users/me/drafts*`

## Test Commands

```bash
# Verify front-door enforcement from integ VM loopback
virtctl -n openshell-agents ssh cloud-user@vm/openshell-saw-integ ... \
  --command='curl -sS -o /dev/null -w "%{http_code}" http://127.0.0.1:18081/healthz'
# Expected: 200

virtctl ... --command='curl -sS -o /dev/null -w "%{http_code}" http://127.0.0.1:18081/pending'
# Expected: 401 (no bearer)

# Verify agent VM cannot reach write proxy
virtctl -n openshell-agents ssh cloud-user@vm/openshell-saw ... \
  --command='curl --noproxy "*" --connect-timeout 2 -s -o /dev/null -w "%{http_code}" \
    http://openshell-saw-integ-gateway.openshell-agents.svc.cluster.local:18081/pending'
# Expected: 000 (connection refused / NetworkPolicy blocked)
```

## Dependencies

- `quay.io/redhat-et/gmail-write-proxy:demo1` image
- Google Cloud project with Gmail API enabled + gmail.compose OAuth scope
- `gmail-write-frontdoor` K8s Secret
- Forge UI relay (for end-to-end write testing)
