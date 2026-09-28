"""Harness bundle contract: digest, parsing, packaging invariants."""

import base64
import hashlib
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


def test_read_profile_files_splits_profiles_from_harness(ab, tmp_path, shipped_harness_files):
    (tmp_path / "profiles__data-science__default__workspace.yaml").write_text("x: 1\n")
    for key, raw in shipped_harness_files.items():
        # The ConfigMap value is base64 (digest contract); raw bytes here would
        # fail b64decode(validate=True) and the test would assert the wrong thing.
        (tmp_path / key).write_text(base64.b64encode(raw).decode())
    (tmp_path / "harness-index.yaml").write_text(
        "bundles: {}\nenrolledGovernanceProfiles: [web-search]\n")
    profiles, harness, index = ab.read_profile_files(tmp_path)
    assert list(profiles) == ["profiles__data-science__default__workspace.yaml"]
    assert set(harness) == set(shipped_harness_files)
    assert index["enrolledGovernanceProfiles"] == ["web-search"]


def test_read_profile_files_rejects_a_harness_key_that_is_not_base64(ab, tmp_path):
    (tmp_path / "harness__demo__harness.yaml").write_text("a: 1\n")
    with pytest.raises(ab.InstallerError, match="not valid base64"):
        ab.read_profile_files(tmp_path)


def test_read_profile_files_still_rejects_an_unknown_key(ab, tmp_path):
    (tmp_path / "surprise.txt").write_text("x")
    with pytest.raises(ab.InstallerError, match="unexpected file"):
        ab.read_profile_files(tmp_path)


def test_parse_profiles_reads_harness_ref(ab):
    doc = yaml.safe_dump({"spec": {"sandboxes": [
        {"name": "notebook", "type": "openclaw", "enabled": True,
         "image": "img", "providers": [],
         "harnessRef": {"name": "ds-default", "digest": "sha256:abc"}}]}})
    files = {"profiles__p__default__workspace.yaml":
             yaml.safe_dump({"metadata": {"name": "default"}, "spec": {}}),
             "profiles__p__default__sandbox.yaml": doc}
    sb = ab.parse_profiles(files)[0].workspaces[0].sandboxes[0]
    assert sb.harness_ref == {"name": "ds-default", "digest": "sha256:abc"}


def _pinned(ab, bundles, digest, profile_name="web-search"):
    """A one-sandbox profile list pinned to bundles['ds-default']."""
    sb = ab.Sandbox(name="notebook", type="openclaw",
                    harness_ref={"name": "ds-default", "digest": digest})
    ws = ab.Workspace(name="default", sandboxes=[sb])
    return [ab.Profile(name="p", workspaces=[ws])]


def test_validate_harness_rejects_a_digest_mismatch(ab, shipped_harness_files):
    bundles = ab.parse_harness_files(shipped_harness_files)
    with pytest.raises(ab.InstallerError, match="digest mismatch"):
        ab.validate_harness(_pinned(ab, bundles, "sha256:STALE"), bundles, {"web-search"})


def test_validate_harness_rejects_a_missing_digest(ab, shipped_harness_files):
    bundles = ab.parse_harness_files(shipped_harness_files)
    profiles = _pinned(ab, bundles, "")
    with pytest.raises(ab.InstallerError, match="no digest"):
        ab.validate_harness(profiles, bundles, {"web-search"})


def test_validate_harness_rejects_an_unknown_bundle(ab):
    with pytest.raises(ab.InstallerError, match="unknown harness bundle"):
        ab.validate_harness(_pinned(ab, {}, "sha256:x"), {}, {"web-search"})


def test_validate_harness_rejects_an_unenrolled_tool(ab, shipped_harness_files):
    bundles = ab.parse_harness_files(shipped_harness_files)
    profiles = _pinned(ab, bundles, bundles["ds-default"].digest)
    with pytest.raises(ab.InstallerError, match="not enrolled"):
        ab.validate_harness(profiles, bundles, set())


def test_validate_harness_accepts_the_shipped_bundle(ab, shipped_harness_files):
    bundles = ab.parse_harness_files(shipped_harness_files)
    profiles = _pinned(ab, bundles, bundles["ds-default"].digest)
    assert ab.validate_harness(profiles, bundles, {"web-search"}) == {
        "notebook": f"ds-default@{bundles['ds-default'].digest}"}


