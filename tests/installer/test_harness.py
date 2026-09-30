"""Harness bundle contract: digest, parsing, packaging invariants."""

import base64
import hashlib
import json
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[2]
HARNESS = ROOT / "charts" / "saw-bom" / "harness"


def test_tree_digest_matches_shared_vector(ab):
    assert ab.tree_digest({"harness.yaml": b"a: 1\n"}) == (
        "sha256:66e30fc612bf7f99db4ac9dcdb9319f93c2ddcdbd4aa059edd554b683611aa9e")


def test_tree_digest_survives_base64_round_trip(ab):
    """Regression: the ConfigMap payload must be b64, not a block scalar.
    A file with no trailing newline must hash identically after transport."""
    raw = {"SKILL.md": b"no trailing newline"}
    wire = {k: base64.b64encode(v).decode() for k, v in raw.items()}
    back = {k: base64.b64decode(v) for k, v in wire.items()}
    assert ab.tree_digest(raw) == ab.tree_digest(back)


def test_tree_digest_is_order_independent(ab):
    a = {"b.txt": b"2", "a.txt": b"1"}
    b = {"a.txt": b"1", "b.txt": b"2"}
    assert ab.tree_digest(a) == ab.tree_digest(b)


def test_bundle_files_are_utf8_text():
    """`.Files.Get` is not binary-safe, so bundles are text-only."""
    for p in HARNESS.rglob("*"):
        if p.is_file():
            p.read_text(encoding="utf-8")


def test_bundle_keys_fit_the_iso9660_joliet_limit():
    """KubeVirt renders the ConfigMap as an iso9660 disk; Joliet caps
    filenames at 64 characters."""
    for p in HARNESS.rglob("*"):
        if p.is_file():
            key = "harness__" + str(p.relative_to(HARNESS)).replace("/", "__")
            assert len(key) <= 64, key


def test_bundle_path_segments_have_no_double_underscore():
    """`__` is the flat-key separator; a segment containing it is ambiguous."""
    for p in HARNESS.rglob("*"):
        for part in p.relative_to(HARNESS).parts:
            assert "__" not in part, p


def test_parse_harness_files_reads_spec(ab):
    manifest = yaml.safe_dump({
        "apiVersion": "saw.redhat.com/v1alpha1", "kind": "HarnessBundle",
        "metadata": {"name": "demo"},
        "spec": {"agent": "openclaw",
                 "skills": [{"name": "s1", "path": "skills/s1"}],
                 "tools": [{"name": "t1", "path": "tools/t1.yaml",
                            "governanceProfile": "web-search"}]}})
    bundles = ab.parse_harness_files({
        "harness__demo__harness.yaml": manifest.encode(),
        "harness__demo__skills__s1__SKILL.md": b"x\n"})
    assert set(bundles) == {"demo"}
    assert bundles["demo"].digest.startswith("sha256:")
    assert bundles["demo"].managed_root == "/sandbox/.openclaw"
    assert bundles["demo"].tools[0].governance_profile == "web-search"
    assert set(bundles["demo"].files) == {"harness.yaml", "skills/s1/SKILL.md"}


def test_parse_harness_files_rejects_a_bundle_without_a_manifest(ab):
    with pytest.raises(ab.InstallerError, match="stray.*harness.yaml"):
        ab.parse_harness_files({"harness__stray__skills__s__SKILL.md": b"x\n"})


def test_parse_harness_files_names_the_bundle_on_bad_schema(ab):
    manifest = yaml.safe_dump({"metadata": {"name": "demo"},
                               "spec": {"skills": [{"path": "skills/s1"}]}})
    with pytest.raises(ab.InstallerError, match="demo.*'name'"):
        ab.parse_harness_files({"harness__demo__harness.yaml": manifest.encode()})


def test_shipped_bundle_parses(ab, shipped_harness_files):
    bundles = ab.parse_harness_files(shipped_harness_files)
    assert "ds-default" in bundles
    assert {"plugin.json", "mcp.json", "plugins/saw-echo/index.mjs",
            "skills/pattern-author/SKILL.md"} <= set(bundles["ds-default"].files)


