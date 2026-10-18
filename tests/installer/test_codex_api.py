"""SAW's Codex API-key choice uses the governed OpenAI API provider."""

import pytest
import yaml

from conftest import ROOT, profile_files


def test_codex_api_key_is_accepted_by_openai_but_not_nvidia(ab):
    ab.check_provider_type(ab.Provider("openai", "openai", credential_secret="inference"), "codex")
    with pytest.raises(ab.InstallerError, match="is for 'codex'"):
        ab.check_provider_type(ab.Provider("nvidia", "nvidia", credential_secret="inference"), "codex")


def test_codex_profile_uses_only_openclaw_and_vended_provider_names(ab, bom):
    profiles = ab.parse_profiles(profile_files("codex"))
    assert len(profiles) == 1
    ab.validate_profiles(profiles)
    ab.check_profiles_against_bom(profiles, bom)
    ws = profiles[0].workspaces[0]
    ids = {yaml.safe_load(p.read_text())["id"]
           for p in (ROOT / "charts/governance-policy/profiles").glob("*.yaml")}
    assert {p.name for p in ws.providers} == {"openai"} <= ids
    assert [(s.type, s.providers) for s in ws.sandboxes] == [("openclaw", ["openai"])]


def test_codex_values_create_openai_provider_and_onboard_requested_model(
        ab, fake_env, config, secrets_dir):
    profiles = ab.parse_profiles(profile_files("codex"))
    assert profiles
    for key, value in {"provider": "codex", "model": "gpt-6-luna",
                       "api_key": "sk-CODEX-API-TEST"}.items():
        (secrets_dir / "inference" / key).write_text(value)
    creds = ab.resolve_credentials(profiles, secrets_dir)
    applier = ab.ProfileApplier(ab.Shell(), config, creds)
    applier.apply(profiles)
    state = fake_env.openshell_state()
    assert state["providers"]["default/openai"] == {
        "type": "openai", "credential": "OPENAI_API_KEY=sk-CODEX-API-TEST"}
    assert state["sandboxes"]["default/notebook"]["providers"] == ["openai"]
    calls = [" ".join(c) for c in fake_env.openshell_calls()]
    onboard = next(c for c in calls if "openclaw onboard" in c)
    assert "--custom-base-url https://api.openai.com/v1 " in onboard
    assert "--custom-model-id gpt-6-luna " in onboard
    assert 'CUSTOM_API_KEY="$OPENAI_API_KEY"' in onboard
    assert all("sk-CODEX-API-TEST" not in c for c in calls)
    assert applier.verify(profiles) == []
