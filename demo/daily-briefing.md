# Personal assistant: a daily Slack and Gmail briefing

The `personal-assistant` SAW-BOM profile gives a user one workspace,
`personal-assistant`, with a NemoClaw sandbox, `assistant`, that keeps a
daily briefing of their Slack and Gmail messages. Its providers are NVIDIA
(inference), Slack and Gmail; it has no web search. Asked to, the agent
updates the briefing every 5 minutes with whatever arrived since the last
update. For the whole demo, from install to the briefing, see
[the personal assistant demo](personal-assistant-demo.md).

What makes it safe to hand an agent the user's Slack and mail:

| Layer | What it does |
|---|---|
| Providers `slack`, `gmail` | Read-only profiles (`charts/governance-policy/profiles`): GET only, on the listed Slack and Gmail API paths, from `node` or `curl` only. |
| Credential refresh | The gateway holds the OAuth client secret and refresh token, and refreshes the access token before it expires (OpenShell `provider refresh`, `oauth2-refresh-token`). Slack's rotated refresh tokens are kept. |
| Placeholders | The sandbox sees `SLACK_BOT_TOKEN` and `GMAIL_ACCESS_TOKEN` as placeholders. The egress proxy puts the current token in only on requests to the profile's endpoints. |
| Harness bundle `daily-briefing` | The skill and two MCP servers (`slack-reader`, `gmail-reader`) are mounted read-only at `/sandbox/harness`. Each server declares the profile that governs it, and the installer refuses the bundle unless the gateway serves that profile and the sandbox has the provider. |

## The bundle

`harness-bundles/daily-briefing` (CI publishes it as an image) and the same
tree inline in `charts/saw-bom/harness/daily-briefing`, which the profile
uses (`harnessRef: {name: daily-briefing}`):

```
harness.yaml                    governance: slack-reader -> slack, gmail-reader -> gmail
plugin.json, mcp.json           Agent Plugins bundle: OpenClaw 2026.9.x loads skills/
                                and the MCP servers in mcp.json from the bundle root
skills/daily-briefing/SKILL.md  update, schedule (cron tool, every 5 min), show
mcp/slack-reader.mjs            tool new_messages: today's messages since the last call
mcp/gmail-reader.mjs            tool new_messages: today's mail since the last call
mcp/briefing-lib.mjs            stdio MCP loop and the store in /sandbox/briefing
```

The servers keep their state and the day's messages in
`/sandbox/briefing/` (`state-slack.json`, `state-gmail.json`,
`<day>/items.jsonl`); the agent writes `<day>/briefing.md`.

Harness bundles are mounted when a sandbox is created, and `nemoclaw onboard`
cannot add a mount on podman. For a NemoClaw sandbox with a `harnessRef` the
installer creates the sandbox itself, from the NemoClaw image with the
bundle mounted, and configures OpenClaw in it, as it does after onboarding.
A NemoClaw sandbox created earlier by `nemoclaw onboard` is created again once
(its `/sandbox` is not kept).

## Slack app and Google OAuth

Full setup walkthroughs — Slack app, scopes, token rotation, and the Google
OAuth client with a `gmail.readonly` refresh token — are in
[the personal assistant demo](personal-assistant-demo.md), Step 2.

What the Secrets look like:

| Secret | Keys |
|---|---|
| `slack` | With token rotation: `client_id`, `client_secret`, `refresh_token`. Without: a plain bot token in `bot_token`, used as is with no refresh. |
| `gmail` | `client_id`, `client_secret`, `refresh_token` (scope `gmail.readonly`). Access tokens last an hour; the gateway refreshes them 5 minutes before they expire. |

## Turn it on for a user

Add your demo user to `overrides/saw-users.yaml` (only `alice` is in the
file upstream) — or run `keycloak-add-user` for each entry you add:

```yaml
users:
  - name: dana        # e.g. your demo user
    profiles:
      - personal-assistant
```

saw-users sees from the profile catalog that the sandbox needs its bundle
(`harnessRequired`) and sets `harnessEnabled` and `allowDriverConfig` for the
user. It also syncs the `slack` and `gmail` Secrets from Vault and mounts
them on the VM.

