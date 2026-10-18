# Codex API-key provider

The `codex` SAW-BOM profile configures OpenClaw with an OpenShell provider
named `codex`, of type `codex`, using an OpenAI Platform API key. It follows
the same Secret, provider-profile and installer path as NVIDIA.

Select `profiles: [codex]` for the user in `overrides/saw-users.yaml`, or pass
[`overrides/saw-bom-codex.yaml`](../overrides/saw-bom-codex.yaml) to the
SAW-BOM chart. Configure the `inference` entry in your private values file:

```yaml
- name: inference
  fields:
    - name: provider
      value: codex
    - name: model
      value: gpt-6-luna
    - name: api_key
      path: ~/.openai-api-key
```

The model is read from the Secret's `model` field. The default is
`gpt-6-luna`. Do not put the actual key in Git. For an isolated test, use
[`examples/values-secret-codex.yaml`](../examples/values-secret-codex.yaml)
and set the user's `vaultPrefix` to `secret/data/hub/saw-tp-codex`.

The installer creates `openshell provider create --name codex --type codex`
and supplies `OPENAI_API_KEY` through the environment. The shipped Codex
API-key profile permits credential use on `api.openai.com:443` by the listed
OpenClaw/Node binaries. Without the governance interceptor, the installer
imports that profile into the gateway when it is missing, as for NVIDIA.

OpenClaw uses its canonical `openai` API-key transport and model reference
`openai/gpt-6-luna`; this does not rename the OpenShell provider. It does not
install a native Codex agent runtime or import the upstream Codex CLI OAuth
example. ChatGPT subscription/OAuth credentials are not used by this profile.

The TP test disables the optional policy server (`governance.enabled: false`)
and optional NemoClaw CLI (`bom.spec.nemoclaw: null`), per the parent spike's
scope. It uses the Podman driver inside the gateway VM. Installing that VM
on OpenShift does not validate OpenShell's Kubernetes driver.

For headless smoke tests, pass the configured model explicitly to
`openclaw agent exec --model openai/gpt-6-luna --auth-env-only --json` and
verify the returned model as well as the answer. A headless invocation
without `--model` may select its own default.
