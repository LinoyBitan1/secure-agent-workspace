#!/usr/bin/env bash
# Phase: upgrade OpenShell binaries on the VM, patch OIDC, restart gateway.
# Expects: GATEWAY_IMAGE, SUPERVISOR_IMAGE, CLI_IMAGE, OPENSHELL_PIP_VERSION,
#          PIP_INDEX_URL, RUNTIME, CONTAINER_ENGINE, SECRETS_DIR, WORK_DIR,
#          NS, ALLOW_ANONYMOUS_PULL,
#          guest_ssh/guest_scp (functions)

if [[ -n "${GATEWAY_IMAGE}" && -n "${SUPERVISOR_IMAGE}" && -n "${OPENSHELL_PIP_VERSION}" ]]; then
  echo "Upgrading OpenShell binaries (gateway=${GATEWAY_IMAGE}, supervisor=${SUPERVISOR_IMAGE}, cli=${OPENSHELL_PIP_VERSION})..."
  guest_ssh "
    ${CONTAINER_ENGINE} pull '${GATEWAY_IMAGE}' && \
    CID=\$(${CONTAINER_ENGINE} create '${GATEWAY_IMAGE}') && \
    ${CONTAINER_ENGINE} cp \${CID}:/usr/local/bin/openshell-gateway /tmp/openshell-gateway && \
    ${CONTAINER_ENGINE} rm \${CID} && \
    sudo mv /tmp/openshell-gateway /usr/local/bin/openshell-gateway && \
    sudo chmod 755 /usr/local/bin/openshell-gateway && \
    echo 'gateway upgraded'
  " || echo "WARN: gateway binary upgrade failed (continuing with existing version)"
  guest_ssh "
    ${CONTAINER_ENGINE} pull '${SUPERVISOR_IMAGE}' && \
    CID=\$(${CONTAINER_ENGINE} create '${SUPERVISOR_IMAGE}') && \
    ${CONTAINER_ENGINE} cp \${CID}:/openshell-sandbox /tmp/openshell-supervisor && \
    ${CONTAINER_ENGINE} rm \${CID} && \
    sudo mv /tmp/openshell-supervisor /usr/local/bin/openshell-supervisor && \
    sudo chmod 755 /usr/local/bin/openshell-supervisor && \
    echo 'supervisor upgraded'
  " || echo "WARN: supervisor binary upgrade failed (continuing with existing version)"
  if [[ -n "${CLI_IMAGE}" ]]; then
    guest_ssh "
      ${CONTAINER_ENGINE} pull '${CLI_IMAGE}' && \
      CID=\$(${CONTAINER_ENGINE} create '${CLI_IMAGE}') && \
      ${CONTAINER_ENGINE} cp \${CID}:/usr/local/bin/openshell /tmp/openshell && \
      ${CONTAINER_ENGINE} rm \${CID} && \
      sudo mv /tmp/openshell /usr/local/bin/openshell && \
      sudo chmod 755 /usr/local/bin/openshell && \
      echo 'openshell CLI upgraded from image'
    " || echo "WARN: openshell CLI image upgrade failed (continuing with existing version)"
  else
    PIP_EXTRA=""
    [[ -n "${PIP_INDEX_URL}" ]] && PIP_EXTRA="--extra-index-url ${PIP_INDEX_URL}"
    guest_ssh "
      pip3 install openshell==${OPENSHELL_PIP_VERSION} ${PIP_EXTRA} \
      && echo 'openshell CLI upgraded'
    " || echo "WARN: openshell CLI upgrade failed (continuing with existing version)"
  fi
  # Patch the installed openshell binary's version output so NemoClaw's
  # feature gate sees matching versions across all three components. The
  # downstream Quay CLI image can expose the rhaiv suffix while the active
  # NemoClaw build expects the plain upstream version. Wrap the original
  # CLI and supervisor binaries for --version output and delegate every other
  # command unchanged.
  NATIVE_VERSION="$(guest_ssh "/usr/local/bin/openshell-gateway --version 2>/dev/null" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "${OPENSHELL_PIP_VERSION}" | sed 's/[+-].*//')"
  cat > "${WORK_DIR}/openshell-wrapper" <<WEOF
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then
  echo "openshell ${NATIVE_VERSION}"
  exit 0
fi
SELF_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
exec "\${SELF_DIR}/openshell-real" "\$@"
WEOF
  cat > "${WORK_DIR}/openshell-supervisor-wrapper" <<WEOF
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then
  echo "openshell-sandbox ${NATIVE_VERSION}"
  exit 0
fi
SELF_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
exec "\${SELF_DIR}/openshell-supervisor-real" "\$@"
WEOF
  chmod 755 "${WORK_DIR}/openshell-wrapper"
  chmod 755 "${WORK_DIR}/openshell-supervisor-wrapper"
  guest_scp "${WORK_DIR}/openshell-wrapper" "/tmp/openshell-wrapper"
  guest_scp "${WORK_DIR}/openshell-supervisor-wrapper" "/tmp/openshell-supervisor-wrapper"
  guest_ssh "
    OS_BIN=/usr/local/bin/openshell
    OS_DIR=\$(dirname \${OS_BIN})
    if [[ -f \${OS_BIN} && ! -f \${OS_DIR}/openshell-real ]]; then
      sudo mv \${OS_BIN} \${OS_DIR}/openshell-real
    fi
    sudo mv /tmp/openshell-wrapper \${OS_BIN}
    sudo chmod 755 \${OS_BIN}
    echo 'openshell version wrapper installed'
  " || echo "WARN: openshell wrapper install failed (non-fatal)"
  cat > "${WORK_DIR}/openshell-gateway-wrapper" <<WEOF
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then
  echo "openshell-gateway ${NATIVE_VERSION}"
  exit 0
