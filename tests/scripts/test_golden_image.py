"""Golden disk source selection and the in-cluster mirror's rendered inputs."""
import os
import subprocess
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[2]
AIPCC = "docker://quay.io/aipcc/saw-golden-image/saw-disk-image-container:0.1.0"


def executable(path, body):
    path.write_text("#!/bin/bash\nset -euo pipefail\n" + body)
    path.chmod(0o755)


@pytest.fixture
def clean_env():
    env = dict(os.environ)
    for key in ("IMAGE_REPO", "IMAGE_TAG", "GOLDEN_IMAGE_URL", "IMAGES", "MIRROR_IMAGES", "OPENSHELL_VERSION"):
        env.pop(key, None)
    return env


@pytest.mark.parametrize("image,settings,expected", [
    ("openshell-gateway", {}, AIPCC),
    ("openshell-gateway", {"IMAGE_TAG": "sha-review"},
     "docker://ghcr.io/validatedpatterns-sandbox/openshell-gateway:sha-review"),
    ("openshell-gateway", {"IMAGE_REPO": "ghcr.io/my-fork"},
     "docker://ghcr.io/my-fork/openshell-gateway:latest"),
    ("openshell-gateway", {"GOLDEN_IMAGE_URL": "docker://quay.io/example/disk@sha256:" + "a" * 64},
     "docker://quay.io/example/disk@sha256:" + "a" * 64),
    ("openshell-gateway-docker", {},
     "docker://ghcr.io/validatedpatterns-sandbox/openshell-gateway-docker:latest"),
    ("saw-credential-proxy", {"GOLDEN_IMAGE_URL": AIPCC, "IMAGE_TAG": "sha-review"},
     "docker://ghcr.io/validatedpatterns-sandbox/saw-credential-proxy:sha-review"),
])
def test_golden_source_preserves_explicit_and_other_image_selection(clean_env, image, settings, expected):
    result = subprocess.run(
        ["bash", "-ec", 'source "$1/scripts/lib/golden-image.sh"; saw_image_source "$2"',
         "bash", str(ROOT), image], env={**clean_env, **settings}, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == expected


@pytest.mark.parametrize("url", ['docker://quay.io/x/disk:1"', "docker://quay.io/x/disk:1\nfoo", "https://quay.io/x/disk:1"])
def test_invalid_golden_source_stops_before_cluster_work(tmp_path, clean_env, url):
    bindir = tmp_path / "bin"
    bindir.mkdir()
    calls = tmp_path / "calls"
    executable(bindir / "oc", 'echo called >> "$CALLS"\nexit 93\n')
    for script in ("images-mirror.sh", "mirror-images-incluster.sh", "import-golden-image.sh"):
        result = subprocess.run(["bash", str(ROOT / "scripts" / script)],
                                env={**clean_env, "PATH": f"{bindir}:{os.environ['PATH']}",
                                     "CALLS": str(calls), "GOLDEN_IMAGE_URL": url},
                                capture_output=True, text=True)
        assert result.returncode != 0
        assert not calls.exists(), script


@pytest.mark.parametrize("via_make", [False, True])
def test_incluster_mirror_uses_aipcc_source_and_existing_internal_name(tmp_path, clean_env, via_make):
    bindir = tmp_path / "bin"
    bindir.mkdir()
    manifest = tmp_path / "job.yaml"
    calls = tmp_path / "calls"
    executable(bindir / "uname", 'echo Darwin\n')
    executable(bindir / "oc", '''
echo "$*" >> "$CALLS"
if [[ "$1" == apply ]]; then
  if [[ "$*" == *"-f -"* ]]; then cat > "$MANIFEST"; fi
elif [[ "$1 $2" == 'get job' && "$*" == *'.status.succeeded'* ]]; then
  echo 1
fi
''')
    env = {**clean_env, "PATH": f"{bindir}:{os.environ['PATH']}", "MANIFEST": str(manifest),
           "CALLS": str(calls), "BUILD_NS": "test-build"}
    args = (["make", "-s", "images-mirror"] if via_make else
            ["bash", str(ROOT / "scripts/mirror-images-incluster.sh")])
    result = subprocess.run(args, cwd=ROOT, env=env, capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    job = yaml.safe_load(manifest.read_text())
    container = job["spec"]["template"]["spec"]["containers"][0]
    values = {entry["name"]: entry["value"] for entry in container["env"]}
    assert values["MIRROR_SOURCE"] == AIPCC
    assert values["MIRROR_IMAGE"] == "openshell-gateway"
    assert values["MIRROR_TAG"] == "latest"
    assert "skopeo copy --all" in container["command"][2]
    assert '"${MIRROR_SOURCE}"' in container["command"][2]


@pytest.mark.parametrize("fail_socket", [False, True])
def test_gateway_setup_prepares_rootless_runtime_without_starting_gateway(tmp_path, clean_env, fail_socket):
    bindir = tmp_path / "bin"
    bindir.mkdir()
    home = tmp_path / "home"
    config = tmp_path / "etc-openshell"
    config.mkdir()
    (config / "gateway.env").write_text("OPENSHELL_SERVER_PORT=17670\n")
    (config / "gateway.toml").write_text("[openshell]\nversion = 2\n")
    calls = tmp_path / "calls"
    executable(bindir / "id", 'echo 1001\n')
    executable(bindir / "getent", 'echo "cloud-user:x:1001:1001::${TEST_HOME}:/bin/bash"\n')
    executable(bindir / "python3", '''
[[ "$1" == -c && "$2" == *yaml* && "$2" == *'(3, 9)'* && "$2" != *tomllib* ]]
''')
    for command in ("loginctl", "systemctl", "runuser", "chown"):
        executable(bindir / command, '''
echo "$(basename "$0") $*" >> "$CALLS"
if [[ "${FAIL_SOCKET:-0}" == 1 && "$*" == *'enable --now podman.socket'* ]]; then exit 1; fi
''')
    env = {**clean_env, "PATH": f"{bindir}:{os.environ['PATH']}", "TEST_HOME": str(home),
           "CALLS": str(calls), "FAIL_SOCKET": str(int(fail_socket))}
    script = ROOT / "charts/openshell-saw/files/guest/saw-gateway-setup"
    for _ in range(2):
        result = subprocess.run(["bash", str(script), str(config)], env=env,
                                capture_output=True, text=True, timeout=10)
        if fail_socket:
            assert result.returncode != 0
            assert "enable --now podman.socket" in calls.read_text()
            return
        assert result.returncode == 0, result.stderr
    settings = (home / ".config/openshell/gateway.env").read_text()
    assert settings.count("OPENSHELL_SERVER_PORT=") == 1
    assert settings.count("OPENSHELL_PODMAN_SOCKET=/run/user/1001/podman/podman.sock") == 1
    assert (home / ".config/openshell/gateway.toml").read_text() == (config / "gateway.toml").read_text()
    recorded = calls.read_text()
    assert "loginctl enable-linger cloud-user" in recorded
    assert "systemctl start user@1001.service" in recorded
    assert "enable --now podman.socket" in recorded
    assert "start openshell-gateway.service" not in recorded


def test_gateway_setup_reports_missing_installer_python_dependencies(tmp_path, clean_env):
    bindir = tmp_path / "bin"
    bindir.mkdir()
    executable(bindir / "id", 'echo 1001\n')
    executable(bindir / "getent", 'echo "cloud-user:x:1001:1001::/home/cloud-user:/bin/bash"\n')
    executable(bindir / "python3", 'echo "No module named yaml" >&2\nexit 1\n')
    result = subprocess.run(
        ["bash", str(ROOT / "charts/openshell-saw/files/guest/saw-gateway-setup")],
        env={**clean_env, "PATH": f"{bindir}:{os.environ['PATH']}"},
        capture_output=True, text=True)
    assert result.returncode != 0
    assert "Python 3.9+" in result.stderr and "PyYAML" in result.stderr
