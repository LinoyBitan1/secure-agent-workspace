"""Official APIs use native onboarding; explicit endpoint URLs remain custom."""
import pytest


def test_attached_models_resolve_and_register_without_changing_default(
        ab, fake_env, config, secrets_dir):
    from conftest import profile_files

    profiles = ab.parse_profiles(profile_files())
    ws = next(w for w in profiles[0].workspaces if w.name == "default")
    sb = ws.sandboxes[0]
    assert {name: src["default"] for name, src in sb.inference["models"].items()} == {
        "openai": "gpt-6-luna", "anthropic": "claude-sonnet-4-6"}
    # Disabled providers neither require Secrets nor appear in chat configuration.
    ab.validate_profiles(profiles)
    ab.resolve_credentials(profiles, secrets_dir)
    assert sb.inference_values["models"] == {}
    for p in ws.providers:
        if p.name in sb.inference["models"]:
            p.enabled = True
            sb.providers.append(p.name)
            secret = secrets_dir / p.credential_secret
            secret.mkdir()
            (secret / "api_key").write_text("test-key")
    (secrets_dir / "inference-openai" / "model").write_text("selected-openai")
    ab.validate_profiles(profiles)
    creds = ab.resolve_credentials(profiles, secrets_dir)
    assert sb.inference_values["models"] == {
        "openai": "selected-openai", "anthropic": "claude-sonnet-4-6"}
    sb.harness_ref = {}
    ab.ProfileApplier(ab.Shell(), config, creds).apply(profiles)
    saved = fake_env.openshell_state()["sandboxes"]["default/notebook"]["openclawConfig"]
    choices = saved["agents.defaults.models"]
    assert "openai/selected-openai" in choices
    assert "anthropic/claude-sonnet-4-6" in choices
    assert "nvidia/nemotron-3.5-lightning-30b-a3b" in choices
    assert choices["openai/selected-openai"]["agentRuntime"] == {"id": "openclaw"}
    assert saved["agents.entries.main.model"].startswith("nvidia/")
    state = fake_env.openshell_state()
    choices = state["sandboxes"]["default/notebook"]["openclawConfig"]["agents.defaults.models"]
    choices["other/user-choice"] = {"alias": "keep"}
    choices["anthropic/claude-sonnet-4-6"] = {"alias": "Claude"}
    fake_env.set_openshell_state(state)
    ab.ProfileApplier(ab.Shell(), config, creds).apply(profiles)
    saved = fake_env.openshell_state()["sandboxes"]["default/notebook"]["openclawConfig"]
    assert saved["agents.defaults.models"]["other/user-choice"] == {"alias": "keep"}
    assert saved["agents.defaults.models"]["anthropic/claude-sonnet-4-6"] == {"alias": "Claude"}
    assert saved["agents.entries.main.model"].startswith("nvidia/")


@pytest.mark.parametrize("models,message", [
    ([], "models must be a mapping"),
    ({"typo": "model"}, "unknown provider"),
    ({"openai": ""}, "non-empty"),
    ({"openai": {"secretKeyRef": {"name": "x", "key": "model"},
                 "default": "", "required": False}}, "non-empty"),
    ({"brave": "model"}, "native OpenAI or Anthropic"),
])
def test_invalid_attached_models_fail_validation(ab, models, message):
    providers = [ab.Provider(name="nvidia", type="nvidia", credential_secret="inference"),
                 ab.Provider(name="openai", type="openai", enabled=False),
                 ab.Provider(name="brave", type="brave", credential_secret="brave")]
    sb = ab.Sandbox(name="chat", type="openclaw", providers=["nvidia"], inference={
        "providerRef": "nvidia", "model": "nvidia/test", "models": models})
    with pytest.raises(ab.InstallerError, match=message):
        ab.validate_profiles([ab.Profile(name="test", workspaces=[
            ab.Workspace(name="default", providers=providers, sandboxes=[sb])])])


