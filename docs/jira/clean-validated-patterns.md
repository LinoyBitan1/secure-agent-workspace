# Clean Validated Patterns: Review make targets and interface cleanliness

**Project:** APPENG
**Type:** Story
**Epic:** Secure Agent Workspace Validated Pattern
**Priority:** Medium
**Component:** RH_AI_Blueprints
**Labels:** secure_agent_workspace, cleanup, developer_experience, validated_patterns

## Summary

Review and clean up the Secure Agent Workspace validated pattern repository to ensure make targets are consistent, well-documented, and follow conventions. Remove dead code, unused targets, stale references, and ensure the developer interface is clean and intuitive for new users.

## Background

The repository has grown organically through rapid iteration. Make targets, Helm values, scripts, and chart structure need a hygiene pass to ensure:

- New users can onboard quickly by reading the Makefile and README
- Make targets have consistent naming, clear help text, and predictable behavior
- No orphaned files, dead config, or commented-out experiments remain in the main branch
- The pattern follows validated patterns conventions for discoverability in the catalog

## Acceptance Criteria

1. Every make target has a `## Help text` comment and appears in `make help`
2. No make target fails silently or produces confusing output
3. No orphaned charts, scripts, or templates remain in the repository
4. Values files have no commented-out alternatives or experimental blocks
5. README accurately reflects the current make targets and deployment flow
6. Pattern passes `make lint` / `helm lint` cleanly

## Review Checklist

### Makefile targets — rename and restructure

Current make targets use inconsistent naming (`openshell-saw-create` vs `build-nemoclaw` vs `copy-images`). Rename to a consistent `noun-verb` or `group-action` convention.

Proposed renaming:

| Current | Proposed | Rationale |
|---------|----------|-----------|
| `build-openshell-gateway` | `gateway-build` | Group by component |
| `build-nemoclaw` | `sandbox-build` | User-facing name |
| `build-nemoclaw-cli` | `cli-build` | Consistent with above |
| `copy-images` | `images-mirror` | Clearer action |
| `openshell-saw-create` | `saw-create` | Drop redundant prefix |
| `openshell-saw-delete` | `saw-delete` | Drop redundant prefix |
| `openshell-saw-configure-gateway` | `saw-configure` | Shorter |
| `openshell-saw-tui` | `saw-tui` | Drop redundant prefix |
| `openshell-saw-gui` | `saw-gui` | Drop redundant prefix |
| `openshell-saw-ssh` | `saw-ssh` | Drop redundant prefix |
| `openshell-saw-logs` | `saw-logs` | Drop redundant prefix |
| `openshell-saw-list` | `saw-list` | Drop redundant prefix |

- [ ] Audit all targets in `Makefile-quickstart` — remove unused, rename inconsistent
- [ ] Verify every target has `## description` for `make help` output
- [ ] Ensure target naming follows a consistent convention
- [ ] Check prerequisite targets (`.check-saw-name`, `.check-ssh-key`, `.check-prereqs`) are correct and useful
- [ ] Verify `make pattern-install` and `make pattern-uninstall` work end-to-end
- [ ] Remove any targets that reference removed features or old flows
- [ ] Ensure `OPENSHELL_SAW_NAME` is consistently required/optional across targets
- [ ] Verify variable defaults (`NS`, `BUILD_NS`, `QUAY_REPO`, `OPENSHELL_VERSION`) are sensible

### Evaluate: Python CLI vs Makefile

The current Makefile approach has limitations:
- Variable passing is awkward (`make saw-create OPENSHELL_SAW_NAME=foo PROVIDER=gemini`)
- Error handling is limited (shell `|| true` patterns)
- No built-in argument validation, help text formatting, or interactive prompts
- Difficult to compose multi-step workflows with rollback
- Shell escaping and quoting issues in embedded scripts

**Evaluate a Python CLI** (e.g., `click` or `typer`) as an alternative:

