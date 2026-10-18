# SAW TP provider / driver matrix

Work item: [APPENG-6705](https://redhat.atlassian.net/browse/APPENG-6705).
Parent: [APPENG-6458](https://redhat.atlassian.net/browse/APPENG-6458).
Updated: 2026-10-18. Setup: [OpenAI setup](../README.md#custom-inference-provider).


| Provider / integration | Podman                                                | Kubernetes                                              |
| ---------------------- | ----------------------------------------------------- | ------------------------------------------------------- |
| OpenAI API (OpenClaw)  | **Validated**                                         | **Not tested — no deployment path in current SAW code** |
| Anthropic (secondary)  | **Not validated — missing Anthropic API key** | **Not tested**                                          |


## OpenAI + Podman test

Recorded on 2026-10-18 using the unchanged shipped
`openai` provider profile, OpenClaw image pinned by digest, Fedora 44,
OpenShell `0.1.2-rhaiv.0`, Podman `5.8.1`. Sandbox `openai-test` in VM
`tp-codex` / namespace `saw-tp-codex` had only provider named/type `openai`
attached, was Ready, and had no configured model fallbacks.

The prompt returned exactly `SAW_TP_OPENAI_API_OK`, model `gpt-6-luna`,
provider `openai`, `ok: true`, exit **0**. A second question about containers
versus VMs returned HTTP **200** and answered:

> A container shares the host’s operating-system kernel, while a virtual machine runs its own guest operating system on virtualized hardware.

```bash
openshell --gateway saw-installer sandbox exec --name openai-test \
  --workspace default --no-tty --timeout 120 -- \
  env OPENCLAW_HOME=/sandbox SQLITE_TMPDIR=/sandbox/.openclaw/state \
    TMPDIR=/sandbox/.openclaw/state OPENCLAW_NIX_MODE=0 \
  openclaw agent exec --auth-env-only --model openai/gpt-6-luna \
    --thinking low --timeout 60 --json \
    'Reply with exactly SAW_TP_OPENAI_API_OK. Do not use tools.'
```

This was manual CLI setup in a new sandbox on an existing VM, using a
manually loaded static policy allowing `api.openai.com:443` for OpenClaw's Node binary,
with governance disabled. It does **not** validate a fresh YAML/Argo CD
deployment.

The TP installer supports Podman only; Kubernetes remains untested.

## Anthropic + Podman attempt

2026-10-18: sandbox `anthropic-test` in the same VM, provider named/type
`anthropic`, model `anthropic/claude-sonnet-4-6`, no configured fallbacks.
Imported the upstream OpenShell 0.1.2 Anthropic profile with OpenClaw Node
binary paths, selected Anthropic API compatibility, and allowed
`api.anthropic.com:443` in the static policy and namespace egress configuration.
The sandbox was Ready with configuration accepted.

Ran the command above with sandbox `anthropic-test`, model
`anthropic/claude-sonnet-4-6`, and expected answer `SAW_TP_ANTHROPIC_API_OK`.
Result: exit **1**, HTTP **401**, `invalid x-api-key`. A direct credential
check against Anthropic's `/v1/models` also returned **401**. A valid API key
and successful retry are required before marking this combination validated.

## Kubernetes preflight

2026-10-18: the SAW chart accepts only `containerRuntime: podman`.
The upstream OpenShell 0.1.2 Kubernetes chart's server-side Helm dry-run
also failed (exit **1**): neither `agents.x-k8s.io/v1beta1` nor
`agents.x-k8s.io/v1alpha1` is available. The cluster has no Agent Sandbox
CRDs or controller. No resources were installed and no Kubernetes inference
request was run. Testing requires the Agent Sandbox controller and a
separate Kubernetes-backed OpenShell deployment.

Link this document from APPENG-6458 after publishing.