@pytest.mark.parametrize("kind", ["openai", "anthropic"])
@pytest.mark.parametrize("native", [True, False])
def test_existing_custom_settings_are_cleared_only_for_native_apis(
        ab, fake_env, config, kind, native):
    endpoint = "https://private-model.example/v1"
    provider = ab.Provider(name="inference", type=kind, model="test-model", base_url=endpoint)
    sandbox = ab.Sandbox(name="chat", type="openclaw", providers=[provider.name])
    workspace = ab.Workspace(name="default", providers=[provider], sandboxes=[sandbox])
    profiles = [ab.Profile(name="test", workspaces=[workspace])]
    applier = ab.ProfileApplier(ab.Shell(), config, {"default": {provider.name: "test-key"}})
    applier.apply(profiles)
    # Native onboarding preserves existing custom endpoint settings in OpenClaw.
    state = fake_env.openshell_state()
    key = f"models.providers.{kind}"
    saved = {key: {"baseUrl": endpoint, "api": "openai-completions"},
             "models.providers.unrelated": {"baseUrl": "https://keep.example/v1"}}
    state["sandboxes"]["default/chat"]["openclawConfig"] = saved
    fake_env.set_openshell_state(state)
    if native:
        provider.base_url = ""
    call_count = len(fake_env.openshell_calls())
    applier.apply(profiles)
    current = fake_env.openshell_state()["sandboxes"]["default/chat"]["openclawConfig"]
    assert (key not in current) == native
    assert current["models.providers.unrelated"] == saved["models.providers.unrelated"]
    if native:
        scripts = [c[-1] for c in fake_env.openshell_calls()[call_count:]
                   if c[:2] == ["sandbox", "exec"]]
        cleanup = next(i for i, s in enumerate(scripts)
                       if f"openclaw config unset {key}" in s)
        onboard = next(i for i, s in enumerate(scripts) if "openclaw onboard " in s)
        assert cleanup < onboard


@pytest.mark.parametrize("kind,endpoint,choice,model", [
    ("openai", "", "openai-api-key", "gpt-4o"),
    ("anthropic", "", "apiKey", "claude-sonnet-4-6"),
    ("openai", "http://ollama.models.svc:11434/v1", "custom-api-key", "llama3"),
    ("openai", "https://api.openai.com/v1", "custom-api-key", "gpt-4o"),
    ("nvidia", "", "custom-api-key", "nvidia/nemotron-3.5-lightning-30b-a3b"),
])
def test_onboarding_uses_the_provider_protocol(
        ab, fake_env, config, kind, endpoint, choice, model):
    provider = ab.Provider(name="inference", type=kind, model=model, base_url=endpoint)
    sandbox = ab.Sandbox(name="chat", type="openclaw", providers=[provider.name])
    workspace = ab.Workspace(name="default", providers=[provider], sandboxes=[sandbox])
    applier = ab.ProfileApplier(ab.Shell(), config,
                                {"default": {provider.name: "test-secret-key"}})
    applier.apply([ab.Profile(name="test", workspaces=[workspace])])
    calls = fake_env.openshell_calls()
    scripts = [c[-1] for c in calls if c[:2] == ["sandbox", "exec"]]
    onboard = next(s for s in scripts if "openclaw onboard " in s)
    assert f"--auth-choice {choice} " in onboard
    if choice == "custom-api-key":
        assert f"--custom-model-id {model}" in onboard
        if endpoint:
            assert f"--custom-base-url {endpoint} " in onboard
    else:
        assert "--custom-" not in onboard
        assert any(f"openclaw models set {kind}/{model}" in s for s in scripts)
    assert not any("test-secret-key" in " ".join(c) for c in calls)


