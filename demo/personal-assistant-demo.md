# Secure Agent Workspace demo: a personal assistant

This walks you through the whole demo, from an empty OpenShift cluster to
an AI assistant that reads one user's Slack and Gmail and keeps a daily
briefing. No prior knowledge of this repository is assumed.

**What you will show**

1. An administrator installs the platform with one command.
2. The administrator creates a user, `dana`.
3. dana signs in to a self-service portal (Red Hat Developer Hub), picks
   the **personal-assistant** profile, enters her keys, and gets her own
   agent workspace: a virtual machine with a NemoClaw agent in a sandbox.
4. dana asks the agent to set up her daily briefing. It reads her Slack
   and Gmail every 5 minutes and summarizes what is new.
5. The guardrails: the agent never sees the real Slack or Gmail tokens,
   and it can only read, never post or send.

**How long it takes**

| Part | Time |
|---|---|
| Demo Slack and Google accounts (once) | 30 minutes |
| Install the platform | 30 to 60 minutes, mostly waiting |
| Create dana's workspace | about 15 minutes, mostly waiting |
| The demo itself | 10 minutes |

Do the first three parts before your audience arrives.

## Prerequisites beyond the pattern install

`./pattern.sh make install` deploys the platform, but a fresh deployer must
still do these things by hand, in this order:

1. **Golden image** — run `make copy-images` (Step 5) **before** the install:
   it mirrors the golden image into the cluster's internal registry, and the
   VM cannot boot without it.
