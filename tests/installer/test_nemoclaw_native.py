"""The installer must use upstream's native prebuilt-image contract."""

import json

import pytest


IMAGE = "ghcr.io/validatedpatterns-sandbox/nemoclaw-sandbox@sha256:" + "a" * 64


def native_setup(ab, config):
    workspace = ab.Workspace(name="default")
    sandbox = ab.Sandbox(name="native-agent", type="nemoclaw", image=IMAGE,
                         providers=["nvidia"])
    provider = ab.Provider(name="nvidia", type="nvidia", nemoclaw_provider="build")
    applier = ab.ProfileApplier(ab.Shell(), config,
                               {"default": {"nvidia": "nvapi-TEST-NATIVE"}})
    return applier, workspace, sandbox, provider


def test_onboard_passes_the_published_digest_to_native_podman(
        ab, fake_env, config, monkeypatch):
    monkeypatch.setenv("XDG_RUNTIME_DIR", "/run/user/1000")
    monkeypatch.delenv("OPENSHELL_PODMAN_SOCKET", raising=False)
    applier, workspace, sandbox, provider = native_setup(ab, config)
    applier.onboard_nemoclaw(workspace, sandbox, provider)
    call = fake_env.other_calls("nemoclaw")[0]
    assert call["args"][call["args"].index("--from-image") + 1] == IMAGE
    assert "--from" not in call["args"]
    assert call["runtime"] == "podman"
    assert call["socket"] == "/run/user/1000/podman/podman.sock"
    assert call["workspace"] == "default"
    assert call["has_key"]
    management = json.loads((fake_env.home / "gateway-management.json").read_text())
    assert management["stateDir"] == str(fake_env.home / ".local/state/saw-installer")
    assert fake_env.other_calls("podman") == []


@pytest.mark.parametrize("image", ["", "invalid image", "ghcr.io/example/sandbox@latest",
                                    "ghcr.io/example/sandbox@sha256:abc"])
def test_native_onboard_rejects_invalid_images_before_effects(
        ab, fake_env, config, image):
    applier, workspace, sandbox, provider = native_setup(ab, config)
    sandbox.image = image
    with pytest.raises(ab.InstallerError, match="image reference"):
        applier.onboard_nemoclaw(workspace, sandbox, provider)
    assert fake_env.other_calls("nemoclaw") == []
    assert not (fake_env.home / "gateway-management.json").exists()


def test_native_onboard_resolves_ci_latest_using_the_same_socket(
        ab, fake_env, config, monkeypatch):
    monkeypatch.setenv("OPENSHELL_PODMAN_SOCKET", "/run/user/1000/podman/podman.sock")
    applier, workspace, sandbox, provider = native_setup(ab, config)
    sandbox.image = "ghcr.io/validatedpatterns-sandbox/nemoclaw-sandbox:latest"
    applier.onboard_nemoclaw(workspace, sandbox, provider)
    call = fake_env.other_calls("nemoclaw")[0]
    assert call["args"][call["args"].index("--from-image") + 1] == IMAGE
    assert sandbox.image.endswith(":latest")
    assert fake_env.other_calls("podman")[0] == [
        "--url", "unix:///run/user/1000/podman/podman.sock", "pull", "--quiet", sandbox.image]


@pytest.mark.parametrize("digests", [[], ["other.example/sandbox@sha256:" + "b" * 64],
                                     ["ghcr.io/validatedpatterns-sandbox/nemoclaw-sandbox:latest"],
                                     None])
def test_native_onboard_stops_if_tag_has_no_matching_digest(
        ab, fake_env, config, digests):
    applier, workspace, sandbox, provider = native_setup(ab, config)
    sandbox.image = "ghcr.io/validatedpatterns-sandbox/nemoclaw-sandbox:latest"
    fake_env.set_images({sandbox.image: {"RepoDigests": digests}})
    with pytest.raises(ab.InstallerError, match="registry digest"):
        applier.onboard_nemoclaw(workspace, sandbox, provider)
    assert fake_env.other_calls("nemoclaw") == []


def test_native_failure_does_not_create_a_fallback_sandbox(ab, fake_env, config):
    applier, workspace, sandbox, provider = native_setup(ab, config)
    workspace.providers = [provider]
    (fake_env.state / "nemoclaw-fail").touch()
    with pytest.raises(ab.InstallerError, match="nemoclaw"):
        applier.apply_sandbox(workspace, sandbox)
    assert not [call for call in fake_env.openshell_calls()
                if call[:2] == ["sandbox", "create"]]


def test_native_success_leaves_agent_creation_and_startup_to_nemoclaw(ab, fake_env, config):
    applier, workspace, sandbox, provider = native_setup(ab, config)
    workspace.providers = [provider]
    applier.apply_sandbox(workspace, sandbox)
    assert not [call for call in fake_env.openshell_calls()
                if call[:2] in (["sandbox", "create"], ["sandbox", "exec"])]
    assert ("sandbox", "default", sandbox.name) in applier.desired


def test_native_missing_provider_does_not_create_a_plain_sandbox(ab, fake_env, config):
    applier, workspace, sandbox, _ = native_setup(ab, config)
    with pytest.raises(ab.InstallerError, match="no usable provider"):
        applier.apply_sandbox(workspace, sandbox)
    assert fake_env.other_calls("nemoclaw") == []
    assert fake_env.openshell_calls() == []
