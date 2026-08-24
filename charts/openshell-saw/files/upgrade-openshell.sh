#!/usr/bin/env bash
# Phase: upgrade OpenShell binaries on the VM, patch OIDC, restart gateway.
# Expects: GATEWAY_IMAGE, SUPERVISOR_IMAGE, OPENSHELL_PIP_VERSION, PIP_INDEX_URL,
#          RUNTIME, SECRETS_DIR, guest_ssh (function)

if [[ -n "${GATEWAY_IMAGE}" && -n "${SUPERVISOR_IMAGE}" && -n "${OPENSHELL_PIP_VERSION}" ]]; then
  echo "Upgrading OpenShell binaries (gateway=${GATEWAY_IMAGE}, supervisor=${SUPERVISOR_IMAGE}, cli=${OPENSHELL_PIP_VERSION})..."
  guest_ssh "
    ${RUNTIME} pull '${GATEWAY_IMAGE}' && \
    CID=\$(${RUNTIME} create '${GATEWAY_IMAGE}') && \
    ${RUNTIME} cp \${CID}:/usr/local/bin/openshell-gateway /tmp/openshell-gateway && \
    ${RUNTIME} rm \${CID} && \
    sudo mv /tmp/openshell-gateway /usr/local/bin/openshell-gateway && \
    sudo chmod 755 /usr/local/bin/openshell-gateway && \
    echo 'gateway upgraded'
  " || echo "WARN: gateway binary upgrade failed (continuing with existing version)"
  guest_ssh "
    ${RUNTIME} pull '${SUPERVISOR_IMAGE}' && \
    CID=\$(${RUNTIME} create '${SUPERVISOR_IMAGE}') && \
    ${RUNTIME} cp \${CID}:/openshell-sandbox /tmp/openshell-supervisor && \
    ${RUNTIME} rm \${CID} && \
    sudo mv /tmp/openshell-supervisor /usr/local/bin/openshell-supervisor && \
    sudo chmod 755 /usr/local/bin/openshell-supervisor && \
    echo 'supervisor upgraded'
  " || echo "WARN: supervisor binary upgrade failed (continuing with existing version)"
  PIP_EXTRA=""
  [[ -n "${PIP_INDEX_URL}" ]] && PIP_EXTRA="--extra-index-url ${PIP_INDEX_URL}"
  guest_ssh "
    pip3 install openshell==${OPENSHELL_PIP_VERSION} ${PIP_EXTRA} \
    && echo 'openshell CLI upgraded'
  " || echo "WARN: openshell CLI upgrade failed (continuing with existing version)"
  # Patch the pip-installed openshell binary's version output so nemoclaw's
  # feature gate sees matching versions across all three components. The pip
  # binary uses '+' (PEP 440 local) while the native Go binaries use '-'
  # (semver pre-release); the mismatch causes componentBuildVersionsMatch()
  # to return false. We wrap the original binary with a script that fixes
  # --version output and delegates everything else.
  NATIVE_VERSION="$(guest_ssh "openshell-gateway --version 2>/dev/null" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\S*' | head -1 || echo "${OPENSHELL_PIP_VERSION}" | sed 's/+/-/')"
  cat > "${WORK_DIR}/openshell-wrapper" <<WEOF
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then
  echo "openshell ${NATIVE_VERSION}"
  exit 0
fi
SELF_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
exec "\${SELF_DIR}/openshell-real" "\$@"
WEOF
  chmod 755 "${WORK_DIR}/openshell-wrapper"
  guest_scp "${WORK_DIR}/openshell-wrapper" "/tmp/openshell-wrapper"
  guest_ssh "
    OS_BIN=\$(command -v openshell 2>/dev/null || echo /home/${SSH_USER}/.local/bin/openshell)
    OS_DIR=\$(dirname \${OS_BIN})
    if [[ -f \${OS_BIN} && ! -f \${OS_DIR}/openshell-real ]]; then
      mv \${OS_BIN} \${OS_DIR}/openshell-real
    fi
    mv /tmp/openshell-wrapper \${OS_BIN}
    chmod 755 \${OS_BIN}
    echo 'openshell version wrapper installed'
  " || echo "WARN: openshell wrapper install failed (non-fatal)"
  guest_ssh "openshell-gateway --version; openshell-supervisor --version; openshell --version" || true