```bash
# Current
make openshell-saw-create OPENSHELL_SAW_NAME=my-saw PROVIDER=gemini MODEL=gemini-2.5-flash

# Proposed CLI
saw create my-saw --provider gemini --model gemini-2.5-flash
saw list
saw ssh my-saw
saw tui my-saw
saw gui my-saw
saw delete my-saw
saw images mirror --version v0.0.97-rhaiv.0
saw gateway build
saw status
```

Benefits of a Python CLI:
- **Subcommands with built-in help**: `saw create --help` shows all options
- **Argument validation**: required args, type checking, choices
- **Interactive prompts**: ask for missing values instead of failing
- **Colored output**: progress bars, status tables, error formatting
- **Composable**: multi-step workflows with proper error handling and rollback
- **Testable**: unit tests for CLI logic, not just template rendering
- **Distributable**: `pip install saw` or bundle in the repo

Risks:
- Adds a Python dependency (but `openshell` CLI already requires Python/pip)
- Deviates from validated patterns convention (which uses Makefiles)
- Needs to coexist with `make pattern-install` (VP operator entry point)

**Recommendation:** Keep `make pattern-install` / `make pattern-uninstall` as the VP-standard entry points. Add a Python CLI (`saw`) for day-2 operations (create, delete, ssh, tui, gui, images, status). The Makefile becomes a thin wrapper that calls the CLI.

**Action:** Work with a UX designer to review the CLI command structure, target naming, help text, error messages, and overall developer experience before finalizing. The interface is the first thing new users see — it should be intuitive, consistent, and self-documenting.

### Helm charts

- [ ] `charts/openshell-saw` — remove unused values, clean up comments
- [ ] `charts/openshell-keycloak` — verify realm import is complete and idempotent
- [ ] `charts/openshift-registry` — confirm removed or still needed
- [ ] `image-builder-charts/helm/*` — verify all three image charts (gateway, sandbox, CLI) are consistent
- [ ] All charts pass `helm lint`
- [ ] No hardcoded values that should be in `values.yaml`
- [ ] Template conditionals are clean (no nested `if .Values.global` workarounds that could be simplified)

### Scripts

- [ ] `scripts/` directory — remove any unused scripts
- [ ] `scripts/push-image.sh` — verify quay auth check works
- [ ] `scripts/openshell-saw-gui.sh` — verify token extraction is reliable
- [ ] `scripts/generate-keys.sh` — verify idempotent behavior
- [ ] All scripts have `set -euo pipefail` and proper error handling
- [ ] No scripts reference removed features or old onboarding paths

### ConfigMap scripts (configmap-scripts.yaml)

- [ ] `run-setup.sh` — clean, well-commented, no dead branches
- [ ] `setup-nemoclaw.sh` — remove any remnants of old onboarding flows (openclaw onboard, nemoclaw onboard experiments)
- [ ] `run-create.sh` — verify all exported env vars are actually used
- [ ] `setup-dashboard.sh` — verify dashboard setup is clean
- [ ] `inject-user-pubkey.sh` — verify minimal and correct
- [ ] `configure-vertex-user.sh` — still needed? clean up if legacy

### Values files

- [ ] Remove commented-out image references (e.g., `# gatewayImage: "ghcr.io/..."` vs `# gatewayImage: "quay.io/..."`)
- [ ] Ensure defaults are production-ready, not debug/test values
- [ ] Document non-obvious values with inline comments
- [ ] Verify `values-global.yaml` and `values-prod.yaml` overrides are minimal and correct

### Documentation

- [ ] README reflects current flow (not old podman/openclaw onboard paths)
- [ ] CLAUDE.md is up to date (if present)
- [ ] No stale references to removed branches or PRs
- [ ] Quickstart instructions work from scratch on a new cluster

### Git hygiene

- [ ] `.gitignore` covers all generated/local files
- [ ] No secrets, credentials, or API keys in git history
- [ ] No large binaries or build artifacts committed
- [ ] Branch naming is consistent

## Out of Scope

- Feature development (covered by other stories)
- Architecture changes (covered by other stories)
- Refactoring configmap-scripts.yaml into separate files (separate story)
