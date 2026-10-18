# Codex / Podman validation attempt, 2026-10-18

Result: **Failed validation**. No successful Codex inference response.

Tracking: APPENG-6705. [Support matrix](../tp-support-matrix.md).

## Environment and route

- Repository base: `5f073e8`, with the credential plumbing, Codex provider
  profiles, and HTTPS hostname rules in this change.
- OpenShift test cluster: `cluster-r4js8`; VM: `saw-tp-validation/tp-validation`.
- Fedora 44; Podman 5.8.1; OpenShell 0.1.2-rhaiv.0.
- OpenClaw 2026.9.6 (`eb377ac`), image
  `quay.io/aipcc/base-images/agentic/openclaw@sha256:896d1526ee29b53167034ba65d1c758c8da777f441ed094e19f3bcf6d7445c61`.
- Effective compute driver: Podman. The VM being hosted on OpenShift does not
  validate the Kubernetes compute driver.
- OpenShell provider: `codex-tp`, type `codex`, workspace `default`.
- OpenClaw route: `openai/gpt-6-astra`, explicit `agentRuntime.id: openclaw`;
  transport reported `openai-chatgpt-responses`.
- Authentication: host Codex subscription OAuth; no OpenAI API-key substitute.
- Native Codex app-server runtime and OAuth refresh: not tested.

## Preparation and request

1. Verified locally that the sign-in contained access/refresh tokens and account
   ID, plus an optional ID token, and that the access token had not expired.
   Credential values were not printed.
2. Imported a workspace profile. Although import reported success, subsequent
   provider creation could not find it: this gateway uses the governance
   interceptor's catalog. Added the adapted Codex profile to that catalog,
   reloaded the service, and added exact HTTPS egress rules for the Codex hosts.
   This was configuration needed for the provider, not governance validation.
3. With explicit approval, sent credentials over SSH stdin to the test VM.
   Created the provider using repeated bare `--credential CODEX_AUTH_*`
   arguments with values in the process environment, then attached it to
   `default/notebook`. Both operations succeeded.
4. Prepared an isolated OpenClaw config/auth store at
   `/sandbox/.openclaw-codex-tp`. Used the installed
   `openclaw/plugin-sdk/provider-auth` export `upsertAuthProfile` with
   `type: oauth`, `provider: openai`, access/refresh/account-ID placeholders,
   and the locally decoded access-token expiry. The bootstrap checked that
   all three values began with `openshell:resolve:` before writing them.
   The sandbox did not receive raw tokens. Config validation passed.
5. Ran the following through `openshell --gateway saw-installer sandbox exec`
   in `default/notebook`, with the isolated config/state paths and writable
   SQLite temporary directory configured:

```bash
openclaw agent --local --agent main --session-id saw-tp-codex-podman \
  --message 'Reply with exactly SAW_TP_OK. Do not use tools.' \
  --thinking low --timeout 60 --json
```

The first probe used `minimal` thinking and was rejected by the selected model
before inference. The command above uses a supported level and reached the
Codex transport. No message delivery option was enabled.

## Sanitized result

```text
Codex provider created from host OAuth credentials
Codex provider attachment: succeeded
Isolated OpenClaw OAuth profile prepared using placeholders only
Config valid: $OPENCLAW_HOME/.openclaw-codex-tp/openclaw.json

provider=openai api=openai-chatgpt-responses model=gpt-6-astra
rawError=Failed to extract accountId from token
decision=surface_error reason=auth attempt=1 retry=0 rotations=0
exit status 1
```

There was no `SAW_TP_OK` response. The command also emitted SQLite maintenance
warnings and a separate memory-embedding request's API-credit error. Neither
establishes Codex inference success or invalidity of the subscription login.

## Cause and remaining work

Inspection of the pinned image's `dist/worker/worker.mjs` confirmed that the
transport calls `extractOpenAICodexAccountId()` on the access token and decodes
the JWT payload's `https://api.openai.com/auth.chatgpt_account_id`. An OpenShell
placeholder is not a JWT. The failure occurs before the Codex inference HTTP
request can pass through the proxy for credential substitution; it does not
establish that the host login is invalid.

The OpenClaw/OpenShell adapter needs a supported way to supply account metadata
while preserving credential substitution, or a validated native Codex runtime
path. The image's `openclaw migrate list` exposes only Claude and Hermes, so the
documented Codex migration path was unavailable. No guard bypass, raw-token
copy into the sandbox, or modification of the pinned OpenClaw code was used.

This manual SDK probe is evidence of the compatibility gap, not a supported
installer recipe. Keep this cell unvalidated until an engineering-owned
deployment/inference test succeeds. Disable automatic memory embeddings in a
future focused probe to isolate the Codex request from auxiliary API activity.
