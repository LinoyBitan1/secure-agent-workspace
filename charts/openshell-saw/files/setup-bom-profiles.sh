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
  fi
done

# Resolve credentials — real from secrets (standalone) or placeholders (agent/integrations)
BOM_ENV="${WORK_DIR}/bom.env"
if [[ "${ROLE}" != "standalone" ]]; then
  echo "Role=${ROLE}: injecting placeholder credentials (real keys live on the integrations VM)"
  for file in ${BOM_MOUNT}/*; do
    key="$(basename "$file")"
    IFS_OLD="${IFS}"; IFS='|'
    read -ra p <<< "$(echo "${key}" | sed 's/__/|/g')"
    IFS="${IFS_OLD}"
    if [[ ${#p[@]} -ge 4 && "${p[3]}" == "providers.yaml" ]]; then
      while IFS= read -r line; do
        if echo "${line}" | grep -q '^\s*- name:'; then
          pname="$(echo "${line}" | sed 's/.*name: *//' | tr -d '"' | tr -d "'")"
          env_var="$(echo "PROV_${pname}_KEY" | tr '[:lower:]' '[:upper:]' | tr '-' '_')"
          echo "${env_var}=placeholder-api-key" >> "${BOM_ENV}"
          echo "  Placeholder: ${pname}"
        fi
      done < "$file"
    fi
  done
else
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
            echo "  WARNING: credential for provider '${cur_name}' not found at ${spath}"
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
fi

# Determine if OIDC token is needed.
# When all BOM workspaces are "default", admin operations (member add, settings set)
# can run via the mTLS gateway — no Keycloak login required.
NEEDS_OIDC=false
for file in ${BOM_MOUNT}/*; do
  key="$(basename "$file")"
  IFS_OLD="${IFS}"; IFS='|'
  read -ra p <<< "$(echo "${key}" | sed 's/__/|/g')"
  IFS="${IFS_OLD}"
  if [[ ${#p[@]} -ge 4 && "${p[3]}" == "workspace.yaml" ]]; then
    ws_name="$(grep '^\s*name:' "$file" | head -1 | sed 's/.*name: *//' | tr -d '"' | tr -d "'")"
    if [[ -n "${ws_name}" && "${ws_name}" != "default" ]]; then
      NEEDS_OIDC=true
      break
    fi
  fi
done

if [[ "${NEEDS_OIDC}" == "true" ]]; then
  # Fetch OIDC token from Keycloak (needed for non-default workspace creation)
  if [[ -z "${OIDC_TOKEN:-}" ]]; then
    if [[ -n "${OIDC_ISSUER_URL}" && -n "${OWNER}" ]]; then
      KEYCLOAK_SECRET="$(kubectl get secret ${KEYCLOAK_NAME}-initial-admin \
        -n ${KEYCLOAK_NS} \
        -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
      if [[ -n "${KEYCLOAK_SECRET}" ]]; then
        TOKEN_RESPONSE=$(curl -sk -X POST \
          "${OIDC_ISSUER_URL}/protocol/openid-connect/token" \
          -d "grant_type=password" \
          -d "client_id=openshell-cli" \
          -d "username=${OWNER}" \
          -d "password=${OWNER}" \
          -d "scope=openid" 2>/dev/null || true)
        OIDC_TOKEN=$(echo "${TOKEN_RESPONSE}" | jq -r '.access_token // empty')
        if [[ -n "${OIDC_TOKEN}" ]]; then
          echo "OIDC token obtained for ${OWNER}"
        else
          echo "WARNING: OIDC token fetch failed for '${OWNER}': $(echo "${TOKEN_RESPONSE}" | jq -r '.error_description // .error // "no response / unparseable response"')"
        fi
      else
        echo "WARNING: could not read secret ${KEYCLOAK_NAME}-initial-admin in namespace ${KEYCLOAK_NS} — skipping OIDC token fetch."
      fi
    fi
  fi
  [[ -n "${OIDC_TOKEN:-}" ]] && echo "OIDC_TOKEN=${OIDC_TOKEN}" >> "${BOM_ENV}"
  echo "OIDC_ISSUER=${OIDC_ISSUER_URL}" >> "${BOM_ENV}"
  echo "OIDC_CLIENT_ID=${OIDC_CLIENT_ID:-openshell-cli}" >> "${BOM_ENV}"
  echo "OPENSHELL_GATEWAY=${OPENSHELL_GATEWAY:-openshell}" >> "${BOM_ENV}"
else
  echo "All workspaces are 'default' — skipping OIDC token fetch (using mTLS gateway)"
fi

# Agent role: set inference base URL to integ VM proxy
if [[ "${ROLE}" == "agent" ]]; then
  {{- $peerLabel := .Values.networkPolicy.peerLabel }}
  INTEG_SERVICE="{{ $peerLabel }}-gateway.${NS}.svc.cluster.local"
  INFERENCE_PROXY_PORT="{{ .Values.inference.proxyPort | default 18083 }}"
  echo "INFERENCE_BASE_URL=http://${INTEG_SERVICE}:${INFERENCE_PROXY_PORT}/v1" >> "${BOM_ENV}"
  echo "  Inference base URL: http://${INTEG_SERVICE}:${INFERENCE_PROXY_PORT}/v1"
fi

# Nemoclaw CLI image
REGISTRY_ROUTE="$(kubectl get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}' 2>/dev/null || true)"
if [[ -n "${REGISTRY_ROUTE}" && -n "${NEMOCLAW_CLI_IMAGE}" ]]; then
  echo "NEMOCLAW_CLI_IMAGE=${NEMOCLAW_CLI_IMAGE}" >> "${BOM_ENV}"
fi

guest_scp "${BOM_ENV}" "/home/${SSH_USER}/bom.env"

# Compute dashboard route for openclaw gateway inside sandboxes
DASHBOARD_ROUTE_HOST="$(kubectl get route "${VM_NAME}-dashboard" -n "${NS}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"

# Run apply_bom.py on the VM
echo "Running BOM setup on vm/${VM_NAME}..."
guest_ssh "
  set -a; source /home/${SSH_USER}/bom.env 2>/dev/null; set +a
  OIDC_GW_FLAG=\"\"
  if [[ -n \"\${OPENSHELL_GATEWAY:-}\" ]]; then
    OIDC_GW_FLAG=\"--oidc-gateway \${OPENSHELL_GATEWAY}\"
  fi
  python3 /home/${SSH_USER}/apply_bom.py \
    --profiles-dir ${BOM_DIR} \
    \${OIDC_GW_FLAG} \
    --mtls-gateway openshell-local \
    --nemoclaw-cli-image \${NEMOCLAW_CLI_IMAGE:-} \
    --dashboard-route '${DASHBOARD_ROUTE_HOST}'
" 2>&1

echo "BOM profiles applied."

# --- Agent role: attach inference-proxy provider to all sandboxes ---
if [[ "${ROLE}" == "agent" ]]; then
  echo "Attaching inference-proxy provider to sandboxes..."
  guest_ssh "
    export PATH=\"\$HOME/.local/bin:\$PATH\"
    for SB in \$(openshell sandbox list --output json 2>/dev/null | python3 -c 'import sys,json;[print(s[\"name\"]) for s in json.load(sys.stdin)]' 2>/dev/null); do
      openshell sandbox provider attach \${SB} inference-proxy 2>/dev/null || true
      echo \"  Attached inference-proxy to \${SB}\"
    done
  " || true
fi
