#!/usr/bin/env bash
# Post-sandbox setup for the two-VM proxy architecture.
# Writes the inter-VM bearer credential file and Gmail skill into the sandbox.
# Provider creation and attachment is handled by providers.yaml + sandbox.yaml.
#
# Expects: SANDBOX_NAME, WORKSPACE, PROV_GMAIL_READ_PROXY_KEY (from bom.env)

set -euo pipefail

SANDBOX_NAME="${1:-notebook}"
WORKSPACE="${2:-default}"
BEARER="${PROV_GMAIL_READ_PROXY_KEY:-}"

if [[ -z "${BEARER}" ]]; then
  echo "WARN: PROV_GMAIL_READ_PROXY_KEY not set — skipping proxy setup"
  exit 0
fi

WS_ARGS=""
[[ "${WORKSPACE}" != "default" ]] && WS_ARGS="--workspace ${WORKSPACE}"

# --- Write credential file into sandbox ---
CRED_FILE="/tmp/gog-access-token"
SAFE_BEARER="${BEARER//\'/\'\"\'\"\'}"
openshell ${WS_ARGS} sandbox exec -n "${SANDBOX_NAME}" --no-tty -- \
  /bin/sh -c "umask 077; printf '%s' '${SAFE_BEARER}' > ${CRED_FILE}; chmod 600 ${CRED_FILE}"
echo "Wrote inter-VM bearer to ${CRED_FILE} inside sandbox '${SANDBOX_NAME}'"

# --- Write Gmail skill override into sandbox workspace ---
openshell ${WS_ARGS} sandbox exec -n "${SANDBOX_NAME}" --no-tty -- \
  /bin/sh -c "mkdir -p /tmp/openclaw-home-${SANDBOX_NAME}/.openclaw/workspace/skills/gmail-read 2>/dev/null
cat > /tmp/openclaw-home-${SANDBOX_NAME}/.openclaw/workspace/skills/gmail-read/SKILL.md << 'SKILLEOF'
---
name: gmail-read
description: Read Gmail via gog (pre-configured, no OAuth setup needed)
---

# Gmail Read (pre-configured)

Gmail access is pre-configured via a secure proxy. Do NOT run gog auth, gog login,
or try to set up OAuth credentials. Authentication is handled automatically.

## Read emails

\`\`\`bash
gog --readonly gmail search \"newer_than:7d\" --max 10 --json --no-input --wrap-untrusted
\`\`\`

## Get a specific message

\`\`\`bash
gog --readonly gmail get <messageId> --sanitize-content --json --no-input --wrap-untrusted
\`\`\`

## Get a thread

\`\`\`bash
gog --readonly gmail thread get <threadId> --sanitize-content --json --no-input --wrap-untrusted
\`\`\`

## List labels

\`\`\`bash
gog --readonly gmail labels --json --no-input
\`\`\`

## Rules

- Always use \`--readonly\` and \`--no-input\`
- Always use \`--json --wrap-untrusted\` for parsing
- Do NOT run \`gog auth\`, \`gog login\`, or \`gog auth credentials\`
- Do NOT try to create OAuth credentials or client secrets
- The proxy only allows read operations (GET/HEAD/OPTIONS)
SKILLEOF
chmod 644 /tmp/openclaw-home-${SANDBOX_NAME}/.openclaw/workspace/skills/gmail-read/SKILL.md"
echo "Gmail read skill installed in sandbox '${SANDBOX_NAME}'"