def test_plan_round_trips_the_harness(ab, shipped_harness_files):
    import json
    bundles = ab.parse_harness_files(shipped_harness_files)
    plan = json.loads(json.dumps(ab.plan_for_user(
        {}, _pinned(ab, bundles, bundles["ds-default"].digest), {}, "d.sh",
        harness={"bundles": bundles, "enrolled": ["web-search"]})))
    back = ab.harness_from_plan(plan)
    assert back["bundles"]["ds-default"].digest == bundles["ds-default"].digest
    assert back["bundles"]["ds-default"].tools[0].governance_profile == "web-search"
    assert back["enrolled"] == {"web-search"}


def _staged(bundle, **override):
    """The managed tree as a correct apply would leave it: relpath -> sha256."""
    files = {rel: hashlib.sha256(base64.b64decode(b64)).hexdigest()
             for rel, b64 in bundle.files.items()
             if rel.split("/", 1)[0] in ("skills", "tools")}
    files.update(override)
    return files


def _adapter(ab, calls, bundle, live=None, revision="", heals=True, locked=()):
    """Adapter over a command-aware, minimally stateful fake shell.

    A constant fake is wrong here: `verify` and `current_revision` issue
    different commands, and one canned stdout makes verify fail for the wrong
    reason. `heals=True` models the wipe-then-write: after `rm -rf` the tree
    is exactly the bundle, so a restage converges. `heals=False` leaves the
    tree untouched, which is how a real failed apply looks. `locked` models
    files the shell can list but not read (e.g. host-root-owned): hashing
    reports them instead of silently dropping them.
    """
    state = dict(_staged(bundle) if live is None else live)

    def run(cmd, **k):
        script = str(cmd[-1])
        calls.append((list(map(str, cmd)), k.get("input_text")))
        if script.startswith("rm -rf") and heals:
            state.clear()
            state.update(_staged(bundle))
        if "sha256sum" in script:
            return ab.Result(0, "\n".join(
                f"UNREADABLE {rel}" if rel in locked else f"OK {h} {rel}"
                for rel, h in sorted(state.items(), key=lambda kv: kv[0])), "")
        if script.startswith("cat ") and ".saw-harness-revision" in script:
            return ab.Result(0, revision, "")
        return ab.Result(0, "", "")

    sh = ab.Shell()
    sh.run = run
    return ab.HarnessAdapter(sh)


def test_wipe_target_refuses_managed_root_itself(ab):
    with pytest.raises(ValueError, match="refusing to wipe"):
        ab.HarnessAdapter(ab.Shell(dry_run=True)).wipe_target("/sandbox/.openclaw", "")


def test_wipe_target_refuses_an_unmanaged_subdir(ab):
    with pytest.raises(ValueError, match="refusing to wipe"):
        ab.HarnessAdapter(ab.Shell(dry_run=True)).wipe_target("/sandbox/.openclaw", "state")


def test_wipe_targets_are_only_skills_and_tools(ab):
    a = ab.HarnessAdapter(ab.Shell(dry_run=True))
    assert a.wipe_target("/sandbox/.openclaw/", "skills") == "/sandbox/.openclaw/skills"
    assert a.wipe_target("/sandbox/.openclaw", "tools") == "/sandbox/.openclaw/tools"


def test_apply_wipes_then_stages_then_writes_the_revision(ab, shipped_harness_files):
    bundle = ab.parse_harness_files(shipped_harness_files)["ds-default"]
    calls = []
    _adapter(ab, calls, bundle).apply("notebook", "default", bundle)
    joined = "\n".join(" ".join(c) for c, _ in calls)
    assert "rm -rf /sandbox/.openclaw/skills /sandbox/.openclaw/tools" in joined
    assert "/sandbox/.openclaw/skills/pattern-author/SKILL.md" in joined
    assert "/sandbox/.openclaw/tools/web-search.yaml" in joined
    # harness.yaml is bundle metadata, not harness content: it is not staged.
    assert "/sandbox/.openclaw/harness.yaml" not in joined
    assert ".saw-harness-revision" in joined
    assert f"ds-default@{bundle.digest}" in joined
    # Every staged file arrives base64 on stdin, never in argv.
    assert any(text for _, text in calls)


def test_apply_never_touches_the_state_directory(ab, shipped_harness_files):
    bundle = ab.parse_harness_files(shipped_harness_files)["ds-default"]
    calls = []
    _adapter(ab, calls, bundle).apply("notebook", "default", bundle)
    for cmd, _ in calls:
        assert "/sandbox/.openclaw/state" not in " ".join(cmd)


