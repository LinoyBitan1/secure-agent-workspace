# Demo options

Two walks of the SAME personal assistant. The honest axis is the provider
strategy: point the providers at external accounts, or run the services
inside the cluster. Choose by what you can set up: accounts or services.

## Personal Assistant (Quick Demo) with external providers: Slack and Gmail

Step-by-step walkthrough: [personal-assistant-demo.md](personal-assistant-demo.md)
(how the briefing works under the hood: [daily-briefing.md](daily-briefing.md)).

- The agent reads real Slack and Gmail, so you need two external demo
  accounts (Slack app, Google Cloud OAuth client): about 30 minutes, once.
- Quick to run: one workspace, one prompt, a ~10-minute demo.
- Same platform install, same profile shape: one NemoClaw sandbox with the
  `daily-briefing` harness bundle, NVIDIA inference, read-only Slack and
  Gmail providers, and token placeholders the agent never resolves.
- Self-service via the Red Hat Developer Hub portal: add your demo user
  (e.g. `dana`) to `overrides/saw-users.yaml` first, then they pick the
  profile, enter their keys, and get their own workspace.
- The earlier "Tier 2" limitation (Slack and Gmail answering
  `invalid_auth`) is resolved: the egress proxy does inject the real token;
  the readers were sending OpenClaw's literal `${SLACK_BOT_TOKEN}` text.
  See [daily-briefing.md](daily-briefing.md#why-briefings-showed-auth-failures-resolved).

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

- **T1a. Gateway startup (npmjs egress):** resolved in the installer. It
  turns OpenClaw's own `slack` chat channel off when a Slack provider is
  attached, so the gateway no longer tries to install `@openclaw/slack`
  from npm; no `registry.npmjs.org` egress is needed.
- **T1b. Installer apply (ArgoCD namespace / ServerSideApply):** hand-created
  Argo CD Applications must land in the cluster's Argo CD namespace
  (`openshift-gitops`), and the installer ConfigMap exceeds Argo CD's
  last-applied annotation limit.
- **T1c. MCP servers loading (harness bundle layout):** resolved. The
  NemoClaw v0.0.133 image (#101) ships OpenClaw 2026.9.2, which loads the
  bundle's `plugin.json` and `mcp.json`, and the installer enables the
  bundle (#98).

**Tier 2 (resolved): Slack and Gmail answered `invalid_auth`.** Not the
gateway: the egress proxy injects the real token (curl in the sandbox,
sending only the placeholder, gets `ok: true` from Slack). OpenClaw passed
the bundle's `${SLACK_BOT_TOKEN}` to the reader as literal text; the
installer now declares the readers in `openclaw.json`, where OpenClaw fills
in the placeholder. See
[daily-briefing.md](daily-briefing.md#why-briefings-showed-auth-failures-resolved).

A reader on a fresh cluster reaches a working demo (Tier 1 cleared) by doing
the three remediations by hand:

### T1a. Gateway npm egress (resolved)

Symptom, before the fix: the OpenClaw gateway refused to start on a fresh
sandbox. It logged "Failed to install missing configured plugin 'slack'
from @openclaw/slack: npm view failed", and the UI answered 502. Cause:
with the Slack provider attached, OpenClaw treated its own `slack` chat
channel as configured and tried to install its plugin from npm. The
installer now sets `channels.slack.enabled: false` in every sandbox with a
Slack provider; the provider is only for the harness's governed reads.

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

### T1c. Harness bundle layout (resolved)

Symptom, before the fix: the briefing's MCP servers (`slack-reader`,
`gmail-reader`) never loaded, and the briefing rendered as an empty
template. Cause: OpenClaw 2026.7.1 read only the Claude layout
(`.claude-plugin/plugin.json`, `.mcp.json`). The NemoClaw v0.0.133 image
(#101) ships OpenClaw 2026.9.2, which reads the bundle's own `plugin.json`
and `mcp.json`; the installer enables the bundle, which 2026.9.x otherwise
keeps disabled (#98). No hand-made layout is needed.

Tier 2 is resolved too; see above.