def test_optional_openai_uses_openclaw_runtime_when_nvidia_is_default(ab, fake_env, config):
    providers = [ab.Provider(name="nvidia", type="nvidia", model="nvidia/test-model"),
                 ab.Provider(name="openai", type="openai", model="gpt-4o")]
    sandbox = ab.Sandbox(name="chat", type="openclaw", providers=[p.name for p in providers])
    workspace = ab.Workspace(name="default", providers=providers, sandboxes=[sandbox])
    ab.ProfileApplier(ab.Shell(), config, {"default": {p.name: "test-key" for p in providers}}).apply(
        [ab.Profile(name="test", workspaces=[workspace])])
    scripts = [c[-1] for c in fake_env.openshell_calls() if c[:2] == ["sandbox", "exec"]]
    assert any("agents.defaults.models.openai/*.agentRuntime" in s and '"openclaw"' in s
               for s in scripts)
    onboard = next(s for s in scripts if "openclaw onboard " in s)
    assert "--custom-model-id nvidia/test-model" in onboard
    assert set(fake_env.openshell_state()["sandboxes"]["default/chat"]["providers"]) == {
        "nvidia", "openai"}


def test_shipped_optional_apis_do_not_require_keys_by_default(ab, secrets_dir):
    from conftest import profile_files

    profiles = ab.parse_profiles(profile_files())
    ab.validate_profiles(profiles)
    workspace = next(ws for ws in profiles[0].workspaces if ws.name == "default")
    optional = [p for p in workspace.providers if p.type in ("openai", "anthropic")]
    assert {p.type for p in optional} == {"openai", "anthropic"}
    assert all(not p.enabled and not p.base_url_secret_key for p in optional)
    assert all(not p.model and not p.model_secret_key for p in optional)
    assert workspace.sandboxes[0].providers == ["nvidia"]
    nvidia = next(p for p in workspace.providers if p.name == "nvidia")
    # The model is the sandbox's (inference.model); the provider holds credentials only.
    assert nvidia.model == ""
    assert nvidia.credential_secret_key == "api_key"
    assert set(ab.resolve_credentials(profiles, secrets_dir)["default"]) == {"nvidia", "brave"}
    assert ab.sandbox_model(workspace.sandboxes[0], nvidia) == "nvidia/nemotron-3.5-lightning-30b-a3b"


def test_each_official_api_reads_its_own_secret(ab, secrets_dir):
    from conftest import profile_files

    profiles = ab.parse_profiles(profile_files())
    workspace = next(ws for ws in profiles[0].workspaces if ws.name == "default")
    for kind in ("openai", "anthropic"):
        provider = next(p for p in workspace.providers if p.name == kind)
        provider.enabled = True
        workspace.sandboxes[0].providers.append(kind)
        secret = secrets_dir / f"inference-{kind}"
        secret.mkdir()
        (secret / "provider").write_text(kind)
        (secret / "api_key").write_text(f"test-{kind}-key")
        (secret / "model").write_text(f"test-{kind}-model")
    ab.validate_profiles(profiles)
    credentials = ab.resolve_credentials(profiles, secrets_dir)
    assert credentials["default"] == {
        "nvidia": "nvapi-TEST-KEY-123", "brave": "brave-TEST-KEY-456",
        "openai": "test-openai-key", "anthropic": "test-anthropic-key"}
    assert credentials["cuda-dev"]["nvidia"] == credentials["default"]["nvidia"]
    for kind in ("openai", "anthropic"):
        provider = next(p for p in workspace.providers if p.name == kind)
        assert provider.credential_secret == f"inference-{kind}"
        assert provider.model == "" and provider.model_secret_key == ""


@pytest.mark.parametrize("kind,default_model", [
    ("openai", "gpt-6-luna"),
    ("anthropic", "claude-sonnet-4-6"),
])
def test_shipped_native_provider_model_is_selected_by_sandbox_inference(
        ab, secrets_dir, kind, default_model):
    from conftest import profile_files

    profiles = ab.parse_profiles(profile_files())
    workspace = next(ws for ws in profiles[0].workspaces if ws.name == "default")
    provider = next(p for p in workspace.providers if p.name == kind)
    assert provider.model == "" and provider.model_secret_key == ""
    provider.enabled = True
    sandbox = workspace.sandboxes[0]
    sandbox.providers.append(kind)
    sandbox.inference = {
        "providerRef": kind,
        "model": {"secretKeyRef": {"name": f"inference-{kind}", "key": "model"},
                  "default": default_model, "title": "Model (notebook)"},
    }
    secret = secrets_dir / f"inference-{kind}"
    secret.mkdir()
    (secret / "api_key").write_text(f"test-{kind}-key")
    ab.validate_profiles(profiles)
    credentials = ab.resolve_credentials(profiles, secrets_dir)
    assert credentials["default"][kind] == f"test-{kind}-key"
    assert sandbox.inference_values["providerRef"] == kind
    assert ab.sandbox_model(sandbox, provider) == default_model
    # Model inputs belong to the sandbox; changing one never changes the provider.
    (secret / "model").write_text("selected-model")
    ab.resolve_credentials(profiles, secrets_dir)
    assert ab.sandbox_model(sandbox, provider) == "selected-model"
    assert provider.model == "" and provider.model_secret_key == ""