fi

# --- Install lsof (needed by nemoclaw for gateway listener identification) ---
guest_ssh "sudo dnf install -y lsof 2>&1 | tail -3" || echo "WARN: lsof install failed (non-fatal)"

# OIDC issuer is patched at the end of run-setup.sh (after all setup phases
# complete over mTLS) so that provider/sandbox creation is not blocked.

# --- Strip governance config if disabled (avoids VM rebuild) ---
if [[ "${GOVERNANCE_ENABLED}" != "true" ]]; then
  guest_ssh "
    TOML=\$HOME/.config/openshell/gateway.toml
    if [[ -f \${TOML} ]] && grep -q 'interceptors' \${TOML}; then
      sed -i '/\[openshell.gateway\]/,\$d' \${TOML}
      echo 'Stripped governance interceptor config from gateway.toml'
    fi
  " || true
fi

# --- Restart gateway with new binaries ---
echo "Restarting gateway service..."
guest_ssh "systemctl --user restart openshell-gateway.service" || true
GW_READY=0
for i in $(seq 1 10); do
  if [[ "$(guest_ssh "systemctl --user is-active openshell-gateway.service" 2>/dev/null || true)" == "active" ]]; then
    GW_READY=1; break
  fi
  echo "  waiting for gateway... (attempt $i)"
  sleep 3
done
if [[ "${GW_READY}" -ne 1 ]]; then
  echo "WARN: gateway did not restart after upgrade"
  guest_ssh "journalctl --user -u openshell-gateway.service --no-pager 2>/dev/null | tail -5" || true
else
  # Wait for gateway to accept connections (systemd active != port ready)
  for i in $(seq 1 15); do
    if guest_ssh "curl -sk --max-time 2 https://127.0.0.1:17670/healthz >/dev/null 2>&1" 2>/dev/null; then
      echo "Gateway healthy"
      break
    fi
    echo "  waiting for gateway port... (attempt $i)"
    sleep 2
  done
fi

# --- Regenerate client cert with OU=openshell-admin for platform admin access ---
# The default cert has OU=openshell-user which lacks admin permissions when OIDC
# is enabled. Re-sign with the existing CA to grant platform admin via mTLS.
# Runs after gateway start so generate-certs has created the CA.
echo "Regenerating mTLS client cert with admin role..."
guest_ssh "
  TLS_DIR=\$HOME/.local/state/openshell/tls
  CA_CERT=\${TLS_DIR}/ca.crt
  CA_KEY=\${TLS_DIR}/ca.key
  CLIENT_DIR=\${TLS_DIR}/client
  if [[ -f \${CA_KEY} && -f \${CA_CERT} ]]; then
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
      -keyout \${CLIENT_DIR}/tls.key \
      -subj '/CN=openshell-client/OU=openshell-admin' \
      -out /tmp/client.csr 2>/dev/null
    openssl x509 -req -in /tmp/client.csr \
      -CA \${CA_CERT} -CAkey \${CA_KEY} -CAcreateserial \
      -days 3650 -out \${CLIENT_DIR}/tls.crt 2>/dev/null
    rm -f /tmp/client.csr
    for gw_dir in \$HOME/.config/openshell/gateways/*/mtls; do
      [[ -d \${gw_dir} ]] && cp \${CLIENT_DIR}/tls.crt \${CLIENT_DIR}/tls.key \${gw_dir}/
    done
    echo 'Client cert regenerated: OU=openshell-admin'
  else
    echo 'WARN: CA key not found, skipping cert regeneration'
  fi
" || echo "WARN: client cert regeneration failed (non-fatal)"
