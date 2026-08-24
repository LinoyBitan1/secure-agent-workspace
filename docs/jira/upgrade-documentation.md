# Create Upgrade Documentation: Cluster and Component Upgrade Impact on Workload Continuity

**Project:** APPENG
**Type:** Story
**Epic:** Secure Agent Workspace Validated Pattern
**Priority:** Medium
**Component:** RH_AI_Blueprints
**Labels:** secure_agent_workspace, documentation, upgrades, day2

## Summary

Document the upgrade flow for the Secure Agent Workspace, describing how OpenShift cluster upgrades, operator upgrades, and component upgrades impact running workloads (VMs, sandboxes, agent sessions, and user data), and what steps are required to maintain continuity.

## Background

The Secure Agent Workspace runs long-lived workloads (KubeVirt VMs, Docker containers inside VMs, agent sessions with state) that are sensitive to disruption. Customers and field teams need clear documentation on:

- What happens to a running agent session during an upgrade
- Whether sandbox state (conversation history, files, credentials) survives upgrades
- Which upgrades require downtime vs. which are rolling/transparent
- The order of operations for upgrading the full stack

## Acceptance Criteria

1. Written flow document covering all upgrade scenarios listed below
2. Each scenario includes: what triggers it, what's impacted, whether downtime occurs, and recovery steps
3. Tested against at least one real upgrade cycle (e.g., OpenShift 4.x → 4.x+1)
4. Published in the pattern's documentation (README or docs/ directory)

## Upgrade Scenarios to Document

### 1. OpenShift cluster upgrade (e.g., 4.17 → 4.18)

- Impact on KubeVirt VMs (live migration vs. drain/restart)
- Impact on running sandbox containers inside the VM
- Impact on ArgoCD-managed applications
- Impact on operator subscriptions (auto vs. manual approval)
- Impact on PVCs and persistent data
- Network disruption during node drain

### 2. OpenShift Virtualization (CNV) operator upgrade

- Does the VM need to restart?
- Is live migration triggered automatically?
- Impact on virt-launcher pods
- Impact on DataVolumes and golden images

### 3. OpenShell gateway/supervisor version upgrade

- Current: binaries installed at provisioning time, not baked into golden image
- Upgrade path: update `values.yaml` image tags → delete/recreate VM, or in-place binary swap via SSH
- Impact on running sandboxes (do they survive a gateway restart?)
- Impact on provider configuration and inference routes
- Impact on mTLS certificates and gateway registrations

### 4. NemoClaw sandbox image upgrade

- Pre-built image in internal registry — how to update the tag
- Impact on running sandboxes (need to recreate or hot-swap?)
- State inside `/sandbox/` — is it preserved across image upgrades?
- OpenClaw config, conversation history, plugin state

### 5. NemoClaw CLI upgrade

- CLI installed from container image at provisioning time
- Upgrade path: rebuild CLI image, re-run setup Job
- Blueprint `max_openshell_version` cap — does it need patching?
- Impact on nemoclaw onboard state

### 6. Keycloak / OIDC upgrade

- RHBK operator upgrade impact on running sessions
- Realm import idempotency — does re-applying the realm break existing users?
- OIDC token validity across Keycloak restarts
- Impact on dashboard oauth2-proxy sessions

### 7. Vault / External Secrets upgrade

- Impact on ExternalSecret refresh cycles
- Do secrets rotate during upgrade?
- Impact if Vault is temporarily unreachable

### 8. Red Hat Developer Hub (RHDH) operator upgrade

- Impact on running Developer Hub instance and Software Templates
- Do existing sandbox provisioning templates survive the upgrade?
- Impact on RHDH catalog (catalog entities, API registrations)
- Impact on RHDH plugins (OpenShift, Kubernetes, TechDocs)
- Authentication provider continuity (Keycloak/OIDC integration)
- Dynamic plugin configuration — are custom plugins preserved?
- Impact on in-flight Software Template runs (user provisioning a sandbox during upgrade)
- RBAC and permission policies — do they persist across upgrades?

### 9. Golden image rebuild (renumbered)

- When is a golden image rebuild required vs. optional?
- How to roll out a new golden image to existing VMs
- DataVolume / DataSource lifecycle during image swap
- CDI cache invalidation (`pullMethod: node` gotcha)

### 10. Validated Pattern (ArgoCD) sync

- What happens when the git branch is updated?
- Which resources ArgoCD recreates vs. updates in place
- ConfigMap changes that require Job re-run vs. automatic pickup
- How to force a full redeploy vs. incremental sync

## Document Structure

```
docs/upgrade-guide.md

1. Overview
   - Component dependency graph
   - Which components can be upgraded independently

2. Upgrade Matrix
   | Component | Rolling? | Downtime? | Data preserved? | Requires VM restart? |
   |-----------|----------|-----------|-----------------|---------------------|
   | OpenShift | Yes      | No*       | Yes             | Possible (drain)    |
   | CNV       | Yes      | No*       | Yes             | Possible (migration)|
   | Gateway   | No       | Brief     | Yes             | Yes (restart)       |
   | Sandbox   | No       | Yes       | No**            | N/A (recreate)      |
   | Keycloak  | Yes      | No        | Yes             | No                  |
   | Vault     | Yes      | No        | Yes             | No                  |
   | RHDH      | Yes      | No        | Yes             | No                  |
   
   * With live migration support
   ** Sandbox state is ephemeral unless persisted

3. Step-by-step upgrade procedures
   - Pre-upgrade checklist
   - Backup recommendations
   - Upgrade commands
   - Post-upgrade verification

4. Rollback procedures
   - How to roll back each component
   - Known limitations of rollback

5. Troubleshooting
   - Common upgrade failures and recovery
```

## Dependencies

- Access to a test cluster for upgrade validation
- At least one real upgrade cycle documented with actual observations
- Input from CNV team on VM live migration behavior during upgrades
