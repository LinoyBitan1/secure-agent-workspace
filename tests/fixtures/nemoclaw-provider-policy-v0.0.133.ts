// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0
// Exact provider policy prerequisite from NemoClaw v0.0.133.
  const ensureProviderPolicyComposition: OpenShellProviderAdapter["ensureProviderPolicyComposition"] =
    async (request) => {
      const targetError = namedGatewayEndpointOverrideError(request.target, environment);
      if (targetError) return failure(targetError);
      const read = () => {
        const result = invoke(["settings", "get", "--global", "--json"], request);
        const error = commandError(result);
        if (error) return failure<string>(error);
        try {
          const document = JSON.parse(bufferOrStringToText(result.stdout));
          const value = document.settings?.providers_v2_enabled;
          if (document.scope === "global" && ["true", "false", "<unset>"].includes(value)) {
            return success<string>(value);
          }
        } catch {
          /* Fail closed on incompatible settings output. */
        }
        return failure<string>({
          kind: "schema",
          message: "OpenShell did not return the global provider policy setting.",
        });
      };
      const before = read();
      if (!before.ok) return before;
      if (before.value === "true") return success(undefined);
      if (before.value === "false") {
        return failure({
          kind: "command",
          reason: "conflict",
          message:
            "Native NVIDIA inference requires provider-derived policy, but providers_v2_enabled is explicitly disabled on this gateway. Ask the gateway administrator to enable it.",
        });
      }
      // OpenShell 0.0.116 defaults this gate off. Preserve explicit administrator
      // choices; enable only its unset default before publishing a native provider.
      const updated = invoke(
        [
          "settings",
          "set",
          "--global",
          "--key",
          "providers_v2_enabled",
          "--value",
          "true",
          "--yes",
        ],
        request,
      );
      const error = commandError(updated);
      if (error) return failure(error);
      const after = read();
      if (!after.ok) return after;
      return after.value === "true"
        ? success(undefined)
        : failure({
            kind: "command",
            reason: "uncertain",
            message:
              "OpenShell did not confirm provider-derived policy activation. Inspect gateway settings before retrying.",
          });
    };

