# Versioned VM BOM installer for OpenShell SAW

**Project:** APPENG  
**Type:** Story  
**Epic:** Secure Agent Workspace Validated Pattern  
**Priority:** High  
**Component:** RH_AI_Blueprints  
**Labels:** secure_agent_workspace, bom, installer, versioning, openshell, nemoclaw

## Summary

Create a versioned, manifest-driven installer that configures a sandbox VM end-to-end for SAW:

- Install OpenShell CLI, gateway, and supervisor
- Install NemoClaw CLI
- Create `nemoclaw-sandbox`
- Configure providers and default workspace state
- Run deterministic post-install verification

The installer must be driven by a single BOM manifest per version (e.g. `bom/v0.0.103/manifest.yaml`) so platform operators can reproduce and audit exactly what was installed.

## Background

Current setup logic is distributed across chart templates and setup scripts. This increases operational risk when versions drift, makes rollbacks difficult, and complicates auditability.

A versioned BOM installer gives:

1. Reproducibility (all artifacts pinned)
2. Traceability (what changed between versions)
3. Safer rollback/upgrade path
4. Cleaner separation of "what to install" (manifest) vs "how to install" (installer)

## Scope

### In scope

- New BOM manifest schema and version directory convention
- Installer entrypoint that consumes manifest
- End-to-end VM install phases:
  - preflight
  - fetch/verify artifacts
  - install binaries/CLIs
  - configure systemd and OpenShell config
  - bootstrap sandbox/providers/workspace
  - verify
- Install report artifact (JSON + text summary)

### Out of scope

- UI workflow for composing manifests
- ArgoCD ApplicationSet generation
- Replacing existing charts in the same story (can be follow-up)

## Proposed Directory Layout

```text
bom/
  v0.0.103-rhaiv.0/
    manifest.yaml
installer/
  install-bom.sh
  lib/
    preflight.sh
    fetch_verify.sh
    install_components.sh
    configure_gateway.sh
    bootstrap_runtime.sh
    verify.sh
```

## Installer Packaging

Package the installer as a versioned tarball artifact, pinned in the BOM manifest.

### Artifact format

```text
saw-bom-installer-v0.0.103-rhaiv.0.tar.gz
└── saw-bom-installer/
    ├── install-bom.sh
    ├── lib/
    │   ├── preflight.sh
    │   ├── fetch_verify.sh
    │   ├── install_components.sh
    │   ├── configure_gateway.sh
    │   ├── bootstrap_runtime.sh
    │   └── verify.sh
    ├── VERSION
    └── checksums.txt
```

### Packaging and publish flow

1. Build tarball from `installer/` per BOM version.
2. Generate SHA256 for the tarball.
3. Optionally sign artifact (cosign/gpg).
4. Publish to internal artifact location.
5. Reference URL + checksum from the BOM manifest.

### Manifest contract for installer artifact

```yaml
spec:
  installer:
    version: v0.0.103
    source:
      url: https://artifacts.example.com/saw/bom/saw-bom-installer-v0.0.103.tar.gz
    checksum:
      algo: sha256
      value: "<installer-tarball-sha256>"
```

## BOM Manifest Schema (v1)

