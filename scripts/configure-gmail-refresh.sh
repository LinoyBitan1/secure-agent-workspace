#!/usr/bin/env bash
# Configure Gmail OAuth refresh on the integrations VM gateway.
#
# This script uploads the OAuth client JSON and refresh token to the
# integrations VM, updates the gmail-read provider profile with refresh
# support, configures the refresh material, and verifies the first token
# rotation.
#
# Prerequisites:
#   - Integrations VM deployed with gmail-read provider already created
#   - A Desktop OAuth client JSON from your GCP project
#   - A gog token export with a valid refresh_token (gmail.readonly scope)
#
# Usage (non-interactive):
#   ./scripts/configure-gmail-refresh.sh \
#     --client-json /path/to/client_secret.json \
#     --token-export /path/to/gog-token-export.json
#
# Usage (interactive):
#   ./scripts/configure-gmail-refresh.sh
#
# Environment overrides:
#   NS                 — OpenShift namespace (default: current project)
#   INTEGRATIONS_VM    — VM name (default: openshell-saw-integ)
#   SSH_KEY_PATH       — SSH private key (default: ~/.generated-ssh-keys/sandbox-ssh)
set -euo pipefail

NS="${NS:-$(oc project -q 2>/dev/null || echo openshell-agents)}"
INTEGRATIONS_VM="${INTEGRATIONS_VM:-openshell-saw-integ}"
SSH_KEY_PATH="${SSH_KEY_PATH:-${HOME}/.generated-ssh-keys/sandbox-ssh}"
SSH_USER="${SSH_USER:-cloud-user}"
CLIENT_JSON=""
TOKEN_EXPORT=""
GMAIL_ACCOUNT="${GMAIL_ACCOUNT:-}"
GCP_PROJECT_ID="${GCP_PROJECT_ID:-}"
AUTHORIZE_LOCAL="${AUTHORIZE_LOCAL:-false}"
INSTALL_GOG_IF_MISSING="${INSTALL_GOG_IF_MISSING:-false}"
INTERACTIVE_MODE="${INTERACTIVE_MODE:-auto}"
PF_PID=""
LOCAL_AUTH_TMP=""

