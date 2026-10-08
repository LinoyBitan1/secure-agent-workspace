# PR 78 Review Fixes Implementation Plan

> **For agentic workers:** Use subagent-driven-development to implement the tasks with regression tests and review checkpoints. The initial implementation was left uncommitted for review. The user subsequently authorized a temporary branch for Option A cluster testing, followed by pushing verified fixes to the PR branch. Keep test-only deployment settings separate from PR fixes.

**Goal:** Close all seven review items on PR 78 without weakening mount admission or silently accepting failed signature verification.

**Architecture:** Keep admission in the governance interceptor, signature lifecycle and registration checks in the installer, and deployment-aware harness disable/restore in the E2E script. Reuse successful digest verification for a bounded period in the existing trusted ledger; never extend trust after a failed recheck. Both interceptor build paths compile and execute the guard's behavioral Rust tests.

**Tech Stack:** Python/pytest, Rust/serde_json, Bash, Helm, OpenShift/Argo CD, GitHub Actions.

## Global Constraints

- Work on `fix/pr53-nvidia-gaps`; preserve the untracked nested checkout.
- Prefix all shell commands with `rtk`. No `.codegraph/` exists; do not index.
- Driver config requires `kind=user`, `provider=mtls`, and the comma-separated `openshell-admin` role.
- Permit only one podman harness mount: `type=volume`, nonempty source starting `saw-harness-`, target `/sandbox/harness`, and `read_only=true`; reject other drivers/options/mounts.
- Pin both interceptor builds to `v0.1.2` by default and compile the actual patched upstream interceptor in PR CI without publishing.
- Verification cache defaults to 300 seconds, configurable from 0 through 300 seconds. Zero disables caching. Scope by full digest image, identity, and issuer; policy changes invalidate cached trust. Future/invalid timestamps are never trusted, dry-run never persists trust, and failure never uses an expired success.
- On failed signature verification, remove the existing mounted sandbox and recreate it without the harness before reporting failure. First-time refused images never create a sandbox. Reapply after trust is restored must restore the mount.
- MCP inspection proves registration only. Use JSON server entries, reject unsupported entries and error status/diagnostics, and emit explicit warnings for unsupported inspection. Use the same inspection semantics in H3; no substring/word-boundary searches over prose.
- H9 must work for Helm and Argo CD deployments, restore original state on failure or signals, and exit on INT/TERM. Do not patch a live cluster during development.

---

### Task 1: Restrict and compile interceptor admission (review items 1 and 7)

**Files:** `image-builder-charts/governance-interceptor/Dockerfile`, `image-builder-charts/helm/governance-interceptor-image/templates/buildconfig.yaml`, `tests/charts/test_governance_interceptor_image.py`, `.github/workflows/build-governance-interceptor.yml`, `.github/actions/build-push-image/action.yml` if needed.

**Interfaces:** Existing `validate_driver_config(Option<&Value>, &HashMap<String,String>) -> InterceptorResult` runs for both creation operations.

- [x] Add failing behavioral Rust tests against the exact guard text extracted from both Dockerfiles, covering OIDC admin, nonadmin mTLS, bind mount, wrong source/target, writable/missing mode, other drivers/options, malformed envelopes, and valid installer mount.
- [x] Run `rtk pytest -q tests/charts/test_governance_interceptor_image.py`; confirm security cases fail on current guard.
- [x] Tighten admission. The allowed shape is exactly `{"podman":{"mounts":[{"type":"volume","source":"saw-harness-default-notebook-12345678","target":"/sandbox/harness","read_only":true}]}}`. Absent/empty driver config remains allowed; malformed supplied config is refused.
- [x] Set Dockerfile default to `ARG OPENSHELL_REF=v0.1.2`; keep full-source patch anchors fail-loud. Run Rust tests and cargo build in each builder. Ensure PR CI builds without registry login/push and verifies chart pin matches the default.
- [x] Rerun guard tests, Helm render, and actual patched upstream compilation if available. Record evidence and any external execution limitation.

