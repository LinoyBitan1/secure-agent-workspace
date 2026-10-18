# SAW 3.6 TP provider and driver validation

Tracking work: APPENG-6705, Determine support matrix for providers and drivers.

Status: test environment deployed; Codex sign-in is blocked before inference.
No combination has been live-validated in this work.
The parent spike link and live verification of provider configuration are pending.

## Scope and terminology

Validate OpenClaw in the single-VM SAW deployment using productized components.
The provider supplies inference; the OpenShell compute driver runs the sandbox.
Hosting the gateway VM on OpenShift does not validate the Kubernetes compute
driver. OpenClaw remains the agent for all four combinations.

Keep the requested label **Codex**. The upstream source distinguishes Codex
OAuth from direct OpenAI API-key access (see the source assessment below).
Use that distinction for validation; do not silently substitute an `openai`
API-key test for a Codex OAuth test. Record the actual OpenClaw model route,
runtime, and authentication method, rather than relying on the provider label.

NemoClaw, GPU passthrough, RHDH provisioning, governance interceptor validation,
and the two-VM Forge architecture are outside this validation scope.

## Validation matrix

These are test results for this spike, not a general product support statement.
**Validated** requires a successful live test and a linked evidence record.
**Failed** means a live test was attempted and failed. **Not tested** means no
qualifying live test has been recorded; it does not mean unsupported.

| Provider | Podman compute driver | Kubernetes compute driver |
| --- | --- | --- |
| Codex (primary) | **Not tested (blocked).** The shipped OpenClaw OAuth flow rejects OpenShell's synthetic DNS address before issuing a login code. See the [live attempt](#codex--podman-live-preparation-attempt). | **Not tested.** An upstream Kubernetes driver exists, but this SAW chart does not configure it. |
| Anthropic (secondary) | **Not tested.** Native provider onboarding and credentials still need validation. The OpenClaw/Podman environment is running. | **Not tested.** No Kubernetes compute-driver deployment path identified in the current chart. |

## Implementation findings

- The [gateway template](../charts/openshell-saw/templates/_helpers.tpl) sets
  `OPENSHELL_COMPUTE_DRIVER=podman`, `compute_driver = "podman"`, and a
  `[openshell.drivers.podman]` configuration. A Kubernetes driver is not exposed
  by this configuration.
- The [installer](../charts/openshell-saw/files/installer/apply_bom.py), in
  `PROVIDER_CRED_MAP`, recognizes `codex`/`openai` with `OPENAI_API_KEY` and
  `anthropic`/`claude-code` with `ANTHROPIC_API_KEY`. Recognition alone is not
  end-to-end validation.
- The installer's `NATIVE_BASE_URLS` includes `openai`, `nvidia`, and `build`,
  but not `codex` or `anthropic`. `start_openclaw()` skips onboarding when no
  endpoint is known and passes `--custom-compatibility openai` when onboarding.
  Native Anthropic compatibility therefore needs investigation.
- The [fallback provider profiles](../charts/openshell-saw/files/provider-profiles/)
  contain `openai`, `nvidia`, and `brave`; they do not contain `codex` or
  `anthropic`. The default
  [OpenClaw sandbox](../charts/saw-bom/profiles/data-science/default/sandbox.yaml)
  attaches NVIDIA, so an unchanged default install does not validate either
  requested provider.
- The [custom-endpoint tests](../tests/installer/test_custom_endpoint.py) use a
  fake environment. They exercise OpenAI-compatible onboarding, not live
  provider inference.

## Upstream source assessment

Inspected OpenShell v0.1.2 examples, the OpenClaw v2026.9.6 documentation
matching the sandbox image's declared version, and NemoClaw commit
`ef5d55d19e2da33c2474db158588613828e1a9be` (the source pin in this repository's
[NemoClaw build values](../image-builder-charts/helm/nemoclaw-cli-imagestream/values.yaml)).
Reading NemoClaw here supplies implementation references; it does not add
NemoClaw to the TP deployment.

