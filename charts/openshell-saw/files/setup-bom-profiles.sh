#!/usr/bin/env bash
# Phase: extract BOM profiles from ConfigMap, resolve credentials, apply via apply_bom.py.
# Expects: NS, SSH_USER, SECRETS_DIR, WORK_DIR, OIDC_ISSUER_URL, OWNER,
#          KEYCLOAK_NAME, KEYCLOAK_NS, NEMOCLAW_CLI_IMAGE, VM_NAME,
#          guest_ssh, guest_scp (functions)

BOM_CM="saw-bom-profiles"
BOM_MOUNT="/tmp/bom-profiles"
if ! kubectl get configmap "${BOM_CM}" -n "${NS}" >/dev/null 2>&1; then
  if [[ "${ROLE}" == "agent" ]]; then
    echo "ERROR: BOM profiles ConfigMap (${BOM_CM}) required for agent role — cannot provision sandboxes."
    exit 1
  fi
  echo "WARNING: No BOM profiles ConfigMap (${BOM_CM}) found — no workspaces or sandboxes will be provisioned."
  echo "WARNING: Deploy the saw-bom chart to configure workspaces and providers."
  echo "WARNING: The VM is running but has no agent sandboxes configured."
  return 0 2>/dev/null || true
fi

echo "BOM profiles detected (ConfigMap ${BOM_CM}) — applying profiles"

mkdir -p "${BOM_MOUNT}"

# Extract ConfigMap data to files
for key in $(kubectl get configmap "${BOM_CM}" -n "${NS}" -o json | jq -r '.data | keys[]'); do
  kubectl get configmap "${BOM_CM}" -n "${NS}" -o json | jq -r --arg k "${key}" '.data[$k]' > "${BOM_MOUNT}/${key}"
done

cp "${SECRETS_DIR}/run-create.env" "${WORK_DIR}/run-create.env"
source "${WORK_DIR}/run-create.env" 2>/dev/null || true

