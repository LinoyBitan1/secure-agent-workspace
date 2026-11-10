"""Notion demo policy permits reading pages and blocks, never writing them."""

import re
from pathlib import Path

import pytest
import yaml


PROFILE = Path(__file__).resolve().parents[2] / "charts/governance-policy/profiles/notion.yaml"


@pytest.mark.ci_external
def test_notion_uses_the_supported_other_category():
    profile = yaml.safe_load(PROFILE.read_text())
    # The interceptor rejects unknown categories and retains its old catalog.
    assert profile["category"] == "other"


@pytest.mark.ci_external
@pytest.mark.parametrize("host,method,path,expected", [
    ("api.notion.com", "GET", "/v1/pages/demo-page", True),
    ("api.notion.com", "GET", "/v1/blocks/demo-block", True),
    ("api.notion.com", "GET", "/v1/blocks/demo-block/children", True),
    ("api.notion.com", "POST", "/v1/pages", False),
    ("api.notion.com", "PATCH", "/v1/pages/demo-page", False),
    ("api.notion.com", "PATCH", "/v1/blocks/demo-block/children", False),
    ("api.notion.com", "DELETE", "/v1/blocks/demo-block", False),
    ("api.notion.com", "POST", "/v1/search", False),
    ("api.notion.com", "GET", "/v1/pages/demo-page/unapproved", False),
    ("example.com", "GET", "/v1/pages/demo-page", False),
])
def test_notion_read_boundaries(host, method, path, expected):
    profile = yaml.safe_load(PROFILE.read_text())
    # Match the same single-segment path globs as the briefing profile tests.
    allowed = any(
        endpoint["host"] == host
        and endpoint["port"] == 443
        and endpoint["enforcement"] == "enforce"
        and rule["allow"]["method"] == method
        and re.fullmatch(re.escape(rule["allow"]["path"]).replace(r"\*", "[^/]*"), path)
        for endpoint in profile["endpoints"] for rule in endpoint["rules"]
    )
    assert bool(allowed) is expected
