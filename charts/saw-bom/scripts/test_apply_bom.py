"""Unit tests for the pure-Python pieces of apply_bom.py — profile parsing,
credential resolution, and provider selection/validation. None of these need
a live gateway VM or cluster.

Run with:
    pip install pytest pyyaml
    pytest charts/saw-bom/scripts/test_apply_bom.py -v
"""
import json
import os
import sys

import pytest
import yaml

sys.path.insert(0, os.path.dirname(__file__))

from apply_bom import (  # noqa: E402
    Provider,
    Sandbox,
    Workspace,
    WorkspaceDeployer,
    GatewaySetup,
    check_provider_type_mismatch,
    find_provider,
    image_pull_command,
    parse_profiles,
    resolve_configured_type,
    resolve_credential,
    runtime_command,
)


def _write_profile(root, profile="data-science", workspace="default",
                    workspace_yaml=None, providers_yaml=None, sandbox_yaml=None):
    """Write a minimal BOM profile directory tree under `root`."""
    ws_dir = root / profile / workspace
    ws_dir.mkdir(parents=True, exist_ok=True)

    default_workspace_yaml = {
        "apiVersion": "saw.redhat.com/v1alpha1",
        "kind": "Workspace",
        "metadata": {"name": workspace},
        "spec": {"enabled": True},
    }
    (ws_dir / "workspace.yaml").write_text(
        yaml.safe_dump(workspace_yaml or default_workspace_yaml))

    if providers_yaml is not None:
        (ws_dir / "providers.yaml").write_text(yaml.safe_dump(providers_yaml))
    if sandbox_yaml is not None:
        (ws_dir / "sandbox.yaml").write_text(yaml.safe_dump(sandbox_yaml))

    return ws_dir


# ---------------------------------------------------------------------------
# parse_profiles()
# ---------------------------------------------------------------------------

def test_parse_profiles_basic(tmp_path):
    _write_profile(
        tmp_path,
        providers_yaml={"spec": {"providers": [
            {"name": "nvidia", "type": "nvidia", "nemoclawProvider": "build",
             "credentialSecret": "inference", "credentialSecretKey": "api_key"},
        ]}},
        sandbox_yaml={"spec": {"sandboxes": [
            {"name": "notebook", "type": "openclaw", "enabled": True,
             "providers": ["nvidia"]},
        ]}},
    )
    profiles = parse_profiles(tmp_path)
    assert len(profiles) == 1
    ws = profiles[0].workspaces[0]
    assert ws.name == "default"
    assert [p.name for p in ws.providers] == ["nvidia"]
    assert ws.providers[0].nemoclaw_provider == "build"
    assert [sb.name for sb in ws.sandboxes] == ["notebook"]
    assert ws.sandboxes[0].providers == ["nvidia"]


def test_parse_profiles_skips_workspace_dir_missing_workspace_yaml(tmp_path):
    # A directory with no workspace.yaml at all should be skipped, not crash.
    bogus_dir = tmp_path / "data-science" / "not-a-workspace"
    bogus_dir.mkdir(parents=True)
    (bogus_dir / "sandbox.yaml").write_text("spec:\n  sandboxes: []\n")
    profiles = parse_profiles(tmp_path)
    assert profiles == []


def test_parse_profiles_no_profiles_dir_entries(tmp_path):
    assert parse_profiles(tmp_path) == []


def test_parse_profiles_disabled_workspace_still_parsed(tmp_path):
    _write_profile(
        tmp_path,
        workspace_yaml={"metadata": {"name": "cuda-dev"},
                         "spec": {"enabled": False}},
        providers_yaml={"spec": {"providers": []}},
        sandbox_yaml={"spec": {"sandboxes": []}},
    )
    profiles = parse_profiles(tmp_path)
    ws = profiles[0].workspaces[0]
    assert ws.enabled is False


# ---------------------------------------------------------------------------
# resolve_credential()
# ---------------------------------------------------------------------------

def test_resolve_credential_prefers_provider_specific_env(monkeypatch):
    monkeypatch.setenv("PROV_NVIDIA_KEY", "specific-key")
    monkeypatch.setenv("NVIDIA_API_KEY", "generic-key")
    p = Provider(name="nvidia", type="nvidia")
    assert resolve_credential(p) == "specific-key"


def test_resolve_credential_falls_back_to_type_map(monkeypatch):
    monkeypatch.delenv("PROV_NVIDIA_KEY", raising=False)
    monkeypatch.setenv("NVIDIA_API_KEY", "generic-key")
    p = Provider(name="nvidia", type="nvidia")
    assert resolve_credential(p) == "generic-key"


def test_resolve_credential_none_when_unset(monkeypatch):
    monkeypatch.delenv("PROV_NVIDIA_KEY", raising=False)
    monkeypatch.delenv("NVIDIA_API_KEY", raising=False)
    p = Provider(name="nvidia", type="nvidia")
    assert resolve_credential(p) is None