# Transfer BOM app + profiles to VM (clean old data first)
BOM_DIR="/home/${SSH_USER}/bom-profiles"
guest_ssh "rm -rf ${BOM_DIR} && mkdir -p ${BOM_DIR}"
for file in ${BOM_MOUNT}/*; do
  key="$(basename "$file")"
  if [[ "${key}" == "apply_bom.py" ]]; then
    guest_scp "$file" "/home/${SSH_USER}/apply_bom.py"
    continue
  fi
  IFS_OLD="${IFS}"; IFS='|'
  read -ra parts <<< "$(echo "${key}" | sed 's/__/|/g')"
  IFS="${IFS_OLD}"
  if [[ ${#parts[@]} -ge 4 ]]; then
    profile="${parts[1]}"
    ws="${parts[2]}"
    ws_file="${parts[3]}"
    guest_ssh "mkdir -p ${BOM_DIR}/${profile}/${ws}"
    guest_scp "$file" "${BOM_DIR}/${profile}/${ws}/${ws_file}"
    [[ "${ws_file}" == *.sh ]] && guest_ssh "chmod +x ${BOM_DIR}/${profile}/${ws}/${ws_file}"
  fi
done

# Resolve credentials from mounted secrets
BOM_ENV="${WORK_DIR}/bom.env"
for file in ${BOM_MOUNT}/*; do
  key="$(basename "$file")"
  IFS_OLD="${IFS}"; IFS='|'
  read -ra p <<< "$(echo "${key}" | sed 's/__/|/g')"
  IFS="${IFS_OLD}"
  if [[ ${#p[@]} -ge 4 && "${p[3]}" == "providers.yaml" ]]; then
    _flush_prov() {
      if [[ -n "${cur_name:-}" && -n "${cur_secret:-}" ]]; then
        skey="${cur_key:-api_key}"
        spath="/ws-secrets/${cur_secret}/${skey}"
        if [[ -f "${spath}" ]]; then
          env_var="$(echo "PROV_${cur_name}_KEY" | tr '[:lower:]' '[:upper:]' | tr '-' '_')"
          echo "${env_var}=$(cat "${spath}")" >> "${BOM_ENV}"
          echo "  Resolved: ${cur_name}"
          ppath="/ws-secrets/${cur_secret}/provider"
          if [[ -f "${ppath}" ]]; then
            type_env_var="$(echo "PROV_${cur_name}_TYPE" | tr '[:lower:]' '[:upper:]' | tr '-' '_')"
            echo "${type_env_var}=$(cat "${ppath}")" >> "${BOM_ENV}"
          fi
        else
          # Fallback: read directly from k8s secret when projected secret mount
          # is empty/missing (timing or values drift). This avoids silently
          # creating providers without credentials.
          _secret_json="$(kubectl get secret "${cur_secret}" -n "${NS}" -o json 2>/dev/null || true)"
          secret_val="$(echo "${_secret_json}" | jq -r ".data.${skey} // empty" 2>/dev/null | base64 -d 2>/dev/null || true)"
          if [[ -n "${secret_val}" ]]; then
            env_var="$(echo "PROV_${cur_name}_KEY" | tr '[:lower:]' '[:upper:]' | tr '-' '_')"
            echo "${env_var}=${secret_val}" >> "${BOM_ENV}"
            echo "  Resolved via API: ${cur_name}"
            provider_type_val="$(echo "${_secret_json}" | jq -r '.data.provider // empty' 2>/dev/null | base64 -d 2>/dev/null || true)"
            if [[ -n "${provider_type_val}" ]]; then
              type_env_var="$(echo "PROV_${cur_name}_TYPE" | tr '[:lower:]' '[:upper:]' | tr '-' '_')"
              echo "${type_env_var}=${provider_type_val}" >> "${BOM_ENV}"
            fi
          else
            echo "  WARNING: credential for provider '${cur_name}' not found at ${spath} and secret/${cur_secret}.${skey}"
          fi
        fi
      fi
    }
    cur_name="" ; cur_secret="" ; cur_key=""
    while IFS= read -r line; do
      if echo "${line}" | grep -q '^\s*- name:'; then
        _flush_prov
        cur_name="$(echo "${line}" | sed 's/.*name: *//' | tr -d '"' | tr -d "'")"
        cur_secret="" ; cur_key=""
      elif echo "${line}" | grep -q 'credentialSecretKey:'; then
        cur_key="$(echo "${line}" | sed 's/.*credentialSecretKey: *//' | tr -d '"' | tr -d "'")"
      elif echo "${line}" | grep -q 'credentialSecret:'; then
        cur_secret="$(echo "${line}" | sed 's/.*credentialSecret: *//' | tr -d '"' | tr -d "'")"
      fi
    done < "$file"
    _flush_prov
  fi
done

# All admin operations use mTLS with OU=openshell-admin cert — no OIDC token needed.
echo "NAMESPACE=${NS}" >> "${BOM_ENV}"

# Resolve inter-VM bearer (create if missing, read if exists).
if [[ "${ROLE}" == "agent" || "${ROLE}" == "integrations" ]]; then
  _bearer=""
  if [[ -f /ws-secrets/inter-vm-bearer/bearer ]]; then
    _bearer="$(cat /ws-secrets/inter-vm-bearer/bearer)"
  elif kubectl get secret inter-vm-bearer -n "${NS}" >/dev/null 2>&1; then
    _bearer="$(kubectl get secret inter-vm-bearer -n "${NS}" -o jsonpath='{.data.bearer}' | base64 -d)"
  else
    _bearer="$(openssl rand -hex 32)"
    _sha256="$(echo -n "${_bearer}" | sha256sum | cut -d ' ' -f 1 | tr -d '\n')"
    kubectl create secret generic inter-vm-bearer -n "${NS}" \
      --from-literal=bearer="${_bearer}" \
      --from-literal=sha256="${_sha256}"
    echo "  Created inter-vm-bearer secret"
  fi
  [[ -n "${_bearer}" ]] && echo "PROV_GMAIL_READ_PROXY_KEY=${_bearer}" >> "${BOM_ENV}"
