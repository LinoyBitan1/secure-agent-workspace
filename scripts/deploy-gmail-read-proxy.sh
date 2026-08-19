#!/usr/bin/env bash
# shellcheck disable=SC2016 # Single-quoted commands expand on the remote VM.
# Post-deploy: set up the Gmail-read proxy sandbox on the integrations VM
# and configure the inter-VM bearer on the agent VM.
#
# Prerequisites:
#   - Both VMs deployed and setup Jobs complete
#   - forge-proxy-gateways repo adjacent to this repo (or set PROXY_REPO)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="${NS:-$(oc project -q 2>/dev/null || true)}"
AGENT_VM="${AGENT_VM:-saw-agent}"
INTEGRATIONS_VM="${INTEGRATIONS_VM:-saw-integ}"
VIRTCTL="${VIRTCTL:-virtctl}"
SSH_KEY_PATH="${SSH_KEY_PATH:-${HOME}/.generated-ssh-keys/sandbox-ssh}"
PROXY_REPO="${PROXY_REPO:-${ROOT}/../forge-proxy-gateways}"
GMAIL_READ_IMAGE="${GMAIL_READ_IMAGE:-quay.io/sallyom/forge-gmail-read-proxy@sha256:dfb6ba5c61745c564035ea49b4e95ed2b21132b49c279c046e8e15e5e9b00f20}"

if [[ -z "${NS}" ]]; then
  echo "No namespace selected. Set NS or run 'oc project <namespace>'." >&2
  exit 1
fi

for cmd in "${VIRTCTL}" oc; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "${cmd} not found." >&2
    exit 1
  fi
done

if [[ ! -f "${SSH_KEY_PATH}" ]]; then
  echo "SSH private key not found: ${SSH_KEY_PATH}" >&2
  exit 1
fi

for file in providers/gmail-read.yaml policy.yaml; do
  if [[ ! -f "${PROXY_REPO}/${file}" ]]; then
    echo "Missing ${PROXY_REPO}/${file}. Set PROXY_REPO to forge-proxy-gateways." >&2
    exit 1
  fi
done

oc whoami >/dev/null
oc get vm "${AGENT_VM}" "${INTEGRATIONS_VM}" -n "${NS}" >/dev/null

ssh_vm() {
  local vm="$1"; shift
  "${VIRTCTL}" -n "${NS}" ssh "cloud-user@vm/${vm}" \
    --identity-file="${SSH_KEY_PATH}" \
    --local-ssh-opts=-oStrictHostKeyChecking=no \
    --local-ssh-opts=-oUserKnownHostsFile=/dev/null \
    --command="$*"
}

copy_to_vm() {
  local source="$1" vm="$2" destination="$3"
  local encoded
  encoded="$(base64 < "${source}" | tr -d '\n')"
  ssh_vm "${vm}" "umask 077; printf '%s' '${encoded}' | base64 -d > '${destination}'"
}

# --- Step 1: Generate inter-VM bearer on agent VM (never printed) ---
echo "Generating inter-VM bearer on ${AGENT_VM}..."
bearer_sha256="$(ssh_vm "${AGENT_VM}" 'set -eu
  bearer_dir=/home/cloud-user/.config/secure-agent-workspace
  bearer_file=${bearer_dir}/inter-vm-bearer
  install -d -m 700 "${bearer_dir}"
  if ! test -s "${bearer_file}"; then
    umask 077; openssl rand -hex 32 | tr -d "\n" > "${bearer_file}"
  fi
  chmod 600 "${bearer_file}"
  sha256sum "${bearer_file}" | cut -d " " -f 1')"
bearer_sha256="${bearer_sha256//$'\r'/}"
bearer_sha256="${bearer_sha256//$'\n'/}"
if [[ ! "${bearer_sha256}" =~ ^[[:xdigit:]]{64}$ ]]; then
  echo "Could not calculate the inter-VM bearer verifier." >&2
  exit 1
fi
echo "  Bearer hash: ${bearer_sha256:0:16}..."

# --- Step 2: Copy provider profile + policy to integrations VM ---
copy_to_vm "${PROXY_REPO}/providers/gmail-read.yaml" "${INTEGRATIONS_VM}" /tmp/gmail-read-provider.yaml
copy_to_vm "${PROXY_REPO}/policy.yaml" "${INTEGRATIONS_VM}" /tmp/gmail-read-policy.yaml

# --- Step 3: Import provider profile + create provider on integ VM ---
ssh_vm "${INTEGRATIONS_VM}" 'export PATH="$HOME/.local/bin:$PATH"
  if ! openshell provider profile export gmail-read >/dev/null 2>&1; then
    openshell provider profile lint -f /tmp/gmail-read-provider.yaml
    openshell provider profile import -f /tmp/gmail-read-provider.yaml
  fi'

ssh_vm "${INTEGRATIONS_VM}" 'export PATH="$HOME/.local/bin:$PATH"
  if ! openshell provider get gmail-read >/dev/null 2>&1; then
    GMAIL_ACCESS_TOKEN=poc-invalid-gmail-token \
      openshell provider create --name gmail-read --type gmail-read --credential GMAIL_ACCESS_TOKEN
  fi'

# --- Step 4: Create gmail-read sandbox with bearer hash ---
if ssh_vm "${INTEGRATIONS_VM}" 'export PATH="$HOME/.local/bin:$PATH"; openshell sandbox get gmail-read >/dev/null 2>&1'; then
  echo "Sandbox gmail-read already exists; refusing to replace it implicitly." >&2
  exit 1
fi

ssh_vm "${INTEGRATIONS_VM}" "export PATH=\"\$HOME/.local/bin:\$PATH\"
  openshell sandbox create --name gmail-read \
    --from '${GMAIL_READ_IMAGE}' \
    --provider gmail-read \
    --policy /tmp/gmail-read-policy.yaml \
    --env INTER_VM_BEARER_SHA256='${bearer_sha256}' \
    --no-tty -- /bin/sh -lc 'nohup /sandbox/rust-email-proxy >/tmp/gmail-read-proxy.log 2>&1 </dev/null &'"

# --- Step 5: Start port forward on integrations VM ---
ssh_vm "${INTEGRATIONS_VM}" 'export PATH="$HOME/.local/bin:$PATH"
  nohup openshell forward start -d 0.0.0.0:18080 gmail-read >/tmp/gmail-read-forward.log 2>&1 </dev/null &'
sleep 2
ssh_vm "${INTEGRATIONS_VM}" 'export PATH="$HOME/.local/bin:$PATH"
  openshell forward list | grep -q "gmail-read.*18080.*running"
  openshell forward list'

# --- Step 6: Verify auth enforcement ---
echo "Verifying proxy auth enforcement..."
ssh_vm "${AGENT_VM}" "set -eu
  target=http://${INTEGRATIONS_VM}-gateway.${NS}.svc.cluster.local:18080
  token=\$(cat /home/cloud-user/.config/secure-agent-workspace/inter-vm-bearer)
  unauth=\$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' \"\$target/gmail/v1/users/me/messages\")
  forbidden=\$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' -H \"Authorization: Bearer \$token\" \"\$target/gmail/v1/users/me/drafts\")
  printf 'unauthenticated=%s write-endpoint=%s\n' \"\$unauth\" \"\$forbidden\"
  test \"\$unauth\" = 401
  test \"\$forbidden\" = 403"

echo "Gmail-read proxy ready on ${INTEGRATIONS_VM}:18080."
