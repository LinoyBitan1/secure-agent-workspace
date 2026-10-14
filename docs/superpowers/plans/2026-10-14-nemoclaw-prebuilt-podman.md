# Native NemoClaw prebuilt Podman integration

**Goal:** Onboard a digest-pinned downstream sandbox image through NemoClaw on the rootless Podman gateway, without direct OpenShell/OpenClaw fallback.

**Approach:** Keep the gateway externally supervised by systemd. Use the upstream `--from-image` contract and native Podman provider. Preserve provider credentials in mounted Secrets and preserve existing sandbox data. Resolve workspace and gateway registration behavior using the real upstream CLI before claiming end-to-end support.

## Constraints

- Keep the default Podman gateway image and OpenShell 0.1.2.
- Do not install Docker or substitute direct sandbox creation for successful onboarding.
- Do not treat an existing Ready fallback sandbox as a registered NemoClaw sandbox.
- Keep image validation, ownership checks, and lifecycle authority checks enabled.
- Do not include unrelated portal or deployment cleanup changes.

## Execution

- [ ] Test upstream native onboarding using a disposable CLI copy with the existing downstream version setting, an immutable image digest, and an unused sandbox name.
- [ ] Add failing installer tests for digest validation, Podman runtime/socket propagation, native command arguments, failure without fallback, and registration-aware reuse.
- [ ] Update `apply_bom.py` to use the native path and leave agent setup/lifecycle to NemoClaw.
- [ ] Preserve CI tags in the shipped profiles, resolve their digests at onboarding, and include `lsof` in both gateway image build recipes.
- [ ] Resolve non-default workspace support and managed-volume admission based on the live test; preserve existing state during migration.
- [ ] Run focused installer/chart tests and validate onboarding, Ready, registration, connect, state-volume provisioning, and lifecycle on the supplied cluster.
- [ ] Record any remaining failure precisely; do not report native support from a fake test or fallback sandbox.

Tests and live onboarding are paused pending user approval. Source review shows
that some upstream lifecycle paths still hardcode the `default` workspace;
forwarding `OPENSHELL_WORKSPACE` alone does not prove `cuda-dev` lifecycle support.
The OpenShell 0.1.2 managed-volume admission and inference integration also need
live qualification before this branch can be described as complete.
