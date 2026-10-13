# NemoClaw upgrade acceptance test

Test on a fresh, dedicated OpenShift cluster using README Option A. Never store
cluster passwords, provider keys, tokens, or Keycloak passwords in evidence.

## Version and build checks

The upgrade pins both builds to NemoClaw `v0.0.133`, commit
`ef5d55d19e2da33c2474db158588613828e1a9be`, and its matching sandbox base.
Run `make cli-build` and `make sandbox-build`. Both must reach Complete; record
the output image digests. Check `dist/build-identity.json` in the CLI image:
`nemoclawVersion` must be `0.0.133` and `sourceRevision` must match the pin.
The image stamps both explicitly because the upstream package version is a
fallback and the container build need not retain Git metadata. Discovery must pass npm audit, signature checks,
its HTTP protocol tests, TypeScript, and bundle generation in the cluster.
Use these new image digests in the deployed InstallerBOM and sandbox profiles;
prebuilt `latest` images do not prove the upgrade works. A running sandbox is
retained when only its image reference changes, and an unchanged CLI image
reference can be skipped as already installed. Use new digest references and
explicitly recreate disposable sandboxes when changing their images. Check
persistence across that recreation; a VM restart alone is insufficient.

Run `.venv/bin/python -m pytest tests cli/tests -q` and `git diff --check`.
The discovery TypeScript configuration deliberately covers the discovery
entry point, dependencies, protocol tests, and bundle builder. It does not
compile upstream's separate managed startup entry point in the isolated build.
GitHub and OpenShift use the same configuration and reviewed dependency locks.

## Fresh cluster, Option A

1. Follow README Option A: log in, generate/reuse SSH keys, configure inference
   and Brave keys, mirror the golden VM image, and check OIDC CA trust.
2. Push the tested branch and run `TARGET_BRANCH=<branch> TARGET_ORIGIN=origin
   ./pattern.sh make install`. Record the exact deployed commit.
3. Wait for operators, Vault, ESO, Keycloak, governance, per-user applications,
   VM disks and VMs. Confirm Argo applications are Synced/Healthy or record each
   failure. Confirm both default/notebook and cuda-dev/cuda-sandbox exist.
4. Check guest installer status and actual extracted CLI source identity;
   inspect fallback messages. NemoClaw v0.0.132 still declares OpenShell
   0.0.116 as its maximum: a fallback to OpenClaw must be reported explicitly.
5. Log in as the workspace owner, configure the CLI, and authenticate the
   gateway. Check owner access and denial of a second user.
6. Launch TUI and GUI, send a unique chat message, and inspect the returned
   answer and session history. A route HTTP 200 alone is insufficient.
   Check both workspaces, inference route, TLS/OIDC, and restart recovery.

## Harness and agent tool calls

1. Enable `harnessEnabled: true` for the test user through saw-users; verify
   its openshell-saw application also sets `allowDriverConfig: true`. Harnesses
   require `type: openclaw`; do not add a harnessRef to `type: nemoclaw`.
   To exercise the upgraded runtime with the harness, use the new NemoClaw
   sandbox image for the default OpenClaw-type notebook in the test fixture.
2. Run `scripts/e2e-harness.sh --gateway <user> --workspace default`.
   Verify mount immutability, revision marker, skills, plugin loading,
   MCP registration, configuration, governance, and secret exclusion.
3. Ask the agent to call `saw_echo` with a unique marker. Inspect session tool
   events and require the plugin's `saw-echo: <marker>` result.
4. Ask the agent to discover and invoke the bundle MCP server's `mcp_echo`
   with another marker. Require a tool event and `saw-mcp-echo: <marker>`.
   Listing a plugin or repeating the marker in assistant prose is not proof.
5. Test an allowed remote/in-cluster MCP request if configured, and a denied
   destination. Record service/policy/TLS failures separately from tool loading.
6. On these disposable sandboxes run the harness disable/restore drill.
   Check plugin paths and mounts disappear/reappear and persisted user files
   survive. Repeat the tool calls after restoration and VM restart.

## Regression and rollback checks

