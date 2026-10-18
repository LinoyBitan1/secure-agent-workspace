"""Codex API-key provider follows the same installer path as NVIDIA."""

import pytest
import yaml

from conftest import ROOT, profile_files


def test_codex_has_a_native_api_endpoint(ab):
    assert ab.NATIVE_BASE_URLS.get("codex") == "https://api.openai.com/v1"


def test_codex_profile_uses_an_api_key_and_permits_openclaw():
    policy = ROOT / "charts/governance-policy/profiles/codex.yaml"
    assert policy.is_file()
    profile = yaml.safe_load(policy.read_text())
    assert profile["id"] == "codex"
    assert profile["credentials"] == [{
        "name": "api_key", "description": "OpenAI API key",
        "env_vars": ["OPENAI_API_KEY"], "required": True,
        "auth_style": "bearer", "header_name": "authorization"}]
    assert profile["discovery"]["credentials"] == ["api_key"]
    assert {e["host"] for e in profile["endpoints"]} == {"api.openai.com"}
    assert "/usr/bin/node-*" in profile["binaries"]
    assert policy.read_bytes() == (ROOT / "charts/openshell-saw/files/provider-profiles/codex.yaml").read_bytes()


def test_codex_apply_imports_profile_and_configures_api_key_inference(
        ab, fake_env, config, secrets_dir):
    profiles = ab.parse_profiles(profile_files("codex"))
    assert len(profiles) == 1
    ab.validate_profiles(profiles)
    for key, value in {"provider": "codex", "model": "gpt-6-luna",
                       "api_key": "sk-CODEX-TEST-ONLY"}.items():
        (secrets_dir / "inference" / key).write_text(value)
    creds = ab.resolve_credentials(profiles, secrets_dir)
    fake_env.without_profiles("codex")
    shipped = ROOT / "charts/openshell-saw/files/provider-profiles/codex.yaml"
    applier = ab.ProfileApplier(ab.Shell(), config, creds, {"codex": shipped.read_text()})
    applier.apply(profiles)
    state = fake_env.openshell_state()
    assert state["providers"]["default/codex"] == {
        "type": "codex", "credential": "OPENAI_API_KEY=sk-CODEX-TEST-ONLY"}
    assert state["sandboxes"]["default/notebook"]["providers"] == ["codex"]
    calls = [" ".join(c) for c in fake_env.openshell_calls()]
    onboard = next(c for c in calls if "openclaw onboard" in c)
    assert "--custom-base-url https://api.openai.com/v1 " in onboard
    assert "--custom-provider-id openai " in onboard
    assert "--custom-model-id gpt-6-luna " in onboard
    assert 'CUSTOM_API_KEY="$OPENAI_API_KEY"' in onboard
    assert all("sk-CODEX-TEST-ONLY" not in c for c in calls)
    assert applier.verify(profiles) == []


def test_codex_credentials_are_not_an_openai_type_alias(ab):
    with pytest.raises(ab.InstallerError, match="is for 'codex'"):
        ab.check_provider_type(ab.Provider("openai", "openai", credential_secret="inference"), "codex")