def test_chart_bundle_matches_the_published_bundle():
    """charts/saw-bom/harness/ds-default ships in the ConfigMap;
    harness-bundles/ds-default is what CI publishes as an OCI image. They are
    the same bundle and must not drift."""
    def tree(root):
        return {p.relative_to(root).as_posix(): p.read_bytes() for p in root.rglob("*")
                if p.is_file() and p.name not in (".containerignore", ".dockerignore")}
    assert tree(HARNESS / "ds-default") == tree(ROOT / "harness-bundles" / "ds-default")


def test_read_profile_files_splits_profiles_from_harness(ab, tmp_path, shipped_harness_files):
    (tmp_path / "profiles__data-science__default__workspace.yaml").write_text("x: 1\n")
    for key, raw in shipped_harness_files.items():
        # The ConfigMap value is base64 (digest contract); raw bytes here would
        # fail b64decode(validate=True) and the test would assert the wrong thing.
        (tmp_path / key).write_text(base64.b64encode(raw).decode())
    (tmp_path / "harness-index.yaml").write_text("bundles: {ds-default: sha256:x}\n")
    profiles, harness, index = ab.read_profile_files(tmp_path)
    assert list(profiles) == ["profiles__data-science__default__workspace.yaml"]
    assert set(harness) == set(shipped_harness_files)
    assert index["bundles"] == {"ds-default": "sha256:x"}


def test_read_profile_files_rejects_a_harness_key_that_is_not_base64(ab, tmp_path):
    (tmp_path / "harness__demo__harness.yaml").write_text("a: 1\n")
    with pytest.raises(ab.InstallerError, match="not valid base64"):
        ab.read_profile_files(tmp_path)


def test_read_profile_files_still_rejects_an_unknown_key(ab, tmp_path):
    (tmp_path / "surprise.txt").write_text("x")
    with pytest.raises(ab.InstallerError, match="unexpected file"):
        ab.read_profile_files(tmp_path)


def test_parse_profiles_reads_harness_ref(ab):
    doc = yaml.safe_dump({"spec": {"sandboxes": [
        {"name": "notebook", "type": "openclaw", "enabled": True,
         "image": "img", "providers": [],
         "harnessRef": {"name": "ds-default", "digest": "sha256:abc"}}]}})
    files = {"profiles__p__default__workspace.yaml":
             yaml.safe_dump({"metadata": {"name": "default"}, "spec": {}}),
             "profiles__p__default__sandbox.yaml": doc}
    sb = ab.parse_profiles(files)[0].workspaces[0].sandboxes[0]
    assert sb.harness_ref == {"name": "ds-default", "digest": "sha256:abc"}


IMAGE = "ghcr.io/example/saw-harness-ds-default@sha256:" + "a" * 64


def _pinned(ab, ref):
    sb = ab.Sandbox(name="notebook", type="openclaw", harness_ref=ref)
    ws = ab.Workspace(name="default", sandboxes=[sb])
    return [ab.Profile(name="p", workspaces=[ws])]


# -- validate_harness ---------------------------------------------------------

def test_validate_harness_rejects_a_digest_mismatch(ab, shipped_harness_files):
    bundles = ab.parse_harness_files(shipped_harness_files)
    with pytest.raises(ab.InstallerError, match="digest mismatch"):
        ab.validate_harness(_pinned(ab, {"name": "ds-default", "digest": "sha256:STALE"}), bundles)


def test_validate_harness_accepts_a_bundle_without_a_digest(ab, shipped_harness_files):
    """Bundle and pin ship in the same ConfigMap, so the pin is optional."""
    bundles = ab.parse_harness_files(shipped_harness_files)
    assert ab.validate_harness(_pinned(ab, {"name": "ds-default"}), bundles) == {
        "notebook": f"ds-default@{bundles['ds-default'].digest}"}