def test_resolve_credential_handles_hyphenated_names(monkeypatch):
    monkeypatch.setenv("PROV_GOOGLE_VERTEX_AI_KEY", "vertex-key")
    p = Provider(name="google-vertex-ai", type="google-vertex-ai")
    assert resolve_credential(p) == "vertex-key"


# ---------------------------------------------------------------------------
# find_provider() — regression test for the ws.providers[0] bug (finding #5):
# reordering providers.yaml must never change which provider a sandbox that
# declares its own `providers:` list actually gets.
# ---------------------------------------------------------------------------

def _ws_with_providers(*names_and_types):
    ws = Workspace(name="default")
    for name, ptype in names_and_types:
        ws.providers.append(Provider(name=name, type=ptype))
    return ws


def test_find_provider_selects_by_declared_name_not_index():
    ws = _ws_with_providers(("brave", "brave"), ("nvidia", "nvidia"))
    prov = find_provider(ws, ["nvidia"])
    assert prov.name == "nvidia"


def test_find_provider_order_independent():
    # Same providers, opposite order — result must be identical.
    ws_a = _ws_with_providers(("nvidia", "nvidia"), ("brave", "brave"))
    ws_b = _ws_with_providers(("brave", "brave"), ("nvidia", "nvidia"))
    assert find_provider(ws_a, ["nvidia"]).name == "nvidia"
    assert find_provider(ws_b, ["nvidia"]).name == "nvidia"


def test_find_provider_falls_back_to_first_when_no_names_declared():
    ws = _ws_with_providers(("nvidia", "nvidia"))
    assert find_provider(ws, []).name == "nvidia"
    assert find_provider(ws, None).name == "nvidia"


def test_find_provider_falls_back_when_declared_name_not_found():
    ws = _ws_with_providers(("nvidia", "nvidia"))
    prov = find_provider(ws, ["does-not-exist"])
    assert prov.name == "nvidia"  # falls back to index 0, not None


def test_find_provider_none_when_workspace_has_no_providers():
    ws = Workspace(name="default")
    assert find_provider(ws, ["nvidia"]) is None


# ---------------------------------------------------------------------------
# check_provider_type_mismatch() — regression test for finding #14.
# ---------------------------------------------------------------------------

def test_provider_type_mismatch_none_when_no_configured_type(monkeypatch):
    monkeypatch.delenv("PROV_NVIDIA_TYPE", raising=False)
    p = Provider(name="nvidia", type="nvidia", nemoclaw_provider="build")
    assert check_provider_type_mismatch(p) is None


def test_provider_type_mismatch_accepts_nemoclaw_alias(monkeypatch):
    # values-secret.yaml.template documents NVIDIA's provider identifier as
    # "build", distinct from the OpenShell provider type "nvidia" — this
    # must NOT be flagged as a mismatch for the bundled default profile.
    monkeypatch.setenv("PROV_NVIDIA_TYPE", "build")
    p = Provider(name="nvidia", type="nvidia", nemoclaw_provider="build")
    assert check_provider_type_mismatch(p) is None


def test_provider_type_mismatch_detects_real_mismatch(monkeypatch):
    monkeypatch.setenv("PROV_NVIDIA_TYPE", "gemini")
    p = Provider(name="nvidia", type="nvidia", nemoclaw_provider="build")
    msg = check_provider_type_mismatch(p)
    assert msg is not None
    assert "gemini" in msg


def test_resolve_configured_type_reads_env(monkeypatch):
    monkeypatch.setenv("PROV_NVIDIA_TYPE", "build")
    p = Provider(name="nvidia", type="nvidia")
    assert resolve_configured_type(p) == "build"


def test_resolve_configured_type_none_when_unset(monkeypatch):
    monkeypatch.delenv("PROV_NVIDIA_TYPE", raising=False)
    p = Provider(name="nvidia", type="nvidia")
    assert resolve_configured_type(p) is None


# ---------------------------------------------------------------------------
# Runtime and managed NemoClaw onboarding
# ---------------------------------------------------------------------------

class _RecordingShell:
    dry_run = True

    def __init__(self):
        self.calls = []

    def run(self, cmd, env=None, check=True):
        self.calls.append((cmd, env or {}))
        if cmd[:3] == ["openshell", "sandbox", "get"]:
            return 1, "", "not found"
        if cmd[:2] == ["which", "nemoclaw"]:
            return 1, "", "not found"
        return 0, "", ""


def test_runtime_command_defaults_to_rootless_podman():
    assert runtime_command("podman", "pull", "image:tag") == [
        "podman", "pull", "image:tag"
    ]


def test_runtime_command_keeps_explicit_docker_compatibility():
    assert runtime_command("docker", "pull", "image:tag") == [
        "sudo", "docker", "pull", "image:tag"
    ]