Check repeated BOM apply is idempotent; provider credentials and owner grants
remain usable; web search, UI proxy ports, and governed egress still work.
Confirm the installed OpenShell version remains the pinned BOM version.
Keep old image digests before upgrade. For rollback, restore old CLI and
sandbox image pins, sync through Argo, and restart the VM as required by the
BOM installer. Capture sandbox recreation and persistence behavior explicitly.
Record PASS, FAIL, BLOCKED, or NOT RUN per case; include timestamp, commit,
cluster identity, image digests, and redacted diagnostic evidence.


## Live continuation, 2026-10-12

Validation is not an all-pass result. Existing uncommitted build-identity
changes are preserved on `codex/nemoclaw-latest-validation-20261012`.
The deployed Git commit is `684d8b95dcd1df4db15602a588db976ad5ebbbec`;
the corrected CLI build also includes the uncommitted version-stamping fix.
The dedicated cluster API is
`https://api.cluster-fx7lm.dyn.redhatworkshops.io:6443`.

Exact image identities:

- Corrected CLI: `sha256:a1db39a3228e8f285300ee46b17b2e0be085b74ea002d5ba96c826e379fdb35d`.
- Upgraded sandbox: `sha256:4424fe33334ba8ad7f052c2bd339a156e8bd07f265551c1e0e55443ddc8ad834`.
- Discovery build: `sha256:6b5aeb13c5a82ce51384a6f94253ef3d78c17619cb6f0b52f276cffa52c737f4`.
- Rollback CLI: `ghcr.io/validatedpatterns-sandbox/nemoclaw-cli@sha256:ff70fdedeb94282282f297276609b00fff4d0888b51d23a9f83c2ff6233b8e45`.
- Rollback sandbox: `ghcr.io/validatedpatterns-sandbox/nemoclaw-sandbox@sha256:e7349d73cbb7576815137762f83942a15f6affb7f6003dac5f6d117a7793a1cf`.

Recorded results before final return from rollback:

- PASS: corrected CLI installed in the VM; `dist/build-identity.json` reports
  `0.0.132` and `95d6505265ba1f2cb05355f83786353e654de096`.
- PASS: host regression suite, 1,168 tests in 501.34 seconds. The restricted
  sandbox run could not create sockets and is not product-failure evidence.
- PASS: stable read-only harness E2E, with two explicit skips: standalone
  MCP-process readiness and OCI signatures for the inline ConfigMap bundle.
  Audit revision, immutable mount, plugin/bundle loading, configuration,
  secret exclusion, and VM volume labels were checked.
- PASS: upgraded TUI reply `SAW_TUI_132_RESUME_1012`; CUDA agent reply
  `SAW_CUDA_132_RESUME_1012`; MCP call returned
  `saw-mcp-echo: SAW_MCP_132_RESUME_1012`, with recorded tool names and zero
  tool failures.
- FAIL: native `saw_echo` was unavailable on the upgraded OpenClaw 2026.9.2
  sandbox despite a loaded plugin. It subsequently worked on the baseline
  AIPCC image after Argo reverted the test fixture. The baseline success
  does not count as upgraded-image validation.
- PASS: harness-disabled notebook was recreated without `/sandbox/harness`
  and without its plugin load paths. Harness mount and paths reappeared on
  restoration. Argo's baseline-image reversion must be excluded from the
  final upgraded-image restoration checks.
- FAIL: notebook `/sandbox/persist/resume-probe` was lost during harness
  recreation. CUDA's marker survived a VM-only restart, then was lost on
  sandbox deletion/recreation during rollback. Recreation persistence is
  therefore not demonstrated and must not be advertised as passing.
- PASS: rollback extracted the cached pre-upgrade CLI and ran the exact old
  CUDA image (OpenClaw 2026.7.1). Real inference returned `SAW_ROLLBACK_1012`.
- PASS: allowed NVIDIA endpoint returned HTTP 200; `example.com` could not
  connect and is absent from the active CUDA policy. This does not by itself
  identify the exact blocking network layer.
- PASS: discovery build's high-severity audit gate, registry
  signatures (98 packages), three HTTP protocol tests, TypeScript, and bundle
  generation completed. Audit reports three moderate vulnerable packages
  (`hono`, `ip-address`, `qs`); this is not a zero-vulnerability result.
