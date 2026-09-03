#!/usr/bin/env bash
# Manage governance interceptor provider profiles via GitOps.
#
# Profiles are auto-discovered from charts/governance-policy/profiles/*.yaml.
# Adding a profile = dropping a file. Removing = deleting the file.
# No values.yaml edit needed — the ConfigMap globs all profile files.
#
# Usage:
#   governance-profile.sh list
#   governance-profile.sh add    <profile-name>
#   governance-profile.sh remove <profile-name>
#   governance-profile.sh create <name> <file>

set -euo pipefail

NS="${NS:-openshell-agents}"
SAW_NAME="${SAW_NAME:-openshell-saw}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROFILES_DIR="${REPO_DIR}/charts/governance-policy/profiles"
SSH_KEY="${SSH_KEY:-$HOME/.generated-ssh-keys/sandbox-ssh}"

usage() {
  echo "Usage: $0 {list|add|remove|create} [profile-name] [file]"
  echo ""
  echo "Commands:"
  echo "  list                      List active governance profiles"
  echo "  add <name>                Re-enable a previously removed profile (from git history)"
  echo "  remove <name>             Remove a provider profile file (git push + ArgoCD sync)"
  echo "  create <name> <file>      Create a new profile from a YAML file"
  echo ""
  echo "Active profiles:"
  for f in "${PROFILES_DIR}"/*.yaml; do
    [[ -f "${f}" ]] && echo "  - $(basename "${f}" .yaml)"
  done
  echo ""
  echo "Examples:"
  echo "  $0 list"
  echo "  $0 remove github"
  echo "  $0 create jira /path/to/jira-profile.yaml"
  exit 1
}

wait_for_sync() {
  local expected_key="${1:-}"
  local expected_action="${2:-}"
  echo "  Waiting for ArgoCD to sync..."
  oc annotate application governance-policy -n vp-gitops \
    argocd.argoproj.io/refresh=hard --overwrite > /dev/null 2>&1

  local profile_name="${expected_key%.yaml}"
  for i in $(seq 1 36); do
    sleep 5
    local profiles
    profiles=$(openshell --gateway "${SAW_NAME}" provider list-profiles 2>&1 || true)
    if [[ -n "${expected_action}" && -n "${profile_name}" ]]; then
      if [[ "${expected_action}" == "appear" ]] && echo "${profiles}" | grep -q "${profile_name}"; then
        echo "  Profile '${profile_name}' is now active. (${i} polls)"
        return 0
      elif [[ "${expected_action}" == "disappear" ]] && ! echo "${profiles}" | grep -q "${profile_name}"; then
        echo "  Profile '${profile_name}' removed. (${i} polls)"
        return 0
      fi
    fi
  done
  echo "  Warning: timed out waiting for profile change (3 min)."
}

cmd_list() {
  echo "Active profiles (enforced on gateway):"
  echo ""
  openshell --gateway "${SAW_NAME}" provider list-profiles
}

cmd_add() {
  local name="${1:?Profile name is required}"

  if [[ -f "${PROFILES_DIR}/${name}.yaml" ]]; then
    echo "Profile '${name}' already exists."
    return 0
  fi

  # Try to restore from git history
  local restored=false
  for path in "charts/governance-policy/profiles/${name}.yaml" "charts/governance-interceptor/profiles/${name}.yaml"; do
    local commit
    commit=$(git -C "${REPO_DIR}" log --all --diff-filter=D --format='%H' -1 -- "${path}" 2>/dev/null || true)
    if [[ -n "${commit}" ]] && git -C "${REPO_DIR}" show "${commit}~1:${path}" > "${PROFILES_DIR}/${name}.yaml" 2>/dev/null; then
      restored=true
      break
    fi
  done
  if [[ "${restored}" != "true" ]]; then
    echo "Error: profile '${name}' not found in git history. Use 'create' instead." >&2
    rm -f "${PROFILES_DIR}/${name}.yaml"
    exit 1
  fi
  echo "Restoring profile '${name}' from git history..."

  git -C "${REPO_DIR}" add "${PROFILES_DIR}/${name}.yaml" > /dev/null 2>&1
  git -C "${REPO_DIR}" commit -m "policy: enable ${name} provider profile" --no-verify > /dev/null 2>&1
  git -C "${REPO_DIR}" push origin HEAD --no-verify > /dev/null 2>&1
  echo "  Pushed: restored profiles/${name}.yaml"

  wait_for_sync "${name}.yaml" appear
  echo ""
  echo "Profile '${name}' enabled."
}

cmd_remove() {
  local name="${1:?Profile name is required}"

  if [[ ! -f "${PROFILES_DIR}/${name}.yaml" ]]; then
    echo "Profile '${name}' is not active."
    return 0
  fi

  echo "Removing profile '${name}'..."
  rm -f "${PROFILES_DIR}/${name}.yaml"

  git -C "${REPO_DIR}" add -A "${PROFILES_DIR}" > /dev/null 2>&1
  git -C "${REPO_DIR}" commit -m "policy: revoke ${name} provider profile" --no-verify > /dev/null 2>&1
  git -C "${REPO_DIR}" push origin HEAD --no-verify > /dev/null 2>&1
  echo "  Pushed: removed profiles/${name}.yaml"

  wait_for_sync "${name}.yaml" disappear
  echo ""
  echo "Profile '${name}' disabled."
}

cmd_create() {
  local name="${1:?Profile name is required}"
  local file="${2:?Profile YAML file is required}"

  if [[ ! -f "${file}" ]]; then
    echo "Error: file '${file}' not found" >&2
    exit 1
  fi

  local dest="${PROFILES_DIR}/${name}.yaml"

  if [[ -f "${dest}" ]]; then
    echo "Profile '${name}' already exists."
    return 1
  fi

  echo "Creating profile '${name}' from ${file}..."
  cp "${file}" "${dest}"
  echo "  Created: profiles/${name}.yaml"

  git -C "${REPO_DIR}" add "${dest}" > /dev/null 2>&1
  git -C "${REPO_DIR}" commit -m "policy: add ${name} provider profile" --no-verify > /dev/null 2>&1
  git -C "${REPO_DIR}" push origin HEAD --no-verify > /dev/null 2>&1
  echo "  Pushed: profiles/${name}.yaml"

  wait_for_sync "${name}.yaml" appear
  echo ""
  echo "Profile '${name}' created and enabled."
}

[[ $# -ge 1 ]] || usage

case "$1" in
  list)   cmd_list ;;
  add)    cmd_add "${2:-}" ;;
  remove) cmd_remove "${2:-}" ;;
  create) cmd_create "${2:-}" "${3:-}" ;;
  *)      usage ;;
esac
