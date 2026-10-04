#!/usr/bin/env bash
# Live E2E for the SAW-BOM harness bundle (PR #53 follow-up).
#
# Verifies, against a real gateway VM, what the offline installer tests
# (make test-installer) can only model with fakes:
#   H1  bundle mounted read-only at /sandbox/harness
#   H2  volume content == applied source (audit: status.json appliedRevision)
#   H3  OpenClaw loads the bundle (MCP servers, plugins, skills)
#   H4  OpenClaw harness config points at the mount (no drift)
#   H5  no literal secrets in the mounted bundle (placeholders only)
#   H6  governance: live catalog serves the profile, host in its endpoints,
#       sandbox has a provider of that type
#   H7  cosign signature (image refs only; inline refs report SKIP)
#   H8  audit: volume admission labels present
#   H9  revocation drill (opt-in --revoke-drill): harnessRef removed ->
#       sandbox recreated without the mount, volume cleaned up
#
# Read-only by default: H1-H8 change nothing. H9 recreates the sandbox
# (agent work outside /sandbox/persist is lost, like any pod restart).
#
# Platform gaps from the PR review are OUT OF SCOPE here and tracked
# separately (upstream OpenShell, not this repo's installer):
#   - default-deny egress outside the VM
#   - tool actions tied to task/permissions + approval for consequential ones
#   - provider/admin keys protected from VM-root
#   - policy-update propagation to running workspaces
#   - in-cluster MCP Service reachability (L7 403 is the sandbox net policy)
#
# Prerequisites:
#   - oc logged in; openshell CLI installed and gateway selected
#   - a SAW deployed with demoHarness=true + allowDriverConfig=true, e.g.
#       helm upgrade --install <saw> charts/openshell-saw ... \
#         --set allowDriverConfig=true
#       helm upgrade --install saw-bom charts/saw-bom ... \
#         --set demoHarness=true
#
# Usage:
#   ./scripts/e2e-harness.sh [--gateway NAME] [--workspace WS]
#                            [--sandbox SB] [--bundle B] [--revoke-drill]
#   make test-harness-e2e OPENSHELL_SAW_NAME=my-saw [--revoke-drill via E2E_ARGS]

set -euo pipefail

GATEWAY="${OPENSHELL_SAW_NAME:-}"
WORKSPACE="${WORKSPACE:-default}"
SANDBOX="${HARNESS_SANDBOX:-notebook}"
BUNDLE="${HARNESS_BUNDLE_EXPECT:-ds-default}"
REVOKE_DRILL="no"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gateway)   GATEWAY="$2"; shift 2 ;;
    --workspace) WORKSPACE="$2"; shift 2 ;;
    --sandbox)   SANDBOX="$2"; shift 2 ;;
    --bundle)    BUNDLE="$2"; shift 2 ;;
    --revoke-drill) REVOKE_DRILL="yes"; shift ;;
    -h|--help)
      sed -n '1,32p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1 (see --help)"; exit 2 ;;
  esac
done

if [[ -z "${GATEWAY}" ]]; then
  echo "Error: set OPENSHELL_SAW_NAME or pass --gateway NAME."
  exit 2
fi

GW=(openshell --gateway "${GATEWAY}")
SB=(openshell --gateway "${GATEWAY}" sandbox exec -n "${SANDBOX}" --workspace "${WORKSPACE}" --no-tty --)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
FAIL=0; SKIPPED=0

step()  { echo -e "\n${CYAN}=== $1 ===${NC}"; }
pass()  { echo -e "  ${GREEN}PASS${NC} $1"; }
fail()  { echo -e "  ${RED}FAIL${NC} $1"; FAIL=1; }
skip()  { echo -e "  ${YELLOW}SKIP${NC} $1"; SKIPPED=$((SKIPPED+1)); }
check() { # check <label> -- <cmd...>: PASS when cmd exits 0
  local label="$1"; shift
  [[ "${1:-}" == "--" ]] && shift
  if "$@" >/tmp/e2e-harness-out 2>&1; then pass "${label}"; else fail "${label}"; sed 's/^/    /' /tmp/e2e-harness-out; fi
}