- BLOCKED: fresh non-admin developer denial test and credential-bearing
  Brave search test. Automatic approval review rejected the credential use;
  explicit approval is pending. Earlier developer denial results are
  historical evidence only. Bob has `openshell-admin` and is not a valid
  non-admin denial-test identity.
- NOT RUN: remote/in-cluster bundle MCP request; this test harness declares
  only a stdio MCP server.

Final upgraded-image restoration and repeated BOM application completed.
The corrected CLI and both actual sandbox containers were verified by digest
after rollback; OpenShell remains `0.1.2-rhaiv.0`. The scoped test BOM image overrides deliberately pause
`saw-alice-bom` self-healing; its OutOfSync state is expected fixture drift,
not a claim that all Argo applications are Synced.


Final checks on the restored upgraded image:

- PASS: both containers run sandbox digest `4424fe33...`; notebook and CUDA
  report OpenClaw 2026.9.2. Install/apply service status is Done.
- PASS: GUI chat returned `SAW_GUI_FINAL_132_1012` at
  `2026-10-12T20:45:45+03:00`; authenticated CUDA GUI displayed the matching
  session reply `SAW_CUDA_FINAL_132_1012` from `20:40:04+03:00`.
- PASS: restored harness E2E; same two explicit skips. Final MCP invocation
  returned `saw-mcp-echo: SAW_MCP_FINAL_132_1012`; receipt lists the MCP tool
  and zero tool failures.
- FAIL: final native-plugin test again reports `saw_echo` unavailable. The
  loaded plugin's inspection shows no registered tools and an unverified
  provenance warning. Do not count the separate MCP tool as its replacement.
- PASS: repeated identical BOM install and apply completed at
  `2026-10-12T20:47:12+03:00`, skipped unchanged component images, retained
  both sandbox IDs (`fed52d3b-5bde-4430-bcf3-ce2fda0cb935` and
  `d425e67b-1112-4b67-bdf6-2ce1ee911641`), retained a user-file probe, and
  retained GUI/native-test/MCP session history.
- Resolved test setup failure: the two-hour registry pull token expired
  during rollback. Renewing the existing service account's short-lived
  credential restored the authenticated pull and corrected CLI installation.
  No anonymous registry access or new permission grants were introduced.
- Observed GUI reload timeouts recovered in a fresh browser tab. VM-local
  UI and forwarding returned HTTP 200; final browser chat succeeded.
- All Argo applications are Healthy; `saw-alice-bom` and its `saw-users`
  parent are OutOfSync because the scoped sandbox-image fixture is retained.
- Fresh developer denial and Brave search remain BLOCKED pending the
  requested credential-use approval. Notebook recreation was explicitly
  authorized and completed. Remote/in-cluster MCP remains NOT RUN for this
  stdio-only fixture.

GUI screenshot evidence is saved locally at
`/home/lbitan/.codex/visualizations/2026/10/12/01a1310e-b092-75c0-815d-f66ef5887b44/nemoclaw-gui-final.png`.

Final evidence recorded at 2026-10-12T20:50:15+03:00.

Final MCP session history was expanded in the owner GUI: tool
`saw-mcp-echo__mcp_echo`, argument `SAW_MCP_FINAL_132_1012`, result
`saw-mcp-echo: SAW_MCP_FINAL_132_1012`, status Completed. This is a real
tool event, not only an assistant echo.

FAIL: native NemoClaw onboarding still fails `gateway.port.uncontested`
(the already-running OpenShell gateway occupies the port). The installer
continues with plain OpenClaw sandbox creation. The installed blueprint
also declares a maximum OpenShell version of `0.0.116`, below the actual
`0.1.2-rhaiv.0` BOM pin. Successful fallback chat is not native onboarding
success.


## Pairing prompt investigation

On 2026-10-12, the newest upstream tag was checked through GitHub's tags
API and remained `v0.0.132`.

The reported screenshots show Carol's default notebook connected while the
CUDA/NemoClaw UI requests device pairing. They come from a separate cluster
(`cluster-bcvkh`); its installed versions have not been inspected here.

The cached pre-upgrade NemoClaw sandbox reproduces the relevant version
incompatibility: its OpenClaw 2026.7.1 rejects the trusted proxy's
`deviceAutoApprove` setting. The rollback guest log at
`2026-10-12T20:30:09+03:00` records the installer warning that it is retrying
without that setting. This explains why a newer default notebook and an
older NemoClaw sandbox can present different authentication behavior.

