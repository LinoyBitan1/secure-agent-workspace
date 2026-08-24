#!/usr/bin/env bash
# Verify Keycloak deployment: instance health, realm, clients, users.
# Usage: verify-keycloak.sh [--ns <namespace>]
set -euo pipefail

NS="${KEYCLOAK_NS:-${NS:-openshell-agents}}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ns) NS="$2"; shift 2 ;;
    *)    echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# Auto-detect Keycloak namespace if none found in the specified one
KC_COUNT=$(oc get keycloak -n "${NS}" -o jsonpath='{.items}' 2>/dev/null | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
if [[ "${KC_COUNT}" -eq 0 ]]; then
  DETECTED_NS="$(oc get keycloak --all-namespaces -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"
  if [[ -n "${DETECTED_NS}" ]]; then
    echo "Keycloak not in '${NS}', found in '${DETECTED_NS}'"
    NS="${DETECTED_NS}"
  fi
fi

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }
info() { echo "  INFO  $1"; }

echo "============================================================"
echo "Verifying Keycloak (namespace: ${NS})"
echo "============================================================"
echo ""

# --- Operator ---
echo "--- RHBK Operator ---"
RHBK_CSV=$(oc get csv -n "${NS}" -o name 2>/dev/null | grep rhbk || true)
if [[ -n "${RHBK_CSV}" ]]; then
  RHBK_PHASE=$(oc get "${RHBK_CSV}" -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  if [[ "${RHBK_PHASE}" == "Succeeded" ]]; then
    pass "RHBK operator: ${RHBK_PHASE}"
  else
    fail "RHBK operator: ${RHBK_PHASE:-unknown}"
  fi
else
  fail "RHBK operator not found in ${NS}"
fi

# --- Keycloak Instance ---
echo ""
echo "--- Keycloak Instance ---"
KC_NAME="${KEYCLOAK_NAME:-openshell-keycloak}"
if ! oc get keycloak "${KC_NAME}" -n "${NS}" >/dev/null 2>&1; then
  KC_NAME=$(oc get keycloak -n "${NS}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
fi
if [[ -z "${KC_NAME}" ]]; then
  fail "No Keycloak instance found"
  echo ""
  echo "Results: ${PASS} passed, ${FAIL} failed"
  exit 1
fi

KC_READY=$(oc get keycloak "${KC_NAME}" -n "${NS}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
if [[ "${KC_READY}" == "True" ]]; then
  pass "Keycloak '${KC_NAME}' is Ready"
else
  fail "Keycloak '${KC_NAME}': Ready=${KC_READY:-unknown}"
fi

KC_URL=$(oc get keycloak "${KC_NAME}" -n "${NS}" -o jsonpath='{.status.externalURL}' 2>/dev/null || true)
if [[ -z "${KC_URL}" ]]; then
  KC_HOST=$(oc get route -n "${NS}" -l app=keycloak -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)
  [[ -n "${KC_HOST}" ]] && KC_URL="https://${KC_HOST}"
fi
if [[ -n "${KC_URL}" ]]; then
  info "URL: ${KC_URL}"
else
  fail "No external URL or route found"
fi

# --- PostgreSQL ---
echo ""
echo "--- PostgreSQL ---"
PG_POD=$(oc get pod -n "${NS}" -l app.kubernetes.io/instance="${KC_NAME}" -o jsonpath='{.items[?(@.metadata.name contains "db")].status.phase}' 2>/dev/null || true)
if [[ -z "${PG_POD}" ]]; then
  PG_POD=$(oc get pod -n "${NS}" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -i 'db\|pgsql\|postgres' | head -1 || true)
fi
if echo "${PG_POD}" | grep -qi 'running'; then
  pass "PostgreSQL is Running"
else
  PG_NAME=$(echo "${PG_POD}" | awk '{print $1}' || true)
  if [[ -n "${PG_NAME}" ]]; then
    fail "PostgreSQL (${PG_NAME}): not running"
  else
    info "PostgreSQL pod not found (Keycloak may use an external database)"
  fi
fi

# --- Admin Credentials ---
echo ""
echo "--- Admin Credentials ---"
ADMIN_SECRET="${KC_NAME}-initial-admin"
ADMIN_USER=$(oc get secret "${ADMIN_SECRET}" -n "${NS}" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || true)
if [[ -n "${ADMIN_USER}" ]]; then
  pass "Admin secret '${ADMIN_SECRET}' exists (user: ${ADMIN_USER})"
else
  fail "Admin secret '${ADMIN_SECRET}' not found"
fi

# --- Realm ---
echo ""
echo "--- Realm ---"
if [[ -z "${KC_URL}" ]]; then
  info "Skipping realm checks (no Keycloak URL)"
else
  KC_BASE="${KC_URL}"
  ADMIN_PASS=$(oc get secret "${ADMIN_SECRET}" -n "${NS}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)

  # Get admin token
  ADMIN_TOKEN=$(curl -sk -X POST "${KC_BASE}/realms/master/protocol/openid-connect/token" \
    -d "grant_type=password" -d "client_id=admin-cli" \
    -d "username=${ADMIN_USER}" -d "password=${ADMIN_PASS}" 2>/dev/null \
    | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p' || true)

  if [[ -z "${ADMIN_TOKEN}" ]]; then
    fail "Could not obtain admin token (check admin credentials)"
  else
    # List realms
    REALMS=$(curl -sk -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      "${KC_BASE}/admin/realms" 2>/dev/null \
      | python3 -c "import sys,json; [print(r['realm']) for r in json.load(sys.stdin) if r['realm'] != 'master']" 2>/dev/null || true)
    if [[ -n "${REALMS}" ]]; then
      echo "${REALMS}" | while read -r realm; do
        info "Realm: ${realm}"
      done
      pass "Realm(s) configured"
    else
      fail "No custom realms found"
    fi

    # Check openshell realm specifically
    REALM="openshell"
    REALM_CHECK=$(curl -sk -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      "${KC_BASE}/admin/realms/${REALM}" 2>/dev/null || true)
    if [[ "${REALM_CHECK}" == "200" ]]; then
      pass "Realm '${REALM}' exists"

      # --- Clients ---
      echo ""
      echo "--- Clients (realm: ${REALM}) ---"
      CLIENTS=$(curl -sk -H "Authorization: Bearer ${ADMIN_TOKEN}" \
        "${KC_BASE}/admin/realms/${REALM}/clients" 2>/dev/null \
        | python3 -c "
import sys, json
clients = json.load(sys.stdin)
for c in clients:
    cid = c.get('clientId', '')
    if not cid.startswith('account') and cid not in ('admin-cli', 'broker', 'realm-management', 'security-admin-console'):
        redirects = ', '.join(c.get('redirectUris', [])[:3])
        print(f'{cid}|{redirects}')
" 2>/dev/null || true)
      if [[ -n "${CLIENTS}" ]]; then
        echo "${CLIENTS}" | while IFS='|' read -r cid redirects; do
          if [[ -n "${redirects}" ]]; then
            info "Client: ${cid} (redirects: ${redirects})"
          else
            info "Client: ${cid}"
          fi
        done
        CLIENT_COUNT=$(echo "${CLIENTS}" | wc -l | tr -d ' ')
        pass "${CLIENT_COUNT} client(s) configured"
      else
        fail "No custom clients found"
      fi

      # --- Users ---
      echo ""
      echo "--- Users (realm: ${REALM}) ---"
      USERS=$(curl -sk -H "Authorization: Bearer ${ADMIN_TOKEN}" \
        "${KC_BASE}/admin/realms/${REALM}/users?max=50" 2>/dev/null \
        | python3 -c "
import sys, json
users = json.load(sys.stdin)
for u in users:
    name = u.get('username', '')
    enabled = u.get('enabled', False)
    federated = bool(u.get('federatedIdentities'))
    source = 'federated' if federated else 'local'
    status = 'enabled' if enabled else 'disabled'
    print(f'{name}|{status}|{source}')
" 2>/dev/null || true)
      if [[ -n "${USERS}" ]]; then
        echo "${USERS}" | while IFS='|' read -r uname status source; do
          info "User: ${uname} (${status}, ${source})"
        done
        USER_COUNT=$(echo "${USERS}" | wc -l | tr -d ' ')
        pass "${USER_COUNT} user(s) in realm"
      else
        info "No users found (may use federated identity provider)"
      fi

      # --- Identity Providers ---
      echo ""
      echo "--- Identity Providers (realm: ${REALM}) ---"
      IDPS=$(curl -sk -H "Authorization: Bearer ${ADMIN_TOKEN}" \
        "${KC_BASE}/admin/realms/${REALM}/identity-provider/instances" 2>/dev/null \
        | python3 -c "
import sys, json
idps = json.load(sys.stdin)
for idp in idps:
    alias = idp.get('alias', '')
    provider = idp.get('providerId', '')
    enabled = idp.get('enabled', False)
    print(f'{alias}|{provider}|{\"enabled\" if enabled else \"disabled\"}')
" 2>/dev/null || true)
      if [[ -n "${IDPS}" ]]; then
        echo "${IDPS}" | while IFS='|' read -r alias provider status; do
          info "IdP: ${alias} (${provider}, ${status})"
        done
        pass "Identity provider(s) configured"
      else
        info "No external identity providers (using local users only)"
      fi

      # --- OIDC Issuer ---
      echo ""
      echo "--- OIDC Issuer ---"
      ISSUER_URL="${KC_URL}/realms/${REALM}"
      WELL_KNOWN=$(curl -sk -o /dev/null -w '%{http_code}' "${ISSUER_URL}/.well-known/openid-configuration" 2>/dev/null || true)
      if [[ "${WELL_KNOWN}" == "200" ]]; then
        pass "OIDC discovery endpoint reachable"
        info "Issuer: ${ISSUER_URL}"
      else
        fail "OIDC discovery returned HTTP ${WELL_KNOWN}"
      fi
    else
      fail "Realm '${REALM}' not found (HTTP ${REALM_CHECK})"
    fi
  fi
fi

# --- Summary ---
echo ""
echo "============================================================"
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "${FAIL}" -eq 0 ]]; then
  echo "STATUS: ALL PASSED"
else
  echo "STATUS: INCOMPLETE"
fi
echo "============================================================"
exit "${FAIL}"
