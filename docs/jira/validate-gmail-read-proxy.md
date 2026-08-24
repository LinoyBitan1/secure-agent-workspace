# Validate Gmail Read Proxy

**Project:** APPENG
**Type:** Task
**Epic:** Secure Agent Workspace — Multi-Proxy Integration
**Priority:** High
**Labels:** proxy, gmail, validation, two_vm

## Summary

Validate the Gmail read-only proxy end-to-end in the two-VM split architecture.

## Acceptance Criteria

- [ ] Integ VM: `gmail-read` provider created with `credentialKey: access_token`
- [ ] Integ VM: `mail-proxy` sandbox running, listening on port 18080
- [ ] Integ VM: `configure-gmail-refresh` configures OAuth refresh (gmail.readonly scope)
- [ ] Integ VM: proxy validates inter-VM bearer (401 without, passes with correct bearer)
- [ ] Integ VM: proxy forwards to Gmail API and returns real data (200)
- [ ] Agent VM: `gmail-read-proxy` provider attached to notebook sandbox
- [ ] Agent VM: `read-agent-forwarder.mjs` running on 127.0.0.1:18079
- [ ] Agent VM: `gog --readonly gmail search "newer_than:1d" --max 5 --json --no-input` returns real email data
- [ ] Agent VM: OpenClaw TUI/GUI can read emails when asked
- [ ] Security: agent VM has no real Gmail credentials
- [ ] Security: proxy only allows GET/HEAD/OPTIONS methods
- [ ] Security: proxy only allows `/gmail/v1/users/me/{messages,threads,labels}` paths

## Test Commands

```bash
# Integ VM verification
make verify-integ

# Agent VM verification
make verify-agent

# E2E test
openshell --gateway openshell-saw --gateway-insecure sandbox exec -n notebook --no-tty -- \
  gog --readonly gmail search "newer_than:1d" --max 3 --json --no-input

# Full flow via TUI
make login && make tui
# Ask: "read my last 5 emails"
```

## Dependencies

- OpenShell 0.0.110+
- `quay.io/sauagarw/gmail-read-proxy:demo1-fix` image (with `select_gmail_token_placeholder`)
- Google Cloud project with Gmail API enabled + Desktop OAuth client
- Known issue: OpenShell v-type credential placeholders not resolved (docs/bugs/)