The upgraded sandbox digest recorded above runs OpenClaw 2026.9.2.
Its live CUDA config was inspected and reports `gateway.auth.mode` as
`trusted-proxy`, `userHeader` as `x-forwarded-email`, `allowUsers` restricted
to Alice, loopback forwarding enabled, and `deviceAutoApprove.enabled=true`.
Both owner-authenticated GUIs were usable without manually approving a
browser pairing request. CUDA session history showed its real inference
reply, and notebook GUI chat produced the final marker recorded above.
This pairing symptom is therefore resolved by the upgraded image in the
dedicated test deployment, despite the separate native-plugin and
persistence failures.

A redeploy of repository main alone does not establish that the upgrade was
loaded: the shipped CUDA profile still references the public `:latest`
image, and changing an image reference retains an existing sandbox.
For another deployment, publish/select the tested new CLI and sandbox
images by immutable digest, preserve the owner-only OIDC/trusted-proxy
settings, verify the actual running OpenClaw version, and recreate the
sandbox with explicit authorization and a backup/export of needed files.
Then test a fresh browser session and a real chat reply. Carol's deployment
is not claimed fixed until those checks are performed there.


## Full-test follow-up

The native plugin failure was isolated to tool policy and stale gateway
configuration, rather than a broken native plugin. On this NemoClaw image,
the coding profile had `tools.alsoAllow=["bundle-mcp"]`; adding the exact
harmless native tool name gives `["bundle-mcp", "saw_echo"]`. Gateway reload
is disabled, so the gateway must be restarted before evaluating the new
policy. Do not grant all plugins or change owner authentication to test this.

PASS: after the explicit allowance and confirmed gateway readiness, the
agent invoked native `saw_echo` with `SAW_NATIVE_RELOADED_READY_132_1012`
and returned `saw-echo: SAW_NATIVE_RELOADED_READY_132_1012`. Its receipt
records `saw_echo` and `tool_call`, two calls and zero failures. The previous
native-tool failures describe the original policy, not this corrected test
configuration. CLI metadata-only plugin inspection does not prove runtime
registration; `plugins inspect saw-echo --runtime --json` reports the native
`saw_echo` registration.

The persistence failure is confirmed at the storage layer: `/sandbox/persist`
has no independent mount. It is inside
`openshell-sandbox-<sandbox-id>-workspace`, and the old workspace volume is
removed by OpenShell sandbox deletion. The installer comment claiming its
retention was corrected; no data-preservation implementation is claimed.
VM restart and repeated apply can retain files, while delete/recreate cannot
meet the preservation acceptance criterion without separate persistent
storage or an explicit backup/restore workflow.

PASS: a repeated live BOM apply retained the explicit native-tool allowance
and the existing persistence probe. Fresh CUDA inference returned
`SAW_CUDA_FULL_132_1012`.

PASS: the follow-up installer and NemoClaw image-build regression run completed
with **460 passed in 329.66 seconds**. The earlier complete regression run
remains **1,168 passed**.

UNRESOLVED: the additional VM restart readiness check timed out. At the last
inspection both installer/apply services were activating and the installer
was retrying gateway startup. This restart is not recorded as passing;
post-restart native/MCP calls and the new persistence probe still need checks.

BLOCKED: automatic approval review requires explicit authorization for the
developer-account cross-workspace denial test and transmission of the
configured Brave API key to its search API. Neither check is claimed passed.

## Pre-upgrade pairing reproduction

On 2026-10-12 at approximately 22:36 Asia/Jerusalem, the reported difference
was reproduced on `cluster-fx7lm` using isolated disposable containers in
Alice's VM, without replacing the existing sandboxes:

- Old NemoClaw: exact rollback sandbox digest `e7349d73...`, OpenClaw
  **2026.7.1** (`2d2ddc4`).
- Default notebook: `quay.io/aipcc/base-images/agentic/openclaw@sha256:896d1526ee29b53167034ba65d1c758c8da777f441ed094e19f3bcf6d7445c61`,
  OpenClaw **2026.9.6** (`eb377ac`).

