#!/usr/bin/env bash
# Deploy Keycloak instance + realm via RHBK operator.
# Checks that the operator is installed in the correct namespace.

set -euo pipefail

NS="${KEYCLOAK_NS:-openshell-agents}"
CHART="${KEYCLOAK_CHART:-charts/openshell-keycloak}"

# Check RHBK operator is installed in the target namespace
RHBK_CSV="$(oc get csv -n "${NS}" -o name 2>/dev/null | grep rhbk || true)"
if [[ -z "${RHBK_CSV}" ]]; then
  RHBK_NS=$(oc get csv --all-namespaces 2>/dev/null | grep rhbk | awk '{print $1}' | head -1)
  if [[ -n "${RHBK_NS}" && "${RHBK_NS}" != "${NS}" ]]; then
    echo "Error: RHBK operator is installed in '${RHBK_NS}' but Keycloak needs it in '${NS}'."
    echo ""
    echo "  Either:"
    echo "    1. Run: make keycloak KEYCLOAK_NS=${RHBK_NS}"
    echo "    2. Or install the RHBK operator in '${NS}' from OperatorHub"
    echo "    3. Or use ./pattern.sh make install (installs operator in ${NS} automatically)"
    exit 1
  elif [[ -n "${RHBK_NS}" ]]; then
    echo "RHBK operator found in '${NS}' (CSV may still be installing)..."
  else
    echo "Error: RHBK operator not installed."
    echo ""
    echo "  Install it from OperatorHub or use ./pattern.sh make install."
    exit 1
  fi
fi

echo "Deploying Keycloak via RHBK operator in ${NS}..."
helm upgrade --install openshell-keycloak "${CHART}" \
  --namespace "${NS}" --create-namespace --timeout 10m

echo "Waiting for Keycloak to be ready..."
deadline=$((SECONDS + 300))
while true; do
  ready=$(oc get keycloak openshell-keycloak -n "${NS}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  if [[ "${ready}" == "True" ]]; then
    echo "Keycloak is ready."
    KC_URL=$(oc get keycloak openshell-keycloak -n "${NS}" -o jsonpath='{.status.externalURL}' 2>/dev/null || true)
    if [[ -n "${KC_URL}" ]]; then
      echo "  OIDC issuer: ${KC_URL}/realms/openshell"
    fi
    exit 0
  fi
  if (( SECONDS > deadline )); then
    echo "Timed out waiting for Keycloak."
    exit 1
  fi
  echo "  waiting for Keycloak (ready=${ready:-pending})..."
  sleep 10
done
