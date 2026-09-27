"""Harness bundle contract: digest, parsing, packaging invariants."""

import base64
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
    assert [t.governance_profile for t in bundles["ds-default"].tools] == ["web-search"]