- **Codex:** OpenShell's
  [Codex example](https://github.com/NVIDIA/OpenShell/blob/v0.1.2/providers/codex.yaml)
  requires OAuth access and refresh tokens plus an account ID; an ID token is
  optional. Its allowed binaries target the Codex CLI. This differs from the
  SAW installer's `codex -> OPENAI_API_KEY` mapping and single-credential
  `apply_provider()` path. The example is not automatically loaded and must
  be adapted to the actual executable paths in the deployed image.
- **OpenClaw's Codex route:** the versioned
  [OpenAI provider documentation](https://github.com/openclaw/openclaw/blob/v2026.9.6/docs/providers/openai.md)
  uses `openai` as the canonical provider ID for API-key and Codex subscription
  access. The route and selected runtime determine execution; a provider name
  alone does not prove Codex execution. Its
  [setup instructions](https://github.com/openclaw/openclaw/blob/v2026.9.6/docs/providers/openai/setup.md)
  describe `openclaw models auth login --provider openai --device-code` for
  headless OAuth. This is a candidate route to inspect in the pinned sandbox,
  not a validated SAW recipe. Integrating its credential lifecycle with
  OpenShell still needs validation.
- **Anthropic:** OpenShell's
  [Anthropic example](https://github.com/NVIDIA/OpenShell/blob/v0.1.2/providers/anthropic.yaml)
  uses `ANTHROPIC_API_KEY` and the `x-api-key` header at `api.anthropic.com`.
  Its example allows curl; it must be adapted for the executable making
  OpenClaw's requests. NemoClaw's
  [hosted provider definitions](https://github.com/NVIDIA/NemoClaw/blob/ef5d55d19e2da33c2474db158588613828e1a9be/src/lib/inference/native-provider/hosted.ts)
  and [configuration builder](https://github.com/NVIDIA/NemoClaw/blob/ef5d55d19e2da33c2474db158588613828e1a9be/src/lib/inference/config.ts)
  use `https://api.anthropic.com` with `anthropic-messages`. This supports
  investigating a native Anthropic path instead of reusing the installer's
  hardcoded OpenAI compatibility.
- **Kubernetes:** upstream has a
  [Kubernetes compute driver](https://github.com/NVIDIA/OpenShell/tree/v0.1.2/crates/openshell-driver-kubernetes).
  Its existence is separate from wiring it into this single-VM SAW deployment.
  The current chart's Podman configuration remains the relevant gap.

### Local checks, 2026-10-18

Tested repository base: `58f90c29017ff1bdf35f2e9edcc7ac5a41a1b5b0`, with the
support-matrix documentation changes in the working tree. No runtime code was
changed. Local OpenShell CLI reports `0.1.2`.

```bash
.venv/bin/python -m pytest -q -p no:cacheprovider \
  tests/installer/test_custom_endpoint.py \
  tests/installer/test_openshell_01.py \
  tests/charts/test_openshell_saw_chart.py \
  -k 'custom_endpoint or openshell_01 or gateway_config_is_schema_v2_for_openshell_01'
```

Result: **53 passed, 108 deselected**. The first sandboxed run had four setup
errors because loopback sockets were forbidden. Running the same selection
outside the sandbox allowed the local HTTPS issuer fixture and passed.
These tests use fakes or local fixtures; they do not validate any matrix cell.

`openshell provider profile lint` for the upstream Codex and Anthropic examples
could not complete: the CLI attempted to refresh an expired gateway OIDC token
against the unreachable configured cluster. Profile lint success is therefore
not claimed.

## Codex + Podman live preparation attempt

Date: 2026-10-18. Deployment commit:
`14fe6e0` on `docs/appeng-6705-support-matrix`.
Cluster: `cluster-r4js8`, OpenShift 4.22.18.
VM: `saw-tp-validation/tp-validation`.
Sandbox: `default/notebook`, Ready.
VM OS: Fedora Linux 44 (Cloud Edition), `x86_64`.
Effective gateway configuration: `compute_driver = "podman"`.

Verified live:

- OpenShell CLI and installed components: `0.1.2-rhaiv.0`.
- Podman: `5.8.1`.
- OpenClaw: `2026.9.6 (eb377ac)`, using the digest-pinned AIPCC image in
  [the test profile](../charts/saw-bom/profiles/tp-validation/default/sandbox.yaml).
- `saw-install.service` and `saw-apply.service` both report phase `Done` in
  `/var/lib/saw/status.json`.
- The only attached provider is the NVIDIA baseline. No Codex credential or
  successful Codex inference is claimed.

From the gateway VM, attempted the shipped OpenClaw device-code flow:

```bash
openshell --gateway saw-installer sandbox exec --name notebook --tty \
  --timeout 180 -- \
  env OPENCLAW_HOME=/sandbox SQLITE_TMPDIR=/sandbox/.openclaw/state \
  TMPDIR=/sandbox/.openclaw/state OPENCLAW_NIX_MODE=0 \
  openclaw models auth login --provider openai --device-code
```

Result: exit status 1 from the remote command, before any login code was issued:

```text
[security] blocked URL fetch (openai-chatgpt-device-code)
targetOrigin=https://auth.openai.com
reason=Blocked: resolves to private/internal/special-use IP address
```

The initial non-TTY attempt was refused because this CLI requires an interactive
TTY; the command above includes that requirement and reaches the OAuth request.

Reproduced the DNS results through Node inside the same sandbox using
`require("node:dns").promises.lookup(host, {all: true})`:

```text
auth.openai.com              198.18.0.7
api.openai.com               198.18.0.8
integrate.api.nvidia.com     198.18.0.5
```

OpenShell's `policy_dns/runtime.rs` allocates synthetic addresses from
`198.18.0.0/15`. Inspection of the installed OpenClaw file
`dist/extensions/openai/openai-chatgpt-device-code.js` shows that OAuth calls
`fetchWithSsrFGuard` for
`https://auth.openai.com/api/accounts/deviceauth/usercode`. Together, the live
DNS answers and the rejection identify a compatibility issue between the
OAuth request guard and the sandbox's synthetic DNS. No broad private-network
exception or agent code patch was applied.

Next prerequisite: establish a supported authentication route compatible with
OpenShell's DNS and credential handling. The current gateway catalog also does
not serve a Codex profile, and the namespace egress rules do not yet include
Codex authentication hosts. These need configuration before a full inference
test, even after the OAuth guard issue is resolved. Account authorization and
the `SAW_TP_OK` inference check have not run.

## Test procedure

Coordinate with APPENG-6703 (engineering-owned e2e deployment test). Reuse its
deployment and inference checks rather than creating a second deployment flow.
Start with Codex + Podman, then Anthropic + Podman. Test the Kubernetes rows
when a reproducible Kubernetes compute-driver deployment is available.

For each combination:

1. Record the tested Git commit, product versions, image digests, VM OS,
   provider type, endpoint, model, authentication method, and target environment.
2. Deploy the single-VM SAW using the documented productized install path and
   the provider-specific profile. Record the effective gateway compute driver
   and provider attached to the OpenClaw sandbox.
3. Verify the sandbox is ready and OpenClaw onboarding succeeded. A running VM
   or ready sandbox alone is not a successful inference test.
4. Through OpenClaw inside that sandbox, submit: `Reply with SAW_TP_OK.`
   Record the exact command or UI procedure, exit status where available, and
   response. Require a successful model response containing `SAW_TP_OK`; a
   direct API call outside the sandbox is insufficient.
5. Save sanitized logs and configuration alongside the result. If the check
   fails, record the failure and reason. If prerequisites prevent running it,
   leave the cell as Not tested and record the blocker.
6. Link the evidence from the corresponding matrix cell. Change it to
   Validated only after the live test succeeds.

The existing [live deployment runner](../scripts/test-deployment.sh) records
timestamp, commit, cluster context, check name, exit code, and detail. It
requires a caller-supplied `TEST_INFERENCE_CHECK` and a dedicated test cluster.
Its full lifecycle includes installation and removal; follow the
[live deployment test instructions](deployment-guide.md#live-deployment-test)
before running it. Its broader checks are not all required by this matrix task.

### Evidence record per combination

Copy and fill this record for every attempt. Keep credentials and tokens out of
the record and attachments.

```text
Provider label / exact provider type:
Compute driver / effective gateway configuration:
Result: Validated | Failed | Not tested
Test date and tester:
Git commit:
Environment / VM OS:
Install method:
OpenShell / OpenClaw versions and image digests:
Provider endpoint / model / authentication method:
Deployment command or procedure:
OpenClaw request command or UI procedure:
Expected response: contains SAW_TP_OK
Actual response / exit status:
Sanitized evidence links:
Failure or not-tested reason:
```

## Current blockers and decisions

- **Environment preflight, 2026-10-18:** the original configured cluster's API
  hostname did not resolve. The supplied replacement, `cluster-r4js8`, is
  reachable and login succeeded. It runs OpenShift 4.22.18 with five Ready
  nodes and a default Ceph RBD StorageClass. A Keycloak instance and RHBK
  operator exist in namespace `keycloak`. No VirtualMachine API was available.
  Created namespace `openshift-cnv`, OperatorGroup `saw-tp-virtualization`,
  and Subscription `kubevirt-hyperconverged` on the repository's `stable`
  channel using `redhat-operators`. Virtualization 4.22.12 and the repository's
  HyperConverged resource are now available, with successful reconciliation
  and no degradation. The temporary `saw-tp-virtualization` OperatorGroup was
  removed after the pattern created its own OperatorGroup. Some API calls returned
  intermittent Unauthorized errors; subsequent explicit-context reads worked.
  Cluster monitoring is reported unavailable. No provider inference test has
  run; credentials are excluded from this record.
- **Option A preparation:** `make prereqs-check` passed. Existing SSH keys and
  secret files were preserved; the inference secret currently selects NVIDIA
  (`build`). Published branch `docs/appeng-6705-support-matrix` to origin at
  the repository base commit above, then mirrored `openshell-gateway:latest`
  successfully using `make images-mirror`. `XDG_RUNTIME_DIR=/tmp/saw-tp-runtime`
  supplies a private writable runtime directory for this session. Started
  `./pattern.sh make install` with `TARGET_BRANCH=docs/appeng-6705-support-matrix`
  and `TARGET_ORIGIN=origin`. The root application, Virtualization, Vault,
  External Secrets, Keycloak, and governance applications are Synced/Healthy.
  The installer is still waiting on the unrelated RHDH application's health.
  NVIDIA deployment is a baseline only and does not validate a Codex or
  Anthropic matrix cell.
- **Test workspace:** added `tp-validation` to `overrides/saw-users.yaml` with
  a dedicated profile containing one OpenClaw sandbox in the default workspace.
  The default data-science profile also enables a NemoClaw CUDA workspace, so
  it is not used for this TP test. The test profile needs only the existing
  inference secret, with no web-search key or harness. Created the corresponding
  Keycloak account through `make keycloak-add-users`; generated passwords stay
  in a cluster Secret. The installer validates the new profile, and
  `tests/charts/test_saw_users_chart.py` plus
  `tests/charts/test_saw_bom_chart.py` passed (45 tests). Argo CD created the
  VM and the `notebook` sandbox; both are running, and both installer phases
  are Done. The Codex authentication attempt and remaining integration gaps
  are recorded above; provider inference still needs live verification.
- **Provider integration:** use the upstream OAuth-based Codex route as the
  working interpretation, verify the actual runtime in the pinned image, and
  establish how its credentials reach the workload. A direct API-key test
  must be labelled separately. For Anthropic, investigate its native Messages
  API configuration and the matching OpenShell provider profile.
- **Driver decision:** identify the Kubernetes compute-driver deployment and
  determine whether it must pass for TP or may remain explicitly Not tested.
- **Publication:** link this document from the parent spike/epic after it is
  published. The parent issue URL has not been supplied. Keep the matrix and
  evidence accessible from that issue; the README link alone does not satisfy
  this acceptance criterion.
