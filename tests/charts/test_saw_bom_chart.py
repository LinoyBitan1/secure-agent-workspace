"""Render the saw-bom chart and check the harness packaging guards.

Needs `helm` on PATH (CI installs it).
"""

import base64
import importlib.util
import shutil
import subprocess
import sys
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[2]
CHART = ROOT / "charts" / "saw-bom"
HARNESS = CHART / "harness"
GOVERNANCE_PROFILES = ROOT / "charts" / "governance-policy" / "profiles"
SCRIPT = ROOT / "charts" / "openshell-saw" / "files" / "installer" / "apply_bom.py"
HELM = shutil.which("helm")

pytestmark = pytest.mark.skipif(not HELM, reason="helm is not installed")


@pytest.fixture(scope="module")
def ab():
    spec = importlib.util.spec_from_file_location("apply_bom", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules["apply_bom"] = module
    spec.loader.exec_module(module)
    return module


def helm_template(chart=CHART, *args, release="saw-bom-test", namespace="saw-alice"):
    return subprocess.run([HELM, "template", release, str(chart), "--namespace", namespace, *args],
                          capture_output=True, text=True)


def render(chart=CHART, *args):
    result = helm_template(chart, *args)
    assert result.returncode == 0, result.stderr
    docs = [d for d in yaml.safe_load_all(result.stdout) if d]
    return {(d["kind"], d["metadata"]["name"]): d for d in docs}


def render_error(chart=CHART, *args):
    result = helm_template(chart, *args)
    assert result.returncode != 0, "render was expected to fail"
    return result.stderr


def bom_data():
    docs = render()
    return docs[("ConfigMap", "saw-bom-profiles")]["data"]


def ds_default_digest(ab):
    files = {str(p.relative_to(HARNESS / "ds-default")): p.read_bytes()
             for p in sorted((HARNESS / "ds-default").rglob("*")) if p.is_file()}
    return ab.tree_digest(files)


def test_governance_profiles_match_the_enrolled_directory():
    values = yaml.safe_load((CHART / "values.yaml").read_text())
    stems = sorted(p.stem for p in GOVERNANCE_PROFILES.glob("*.yaml"))
    assert sorted(values["governanceProfiles"]) == stems


def test_configmap_ships_the_harness_manifest_byte_for_byte():
    data = bom_data()
    key = "harness__ds-default__harness.yaml"
    assert key in data
    on_disk = (HARNESS / "ds-default" / "harness.yaml").read_bytes()
    assert base64.b64decode(data[key]) == on_disk


def test_harness_index_digest_matches_tree_digest(ab):
    data = bom_data()
    index = yaml.safe_load(data["harness-index.yaml"])
    assert index["bundles"]["ds-default"] == ds_default_digest(ab)


def test_harness_ref_digest_mismatch_fails_the_render(tmp_path):
    copy = tmp_path / "saw-bom"
    shutil.copytree(CHART, copy)
    sandbox_path = copy / "profiles" / "data-science" / "default" / "sandbox.yaml"
    doc = yaml.safe_load(sandbox_path.read_text())
    doc["spec"]["sandboxes"][0]["harnessRef"] = {"name": "ds-default", "digest": "sha256:deadbeef"}
    sandbox_path.write_text(yaml.safe_dump(doc))
    err = render_error(copy)
    assert "harnessRef digest mismatch" in err


def test_unenrolled_governance_profile_fails_the_render(tmp_path):
    copy = tmp_path / "saw-bom"
    shutil.copytree(CHART, copy)
    manifest_path = copy / "harness" / "ds-default" / "harness.yaml"
    doc = yaml.safe_load(manifest_path.read_text())
    doc["spec"]["tools"][0]["governanceProfile"] = "nope"
    manifest_path.write_text(yaml.safe_dump(doc))
    err = render_error(copy)
    assert "not enrolled" in err


def test_bundle_key_over_the_joliet_limit_fails_the_render(tmp_path):
    copy = tmp_path / "saw-bom"
    shutil.copytree(CHART, copy)
    long_dir = copy / "harness" / "ds-default" / "skills" / ("x" * 40)
    long_dir.mkdir(parents=True)
    (long_dir / "SKILL.md").write_text("x\n")
    err = render_error(copy)
    assert "Joliet" in err