def test_validate_harness_rejects_an_unknown_bundle(ab):
    with pytest.raises(ab.InstallerError, match="unknown harness bundle"):
        ab.validate_harness(_pinned(ab, {"name": "ds-default"}), {})


def test_validate_harness_accepts_a_digest_pinned_image(ab):
    assert ab.validate_harness(_pinned(ab, {"image": IMAGE}), {}) == {"notebook": IMAGE}


@pytest.mark.parametrize("image", ["ghcr.io/example/h:latest", "ghcr.io/example/h@sha256:abc"])
def test_validate_harness_rejects_an_unpinned_image(ab, image):
    with pytest.raises(ab.InstallerError, match="pinned by digest"):
        ab.validate_harness(_pinned(ab, {"image": image}), {})


def test_validate_harness_rejects_image_and_name_together(ab):
    with pytest.raises(ab.InstallerError, match="not both"):
        ab.validate_harness(_pinned(ab, {"image": IMAGE, "name": "ds-default"}), {})


def test_plan_round_trips_the_harness(ab, shipped_harness_files):
    import json
    bundles = ab.parse_harness_files(shipped_harness_files)
    plan = json.loads(json.dumps(ab.plan_for_user(
        {}, _pinned(ab, {"name": "ds-default"}), {}, "d.sh", harness={"bundles": bundles})))
    back = ab.harness_from_plan(plan)
    assert back["bundles"]["ds-default"].digest == bundles["ds-default"].digest
    assert back["bundles"]["ds-default"].files == bundles["ds-default"].files


def test_plan_round_trips_resolved_mcp_secrets(ab, shipped_harness_files):
    """Secrets are resolved admin-side (Inputs.load), before the plan hands
    off to the runtime-user subprocess -- the resolved values must survive
    that JSON round trip, same as provider credentials do."""
    import json
    bundles = ab.parse_harness_files(shipped_harness_files)
    mcp_secrets = {"ds-default": {"tavily": "tvly-TEST-KEY"}}
    plan = json.loads(json.dumps(ab.plan_for_user(
        {}, _pinned(ab, {"name": "ds-default"}), {}, "d.sh",
        harness={"bundles": bundles, "mcpSecrets": mcp_secrets})))
    back = ab.harness_from_plan(plan)
    assert back["mcpSecrets"] == mcp_secrets


# -- reading a harness image, and the inline volume tarball ---------------------
#
# An OCI harness image is FROM scratch with the bundle tree at its root; the
# sandbox mounts the image itself. The installer only reads it (via `podman
# export`) for the governance check, so these tests pin what it accepts.

def _tar(path, entries):
    """entries: (name, bytes | None for a dir | ("symlink", target))."""
    import io
    import tarfile
    with tarfile.open(path, "w") as tar:
        for name, data in entries:
            info = tarfile.TarInfo(name)
            if data is None:
                info.type = tarfile.DIRTYPE
                tar.addfile(info)
            elif isinstance(data, tuple):
                info.type = tarfile.SYMTYPE
                info.linkname = data[1]
                tar.addfile(info)
            else:
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))


def test_read_harness_tar_reads_the_tree_at_the_image_root(ab, tmp_path):
    _tar(tmp_path / "i.tar", [("skills/", None), ("harness.yaml", b"spec: {}\n"),
                              ("./skills/s/SKILL.md", b"x"),
                              ("skills/s/._SKILL.md", b"appledouble")])
    assert ab.read_harness_tar(tmp_path / "i.tar") == {
        "harness.yaml": (b"spec: {}\n", False), "skills/s/SKILL.md": (b"x", False)}


def test_read_harness_tar_refuses_links(ab, tmp_path):
    _tar(tmp_path / "i.tar", [("harness.yaml", b"spec: {}\n"),
                              ("skills/evil", ("symlink", "/etc/shadow"))])
    with pytest.raises(ab.InstallerError, match="not a regular file"):
        ab.read_harness_tar(tmp_path / "i.tar")


