# Gmail gog Setup Runbook (OpenShell + OpenClaw)

This runbook prepares the two files required by `make configure-gmail-refresh`:

- OAuth Desktop client JSON
- gog token export JSON containing `refresh_token`

Use this when the interactive flow says "I need to grab/create new files first."

## Inputs

Set these before you start:

```bash
export GOG_PROJECT_ID="sa-001"
export GOG_ACCOUNT="saurabh74@gmail.com"
export GOG_DIR="$HOME/gog"
install -d -m 700 "$GOG_DIR"
```

## 1) Enable Gmail API in your team-owned project

```bash
gcloud services enable gmail.googleapis.com --project="$GOG_PROJECT_ID"
gcloud services list --enabled --project="$GOG_PROJECT_ID" \
  --filter='config.name:gmail.googleapis.com' --format='value(config.name)'
```

The second command must print `gmail.googleapis.com`.

## 2) Create project-owned Desktop OAuth client

Open these URLs (replace project id if needed):

- [Project home](https://console.cloud.google.com/home/dashboard)
- [Enable Gmail API](https://console.cloud.google.com/apis/library/gmail.googleapis.com)
- [OAuth consent](https://console.cloud.google.com/apis/credentials/consent)
- [Credentials page](https://console.cloud.google.com/apis/credentials)

On Credentials:

- Create OAuth client ID
- Application type: Desktop app
- Download JSON and save as:

```bash
install -m 600 "/path/to/downloaded-client.json" "$GOG_DIR/client_secret.json"
```

## 3) Verify OAuth client belongs to the same project

```bash
oauth_project_number="$(
  jq -er '.installed.client_id | split("-")[0]' "$GOG_DIR/client_secret.json"
)"
expected_project_number="$(
  gcloud projects describe "$GOG_PROJECT_ID" --format='value(projectNumber)'
)"
test "$oauth_project_number" = "$expected_project_number"
unset oauth_project_number expected_project_number
```

If that test fails, stop and create a new Desktop client in the correct project.

## 4) Authorize Gmail read-only with gog

Use a temporary local keyring environment:

```bash
export GOG_HOME="$GOG_DIR/auth"
export GOG_KEYRING_BACKEND=file
install -d -m 700 "$GOG_HOME"
read -rsp "Temporary gog keyring password: " GOG_KEYRING_PASSWORD; echo
export GOG_KEYRING_PASSWORD
```

Store the OAuth client and authorize:

```bash
gog auth credentials set "$GOG_DIR/client_secret.json"
gog --readonly auth add "$GOG_ACCOUNT" \
  --services gmail --gmail-scope readonly --manual --force-consent
```

Then validate:

```bash
gog auth list --check
gog auth doctor --check
```

## 5) Export token file for OpenShell refresh setup

```bash
gog auth tokens export "$GOG_ACCOUNT" --out "$GOG_DIR/gog-token-export.json"
chmod 600 "$GOG_DIR/gog-token-export.json"
jq -er '.refresh_token' "$GOG_DIR/gog-token-export.json" >/dev/null
```

## 6) Run OpenShell refresh configuration

From this repo:

```bash
make configure-gmail-refresh \
  GCP_PROJECT_ID="$GOG_PROJECT_ID" \
  GMAIL_ACCOUNT="$GOG_ACCOUNT" \
  CLIENT_JSON="$GOG_DIR/client_secret.json" \
  TOKEN_EXPORT="$GOG_DIR/gog-token-export.json"
```

Alternative (local gog authorization + temporary token export managed by script):

```bash
make configure-gmail-refresh \
  GCP_PROJECT_ID="$GOG_PROJECT_ID" \
  GMAIL_ACCOUNT="$GOG_ACCOUNT" \
  AUTHORIZE_LOCAL=1 \
  CLIENT_JSON="$GOG_DIR/client_secret.json"
```

## Security notes

- Do not commit or paste OAuth client JSON, refresh tokens, or token exports.
- Keep Gmail scope to `gmail.readonly`.
- Prefer team-owned OAuth clients in the same project where Gmail API is enabled.
