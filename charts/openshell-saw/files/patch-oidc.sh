#!/usr/bin/env bash
# Phase: patch OIDC issuer on the gateway and restart.
# Runs AFTER all provider/sandbox setup completes (over mTLS) so that
# OIDC auth doesn't block the setup Job.
# Expects: OIDC_ISSUER_URL, SECRETS_DIR, guest_ssh (function)

source "${SECRETS_DIR}/run-create.env" 2>/dev/null || true
OIDC_ISSUER="${OIDC_ISSUER:-${OIDC_ISSUER_URL}}"

if [[ -z "${OIDC_ISSUER}" ]]; then
  return 0 2>/dev/null || true
fi

echo "Patching OIDC issuer: ${OIDC_ISSUER}"
guest_ssh "sudo sed -i 's|issuer = \".*\"|issuer = \"${OIDC_ISSUER}\"|' /etc/openshell/gateway.toml 2>/dev/null || true" || true
guest_ssh "sed -i 's|issuer = \".*\"|issuer = \"${OIDC_ISSUER}\"|' ~/.config/openshell/gateway.toml 2>/dev/null || true" || true
guest_ssh "
  grep -vE '^OPENSHELL_OIDC|^OPENSHELL_ENABLE_MTLS' ~/.config/openshell/gateway.env > /tmp/genv.tmp 2>/dev/null && mv /tmp/genv.tmp ~/.config/openshell/gateway.env
  echo 'OPENSHELL_OIDC_ISSUER=${OIDC_ISSUER}' >> ~/.config/openshell/gateway.env
  echo 'OPENSHELL_OIDC_CLIENT_ID=openshell-cli' >> ~/.config/openshell/gateway.env
  echo 'OPENSHELL_OIDC_AUDIENCE=openshell-cli' >> ~/.config/openshell/gateway.env
  echo 'OPENSHELL_ENABLE_MTLS_AUTH=true' >> ~/.config/openshell/gateway.env
" || true
guest_ssh "MFILE=~/.config/openshell/gateways/openshell/metadata.json; [[ -f \"\${MFILE}\" ]] && sed -i 's|\"oidc_issuer\":\"[^\"]*\"|\"oidc_issuer\":\"${OIDC_ISSUER}\"|' \"\${MFILE}\" || true" || true

echo "Restarting gateway with OIDC..."
guest_ssh "systemctl --user restart openshell-gateway.service" || true
sleep 2
echo "OIDC enabled on gateway."