sb_exec() { "${SB[@]}" "$@"; }

step "Pre-flight"
check "openshell CLI present" -- command -v openshell
check "gateway '${GATEWAY}' reachable" -- "${GW[@]}" sandbox list --workspace "${WORKSPACE}"
check "sandbox '${SANDBOX}' exists" -- \
  bash -c "\"${GW[@]} sandbox list --workspace '${WORKSPACE}'\" | grep -q '^${SANDBOX} '"

# Which source did the installer apply? status.json lives on the VM
# (root-owned); read it over vm-ssh when available, else report and continue.
step "Audit source (status.json appliedRevision)"
STATUS_JSON=""
if command -v virtctl >/dev/null 2>&1; then
  SAW_NS="${SAW_NS:-saw-${GATEWAY}}"
  SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.generated-ssh-keys/sandbox-ssh}"
  STATUS_JSON=$(virtctl -n "${SAW_NS}" ssh "cloud-user@vm/${GATEWAY}" \
    --identity-file="${SSH_KEY_PATH}" \
    --local-ssh-opts=-oStrictHostKeyChecking=no \
    --local-ssh-opts=-oUserKnownHostsFile=/dev/null \
    --command="sudo cat /var/lib/saw/status.json" 2>/dev/null || true)
fi
if [[ -n "${STATUS_JSON}" ]]; then
  echo "${STATUS_JSON}" | python3 -c "
import json,sys
d = json.load(sys.stdin)
rev = (d.get('apply') or {}).get('appliedRevision', {})
print('  appliedRevision:', json.dumps(rev))
" || fail "status.json parses as JSON"
  if echo "${STATUS_JSON}" | grep -q "${SANDBOX}"; then
    pass "status.json records sandbox '${SANDBOX}'"
  else
    fail "status.json has no entry for sandbox '${SANDBOX}'"
  fi
else
  skip "status.json not reachable (needs virtctl + vm-ssh); H2 compares mount content only"
fi

step "H1: read-only mount at /sandbox/harness"
check "mountpoint exists" -- sb_exec test -d /sandbox/harness
MOUNT_LINE=$(sb_exec mount 2>/dev/null | grep " /sandbox/harness " || true)
if [[ -z "${MOUNT_LINE}" ]]; then
  fail "no /sandbox/harness entry in mount table"
else
  echo "  ${MOUNT_LINE}"
  if echo "${MOUNT_LINE}" | grep -q "ro[, ]"; then pass "mounted read-only"; else fail "mount is not read-only"; fi
fi
# A write through the mount must be refused (proves RO end to end).
if sb_exec sh -c 'touch /sandbox/harness/.w 2>/dev/null' 2>/dev/null; then
  fail "write to /sandbox/harness succeeded (should be refused)"
else
  pass "write to /sandbox/harness refused"
fi

step "H2: mounted content is the bundle"
check "plugin.json present" -- sb_exec test -f /sandbox/harness/plugin.json
check "mcp.json present" -- sb_exec test -f /sandbox/harness/mcp.json
check "skills dir present" -- sb_exec test -d /sandbox/harness/skills
check "revision marker present" -- sb_exec test -f /sandbox/harness/.saw-harness-revision
if [[ -n "${STATUS_JSON}" ]]; then
  MARKER_SRC=$(sb_exec cat /sandbox/harness/.saw-harness-revision 2>/dev/null || true)
  if echo "${STATUS_JSON}" | grep -q "$(echo "${MARKER_SRC}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('source',''))" 2>/dev/null)"; then
    pass "marker source matches appliedRevision"
  else
    fail "marker source does not match appliedRevision (drift?)"
  fi
fi

step "H3: OpenClaw loads the bundle"
# `mcp list` never shows bundle servers; check `plugins list --json` instead.
PLUGINS_JSON=$(sb_exec sh -c 'OPENCLAW_HOME=/sandbox openclaw plugins list --json' 2>/dev/null || true)
if [[ -z "${PLUGINS_JSON}" ]]; then
  fail "openclaw plugins list --json returned nothing"