### Task 2: Signature lifecycle, bounded cache, accurate MCP registration (items 2, 3, 5)

**Files:** `charts/openshell-saw/files/installer/apply_bom.py`, `charts/openshell-saw/values.yaml`, `charts/openshell-saw/templates/configmap-installer.yaml`, `tests/installer/test_harness_mount.py`, `tests/installer/fakes/openshell`, `tests/charts/test_openshell_saw_chart.py`, `docs/harness-bundles.md`.

**Interfaces:** `verify_harness_image(image)` remains the trust gate. Ledger stores successful verification time/policy per digest. `verify_harness` consumes structured `openclaw plugins inspect <actual bundle id> --runtime --json` output.

- [x] Add failing tests: revoked previously mounted harness leaves no mounted volume/config and can recover; fresh cache avoids network, expired/policy-changed/future cache does not; failures never renew trust; dry-run/no ledger cannot persist trust. Existing revocation tests disable caching to require immediate rechecks.
- [x] Add failing structured-inspection cases: absent server, hyphenated collision, unsupported entry, plugin runtime error/diagnostic containing the expected name, differing manifest/bundle ids, and unavailable inspection warning.
- [x] Run the new tests and confirm expected failures.
- [x] Implement cache with `0 <= now - verifiedAt < ttl` and exact identity/issuer matching. Persist only successful real verification. Bound TTL to 300; propagate the Helm field into config and validate it.
- [x] On trust refusal for an existing harness-mounted sandbox, delete and wait, clear in-memory harness info, and create/configure the same sandbox with `harness_ref={}`. Keep the requested source refused and report original verification failure. The volume/image cleanup then removes rejected content; never recreate the mount during remediation.
- [x] Parse inspect JSON and compare `mcpServers[].name` exactly; inspect the selected mounted bundle's actual id. Use registration language in warnings/docs; do not claim process readiness. Unsupported CLI produces an explicit degraded-verification warning.
- [x] Run installer harness and affected chart tests. Document five-minute maximum cache grace, immediate invalidation on identity/issuer changes, cache disable, fail-closed expiry, network hosts required for periodic verification, and active mount removal after refusal.

### Task 3: Consistent H3 and deployment-aware H9 (items 4 and 6)

**Files:** `scripts/e2e-harness.sh`, E2E helper/test files as needed, `tests/scripts/test_e2e_harness.py` or a matching existing test location, `docs/harness-bundles.md`.

**Interfaces:** Existing gateway/sandbox arguments stay valid. Add explicit Argo Application/namespace options with automatic discovery by destination namespace and chart path. H9 changes the controller's desired state and waits for the ConfigMap to reflect it before restarting non-live-input VMs.

- [x] Add failing CLI-fake tests for H3 structured exact-name registration and unsupported output; Helm disable/restore; Argo Application discovery/parameter override, sync/self-heal behavior; restore after failed polling and INT/TERM.
- [x] Run tests to show current H3/H9 failures.
- [x] Use mounted bundle id and `plugins inspect --runtime --json` in H3 with structured name checks. Clearly label registration and skipped readiness.
- [x] For Helm, preserve the original harness flag. For Argo, snapshot the exact parameter list and automated sync setting, temporarily suspend automation on the BOM Application and its managing parent if necessary, update the desired parameter, request reconciliation, wait for rendered profiles, restart only when required, and restore snapshots on exit. Refuse ambiguous discovery or unsupported controller ownership rather than falsely passing.
- [x] Separate EXIT cleanup from signal handlers: `trap 'exit 130' INT` and `trap 'exit 143' TERM`; cleanup restores controller state and the harness. Do not clear cleanup before restoration succeeds.
- [x] Run E2E fake tests and `rtk bash -n scripts/e2e-harness.sh`; document options and that H9 is harness disable/restore, not signature revocation.

