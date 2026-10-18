# Codex API-key configuration for SAW

Select the SAW-BOM profile `codex` (see
[`overrides/saw-bom-codex.yaml`](../overrides/saw-bom-codex.yaml)) and configure
the `inference` secret:

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

For a pattern-managed user, set `profiles: [codex]` on that user's entry in
`overrides/saw-users.yaml`. The selected profile creates only the `default`
workspace and its OpenClaw `notebook` sandbox. It does not require a Brave key.

`codex` here is SAW's API-key choice, implemented using OpenShell's existing
`openai` provider named `openai`. OpenClaw calls `https://api.openai.com/v1`
with the selected model. The existing OpenAI governance profile restricts
credential use to that endpoint and the permitted binaries. This does not
configure OpenShell's `codex` OAuth profile or the native Codex agent runtime.
The API-key route and those integrations must be recorded separately in validation results.

The default `data-science` profile still uses NVIDIA. A `provider: codex`
secret is refused by that profile; select `profiles: [codex]` as well.

To test without replacing the shared NVIDIA secret, use the scoped values in
[`examples/values-secret-codex-tp.yaml`](../examples/values-secret-codex-tp.yaml)
and set the test user's `vaultPrefix` to `secret/data/hub/saw-tp-api-clean`.
The SSH key and ingress CA can continue to use the shared Vault prefix.
Store the actual key only in the private file referenced by `api_key.path`.

After changing credentials or profiles on an existing VM without live inputs,
sync its Argo CD applications and restart the VM to apply the mounted inputs.

For headless validation, pass the configured model explicitly to
`openclaw agent exec --model openai/gpt-6-luna`; the headless command can
otherwise choose its own default. Check the returned provider and model as
well as the answer. See the [validation matrix](provider-driver-matrix.md).
