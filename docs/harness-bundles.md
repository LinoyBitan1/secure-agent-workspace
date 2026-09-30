# Harness bundles: skills, MCP servers and tool plugins

A harness bundle is what an OpenClaw sandbox loads on top of its image:
skills, MCP servers and tool code. A SAW-BOM sandbox names one with
`harnessRef`, and the installer **mounts it read-only at `/sandbox/harness`,
exactly as written**. Nothing is copied into the sandbox with `sandbox exec`,
and nothing is converted: the files in the bundle are the files OpenClaw
reads.

How it is built: [harness-implementation.md](harness-implementation.md).

## Layout

```
harness-bundles/<bundle>/
  harness.yaml            kind HarnessBundle: name, version, governance (read by the installer only)
  plugin.json             Agent Plugins manifest: OpenClaw loads skills/ and mcp.json from the bundle root
  skills/<name>/SKILL.md  skills
  mcp.json                MCP servers
  mcp/…                   files a stdio MCP server runs (optional)
  plugins/<id>/           native OpenClaw plugins (tool code)
    package.json          "openclaw": { "extensions": ["./index.mjs"] }
    openclaw.plugin.json  id, contracts.tools
    index.mjs             calls api.registerTool(...)
```

`harness-bundles/ds-default` is the sample: the `pattern-author` skill, the
`saw-echo` tool plugin and a stdio `saw-mcp-echo` MCP server.

### MCP servers (`mcp.json`)

Agent Plugins format. Every server needs a `type`; OpenClaw ignores an entry
without one.

```json
{
  "$schema": "https://agent-plugins.org/schemas/1.0.0/mcp.schema.json",
  "mcpServers": {
    "local-tool": { "type": "stdio", "command": "node", "args": ["${PLUGIN_ROOT}/mcp/server.mjs"] },
    "local-mcp":  { "type": "streamable-http", "url": "http://my-mcp.mcp-servers.svc.cluster.local:8080/mcp" }
  }
}
```

| `type` | Fields | Runs |
|---|---|---|
| `stdio` | `command` (a bare name or `./`-relative), `args`, `env`, `cwd` | inside the sandbox |
| `streamable-http`, `sse` | `url`, `headers` | elsewhere; the sandbox connects to it |

The only placeholders are `${PLUGIN_ROOT}` and `${PLUGIN_DATA}`, so a bundle
cannot reference secrets. The agent sees a server's tools as
`<server>__<tool>`, e.g. `local-mcp__search`.

A remote server must be declared in `harness.yaml` with a governance profile,
and its host must be one of that profile's endpoints:

```yaml
spec:
  mcpServers:
    - name: local-mcp
      governanceProfile: local-mcp
```

Example, web search with Tavily's MCP server. It runs inside the sandbox;
`npx` fetches the package from `registry.npmjs.org` and the server calls
`api.tavily.com`, both endpoints of the `web-search` profile:

```json
"web-search": { "type": "stdio", "command": "npx", "args": ["-y", "tavily-mcp@0.2.22"] }
```

It reads `TAVILY_API_KEY` from its environment. How that key reaches the
server from the SAW's provider Secret is not verified yet, so `ds-default`
does not include it.

### Tool plugins (`plugins/<id>/`)

Plain ES modules (`.mjs`, or `.js` with `"type": "module"`), self-contained:
nothing runs `npm install`, so bundle any dependency into one file. A plugin
that makes network calls names a `governanceProfile` in `harness.yaml`
`spec.plugins`.

## Two ways to ship a bundle

### OCI image (recommended)

```yaml
harnessRef:
  image: ghcr.io/<owner>/saw-harness-ds-default@sha256:<digest>
```

The image is `FROM scratch` with the bundle tree at its root. The sandbox
mounts the image itself, read-only (podman image mount, the same idea as a
[Kubernetes image volume](https://kubernetes.io/docs/tasks/configure-pod-container/image-volumes/)).
Mounts are fixed when a sandbox is created, so **a new digest recreates the
sandbox**. Anything the agent wrote outside `/sandbox/persist` or other data
volumes is lost, as with a pod restart.

`.github/workflows/harness-bundles.yml` builds every `harness-bundles/<bundle>/`,
pushes `ghcr.io/<owner>/saw-harness-<bundle>:<version>` on `main`, signs the
digest with cosign, and prints the `harnessRef` in the job summary. Locally:

```bash
make -f Makefile-quickstart harness-bundle-build HARNESS_BUNDLE=ds-default
make -f Makefile-quickstart harness-bundle-push  HARNESS_BUNDLE=ds-default \
     HARNESS_REPO=ghcr.io/<owner>/saw-harness-ds-default
```

The gateway VM pulls as its runtime user, so the package must be public, or
the VM needs pull credentials for it.

### Inline, in the saw-bom chart

```yaml
harnessRef:
  name: ds-default
  # digest: sha256:…   optional; checked when set
```

The bundle lives in `charts/saw-bom/harness/<bundle>/` and ships in the
profiles ConfigMap. The installer copies it unchanged into the podman volume
`saw-harness-<workspace>-<sandbox>`, which is mounted read-only. **An edit
refills the volume; the running sandbox is kept** and sees the new files.
Limits: the 1 MiB ConfigMap size, and 64-character file keys
(`harness__<bundle>__<path>`).

## What happens at apply

For each sandbox with a `harnessRef`:

1. **Read the bundle**, without changing it: pull the image by digest and read
   `harness.yaml` and `mcp.json` from it, or take the inline bundle from the
   ConfigMap.
2. **Check governance** against the gateway's live catalog
   (`openshell provider list-profiles -o json`). Every `governanceProfile` must
   be served, and a remote MCP server's host must be one of its endpoints.
   Nothing is mounted before this passes.
3. **Inline only:** fill the volume if its content differs.
4. **Mount:** create the sandbox with the image or the volume at
   `/sandbox/harness`. A running sandbox that mounts something else (an older
   digest, or no harness at all) is recreated.
5. **Configure OpenClaw once:** `plugins.load.paths` gets `/sandbox/harness`
   (skills and MCP servers) and `/sandbox/harness/plugins` (every tool
   plugin). A bundle without `plugin.json` uses `skills.load.extraDirs`.
6. **Verify:** the container mounts the pinned source, and the sandbox reads
   the same content through it. `status.json` records the source as
   `appliedRevision`.
