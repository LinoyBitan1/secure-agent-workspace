# PR78 cluster validation — 2026-10-08

Deployment branch: `codex/pr78-cluster-validation-20261008` in the LinoyBitan1 fork.

The workshop cluster already contained an Option A deployment and Alice's running VM. Validation reuses its GitOps, Virtualization, Vault and Keycloak operators, with an isolated Option A application tree, VM `pr78` in `saw-pr78`, and governance/image build in `pr78-build`. This validates fresh VM provisioning and Argo reconciliation; it does not repeat operator bootstrap on an empty cluster. Existing Alice and shared application sources were preserved.

## Evidence

- OpenShift 4.22.15; Kubernetes v1.35.6. Fresh VM provisioned from the existing golden-image source. Install completed with BOM `openshell-0-1-2-rhaiv-0`.
- OpenShift BuildConfig `pr78-build/governance-interceptor-2` completed. All six embedded Rust guard tests passed, the locked release binary compiled, and the UBI runtime image assembled and pushed.
- Interceptor image digest: `sha256:b50a0850489d982e88e8d9477245f605bba45b72d269eb667b66461913140088`.
- Completed baseline apply: notebook audit digest `d4ec9daaf232b0ac5256f6f3e196f908eda2a47b5cc5914ec9d2174f0e084f01`. Mount read-only; writes refused; mounted bundle, native plugin and declared MCP registration verified. Registration inspection does not establish process readiness.
- Real OIDC `admin` token carried both `openshell-user` and `openshell-admin`. `CreateSandbox` denied its installer-shaped volume and all five invalid mount cases. Installer mTLS denied bind/root, bind/TLS-directory, wrong target, wrong source and writable mounts: eleven live denial cases passed.
- A live template probe showed that storing driver config did not invoke the interceptor. Resource admission still rejected the bind-template launch in this deployment. Adding its RPC to the gateway allowlist then proved that OpenShell 0.1.2 rejects it as non-interceptable; upstream routes confirm that restriction. The final guard refuses nonempty `workloadTemplate`/`workload_template` at `CreateSandbox` before resolution, and omits the unsupported binding. Templates can be stored but cannot be used to create sandboxes with this guard. Both full upstream compilation and independent review passed. Probe templates are cleaned up.
- Live volume-label inspection confirmed `openshell.ai/sandbox-attachable=true`, workspace `default`, and `saw.redhat.com/harness-volume=true`. Fixed H8's literal volume wildcard.
- Argo H9 disabled the harness and completed apply with empty `appliedRevision`. OpenClaw returned its documented nonzero valid-but-unset config response, exposing a polling bug. Fixed that specific response handling while retaining failure behavior for connection errors; 20 script regression tests passed.
- Interrupted the initial drill with SIGTERM. Its restoration trap restored harness enablement and parent/child `selfHeal=true`; VM harness restoration verification completed; the interrupted script exited with the expected status 143.
- Real host-side keyless verification passed for `ghcr.io/validatedpatterns-sandbox/saw-harness-ds-default@sha256:7a594688a2e9e64054ef5ff7c342a045766c968822567c292ab47cd17b12a7af`, signed by the repository's `harness-bundles.yml@refs/heads/main` workflow.

## Live outcomes

- Final image runtime verified by digest. All thirteen direct/template denial cases passed with real mTLS and OIDC principals.
- Final H1–H8 passed against the signed bundle: mounted audit, registration, read-only refusal, real cosign and admission labels. The script explicitly skips process readiness, which was separately exercised for the sample server. H9 passed both disable and restore phases; the final script exited zero with one explicit process-readiness skip. Parent/child Helm parameters and complete Argo sync policies exactly matched the pre-drill snapshot.
- Real image-sourced apply completed, pinned audit and harness volume populated. The mounted sample MCP process passed initialize, tools/list and tools/call; this additional probe does not change H3’s registration-only claim.
- Injected verifier outage with a fresh cache: complete apply passed, cache age 259s (maximum 300s), cosign was not invoked. Wrapper restored the real verifier on exit.
- Expired-cache/injected-outage apply returned the expected failure. The notebook was recreated from ID `6744bc54-14ef-41d6-b24c-eb677c71ee32` to `ccbd2838-3926-4b40-b58e-8ec886a05c6c` with no harness mounts. The real verifier was restored.
- Expired-cache refusal also removed the old image and volume; cleanup and real-verifier restoration passed. Trusted signed-image recovery completed.
- Actual signer-policy refusal used real cosign: certificate subject remained the main workflow, while copied inputs required a revoked workflow identity. Cosign reported an expected identity mismatch. Running notebook changed from `d864c023-b993-4051-9e85-a4ad9238643b` to `08057038-dbe6-478e-a7f1-b35b62030efc`, with no harness mount and no VM restart. This is a trust-policy rejection drill, not removal of the public signature.
- Final real trusted signed-image recovery completed with apply Done. Final H1–H9 passed on that recovered image, then restored the original GitOps inline bundle.
- VM/BOM/secrets/governance applications are Synced and Healthy. Existing Alice VMI remains Ready and Running (age 3d16h). Final baseline install and apply are Done; inline audit digest restored at 10:34:36 UTC. The isolated VM is left running for inspection.

- Latest focused harness/chart/script run: 115 passed, three of the previously reproduced gateway tests failed. Final independent focused review: 39 passed.
- The older workshop golden image lacks `cosign`; an existing v2.4.1 binary was copied onto this isolated VM for image tests.

## Existing offline limits

Earlier broader installer/chart run: 622 passed, 6 failed. Four gateway tests reproduced on the unchanged original PR head; the other two passed individually. These are not reported as a green full suite. Final full script suite: 134 passed, including the live-discovered regression cases. No live Helm-controller drill or PR68 firewall deployment is claimed.

Test-only `overrides/pr78-validation.yaml` is a separate commit and must not be transferred to the PR branch. Credentials and test client keys are stored outside the repository and omitted from this report.