Both gateways used loopback-only listeners, the same trusted-proxy owner
`alice`, and the same requested operator scopes. A WebSocket client sent
the Control UI's `openclaw-control-ui` / `webchat` connection handshake,
including a newly generated Ed25519 device and a signed challenge. Every
trial used a fresh device; no pending device was manually approved.

CONFIRMED: the old image rejects the full `deviceAutoApprove` configuration
with `gateway.auth.trustedProxy: Invalid input`. Removing only that key,
as the installer fallback does, makes the configuration valid. The default
notebook accepts the full configuration.

CONFIRMED: the old NemoClaw gateway repeatedly returns `ok=false`,
`error.code=NOT_PAIRED`, `details.code=PAIRING_REQUIRED`, and
`pairing required: device is not approved yet`. The default notebook returns
`ok=true`, `hello-ok`, and the requested operator scopes. This reproduces
the gateway error responsible for the screenshot's pairing screen.

CONFIRMED control: removing automatic device approval from the default
notebook makes its fresh-device connection return the same `NOT_PAIRED` /
`PAIRING_REQUIRED` error. Restoring the owner-scoped setting and restarting
its gateway restores `hello-ok` for another fresh device. This isolates
automatic device approval as the decisive configuration difference.

The old isolated image also required initialization of its shipped empty
legacy `exec-approvals.json` before its startup migration would complete.
Only the disposable container's file was initialized; existing sandbox
files were untouched. Connection refusals and `gateway starting` responses
during setup are excluded from the pairing result.

Scope: this is a real gateway protocol reproduction on the cluster VM,
with the proxy's owner headers supplied by the test client. It does not
retest the browser rendering, OIDC ingress chain, or LLM inference. Earlier
live upgraded GUI/inference evidence remains separate. Carol's
`cluster-bcvkh` was not accessed.

The existing VM's rootless Podman database now reports corruption:
`PRAGMA integrity_check` finds an overflow-list error and a wrong entry
count in `sqlite_autoindex_ContainerState_1`; `podman` reports
`database disk image is malformed`. Installer/apply services are failed.
This explains the outstanding restart readiness failure; no container-store
reset or data-loss repair was performed, and its cause is not established.

## Fresh-cluster validation — 2026-10-13

Deployed through README Option A (`./pattern.sh make install`) on
`cluster-vqvlk`, OpenShift 4.22.16. Tested source commit
`951afdf6743bb054277937cb469b2350edda724e` pins NemoClaw v0.0.133 to
`ef5d55d19e2da33c2474db158588613828e1a9be`. OpenShell remains
0.1.2-rhaiv.0. All image builds completed; installed build identity matches
the pin. The application's public wildcard certificate passed the OIDC CA
check. Workshop API access used its insecure TLS option.

### Passed

- Full regression suite: **1,168 passed in 474.44 seconds**. The focused
  image-build checks also passed (11 tests).
- Alice signed in through the actual owner OIDC flow. The CUDA browser chat
  returned `SAW_FRESH_CUDA_133_1013`; CLI inference returned
  `SAW_FRESH_CUDA_CLI_133_1013`. The default notebook browser initially
  returned `SAW_FRESH_NOTEBOOK_1013`.
- Controlled v0.0.132 and v0.0.133 harness sandboxes both invoked native
  `saw_echo` and stdio MCP echo successfully. Clean final chat histories
  contained the expected tool results and zero tool errors. Both used
  OpenClaw 2026.9.2, NVIDIA inference, and the same `ds-default` bundle
  digest `sha256:d4ec9daaf232b0ac5256f6f3e196f908eda2a47b5cc5914ec9d2174f0e084f01`.
  The exact harmless native tool was explicitly allowed in both isolated
  test configurations. Requests discovered tools before invoking them.
- Read-only harness E2E passed on both versions, and again on v0.0.133
  after restart. Each run skipped standalone MCP readiness inspection and
  OCI signature inspection for the inline ConfigMap bundle; real MCP calls
  separately verified the tested stdio path.
- Repeated installer/apply runs retained all four sandbox IDs and data.
  A normal KubeVirt restart retained CUDA, notebook, and both harness IDs,
  persistent marker files, owner configuration, and browser chat history.
  Podman SQLite integrity was `ok` before and after restart.
