#!/usr/bin/env bash
# Idempotent: KV mount openshell/, policy openshell-gateway, k8s auth role.
set -euo pipefail
VAULT_NS="${VAULT_NS:-vault}"
VAULT_POD="${VAULT_POD:-vault-0}"
TARGET_NS="${TARGET_NS:-openshell-agents}"
SA_NAME="${SA_NAME:-openshell-gateway}"
ROLE="${ROLE:-openshell-gateway}"
POLICY="${POLICY:-openshell-gateway}"
MOUNT="${MOUNT:-openshell}"
K8S_AUTH="${K8S_AUTH:-kubernetes}"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

POLICY_HCL=$(cat <<'HCL'
path "openshell/data/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "openshell/metadata/*" {
  capabilities = ["list", "read", "delete"]
}
HCL
)

vault_cmd() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    printf 'oc exec -n %s %s -- vault %s\n' \
      "${VAULT_NS}" "${VAULT_POD}" "$*"
    return 0
  fi
  # shellcheck disable=SC2086
  oc exec -n "${VAULT_NS}" "${VAULT_POD}" -- vault "$@"
}

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "DRY-RUN: would enable kv-v2 at ${MOUNT},"  \
    "write policy ${POLICY}, write role ${ROLE}"
  echo "${POLICY_HCL}"
  vault_cmd secrets enable -path="${MOUNT}" kv-v2
  echo "vault policy write ${POLICY} <stdin>"
  echo "vault write auth/${K8S_AUTH}/role/${ROLE}" \
    "bound_service_account_names=${SA_NAME}" \
    "bound_service_account_namespaces=${TARGET_NS}" \
    "policies=${POLICY} ttl=1h"
  exit 0
fi

echo "Waiting for ${VAULT_NS}/${VAULT_POD}..."
VAULT_READY=0
for _ in $(seq 1 30); do
  if oc exec -n "${VAULT_NS}" "${VAULT_POD}" -- vault status \
    >/dev/null 2>&1; then
    VAULT_READY=1
    break
  fi
  sleep 2
done
if [[ "${VAULT_READY}" -ne 1 ]]; then
  echo "ERROR: ${VAULT_NS}/${VAULT_POD} not ready for vault exec" >&2
  exit 1
fi

vault_cmd secrets enable -path="${MOUNT}" kv-v2 || true

TMP="$(mktemp)"
printf '%s\n' "${POLICY_HCL}" > "${TMP}"
oc exec -i -n "${VAULT_NS}" "${VAULT_POD}" \
  -- vault policy write "${POLICY}" - < "${TMP}"
rm -f "${TMP}"

vault_cmd write "auth/${K8S_AUTH}/role/${ROLE}" \
  bound_service_account_names="${SA_NAME}" \
  bound_service_account_namespaces="${TARGET_NS}" \
  policies="${POLICY}" \
  ttl="1h"

echo "Vault gateway auth configured:" \
  "mount=${MOUNT} role=${ROLE}" \
  "sa=${TARGET_NS}/${SA_NAME}"