def test_read_harness_tar_refuses_path_escapes(ab, tmp_path):
    _tar(tmp_path / "i.tar", [("harness.yaml", b"spec: {}\n"), ("skills/../../outside", b"x")])
    with pytest.raises(ab.InstallerError, match="unsafe path"):
        ab.read_harness_tar(tmp_path / "i.tar")


def test_read_harness_tar_needs_a_manifest(ab, tmp_path):
    _tar(tmp_path / "i.tar", [("skills/s/SKILL.md", b"x")])
    with pytest.raises(ab.InstallerError, match="no /harness.yaml"):
        ab.read_harness_tar(tmp_path / "i.tar")


def test_volume_tarball_is_root_owned_world_readable_and_round_trips(ab, tmp_path):
    """Inline bundles go into a named volume unchanged; only ownership and
    modes are normalised so the sandbox user can read them."""
    import tarfile
    tree = {"harness.yaml": (b"spec: {}\n", False), "mcp/server.sh": (b"#!/bin/sh\n", True),
            "skills/s/SKILL.md": (b"x", False)}
    ab.write_harness_tar(tmp_path / "v.tar", tree, {"source": "bundle:x@d", "treeDigest": "d"})
    with tarfile.open(tmp_path / "v.tar") as tar:
        members = {m.name: m for m in tar.getmembers()}
        assert {m.uid for m in members.values()} == {0}
        assert members["skills/s/SKILL.md"].mode == 0o644
        assert members["mcp/server.sh"].mode == 0o755
        assert members["skills"].mode == 0o755
        tar.extractall(tmp_path / "vol")
    assert ab.read_volume_tree(tmp_path / "vol") == tree


def test_mount_json_matches_the_openshell_podman_driver_schema(ab):
    assert json.loads(ab.harness_mounts_json("image", IMAGE)) == {"podman": {"mounts": [{
        "type": "image", "source": IMAGE, "target": "/sandbox/harness", "read_only": True}]}}


# -- what OpenClaw is pointed at, and what governance must allow ---------------

def _tree(**files):
    base = {"harness.yaml": (yaml.safe_dump({"metadata": {"name": "demo"},
                                             "spec": {"agent": "openclaw"}}).encode(), False)}
    base.update({k.replace("__", "/"): (v.encode(), False) for k, v in files.items()})
    return base


def test_an_agent_plugins_bundle_is_loaded_from_its_root(ab):
    info = ab.describe_harness_tree(_tree(**{"plugin.json": "{}", "skills__s__SKILL.md": "x",
                                             "plugins__p1__index.mjs": "",
                                             "plugins__p2__index.mjs": ""}))
    assert ab.openclaw_harness_config(info) == {
        "plugins.load.paths": ["/sandbox/harness", "/sandbox/harness/plugins"]}


def test_a_bundle_without_plugin_json_uses_extra_skill_dirs(ab):
    info = ab.describe_harness_tree(_tree(**{"skills__s__SKILL.md": "x"}))
    assert ab.openclaw_harness_config(info) == {
        "skills.load.extraDirs": ["/sandbox/harness/skills"]}


def test_an_mcp_server_without_a_type_is_rejected(ab):
    """OpenClaw drops such entries with a warning; fail early instead."""
    mcp = '{"mcpServers": {"s": {"command": "node"}}}'
    with pytest.raises(ab.InstallerError, match='needs "type"'):
        ab.describe_harness_tree(_tree(**{"mcp.json": mcp}))


def test_a_remote_mcp_server_needs_a_governance_profile(ab):
    mcp = '{"mcpServers": {"s": {"type": "streamable-http", "url": "https://api.tavily.com/mcp"}}}'
    with pytest.raises(ab.InstallerError, match="needs a governanceProfile"):
        ab.describe_harness_tree(_tree(**{"mcp.json": mcp}))