- After restart, actual native and MCP calls returned
  `SAW_NATIVE_POST_RESTART_133_1013` and
  `SAW_MCP_POST_RESTART_133_1013`. A new CUDA browser request returned
  `SAW_CUDA_POST_RESTART_133_1013`.
- Interactive CUDA TUI inference passed using the already configured
  gateway password, returning `SAW_TUI_PASSWORD_133_1013`. The initial
  device-token attempt failed with a scope mismatch; that authentication
  path is not counted as passing.

### Limits and unresolved failures

This is **not an all-pass qualification**. Native NemoClaw onboarding still
fails `gateway.port.uncontested` and uses the existing plain OpenClaw
fallback. The v0.0.133 blueprint declares a maximum OpenShell version of
0.0.116, while this deployment uses 0.1.2-rhaiv.0.

The default notebook browser worked before restart, but subsequent browser
reloads timed out or displayed HTTP 504. Its guest backend, limiter, and
forwarder returned HTTP 200 and its services were active. A scoped
forwarder restart was attempted; browser recovery was not verified.
The cause remains unresolved. CUDA browser recovery was verified.

Normal restart preservation does not resolve or prove sandbox
delete/recreate preservation. No destructive persistence drill was run.
Non-admin cross-workspace denial and configured Brave-key checks remain
blocked pending the explicit authorization requested earlier. Other hosted
providers and remote MCP transports were not qualified. Discovery audit
reported three moderately vulnerable packages (`hono`, `ip-address`, `qs`);
CLI runtime audit reported two moderate findings.

### Version comparison and retained state

