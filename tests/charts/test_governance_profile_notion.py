"""Keep the demo's Notion capability compatible and read-only."""

from pathlib import Path

import pytest
import yaml


@pytest.mark.ci_external
def test_notion_profile_uses_supported_read_only_contract():
    path = Path(__file__).resolve().parents[2] / "charts/governance-policy/profiles/notion.yaml"
    profile = yaml.safe_load(path.read_text())
    # Unsupported categories prevent the entire updated catalog from loading.
    assert profile["category"] == "other"
    assert len(profile["endpoints"]) == 1
    endpoint = profile["endpoints"][0]
    assert endpoint["host"] == "api.notion.com" and endpoint["port"] == 443
    assert endpoint["protocol"] == "rest" and endpoint["enforcement"] == "enforce"
    assert endpoint["access"] == "read-only"
    assert not endpoint.get("rules"), "do not override the read-only access policy"
    assert profile["discovery"]["credentials"] == ["api_key"]
    assert profile["credentials"][0]["env_vars"] == ["NOTION_API_KEY"]