@pytest.mark.parametrize("kind,model", [
    ("openai", "gpt-6-luna"),
    ("anthropic", "claude-sonnet-4-6"),
    ("nvidia", "nvidia/nemotron-3.5-lightning-30b-a3b"),
])
def test_configured_model_replaces_the_main_agents_onboarding_selection(
        ab, fake_env, config, tmp_path, kind, model):
    import json

    secret = tmp_path / "model-key"
    secret.mkdir()
    (secret / "api_key").write_text("test-model-key")
    provider = ab.Provider(name=kind, type=kind, credential_secret="model-key")
    sandbox = ab.Sandbox(name="chat", type="openclaw", providers=[kind], inference={
        "providerRef": kind, "model": model})
    workspace = ab.Workspace(name="default", providers=[provider], sandboxes=[sandbox])
    profiles = [ab.Profile(name="test", workspaces=[workspace])]
    creds = ab.resolve_credentials(profiles, tmp_path)
    ab.ProfileApplier(ab.Shell(), config, creds).apply(profiles)
    state = fake_env.openshell_state()
    saved = state["sandboxes"]["default/chat"].setdefault("openclawConfig", {})
    # Onboarding can pin a model on main, which wins over models set's default.
    profile_id = f"{kind}:setup-df67c47c-d3f2-46f5-b698-c42390c67b5d"
    saved["agents.entries.main.model"] = f"{kind}/onboarding-default@{profile_id}"
    saved["agents.entries.other.model"] = "other/keep-me"
    fake_env.set_openshell_state(state)
    (fake_env.state / "exec-output.json").write_text(json.dumps({
        "openclaw onboard": "Replacement credential saved but inactive.\n"
        f"openclaw models auth activate {profile_id} --agent main"}))
    before = len(fake_env.openshell_calls())
    ab.ProfileApplier(ab.Shell(), config, creds).apply(profiles)
    current = fake_env.openshell_state()["sandboxes"]["default/chat"]["openclawConfig"]
    expected = model if model.startswith(kind + "/") else f"{kind}/{model}"
    assert current["agents.entries.main.model"] == f"{expected}@{profile_id}"
    assert current["agents.entries.other.model"] == "other/keep-me"
    scripts = [c[-1] for c in fake_env.openshell_calls()[before:]
               if c[:2] == ["sandbox", "exec"]]
    activate = next(i for i, s in enumerate(scripts) if "models auth activate " in s)
    select = next(i for i, s in enumerate(scripts)
                  if "config set agents.entries.main.model " in s)
    assert select > activate


@pytest.mark.parametrize("current,expected", [
    ("anthropic/old@anthropic:current", "anthropic/new@anthropic:current"),
    ("openai/old@openai:current", "anthropic/new"),
    ("anthropic/old@openai:current", "anthropic/new"),
    ("anthropic/old", "anthropic/new"),
    (None, "anthropic/new"),
    ({"primary": "anthropic/old@anthropic:current", "fallbacks": ["anthropic/fallback"]},
     {"primary": "anthropic/new@anthropic:current", "fallbacks": ["anthropic/fallback"]}),
])
def test_agent_model_selection_preserves_only_a_matching_credential_binding(ab, current, expected):
    assert ab.openclaw_agent_model("anthropic/new", current) == expected