cleanup_on_exit() {
  [[ -n "${PF_PID}" ]] && kill "${PF_PID}" 2>/dev/null || true
  if [[ -n "${LOCAL_AUTH_TMP}" && "${LOCAL_AUTH_TMP}" == /tmp/* && -d "${LOCAL_AUTH_TMP}" ]]; then
    rm -rf -- "${LOCAL_AUTH_TMP}" 2>/dev/null || true
  fi
}
trap cleanup_on_exit EXIT

usage() {
  echo "Usage: $0 [--client-json <path>] [--token-export <path>] [--gmail-account <email>] [--gcp-project <id>] [--authorize-local] [--install-gog-if-missing] [--interactive|--non-interactive]" >&2
  exit 0
}

usage_error() {
  echo "Usage: $0 [--client-json <path>] [--token-export <path>] [--gmail-account <email>] [--gcp-project <id>] [--authorize-local] [--install-gog-if-missing] [--interactive|--non-interactive]" >&2
  exit 1
}

normalize_path() {
  local input="$1"
  input="${input#\"}"
  input="${input%\"}"
  input="${input#\'}"
  input="${input%\'}"
  case "${input}" in
    ~/*) input="${HOME}/${input#~/}" ;;
  esac
  printf '%s' "${input}"
}

first_existing_file() {
  local candidate
  for candidate in "$@"; do
    [[ -f "${candidate}" ]] && printf '%s' "${candidate}" && return 0
  done
  return 1
}

prompt_for_file() {
  local __var_name="$1"
  local prompt_text="$2"
  local default_path="${3:-}"
  local input=""
  local resolved=""

  while true; do
    if [[ -n "${default_path}" ]]; then
      read -r -p "${prompt_text} [${default_path}]: " input
      input="${input:-${default_path}}"
    else
      read -r -p "${prompt_text}: " input
    fi

    resolved="$(normalize_path "${input}")"
    if [[ -f "${resolved}" ]]; then
      printf -v "${__var_name}" '%s' "${resolved}"
      return 0
    fi
    echo "File not found: ${resolved}" >&2
  done
}

prompt_with_default() {
  local __var_name="$1"
  local prompt_text="$2"
  local default_value="${3:-}"
  local input=""

  read -r -p "${prompt_text} [${default_value}]: " input
  input="${input:-${default_value}}"
  input="$(normalize_path "${input}")"
  printf -v "${__var_name}" '%s' "${input}"
}

guide_missing_client_json_interactive() {
  local action=""
  local creds_url=""
  local gmail_api_url=""
  local consent_url=""
  local project_name=""

  creds_url="https://console.cloud.google.com/apis/credentials"
  gmail_api_url="https://console.cloud.google.com/apis/library/gmail.googleapis.com"
  consent_url="https://console.cloud.google.com/apis/credentials/consent"
  project_name="${GCP_PROJECT_ID:-<your-project-id>}"
  if [[ -n "${GCP_PROJECT_ID}" ]]; then
    creds_url="${creds_url}?project=${GCP_PROJECT_ID}"
    gmail_api_url="${gmail_api_url}?project=${GCP_PROJECT_ID}"
    consent_url="${consent_url}?project=${GCP_PROJECT_ID}"
  fi

  echo ""
  echo "OAuth client JSON is missing: ${CLIENT_JSON}"
  echo "Follow these click-by-click steps:"
  echo "  1) Open Credentials page:"
  echo "     ${creds_url}"
  echo "  2) Confirm top project selector is: ${project_name}"
  echo "  3) Enable Gmail API (if needed):"
  echo "     ${gmail_api_url}"
  echo "  4) Configure OAuth consent screen (first-time only):"
  echo "     ${consent_url}"
  echo "     - If audience is External, add ${GMAIL_ACCOUNT:-your Gmail account} as a Test user."
  echo "  5) Back on Credentials page:"
  echo "     - Click '+ Create Credentials' -> 'OAuth client ID'"
  echo "     - Application type: Desktop app"
  echo "     - Name: gog-openclaw (or any name)"
  echo "     - Click Create, then Download JSON"
  echo "  6) Save file to expected path:"
  echo "     mkdir -p \"$(dirname "${CLIENT_JSON}")\""
  echo "     mv \"\$HOME/Downloads/client_secret_\"*.json \"${CLIENT_JSON}\""
  echo "     chmod 600 \"${CLIENT_JSON}\""
  echo ""

  if command -v open >/dev/null 2>&1; then
    read -r -p "Open Google Credentials page in browser now? [Y/n]: " action
    action="${action:-Y}"
    if [[ "${action}" =~ ^[Yy]$ ]]; then
      open "${creds_url}" >/dev/null 2>&1 || true
    fi
  fi

  while [[ ! -f "${CLIENT_JSON}" ]]; do
    read -r -p "Use a different OAuth client JSON path instead? [y/N]: " action
    action="${action:-N}"
    if [[ "${action}" =~ ^[Yy]$ ]]; then
      prompt_for_file CLIENT_JSON "Path to OAuth Desktop client JSON" "${CLIENT_JSON}"
      break
    fi
    read -r -p "Press Enter after saving the file at ${CLIENT_JSON}..." action
    if [[ ! -f "${CLIENT_JSON}" ]]; then
      echo "Still not found: ${CLIENT_JSON}"
    fi
  done
}

collect_credentials_interactively() {
  local choice=""
  local default_client=""
  local default_token=""
  local target_dir="${HOME}/gog"
  local gmail_input=""
  local project_input=""
  local ready_choice=""

  default_client="$(
    first_existing_file \
      "${HOME}/gog/client_secret.json" \
      "${HOME}/gog/gog-client-secret.json" \
      "${HOME}/Downloads/client_secret.json" \
      "${HOME}/Downloads/gog-client-secret.json" \
      "./client_secret.json" \
      "./gog-client-secret.json" \
      "${CLIENT_JSON:-}" || true
  )"
  default_token="$(
    first_existing_file \
      "${HOME}/gog/gog-token-export.json" \
      "${HOME}/Downloads/gog-token-export.json" \
      "./gog-token-export.json" \
      "${TOKEN_EXPORT:-}" || true
  )"

  echo ""
  echo "Credential setup mode:"
  while true; do
    read -r -p "Gmail address to authorize${GMAIL_ACCOUNT:+ [${GMAIL_ACCOUNT}]}: " gmail_input
    gmail_input="${gmail_input:-${GMAIL_ACCOUNT:-}}"
    if [[ "${gmail_input}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
      GMAIL_ACCOUNT="${gmail_input}"
      break
    fi
    echo "Please enter a valid email address (example: you@gmail.com)." >&2
  done
  while true; do
    read -r -p "Google Cloud project id/name${GCP_PROJECT_ID:+ [${GCP_PROJECT_ID}]}: " project_input
    project_input="${project_input:-${GCP_PROJECT_ID:-}}"
    if [[ -n "${project_input}" ]]; then
      GCP_PROJECT_ID="${project_input}"
      break
    fi
    echo "Project id/name cannot be empty." >&2
  done
  echo "  1) Use existing files"
  echo "  2) I need to grab/create new files first"
  read -r -p "Select [1]: " choice
  choice="${choice:-1}"

  if [[ "${choice}" == "2" ]]; then
    prompt_with_default target_dir "Credential directory for new files" "${HOME}/gog"
    mkdir -p "${target_dir}"
    chmod 700 "${target_dir}" 2>/dev/null || true
    if [[ -z "${default_client}" ]]; then
      default_client="${target_dir}/client_secret.json"
    fi
    if [[ -z "${default_token}" ]]; then
      default_token="${target_dir}/gog-token-export.json"
    fi

    echo ""
    echo "Before continuing, prepare two files:"
    echo "  - In project '${GCP_PROJECT_ID}', create/use a Desktop OAuth client"
    echo "  - Authorize Gmail account: ${GMAIL_ACCOUNT}"
    echo "  - Download the OAuth JSON to: ${default_client}"
    echo "  - Generate/export gog token JSON to: ${default_token}"
    echo "  - Token export must include refresh_token and gmail.readonly scope"
    echo ""
    echo "Google Console links for project '${GCP_PROJECT_ID}':"
    echo "  - Project home: https://console.cloud.google.com/home/dashboard?project=${GCP_PROJECT_ID}"
    echo "  - Enable Gmail API: https://console.cloud.google.com/apis/library/gmail.googleapis.com?project=${GCP_PROJECT_ID}"
    echo "  - OAuth consent: https://console.cloud.google.com/apis/credentials/consent?project=${GCP_PROJECT_ID}"
    echo "  - Credentials page: https://console.cloud.google.com/apis/credentials?project=${GCP_PROJECT_ID}"
    echo ""
    echo "Suggested steps:"
    echo "  1) Enable Gmail API."
    echo "  2) Configure OAuth consent screen."
    echo "  3) Create OAuth client ID -> Desktop app."
    echo "  4) Download JSON to: ${default_client}"
    echo "  5) Generate/export gog token JSON to: ${default_token}"
    echo "  6) Detailed runbook: docs/gmail-gog-openclaw-runbook.md"
    if command -v gog >/dev/null 2>&1; then
      echo "Tip: run 'gog auth --help' and 'gog auth export --help' for exact commands."
      echo "Example commands:"
      echo "  gog auth credentials set ${default_client}"
      echo "  gog --readonly auth add ${GMAIL_ACCOUNT} --services gmail --gmail-scope readonly --manual --force-consent"
      echo "  gog auth tokens export ${GMAIL_ACCOUNT} --out ${default_token}"
    else
      echo "Tip: if 'gog' is not installed here, generate token export on another machine and copy it locally."
    fi
    echo ""

    while true; do
      read -r -p "Press Enter when files are ready at those paths, or type 'paths' to enter custom paths: " ready_choice
      ready_choice="${ready_choice:-ready}"
      if [[ "${ready_choice}" == "paths" ]]; then
        prompt_for_file CLIENT_JSON "Path to OAuth Desktop client JSON" "${default_client}"
        prompt_for_file TOKEN_EXPORT "Path to gog token export JSON" "${default_token}"
        return 0
      fi
      if [[ -f "${default_client}" && -f "${default_token}" ]]; then
        CLIENT_JSON="${default_client}"
        TOKEN_EXPORT="${default_token}"
        return 0
      fi
      echo "Files not found yet:"
      [[ -f "${default_client}" ]] || echo "  missing: ${default_client}"
      [[ -f "${default_token}" ]] || echo "  missing: ${default_token}"
    done
  fi

  echo "Using Gmail '${GMAIL_ACCOUNT}' and project '${GCP_PROJECT_ID}'."
  prompt_for_file CLIENT_JSON "Path to OAuth Desktop client JSON" "${default_client}"
  prompt_for_file TOKEN_EXPORT "Path to gog token export JSON" "${default_token}"
}

validate_oauth_client_project_ownership() {
  local oauth_project_number=""
  local expected_project_number=""

  [[ -z "${GCP_PROJECT_ID}" ]] && return 0

  if ! command -v gcloud >/dev/null 2>&1; then
    echo "WARN: gcloud not found; skipping OAuth client ownership check for project '${GCP_PROJECT_ID}'." >&2
    return 0
  fi

  oauth_project_number="$(jq -er '.installed.client_id | split("-")[0]' "${CLIENT_JSON}" 2>/dev/null || true)"
  expected_project_number="$(gcloud projects describe "${GCP_PROJECT_ID}" --format='value(projectNumber)' 2>/dev/null || true)"

  if [[ -z "${oauth_project_number}" || -z "${expected_project_number}" ]]; then
    echo "WARN: Could not verify OAuth client ownership for project '${GCP_PROJECT_ID}'." >&2
    return 0
  fi

  if [[ "${oauth_project_number}" != "${expected_project_number}" ]]; then
    echo "ERROR: OAuth client does not belong to project '${GCP_PROJECT_ID}'." >&2
    echo "  client_id prefix: ${oauth_project_number}" >&2
    echo "  project number:   ${expected_project_number}" >&2
    echo "Create a Desktop OAuth client in the correct project and retry." >&2
    exit 1
  fi

  echo "Verified OAuth client belongs to project '${GCP_PROJECT_ID}'."
}

validate_token_export_expectations() {
  local has_scope="false"
  local has_account="false"

  if jq -er '.. | strings | select(test("gmail\\.readonly"))' "${TOKEN_EXPORT}" >/dev/null 2>&1; then
    has_scope="true"
  fi
  if [[ "${has_scope}" == "true" ]]; then
    echo "Verified token export references gmail.readonly scope."
  else
    echo "WARN: Could not confirm gmail.readonly scope from token export JSON. Continue only if you authorized readonly scope." >&2
  fi

  if [[ -n "${GMAIL_ACCOUNT}" ]]; then
    if jq -er --arg acct "${GMAIL_ACCOUNT}" '.. | strings | select(. == $acct)' "${TOKEN_EXPORT}" >/dev/null 2>&1; then
      has_account="true"
    fi
    if [[ "${has_account}" == "true" ]]; then
      echo "Verified token export references Gmail account '${GMAIL_ACCOUNT}'."
    else
      echo "WARN: Token export does not explicitly reference '${GMAIL_ACCOUNT}' in JSON fields." >&2
    fi
  fi
}

token_export_expiry_status() {
  local raw=""
  raw="$(jq -r '.expires_at // .access_token_expires_at // .expiry // empty' "${TOKEN_EXPORT}" 2>/dev/null || true)"
  if [[ -z "${raw}" ]]; then
    echo "unknown"
    return 0
  fi

  python3 - "${raw}" <<'PY'
import sys
from datetime import datetime, timezone

raw = sys.argv[1].strip()

def out(value):
    print(value)
    raise SystemExit(0)

try:
    if raw.isdigit():
        ts = int(raw)
        if ts > 10_000_000_000:
            ts = ts // 1000
        dt = datetime.fromtimestamp(ts, tz=timezone.utc)
    else:
        normalized = raw.replace("Z", "+00:00")
        dt = datetime.fromisoformat(normalized)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
    now = datetime.now(timezone.utc)
    out("expired" if dt <= now else "valid")
except Exception:
    out("unknown")
PY
}

resolve_token_export_path() {
  local found=""
  local client_dir=""
  local next_to_client=""

  if [[ -n "${TOKEN_EXPORT}" ]]; then
    TOKEN_EXPORT="$(normalize_path "${TOKEN_EXPORT}")"
    return 0
  fi
  if [[ -n "${CLIENT_JSON}" ]]; then
    next_to_client="$(dirname "${CLIENT_JSON}")/gog-token-export.json"
  fi
  found="$(
    first_existing_file \
      "${HOME}/gog/gog-token-export.json" \
      "${next_to_client}" \
      "${HOME}/Downloads/gog-token-export.json" \
      "./gog-token-export.json" || true
  )"
  if [[ -n "${found}" ]]; then
    TOKEN_EXPORT="${found}"
    return 0
  fi
  TOKEN_EXPORT="${next_to_client:-${HOME}/gog/gog-token-export.json}"
}

maybe_prompt_token_refresh_interactive() {
  local status="unknown"
  local choice=""

  [[ -f "${TOKEN_EXPORT}" ]] || return 0

  if [[ "${INTERACTIVE_MODE}" != "true" ]]; then
    echo "Using existing token export: ${TOKEN_EXPORT}"
    return 0
  fi

  status="$(token_export_expiry_status)"
  echo ""
  echo "Token export already exists: ${TOKEN_EXPORT}"
  case "${status}" in
    expired) echo "Status: appears expired (based on expiry field in token export)." ;;
    valid)   echo "Status: appears valid (based on expiry field in token export)." ;;
    *)       echo "Status: unknown (no parseable expiry field found)." ;;
  esac

  read -r -p "Skip Google authorization and reuse this file? [Y/n]: " choice
  choice="${choice:-Y}"
  if [[ "${choice}" =~ ^[Nn]$ ]]; then
    if [[ -z "${GMAIL_ACCOUNT}" ]]; then
      prompt_with_default GMAIL_ACCOUNT "Gmail account for gog auth" ""
    fi
    generate_token_export_locally
  else
    echo "Skipping authorization; using existing token export."
  fi
}

file_mode() {
  local path="$1"
  local mode=""
  mode="$(stat -c '%a' "${path}" 2>/dev/null || true)"
  if [[ -z "${mode}" ]]; then
    mode="$(stat -f '%Lp' "${path}" 2>/dev/null || true)"
  fi
  printf '%s' "${mode}"
}

require_file_mode_600() {
  local path="$1"
  local mode=""
  mode="$(file_mode "${path}")"
  if [[ "${mode}" != "600" ]]; then
    echo "ERROR: File must have mode 600: ${path} (current: ${mode:-unknown})" >&2
    echo "Run: chmod 600 \"${path}\"" >&2
    exit 1
  fi
}

print_gog_install_instructions() {
  local os arch asset gog_version
  os="$(uname -s 2>/dev/null || echo unknown)"
  arch="$(uname -m 2>/dev/null || echo unknown)"
  gog_version="${GOG_VERSION:-0.36.0}"
  asset="(detect release asset for your platform)"

  case "${os}:${arch}" in
    Darwin:arm64) asset="gogcli_<version>_darwin_arm64.tar.gz" ;;
    Darwin:x86_64) asset="gogcli_<version>_darwin_amd64.tar.gz" ;;
    Linux:x86_64) asset="gogcli_<version>_linux_amd64.tar.gz" ;;
    Linux:aarch64|Linux:arm64) asset="gogcli_<version>_linux_arm64.tar.gz" ;;
  esac

  echo "gog is required for --authorize-local but was not found in PATH." >&2
  echo "Detected platform: ${os} ${arch}" >&2
  echo "Install from: https://github.com/openclaw/gogcli/releases" >&2
  echo "Suggested release asset: ${asset}" >&2
  if [[ "${os}" == "Darwin" && "${arch}" == "arm64" ]]; then
    echo "" >&2
    echo "Install commands for macOS arm64:" >&2
    echo "  export GOG_VERSION=\"${gog_version}\"" >&2
    echo "  tmp=\"\$(mktemp -d)\" && cd \"\$tmp\"" >&2
    echo "  curl -fL -o \"gogcli_\${GOG_VERSION}_darwin_arm64.tar.gz\" \\" >&2
    echo "    \"https://github.com/openclaw/gogcli/releases/download/v\${GOG_VERSION}/gogcli_\${GOG_VERSION}_darwin_arm64.tar.gz\"" >&2
    echo "  tar -xzf \"gogcli_\${GOG_VERSION}_darwin_arm64.tar.gz\"" >&2
    echo "  install -m 755 gog /opt/homebrew/bin/gog  # use sudo if needed" >&2
  fi
  echo "After installation, verify with: gog --version" >&2
}

install_gog_if_supported() {
  local os arch gog_version tmp_dir asset url
  os="$(uname -s 2>/dev/null || echo unknown)"
  arch="$(uname -m 2>/dev/null || echo unknown)"
  gog_version="${GOG_VERSION:-0.36.0}"

  case "${os}:${arch}" in
    Darwin:arm64)
      asset="gogcli_${gog_version}_darwin_arm64.tar.gz"
      ;;
    Darwin:x86_64)
      asset="gogcli_${gog_version}_darwin_amd64.tar.gz"
      ;;
    Linux:x86_64)
      asset="gogcli_${gog_version}_linux_amd64.tar.gz"
      ;;
    Linux:aarch64|Linux:arm64)
      asset="gogcli_${gog_version}_linux_arm64.tar.gz"
      ;;
    *)
      echo "Auto-install is not supported for ${os} ${arch} in this script." >&2
      return 1
      ;;
  esac

  url="https://github.com/openclaw/gogcli/releases/download/v${gog_version}/${asset}"
  tmp_dir="$(mktemp -d)"

  echo "Auto-installing gog ${gog_version} (${os} ${arch})..."
  curl -fL -o "${tmp_dir}/${asset}" "${url}"
  tar -xzf "${tmp_dir}/${asset}" -C "${tmp_dir}"

  if install -m 755 "${tmp_dir}/gog" /opt/homebrew/bin/gog 2>/dev/null; then
    echo "Installed gog to /opt/homebrew/bin/gog"
  elif install -m 755 "${tmp_dir}/gog" /usr/local/bin/gog 2>/dev/null; then
    echo "Installed gog to /usr/local/bin/gog"
  else
    rm -rf "${tmp_dir}" 2>/dev/null || true
    echo "Auto-install could not write to /opt/homebrew/bin or /usr/local/bin." >&2
    echo "Re-run with sudo, or install manually from: ${url}" >&2
    return 1
  fi

  rm -rf "${tmp_dir}" 2>/dev/null || true
  command -v gog >/dev/null 2>&1 && gog --version || true
}

generate_token_export_locally() {
  local client_dir=""
  local token_tmp_dir=""
  local token_tmp=""
  local token_backup=""
  [[ -n "${GMAIL_ACCOUNT}" ]] || {
    echo "ERROR: --authorize-local requires --gmail-account (or interactive Gmail prompt)." >&2
    exit 1
  }
  if ! command -v gog >/dev/null 2>&1; then
    if [[ "${INSTALL_GOG_IF_MISSING}" == "true" ]]; then
      install_gog_if_supported || {
        print_gog_install_instructions
        exit 1
      }
    else
      print_gog_install_instructions
      exit 1
    fi
  fi
  command -v openssl >/dev/null 2>&1 || {
    echo "ERROR: --authorize-local requires 'openssl' installed locally." >&2
    exit 1
  }

  LOCAL_AUTH_TMP="$(mktemp -d)"
  chmod 700 "${LOCAL_AUTH_TMP}"
  export GOG_HOME="${LOCAL_AUTH_TMP}"
  export GOG_KEYRING_BACKEND=file
  export GOG_KEYRING_PASSWORD
  GOG_KEYRING_PASSWORD="$(openssl rand -hex 32)"

  client_dir="$(dirname "${CLIENT_JSON}")"
  if [[ -z "${TOKEN_EXPORT}" ]]; then
    TOKEN_EXPORT="${client_dir}/gog-token-export.json"
  fi

  mkdir -p "${client_dir}"
  echo "Starting local gog authorization for ${GMAIL_ACCOUNT}..."
  gog auth credentials set "${CLIENT_JSON}"
  gog --readonly auth add "${GMAIL_ACCOUNT}" \
    --services gmail \
    --gmail-scope readonly \
    --manual \
    --force-consent

  echo "Writing token export to: ${TOKEN_EXPORT}"
  token_tmp_dir="$(mktemp -d)"
  token_tmp="${token_tmp_dir}/gog-token-export.json"
  gog auth tokens export "${GMAIL_ACCOUNT}" --out "${token_tmp}" >/dev/null
  if [[ -f "${TOKEN_EXPORT}" ]]; then
    token_backup="${TOKEN_EXPORT}.bak.$(date +%Y%m%d%H%M%S)"
    cp -f "${TOKEN_EXPORT}" "${token_backup}" 2>/dev/null || true
    echo "Existing token export backed up to: ${token_backup}"
  fi
  mv -f "${token_tmp}" "${TOKEN_EXPORT}"
  rm -rf "${token_tmp_dir}" 2>/dev/null || true
  chmod 600 "${TOKEN_EXPORT}"

  unset GOG_KEYRING_PASSWORD GOG_HOME GOG_KEYRING_BACKEND
  echo "Generated token export via local gog authorization."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --client-json)  CLIENT_JSON="$2"; shift 2 ;;
    --token-export) TOKEN_EXPORT="$2"; shift 2 ;;
    --gmail-account) GMAIL_ACCOUNT="$2"; shift 2 ;;
    --gcp-project)  GCP_PROJECT_ID="$2"; shift 2 ;;
    --authorize-local) AUTHORIZE_LOCAL="true"; shift 1 ;;
    --install-gog-if-missing) INSTALL_GOG_IF_MISSING="true"; shift 1 ;;
    --namespace)    NS="$2"; shift 2 ;;
    --vm)           INTEGRATIONS_VM="$2"; shift 2 ;;
    --ssh-key)      SSH_KEY_PATH="$2"; shift 2 ;;
    --interactive)  INTERACTIVE_MODE="true"; shift 1 ;;
    --non-interactive) INTERACTIVE_MODE="false"; shift 1 ;;
    -h|--help)      usage ;;
    *)              echo "Unknown option: $1" >&2; usage_error ;;
  esac
done

CLIENT_JSON="$(normalize_path "${CLIENT_JSON}")"
TOKEN_EXPORT="$(normalize_path "${TOKEN_EXPORT}")"
SSH_KEY_PATH="$(normalize_path "${SSH_KEY_PATH}")"

if [[ "${INTERACTIVE_MODE}" == "auto" ]]; then
  if [[ -t 0 && -t 1 ]]; then
    INTERACTIVE_MODE="true"
  else
    INTERACTIVE_MODE="false"
  fi
fi

if [[ -z "${CLIENT_JSON}" || ( -z "${TOKEN_EXPORT}" && "${AUTHORIZE_LOCAL}" != "true" ) ]]; then
  if [[ "${INTERACTIVE_MODE}" == "true" ]]; then
    collect_credentials_interactively
  else
    echo "ERROR: --client-json is required, and --token-export is required unless --authorize-local is used." >&2
    usage_error
  fi
fi

if [[ ! -f "${CLIENT_JSON}" ]]; then
  if [[ "${INTERACTIVE_MODE}" == "true" ]]; then
    guide_missing_client_json_interactive
  else
    echo "ERROR: OAuth client JSON not found: ${CLIENT_JSON}" >&2
    if [[ -n "${GCP_PROJECT_ID}" ]]; then
      echo "Download a Desktop OAuth client JSON from:" >&2
      echo "  https://console.cloud.google.com/apis/credentials?project=${GCP_PROJECT_ID}" >&2
    else
      echo "Download a Desktop OAuth client JSON from:" >&2
      echo "  https://console.cloud.google.com/apis/credentials" >&2
    fi
    echo "Then save it to that path and run: chmod 600 \"${CLIENT_JSON}\"" >&2
    exit 1
  fi
fi

if [[ ! -f "${CLIENT_JSON}" ]]; then
  echo "ERROR: OAuth client JSON not found after interactive prompt: ${CLIENT_JSON}" >&2
  exit 1
fi

resolve_token_export_path

if [[ "${INTERACTIVE_MODE}" == "true" ]]; then
  if command -v chmod >/dev/null 2>&1; then
    chmod 600 "${CLIENT_JSON}" 2>/dev/null || true
  fi
fi

maybe_prompt_token_refresh_interactive

# No existing token file: only run the local auth flow when explicitly requested.
if [[ "${AUTHORIZE_LOCAL}" == "true" && ! -f "${TOKEN_EXPORT}" ]]; then
  generate_token_export_locally
fi

for f in "${CLIENT_JSON}" "${TOKEN_EXPORT}" "${SSH_KEY_PATH}"; do
  if [[ ! -f "${f}" ]]; then
    echo "ERROR: File not found: ${f}" >&2
    exit 1
  fi
done

for cmd in jq kubectl; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: ${cmd} not found." >&2
    exit 1
  fi
done

# Validate the client JSON has the expected structure
jq -er '.installed.client_id' "${CLIENT_JSON}" >/dev/null 2>&1 || {
  echo "ERROR: ${CLIENT_JSON} does not look like a Desktop OAuth client JSON." >&2
  exit 1
}

jq -er '.refresh_token' "${TOKEN_EXPORT}" >/dev/null 2>&1 || {
  echo "ERROR: ${TOKEN_EXPORT} does not contain a refresh_token." >&2
  exit 1
}

require_file_mode_600 "${CLIENT_JSON}"
require_file_mode_600 "${TOKEN_EXPORT}"

validate_oauth_client_project_ownership
validate_token_export_expectations

echo "============================================================"
echo "Configure Gmail OAuth refresh on integrations VM"
echo "============================================================"
echo "  Namespace: ${NS}"
echo "  VM:        ${INTEGRATIONS_VM}"
[[ -n "${GCP_PROJECT_ID}" ]] && echo "  Project:   ${GCP_PROJECT_ID}"
[[ -n "${GMAIL_ACCOUNT}" ]] && echo "  Gmail:     ${GMAIL_ACCOUNT}"
echo ""

# --- Set up SSH via port-forward ---
LOCAL_SSH_PORT=2222
echo "Starting port-forward to ${INTEGRATIONS_VM}..."
kubectl port-forward "svc/${INTEGRATIONS_VM}-gateway" -n "${NS}" "${LOCAL_SSH_PORT}:22" &
PF_PID=$!
for _i in $(seq 1 10); do
  if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=2 \
       -o BatchMode=yes -i "${SSH_KEY_PATH}" -p "${LOCAL_SSH_PORT}" \
       "${SSH_USER:-cloud-user}@127.0.0.1" "echo ready" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

ssh_cmd() {
  ssh -i "${SSH_KEY_PATH}" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -o ConnectTimeout=10 \
    -o ServerAliveInterval=5 \
    -o ServerAliveCountMax=3 \
    -o BatchMode=yes \
    -p "${LOCAL_SSH_PORT}" \
    "${SSH_USER}@127.0.0.1" "$@"
}

scp_cmd() {
  scp -i "${SSH_KEY_PATH}" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -P "${LOCAL_SSH_PORT}" \
    "$@"
}

# Verify connectivity
echo "Verifying SSH connectivity..."
ssh_cmd "echo 'Connected to \$(hostname)'"

# --- Step 1: Copy credential files to the VM ---
echo "Copying credential files to VM..."
scp_cmd "${CLIENT_JSON}" "${SSH_USER}@127.0.0.1:/tmp/gog-client-secret.json"
scp_cmd "${TOKEN_EXPORT}" "${SSH_USER}@127.0.0.1:/tmp/gog-token-export.json"
ssh_cmd "chmod 600 /tmp/gog-client-secret.json /tmp/gog-token-export.json"
echo "  Files copied."

# --- Step 2: Ensure provider profile has refresh support ---
# The governance interceptor hot-pushes the profile from the
# governance-policy chart. If the profile already has the refresh
# block (via ArgoCD sync), this is a no-op. Otherwise, update it
# manually so the script works before the next ArgoCD sync.
echo "Checking gmail-read provider profile for refresh support..."
ssh_cmd 'export PATH="$HOME/.local/bin:$PATH"
if openshell provider profile export gmail-read 2>/dev/null | grep -q oauth2_refresh_token; then
  echo "  Profile already has refresh support."
else
  echo "  Updating profile with refresh block..."
  cat > /tmp/gmail-read-profile-v2.yaml << '"'"'EOF'"'"'
id: gmail-read
display_name: Gmail read proxy
description: Gmail read-only proxy on the integrations VM with gateway-managed refresh
category: data
inference_capable: false
credentials:
  - name: access_token
    description: Short-lived Google OAuth access token
    env_vars: [GMAIL_ACCESS_TOKEN]
    required: true
    auth_style: bearer
    header_name: authorization
    refresh:
      strategy: oauth2_refresh_token
      token_url: https://oauth2.googleapis.com/token
      scopes: []
      refresh_before_seconds: 300
      max_lifetime_seconds: 3600
      material:
        - name: client_id
          required: true
        - name: client_secret
          required: true
          secret: true
        - name: refresh_token
          required: true
          secret: true
discovery:
  credentials: [access_token]
endpoints:
  - host: gmail.googleapis.com
    port: 443
    protocol: rest
    enforcement: enforce
    access: read-only
binaries:
  - /usr/bin/curl
  - /usr/local/bin/curl
  - /usr/local/bin/node
  - /sandbox/rust-email-proxy
  - /sandbox/gmail-read-proxy
EOF
  RV=$(openshell provider profile export gmail-read 2>/dev/null | grep resource_version | awk "{print \$2}")
  if [ -n "$RV" ] && [ "$RV" != "0" ]; then
    sed -i "1a resource_version: $RV" /tmp/gmail-read-profile-v2.yaml
    openshell provider profile update --file /tmp/gmail-read-profile-v2.yaml gmail-read
  else
    openshell provider profile import -f /tmp/gmail-read-profile-v2.yaml
  fi
  rm -f /tmp/gmail-read-profile-v2.yaml
  echo "  Profile updated."
fi'

# --- Step 3: Configure refresh material ---
echo "Configuring refresh material..."
ssh_cmd 'set -e
export PATH="$HOME/.local/bin:$PATH"
GOG_CLIENT_ID="$(jq -er ".installed.client_id" /tmp/gog-client-secret.json)"
export GOG_CLIENT_SECRET="$(jq -er ".installed.client_secret" /tmp/gog-client-secret.json)"
export GOG_REFRESH_TOKEN="$(jq -er ".refresh_token" /tmp/gog-token-export.json)"
openshell provider refresh configure gmail-read \
  --credential-key access_token \
  --strategy oauth2-refresh-token \
  --material "client_id=${GOG_CLIENT_ID}" \
  --secret-material-env client_secret=GOG_CLIENT_SECRET \
  --secret-material-env refresh_token=GOG_REFRESH_TOKEN
if openshell provider get gmail-read -v 2>/dev/null | grep -q "Credential keys:.*GMAIL_ACCESS_TOKEN"; then
  openshell provider refresh configure gmail-read \
    --credential-key GMAIL_ACCESS_TOKEN \
    --strategy oauth2-refresh-token \
    --material "client_id=${GOG_CLIENT_ID}" \
    --secret-material-env client_secret=GOG_CLIENT_SECRET \
    --secret-material-env refresh_token=GOG_REFRESH_TOKEN
fi
if openshell provider get gmail-read -v 2>/dev/null | grep -q "Credential keys:.*API_KEY"; then
  openshell provider refresh configure gmail-read \
    --credential-key API_KEY \
    --strategy oauth2-refresh-token \
    --material "client_id=${GOG_CLIENT_ID}" \
    --secret-material-env client_secret=GOG_CLIENT_SECRET \
    --secret-material-env refresh_token=GOG_REFRESH_TOKEN
fi
echo "  Refresh configured."'

# --- Step 4: Rotate and verify ---
echo "Rotating token..."
ssh_cmd 'export PATH="$HOME/.local/bin:$PATH"
openshell provider refresh rotate gmail-read --credential-key access_token || true'
ssh_cmd 'export PATH="$HOME/.local/bin:$PATH"
if openshell provider get gmail-read -v 2>/dev/null | grep -q "Credential keys:.*GMAIL_ACCESS_TOKEN"; then
  openshell provider refresh rotate gmail-read --credential-key GMAIL_ACCESS_TOKEN
fi'
ssh_cmd 'export PATH="$HOME/.local/bin:$PATH"
if openshell provider get gmail-read -v 2>/dev/null | grep -q "Credential keys:.*API_KEY"; then
  openshell provider refresh rotate gmail-read --credential-key API_KEY
fi'

echo "Checking refresh status..."
ssh_cmd 'export PATH="$HOME/.local/bin:$PATH"
openshell provider refresh status gmail-read'

BEARER_SHA256="$(kubectl get secret inter-vm-bearer -n "${NS}" -o jsonpath='{.data.sha256}' 2>/dev/null | base64 -d || true)"
BEARER="$(kubectl get secret inter-vm-bearer -n "${NS}" -o jsonpath='{.data.bearer}' 2>/dev/null | base64 -d || true)"
echo "Restarting mail-proxy so it picks up a fresh credential session..."
# Fail-safe: never use unbounded `sandbox exec` to kill leftovers (it can hang
# forever). Free :18080 via timed podman/docker exec, start the governed
# binary as argv0 so the supervisor injects an s-type token, and require HTTP 200.
ssh_cmd 'bash -s' << EOF
set +e
export PATH="\$HOME/.local/bin:\$PATH"
openshell gateway select openshell-local >/dev/null 2>&1 || true

kill_leftover_proxy() {
  local i pid rest pids
  echo "  Stopping leftover /sandbox/gmail-read-proxy on the VM host..."
  for i in \$(seq 1 10); do
    pids=""
    while read -r pid rest; do
      case "\$rest" in
        /sandbox/gmail-read-proxy*) pids="\$pids \$pid" ;;
      esac
    done < <(ps -eo pid=,args=)
    if [[ -z "\${pids// }" ]]; then
      return 0
    fi
    for pid in \$pids; do
      kill -9 "\$pid" 2>/dev/null || sudo kill -9 "\$pid" 2>/dev/null || true
    done
    sleep 1
  done
}

wait_proxy_http_200() {
  local i code
  echo "  Waiting for proxy HTTP 200..."
  for i in \$(seq 1 30); do
    code=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \\
      -H 'x-forge-read-bearer: ${BEARER}' \\
      'http://127.0.0.1:18080/gmail/v1/users/me/labels?maxResults=1' 2>/dev/null || true)
    if [[ "\$code" == "200" ]]; then
      echo "  proxy status: 200"
      return 0
    fi
    sleep 1
  done
  echo "  proxy status: \${code:-000}"
  if [[ "\$code" =~ ^[45] ]]; then
    curl -s -o /tmp/gmail-proxy-err.out --max-time 5 \\
      -H 'x-forge-read-bearer: ${BEARER}' \\
      'http://127.0.0.1:18080/gmail/v1/users/me/labels?maxResults=1' >/dev/null 2>&1 || true
    python3 -c 'import json
try:
  d=json.load(open("/tmp/gmail-proxy-err.out"))
  print("  proxy error: %s" % (d.get("error") or "unknown"))
except Exception:
  print("  proxy error: not-ready")
' 2>/dev/null || true
    rm -f /tmp/gmail-proxy-err.out
  else
    echo "  proxy error: empty reply (process not listening yet or still restarting)"
  fi
  return 1
}

restart_mail_proxy() {
  timeout -k 2 20 systemctl --user stop openshell-sandbox-mail-proxy.service >/dev/null 2>&1 || true
  timeout -k 2 10 systemctl --user reset-failed openshell-sandbox-mail-proxy.service >/dev/null 2>&1 || true
  kill_leftover_proxy
  sleep 1
  timeout -k 2 25 systemctl --user start openshell-sandbox-mail-proxy.service || true
  wait_proxy_http_200
}

cat > "\$HOME/.local/bin/openshell-sandbox-mail-proxy.service.sh" << 'EOS'
#!/usr/bin/env bash
set -euo pipefail
export PATH="\$HOME/.local/bin:\$PATH"
openshell gateway select openshell-local >/dev/null 2>&1 || true
exec openshell sandbox exec -n mail-proxy --no-tty --env INTER_VM_BEARER_SHA256=${BEARER_SHA256} -- /sandbox/gmail-read-proxy
EOS
chmod +x "\$HOME/.local/bin/openshell-sandbox-mail-proxy.service.sh"
mkdir -p "\$HOME/.config/systemd/user"
if ! grep -q '^TimeoutStopSec=' "\$HOME/.config/systemd/user/openshell-sandbox-mail-proxy.service" 2>/dev/null; then
  sed -i '/^RestartSec=/a TimeoutStopSec=20' "\$HOME/.config/systemd/user/openshell-sandbox-mail-proxy.service" 2>/dev/null || true
fi
systemctl --user daemon-reload

ok=0
if ! restart_mail_proxy; then
  echo "  Retrying leftover kill + start..."
  if ! restart_mail_proxy; then
    echo "  ERROR: mail-proxy did not become healthy (want HTTP 200)"
    systemctl --user status openshell-sandbox-mail-proxy.service --no-pager || true
    journalctl --user -u openshell-sandbox-mail-proxy.service -n 20 --no-pager || true
    ok=1
  fi
fi
exit \$ok
EOF
restart_rc=$?

# --- Step 6: Clean up credential files on VM ---
echo "Cleaning up credential files on VM..."
ssh_cmd "rm -f /tmp/gog-client-secret.json /tmp/gog-token-export.json /tmp/gmail-read-profile-v2.yaml /tmp/gmail-proxy-check.out /tmp/gmail-proxy-err.out" || true

if [[ "${restart_rc}" -ne 0 ]]; then
  echo "ERROR: Gmail refresh configured, but mail-proxy did not return HTTP 200."
  echo "The leftover proxy on :18080 was not replaced with a fresh credential session."
  exit 1
fi

echo ""
echo "============================================================"
echo "Gmail OAuth refresh configured successfully."
echo "The gateway will auto-refresh the access token before expiry."
echo "mail-proxy was restarted after refresh (new sandbox exec session)."
echo "============================================================"