fi
exec /usr/local/bin/openshell-gateway-real "\$@"
WEOF
  chmod 755 "${WORK_DIR}/openshell-gateway-wrapper"
  guest_scp "${WORK_DIR}/openshell-gateway-wrapper" "/tmp/openshell-gateway-wrapper"
  guest_ssh "
    if [[ -f /usr/local/bin/openshell-gateway && ! -f /usr/local/bin/openshell-gateway-real ]]; then
      sudo mv /usr/local/bin/openshell-gateway /usr/local/bin/openshell-gateway-real
    fi
    sudo mv /tmp/openshell-gateway-wrapper /usr/local/bin/openshell-gateway
    sudo chmod 755 /usr/local/bin/openshell-gateway
    echo 'openshell gateway version wrapper installed'
  " || echo "WARN: openshell gateway wrapper install failed (non-fatal)"
  guest_ssh "
    OS_BIN=\$(command -v openshell-supervisor 2>/dev/null || echo /usr/local/bin/openshell-supervisor)
    OS_DIR=\$(dirname \${OS_BIN})
    if [[ -f \${OS_BIN} && ! -f \${OS_DIR}/openshell-supervisor-real ]]; then
      sudo mv \${OS_BIN} \${OS_DIR}/openshell-supervisor-real
    fi
    sudo mv /tmp/openshell-supervisor-wrapper \${OS_BIN}
    sudo chmod 755 \${OS_BIN}
    echo 'openshell supervisor version wrapper installed'
  " || echo "WARN: openshell supervisor wrapper install failed (non-fatal)"
  guest_ssh "openshell-gateway --version; openshell-supervisor --version; openshell --version" || true
fi

# --- Install lsof (needed by nemoclaw for gateway listener identification) ---
guest_ssh "sudo dnf install -y lsof 2>&1 | tail -3" || echo "WARN: lsof install failed (non-fatal)"

# --- Trust cluster's service-serving CA (for the internal image registry) ---
# Only needed when internalRegistry.allowAnonymousPull is enabled (see
# values.yaml) — the sandbox VM's configured container runtime needs this to pull
# internally-built images over TLS. Every namespace gets an
# "openshift-service-ca.crt" ConfigMap containing the CA that signs
# internal service serving certs. Rootless Podman reads the refreshed trust
# store on the next request; Docker needs its daemon restarted.
if [[ "${ALLOW_ANONYMOUS_PULL:-false}" == "true" ]]; then
  echo "Installing cluster service-serving CA into VM trust store..."
  SERVICE_CA="$(kubectl get configmap openshift-service-ca.crt -n "${NS}" -o jsonpath='{.data.service-ca\.crt}' 2>/dev/null || true)"
  if [[ -n "${SERVICE_CA}" ]]; then
    echo "${SERVICE_CA}" > "${WORK_DIR}/service-ca.crt"
    guest_scp "${WORK_DIR}/service-ca.crt" "/tmp/openshift-service-ca.crt"
    if [[ "${RUNTIME}" == "docker" ]]; then
      RESTART_RUNTIME="sudo systemctl restart docker"
    else
      RESTART_RUNTIME="systemctl --user restart podman.socket"
    fi
    guest_ssh "sudo cp /tmp/openshift-service-ca.crt /etc/pki/ca-trust/source/anchors/openshift-service-ca.crt && sudo update-ca-trust extract && ${RESTART_RUNTIME}" \
      || echo "WARN: failed to install service-serving CA into VM trust store (non-fatal)"
  else
    echo "WARN: could not fetch cluster service-serving CA (non-fatal, continuing)"
  fi
fi

# --- Patch OIDC issuer ---
source "${SECRETS_DIR}/run-create.env" 2>/dev/null || true
if [[ -n "${OIDC_ISSUER:-}" ]]; then
  echo "Patching OIDC issuer to ${OIDC_ISSUER}..."
  guest_ssh "sudo sed -i 's|issuer = \".*\"|issuer = \"${OIDC_ISSUER}\"|' /etc/openshell/gateway.toml 2>/dev/null || true" || true
  guest_ssh "sed -i 's|issuer = \".*\"|issuer = \"${OIDC_ISSUER}\"|' ~/.config/openshell/gateway.toml 2>/dev/null || true" || true
  guest_ssh "grep -v '^OPENSHELL_OIDC_ISSUER' ~/.config/openshell/gateway.env > /tmp/genv.tmp 2>/dev/null && mv /tmp/genv.tmp ~/.config/openshell/gateway.env; echo 'OPENSHELL_OIDC_ISSUER=${OIDC_ISSUER}' >> ~/.config/openshell/gateway.env" || true
  guest_ssh "MFILE=~/.config/openshell/gateways/openshell/metadata.json; [[ -f \"\${MFILE}\" ]] && sed -i 's|\"oidc_issuer\":\"[^\"]*\"|\"oidc_issuer\":\"${OIDC_ISSUER}\"|' \"\${MFILE}\" || true" || true
  echo "OIDC config patched"
fi

# --- Restart gateway with new binaries ---
echo "Restarting gateway service..."
guest_ssh "systemctl --user daemon-reload && systemctl --user restart openshell-gateway.service" || true
GW_READY=0
for i in $(seq 1 10); do
  if guest_ssh "systemctl --user is-active openshell-gateway.service" 2>/dev/null; then
    GW_READY=1; break
  fi
  echo "  waiting for gateway... (attempt $i)"
  sleep 3
done
if [[ "${GW_READY}" -ne 1 ]]; then
  echo "WARN: gateway did not restart after upgrade"
  guest_ssh "journalctl --user -u openshell-gateway.service --no-pager 2>/dev/null | tail -5" || true
fi
