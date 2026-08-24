# GPU Passthrough for OpenShell Agent Sandbox via OpenShift Virtualization

**Project:** APPENG
**Type:** Story
**Epic:** Secure Agent Workspace Validated Pattern
**Priority:** High
**Component:** RH_AI_Blueprints
**Labels:** secure_agent_workspace, gpu, openshell, openshift_virt

## Summary

Enable GPU passthrough from OpenShift Virtualization (KubeVirt) to the sandbox container runtime (Podman) inside the gateway VM, allowing NemoClaw/OpenClaw agents to leverage GPU-accelerated workloads.

## Collaborators

- **Giuseppe**/**Quinn**  — OpenShift Virtualization GPU passthrough (KubeVirt device plugins, VFIO/mediated devices).
- **Saurabh** — Validated Pattern integration, end-to-end demo

## Background

The current Secure Agent Workspace deploys the AI agent sandbox inside a KubeVirt VM running on OpenShift. The sandbox container (NemoClaw/OpenClaw) runs inside Podman within the VM. For GPU-accelerated workloads (local inference, code execution with CUDA), the GPU must be passed through three layers:

```
Physical GPU → OpenShift Node → KubeVirt VM → Podman Container → Sandbox Process
```

## Acceptance Criteria

1. GPU is visible and usable inside the sandbox container (`nvidia-smi` works)
2. Local inference via Ollama or vLLM runs on GPU inside the sandbox
3. NemoClaw agent can use GPU-accelerated tools (code execution with CUDA)
4. End-to-end demo: user prompt → agent routes to local GPU inference → response
5. Works with OpenShift Virtualization on bare-metal nodes with NVIDIA GPUs

## Implementation Plan

### Phase 1: OpenShift Virt GPU Passthrough to VM

- Configure NVIDIA GPU Operator on OpenShift nodes
- Set up KubeVirt `gpus` or `hostDevices` in the VirtualMachine spec
- Verify `nvidia-smi` works inside the VM
- Document which GPU models / mediated device types are supported
- Handle multi-GPU and GPU sharing (MIG, time-slicing) if applicable

**Key questions:**
- VFIO passthrough vs mediated devices (vGPU) — which is preferred?
- How does GPU allocation interact with OpenShift node scheduling?
- Can multiple VMs share a GPU via MIG or vGPU?

### Phase 2: Container Runtime GPU Support

- Install NVIDIA Container Toolkit inside the gateway VM
- Configure Docker (current) or Podman (future) with `nvidia` runtime
- Ensure `openshell sandbox create --gpu` passes `--gpus all` to Podman
- Verify `nvidia-smi` works inside the sandbox container
- Test with Ollama and vLLM running on GPU inside the sandbox

**Key questions:**
- NVIDIA Container Toolkit packaging for RHEL (golden image)
- GPU memory limits and isolation between sandboxes

### Phase 3: Validated Pattern Integration

- Add GPU configuration to `charts/openshell-saw/values.yaml`:
  ```yaml
  vm:
    gpu:
      enabled: false
      count: 1
      deviceName: "nvidia.com/gpu"
  ```
- Update VM template to include GPU device allocation
- Update golden image build to include NVIDIA Container Toolkit
- Update `gateway.env` with GPU-aware driver config
- Add `--gpu` flag to `openshell sandbox create` in setup scripts
- Update NemoClaw onboard to detect and use GPU
- Add GPU health check to setup Job

### Phase 4: End-to-End Demo

- Deploy pattern on GPU-enabled OpenShift cluster
- Create sandbox with GPU passthrough
- Run local Ollama with a model (e.g., Llama 3.1 8B) on GPU
- Configure NemoClaw to route inference to local Ollama
- Demo: user asks a question → agent uses local GPU inference → responds
- Measure latency and throughput vs cloud inference

## Architecture

```
┌─────────────────────────────────────────────────┐
│ OpenShift Node (bare-metal, NVIDIA GPU)         │
│                                                 │
│  ┌─────────────────────────────────────────┐    │
│  │ KubeVirt VM (Fedora 44 + Docker)        │    │
│  │                                         │    │
│  │  ┌─────────────────────────────────┐    │    │
│  │  │ Sandbox Container (NemoClaw)    │    │    │
│  │  │                                 │    │    │
│  │  │  ┌───────────┐ ┌───────────┐    │    │    │
│  │  │  │ OpenClaw  │ │ Ollama    │    │    │    │
│  │  │  │ Agent     │ │ (GPU)     │    │    │    │
│  │  │  └───────────┘ └───────────┘    │    │    │
│  │  │         ↕ inference proxy       │    │    │
│  │  └─────────────────────────────-───┘    │    │
│  │         ↕ Docker --gpus all             │    │
│  │  ┌──────────────┐                       │    │
│  │  │ NVIDIA Driver│ (Container Toolkit)   │    │
│  │  └──────────────┘                       │    │
│  └────────────────↕──────────────────-─────┘    │
│            VFIO / vGPU passthrough              │
│  ┌──────────────────────┐                       │
│  │ NVIDIA GPU (physical)│                       │
│  └──────────────────────┘                       │
└─────────────────────────────────────────────────┘
```

## Dependencies

- OpenShift cluster with bare-metal nodes and NVIDIA GPUs
- NVIDIA GPU Operator installed on OpenShift
- KubeVirt GPU passthrough support (VFIO or mediated devices)
- NVIDIA Container Toolkit for Fedora 44
- OpenShell `--gpu` / `--sandbox-gpu` support

## Risks

- **GPU driver version compatibility** — VM kernel driver must match the container toolkit version
- **Performance overhead** — VFIO passthrough adds latency vs bare-metal; vGPU adds more
- **Resource contention** — GPU is a shared resource; need isolation between sandboxes
- **Golden image size** — NVIDIA drivers + toolkit add significant size to the VM image
- **Podman transition** — GPU support may differ between Docker and Podman CDI paths
