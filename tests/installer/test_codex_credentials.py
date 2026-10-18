"""Codex subscription credentials must travel together without entering argv."""
import pytest


TOKENS = {
    "CODEX_AUTH_ACCESS_TOKEN": "test-access-token",
    "CODEX_AUTH_REFRESH_TOKEN": "test-refresh-token",
    "CODEX_AUTH_ACCOUNT_ID": "test-account-id",
}


def setup_codex(ab, tmp_path, extra=None):
    provider = ab.Provider(name="codex", type="codex", credential_secret="codex")
    ws = ab.Workspace(name="default", providers=[provider])
    profiles = [ab.Profile(name="tp", workspaces=[ws])]
    secret = tmp_path / "codex"
    secret.mkdir()
    for name, value in {**TOKENS, **(extra or {})}.items():
        (secret / name.removeprefix("CODEX_AUTH_").lower()).write_text(value + "\n")
    (secret / "provider").write_text("codex\n")
    return provider, ws, profiles


@pytest.mark.parametrize("with_id", [False, True])
def test_resolve_oauth_without_api_key(ab, tmp_path, with_id):
    extra = {"CODEX_AUTH_ID_TOKEN": "test-id-token"} if with_id else {}
    _, _, profiles = setup_codex(ab, tmp_path, extra)
    assert ab.resolve_credentials(profiles, tmp_path) == {"default": {"codex": {**TOKENS, **extra}}}


@pytest.mark.parametrize("key", ["access_token", "refresh_token", "account_id"])
def test_missing_oauth_field_fails_without_disclosing_tokens(ab, tmp_path, key):
    _, _, profiles = setup_codex(ab, tmp_path)
    (tmp_path / "codex" / key).unlink()
    with pytest.raises(ab.InstallerError) as error:
        ab.resolve_credentials(profiles, tmp_path)
    assert key in str(error.value)
    assert all(token not in str(error.value) for token in TOKENS.values())


def test_disabled_codex_needs_no_credentials(ab, tmp_path):
    provider, _, profiles = setup_codex(ab, tmp_path)
    provider.enabled = False
    (tmp_path / "codex" / "access_token").unlink()
    assert ab.resolve_credentials(profiles, tmp_path) == {}


def test_codex_secret_with_wrong_provider_is_rejected(ab, tmp_path):
    _, _, profiles = setup_codex(ab, tmp_path)
    (tmp_path / "codex" / "provider").write_text("openai\n")
    with pytest.raises(ab.InstallerError):
        ab.resolve_credentials(profiles, tmp_path)


def test_nemoclaw_does_not_receive_oauth_map_as_api_key(ab, tmp_path, config):
    provider, ws, profiles = setup_codex(ab, tmp_path)
    applier = ab.ProfileApplier(ab.Shell(), config, ab.resolve_credentials(profiles, tmp_path))
    with pytest.raises(ab.InstallerError, match="Codex OAuth onboarding through NemoClaw"):
        applier.onboard_nemoclaw(ws, ab.Sandbox(name="agent", type="nemoclaw"), provider)


def test_create_and_refresh_pass_every_credential_only_via_env(ab, tmp_path, config, monkeypatch):
    extra = {"CODEX_AUTH_ID_TOKEN": "test-id-token"}
    provider, ws, profiles = setup_codex(ab, tmp_path, extra)
    creds = ab.resolve_credentials(profiles, tmp_path)
    shell = ab.Shell()
    applier = ab.ProfileApplier(shell, config, creds)
    calls = []

    def run(cmd, **kwargs):
        calls.append((cmd, kwargs))
        return ab.Result(0, existed=True)

    monkeypatch.setattr(shell, "run", run)
    applier.apply_provider(ws, provider)
    assert len(calls) == 2
    for cmd, kwargs in calls:
        assert kwargs["env"] == {**TOKENS, **extra}
        names = [cmd[i + 1] for i, arg in enumerate(cmd) if arg == "--credential"]
        assert set(names) == set(TOKENS) | set(extra)
        assert all(value not in " ".join(cmd) for value in kwargs["env"].values())
        assert shell.mask(" ".join(kwargs["env"].values())) == "*** *** *** ***"
