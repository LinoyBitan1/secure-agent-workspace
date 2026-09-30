# Harness bundles: implementation

How an agent sandbox gets its skills, MCP servers and tool plugins: what is
built, where each piece lives, and what was checked live. It builds on PR #53
(harness bundles in SAW-BOM) and replaces its `sandbox exec` copier. For
authoring and publishing a bundle, see [harness-bundles.md](harness-bundles.md).

**Status:** implemented on `feat/harness-oci-mount` (on top of PR #53).
The mount mechanics were checked live on OpenShell 0.0.116 and OpenClaw
2026.9.5 with throwaway sandboxes. An agent turn that calls a bundle tool,
and a full run of this branch on the cluster, are still to do.

## 1. Summary

A **harness bundle** is a directory tree in the layout OpenClaw loads:
`plugin.json`, `skills/`, `mcp.json`, `plugins/`. A SAW-BOM sandbox names one
with `harnessRef`, and it reaches the sandbox **only as a read-only mount at
`/sandbox/harness`, exactly as written**:

| `harnessRef` | Source | Mounted as | On a change |
|---|---|---|---|
| `image: <repo>@sha256:…` | OCI image built from `harness-bundles/` by CI, published to GHCR | the image itself (podman image mount, like a Kubernetes image volume) | new digest → sandbox recreated |
| `name: <bundle>` | inline, `charts/saw-bom/harness/<bundle>/` in the profiles ConfigMap | a podman named volume holding the files unchanged | volume refilled; sandbox kept |

OpenClaw is configured once to load from `/sandbox/harness`. Governance is
checked against the gateway's live provider-profile catalog before anything
is mounted.

## 2. What changed from PR #53

| PR #53 | Now |
|---|---|
| Files base64-piped into the sandbox with `sandbox exec … sh -c 'base64 -d > <path>'` | Mounted read-only; nothing is written inside the sandbox |
| Staged under `/sandbox/.openclaw/{skills,tools}`, wiped each reconcile | `/sandbox/harness`, which the sandbox can only read |
| `tools/*.yaml` copied, never read by OpenClaw | MCP servers in `mcp.json`, code tools in `plugins/<id>/` (`.mjs`), both loaded by OpenClaw from the mount |
| Only inline bundles (1 MiB ConfigMap, 64-character keys) | Also OCI images with no size or name limits, mounted directly |
| `governanceProfiles` list kept in saw-bom values; name check only | Live catalog from the gateway; remote MCP hosts checked against the profile's endpoints |
| `harnessRef.digest` required | Optional for inline bundles; the image digest is the pin for OCI |
| Unquoted paths in shell commands | No shell involved in delivering files |

## 3. Architecture

```
 Git
 ├─ harness-bundles/<bundle>/ ──(CI: harness-bundles.yml)──► ghcr.io/<owner>/saw-harness-<bundle>@sha256:…
 └─ charts/saw-bom/
    ├─ harness/<bundle>/ ──► profiles ConfigMap keys harness__<bundle>__<path> (base64)
    └─ profiles/…/sandbox.yaml: harnessRef {image} or {name}
                    │
                    ▼  Argo CD → ConfigMap → disk (or virtiofs) → /run/saw/profiles
 Gateway VM: apply_bom.py apply-profiles, as the runtime user (rootless podman)
   1. read      image: podman pull + export (read only) │ inline: ConfigMap files
   2. govern    openshell provider list-profiles -o json
   3. inline    fill volume saw-harness-<ws>-<sandbox> (unchanged files + marker)
   4. mount     sandbox create --driver-config-json {podman.mounts: [image|volume → /sandbox/harness, ro]}
                a running sandbox mounting something else is deleted and recreated
   5. configure openclaw config set plugins.load.paths …
   6. verify    podman inspect .Mounts + read back through the mount
                    │
                    ▼
 Sandbox container (OpenShell podman driver)
   /sandbox/harness  (read-only)  plugin.json  skills/  mcp.json  mcp/  plugins/<id>/
   OpenClaw: Agent Plugins bundle at /sandbox/harness (skills + MCP servers),
             native plugins under /sandbox/harness/plugins
```

## 4. Bundle format

```
<bundle>/
  harness.yaml            kind HarnessBundle; read only by the installer
  plugin.json             Agent Plugins manifest
  skills/<name>/SKILL.md
  mcp.json                MCP servers (Agent Plugins 1.0.0)
  mcp/…                   files a stdio MCP server runs
  plugins/<id>/           native OpenClaw plugins
    package.json          "openclaw": {"extensions": ["./index.mjs"]}
    openclaw.plugin.json  id, contracts.tools
    index.mjs             api.registerTool(...)
```

### `harness.yaml`

OpenClaw never reads it. The installer uses it for metadata and governance:

```yaml
apiVersion: saw.redhat.com/v1alpha1
kind: HarnessBundle
metadata:
  name: ds-default
spec:
  agent: openclaw              # only openclaw is supported
  version: 0.1.0               # image tag used by CI
  plugins:                     # plugins that make network calls
    - name: my-plugin
      governanceProfile: github
  mcpServers:                  # remote (HTTP) servers in mcp.json
    - name: local-mcp
      governanceProfile: local-mcp
```

### MCP servers

OpenClaw reads them from the Agent Plugins bundle's `mcp.json`. Each entry
needs a `type`; OpenClaw 2026.9.5 drops entries without one, so the installer
refuses them:

| `type` | Fields | Runs |
|---|---|---|
| `stdio` | `command` (bare name or `./`-relative), `args`, `env`, `cwd` | inside the sandbox, under OpenShell's policy |
| `streamable-http`, `sse` | `url`, `headers` | remote; the sandbox connects to it |

`${PLUGIN_ROOT}` and `${PLUGIN_DATA}` are the only placeholders, so secrets
cannot be referenced. The agent sees a server's tools as `<server>__<tool>`.

### Tool plugins

Self-contained ES modules; nothing runs `npm install`. OpenClaw finds every
plugin under `plugins/` from one load path, so adding or removing a plugin
needs no config change.

## 5. Building and publishing

| Piece | What it does |
|---|---|
| `harness-bundles/Containerfile` | `FROM scratch`, `COPY . /`: the bundle tree is the image root, which is what gets mounted |
| `.github/workflows/harness-bundles.yml` | For each `harness-bundles/<bundle>/`: checks `harness.yaml`, the `mcp.json` types and that there are no links; builds; on `main` pushes `ghcr.io/<owner>/saw-harness-<bundle>:<version>` and `:sha-<commit>`, signs the digest with cosign (keyless), writes the `harnessRef` to the job summary. Pull requests build only. |
| `scripts/harness-bundle.sh` | `build`, `push` (prints the `harnessRef`), `ref` |
| `make harness-bundle-build` / `harness-bundle-push` | Wrappers (`HARNESS_BUNDLE`, `HARNESS_REPO`) |

`charts/saw-bom/harness/ds-default` (inline) and `harness-bundles/ds-default`
(OCI) hold the same tree; `test_chart_bundle_matches_the_published_bundle`
keeps them equal.

## 6. Referencing a bundle (`sandbox.yaml`)

```yaml
harnessRef:
  image: ghcr.io/<owner>/saw-harness-ds-default@sha256:<64 hex>
```

```yaml
harnessRef:
  name: ds-default
  # digest: sha256:…     optional; checked when set
```

`image` and `name` are mutually exclusive. The saw-bom chart fails the render
for an unpinned image, for both at once, or for a digest that does not match.
It ships only the inline bundles that some `harnessRef.name` uses.

## 7. Installer (`apply_bom.py`)

Everything below runs in `apply-profiles` as the runtime user (`cloud-user`),
in the same rootless podman that OpenShell's podman driver runs sandboxes in.
The module comment above `HARNESS_MOUNT` lists the steps and the functions
that implement them.

### 7.1 Validation, before anything changes (`validate_harness`)

- only `openclaw` sandboxes may have a `harnessRef`;
- `image` must be `repo@sha256:<64 hex>`, and not combined with `name`/`digest`;
- `name` must be a delivered inline bundle; `digest`, when set, must match.

Returns `{sandbox: source}` for `status.json` `appliedRevision`.

### 7.2 Reading the bundle (`prepare_harness`)

Called from `create_sandbox`, before the sandbox is created or checked.

- **Image:** `podman image exists`, else `podman pull --quiet <image>`; then
  `podman create` + `podman export` and `read_harness_tar()`. This keeps
  regular files, skips AppleDouble `._*`, refuses links, devices and `..`
  paths, and requires `/harness.yaml`. The export is only read; the sandbox
  mounts the image.
- **Inline:** decoded from the ConfigMap keys. `HarnessVolume.current()` says
  whether the volume already holds exactly this source, intact.

### 7.3 Governance (`check_harness_governance`)

`describe_harness_tree()` lists what needs a profile:

- plugins with a `governanceProfile` in `harness.yaml`;
- every remote MCP server in `mcp.json`, with the host of its `url`. Its
  profile comes from `harness.yaml` `spec.mcpServers`, and one is required;
- stdio servers need none: they run inside the sandbox, where OpenShell's
  policy governs what they reach.

The catalog is read once per apply with
`openshell provider list-profiles -o json` (`parse_profile_catalog()` →
`{id: {endpoint hosts}}`). A profile the gateway does not serve, or a host
that is not one of its endpoints, stops the apply **before anything is
mounted**. If the catalog cannot be read, the harness is refused (fail
closed). Because it asks the gateway, it works the same with the governance
interceptor and with APF.

### 7.4 Inline volume (`HarnessVolume`)

- volume `saw-harness-<workspace>-<sandbox>` (`podman volume create --ignore`);
- when the content differs: wipe (in Python; `podman unshare rm -rf` for
  anything not owned by the runtime user), then `podman volume import` a
  tarball from `write_harness_tar()`. The tarball holds the bundle files
  unchanged, uid/gid 0 (the runtime user on the host), directories 0755,
  files 0644 (0755 if executable), and the marker `.saw-harness-revision`:
  `{"source": "bundle:<name>@<digest>", "treeDigest": …}`.

`treeDigest` is PR #53's `tree_digest`, so a volume edited on the VM is
detected (`verify`) and refilled on the next apply.

### 7.5 Mounting (`create_sandbox`, `harness_mount_ok`)

```
openshell sandbox create --name <sb> … --driver-config-json \
  '{"podman":{"mounts":[{"type":"image","source":"<repo>@sha256:…","target":"/sandbox/harness","read_only":true}]}}'
```

For an inline bundle, `"type":"volume","source":"saw-harness-<ws>-<sb>"`.

Mounts are fixed at creation, so for a sandbox that already runs,
`harness_mount_ok()` compares its container's mount with the desired one.
`sandbox_harness_mount()` finds the container by its labels
`openshell.ai/sandbox-name` and `openshell.ai/sandbox-workspace`. It reads
`podman inspect --format '{{json .Mounts}}'`, where an image mount is
`{"Type":"image","Source":"<the image reference given at create>"}` and a
volume is `{"Type":"volume","Name":"<volume>"}`. When they differ (an older
digest, or no harness mount at all), the sandbox is deleted and created again
with the right mount. OpenShell itself mounts its supervisor image into every
sandbox the same way (`/opt/openshell/bin`).

The start-up `chown` of `/sandbox` skips the read-only mount (`find … -prune`).

### 7.6 OpenClaw configuration (`configure_harness`)

From `openclaw_harness_config()`, set with `openclaw config set` during
onboarding:

| Bundle has | Setting |
|---|---|
| `plugin.json` | `plugins.load.paths` += `/sandbox/harness` (skills and `mcp.json`) |
| no `plugin.json`, but `skills/` | `skills.load.extraDirs = ["/sandbox/harness/skills"]` |
| `plugins/` | `plugins.load.paths` += `/sandbox/harness/plugins` |

Config only; bundle content never goes through `exec`. `plugins.allow` is
deliberately not set: it would restrict every plugin, and it warns about
stale entries when a plugin is removed.

### 7.7 Verification (`verify_harness`)

- **Image:** the container mounts exactly the pinned image reference, and
  `cat /sandbox/harness/harness.yaml` in the sandbox matches the image's.
- **Inline:** the volume holds the source intact (`HarnessVolume.verify`), the
  container mounts that volume, and `cat /sandbox/harness/.saw-harness-revision`
  matches the marker.

Failures join the normal verification list, so the SAW is not marked ready.

### 7.8 Removed

`HarnessAdapter` (exec staging, wipe targets, in-sandbox hashing),
`reconcile_harness`, `governanceProfiles` in saw-bom values with its render
check, and `enrolledGovernanceProfiles` in `harness-index.yaml`.

## 8. Lifecycle

| Event | What happens |
|---|---|
| First apply | Bundle read, governance checked, (inline: volume filled), sandbox created with the mount, OpenClaw configured |
| Re-apply, nothing changed | Image present and mounted, or volume intact: no pull, no write, sandbox kept |
| New image digest | Sandbox deleted and recreated with the new image (like a pod restart) |
| Inline bundle edited | Volume wiped and refilled; running sandbox sees it; OpenClaw reloads skills and plugins, MCP servers apply from the next session |
| Sandbox created before its `harnessRef` | Recreated with the mount on the next apply |
| Volume edited on the VM | Verify fails; next apply refills it |
| `harnessRef` removed | The mount stays until the sandbox is recreated |

With `vm.liveInputs` (PR #54), a saw-bom change reaches the VM over virtiofs
and reconcile runs apply, so neither kind of update needs a VM restart.

## 9. Security properties

- The sandbox cannot change its harness: both mounts are read-only.
- An OCI bundle is pinned by digest, and what is mounted is exactly what was
  published. CI signs it with cosign; the installer does not verify that
  signature yet. PR #54's per-pull signature policy is the place to add it
  (`harnessRef.signature`).
- Only regular files are read from an image for governance; links and `..`
  paths are refused.
- Governance comes from the gateway's live catalog and endpoint hosts, not a
  list in the same repository as the bundle.
- Secrets are not part of bundles (§11 for stdio server keys).
- `npx`-style servers fetch code at run time, outside the digest. Vendor the
  package into the bundle when that matters.

## 10. Tests

`make test-installer`: 222 installer tests and 86 chart tests.

| File | Covers |
|---|---|
| `tests/installer/test_harness.py` | digest contract; validation (optional digest, image pinning, `name`/`image` exclusivity); reading an image root tree (links, `..`, AppleDouble, missing manifest); the inline volume tarball's ownership and modes; the `--driver-config-json` shape; OpenClaw config; `mcp.json` types; remote server and plugin governance; catalog parsing; inline and published bundles identical |
| `tests/installer/test_harness_mount.py` | image mounted directly (no volume); no second pull; unchanged image keeps the sandbox; new digest recreates it; sandbox without a harness recreated; verify catches another image; inline volume mounted, refilled in place (dropped files removed, sandbox kept), tamper detected and repaired; unserved profile and `search.internal` refused before anything is created; catalog read once; OpenClaw config set with no exec copies |
| `tests/installer/test_apply_profiles.py` | full apply mounts the inline `ds-default` into `notebook`; a denied `openclaw` does not affect harness delivery |
| `tests/charts/test_saw_bom_chart.py` | no governance list in the chart; optional digest; image refs render without shipping a bundle; unpinned image fails |

The fakes model what was checked live: the fake openshell records
`--driver-config-json` and serves `sandbox exec cat` through the mount; the
fake podman lists sandbox containers by their `openshell.ai/*` labels,
reports `.Mounts` in podman 5.8's shape, exports image trees, and keeps
volumes as directories.

## 11. Checked live, and open items

**Checked** (OpenShell 0.0.116-rhaiv.0, podman 5.8.1, OpenClaw 2026.9.5):

- `--driver-config-json` image and volume mounts, read-only in the sandbox.
  The CLI marks the flag experimental.
- How podman reports them: `.Mounts` with `Type: image` and `Source` set to
  the reference given at create; the container labels
  `openshell.ai/sandbox-name` and `openshell.ai/sandbox-workspace`.
- A skill loaded from the mount and visible to the model.
- An Agent Plugins bundle detected from `plugins.load.paths`, with its MCP
  servers listed (once each entry has a `type`).
- Two tool plugins loaded from one parent path.
- A volume refill seen by the running sandbox: a removed plugin gone, a skill
  at its new version, a new MCP server listed.
- `openshell provider list-profiles -o json` returns ids and endpoint hosts.

**Open:**

1. A full run of this branch on the cluster: first apply, recreate on a new
   digest, and recreating the existing `notebook` once.
2. An agent turn that calls a bundle MCP tool and a plugin tool.
3. Pulling a public image from GHCR in the VM (the probes used local images).
4. How a stdio MCP server's key (e.g. `TAVILY_API_KEY`) reaches it from the
   SAW's provider Secret.
5. Whether the governance interceptor's profiles accept `protocol: mcp` with
   `rules`, for remote MCP servers (the fallback is `rest` with `read-write`).
6. Reaching an in-cluster MCP Service from inside a sandbox.
7. Verifying the bundle image's cosign signature at pull time (after PR #54).

## 12. Files

| Area | Files |
|---|---|
| Installer | `charts/openshell-saw/files/installer/apply_bom.py` |
| Chart | `charts/saw-bom/templates/configmap-bom.yaml`, `values.yaml`, `harness/ds-default/`, `profiles/data-science/default/sandbox.yaml` |
| Bundles | `harness-bundles/Containerfile`, `harness-bundles/ds-default/` |
| Build | `.github/workflows/harness-bundles.yml`, `scripts/harness-bundle.sh`, `Makefile-quickstart` |
| Tests | `tests/installer/test_harness.py`, `test_harness_mount.py`, `test_apply_profiles.py`, `fakes/podman`, `fakes/openshell`, `tests/charts/test_saw_bom_chart.py` |
| Docs | `docs/harness-bundles.md` (usage), this file, `README.md` |