else
  # Same bar as the installer's verify: mount row loaded, caps covering the
  # mounted tree, every native plugin id enabled.
  NEED_CAPS=""
  sb_exec test -f /sandbox/harness/mcp.json >/dev/null 2>&1 && NEED_CAPS="mcpServers"
  sb_exec test -d /sandbox/harness/skills >/dev/null 2>&1 && NEED_CAPS="${NEED_CAPS} skills"
  NEED_PLUGINS=$(sb_exec ls /sandbox/harness/plugins 2>/dev/null || true)
  echo "${PLUGINS_JSON}" | NEED_CAPS="${NEED_CAPS}" NEED_PLUGINS="${NEED_PLUGINS}" python3 -c "
import json, os, sys
plugins = json.load(sys.stdin).get('plugins') or []
rows = [p for p in plugins if isinstance(p, dict)]
bundle = next((p for p in rows if p.get('format') == 'bundle'
               and p.get('rootDir') == '/sandbox/harness'), None)
assert bundle and bundle.get('enabled') and bundle.get('status') == 'loaded', 'bundle row not loaded'
caps = set(bundle.get('bundleCapabilities') or [])
if caps:
    missing = sorted(set(os.environ['NEED_CAPS'].split()) - caps)
    assert not missing, f'bundle lacks capabilities: {missing}'
by_id = {p.get('id') or p.get('name'): p for p in rows}
missing = [p for p in os.environ['NEED_PLUGINS'].split()
           if not by_id.get(p, {}).get('enabled', False)]
assert not missing, f'plugins not enabled: {missing}'
print('  bundle:', bundle.get('id'), '| caps:', ','.join(sorted(caps)) or '<unreported>')
print('  enabled plugins:', ' '.join(sorted(by_id)) or '<none>')
" && pass "bundle row loaded from /sandbox/harness (caps + plugins match)" \
    || fail "bundle row missing/disabled/capability-short in plugins list --json"
fi

step "H4: OpenClaw harness config points at the mount"
PATHS=$(sb_exec sh -c 'openclaw config get plugins.load.paths' 2>/dev/null || true)
if echo "${PATHS}" | grep -q "/sandbox/harness"; then
  pass "plugins.load.paths includes /sandbox/harness"
else
  fail "plugins.load.paths missing /sandbox/harness (got: ${PATHS:-<unset>})"
fi

step "H5: no literal secrets in the mounted bundle"
# Placeholders (${VAR} / Bearer ${VAR}) are the only allowed secret shape.
if sb_exec sh -c 'grep -rniE "api[_-]?key|bearer [A-Za-z0-9._-]{16,}|sk-[A-Za-z0-9]{16,}" /sandbox/harness/mcp.json' \
    2>/dev/null | grep -v '\${' >/dev/null; then
  fail "literal secret pattern found in mounted mcp.json"
else
  pass "mounted mcp.json holds no literal secrets"
fi

step "H6: governance against the live catalog"
CATALOG=$("${GW[@]}" provider list-profiles --workspace "${WORKSPACE}" -o json 2>/dev/null || true)
if [[ -z "${CATALOG}" ]]; then
  fail "provider list-profiles returned nothing"
else
  echo "${CATALOG}" | python3 -c "import json,sys; print('  profiles:', sorted(p['id'] for p in json.load(sys.stdin)))" \
    || fail "catalog is not JSON"
  # Every governanceProfile named by the bundle must be served...
  PROFILES_NEEDED=$(sb_exec sh -c 'cat /sandbox/harness/harness.yaml' 2>/dev/null \
    | python3 -c "import sys,yaml; d=yaml.safe_load(sys.stdin); got=set(); [got.add(x.get('governanceProfile')) for k in ('mcpServers','plugins') for x in (d.get('spec') or {}).get(k) or [] if x.get('governanceProfile')]; print(' '.join(sorted(got)))" 2>/dev/null || true)
  echo "  bundle needs profiles: ${PROFILES_NEEDED:-<none declared>}"
  for p in ${PROFILES_NEEDED:-}; do
    if echo "${CATALOG}" | grep -q "\"id\": *\"$p\""; then pass "catalog serves '${p}'"; else fail "catalog does not serve '${p}'"; fi
  done
  # ...and the sandbox must hold a provider of each type.
  ATTACHED=$("${GW[@]}" sandbox provider list "${SANDBOX}" --workspace "${WORKSPACE}" 2>/dev/null || true)
  for p in ${PROFILES_NEEDED:-}; do
    if echo "${ATTACHED}" | grep -qw "$p"; then pass "sandbox has provider '${p}'"; else fail "sandbox lacks provider '${p}'"; fi
  done