```yaml
apiVersion: saw.redhat.com/v1alpha1
kind: VmBom
metadata:
  name: saw-vm-bom
  version: v0.0.103
  createdBy: platform-team
  createdAt: "2026-08-10T00:00:00Z"

spec:
  platform:
    os: fedora
    arch: amd64
    runtime: docker

  installer:
    version: v0.0.103
    source:
      url: https://artifacts.example.com/saw/bom/saw-bom-installer-v0.0.103.tar.gz
    checksum:
      algo: sha256
      value: "<installer-tarball-sha256>"

  artifacts:
    openshell:
      cli:
        source:
          type: pip
          package: openshell
          version: "0.0.97+rhaiv.0"
          extraIndexUrl: "https://packages.redhat.com/api/pypi/public-rhai/rhoai/3.6-EA1/cpu-ubi9-test/simple/"
      gateway:
        source:
          type: image_binary
          image: "quay.io/opendatahub/odh-openshell-gateway:v0.0.103"
          pathInImage: "/usr/local/bin/openshell-gateway"
        checksum:
          algo: sha256
          value: "<gateway-binary-sha256>"
      supervisor:
        source:
          type: image_binary
          image: "quay.io/opendatahub/odh-openshell-supervisor:v0.0.103"
          pathInImage: "/openshell-sandbox"
        checksum:
          algo: sha256
          value: "<supervisor-binary-sha256>"

    nemoclaw:
      cli:
        source:
          type: image_tree
          image: "quay.io/rh-ai-quickstart/nemoclaw-cli:v0.0.103"
          pathInImage: "/opt/nemoclaw"
        checksum:
          algo: sha256
          value: "<nemoclaw-cli-tree-sha256>"
      sandboxImage:
        image: "quay.io/rh-ai-quickstart/nemoclaw-sandbox:v0.0.103"

  system:
    user: cloud-user
    installPaths:
      gatewayBin: /usr/local/bin/openshell-gateway
      supervisorBin: /usr/local/bin/openshell-supervisor
      nemoclawRoot: /opt/nemoclaw
      nemoclawShim: /usr/local/bin/nemoclaw
    packages:
      required:
        - docker-ce
        - docker-ce-cli
        - containerd.io
        - jq
        - lsof
    services:
      enable:
        - docker
      restartAfterInstall:
        - openshell-gateway.service
    gatewayEnv:
      OPENSHELL_DRIVERS: docker
      OPENSHELL_SERVER_PORT: "17670"
      OPENSHELL_SSH_GATEWAY_PORT: "17670"
      OPENSHELL_ENABLE_MTLS_AUTH: "true"

  bootstrap:
    gateway:
      name: openshell
      endpoint: "https://127.0.0.1:17670"
      authMode: mtls
      externallySupervised: true
    workspaces:
      mode: multi_workspace_bom
      source:
        type: file_refs
        basePath: /etc/saw/workspaces
      defaultMemberGrants:
        - subject: openshell-client
          role: admin
      boms:
        - id: default
          workspaceFile: default/workspace.yaml
          providersFile: default/providers.yaml
          sandboxFile: default/sandbox.yaml
      providerBehavior:
        firstProviderSetsInference: true
        prefixProviderNameForNonDefaultWorkspace: true
        credentialSecretKeyDefault: api_key
      sandboxBehavior:
        defaultSandboxNameFromWorkspace: true
        fallbackSandboxImageFromGlobal: true
    providerConfig:
      source:
        type: file_ref
        path: /etc/saw/provider.yaml
    bootstrapSandboxConfig:
      source:
        type: file_ref
        path: /etc/saw/bootstrap-sandbox.yaml

  security:
    verifyChecksums: true
    denyLatestTags: true
    failOnMissingSecrets: true

  verify:
    commands:
      - "openshell --version"
      - "openshell-gateway --version"
      - "openshell-supervisor --version"
      - "nemoclaw --version"
      - "systemctl --user is-active openshell-gateway.service"
      - "docker --version"
    assert:
      sandboxExists: nemoclaw-sandbox
      providerProfileListRequired: []

  report:
    writeJson: /var/log/saw-bom-install-report.json
    writeText: /var/log/saw-bom-install-report.txt
```

## Installer Behavior Requirements

1. **Idempotent**: repeated runs must converge without destructive side effects.
2. **Fail-fast**: hard fail on artifact verification/install failures.
3. **Dry-run mode**: `install-bom.sh --manifest <path> --dry-run`.
4. **Version guardrails**: reject manifests with floating tags (`latest`) when `denyLatestTags=true`.
5. **Deterministic logs**: phase markers and machine-readable report.

## GitOps + VM Startup Execution Model

Run the BOM installer inside VM startup (cloud-init + systemd), while keeping Git as the single source of truth.

### Control plane (GitOps)

- GitOps defines VM spec, BOM manifest version, and installer artifact version.
- VM rollout/recreate is triggered by git changes to VM template, cloud-init payload, or BOM reference.
- The rendered `manifest.yaml` is injected into VM at bootstrap time (for example under `/etc/saw/manifest.yaml`).

### In-VM execution (systemd)

- `cloud-init` writes installer payload and config:
  - `/opt/saw-installer/install-bom.sh`
  - `/opt/saw-installer/lib/*`
  - `/etc/saw/manifest.yaml`
- `cloud-init` installs and enables a unit:
  - `saw-bom-install.service` (`After=network-online.target docker.service`, `Wants=network-online.target`)
- Service executes:
  - `/opt/saw-installer/install-bom.sh --manifest /etc/saw/manifest.yaml`
- Installer writes state and report:
  - `/var/lib/saw-bom/last-applied-sha`
  - `/var/log/saw-bom-install-report.json`
  - `/var/log/saw-bom-install-report.txt`
- Re-run behavior:
  - if manifest hash unchanged, installer exits cleanly with `no-op`;
  - if hash changed, installer runs reconcile flow.

#### Concrete `saw-bom-install.service` example

