# Demo options

Two walks of the SAME personal assistant. The honest axis is the provider
strategy: point the providers at external accounts, or run the services
inside the cluster. Choose by what you can set up: accounts or services.

## Personal Assistant (Quick Demo) with external providers: Slack and Gmail

Step-by-step walkthrough: [personal-assistant-demo.md](personal-assistant-demo.md)
(how the briefing works under the hood: [daily-briefing.md](daily-briefing.md)).

- The agent reads real Slack and Gmail (⚠️ with the Tier 2 limitation below:
  the token is not injected, so fetches currently return `invalid_auth`),
  so you need two external demo
  accounts (Slack app, Google Cloud OAuth client): about 30 minutes, once.
- Quick to run: one workspace, one prompt, a ~10-minute demo.
- Same platform install, same profile shape: one NemoClaw sandbox with the
  `daily-briefing` harness bundle, NVIDIA inference, read-only Slack and
  Gmail providers, and token placeholders the agent never resolves.
- Self-service via the Red Hat Developer Hub portal: add your demo user
  (e.g. `dana`) to `overrides/saw-users.yaml` first, then they pick the
  profile, enter their keys, and get their own workspace.
- ⚠️ **Current limitation (Tier 2 blockage): the sandbox egress proxy does
  not inject the real provider token.** The gateway's profile→policy
  conversion drops the
  `credentials:` binding (prebuilt gateway limitation), so Slack/Gmail calls
  return `invalid_auth` and the briefing shows the auth failure instead of
  real messages — until the gateway fix lands upstream. Full diagnosis and
  honest scoping: [daily-briefing.md](daily-briefing.md#why-briefings-show-auth-failures-the-gateway-does-not-deliver-provider-credentials-to-the-sandbox-policy-tier-2)
  Limits. Everything else in the demo works as described.

## Personal Assistant (Longer Setup) with on-cluster providers: chat, email and calendar

Walkthrough: [on-cluster-demo.md](on-cluster-demo.md).

- Chat, email and calendar services (Mattermost, Mailpit, Radicale) run
  inside the cluster, so you stand up three demo services instead: about
  20 minutes, once.
- Setup: services + profile placement + seeding + two
  workspaces ≈ 1.5 to 2 hours, mostly waiting; the demo itself is ~12 to
  15 minutes.
- As a consequence of the on-cluster providers, it shows more of the
  enforcement layers: a fake credential re-registration email prompting the
  agent into denied actions (calendar call denied at the sandbox proxy, exfil
  denied at egress, circumvention denied at the provider-create gate), VM
  containment of the agent, a policy-as-data capability grant through
  GitOps, and workspace provisioning.
- The grant is the story: the block surfaces the legitimate need, the
  interceptor loads profiles at startup, the new capability arrives as data
  (a YAML file), and the same request that was denied is allowed after the
  sync.

## Choosing

Short on time? Take the external-providers demo. Want to see every layer of the
guardrails in detail and can invest in the setup? Take the on-cluster demo.
Same assistant, different setup times and provider strategies.

## Charts

The demo charts are standalone helm installs from this directory:

```
helm install mailpit demo/charts/mailpit -n openshell-agents
helm install radicale demo/charts/radicale -n openshell-agents
helm install mattermost demo/charts/mattermost -n openshell-agents
```

On OpenShift with restricted-v2, Mattermost may need the service account
anyuid grant; the charts already set the security contexts and probe delays
for that case.

## Profiles

The governance profiles for the on-cluster providers are copied here as the
portable artifacts-to-place: `mailpit.yaml`, `mattermost.yaml`,
`calendar.yaml`. Copy them into `charts/governance-policy/profiles/` BEFORE
deploying the sandbox (the interceptor loads profiles at startup), or after
deployment and let Argo auto-sync.

- For EXISTING sandboxes, the sync is not enough: use the two-step
  `provider create` + `sandbox provider attach` (see the on-cluster demo).
- If the new capability is still denied after the sync, restart the
  interceptor pod: profile hot-reload does not always fire.
- In the on-cluster demo, `calendar.yaml` is the live beat-4 commit: leave it out of
  the pre-placed set if you want the genuine "this capability was not there
  before" moment.

The copies in `charts/governance-policy/profiles/` are the live source the
cluster's Argo self-heals from; keep them in place.

## Manual remediations: what is still blocked (the two-tier blockage model)

Two distinct kinds of blockage exist. The tiers are deliberately explicit so
a reader can tell at a glance which tier any failure belongs to:

**Tier 1 — blocked by missing cluster-state fixes; fixed by the manual
remediations below.** On a cluster setup without the manual remediations in
this PR, the demo does not work at all:

- **T1a. Gateway startup (npmjs egress):** the OpenClaw gateway refuses to
  start on a fresh sandbox because the slack provider profile's egress
  allowlist lacks `registry.npmjs.org`.
- **T1b. Installer apply (ArgoCD namespace / ServerSideApply):** hand-created
  Argo CD Applications must land in the cluster's Argo CD namespace
  (`openshift-gitops`), and the installer ConfigMap exceeds Argo CD's
  last-applied annotation limit.
- **T1c. MCP servers loading (harness bundle layout):** the old
  daily-briefing bundle layout is not loaded by openclaw 2026.7.1, so the
  briefing's MCP servers never load.

**Tier 2 — blocked by the prebuilt gateway; NOT fixable by any remediation
or scripting; applies to EVERY cluster (remediated or not).** The gateway
drops the profile `credentials:` section when converting the profile into
the sandbox policy, so the supervisor's egress proxy never injects the real
provider token: MCP tools load and are invocable, but Slack/Gmail calls
return `invalid_auth`. Full diagnosis:
[daily-briefing.md](daily-briefing.md#why-briefings-show-auth-failures-the-gateway-does-not-deliver-provider-credentials-to-the-sandbox-policy-tier-2).

A reader on a fresh cluster reaches a working demo (Tier 1 cleared) by doing
the three remediations by hand:

### T1a. Gateway npm egress (Tier 1)

Symptom: the OpenClaw gateway refuses to start on a fresh sandbox — it logs
"Failed to install missing configured plugin 'slack' from @openclaw/slack:
npm view failed", then "startup migrations did not complete cleanly". Cause:
the slack provider profile's egress allowlist lacks `registry.npmjs.org`
(OpenClaw auto-installs its configured provider plugins at gateway startup).
Remediation: add a `registry.npmjs.org` endpoint to BOTH
`charts/governance-policy/profiles/slack.yaml` AND
`charts/openshell-saw/files/provider-profiles/slack.yaml` — match the entry
format in `charts/governance-policy/profiles/slack.yaml` on the consolidated
`demo` state — re-apply, and let ArgoCD sync; the gateway starts. Full
detail: [daily-briefing.md](daily-briefing.md) Limits.

### T1b. Installer apply — ArgoCD namespace / ServerSideApply (Tier 1)

Symptom: a hand-created Argo CD Application for the workspace fails to sync,
or the sync dies on the installer ConfigMap. Two checks:

- Applications must land in the cluster's Argo CD namespace
  (`openshift-gitops`) — a cluster setup without the manual remediations in
  this PR has no per-namespace Argo CD, so set `spec.project`/destination
  accordingly and create the Application in `openshift-gitops`.
- The openshell-saw installer ConfigMap embeds the BOM disk + harness bundle
  (~270KB), which exceeds Argo CD's 262144-byte
  last-applied-configuration annotation limit — the template carries
  `argocd.argoproj.io/sync-options: ServerSideApply=true` (see
  `charts/openshell-saw/templates/configmap-installer.yaml` on the
  consolidated `demo` state). Verify the annotation survives when creating
  or syncing the Application by hand.

### T1c. Harness bundle layout (Tier 1)

Symptom: the briefing's MCP servers (`slack-reader`, `gmail-reader`) never
load — `tool_search` finds nothing and the briefing renders as a template
with empty Slack and Email sections. Cause: a daily-briefing bundle with the
OLD layout (plain root `plugin.json` + `mcp.json`), which openclaw 2026.7.1
does NOT load — only the Claude/Codex/Cursor layouts load (manifest at
`.claude-plugin/plugin.json`, MCP at `.mcp.json`, root placeholder
`${CLAUDE_PLUGIN_ROOT}`; note `.mcp.json` env values pass as LITERALS, so
the CA path must be hardcoded). Remediation: add
`.claude-plugin/plugin.json` (name/version/description) and `.mcp.json` with
`mcpServers` entries using `${CLAUDE_PLUGIN_ROOT}` args and
`"NODE_EXTRA_CA_CERTS": "/run/openshell-supervisor-ca/material/ca.crt"`
(the supervisor-mounted MITM proxy CA inside the sandbox container), then
restart the gateway. This is a workaround until the bundle fix lands
upstream. Detail: [daily-briefing.md](daily-briefing.md) Limits.

Tier 2 is not fixed by any of the above: it needs the prebuilt gateway's
profile→policy construction to emit the credential binding — see
[daily-briefing.md](daily-briefing.md#why-briefings-show-auth-failures-the-gateway-does-not-deliver-provider-credentials-to-the-sandbox-policy-tier-2).
