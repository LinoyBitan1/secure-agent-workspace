# Customer-supplied interceptors for signed policies

**Project:** APPENG
**Type:** Story
**Epic:** Secure Agent Workspace Validated Pattern
**Priority:** High
**Component:** RH_AI_Blueprints
**Labels:** secure_agent_workspace, governance, interceptor, policy, security

## Summary

Implement customer-supplied governance interceptors for the Secure Agent Workspace, enabling organizations to enforce signed sandbox policies, restrict provider profiles, and audit policy changes through OpenShell's gateway interceptor framework. Build a mock interceptor (based on the upstream example) to validate the integration and demonstrate the governance story end-to-end.

## Collaborators

- **Saurabh** — Interceptor integration into the Validated Pattern, deployment automation
- **Jesse** — Build a mock interceptor to test the integration, modeled on the upstream governance-interceptor example

## Background

OpenShell provides a **gateway interceptor framework** — a gRPC-based extension point that lets an external service intercept and govern gateway operations (sandbox creation, provider management, policy updates). The upstream example at [NVIDIA/OpenShell/examples/governance-interceptor](https://github.com/NVIDIA/OpenShell/tree/main/examples/governance-interceptor) demonstrates:

- **Signed policy injection**: Every new sandbox receives an admin-controlled policy, signed with an EdDSA JWT over a canonical protobuf SHA-256 hash
- **Tamper detection**: Policy signatures are validated on sandbox creation and config updates — any modification is rejected
- **Provider profile governance**: Only approved provider profiles can be created; unauthorized profiles are blocked
- **Policy widening prevention**: Auto-approval of agent-authored policy proposals is blocked; sandbox-side policy updates must carry a valid governance signature
- **Hot-reload**: Policy changes are re-signed and propagated to all running sandboxes in real time

This is the mechanism that lets a customer's security team say: *"the agent can only do what we've explicitly signed off on, and we can prove it hasn't been tampered with."*

## How it works

```
Customer Policy Admin
        │
        ▼
┌──────────────────-────┐
│ Governance Interceptor│ (gRPC server, fail-closed)
│                       │
│ • Signs policies (JWT)│
│ • Validates signatures│
│ • Vends profiles      │
│ • Blocks widening     │
│ • Hot-reloads policy  │
└───────────┬─────--────┘
            │ gRPC (Describe, Evaluate, SnapshotProviderProfiles)
            ▼
┌──────────────-───-────┐
│ OpenShell Gateway     │
│                       │
│ • Calls interceptor   │
│   on every operation  │
│ • Fail-closed if      │
│   interceptor down    │
│ • JSON Patches to     │
│   inject policy       │
└───────────┬───-───────┘
            │
            ▼
┌─────────────────────-─┐
│ Sandbox (OpenClaw)    │
│ • Runs with signed    │
│   policy enforced     │
│ • Cannot widen policy │
│ • Audit trail of all  │
│   policy evaluations  │
└─────────────────-─────┘
```

### Interceptor protocol (gRPC)

| RPC | Purpose |
|-----|---------|
| `Describe` | Returns manifest declaring which RPCs and phases to intercept |
| `Evaluate` | Called per-request per-phase: `modify_operation`, `validate`, `post_commit` |
| `SnapshotProviderProfiles` | Returns the governed set of provider profiles |

### Policy signing

- Ed25519 keypair generated at startup (or loaded from HSM/Vault)
- Policy serialized to canonical protobuf JSON, SHA-256 hashed with domain separation
- Hash embedded in JWT with issuer, audience, subject, and hash algorithm claims
- Signature validated on every sandbox create and config update

## Acceptance Criteria

1. Mock interceptor deploys alongside the Secure Agent Workspace
2. New sandboxes receive a signed, admin-controlled policy
3. Attempting to modify the sandbox policy without a valid signature is rejected
4. Attempting to create an unauthorized provider profile is rejected
5. Policy hot-reload propagates to running sandboxes
6. Interceptor failure results in fail-closed behavior (operations denied)
7. Audit trail shows interceptor evaluations (allow/deny with annotations)

## Implementation Plan

### Phase 1: Build mock interceptor (Jesse)

Build a simplified governance interceptor in Rust or Go, based on the upstream example:

- Implement the `GatewayInterceptor` gRPC service (Describe, Evaluate, SnapshotProviderProfiles)
- Sign a baseline sandbox policy with Ed25519 JWT
- Validate signatures on sandbox creation
- Block unauthorized provider profile creation
- Block policy widening (deny `proposal_approval_mode=auto`)
- Containerize and publish to quay.io

Key decisions:
- Rust (match upstream example) vs Go (more common in the Red Hat ecosystem)?
- Ed25519 key management: in-memory for mock, Vault-backed for production
- Which policy rules to enforce in the mock (filesystem, network, tool restrictions)?

### Phase 2: Integrate into Validated Pattern (Saurabh)

- Add interceptor Helm chart to the pattern (`charts/governance-interceptor/`)
- Deploy interceptor as a pod in the same namespace as the gateway VM
- Configure gateway TOML to bind the interceptor:

```toml
[openshell.gateway]
provider_profile_sources = [
  { type = "interceptor", name = "governance" },
]

[[openshell.gateway.interceptors]]
name           = "governance"
grpc_endpoint  = "http://governance-interceptor:18081"
order          = 10
failure_policy = "fail_closed"
binding_policy = "allowlist"
timeout        = "500ms"
```

- Add per-RPC phase bindings for CreateSandbox, CreateProvider, UpdateConfig, SubmitPolicyAnalysis
- Inject gateway TOML interceptor config via cloud-init or setup Job
- Add `governance.enabled` toggle in `values.yaml`

### Phase 3: Customer-facing demo

- Demo flow: admin sets policy → user creates sandbox → sandbox runs with signed policy → user tries to widen policy → denied → admin updates policy → hot-reloaded to running sandbox
- Show audit trail of interceptor evaluations
- Show fail-closed behavior when interceptor is stopped

### Phase 4: Production hardening

- Ed25519 key management via Vault (not in-memory)
- Policy versioning and rollback
- Multi-interceptor chaining (multiple governance providers)
- Integration with OPA/Gatekeeper for Kubernetes-level policy
- Customer-supplied interceptor deployment guide

## Dependencies

- OpenShell 0.0.96+ (interceptor framework support)
- Access to the `openshell.gateway_interceptor.v1` protobuf definitions
- gRPC runtime (tonic for Rust, grpc-go for Go)
- Ed25519 signing library (ring/rcgen for Rust, crypto/ed25519 for Go)

## Risks

- **Interceptor availability** — fail-closed means interceptor outage blocks all sandbox operations. Need health checks and HA deployment.
- **Performance** — interceptor adds latency to every governed operation. The 500ms timeout must be tuned.
- **Key management** — in-memory keys are acceptable for a mock but not for production. Vault integration is required.
- **Protobuf compatibility** — interceptor must stay in sync with OpenShell's protobuf definitions across versions.

## References

- [Upstream governance interceptor example](https://github.com/NVIDIA/OpenShell/tree/main/examples/governance-interceptor)
- OpenShell gateway interceptor protobuf: `openshell.gateway_interceptor.v1.GatewayInterceptor`
- OpenShell gateway TOML config: `[[openshell.gateway.interceptors]]`