def test_a_remote_mcp_server_is_governed_by_host(ab):
    manifest = yaml.safe_dump({"metadata": {"name": "demo"}, "spec": {
        "mcpServers": [{"name": "s", "governanceProfile": "web-search"}]}})
    mcp = '{"mcpServers": {"s": {"type": "streamable-http", "url": "https://api.tavily.com/mcp"},' \
          ' "local": {"type": "stdio", "command": "node"}}}'
    tree = {"harness.yaml": (manifest.encode(), False), "mcp.json": (mcp.encode(), False)}
    assert ab.describe_harness_tree(tree)["governance"] == [
        {"kind": "MCP server", "name": "s", "governanceProfile": "web-search",
         "hosts": ["api.tavily.com"]}]


def test_a_networked_plugin_is_governed_by_profile(ab):
    manifest = yaml.safe_dump({"metadata": {"name": "demo"}, "spec": {
        "plugins": [{"name": "p", "governanceProfile": "github"}]}})
    tree = {"harness.yaml": (manifest.encode(), False)}
    assert ab.describe_harness_tree(tree)["governance"] == [
        {"kind": "plugin", "name": "p", "governanceProfile": "github", "hosts": []}]


def test_parse_profile_catalog_reads_ids_and_hosts(ab):
    out = ('[{"id": "web-search", "endpoints": [{"host": "api.tavily.com", "port": 443}]},'
           ' {"id": "slack", "endpoints": []}]')
    assert ab.parse_profile_catalog(out) == {"web-search": {"api.tavily.com"}, "slack": set()}


# -- stdio MCP server secrets: never in the bundle, resolved from a Secret ---

def _stdio_secret_tree(**decl_overrides):
    decl = {"name": "tavily", "credentialSecret": "tavily",
            "credentialSecretKey": "api_key", "credentialEnvVar": "TAVILY_API_KEY"}
    decl.update(decl_overrides)
    manifest = yaml.safe_dump({"metadata": {"name": "demo"}, "spec": {"mcpServers": [decl]}})
    mcp = '{"mcpServers": {"tavily": {"type": "stdio", "command": "node"}}}'
    return {"harness.yaml": (manifest.encode(), False), "mcp.json": (mcp.encode(), False)}


def test_a_stdio_server_with_a_credential_secret_is_declared(ab):
    info = ab.describe_harness_tree(_stdio_secret_tree())
    assert info["mcpSecrets"] == [{"server": "tavily", "envVar": "TAVILY_API_KEY",
                                   "credentialSecret": "tavily", "credentialSecretKey": "api_key"}]
    assert info["governance"] == []  # stdio needs no governance profile


def test_a_stdio_secret_needs_a_well_formed_env_var(ab):
    with pytest.raises(ab.InstallerError, match="credentialEnvVar must look like an env var"):
        ab.describe_harness_tree(_stdio_secret_tree(credentialEnvVar="not an env var!"))


def test_a_stdio_secret_rejects_a_bad_secret_name(ab):
    with pytest.raises(ab.InstallerError, match="invalid credentialSecret"):
        ab.describe_harness_tree(_stdio_secret_tree(credentialSecret="Not Valid"))


def test_resolve_harness_mcp_secrets_reads_the_mounted_secret(ab, tmp_path):
    (tmp_path / "tavily").mkdir()
    (tmp_path / "tavily" / "api_key").write_text("tvly-TEST-KEY\n")
    bundle = ab.HarnessBundle(name="demo", files={
        rel: base64.b64encode(data).decode()
        for rel, (data, _) in _stdio_secret_tree().items()})
    out = ab.resolve_harness_mcp_secrets({"demo": bundle}, tmp_path)
    assert out == {"demo": {"tavily": "tvly-TEST-KEY"}}


def test_resolve_harness_mcp_secrets_fails_closed_when_missing(ab, tmp_path):
    bundle = ab.HarnessBundle(name="demo", files={
        rel: base64.b64encode(data).decode()
        for rel, (data, _) in _stdio_secret_tree().items()})
    with pytest.raises(ab.InstallerError, match="credential for MCP server 'tavily' not found"):
        ab.resolve_harness_mcp_secrets({"demo": bundle}, tmp_path)