### Final verification

- [x] Review each task's diff for spec and quality, then review the combined changes.
- [x] Run the harness and chart suites plus script regressions; compare pre-existing gateway process test failures against pinned base when needed.
- [x] Record final build evidence, test counts, and cluster-only limitations in this plan. Do not claim live cluster validation unless executed.
- [x] Leave the initial implementation uncommitted for review; subsequent user authorization permits temporary-branch testing and final PR push.

## Execution ledger

- Task 1: implemented and independently reviewed (spec and quality pass). 20 chart tests; both exact embedded guards exercised. Patched upstream OpenShell v0.1.2: five Rust guard tests passed and locked release build succeeded. Docker daemon access prevented local container assembly; PR CI now builds both sources without authentication or publication.
- Task 2: implemented and independently reviewed (spec and quality pass). New regressions reproduced before fixes. Follow-up review found inconclusive mount inspection could skip remediation; four failing inspection cases now pass. Focused lifecycle/registration tests: 20 passed. Installer/chart run: 138 passed, three previously reproduced base process-test failures. Final full installer/chart run: 622 passed, six gateway-process failures; see final verification below.
- Task 3: implemented and combined review passed. 17 public CLI fake regressions passed; Bash syntax and Python compilation passed. Tests are included in existing Make/CI targets. No live cluster mutation performed. Final complete script suite: 131 passed.

- Combined review: all three tasks passed spec and quality review with no remaining actionable findings. Final Argo restore sequencing saves desired parameters, waits for prior operations, then syncs original state; automation restoration is attempted even after polling failure.

## Final verification results

- Full installer/chart suite (with local socket permissions): **622 passed, 6 failed**. Four failures also reproduce on unchanged PR HEAD `1d24083`: `test_a_running_gateway_is_kept_when_nothing_changed`, `test_a_refill_replaces_the_running_gateway`, `test_changed_settings_replace_the_running_gateway`, and `test_an_older_openclaw_gets_the_trusted_proxy_form_it_accepts`. The two additional failures (`test_every_openclaw_sandbox_ends_up_with_a_gateway[notebook]` and `test_a_running_gateway_without_a_fingerprint_is_replaced`) passed in an isolated comparison on the updated branch. These process-based test results vary with execution context; the full suite is not claimed green. The generated `openclaw_gateway_script` is AST-identical to original PR HEAD.
- Complete `tests/scripts`: **131 passed**, including all 17 new public CLI regressions. Initial sandbox runs could not bind local HTTP sockets; permitted reruns resolved those errors. An Argo fake initially failed before snapshot/mutation; corrected to fail after controller mutation, then verified restoration and retained recovery snapshot.
- Both exact embedded Rust guards pass behavioral tests in the chart suite. Patched full OpenShell v0.1.2 source passes **5 Rust guard tests** and the locked release build. Both builder paths are compiled/tested in PR CI.
- Bash syntax, installer/helper Python compilation, and `git diff --check`: passed. Task and combined reviews: passed with no remaining actionable findings.
- Limits: no live Helm/Argo/VM drill, and Docker daemon access prevented local full container assembly. Signature verification reuse has a documented maximum five-minute revocation grace; set `cacheTtlSeconds: 0` for every-apply verification. Required Sigstore/registry hosts are documented for PR #68.
- All seven initial review fixes were implemented before cluster testing. The user then authorized commits and pushes to a temporary branch. The pre-existing nested checkout remains untouched.

## Live validation refinement

See [cluster validation](2026-10-08-pr78-cluster-validation.md). Real deployment showed that `CreateSandboxTemplate` exists but is not interceptable in OpenShell 0.1.2. The final guard rejects template-based `CreateSandbox` before its driver config resolves, rather than installing an unsupported RPC binding. Both builders execute six Rust tests. Live testing also corrected volume-name enumeration and the exact unset-config response in H9.