fi

# Pass inference config to VM for openclaw onboard.
# Prefer env vars from run-create.env, fall back to mounted inference secret.
INF_PROVIDER="${INFERENCE_PROVIDER:-}"
INF_MODEL="${INFERENCE_MODEL:-}"
if [[ -z "${INF_PROVIDER}" && -f /provider-secret/provider ]]; then
  INF_PROVIDER="$(cat /provider-secret/provider)"
fi
if [[ -z "${INF_MODEL}" && -f /provider-secret/model ]]; then
  INF_MODEL="$(cat /provider-secret/model)"
fi
[[ -n "${INF_PROVIDER}" ]] && echo "INFERENCE_PROVIDER=${INF_PROVIDER}" >> "${BOM_ENV}"
[[ -n "${INF_MODEL}" ]] && echo "INFERENCE_MODEL=${INF_MODEL}" >> "${BOM_ENV}"

# Inference routes through the supervisor via inference.local (default in apply_bom.py).
# The inference-proxy provider on the gateway handles routing to the integ VM.

# Nemoclaw CLI image
REGISTRY_ROUTE="$(kubectl get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}' 2>/dev/null || true)"
if [[ -n "${REGISTRY_ROUTE}" && -n "${NEMOCLAW_CLI_IMAGE}" ]]; then
  echo "NEMOCLAW_CLI_IMAGE=${NEMOCLAW_CLI_IMAGE}" >> "${BOM_ENV}"
fi

guest_scp "${BOM_ENV}" "/home/${SSH_USER}/bom.env"

# Transfer governance profiles to VM (for provider profile import)
GOV_PROFILES_VM="/home/${SSH_USER}/governance-profiles"
guest_ssh "mkdir -p ${GOV_PROFILES_VM}"
if [[ -d /governance-profiles ]]; then
  for file in /governance-profiles/*.yaml; do
    [[ -f "$file" ]] && guest_scp "$file" "${GOV_PROFILES_VM}/$(basename "$file")"
  done
  echo "Governance profiles transferred to VM"
fi

# Compute dashboard route for openclaw gateway inside sandboxes
DASHBOARD_ROUTE_HOST="$(kubectl get route "${VM_NAME}-dashboard" -n "${NS}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"

# Run apply_bom.py on the VM
echo "Running BOM setup on vm/${VM_NAME}..."
guest_ssh "
  set -a; source /home/${SSH_USER}/bom.env 2>/dev/null; set +a
  python3 /home/${SSH_USER}/apply_bom.py \
    --profiles-dir ${BOM_DIR} \
    --mtls-gateway openshell-local \
    --nemoclaw-cli-image \${NEMOCLAW_CLI_IMAGE:-} \
    --dashboard-route '${DASHBOARD_ROUTE_HOST}' \
    --governance-profiles-dir ${GOV_PROFILES_VM}
" 2>&1

echo "BOM profiles applied."

# --- Agent role: attach inference-proxy provider to all sandboxes (if configured) ---
if [[ "${ROLE}" == "agent" ]]; then
  HAS_PROXY=$(guest_ssh "openshell provider get inference-proxy 2>/dev/null" 2>/dev/null || true)
  if echo "${HAS_PROXY}" | grep -q 'inference-proxy'; then
    echo "Attaching inference-proxy provider to sandboxes..."
    guest_ssh "
      export PATH=\"\$HOME/.local/bin:\$PATH\"
      for SB in \$(openshell sandbox list --output json 2>/dev/null | python3 -c 'import sys,json;[print(s[\"name\"]) for s in json.load(sys.stdin)]' 2>/dev/null); do
        openshell sandbox provider attach \${SB} inference-proxy 2>/dev/null || true
        echo \"  Attached inference-proxy to \${SB}\"
      done
    " || true
  fi
fi