The upstream v0.0.132-to-v0.0.133 delta contains 29 commits. The
[official v0.0.133 changelog](https://github.com/NVIDIA/NemoClaw/blob/v0.0.133/docs/changelog/2026-10-12.mdx)
describes additional hosted providers, local provider tool disclosure,
gateway port recovery, and several compatibility/cleanup fixes. The tested
NVIDIA inference, native tool, and stdio MCP paths passed on both versions;
this does not qualify every new provider or recovery path. All 14 discovery
runtime files have identical Git blob hashes across these two tags.

Retained images on the fresh cluster:

- v0.0.133 CLI: `sha256:ee41714463f18cf9885ec1486a03415109e973fd30f03e930b2c6a5df83a11a9`
- v0.0.133 discovery: `sha256:b3bcafad794ae4725f87064c9017b2e709d6f6be0e0ce4daad300fb3f6e57c8d`
- v0.0.133 sandbox: `sha256:e03b64eb98c184a1e3721fd6a42bee6a8ec67ded4de92c5117a777ea88df23a2`
- v0.0.132 baseline sandbox: `sha256:342fb754dffd2b5b3859b8f55254e174679cbc432abea6aa64b43efa68506d3b`

Fresh VM `saw-alice/alice` and all four test sandboxes remain available.
Retained snapshot `saw-alice/alice-nemoclaw-133-pre-restart` is Succeeded and
ready to use, with deletion policy Retain and the root disk included. The
initial fresh CUDA data/configuration were archived before loading the
pinned image. The old cluster's original store and recovery archives remain
untouched; its corrupted database was not repaired or reset.

The fresh deployment intentionally retains scoped test fixture drift:
`saw-users` automated sync is disabled and `saw-alice-bom` automated sync is
paused. These applications were Healthy with expected OutOfSync status.
The default notebook continues to use its original AIPCC OpenClaw 2026.9.6
image; the additional v0.0.132/v0.0.133 harness sandboxes carry the comparison.
Restore automatic reconciliation only when the fixtures are no longer needed.

Evidence receipts are retained under `/tmp/nemoclaw-fresh-*`, including
native/MCP histories, post-restart histories, and TUI history. Browser proof
is saved at
`/home/lbitan/.codex/visualizations/2026/10/13/01a13436-9153-7312-84f7-b9a27b83cbea/nemoclaw-fresh-cuda-post-restart.jpg`.
Generated kubeconfigs and values files remain private and gitignored;
credentials are excluded from this record.

### Notebook recovery follow-up — 2026-10-13, 12:48 Israel time

**Tracking item: NOTEBOOK-504 — OPEN (recovered; intermittent failure still
under investigation).** GitHub Issues is disabled for this repository, so
this record is the tracking location. Native NemoClaw onboarding is a
separate deferred item.

Remaining investigation: reproduce the authenticated browser stall after
a normal VM restart, capture correlated proxy/relay/forwarder/backend logs
before restarting any service, and identify which upstream connection
stops responding. Close this item only after the cause is established,
the necessary fix is verified, and browser chat/reload succeeds after a
normal restart without manual forwarding-service recovery. Preserve all
sandbox data throughout.

The owner notebook browser is now recovered. A fresh browser navigation
loaded the retained chat, a new request returned
`SAW_NOTEBOOK_RECOVERED_1013`, and an explicit page reload retained both the
old and new replies. Authenticated proxy logs confirmed successful asset
and configuration responses. No additional service restart, sandbox reset,
or authentication change was made during this follow-up.

The earlier scoped restart of `saw-ui-forward-default-notebook.service`
occurred at 12:34:34 Israel time. Recovery was first verified afterwards;
that association does not establish causation. During the original failure,
oauth2-proxy logged `net/http: timeout awaiting response headers` and the
connection relay logged unanswered asset/service-worker requests. This
places the observed failure in the proxy's upstream response path, rather
than showing lost sandbox data or a failed owner login. The precise cause
of the intermittent stall, and a durable prevention fix, remain unproven.

Browser evidence:
`/home/lbitan/.codex/visualizations/2026/10/13/01a13436-9153-7312-84f7-b9a27b83cbea/nemoclaw-notebook-recovered.png`.

### Carol owner pairing test — 2026-10-13

Added a separate chart-rendered Carol test deployment on `cluster-vqvlk`,
using this validation branch and the same pinned v0.0.133 CLI/CUDA images.
Alice's resources and sandbox data were not modified. Carol's BOM app has
automatic sync paused to retain the pinned test ConfigMap; the Carol-only
rendered manifests remain in `/tmp/nemo-carol-apps.yaml` and
`/tmp/nemo-carol-bom.yaml`. These are additional validation fixtures, not a
change to the default GitOps user list.

The initial HTTP 503 was traced to `authentication required` when Carol's
installer pulled the private cluster-registry CLI image. After installing
temporary registry pull authentication and resuming only Carol's failed
installer/apply services, both completed successfully. Native onboarding
used the already documented fallback.

Created Carol's `openshell-user` account and authorized the existing
workstation SSH key after explicit user authorization. Existing users and
passwords were preserved. An initial browser attempt reused Alice's SSO
identity and received HTTP 403; switching the test sign-in to Carol then
opened her CUDA chat without any manual device approval or
`Device pairing required` error. Actual inference returned
`SAW_CAROL_PAIRING_OK_133_1013` at 13:56:17 Israel time. Owner authentication
was `trusted-proxy`, restricted to `carol`, with device auto-approval enabled
for the same four configured owner scopes as Alice.

An explicit browser reload retained the successful reply and did not show
a pairing prompt. Screenshot evidence is saved at
`/home/lbitan/.codex/visualizations/2026/10/13/01a13436-9153-7312-84f7-b9a27b83cbea/carol-pairing-passed.png`.

This qualifies Carol on the validation branch in `cluster-vqvlk`; it does
not qualify the manager's `main` deployment in `cluster-bcvkh`.

### PR #98 live reproduction — 2026-10-13

Reviewed upstream PR #98 at exact head
`93fc557ea38c4697bdd016f1815d635e6e4cbb17`. Its plugin-enable changes are
absent from this deployment's normal installer. Upstream's three CI checks
passed; isolated local tests on that exact source passed (60 harness
contract tests and 38 apply-profile tests). These results are separate from
the earlier 1,168-test upgrade suite.

Created an additional `default/pr98-repro` sandbox using the existing
v0.0.133 image and unchanged `ds-default` harness. Existing Alice/Carol
sandboxes were excluded from the reproduction plan, pruning was disabled,
and the production installer was not replaced.

**Fresh baseline without PR #98:** verification passed. Both `ds-default`
and `saw-echo` were enabled and loaded. The fresh v0.0.133 configuration had
no `plugins.allow` restriction. Thus this fresh-image case did not
reproduce the reported problem; saying every fresh 2026.9.x harness needs
this PR was too broad.

**Controlled compatibility case:** set only the reproduction sandbox's
`plugins.allow` to `["brave", "memory-core", "nemoclaw"]`, the restrictive
configuration described in the PR. Running the current installer's
unchanged harness setup then produced disabled `ds-default` and `saw-echo`
plugins and the actual verification failure:
`OpenClaw does not load the harness bundle 'ds-default' from /sandbox/harness`.
This is an intentionally seeded configuration, not a spontaneous failure
of the fresh image or a reproduction of the manager's whole deployment.

**Exact PR implementation on the same sandbox:** ran the PR's
`configure_harness` implementation, including
`openclaw plugins enable <id> --accept-capabilities` and its plain-command
fallback. Both commands for both plugins returned
`Plugin "<id>" could not be enabled (blocked by allowlist).`
Verification still failed, now with the PR's additional `status disabled`
diagnostic. The runtime identified itself as
`OpenClaw 2026.9.2 (3928bad)`.

**Review outcome:** do not approve PR #98 as a complete fix for the
restrictive-allowlist case based on the earlier passing tests. Its claim
that enable automatically adds a plugin to an existing allowlist did not
hold on this tested runtime. It needs a fix that retains existing allowed
IDs while admitting the intended harness IDs, plus a regression test for
this case. Capability consent on other runtimes remains a separate path.
No PR comment, review submission, merge, or product-code change was made.

The isolated failed configuration is retained for inspection. VM receipts:
`/home/cloud-user/pr98-repro-apply.json`,
`/home/cloud-user/pr98-disabled-plugins.json`,
`/home/cloud-user/pr98-repro-legacy-policy.json`,
`/home/cloud-user/pr98-repro-fix.json`, and the corresponding
`pr98-repro-apply.log`, `pr98-legacy-policy.log`, `pr98-fixed.log`.
The bounded driver is `/tmp/pr98-live-repro.py` on the workstation and
`/home/cloud-user/pr98-live-repro.py` on Alice's VM.

### Full PR #98 integration on the latest-version branch — 2026-10-13

At the user's request, cherry-picked the complete PR head
`93fc557ea38c4697bdd016f1815d635e6e4cbb17` into
`fix/nemoclaw-upgrade-validation` as **`75de2bd`**, preserving the
v0.0.133 image pins. Both changed files integrated without conflicts.
Fresh combined-branch checks passed: **176 tests** across apply profiles,
harness contracts, and harness mounting in 186.72 seconds. This was a
targeted integration check, not another full 1,168-test suite run.

Pushed the combined branch and refreshed Alice's GitOps application. The
deployed `alice-installer` ConfigMap and the guest's verified
`/var/lib/saw/verified/installer/apply_bom.py` both match the combined
source hash:
`a690f261144a7b1ced4784813f629a62406ee5b0feb38745433936ac69b55d75`.
This supersedes the earlier narrower test that staged the PR installer as
a separate file.

Before normal restart, created retained VM snapshot
`saw-alice/alice-pr98-pre-integration` and verified it Succeeded and ready
to use. Normal restart loaded the updated installer disk. The full normal
install/apply sequence finished successfully at **15:02:22 Israel time**,
including actual PR plugin-enable commands and
`PASS all workspaces, providers and sandboxes present`.
All five Alice sandbox/container IDs remained unchanged, and the CUDA,
notebook, and latest harness persistent markers matched their earlier
values. Carol's running VM was not restarted for this integration check.

Repeated the controlled restrictive-allowlist test in `default/pr98-repro`
using the **installed combined-branch installer**, rather than the
separately staged PR file. Both enable commands and their fallbacks still
returned `could not be enabled (blocked by allowlist)`; harness verification
still failed with `status disabled`. Guest evidence is
`/home/cloud-user/pr98-integrated-repro.log` and
`/home/cloud-user/pr98-repro-legacy-policy.json`.

Result: the complete PR is now on the latest-version testing branch and
normal profile apply passes, but the intentionally restrictive allowlist
case remains failing on OpenClaw 2026.9.2. Full integration did not remove
the earlier observed limitation. No upstream approval, merge, or review
comment was submitted, and no data-reset or sandbox-delete operation was
performed.