def test_current_revision_reads_the_marker(ab, shipped_harness_files):
    bundle = ab.parse_harness_files(shipped_harness_files)["ds-default"]
    rev = f"ds-default@{bundle.digest}"
    assert _adapter(ab, [], bundle, revision=rev).current_revision(
        "notebook", "default", bundle) == rev


def test_reconcile_skips_when_the_revision_matches_and_nothing_drifted(
        ab, shipped_harness_files, capsys):
    bundle = ab.parse_harness_files(shipped_harness_files)["ds-default"]
    calls = []
    a = _adapter(ab, calls, bundle, revision=f"ds-default@{bundle.digest}")
    assert a.reconcile("notebook", "default", bundle) is False
    assert "rm -rf" not in "\n".join(" ".join(c) for c, _ in calls)
    assert "up to date" in capsys.readouterr().out.lower()


def test_reconcile_applies_when_the_revision_differs(ab, shipped_harness_files):
    bundle = ab.parse_harness_files(shipped_harness_files)["ds-default"]
    calls = []
    a = _adapter(ab, calls, bundle, revision="ds-default@sha256:OLD")
    assert a.reconcile("notebook", "default", bundle) is True
    assert "rm -rf" in "\n".join(" ".join(c) for c, _ in calls)


def test_reconcile_restages_on_drift_even_when_the_revision_matches(
        ab, shipped_harness_files):
    """Skip-on-match alone would never look, so drift would go undetected."""
    bundle = ab.parse_harness_files(shipped_harness_files)["ds-default"]
    calls = []
    a = _adapter(ab, calls, bundle, revision=f"ds-default@{bundle.digest}",
                 live=_staged(bundle, **{"skills/rogue": "00"}))
    assert a.reconcile("notebook", "default", bundle) is True
    assert "rm -rf" in "\n".join(" ".join(c) for c, _ in calls)


def test_reconcile_raises_when_the_sandbox_still_drifts_after_apply(
        ab, shipped_harness_files):
    """heals=False: the wipe does not take, so the leftover survives apply."""
    bundle = ab.parse_harness_files(shipped_harness_files)["ds-default"]
    a = _adapter(ab, [], bundle, revision="ds-default@sha256:OLD",
                 live=_staged(bundle, **{"skills/rogue": "00"}), heals=False)
    with pytest.raises(ab.InstallerError, match="unexpected: skills/rogue"):
        a.reconcile("notebook", "default", bundle)


def test_compare_is_content_aware_not_just_name_aware(ab):
    a = ab.HarnessAdapter(ab.Shell(dry_run=True))
    assert a.compare({"a": "h1"}, {"a": "h1"}) == []
    assert a.compare({"a": "h1"}, {"a": "h1", "revoked": "h2"}) == ["unexpected: revoked"]
    assert a.compare({"a": "h1", "b": "h2"}, {"a": "h1"}) == ["missing: b"]
    # The hole a name-set comparison leaves: an empty or truncated file.
    assert a.compare({"a": "h1"}, {"a": "h2"}) == ["content differs: a"]


def test_verify_catches_an_empty_staged_file(ab, shipped_harness_files):
    """Regression for the unverified base64-over-stdin transport: if the CLI
    does not forward stdin, files land empty and a name-only check passes."""
    bundle = ab.parse_harness_files(shipped_harness_files)["ds-default"]
    live = _staged(bundle, **{
        "skills/pattern-author/SKILL.md": hashlib.sha256(b"").hexdigest()})
    a = _adapter(ab, [], bundle, live=live, heals=False)
    assert a.verify("notebook", "default", bundle) == [
        "content differs: skills/pattern-author/SKILL.md"]


def test_verify_reports_files_it_can_list_but_not_read(ab, shipped_harness_files):
    """Fail closed, not silent: a managed file the shell lists but cannot hash
    (found live: host-root-owned +i file, readable by ls/stat, EACCES on open)
    must fail verify instead of dropping out of a batched hash listing."""
    bundle = ab.parse_harness_files(shipped_harness_files)["ds-default"]
    a = _adapter(ab, [], bundle, heals=False,
                 locked=("skills/pattern-author/SKILL.md",))
    assert a.verify("notebook", "default", bundle) == [
        "unreadable: skills/pattern-author/SKILL.md"]