Load the keys into Vault: uncomment the `slack` and `gmail` entries in your
`values-secret` file (see `values-secret.yaml.template`) and run
`./pattern.sh make load-secrets`. They go to `secret/data/hub/slack` and
`secret/data/hub/gmail` (or under the user's `vaultPrefix`). The
`personal-assistant` profile in the portal asks for the same fields and
stores them under the user's own Vault path; for signing in and entering
the keys, see [the personal assistant demo](personal-assistant-demo.md),
Steps 5-7.

Check on the VM, as the installer's identity:

```
openshell provider refresh status gmail --workspace personal-assistant
openshell provider refresh status slack --workspace personal-assistant
```

## Demo

For the demo chat script ("Set up my daily briefing", the live update, the
token and post denials), see [the personal assistant demo](personal-assistant-demo.md),
Step 8. What that step does not show: the sandbox log's denial entries,

```
openshell logs assistant --workspace personal-assistant --source sandbox
```

## Limits

- The bundle needs OpenClaw 2026.9.x (the NemoClaw v0.0.133 image, #101):
  2026.7.1 loaded only the Claude layout (`.claude-plugin/plugin.json`,
  `.mcp.json`) and left this bundle's MCP servers unloaded. On 2026.9.x the
  installer also enables the bundle (#98), which otherwise stays disabled
  ("not in allowlist"). Verify after the first apply: ask the assistant which
  Slack and Gmail tools it has; it names `slack-reader__new_messages` and
  `gmail-reader__new_messages`.
  The schedule uses the agent's `cron` tool; if that OpenClaw has none,
  schedule the update from the OpenClaw UI's cron page.
- OpenClaw 2026.9.x expands only `${PLUGIN_ROOT}` and `${PLUGIN_DATA}` in a
  bundle's `mcp.json`; `${SLACK_BOT_TOKEN}` and `${NODE_EXTRA_CA_CERTS}`
  reached the readers as literal text, so Slack answered `invalid_auth` and
  TLS through the egress proxy failed (`SELF_SIGNED_CERT_IN_CHAIN`). The
  installer now re-declares both readers under `mcp.servers` in
  `openclaw.json`, where OpenClaw substitutes the provider placeholders and
  the CA settings (see [harness bundles](../docs/harness-bundles.md)).
  The readers also load the proxy CA file themselves
  (`/run/openshell-supervisor-ca/material/ca.crt`), as a second line.
- The sandbox gateway can hang and die mid-conversation: a model call through
  the egress proxy can stall with no timeout. Re-run the in-VM installer apply
  (`systemctl restart saw-apply.service`) and continue — the agent's sessions
  live on disk and survive. Note: re-applying the installer re-creates the
  sandbox if it is broken, which wipes `/sandbox` (the briefing state), not
  the sessions.
- With the Slack provider attached, OpenClaw treats its own `slack` chat
  channel as configured and, at gateway startup, tries to install
  `@openclaw/slack` from `registry.npmjs.org`, which the sandbox's egress
  policy denies; the gateway then does not start and the UI answers 502
  (verified on-cluster). The installer now sets
  `channels.slack.enabled: false` in every sandbox with a Slack provider:
  the provider is for the harness's governed reads, not for an OpenClaw
  chat channel, so no npm egress is needed.
- The NemoClaw image (`ghcr.io/validatedpatterns-sandbox/nemoclaw-sandbox:latest`,
  NemoClaw v0.0.133 since #101) ships OpenClaw 2026.9.2, which loads the
  bundle's MCP servers; 2026.7.1 loaded only its skills. On 2026.9.x the
  installer enables the bundle (`openclaw plugins enable`, #98), since a
  bundle on `plugins.load.paths` stays disabled otherwise.
- Running processes keep their environment: a provider attached to a running
  sandbox reaches OpenClaw after its gateway restarts, which the installer
  does when the sandbox's providers change.
- A refresh failure that needs the user (a revoked grant) shows as
  `reauthorize` in `provider refresh status`. Put a new refresh token in
  Vault; the installer configures it on its next run.

## Why briefings showed auth failures (resolved)

Symptom: the briefing's MCP tools loaded, but Slack calls returned
`invalid_auth` (and, before that, TLS failed with
`SELF_SIGNED_CERT_IN_CHAIN`).

An earlier diagnosis blamed the gateway for not passing the provider's
credential binding to the sandbox policy. Checked live, that is not it: in
the same sandbox, `curl -H "Authorization: Bearer $SLACK_BOT_TOKEN"
https://slack.com/api/auth.test`, sending only the placeholder
(`openshell:resolve:env:…`), gets `"ok": true`. The proxy injects the real
token, and the stored token is valid.

The cause was OpenClaw: it expands only `${PLUGIN_ROOT}`, `${PLUGIN_DATA}`
and `${CLAUDE_PLUGIN_ROOT}` in a bundle's `mcp.json`, and starts a stdio
server with almost no environment. The reader got the literal text
`${SLACK_BOT_TOKEN}`, which the proxy does not recognise, and the literal
`${NODE_EXTRA_CA_CERTS}`. The installer now re-declares each bundle MCP
server under `mcp.servers` in `openclaw.json`, where OpenClaw substitutes
`${VAR}` from the gateway's environment (the placeholders and the CA
settings). A server declared that way read `#all-gtc-demo` live.

## On-cluster notes: the two-tier blockage model

The three platform-level fixes this consolidated state carries are Tier 1
blockages — on a cluster setup without the manual remediations in this PR,
the demo does not work at all (also listed in
[README.md](README.md#manual-remediations-what-is-still-blocked-the-two-tier-blockage-model)):

1. **T1a. Gateway npm egress** — resolved: the installer keeps OpenClaw's
   own `slack` chat channel off (see the limit above).
2. **T1b. ArgoCD namespace / ServerSideApply** — see README.
3. **T1c. Harness bundle layout** — resolved: OpenClaw 2026.9.2 in the
   NemoClaw v0.0.133 image (#101) reads the bundle's own layout, and the
   installer enables the bundle (#98).

The auth failures described above are resolved; nothing in this demo is
blocked by the gateway.
