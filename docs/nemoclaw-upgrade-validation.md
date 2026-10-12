# NemoClaw upgrade acceptance test

Test on a fresh, dedicated OpenShift cluster using README Option A. Never store
cluster passwords, provider keys, tokens, or Keycloak passwords in evidence.

## Version and build checks

The upgrade pins both builds to NemoClaw `v0.0.132`, commit
`95d6505265ba1f2cb05355f83786353e654de096`, and its matching sandbox base.
Run `make cli-build` and `make sandbox-build`. Both must reach Complete; record
the output image digests. Discovery must pass npm audit, signature checks,
its HTTP protocol tests, TypeScript, and bundle generation in the cluster.
Use these new image digests in the deployed InstallerBOM and sandbox profiles;
prebuilt `latest` images do not prove the upgrade works.

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
   its openshell-saw application also sets `allowDriverConfig: true`.
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