def test_internal_registry_pull_disables_tls_only_for_podman():
    image = "image-registry.openshift-image-registry.svc.cluster.local:5000/ns/image:tag"
    assert image_pull_command("podman", image) == [
        "podman", "pull", "--tls-verify=false", image
    ]
    assert image_pull_command("docker", image) == [
        "sudo", "docker", "pull", image
    ]


def test_nemoclaw_onboarding_selects_podman_without_custom_image():
    shell = _RecordingShell()
    deployer = WorkspaceDeployer(shell, None)
    sandbox = Sandbox(name="cuda-sandbox", type="nemoclaw", agent="openclaw")
    provider = Provider(name="nvidia", type="nvidia", nemoclaw_provider="build")

    assert deployer.onboard_nemoclaw(sandbox, provider, "secret") is True

    command, env = shell.calls[-1]
    assert command[:2] == ["nemoclaw", "onboard"]
    assert "--from" not in command
    assert env["NEMOCLAW_GATEWAY_RUNTIME"] == "podman"
    assert env["NEMOCLAW_IGNORE_RUNTIME_RESOURCES"] == "1"


def test_nemoclaw_cli_install_pulls_with_selected_runtime():
    shell = _RecordingShell()
    deployer = WorkspaceDeployer(shell, None)

    deployer.install_nemoclaw_cli(
        "image-registry.openshift-image-registry.svc.cluster.local:5000/ns/nemoclaw-cli:latest"
    )

    assert any(
        cmd[:2] == ["bash", "-c"]
        and "image-registry.openshift-image-registry.svc.cluster.local:5000/ns/nemoclaw-cli:latest" in cmd[2]
        for cmd, _ in shell.calls
    )


def test_generic_sandbox_pull_uses_selected_runtime():
    shell = _RecordingShell()
    deployer = WorkspaceDeployer(shell, None)
    sandbox = Sandbox(
        name="generic-sandbox",
        image="image-registry.openshift-image-registry.svc.cluster.local:5000/ns/image:tag",
    )

    deployer.create_sandbox_generic(sandbox)

    assert ([("podman", "pull", "--tls-verify=false", sandbox.image)]
            == [tuple(cmd) for cmd, _ in shell.calls if cmd[:2] == ["podman", "pull"]])


def test_nemoclaw_cli_image_refreshes_existing_install():
    class RecordingShell:
        dry_run = False

        def __init__(self):
            self.commands = []

        def run(self, cmd, **kwargs):
            self.commands.append(cmd)
            if cmd[:2] == ["which", "nemoclaw"]:
                return 0, "/usr/local/bin/nemoclaw\n", ""
            return 0, "", ""

    shell = RecordingShell()
    WorkspaceDeployer(shell, None).install_nemoclaw_cli(
        "registry.example/nemoclaw-cli:latest"
    )

    assert any(
        cmd[:2] == ["bash", "-c"]
        and "registry.example/nemoclaw-cli:latest" in cmd[2]
        for cmd in shell.commands
    )


def test_gateway_setup_clones_oidc_registration_for_nemoclaw_alias(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    source = tmp_path / ".config" / "openshell" / "gateways" / "openshell"
    source.mkdir(parents=True)
    (source / "metadata.json").write_text(json.dumps({
        "name": "openshell",
        "gateway_endpoint": "https://127.0.0.1:17670",
        "auth_mode": "oidc",
    }))
    (source / "oidc_token.json").write_text('{"access_token":"redacted"}')

    class RecordingShell:
        dry_run = False

        def __init__(self):
            self.commands = []

        def run(self, cmd, **kwargs):
            self.commands.append(cmd)
            return 0, "", ""

    shell = RecordingShell()
    GatewaySetup(shell, "openshell", "openshell-local").ensure_oidc_alias(
        "nemoclaw-17670"
    )

    target = tmp_path / ".config" / "openshell" / "gateways" / "nemoclaw-17670"
    metadata = json.loads((target / "metadata.json").read_text())
    assert metadata["name"] == "nemoclaw-17670"
    assert (target / "oidc_token.json").read_text() == '{"access_token":"redacted"}'
    assert ["openshell", "gateway", "select", "nemoclaw-17670"] in shell.commands


def test_nemoclaw_onboard_exports_provider_type_and_alias_credentials():
    class RecordingShell:
        dry_run = True

        def __init__(self):
            self.env = None

        def run(self, cmd, **kwargs):
            self.env = kwargs.get("env")
            return 0, "", ""

    shell = RecordingShell()
    WorkspaceDeployer(shell, None).onboard_nemoclaw(
        Sandbox(name="cuda-sandbox"),
        Provider(name="nvidia", type="nvidia", nemoclaw_provider="build"),
        "secret",
    )

    assert shell.env["NEMOCLAW_PRESERVE_GATEWAY_REGISTRATION"] == "1"
    assert shell.env["NVIDIA_API_KEY"] == "secret"
    assert shell.env["NVIDIA_INFERENCE_API_KEY"] == "secret"


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