```ini
[Unit]
Description=SAW BOM Installer
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service
ConditionPathExists=/etc/saw/manifest.yaml
StartLimitIntervalSec=0

[Service]
Type=oneshot
User=cloud-user
WorkingDirectory=/opt/saw-installer
Environment=HOME=/home/cloud-user
Environment=PATH=/usr/local/bin:/usr/bin:/bin
ExecStartPre=/usr/bin/mkdir -p /var/lib/saw-bom /var/log
ExecStart=/opt/saw-installer/install-bom.sh --manifest /etc/saw/manifest.yaml --state-dir /var/lib/saw-bom
StandardOutput=journal
StandardError=journal
RemainAfterExit=yes
TimeoutStartSec=1800
Restart=on-failure
RestartSec=15

[Install]
WantedBy=multi-user.target
```

Notes:

- Use `Type=oneshot` + `RemainAfterExit=yes` so systemd tracks completion state.
- `ConditionPathExists` prevents noisy failures when cloud-init sequencing is delayed.
- Keep installer idempotent so retries and reboot runs are safe.

### Minimal cluster-side reconciler split

If setup Jobs are removed, keep a minimal cluster-side component for operations that depend on Kubernetes APIs or cluster secrets:

1. **Secret projection contract**
   - Resolve workspace/provider secrets from Kubernetes and project them into VM bootstrap inputs (or VM-attached secret volume) in a deterministic format.
2. **Route/identity contract**
   - Resolve Route hostnames and Keycloak admin credentials needed for dashboard redirect registration.
3. **RBAC-scoped API actions**
   - Perform namespace-scoped operations that are safer outside the VM trust boundary.

This keeps VM-local installation fully declarative while preventing loss of current setup behavior that depends on cluster state.

### Example `provider.yaml` (admin-authored)

```yaml
apiVersion: saw.redhat.com/v1alpha1
kind: ProviderConfig
metadata:
  name: default-provider-config
spec:
  strategy: nemoclaw_onboard_with_fallback
  agent: openclaw
  allowFallbackProviderCreate: true
  map:
    build:
      providerType: nvidia
      credentialKey: NVIDIA_API_KEY
      nemoclawEnv: NVIDIA_INFERENCE_API_KEY
    openai:
      providerType: codex
      credentialKey: OPENAI_API_KEY
      nemoclawEnv: OPENAI_API_KEY
    anthropic:
      providerType: claude-code
      credentialKey: ANTHROPIC_API_KEY
      nemoclawEnv: ANTHROPIC_API_KEY
    gemini:
      providerType: google-vertex-ai
      credentialKey: GOOGLE_API_KEY
      nemoclawEnv: GEMINI_API_KEY
```

### Example `bootstrap-sandbox.yaml` (admin-authored)

```yaml
apiVersion: saw.redhat.com/v1alpha1
kind: BootstrapSandboxConfig
metadata:
  name: default-bootstrap-sandbox-config
spec:
  sandboxName: nemoclaw-sandbox
```

## Acceptance Criteria

1. `install-bom.sh --manifest bom/vX/manifest.yaml` fully configures a fresh VM end-to-end.
2. All installed component versions match manifest pins exactly.
3. Installer verifies checksums and exits non-zero on mismatch.
4. Re-running installer produces no drift and no duplicate/broken resources.
5. Post-install report includes:
   - BOM version
   - resolved artifact digests/checksums
   - installed component versions
   - verification status per phase
6. Dry-run prints planned actions without modifying host.
7. VM boot path can run installer via systemd without setup Job dependency for VM-local phases.
8. Installer performs `no-op` when manifest hash is unchanged, and reconcile when changed.

## Implementation Plan

### Phase 1: Schema + parser

- Add manifest version contract (`apiVersion`, `kind`, required fields)
- Add parser/validator in installer entrypoint

### Phase 2: Installer phases

- Implement preflight/fetch/install/configure/bootstrap/verify phases
- Add structured logging and report generation

### Phase 3: Integrate with current flow

- Add Makefile target (example: `make install-bom BOM_VERSION=v0.0.103`)
- Document operator workflow in `docs/`

### Phase 4: Hardening

- Add negative tests (bad checksum, missing artifact, invalid manifest)
- Add rollback playbook for failed upgrades

## Review Items (Follow-up)

1. **Policy BOM integration (relook required):**
   - Current runtime flow consumes `workspace.yaml`, `providers.yaml`, and `sandbox.yaml`.
   - `policy.yaml` is defined in design docs but is not yet consumed by `setup-workspaces.sh`.
   - Revisit once policy enforcement wiring is implemented (likely through governance interceptor integration).

2. **Manifest/runtime schema alignment (relook required):**
   - Keep `manifest.yaml` workspace bootstrap schema aligned with the live parser behavior:
     - provider secret lookup via `credentialSecret` + `credentialSecretKey` (default `api_key`)
     - provider name prefixing for non-default workspaces
     - first provider inference defaulting
     - sandbox name/image fallback behavior
   - Re-validate on each parser/setup script update before finalizing BOM schema version.
