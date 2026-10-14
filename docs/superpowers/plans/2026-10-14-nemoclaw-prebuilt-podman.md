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

## Live qualification: cluster-sm9bk, 2026-10-14

Testing was approved by the user. ArgoCD restored Alice and delivered the
installer through the existing Option A path. A separate `nc-native-probe`
sandbox name in `default` preserved the existing `notebook` and `cuda-sandbox`.
Both existing sandboxes were verified Ready after the VM restarts.

- `:latest` resolves through `/run/user/1000/podman/podman.sock` to
  `ghcr.io/validatedpatterns-sandbox/nemoclaw-sandbox@sha256:b821b26f857a5f56582757e20e93ba9676b25490a35c2a3e47741cdb9e3fe2fb`.
- The CLI was rebuilt with the repository's BuildConfig and
  `maxOpenshellVersion: 0.1.2`. Built image:
  `image-registry.openshift-image-registry.svc:5000/saw-native-build/nemoclaw-cli@sha256:e3e24bfe3e917565414a949c06ee313b9d47387f078c6f6b9499779e7a4c959f`.
  The verified extracted CLI was used only for the isolated probe; the published
  `nemoclaw-cli:latest` image was not replaced.
- Native Podman preflight and attachment to the externally supervised gateway passed.
  Alpine pull/DNS probes timed out and were reported as inconclusive by NemoClaw.
- Fixed cached gateway identity: upstream reuses `nemoclaw-17670`; the installer
  now refreshes that registration with its admin mTLS certificate.
- Published NemoClaw's exact checked-in NVIDIA profile through governance.
  Profile validation passed after the interceptor catalog exposed it.
- Remaining failure at step 4: `Could not activate native NVIDIA provider policy:
  OpenShell did not return the global provider policy setting.`
  NemoClaw's `provider-adapter-cli.ts` reads `settings.providers_v2_enabled`;
  the actual OpenShell 0.1.2 global response has no such key.
- No native sandbox or managed state volume was created. Native Ready, connect,
  managed-volume admission and lifecycle were not reached. Non-default workspace
  support remains unverified; some upstream lifecycle paths hardcode `default`.
- Installer regression suite: **467 passed** after the admin-registration fix.
  Provider profile/firewall parity checks: **7 passed** after profile publication.
  Relevant chart checks had 123 passes and one failure caused by the intentional
  Alice test entry (the chart test asserts the user override is empty).

The automatic apply service was paused during the isolated probe to prevent
competing onboarding sessions. The gateway and existing sandbox services remain
running. The temporary archive-serving pod was removed; the CLI build is retained
in `saw-native-build` for inspection.

Next work is version-aware native provider policy activation for OpenShell 0.1.x.
The missing flag must not be treated as proof that policy is disabled or simply
ignored. Validate the gateway's provider composition semantics before changing
the upstream adapter, then qualify the remaining native lifecycle boundaries.
