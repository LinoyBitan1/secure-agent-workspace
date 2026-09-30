"""Harness bundles reach the sandbox only as a read-only mount at /sandbox/harness.

Two sources, both mounted exactly as written (nothing is converted):

- harnessRef.image: an OCI image pinned by digest, mounted with podman's
  image mount (like a Kubernetes image volume). Mounts are fixed when a
  sandbox is created, so a new digest recreates the sandbox.
- harnessRef.name: an inline bundle from the saw-bom ConfigMap, copied
  unchanged into a named volume that is mounted; an edit refills the volume
  and the running sandbox keeps going.

The fakes model what was checked live on OpenShell 0.0.116 / podman 5.8:
the fake openshell records --driver-config-json, the fake podman lists
sandbox containers by their openshell.ai/* labels and reports their
`.Mounts`, and `sandbox exec cat` reads through the mount.
"""
import json

import pytest
import yaml

from test_apply_profiles import creds, make_applier, profiles  # noqa: F401 (fixtures)

IMAGE_V1 = "ghcr.io/example/saw-harness-demo@sha256:" + "1" * 64
IMAGE_V2 = "ghcr.io/example/saw-harness-demo@sha256:" + "2" * 64
VOLUME = "saw-harness-default-notebook"


def manifest(**spec):
    return yaml.safe_dump({"apiVersion": "saw.redhat.com/v1alpha1", "kind": "HarnessBundle",
                           "metadata": {"name": "demo"}, "spec": {"agent": "openclaw", **spec}})


V1 = {"harness.yaml": manifest(version="1"), "plugin.json": '{"name": "demo"}',
      "skills/demo/SKILL.md": "---\nname: demo\ndescription: v1\n---\n",
      "plugins/old-tool/index.mjs": "export default {id: 'old-tool'}\n",
      "mcp.json": json.dumps({"mcpServers": {"echo": {"type": "stdio", "command": "node"}}})}
V2 = {**V1, "harness.yaml": manifest(version="2"),
      "skills/demo/SKILL.md": "---\nname: demo\ndescription: v2\n---\n"}


def use_ref(profiles, ref):
    for profile in profiles:
        for ws in profile.workspaces:
            for sb in ws.sandboxes:
                if sb.name == "notebook":
                    sb.harness_ref = ref
    return profiles


def notebook(fake_env):
    return fake_env.openshell_state()["sandboxes"]["default/notebook"]


def notebook_creates(fake_env):
    return [c for c in fake_env.openshell_calls()
            if c[:2] == ["sandbox", "create"] and "notebook" in c]


def podman_ops(fake_env):
    return [json.loads(line) for line in (fake_env.state / "podman.log").read_text().splitlines()]


def mcp_tree(url, profile="web-search"):
    return {**V1, "harness.yaml": manifest(mcpServers=[{"name": "search", "governanceProfile": profile}]),
            "mcp.json": json.dumps({"mcpServers": {"search": {"type": "streamable-http", "url": url}}})}


# -- OCI image: image mount -----------------------------------------------------

def test_an_image_is_mounted_directly(ab, fake_env, config, profiles, creds):
    """No copy and no volume: the sandbox mounts the pinned image read-only."""
    fake_env.set_images({IMAGE_V1: {"__tree__": V1}})
    applier = make_applier(ab, config, creds)
    applier.apply(use_ref(profiles, {"image": IMAGE_V1}))
    assert notebook(fake_env)["driverConfig"] == {"podman": {"mounts": [{
        "type": "image", "source": IMAGE_V1, "target": "/sandbox/harness", "read_only": True}]}}
    assert not (fake_env.state / "volumes" / VOLUME).exists()
    assert ["pull", "--quiet", IMAGE_V1] in podman_ops(fake_env)
    assert applier.verify(profiles) == []


def test_a_present_image_is_not_pulled_again(ab, fake_env, config, profiles, creds):
    fake_env.set_images({IMAGE_V1: {"__tree__": V1}})
    use_ref(profiles, {"image": IMAGE_V1})
    make_applier(ab, config, creds).apply(profiles)
    make_applier(ab, config, creds).apply(profiles)
    assert sum(op[:1] == ["pull"] and op[-1] == IMAGE_V1 for op in podman_ops(fake_env)) == 1


def test_an_unchanged_image_keeps_the_sandbox(ab, fake_env, config, profiles, creds):
    fake_env.set_images({IMAGE_V1: {"__tree__": V1}})
    use_ref(profiles, {"image": IMAGE_V1})
    make_applier(ab, config, creds).apply(profiles)
    make_applier(ab, config, creds).apply(profiles)
    assert len(notebook_creates(fake_env)) == 1
    assert ["sandbox", "delete", "notebook"] not in fake_env.openshell_calls()