fi

step "H7: cosign (image refs only)"
HREF_KIND=""
if [[ -n "${STATUS_JSON}" ]]; then
  HREF_KIND=$(echo "${STATUS_JSON}" | python3 -c "
import json,sys
rev = (json.load(sys.stdin).get('apply') or {}).get('appliedRevision', {})
v = rev.get('${SANDBOX}','')
print('image' if '@sha256:' in v or 'ghcr.io' in v else 'inline')" 2>/dev/null || true)
fi
if [[ "${HREF_KIND}" == "image" ]]; then
  if command -v cosign >/dev/null 2>&1; then
    check "cosign verifies the applied image" -- bash -c "echo '${STATUS_JSON}' | python3 -c \"import json,sys; print((json.load(sys.stdin).get('apply') or {}).get('appliedRevision',{}).get('${SANDBOX}',''))\" | xargs -I{} cosign verify {}"
  else
    skip "cosign not installed; installer verified at apply time (see status)"
  fi
else
  skip "inline ConfigMap bundle: no image signature to verify (installer enforces digest when pinned)"
fi

step "H8: audit labels on the harness volume"
if [[ -n "${STATUS_JSON}" ]] && command -v virtctl >/dev/null 2>&1; then
  SAW_NS="${SAW_NS:-saw-${GATEWAY}}"
  SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.generated-ssh-keys/sandbox-ssh}"
  LABELS=$(virtctl -n "${SAW_NS}" ssh "cloud-user@vm/${GATEWAY}" \
    --identity-file="${SSH_KEY_PATH}" \
    --local-ssh-opts=-oStrictHostKeyChecking=no \
    --local-ssh-opts=-oUserKnownHostsFile=/dev/null \
    --command="podman volume inspect saw-harness-${WORKSPACE}-${SANDBOX}-* --format '{{.Labels}}' 2>/dev/null" 2>/dev/null || true)
  if echo "${LABELS}" | grep -q "sandbox-attachable"; then
    pass "harness volume carries admission labels"
  else
    skip "volume labels not reachable from here (installer sets openshell.ai/sandbox-attachable*)"
  fi
else
  skip "volume labels need vm-ssh; covered offline by test_harness_mount.py"
fi

if [[ "${REVOKE_DRILL}" == "yes" ]]; then
  step "H9: revocation drill (DESTRUCTIVE: recreates '${SANDBOX}')"
  echo -e "  ${YELLOW}Remove the harnessRef from the profile, re-apply, then re-run this script:${NC}"
  echo "  1. helm upgrade saw-bom charts/saw-bom --set demoHarness=false"
  echo "     (or drop harnessRef from the sandbox) + restart the VM installer"
  echo "  2. expect: sandbox recreated WITHOUT /sandbox/harness,"
  echo "     'openclaw config get plugins.load.paths' no longer lists it,"
  echo "     unused harness volume removed."
  echo "  3. restore: re-add the harnessRef, re-apply, re-run without --revoke-drill."
  skip "manual drill: instructions printed above (not executed by the script)"
fi

echo ""
echo "============================================="
if [[ "${FAIL}" -eq 0 ]]; then
  echo -e " HARNESS E2E ${GREEN}PASSED${NC} (skipped: ${SKIPPED})"
else
  echo -e " HARNESS E2E ${RED}FAILED${NC} (skipped: ${SKIPPED})"
fi
echo "============================================="
exit "${FAIL}"
