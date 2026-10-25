"""Real GNU tar coverage for non-root sandbox restores."""
import hashlib
import io
import os
import shutil
import subprocess
import tarfile

import pytest


@pytest.fixture
def restore(ab, tmp_path):
    if "GNU tar" not in subprocess.run(["tar", "--version"], capture_output=True, text=True).stdout:
        pytest.skip("needs GNU tar")
    if os.getuid() == 0:
        pytest.skip("requires the non-root identity used by sandbox exec")
    archive = tmp_path / "original.tar.gz"
    with tarfile.open(archive, "w:gz") as packed:
        member = tarfile.TarInfo(".bashrc")
        member.uid, member.gid = os.getuid(), 0
        member.uname, member.gname = "sandbox", "root"
        member.mode, member.size = 0o664, 7
        member.pax_headers = {"gid": "0", "gname": "root"}
        packed.addfile(member, io.BytesIO(b"payload"))
        link = tarfile.TarInfo("link")
        link.type, link.linkname = tarfile.SYMTYPE, ".bashrc"
        link.uid, link.gid = member.uid, member.gid
        link.mode = 0o777
        packed.addfile(link)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    fresh = tmp_path / "sandbox"
    fresh.mkdir()
    applier = ab.ProfileApplier(ab.Shell(), {"mtlsGateway": "g"}, {})
    calls = []
    tamper = []

    def cli(*args, **kwargs):
        calls.append(args)
        if args[:2] == ("sandbox", "upload"):
            shutil.copyfile(args[-2], fresh / ".saw-preserve.tar.gz")
            return ab.Result(0, "", "")
        command = list(args[args.index("--") + 1:])
        if command[:2] == ["sh", "-c"]:
            script = command[-1].replace("/sandbox", str(fresh))
            if tamper:
                script = script.replace("tar -tzf", tamper[0] + "; tar -tzf", 1)
            command[-1] = "umask 027; " + script
        else:
            command = [c.replace("/sandbox", str(fresh)) for c in command]
        result = subprocess.run(command, capture_output=True, text=True)
        return ab.Result(result.returncode, result.stdout, result.stderr)

    applier.cli = cli
    ws, sb = ab.Workspace(name="default"), ab.Sandbox(name="notebook")
    record = {"archive": str(archive), "sha256": digest}
    return applier, ws, sb, record, fresh, archive, calls, tamper


def test_restore_preserves_modes_with_foreign_archive_group_and_restrictive_umask(restore):
    applier, ws, sb, record, fresh, archive, calls, _ = restore
    original = archive.read_bytes()
    applier.restore_sandbox(ws, sb, record)
    assert (fresh / ".bashrc").read_bytes() == b"payload"
    assert (fresh / ".bashrc").stat().st_mode & 0o777 == 0o664
    assert (fresh / ".bashrc").stat().st_gid == os.getgid()
    assert (fresh / "link").is_symlink() and os.readlink(fresh / "link") == ".bashrc"
    assert not (fresh / ".saw-preserve.tar.gz").exists()
    assert archive.read_bytes() == original


@pytest.mark.parametrize("damage", ["content", "mode"])
def test_restore_still_rejects_changed_content_or_modes(ab, restore, damage):
    applier, ws, sb, record, fresh, archive, _, tamper = restore
    target = fresh / ".bashrc"
    tamper.append(f"printf corrupt > {target}" if damage == "content" else f"chmod 600 {target}")
    with pytest.raises(ab.InstallerError, match="could not restore"):
        applier.restore_sandbox(ws, sb, record)
    assert archive.exists() and (fresh / ".saw-preserve.tar.gz").exists()
    assert not (fresh / ".saw-preserve.sha256").exists()


def test_restore_rejects_corrupted_source_archive_before_upload(ab, restore):
    applier, ws, sb, record, _, archive, calls, _ = restore
    archive.write_bytes(archive.read_bytes() + b"corrupt")
    with pytest.raises(ab.InstallerError, match="checksum"):
        applier.restore_sandbox(ws, sb, record)
    assert not any(c[:2] == ("sandbox", "upload") for c in calls)


def test_retry_after_verified_restore_keeps_new_user_edits(restore):
    applier, ws, sb, record, fresh, _, calls, _ = restore
    applier.restore_sandbox(ws, sb, record)
    (fresh / ".bashrc").write_text("new work after restore")
    calls.clear()
    # The installer died before removing the migration record.
    applier.restore_sandbox(ws, sb, record)
    assert (fresh / ".bashrc").read_text() == "new work after restore"
    assert not any(c[:2] == ("sandbox", "upload") for c in calls)


def test_a_stamp_for_another_archive_does_not_skip_restore(restore):
    applier, ws, sb, record, fresh, _, _, _ = restore
    (fresh / ".saw-preserve.sha256").write_text("0" * 64)
    applier.restore_sandbox(ws, sb, record)
    assert (fresh / ".bashrc").read_text() == "payload"
    assert (fresh / ".saw-preserve.sha256").read_text() == record["sha256"]