def test_a_new_image_digest_recreates_the_sandbox(ab, fake_env, config, profiles, creds):
    """Mounts are fixed at create, as for a Kubernetes image volume."""
    fake_env.set_images({IMAGE_V1: {"__tree__": V1}, IMAGE_V2: {"__tree__": V2}})
    make_applier(ab, config, creds).apply(use_ref(profiles, {"image": IMAGE_V1}))
    applier = make_applier(ab, config, creds)
    applier.apply(use_ref(profiles, {"image": IMAGE_V2}))
    assert ["sandbox", "delete", "notebook"] in fake_env.openshell_calls()
    assert len(notebook_creates(fake_env)) == 2
    assert notebook(fake_env)["driverConfig"]["podman"]["mounts"][0]["source"] == IMAGE_V2
    assert applier.verify(profiles) == []


def test_a_sandbox_created_before_its_harness_is_recreated(ab, fake_env, config, profiles, creds):
    fake_env.set_images({IMAGE_V1: {"__tree__": V1}})
    make_applier(ab, config, creds).apply(use_ref(profiles, {}))
    assert "driverConfig" not in notebook(fake_env)
    applier = make_applier(ab, config, creds)
    applier.apply(use_ref(profiles, {"image": IMAGE_V1}))
    assert notebook(fake_env)["driverConfig"]["podman"]["mounts"][0]["type"] == "image"
    assert applier.verify(profiles) == []


def test_verify_reports_a_sandbox_that_mounts_another_image(ab, fake_env, config, profiles, creds):
    fake_env.set_images({IMAGE_V1: {"__tree__": V1}, IMAGE_V2: {"__tree__": V2}})
    make_applier(ab, config, creds).apply(use_ref(profiles, {"image": IMAGE_V1}))
    failures = make_applier(ab, config, creds).verify(use_ref(profiles, {"image": IMAGE_V2}))
    assert any("is not mounted from image " + IMAGE_V2 in f for f in failures), failures


# -- inline bundle: named volume -------------------------------------------------

def _inline(ab, name, tree):
    files = {f"harness__{name}__{rel.replace('/', '__')}": text.encode() for rel, text in tree.items()}
    return {"bundles": ab.parse_harness_files(files)}


def test_an_inline_bundle_is_mounted_from_a_volume(ab, fake_env, config, profiles, creds):
    applier = make_applier(ab, config, creds, harness=_inline(ab, "demo", V1))
    applier.apply(use_ref(profiles, {"name": "demo"}))
    mount = notebook(fake_env)["driverConfig"]["podman"]["mounts"][0]
    assert (mount["type"], mount["source"]) == ("volume", VOLUME)
    volume = fake_env.state / "volumes" / VOLUME
    assert (volume / "skills/demo/SKILL.md").read_text() == V1["skills/demo/SKILL.md"]
    assert applier.verify(profiles) == []


def test_an_edited_inline_bundle_refills_the_volume_in_place(ab, fake_env, config, profiles, creds):
    use_ref(profiles, {"name": "demo"})
    make_applier(ab, config, creds, harness=_inline(ab, "demo", V1)).apply(profiles)
    edited = {k: v for k, v in V2.items() if not k.startswith("plugins/old-tool/")}
    applier = make_applier(ab, config, creds, harness=_inline(ab, "demo", edited))
    applier.apply(profiles)
    volume = fake_env.state / "volumes" / VOLUME
    assert "v2" in (volume / "skills/demo/SKILL.md").read_text()
    assert not (volume / "plugins/old-tool").exists(), "a dropped file must not linger"
    assert len(notebook_creates(fake_env)) == 1, "the running sandbox keeps its mount"
    assert applier.verify(profiles) == []


def test_a_tampered_inline_volume_is_reported_and_refilled(ab, fake_env, config, profiles, creds):
    use_ref(profiles, {"name": "demo"})
    harness = _inline(ab, "demo", V1)
    make_applier(ab, config, creds, harness=harness).apply(profiles)
    skill = fake_env.state / "volumes" / VOLUME / "skills/demo/SKILL.md"
    skill.write_text("tampered")
    applier = make_applier(ab, config, creds, harness=harness)
    assert applier.verify(profiles), "verify must notice the edited volume"
    applier.apply(profiles)
    assert skill.read_text() == V1["skills/demo/SKILL.md"]
    assert applier.verify(profiles) == []


# -- governance: checked before anything is mounted -------------------------------

