ARG NODE_IMAGE=node:22-trixie-slim

FROM ${NODE_IMAGE} AS builder
ENV NPM_CONFIG_AUDIT=false \
    NPM_CONFIG_FUND=false \
    NPM_CONFIG_UPDATE_NOTIFIER=false
WORKDIR /opt/nemoclaw
COPY package.json package-lock.json ./
COPY nemoclaw/package.json nemoclaw/package-lock.json nemoclaw/tsconfig.json nemoclaw/tsconfig.shared.json ./nemoclaw/
RUN npm ci --ignore-scripts && cd nemoclaw && npm ci --ignore-scripts
COPY . .
ARG NEMOCLAW_VERSION
ARG SOURCE_REVISION
# The build context need not retain Git metadata, and package.json is not the release version.
RUN printf '%s\n' "$SOURCE_REVISION" | grep -Eq '^[0-9a-f]{40}$' \
    && printf '%s\n' "$NEMOCLAW_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
    && printf '%s\n' "$SOURCE_REVISION" > .source-revision \
    && printf '%s\n' "$NEMOCLAW_VERSION" > .version
# OpenShell 0.1.2 has mandatory provider policy and no Providers v2 switch.
RUN node -e 'const fs = require("fs"); \
    const file = "src/lib/adapters/openshell/provider-adapter-cli.ts"; \
    const source = fs.readFileSync(file, "utf8"); \
    const anchor = "          const value = document.settings?.providers_v2_enabled;"; \
    if (source.split(anchor).length !== 2) throw Error("Review NemoClaw provider policy compatibility patch"); \
    const added = String.raw` \
          if (document.scope === "global" && document.settings && \
              typeof document.settings === "object" && !Array.isArray(document.settings) && \
              !Object.hasOwn(document.settings, "providers_v2_enabled") && request.target.kind === "named") { \
            const info = invoke(["gateway", "info", "--output", "json"], request); \
            const error = commandError(info); \
            if (error) return failure<string>(error); \
            const gateway = JSON.parse(bufferOrStringToText(info.stdout)); \
            if (gateway.gateway === request.target.gatewayName && gateway.status === "healthy" && \
                typeof gateway.version === "string" && /^0\.1\.2(?:-rhaiv\.[0-9]+)?$/u.test(gateway.version)) \
              return success<string>("true"); \
          }`; \
    fs.writeFileSync(file, source.replace(anchor, anchor + added));'
RUN npm run build:cli

FROM ${NODE_IMAGE}
ARG MAX_OPENSHELL_VERSION=0.0.116
WORKDIR /opt/nemoclaw
COPY --from=builder /opt/nemoclaw/package.json /opt/nemoclaw/package-lock.json ./
COPY --from=builder /opt/nemoclaw/.version /opt/nemoclaw/.source-revision ./
RUN npm ci --omit=dev --ignore-scripts
COPY --from=builder /opt/nemoclaw/dist/ ./dist/
COPY --from=builder /opt/nemoclaw/bin/ ./bin/
COPY --from=builder /opt/nemoclaw/nemoclaw/dist/ ./nemoclaw/dist/
COPY --from=builder /opt/nemoclaw/agents/ ./agents/
COPY --from=builder /opt/nemoclaw/scripts/ ./scripts/
COPY --from=builder /opt/nemoclaw/nemoclaw-blueprint/ ./nemoclaw-blueprint/
COPY --from=builder /opt/nemoclaw/managed-inference/ ./managed-inference/
RUN sed -i "s/max_openshell_version: \"[^\"]*\"/max_openshell_version: \"${MAX_OPENSHELL_VERSION}\"/" ./nemoclaw-blueprint/blueprint.yaml \
    && grep -Fq "max_openshell_version: \"${MAX_OPENSHELL_VERSION}\"" ./nemoclaw-blueprint/blueprint.yaml
COPY --from=builder /opt/nemoclaw/schemas/ ./schemas/
COPY --from=builder /opt/nemoclaw/Dockerfile ./Dockerfile
COPY --from=builder /opt/nemoclaw/tsconfig.runtime-preloads.json ./tsconfig.runtime-preloads.json
ENTRYPOINT ["node", "/opt/nemoclaw/bin/nemoclaw.js"]