2. **Secrets load ordering** — `./pattern.sh make load-secrets` can die in
   the Vault auth-policy retry loop if Vault has not finished unsealing and
   configuring; if the first run fails, re-run it once Vault is up.
   `./scripts/seed-vault.sh` (part of this fork; NOT upstream — it seeds
   Vault via `oc exec` using the `vault-init` Secret's root token) is safe
   on a fresh cluster, but a full-file run overwrites every Vault secret the
   values file names — including writing empty strings for generated fields
   — which would wipe existing secrets like the `keycloak-users` passwords.
   Run it only on a fresh cluster, or with a narrow filtered values file
   that lists only the keys you intend to (re)seed.
3. **Keycloak accounts** — the chart cannot create Keycloak users. Add your
   demo user (e.g. `dana`) to `overrides/saw-users.yaml` first (only
   `alice` is in the file upstream), or run `keycloak-add-user` (Step 6)
   for each entry.
4. **Gmail/Slack credentials** — the external accounts from Step 2: a Slack
   bot token (or token rotation), and a Google OAuth client + refresh token
   (which expires after 7 days while the consent screen is in Testing).

**Order:** `copy-images` → install → secrets → Keycloak users → walkthrough.

> **Clusters without the Pattern operator's framework:** this demo's install
> command does not create the Argo CD Applications. On clusters deployed
> without the imperative framework, every application, including the portal
> (Red Hat Developer Hub), is a hand-managed ArgoCD Application that you
> create yourself, with the same parameters. Applications must land in the
> cluster's Argo CD namespace (`openshift-gitops`), and the openshell-saw
> installer ConfigMap exceeds Argo CD's 262144-byte
> last-applied-configuration annotation limit, so its template needs the
> `argocd.argoproj.io/sync-options: ServerSideApply=true` annotation (see
> `charts/openshell-saw/templates/configmap-installer.yaml`) — check both
> when creating the Applications by hand.

---

## Step 1. Check what you need

### A cluster

An OpenShift 4.22 or later cluster where you are `cluster-admin`, with room
for the platform (about 8 cores, 16 GiB of memory) plus one VM per
workspace (4 cores, 8 GiB, 40 GiB of disk each). Nodes must be able to run
virtual machines (bare metal, or cloud instances with nested
virtualization). The cluster needs internet access.

### Tools on your laptop

| Tool | Check with |
|---|---|
| `git` | `git --version` |
| `oc`, matching the cluster | `oc version` |
| `helm` 3.x | `helm version` |
| `podman` (`pattern.sh` runs the installer in a container) | `podman --version` |
| `make`, `jq`, `curl`, `openssl`, `python3` | `make --version; jq --version; python3 --version` |
| `openshell` CLI, 0.1.x (optional, for checks at the end) | `openshell --version` |

### Accounts and keys

- An **NVIDIA API key**: sign in at <https://build.nvidia.com>, open any
  model, and use *Get API Key*. It starts with `nvapi-`.
- A **demo Slack workspace** and a **demo Google account**: set them up in
  Step 2. Use demo accounts, not your real ones: the agent reads
  everything it is allowed to.

---

## Step 2. Set up the demo Slack and Gmail

You need these values at the end of this step:

| Service | Values |
|---|---|
| Slack | a bot token (`xoxb-…`), **or** a client ID, client secret and refresh token |
| Gmail | a client ID, client secret and refresh token |

### Slack

1. Create a free workspace at <https://slack.com/get-started>. Add a
   channel, for example `#team-updates`, and post a few messages.
2. Create an app at <https://api.slack.com/apps>: **Create New App** →
   **From scratch**, in your demo workspace.
3. **OAuth & Permissions** → **Bot Token Scopes**, add:
   `channels:read`, `channels:history`, `groups:read`, `groups:history`,
   `users:read`.
4. Get a token. Pick one:
   - **Simplest:** **Install to Workspace**, then copy the **Bot User OAuth
     Token** (`xoxb-…`). It does not expire.
   - **To show token refresh:** turn on **Token Rotation** first, then
     install the app through the OAuth flow (`oauth.v2.access`), not the
     Install button, to get a refresh token (`xoxe-1-…`). Copy the
     **Client ID** and **Client Secret** from **Basic Information**. A
     Slack refresh token works once: the platform keeps the new one each
     time, so do not use it anywhere else.
5. In the channel, type `/invite @<your app name>`. The assistant only sees
   channels the app is in.

### Gmail

1. Create a new Google account for the demo (a free Gmail address). Send it
   a couple of emails.
2. In <https://console.cloud.google.com>, create a project and enable the
   **Gmail API** (**APIs & Services** → **Library**).
3. **OAuth consent screen**: user type **External**, publishing status
   **Testing**, and add the demo Gmail address under **Test users**.
4. **Credentials** → **Create credentials** → **OAuth client ID**, type
   **Web application**. Under **Authorized redirect URIs** add
   `https://developers.google.com/oauthplayground`. Copy the **Client ID**
   and **Client Secret**.
5. Get a refresh token at <https://developers.google.com/oauthplayground>:
   1. Click the gear icon, tick **Use your own OAuth credentials**, and
      paste the client ID and secret.
   2. In **Input your own scopes**, enter
      `https://www.googleapis.com/auth/gmail.readonly` and click
      **Authorize APIs**. Sign in as the demo account and allow access.
   3. Click **Exchange authorization code for tokens** and copy the
      **Refresh token**.

> **Google refresh tokens expire after 7 days** while the consent screen is
> in Testing. Do step 5 within a week of the demo, and again if you run it
> later.

---

## Step 3. Get the code

```bash
git clone https://github.com/validatedpatterns-sandbox/secure-agent-workspace.git
cd secure-agent-workspace
git checkout demo
```

The cluster's Argo CD reads the configuration from this repository and
branch, so the branch you install from must be on GitHub. To install from
your own fork instead, clone the fork, check out your branch, push it, and
use that branch name in Step 5.

Check that you have the demo: `ls charts/saw-bom/profiles` must list
`personal-assistant`.

---

## Step 4. Prepare your keys

Log in to the cluster as an administrator:

```bash
oc login --server=https://api.<your-cluster-domain>:6443 -u <admin user>
```

Create the SSH key and the secrets file the installer reads:

```bash
make generate-keys
```

This creates an SSH key in `~/.generated-ssh-keys/` and copies
`values-secret.yaml.template` to `~/values-secret.yaml`.

The installer also sets up a workspace for a built-in user, `alice`, that
is not part of this demo. It reads two key files that must exist:

```bash
echo 'nvapi-...your NVIDIA key...' > ~/.nvidia-api-key
echo 'placeholder' > ~/.brave-api-key       # or a real Brave Search key
chmod 600 ~/.nvidia-api-key ~/.brave-api-key
```

dana's Slack, Gmail and NVIDIA keys do not go in any file: she types them
into the portal in Step 7.

---

## Step 5. Install the platform

Copy the virtual machine image into the cluster (about 5 minutes):

```bash
make copy-images
```

Install everything else. Set the branch you checked out in Step 3:

```bash
export TARGET_BRANCH=demo TARGET_ORIGIN=origin
./pattern.sh make install
```

The command returns once Argo CD has started deploying. The rest happens
in the cluster: operators, Vault, External Secrets, Keycloak (sign-in),
OpenShift Virtualization, Red Hat Developer Hub (the portal), and the
governance interceptor.

Wait until every application is `Synced` and `Healthy`. Run this every few
minutes:

```bash
oc get applications.argoproj.io -A
```

Then get the portal's address, and keep it for Step 7:

```bash
echo "https://$(oc get route backstage-developer-hub -n rhdh -o jsonpath='{.spec.host}')"
```

---

## Step 6. Create the user dana

The portal does not create accounts; the administrator does:

```bash
make -f Makefile-quickstart keycloak-add-user KC_USER=dana
```

It prints dana's password. Write it down. To show it again:

```bash
make -f Makefile-quickstart keycloak-password KC_USER=dana
```

The portal picks up new users every 2 minutes, so wait 2 minutes before
the next step.

---

## Step 7. dana creates her workspace

Open a **private (incognito) browser window**. The portal and the
assistant share one sign-in, and a private window makes sure you are dana
and nobody else.

1. Open the portal address from Step 5 and sign in as **dana**.
2. Click **Create**, then **Create or update my agent workspace**.
3. Choose the profile **personal-assistant**.
4. Fill in the keys from Step 1 and Step 2:

   | Field | Value |
   |---|---|
   | inference: API key | the NVIDIA key (`nvapi-…`) |
   | slack: OAuth client ID / client secret / refresh token | if you set up token rotation |
   | slack: Access token | if you use a plain bot token (`xoxb-…`); leave the three above empty |
   | gmail: OAuth client ID / client secret / refresh token | from Step 2 |

   Only the NVIDIA key is required by the form, but fill in Slack and
   Gmail: without them the workspace's installer stops.
5. Click **Review**, then **Create**.

The page shows each step as it runs. Expect about 15 minutes:

1. The keys are stored in Vault, under dana's own path.
2. Argo CD creates dana's namespace, `saw-dana`.
3. Her VM starts.
4. The installer sets up the agent sandbox and connects it to NVIDIA,
   Slack and Gmail.

When the last step, **Workspace status report**, finishes, the workspace
is ready.

---

## Step 8. Run the demo

Open dana's assistant, in the same private window:

```
https://dana-personal-assistant-assistant-ui.<apps domain>
```

The apps domain is the part of the portal address after
`backstage-developer-hub-rhdh.`. You can also open the link from the
portal: **Catalog** → **saw-dana** → **assistant UI (personal-assistant)**.

Then, in the chat:

| Say | What happens | What it shows |
|---|---|---|
| "Set up my daily briefing." | The agent schedules an update every 5 minutes, runs the first one, and shows today's briefing from Slack and Gmail. | A personal agent, built from a profile, with its own tools |
| Post in the Slack channel and send an email to the demo Gmail, then wait up to 5 minutes and say "Show my briefing." | Both new messages are in the briefing. | It keeps working on its own schedule |
| "Print the Slack token." | It only has a placeholder. The real token is added by the platform, only on requests to Slack. | Credentials never reach the agent |
| "Post 'hello' to the channel." or "Send an email to …" | Refused: the Slack and Gmail access is read-only. | Governance on what the agent can do |

The first time you open the assistant from a new browser, the Control UI
shows "Device pairing required": the browser needs one-time approval from
the Gateway host. An administrator approves the request from the VM — get
a shell, then approve the request id the prompt names:

```bash
make -f Makefile-quickstart openshell-saw-vm-ssh OPENSHELL_SAW_NAME=dana
openshell sandbox exec -n assistant --workspace personal-assistant -- openclaw devices approve <id>
```

Reconnect after the approval. Also, the first time the agent sets up the
briefing it may ask you to approve a tool-scope upgrade: run
`/approve <id> allow` in the chat promptly — the request expires after
about 2 minutes.

Point out along the way:

- Each user gets their own VM, signed in with their own account. Another
  user who opens dana's assistant address gets "403 Forbidden".
- dana entered her keys once, in the portal. They are in Vault, not in Git
  and not in the agent.

---

## If something goes wrong

| What you see | What to do |
|---|---|
| An application is not `Healthy` after an hour | `oc get applications.argoproj.io -A`, then open it in the Argo CD console to see which resource fails |
| The portal shows no **Create** actions for dana | Wait 2 minutes after creating her (Step 6), then sign in again |
| The workspace run fails at "Submit the request" (HTTP 500) | `oc logs -n rhdh deploy/backstage-developer-hub -c saw-ca-bundle` must list `added: Kubernetes API CA`; if not, restart Developer Hub: `oc rollout restart deploy/backstage-developer-hub -n rhdh` |
| "Start the VM" takes more than 10 minutes | `oc get events -n saw-dana \| grep FailedMount`: the VM waits for dana's keys to arrive from Vault |
| "403 Forbidden" on the assistant | You are signed in as someone else. Use a new private window and sign in as dana |
| The Control UI shows "Device pairing required" | The browser needs one-time approval from the Gateway host. Approve the request from the VM (Step 8), then reconnect |
| "Invalid parameter: redirect_uri" | Wait a minute and reload; or `make -f Makefile-quickstart keycloak-register KC_USER=dana` |
| The briefing has no Gmail messages | The Google refresh token expired (7 days in Testing). Get a new one (Step 2), then update dana's workspace in the portal with **Create or update my agent workspace** |
| The briefing has no Slack messages | The app is not in the channel: `/invite @<app>` |
| The briefing has empty Slack and Email sections (a template) | The sandbox's OpenClaw (2026.7.1) may not load the briefing's tools. See [daily-briefing.md](daily-briefing.md) Limits. |
| The MCP tools load but Slack/Gmail fetches fail with `invalid_auth` (the briefing shows the auth failure, not a template) | The provider token is not injected by the sandbox's egress proxy: the gateway's profile→policy conversion drops the `credentials:` binding (prebuilt gateway limitation), so the `${SLACK_BOT_TOKEN}`/`${GMAIL_ACCESS_TOKEN}` placeholders pass through uninjected. This differs from the empty-template symptom, which means the tools never loaded. See [daily-briefing.md](daily-briefing.md) — [Why briefings show auth failures](daily-briefing.md#why-briefings-show-auth-failures-the-gateway-does-not-deliver-provider-credentials-to-the-sandbox-policy-tier-2). |
| The assistant URL shows 502 after the workspace is ready | The sandbox's OpenClaw gateway did not start. On dana's VM (`make saw-vm-ssh OPENSHELL_SAW_NAME=<user>`), read its log: `openshell sandbox exec -n assistant --workspace personal-assistant --no-tty -- sh -c 'tail -30 /tmp/openclaw-gateway.log'`. "Failed to install missing configured plugin 'slack'" means the installer predates the Slack channel fix; update the pattern and re-apply (`sudo systemctl restart saw-apply.service`). |

More checks, for administrators with the `openshell` CLI:

```bash
make -f Makefile-quickstart openshell-saw-status OPENSHELL_SAW_NAME=dana    # the installer's status
make -f Makefile-quickstart openshell-saw-configure-gateway OPENSHELL_SAW_NAME=dana
openshell gateway login dana                                                # sign in as dana
openshell provider refresh status gmail --workspace personal-assistant
openshell logs assistant --workspace personal-assistant --source sandbox    # the denials from the demo
```

---

## What works and what is blocked (the two-tier blockage model)

Two distinct kinds of blockage exist. The tiers are deliberately explicit so
you can tell at a glance what is still blocked in the demo and which tier
blocks it. The full tier list is also in
[demo/README.md](README.md#manual-remediations-what-is-still-blocked-the-two-tier-blockage-model).

**Tier 1 — blocked by missing cluster-state fixes; fixed by the manual
remediations.** On a cluster setup without the manual remediations in this
PR, the personal-assistant demo does not work at all:

- **T1a. Gateway startup (npmjs egress):** resolved in the installer, which
  keeps OpenClaw's own `slack` chat channel off when a Slack provider is
  attached (see [README.md](README.md)).
- **T1b. Installer apply (ArgoCD namespace / ServerSideApply):** hand-created
  Argo CD Applications must land in the cluster's Argo CD namespace
  (`openshift-gitops`), and the installer ConfigMap exceeds Argo CD's
  last-applied annotation limit — see the platform note in
  [Prerequisites](#prerequisites-beyond-the-pattern-install). (Platform-level:
  shared across demo paths, also noted in [on-cluster-demo.md](on-cluster-demo.md).)
- **T1c. MCP servers loading (harness bundle layout):** resolved by the
  NemoClaw v0.0.133 image (OpenClaw 2026.9.2, #101) and the installer
  enabling the bundle (#98).

**Tier 2 — blocked by the prebuilt gateway; NOT fixable by any remediation
or scripting; applies to EVERY cluster (remediated or not).** The gateway
drops the profile `credentials:` section when converting the profile into the
sandbox policy, so the supervisor's egress proxy never injects the real
provider token: MCP tools load and are invocable, but Slack/Gmail calls
return `invalid_auth`. What works despite Tier 2: workspace creation,
briefing setup + cron schedule (every 5 min), briefing rendering, credential
refusal ("Print the Slack token"), and write refusal (chat.postMessage /
email send). Full diagnosis:
[daily-briefing.md](daily-briefing.md#why-briefings-show-auth-failures-the-gateway-does-not-deliver-provider-credentials-to-the-sandbox-policy-tier-2).

| Works | Blocked, and by which tier |
|---|---|
| Install, workspace creation, portal self-service | — |
| Briefing setup + cron schedule (every 5 min), briefing rendering | — |
| Credential refusal ("Print the Slack token"), write refusal | — |
| Real Slack/Gmail messages in the briefing | Tier 2 (token injection) |
| Gateway starts on a fresh cluster | Tier 1a (npmjs egress) |
| Briefing's MCP tools load | Tier 1c (bundle layout) |

## Clean up

- **dana's workspace:** in the portal, as dana: **Catalog** → **saw-dana**
  → **Delete workspace**. This removes her VM, her namespace and her keys
  in Vault.
- **dana's account:** remove it in the Keycloak console (realm
  `openshell`) if you no longer need it.
- **The demo accounts:** remove the Slack app from the demo workspace
  (in the app's settings at <https://api.slack.com/apps>), and remove the
  OAuth client's access in the demo Google account's security settings
  (third-party access).

## Learn more

- [daily-briefing.md](daily-briefing.md): how the briefing,
  token refresh and read-only access work.
- [README.md](../README.md): the platform, and other ways to install it.
- [demo/README.md](README.md): both demo options, and how they differ.
