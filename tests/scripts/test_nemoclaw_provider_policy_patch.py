"""Exercise the actual upstream prerequisite after the downstream source patch."""
import json
import re
import shlex
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
DOCKERFILE = ROOT / "image-builder-charts/helm/nemoclaw-cli-imagestream/files/Dockerfile"
FIXTURE = ROOT / "tests/fixtures/nemoclaw-provider-policy-v0.0.133.ts"
NODE = shutil.which("node")

HARNESS = r'''
const fs = require("node:fs");
const input = JSON.parse(process.argv[2]);
let source = fs.readFileSync(process.argv[1], "utf8")
  .replace(/: OpenShellProviderAdapter\["ensureProviderPolicyComposition"\]/g, "")
  .replace(/(failure|success)<string>/g, "$1");
const calls = [];
const document = input.document;
const invoke = (args, request) => {
  calls.push({args, gateway:request.target.gatewayName});
  if (args[0] === "gateway") return {status:input.infoStatus ?? 0, stdout:JSON.stringify(input.info)};
  if (args[1] === "set") {
    if (!input.unconfirmed) document.settings.providers_v2_enabled = "true";
    return {status:0, stdout:""};
  }
  return {status:input.settingsStatus ?? 0, stdout:JSON.stringify(document)};
};
const make = new Function("invoke", "commandError", "bufferOrStringToText", "failure",
  "success", "namedGatewayEndpointOverrideError", "environment", source + ";return ensureProviderPolicyComposition;");
const fn = make(invoke, r=>r.status===0?null:{kind:"transport",message:"failed"},
  x=>String(x), error=>({ok:false,error}), value=>({ok:true,value}), ()=>null, {});
fn({target:{kind:"named",gatewayName:"nemoclaw-17670"}})
  .then(result=>process.stdout.write(JSON.stringify({result,calls})));
'''


def run_prerequisite(tmp_path, *, settings=None, info=None, **options):
    source = tmp_path / "src/lib/adapters/openshell/provider-adapter-cli.ts"
    source.parent.mkdir(parents=True, exist_ok=True)
    source.write_bytes(FIXTURE.read_bytes())
    identity = source.with_name("sandbox-identity.ts")
    identity.write_text('const limitFlag = (input, timeout) => "--limit";\n'
                        'function parsePage(output) { let rows; try { rows = JSON.parse(output); } '
                        'catch { return null; } return Array.isArray(rows) ? rows : null; }')
    command = re.search(r"^RUN (node -e .*?)\nRUN npm run build:cli", DOCKERFILE.read_text(),
                        re.MULTILINE | re.DOTALL).group(1).replace("\\\n", "")
    subprocess.run(shlex.split(command), cwd=tmp_path, check=True, capture_output=True, text=True)
    payload = {"document": {"scope": "global", "settings": settings or {}},
               "info": info or {"gateway": "nemoclaw-17670", "status": "healthy",
                                "version": "0.1.2-rhaiv.0"}, **options}
    result = subprocess.run([NODE, "-e", HARNESS, str(source), json.dumps(payload)],
                            check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


@pytest.mark.skipif(not NODE, reason="node is not installed")
@pytest.mark.parametrize("version", ["0.1.2", "0.1.2-rhaiv.0"])
def test_native_policy_recognizes_the_verified_gateway_without_legacy_flag(tmp_path, version):
    result = run_prerequisite(tmp_path, info={"gateway": "nemoclaw-17670", "status": "healthy",
                                              "version": version})
    assert result["result"]["ok"]
    assert [c["args"][:2] for c in result["calls"]] == [["settings", "get"], ["gateway", "info"]]
    assert all(c["gateway"] == "nemoclaw-17670" for c in result["calls"])


@pytest.mark.parametrize("value,ok", [("true", True), ("false", False), ("invalid", False)])
def test_existing_policy_setting_is_preserved(tmp_path, value, ok):
    result = run_prerequisite(tmp_path, settings={"providers_v2_enabled": value})
    assert result["result"]["ok"] is ok
    assert len(result["calls"]) == 1


def test_legacy_unset_setting_is_enabled_and_verified(tmp_path):
    result = run_prerequisite(tmp_path, settings={"providers_v2_enabled": "<unset>"})
    assert result["result"]["ok"]
    assert [c["args"][:2] for c in result["calls"]] == [
        ["settings", "get"], ["settings", "set"], ["settings", "get"]]
    assert not run_prerequisite(tmp_path, settings={"providers_v2_enabled": "<unset>"},
                                unconfirmed=True)["result"]["ok"]


@pytest.mark.parametrize("info", [
    {"gateway": "nemoclaw-17670", "status": "healthy", "version": "0.0.116"},
    {"gateway": "nemoclaw-17670", "status": "healthy", "version": "0.2.0"},
    {"gateway": "other", "status": "healthy", "version": "0.1.2"},
    {"gateway": "nemoclaw-17670", "status": "unhealthy", "version": "0.1.2"},
    {"gateway": "nemoclaw-17670", "status": "healthy", "version": "0.1.2-alpha"},
    {"gateway": "nemoclaw-17670", "status": "healthy", "version": ["0.1.2"]},
])
def test_unknown_or_unhealthy_gateway_cannot_bypass_policy_validation(tmp_path, info):
    result = run_prerequisite(tmp_path, info=info)
    assert not result["result"]["ok"]
    assert not any(c["args"][:2] == ["settings", "set"] for c in result["calls"])


def test_transport_failure_does_not_imply_policy_composition(tmp_path):
    assert not run_prerequisite(tmp_path, infoStatus=1)["result"]["ok"]
    assert not run_prerequisite(tmp_path, settingsStatus=1)["result"]["ok"]


@pytest.mark.parametrize("help_text,flag", [("--page-size <PAGE_SIZE>", "--page-size"),
                                         ("--limit <LIMIT>", "--limit")])
def test_identity_pagination_preserves_the_installed_cli_contract(tmp_path, help_text, flag):
    run_prerequisite(tmp_path)
    identity = tmp_path / "src/lib/adapters/openshell/sandbox-identity.ts"
    code = ('const fs=require("fs");const make=new Function(fs.readFileSync(process.argv[1],"utf8")'
            '+";return limitFlag;");const f=make();process.stdout.write('
            'f({runCaptureOpenshell:()=>process.argv[2]},1000));')
    result = subprocess.run([NODE, "-e", code, str(identity), help_text],
                            check=True, capture_output=True, text=True)
    assert result.stdout == flag


@pytest.mark.parametrize("payload,expected", [
    ([], []), ([{"id": "legacy"}], [{"id": "legacy"}]),
    ({"sandboxes": [], "next_page_token": ""}, []),
    ({"sandboxes": [{"id": "native"}], "next_page_token": ""}, [{"id": "native"}]),
    ({"sandboxes": [{"id": "partial"}], "next_page_token": "more"}, None),
    ({"sandboxes": []}, None), ({"sandboxes": "invalid", "next_page_token": ""}, None),
    (None, None),
])
def test_identity_parser_requires_a_complete_page(tmp_path, payload, expected):
    run_prerequisite(tmp_path)
    identity = tmp_path / "src/lib/adapters/openshell/sandbox-identity.ts"
    code = ('const fs=require("fs");const f=new Function(fs.readFileSync(process.argv[1],"utf8")'
            '+";return parsePage;")();process.stdout.write(JSON.stringify(f(process.argv[2])));')
    result = subprocess.run([NODE, "-e", code, str(identity), json.dumps(payload)],
                            check=True, capture_output=True, text=True)
    assert json.loads(result.stdout) == expected