def test_an_unserved_governance_profile_stops_before_the_sandbox_is_created(
        ab, fake_env, config, profiles, creds):
    tree = {**V1, "harness.yaml": manifest(plugins=[{"name": "old-tool", "governanceProfile": "nope"}])}
    fake_env.set_images({IMAGE_V1: {"__tree__": tree}})
    with pytest.raises(ab.InstallerError, match="'nope', which the gateway does not serve"):
        make_applier(ab, config, creds).apply(use_ref(profiles, {"image": IMAGE_V1}))
    assert not notebook_creates(fake_env)


def test_a_remote_mcp_server_outside_its_profile_is_refused(ab, fake_env, config, profiles, creds):
    """#53's example pointed at search.internal: refused, never mounted."""
    fake_env.set_images({IMAGE_V1: {"__tree__": mcp_tree("https://search.internal/v1/mcp")}})
    with pytest.raises(ab.InstallerError, match="reaches search.internal, which governanceProfile "
                                                "'web-search' does not allow"):
        make_applier(ab, config, creds).apply(use_ref(profiles, {"image": IMAGE_V1}))
    assert not notebook_creates(fake_env)


def test_a_remote_mcp_server_inside_its_profile_is_accepted(ab, fake_env, config, profiles, creds):
    fake_env.set_images({IMAGE_V1: {"__tree__": mcp_tree("https://api.tavily.com/mcp")}})
    applier = make_applier(ab, config, creds)
    applier.apply(use_ref(profiles, {"image": IMAGE_V1}))
    assert applier.verify(profiles) == []


def test_the_catalog_is_read_from_the_gateway_once(ab, fake_env, config, profiles, creds):
    tree = {**V1, "harness.yaml": manifest(plugins=[{"name": "old-tool", "governanceProfile": "web-search"}])}
    fake_env.set_images({IMAGE_V1: {"__tree__": tree}})
    make_applier(ab, config, creds).apply(use_ref(profiles, {"image": IMAGE_V1}))
    calls = [c for c in fake_env.openshell_calls() if c[:2] == ["provider", "list-profiles"]]
    assert calls == [["provider", "list-profiles", "-o", "json"]]


# -- OpenClaw is pointed at the mount ---------------------------------------------

def test_openclaw_loads_the_bundle_from_the_mount(ab, fake_env, config, profiles, creds):
    fake_env.set_images({IMAGE_V1: {"__tree__": V1}})
    make_applier(ab, config, creds).apply(use_ref(profiles, {"image": IMAGE_V1}))
    scripts = "\n".join(c[-1] for c in fake_env.openshell_calls() if c[:2] == ["sandbox", "exec"])
    assert """openclaw config set plugins.load.paths '["/sandbox/harness", "/sandbox/harness/plugins"]'""" in scripts
    assert "base64 -d" not in scripts, "bundle files never go through exec"


# -- stdio MCP server secrets: resolved admin-side, injected at onboard time -----

def test_a_stdio_secret_is_set_as_an_openclaw_env_ref_and_exported_at_gateway_start(
        ab, fake_env, config, profiles, creds):
    tree = {**V1, "harness.yaml": yaml.safe_dump({
        "apiVersion": "saw.redhat.com/v1alpha1", "kind": "HarnessBundle",
        "metadata": {"name": "demo"},
        "spec": {"agent": "openclaw", "mcpServers": [
            {"name": "echo", "credentialSecret": "tavily", "credentialSecretKey": "api_key",
             "credentialEnvVar": "TAVILY_API_KEY"}]}})}
    harness = _inline(ab, "demo", tree)
    harness["mcpSecrets"] = {"demo": {"echo": "tvly-TEST-KEY"}}
    make_applier(ab, config, creds, harness=harness).apply(use_ref(profiles, {"name": "demo"}))
    scripts = [c[-1] for c in fake_env.openshell_calls()
              if c[:2] == ["sandbox", "exec"] and c[3] == "notebook"]
    config_set = "\n".join(scripts)
    assert ('openclaw config set mcp.servers.echo.env.TAVILY_API_KEY '
            '\'{"source": "env", "provider": "default", "id": "TAVILY_API_KEY"}\'') in config_set
    gateway_run = next(s for s in scripts if "nohup openclaw gateway run" in s)
    assert "export TAVILY_API_KEY=tvly-TEST-KEY" in gateway_run
    assert "tvly-TEST-KEY" not in "\n".join(
        " ".join(c) for c in fake_env.openshell_calls() if c[:2] != ["sandbox", "exec"]), \
        "the raw key never appears outside the sandbox-exec command it's exported in"
