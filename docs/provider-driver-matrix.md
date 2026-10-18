# SAW TP provider and driver validation

Results recorded on 2026-10-18 for APPENG-6705.

| Provider configuration | Podman driver | Kubernetes driver |
|---|---|---|
| Codex: SAW API-key choice, implemented through the OpenAI API provider | Validated: `gpt-6-luna`, successful prompt response | Not tested |
| Anthropic | Not tested | Not tested |

The validated configuration uses OpenClaw as the agent and an OpenAI API key.
It does **not** validate OpenShell's separate Codex OAuth provider or the native
Codex agent runtime. Those remain not tested. Hosting the gateway VM on
OpenShift does not count as testing the OpenShell Kubernetes driver: the
tested gateway has only the Podman driver configured.

## Validated API-key configuration

- Branch: `test/codex-api-key`; tested implementation: `ab85d08ad54a1dac06fbbf9123d1cdc46405c4b5`.
- Argo CD applications: `saw-tp-api-clean`, `saw-tp-api-clean-bom`, `saw-tp-api-clean-secrets`.
- Namespace: `saw-tp-api-clean`; VM: `tp-api-clean`; sandbox: `default/notebook`.
- Values: [`examples/values-secret-codex-tp.yaml`](../examples/values-secret-codex-tp.yaml).
- Profile selection: [`overrides/saw-bom-codex.yaml`](../overrides/saw-bom-codex.yaml).
- Fedora 44, Podman 5.8.1, OpenShell 0.1.2-rhaiv.0, OpenClaw 2026.9.6.
- Installer stages completed. All three Argo sync operations succeeded.
  The BOM and secrets applications were Synced/Healthy; the VM application was
  Healthy but still reported OutOfSync. The live VM's declared settings matched
  the chart render; KubeVirt had added generated default fields. Full Argo
  convergence is not claimed by this inference test.

After syncing and restarting the VM, the installed configuration was checked:
primary `openai/gpt-6-luna`, no configured fallback, gateway driver `podman`.
The headless test explicitly selected that same model:

```bash
make saw-vm-ssh OPENSHELL_SAW_NAME=tp-api-clean \
  CMD='openshell --gateway saw-installer sandbox exec --name notebook --workspace default --no-tty --timeout 120 -- env OPENCLAW_HOME=/sandbox SQLITE_TMPDIR=/sandbox/.openclaw/state TMPDIR=/sandbox/.openclaw/state OPENCLAW_NIX_MODE=0 openclaw agent exec --auth-env-only --model openai/gpt-6-luna --thinking low --timeout 60 --json "Reply with exactly SAW_TP_CODEX_API_OK. Do not use tools."'
```

The command exited successfully and reported `ok: true`, provider `openai`,
model `gpt-6-luna`, and final response `SAW_TP_CODEX_API_OK`. The result was
checked against both the configured model and expected response. An earlier
headless invocation without `--model` selected Astra; it is not counted as
Luna validation.

[Recorded test evidence](validation/codex-api-podman-2026-10-18.json).

## Parent epic

The parent epic has not been updated. Its issue key/URL was not supplied;
link this matrix from the parent epic when that destination is available.
