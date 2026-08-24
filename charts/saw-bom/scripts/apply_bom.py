#!/usr/bin/env python3
"""
apply_bom.py — BOM-driven agent configuration for SAW.

Single entry point for provisioning an OpenShell Secure Agent Workspace.
Reads BOM profile directories, sets up the gateway, installs CLIs as needed,
creates workspaces, providers, and sandboxes.

Runs INSIDE the gateway VM.

Usage:
    python3 apply_bom.py --profiles-dir /path/to/profiles \
        --oidc-gateway openshell --mtls-gateway openshell-local
"""

import argparse
import json
import os
import re
import shlex
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path

import yaml


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------

@dataclass
class Provider:
    name: str
    type: str
    enabled: bool = True
    nemoclaw_provider: str = ""
    credential_key: str = ""
    credential_secret: str = ""
    credential_secret_key: str = "api_key"
    model: str = ""


@dataclass
class Sandbox:
    name: str
    type: str = "generic"       # nemoclaw, openclaw, generic
    enabled: bool = True
    agent: str = "openclaw"     # openclaw, hermes
    image: str = ""
    providers: list = field(default_factory=list)
    model: str = ""
    command: str = ""
    expose_port: int = 0
    env: dict = field(default_factory=dict)
    runtime_env: dict = field(default_factory=dict)
    gateway_pre_start: str = ""
    run_as_user: str = ""
    run_as_group: str = ""


@dataclass
class Workspace:
    name: str
    enabled: bool = True
    description: str = ""
    providers: list = field(default_factory=list)
    sandboxes: list = field(default_factory=list)


@dataclass
class Profile:
    name: str
    workspaces: list = field(default_factory=list)


# ---------------------------------------------------------------------------
# Shell runner
# ---------------------------------------------------------------------------

class Shell:
    def __init__(self, dry_run=False):
        self.dry_run = dry_run

    def run(self, cmd, env=None, check=True):
        display = re.sub(
            r'(--credential\s+\S+=)\S+',
            r'\1***',
            " ".join(cmd))
        display = re.sub(
            r'(API_KEY=|api_key=|TOKEN=|token=)\S+',
            r'\1***',
            display)
        # openclaw's own "config set gateway.auth.token '<value>'" call style has
        # no '=' at all, so the regex above never touches it — this leaked the
        # raw gateway auth token to Job logs in plaintext. Catch it explicitly.
        display = re.sub(
            r"(gateway\.auth\.token\s+')[^']+(')",
            r'\1***\2',
            display)
        if self.dry_run:
            log(f"[dry-run] {display}")
            return 0, "", ""
        log(f"$ {display}")
        try:
            result = subprocess.run(
                cmd, capture_output=True, text=True,
                env={**os.environ, **(env or {})}, check=False
            )
        except FileNotFoundError:
            log(f"  WARN: command not found: {cmd[0]}")
            return 1, "", f"{cmd[0]}: not found"
        stdout = result.stdout.strip()
        stderr = result.stderr.strip()
        if stdout:
            for line in stdout.split("\n"):
                log(f"  {line}")
        if result.returncode != 0:
            if "already exists" in (stdout + stderr):
                log("  (already exists)")
                return 0, stdout, stderr
            if stderr:
                log(f"  WARN: {stderr[:300]}")
        return result.returncode, stdout, stderr


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def log(msg, indent=0):
    prefix = "  " * indent
    print(f"{prefix}{msg}", flush=True)


def banner(title):
    log(f"\n{'=' * 60}")
    log(title)
    log(f"{'=' * 60}")


def section(title):
    log(f"\n  [{title}]")


# ---------------------------------------------------------------------------
# Profile parser
# ---------------------------------------------------------------------------

def load_yaml_file(path):
    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


def resolve_env_value(value):
    """Resolve $VAR / ${VAR} indirection from process env."""
    if not isinstance(value, str):
        return value
    text = value.strip()
    match = re.fullmatch(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", text)
    if not match:
        match = re.fullmatch(r"\$([A-Za-z_][A-Za-z0-9_]*)", text)
    if not match:
        return value
    return os.environ.get(match.group(1), "")


def parse_profiles(profiles_dir):
    profiles = []
    for profile_entry in sorted(Path(profiles_dir).iterdir()):
        if not profile_entry.is_dir():
            continue
        profile = Profile(name=profile_entry.name)
        for ws_entry in sorted(profile_entry.iterdir()):
            if not ws_entry.is_dir():
                continue
            ws_file = ws_entry / "workspace.yaml"
            if not ws_file.exists():
                log(f"WARN: {ws_entry} missing workspace.yaml, skipping")
                continue
            ws_data = load_yaml_file(ws_file)
            ws_meta = ws_data.get("metadata", {})
            ws = Workspace(
                name=ws_meta.get("name", ws_entry.name),
                enabled=ws_data.get("spec", {}).get("enabled", True),
                description=ws_meta.get("description", ""),
            )
            prov_file = ws_entry / "providers.yaml"
            if prov_file.exists():
                prov_data = load_yaml_file(prov_file)
                for p in prov_data.get("spec", {}).get("providers", []):
                    ws.providers.append(Provider(
                        name=p["name"],
                        type=p["type"],
                        enabled=p.get("enabled", True),
                        nemoclaw_provider=p.get("nemoclawProvider", ""),
                        credential_key=p.get("credentialKey", ""),
                        credential_secret=p.get("credentialSecret", ""),
                        credential_secret_key=p.get("credentialSecretKey", "api_key"),
                        model=p.get("model", ""),
                    ))
            sb_file = ws_entry / "sandbox.yaml"
            if sb_file.exists():
                sb_data = load_yaml_file(sb_file)
                for s in sb_data.get("spec", {}).get("sandboxes", []):
                    ws.sandboxes.append(Sandbox(
                        name=s["name"],
                        type=s.get("type", "generic"),
                        enabled=s.get("enabled", True),
                        agent=s.get("agent", "openclaw"),
                        image=s.get("image", ""),
                        providers=s.get("providers", []),
                        model=s.get("model", ""),
                        command=s.get("command", ""),
                        expose_port=s.get("exposePort", 0),
                        env=s.get("env", {}),
                        runtime_env=s.get("runtimeEnv", {}),
                        gateway_pre_start=s.get("gatewayPreStart", ""),
                        run_as_user=str(s.get("runAsUser", "")),
                        run_as_group=str(s.get("runAsGroup", "")),
                    ))
            profile.workspaces.append(ws)
        if profile.workspaces:
            profiles.append(profile)
    return profiles




# ---------------------------------------------------------------------------
# Credential resolver
# ---------------------------------------------------------------------------

PROVIDER_CRED_MAP = {
    "gemini": "GEMINI_API_KEY",
    "google-vertex-ai": "GOOGLE_API_KEY",
    "claude-code": "ANTHROPIC_API_KEY",
    "codex": "OPENAI_API_KEY",
    "nvidia": "NVIDIA_API_KEY",
    "build": "NVIDIA_INFERENCE_API_KEY",
    "brave": "BRAVE_API_KEY",
    "tavily": "TAVILY_API_KEY",
}


def resolve_credential(provider):
    env_var = f"PROV_{provider.name}_KEY".replace("-", "_").upper()
    val = os.environ.get(env_var)
    if val:
        return val
    cred_key = PROVIDER_CRED_MAP.get(provider.type)
    if cred_key:
        val = os.environ.get(cred_key)
        if val:
            return val
    return None


def resolve_configured_type(provider):
    """The credential secret's own `provider:` field (if setup-bom-profiles.sh
    found one alongside the API key), e.g. "gemini" or "build" (NVIDIA
    Build's own provider identifier — distinct from the OpenShell provider
    *type* "nvidia"). Returns None if not present, e.g. for secrets that
    don't carry a provider field at all.
    """
    env_var = f"PROV_{provider.name}_TYPE".replace("-", "_").upper()
    return os.environ.get(env_var) or None


def check_provider_type_mismatch(provider):
    """Validate that the credential secret's own declared provider matches
    what this BOM profile expects, before we create a provider using a
    credential that may belong to an entirely different service. Returns
    an error string if there's a mismatch, or None if it's fine / unknown.

    A profile's `type` (the OpenShell provider type, e.g. "nvidia") and
    `nemoclaw_provider` (a NemoClaw-specific alias, e.g. "build" for NVIDIA
    Build) are both accepted as valid matches, since values-secret.yaml's
    documented provider identifiers ("gemini, anthropic, openai, build
    (NVIDIA), openrouter, ...") use the nemoclaw-style alias, not the
    OpenShell type, for NVIDIA specifically.
    """
    configured = resolve_configured_type(provider)
    if not configured:
        return None
    valid = {v for v in (provider.type, provider.nemoclaw_provider) if v}
    if configured not in valid:
        expected = " or ".join(sorted(valid)) if valid else provider.type
        return (f"BOM profile expects provider type '{expected}' for "
                f"'{provider.name}', but the credential secret is "
                f"configured for provider '{configured}'")
    return None


def find_provider(ws, names):
    """Look up a provider by name from a sandbox's own declared providers list.

    Falls back to the first workspace provider only if the sandbox didn't
    declare any (or none of its declared names match) — previously this
    fallback was the *only* behavior, silently ignoring `sandbox.providers`
    entirely and wiring up whatever happened to be first in the workspace's
    provider list (e.g. attaching a web-search credential as if it were an
    LLM provider, if that provider happened to be declared first).
    """
    for name in names or []:
        for p in ws.providers:
            if p.name == name:
                return p
    return ws.providers[0] if ws.providers else None


# ---------------------------------------------------------------------------
# Gateway setup
# ---------------------------------------------------------------------------

class GatewaySetup:
    def __init__(self, shell, oidc_gw, mtls_gw):
        self.sh = shell
        self.oidc_gw = oidc_gw
        self.mtls_gw = mtls_gw

    def configure_oidc(self, token, issuer, client_id):
        if not token:
            return
        section("Configuring OIDC token")
        gw_name = self.oidc_gw
        token_dir = Path.home() / ".config" / "openshell" / "gateways" / gw_name
        token_dir.mkdir(parents=True, exist_ok=True)
        token_path = token_dir / "oidc_token.json"
        token_data = {
            "access_token": token,
            "issuer": issuer,
            "client_id": client_id,
        }
        with open(token_path, "w", encoding="utf-8") as f:
            json.dump(token_data, f)
        token_path.chmod(0o600)
        log(f"OIDC token written for gateway '{gw_name}'")

    def register_mtls_gateway(self):
        section("Registering mTLS gateway")
        self.sh.run(["openshell", "gateway", "remove", self.mtls_gw],
                     check=False)
        self.sh.run([
            "openshell", "gateway", "add",
            "https://127.0.0.1:17670",
            "--name", self.mtls_gw, "--local"
        ])
        self.sh.run(["openshell", "gateway", "select", self.mtls_gw])

    def grant_default_workspace_access(self):
        section("Granting default workspace access")
        self.select_mtls()
        self.sh.run([
            "openshell", "workspace", "member", "add",
            "--workspace", "default",
            "--subject", "openshell-client",
            "--role", "admin"
        ], check=False)

    def enable_providers_v2(self):
        section("Enabling providers_v2")
        self.select_mtls()
        self.sh.run([
            "openshell", "settings", "set",
            "--global", "--key", "providers_v2_enabled",
            "--value", "true", "--yes"
        ], check=False)

    def select_oidc(self):
        if self.oidc_gw:
            self.sh.run(["openshell", "gateway", "select", self.oidc_gw],
                         check=False)

    def select_mtls(self):
        self.sh.run(["openshell", "gateway", "select", self.mtls_gw],
                     check=False)

    def _with_oidc(self, fn):
        if self.oidc_gw:
            self.select_oidc()
            fn()
            self.select_mtls()
        else:
            fn()


# ---------------------------------------------------------------------------
# Workspace deployer
# ---------------------------------------------------------------------------

class WorkspaceDeployer:
    def __init__(self, shell, gateway_setup, governance_profiles_dir=None):
        self.sh = shell
        self.gw = gateway_setup
        self.governance_profiles_dir = Path(governance_profiles_dir or "/governance-profiles")
        self._pending_gateway_services = []

    def create_workspace(self, ws):
        if ws.name == "default":
            log(f"Using existing 'default' workspace")
            return
        log(f"Creating workspace '{ws.name}'")
        self.gw.select_mtls()
        self.sh.run(["openshell", "workspace", "create",
                     "--name", ws.name], check=False)
        self.sh.run(["openshell", "workspace", "member", "add",
                     "--workspace", ws.name,
                     "--subject", "openshell-client",
                     "--role", "admin"], check=False)

    def create_provider(self, provider, credential,
                        workspace_name="default"):
        mismatch = check_provider_type_mismatch(provider)
        if mismatch:
            log(f"ERROR: {mismatch} — skipping provider "
                f"'{provider.name}' creation. Fix values-secret.yaml or "
                f"the BOM profile's declared type/nemoclawProvider.")
            return
        # Import provider profile if available (governance or BOM profile)
        self._import_profile_if_needed(provider.type)

        args = ["openshell", "provider", "create",
                "--name", provider.name, "--type", provider.type]
        if workspace_name != "default":
            args += ["--workspace", workspace_name]
        cred_key = (provider.credential_key
                    or PROVIDER_CRED_MAP.get(provider.type, "API_KEY"))
        if credential and cred_key:
            args += ["--credential", f"{cred_key}={credential}"]
        elif provider.credential_secret:
            log(f"ERROR: provider '{provider.name}' declares "
                f"credentialSecret '{provider.credential_secret}', but no "
                f"resolved credential was provided to apply_bom.py. "
                f"Skipping create to avoid invalid runtime-credentials mode.")
            return
        else:
            args += ["--from-existing"]
        self.sh.run(args, check=False)

        # Keep provider credentials in sync with latest resolved secret/env
        # values. `provider create` is not idempotent for credential updates:
        # if a provider already exists, create may no-op/error and leave stale
        # credentials (e.g. rotated inter-VM bearer tokens). Upsert credential
        # material explicitly so reruns reconcile drift.
        if credential and cred_key:
            update_args = ["openshell", "provider", "update"]
            if workspace_name != "default":
                update_args += ["--workspace", workspace_name]
            update_args += [
                "--credential", f"{cred_key}={credential}",
                provider.name,
            ]
            self.sh.run(update_args, check=False)

    def _import_profile_if_needed(self, profile_type):
        """Import or update provider profile from governance profiles dir."""
        rc, out, _ = self.sh.run(
            ["openshell", "provider", "profile", "export", profile_type],
            check=False)
        profile_path = self.governance_profiles_dir / f"{profile_type}.yaml"
        if not profile_path.exists():
            return
        if rc != 0:
            log(f"  Importing provider profile '{profile_type}'")
            self.sh.run(
                ["openshell", "provider", "profile", "import",
                 "-f", str(profile_path)], check=False)
            return
        # Profile already exists: upsert latest chart content so schema/header
        # fixes are applied even on existing clusters.
        # Skip builtin profiles — they can't be updated.
        if "source: builtin" in (out or ""):
            return
        rv_match = re.search(r"resource_version:\s*([0-9]+)", out or "")
        profile_doc = load_yaml_file(profile_path)
        if rv_match:
            profile_doc["resource_version"] = int(rv_match.group(1))
        tmp = Path(f"/tmp/provider-profile-{profile_type}.yaml")
        tmp.write_text(
            yaml.safe_dump(profile_doc, sort_keys=False), encoding="utf-8")
        log(f"  Updating provider profile '{profile_type}'")
        self.sh.run(
            ["openshell", "provider", "profile", "update",
             "--file", str(tmp), profile_type],
            check=False)

    def _container_cmd(self):
        """Return the container runtime command (docker or podman)."""
        if not hasattr(self, '_cached_container_cmd'):
            for cmd in ["docker", "podman"]:
                rc, _, _ = self.sh.run(["which", cmd], check=False)
                if rc == 0:
                    self._cached_container_cmd = cmd
                    break
            else:
                self._cached_container_cmd = "docker"
        return self._cached_container_cmd

    def cleanup_sandbox_service(self, sandbox_name):
        svc = f"openclaw-gateway-{sandbox_name}.service"
        self.sh.run(
            ["bash", "-c",
             f"systemctl --user disable {svc} 2>/dev/null; "
             f"rm -f ~/.config/systemd/user/{svc}; "
             f"systemctl --user daemon-reload"],
            check=False)

    def ensure_forward_supervisor(self, sandbox_name, expose_port):
        """Keep `openshell forward` alive for exposed integration proxies."""
        svc = f"openshell-forward-{sandbox_name}.service"
        script = f"""#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
while true; do
  if ! openshell forward list 2>/dev/null | grep -q '^{sandbox_name}[[:space:]].*[[:space:]]{expose_port}[[:space:]].*[[:space:]]running'; then
    openshell forward stop {expose_port} {sandbox_name} >/dev/null 2>&1 || true
    openshell forward start -d 0.0.0.0:{expose_port} {sandbox_name} >/tmp/{sandbox_name}-forward.log 2>&1 || true
  fi
  sleep 30
done
"""
        self.sh.run(
            ["bash", "-c",
             "mkdir -p ~/.local/bin ~/.config/systemd/user && "
             f"cat > ~/.local/bin/{svc}.sh << 'FWEOF'\n{script}FWEOF\n"
             f"chmod +x ~/.local/bin/{svc}.sh && "
             f"cat > ~/.config/systemd/user/{svc} << 'SVCEOF'\n"
             "[Unit]\n"
             f"Description=OpenShell forward supervisor for {sandbox_name}\n"
             "After=network.target\n"
             "[Service]\n"
             f"ExecStart=%h/.local/bin/{svc}.sh\n"
             "Restart=always\n"
             "RestartSec=3\n"
             "[Install]\n"
             "WantedBy=default.target\n"
             "SVCEOF\n"
             "loginctl enable-linger $(whoami) 2>/dev/null || true && "
             "systemctl --user daemon-reload && "
             f"systemctl --user enable {svc} >/dev/null 2>&1 || true && "
             f"systemctl --user restart {svc}"],
            check=False)

    def wait_for_sandbox_port(self, sandbox_name, expose_port, workspace_name="default"):
        """Wait for an exposed sandbox port to begin accepting connections."""
        ws_args = (["--workspace", workspace_name]
                   if workspace_name != "default" else [])
        check_script = (
            "if curl -so /dev/null --max-time 1 http://127.0.0.1:"
            + str(expose_port) + "/ 2>/dev/null; "
            "then echo PORT_READY=1; else echo PORT_READY=0; fi"
        )
        for _ in range(30):
            _, out, _ = self.sh.run(
                ["openshell", "sandbox", "exec", "-n", sandbox_name] + ws_args + [
                    "--no-tty", "--", "/bin/sh", "-lc", check_script
                ],
                check=False,
            )
            if "PORT_READY=1" in (out or ""):
                return True
            if not self.sh.dry_run:
                time.sleep(1)
        return False

    def create_sandbox_generic(self, sandbox, workspace_name="default"):
        ws_args = (["--workspace", workspace_name]
                   if workspace_name != "default" else [])
        rc, out, _ = self.sh.run(
            ["openshell", "sandbox", "get", sandbox.name] + ws_args,
            check=False)
        already_exists = False
        if rc == 0:
            clean = re.sub(r'\x1b\[[0-9;]*m', '', out)
            if "Error" in clean:
                log(f"Sandbox '{sandbox.name}' is in Error state, "
                    "recreating...")
                self.sh.run(
                    ["openshell", "sandbox", "delete",
                     sandbox.name] + ws_args,
                    check=False)
                self.cleanup_sandbox_service(sandbox.name)
            else:
                log(f"Sandbox '{sandbox.name}' already exists")
                already_exists = True
        if not already_exists:
            crt = self._container_cmd()
            is_full_ref = sandbox.image and ("/" in sandbox.image or ":" in sandbox.image)
            if is_full_ref:
                self.sh.run(["sudo", crt, "pull", sandbox.image], check=False)
            policy_path = Path("/tmp/sandbox-policy.yaml")
            run_as_user = str(
                sandbox.run_as_user
                or os.environ.get("BOM_DEFAULT_RUN_AS_USER", "1001"))
            run_as_group = str(
                sandbox.run_as_group
                or os.environ.get("BOM_DEFAULT_RUN_AS_GROUP", "1001"))
            policy_path.write_text(
                "version: 1\n"
                "filesystem_policy:\n"
                "  include_workdir: true\n"
                "  read_only: [/usr, /lib, /lib64, /etc, /proc, /dev/urandom, /app, /opt, /var/log]\n"
                "  read_write: [/sandbox, /tmp, /dev/null, /dev/pts, /proc/self/oom_score_adj, /proc/thread-self/oom_score_adj]\n"
                "landlock:\n"
                "  compatibility: best_effort\n"
                "process:\n"
                f"  run_as_user: \"{run_as_user}\"\n"
                f"  run_as_group: \"{run_as_group}\"\n",
                encoding="utf-8",
            )
            args = ["openshell", "sandbox", "create", "--name", sandbox.name]
            if sandbox.image:
                args += ["--from", sandbox.image]
            args += ["--policy", str(policy_path)]
            if workspace_name != "default":
                args += ["--workspace", workspace_name]
            for prov in sandbox.providers:
                args += ["--provider", prov]
            for k, v in sandbox.env.items():
                resolved = resolve_env_value(v)
                args += ["--env", f"{k}={resolved}"]
            # Create must return; the long-lived command is started later as a
            # tracked `sandbox exec` so provider credentials stay bound.
            args += ["--no-tty", "--", "sh", "-c", "echo sandbox-ready"]
            rc, out, err = self.sh.run(args, check=False)
            combined = re.sub(r'\x1b\[[0-9;]*m', '',
                              (out or "") + " " + (err or ""))
            if "Error" in combined or "Restarting" in combined:
                log("Sandbox entered Error state, waiting 10s for logs...")
                if not self.sh.dry_run:
                    time.sleep(10)
                self.sh.run([
                    "bash", "-c",
                    f"CNAME=$(sudo {crt} ps -a "
                    f"--filter 'name=openshell.*{sandbox.name}' "
                    "--format '{{.Names}}' | head -1) && "
                    "echo \"Container: $CNAME\" && "
                    f"echo \"Status: $(sudo {crt} inspect $CNAME "
                    "--format '{{.State.Status}} ExitCode={{.State.ExitCode}}')"
                    "\" && echo '--- logs ---' && "
                    f"sudo {crt} logs $CNAME 2>&1 | tail -30"
                ], check=False)
                return

        if sandbox.command:
            # Pass non-secret sandbox.env via --env so argv0 stays the
            # governed binary (needed for s-type credential injection).
            # Only wrap in /bin/sh when runtime_env must copy placeholders.
            env_flags = []
            for k, v in sandbox.env.items():
                resolved = resolve_env_value(v)
                env_flags.append(f"--env {k}={shlex.quote(resolved)}")
            runtime_exports = []
            for k, v in sandbox.runtime_env.items():
                var_name = v.strip().lstrip("$").strip("{}")
                runtime_exports.append(f"export {k}=${var_name}")
            env_flag_str = (" ".join(env_flags) + " ") if env_flags else ""
            if runtime_exports:
                inner = "; ".join(
                    runtime_exports + [f"exec {sandbox.command}"])
                exec_argv = f"/bin/sh -c {shlex.quote(inner)}"
            else:
                exec_argv = sandbox.command
            svc = f"openshell-sandbox-{sandbox.name}.service"
            script_path = f"$HOME/.local/bin/{svc}.sh"
            ws_flag = (
                f"--workspace {workspace_name} "
                if workspace_name != "default" else ""
            )
            script = (
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                "export PATH=\"$HOME/.local/bin:$PATH\"\n"
                "openshell gateway select openshell-local "
                ">/dev/null 2>&1 || true\n"
                f"exec openshell sandbox exec -n {sandbox.name} {ws_flag}"
                f"{env_flag_str}--no-tty -- {exec_argv}\n"
            )
            log(f"Installing systemd service for '{sandbox.name}'")
            self.sh.run(
                ["bash", "-c",
                 f"mkdir -p ~/.local/bin ~/.config/systemd/user && "
                 f"cat > {script_path} << 'SHEOF'\n{script}SHEOF\n"
                 f"chmod +x {script_path} && "
                 f"cat > ~/.config/systemd/user/{svc} << 'SVCEOF'\n"
                 "[Unit]\n"
                 f"Description=Sandbox command for {sandbox.name}\n"
                 "After=openshell-gateway.service\n"
                 "[Service]\n"
                 "Type=simple\n"
                 "Restart=always\n"
                 "RestartSec=5\n"
                 "TimeoutStopSec=20\n"
                 f"ExecStart=%h/.local/bin/{svc}.sh\n"
                 "[Install]\n"
                 "WantedBy=default.target\n"
                 "SVCEOF\n"
                 "loginctl enable-linger $(whoami) 2>/dev/null || true && "
                 "systemctl --user daemon-reload && "
                 f"systemctl --user enable --now {svc}"],
                check=False)

        if sandbox.expose_port:
            if sandbox.command:
                ready = self.wait_for_sandbox_port(
                    sandbox.name, sandbox.expose_port, workspace_name)
                if ready:
                    log(f"Port {sandbox.expose_port} is ready in '{sandbox.name}'")
                else:
                    log(f"WARN: Port {sandbox.expose_port} in '{sandbox.name}' "
                        "was not ready before forward")
            log(f"Forwarding port {sandbox.expose_port}")
            self.sh.run(
                ["bash", "-c",
                 f"nohup openshell forward start "
                 f"-d 0.0.0.0:{sandbox.expose_port} {sandbox.name} "
                 f">/tmp/{sandbox.name}-forward.log 2>&1 </dev/null &"],
                check=False)
            if not self.sh.dry_run:
                time.sleep(2)
            self.ensure_forward_supervisor(sandbox.name, sandbox.expose_port)


    def install_nemoclaw_cli(self, cli_image):
        if not cli_image:
            return
        rc, _, _ = self.sh.run(["which", "nemoclaw"], check=False)
        if rc == 0:
            log("nemoclaw CLI already installed, skipping")
            return
        section("Installing nemoclaw CLI")
        crt = self._container_cmd()
        self.sh.run([
            "bash", "-c",
            f"CID=$({crt} create '{cli_image}' 2>/dev/null) && "
            f"{crt} cp $CID:/opt/nemoclaw /tmp/nemoclaw-cli && "
            f"{crt} rm $CID >/dev/null && "
            f"sudo mv /tmp/nemoclaw-cli /opt/nemoclaw && "
            f"printf '#!/usr/bin/env bash\\nexec node "
            f"/opt/nemoclaw/bin/nemoclaw.js \"$@\"\\n' "
            f"| sudo tee /usr/local/bin/nemoclaw >/dev/null && "
            f"sudo chmod 755 /usr/local/bin/nemoclaw"
        ], check=False)

    def onboard_nemoclaw(self, sandbox, provider, credential):
        state_dir = str(Path.home() / ".local" / "state" / "openshell")
        mgmt_path = str(Path.home() / "gateway-management.json")
        mgmt = {
            "version": 1, "mode": "externally-supervised",
            "endpoint": "https://127.0.0.1:17670",
            "stateDir": state_dir,
            "supervisor": {
                "kind": "systemd-user",
                "serviceName": "openshell-gateway.service",
                "execPath": "/usr/local/bin/openshell-gateway",
            },
        }
        if not self.sh.dry_run:
            os.makedirs(os.path.dirname(mgmt_path), exist_ok=True)
            with open(mgmt_path, "w", encoding="utf-8") as f:
                json.dump(mgmt, f)

        nc_prov = provider.nemoclaw_provider or provider.type
        env = {
            "NEMOCLAW_GATEWAY_MANAGEMENT": mgmt_path,
            "NEMOCLAW_GATEWAY_PORT": "17670",
            "NEMOCLAW_IGNORE_RUNTIME_RESOURCES": "1",
            "NEMOCLAW_OPENSHELL_GATEWAY_BIN":
                "/usr/local/bin/openshell-gateway",
            "NEMOCLAW_OPENSHELL_SANDBOX_BIN":
                "/usr/local/bin/openshell-supervisor",
            "NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE": "1",
            "NEMOCLAW_PROVIDER": nc_prov,
        }
        if sandbox.model or provider.model:
            env["NEMOCLAW_MODEL"] = sandbox.model or provider.model
        if credential:
            env["NEMOCLAW_PROVIDER_KEY"] = credential
            cred_key = PROVIDER_CRED_MAP.get(nc_prov, "")
            if cred_key:
                env[cred_key] = credential
        cmd = [
            "nemoclaw", "onboard",
            "--fresh", "--non-interactive",
            "--name", sandbox.name,
            "--agent", sandbox.agent or "openclaw",
            "--yes", "--yes-i-accept-third-party-software",
        ]
        rc, _, _ = self.sh.run(cmd, env=env, check=False)
        return rc == 0

    def start_openclaw_gateway(self, sandbox_name, dashboard_route,
                               workspace_name="default",
                               provider_id="nvidia",
                               model_id="",
                               gateway_pre_start=""):
        import secrets as secrets_mod

        ws_args = ["--workspace", workspace_name] if workspace_name else []

        # Wait for sandbox to reach Ready
        if not self.sh.dry_run:
            for i in range(20):
                rc, out, _ = self.sh.run([
                    "openshell", "sandbox", "get", sandbox_name
                ] + ws_args, check=False)
                clean = re.sub(r'\x1b\[[0-9;]*m', '', out or "")
                if "Ready" in clean and "Error" not in clean:
                    log(f"Sandbox '{sandbox_name}' is Ready")
                    break
                log(f"  waiting for sandbox ready... (attempt {i+1})")
                time.sleep(5)

        token = secrets_mod.token_hex(16)
        exec_cmd = ["openshell", "sandbox", "exec", "-n",
                     sandbox_name] + ws_args + ["--no-tty", "--"]

        # Configure OpenClaw with secure writable dirs under /tmp.
        # /sandbox/.openclaw can be unreadable/unwritable under policy.
        home_dir = f"/tmp/openclaw-home-{sandbox_name}"
        state_dir = f"/tmp/openclaw-state-{sandbox_name}"
        oc_env = (f"HOME={home_dir} "
                  f"OPENCLAW_HOME={home_dir} "
                  f"SQLITE_TMPDIR={state_dir} "
                  f"TMPDIR={state_dir} "
                  "OPENCLAW_NIX_MODE=0")

        prep_dirs_cmd = (
            "uid=$(id -u); "
            f"mkdir -p {home_dir}/.openclaw/npm/projects; "
            f"mkdir -p {state_dir} {state_dir}/openclaw-${{uid}}; "
            f"chmod 755 {home_dir} {home_dir}/.openclaw "
            f"{home_dir}/.openclaw/npm {home_dir}/.openclaw/npm/projects; "
            f"chmod 700 {state_dir} {state_dir}/openclaw-${{uid}}; "
            f"rm -f {state_dir}/*/gateway.state.*.lock 2>/dev/null; "
            "true"
        )

        # Prepare secure OpenClaw home and temp/sqlite state dirs.
        self.sh.run(exec_cmd + ["sh", "-c", prep_dirs_cmd], check=False)

        # OpenClaw onboard with inference.local — the OpenShell supervisor
        # routes requests through the provider created by BOM (e.g. nvidia).
        # Credentials are on the gateway, not in OpenClaw — use a placeholder.
        log(f"Running openclaw onboard (base=inference.local, "
            f"provider={provider_id}, model={model_id})...")
        self.sh.run(
            exec_cmd + ["sh", "-c",
                        f"{oc_env} CUSTOM_API_KEY=gateway-managed "
                        f"openclaw onboard "
                        f"--non-interactive --accept-risk "
                        f"--mode local "
                        f"--auth-choice custom-api-key "
                        f'--custom-base-url "https://inference.local/v1" '
                        f"--custom-provider-id {provider_id} "
                        f'--custom-model-id "{model_id}" '
                        f"--custom-compatibility openai "
                        f"--skip-channels --skip-health"],
            check=False)
        # Set gateway token
        self.sh.run(
            exec_cmd + ["sh", "-c",
                        f"{oc_env} openclaw config set "
                        f"gateway.auth.token '{token}'"],
            check=False)
        # Make config readable for mixed-UID runtime contexts (e.g. 1000/1001).
        self.sh.run(
            exec_cmd + ["sh", "-c",
                        f"chmod 755 {home_dir} {home_dir}/.openclaw 2>/dev/null; "
                        f"chmod 644 {home_dir}/.openclaw/openclaw.json 2>/dev/null; "
                        "true"],
            check=False)
        if dashboard_route:
            self.sh.run(
                exec_cmd + ["sh", "-c",
                            f"{oc_env} openclaw config set "
                            "gateway.controlUi.allowedOrigins "
                            f"'[\"https://{dashboard_route}\"]'"],
                check=False)

        # Re-assert secure perms and clear stale locks before starting gateway.
        self.sh.run(
            exec_cmd + ["sh", "-c",
                        "uid=$(id -u); "
                        f"mkdir -p {home_dir}/.openclaw/npm/projects; "
                        f"mkdir -p {state_dir} {state_dir}/openclaw-${{uid}}; "
                        f"chmod 755 {home_dir} {home_dir}/.openclaw "
                        f"{home_dir}/.openclaw/npm {home_dir}/.openclaw/npm/projects; "
                        f"chmod 700 {state_dir} {state_dir}/openclaw-${{uid}}; "
                        f"rm -f {state_dir}/*/gateway.state.*.lock 2>/dev/null; "
                        "true"],
            check=False)

        log(f"Starting openclaw gateway (token={token[:8]}...)")
        gateway_script = f"/tmp/openclaw-start-gateway-{sandbox_name}.sh"
        wait_script = f"$HOME/.local/bin/openclaw-wait-gateway-{sandbox_name}.sh"
        self.sh.run(
            exec_cmd + ["sh", "-c",
                        f"cat > {gateway_script} << 'GWEOF'\n"
                        f"#!/bin/sh\n"
                        f"export OPENCLAW_GATEWAY_TOKEN={token} "
                        f"HOME={home_dir} "
                        f"OPENCLAW_HOME={home_dir} "
                        f"SQLITE_TMPDIR={state_dir} "
                        f"TMPDIR={state_dir} "
                        f"OPENCLAW_NIX_MODE=0\n"
                        f"rm -f {state_dir}/*/gateway.state.*.lock 2>/dev/null\n"
                        + (gateway_pre_start.rstrip() + "\n" if gateway_pre_start.strip() else "") +
                        f"exec openclaw gateway run "
                        f"--allow-unconfigured "
                        f"--bind loopback --port 18789\n"
                        f"GWEOF\n"
                        f"chmod 700 {gateway_script}"],
            check=False)
        self.sh.run(
            ["bash", "-c",
             f"mkdir -p ~/.local/bin && "
             f"cat > {wait_script} << 'WEOF'\n"
             "#!/bin/bash\n"
             "set -euo pipefail\n"
             "for i in $(seq 1 90); do\n"
             "  if (echo > /dev/tcp/127.0.0.1/17670) >/dev/null 2>&1; then\n"
             "    exit 0\n"
             "  fi\n"
             "  sleep 2\n"
             "done\n"
             "echo 'openshell gateway port 17670 not ready in time' >&2\n"
             "exit 1\n"
             "WEOF\n"
             f"chmod 700 {wait_script}"],
            check=False)
        service_ws_args = (f"--workspace {workspace_name} "
                           if workspace_name and workspace_name != "default"
                           else "")
        self.sh.run(
            ["bash", "-c",
             f"cat > ~/.config/systemd/user/openclaw-gateway-{sandbox_name}.service << 'SVCEOF'\n"
             f"[Unit]\n"
             f"Description=OpenClaw gateway for sandbox {sandbox_name}\n"
             f"[Service]\n"
             f"Type=simple\n"
             f"Restart=always\n"
             f"RestartSec=5\n"
             f"ExecStartPre=/bin/bash -lc '{wait_script}'\n"
             f"ExecStart=/bin/bash -lc '"
             f"openshell gateway select {self.gw.mtls_gw} >/dev/null 2>&1 || true; "
             f"exec openshell sandbox exec -n {sandbox_name} {service_ws_args}--no-tty -- "
             f"{gateway_script}"
             f"'\n"
             f"[Install]\n"
             f"WantedBy=default.target\n"
             f"SVCEOF\n"
             f"systemctl --user daemon-reload"],
            check=False)

        self._pending_gateway_services.append(sandbox_name)

    def start_pending_gateway_services(self):
        """Start gateway systemd services deferred from start_openclaw_gateway."""
        for name in getattr(self, '_pending_gateway_services', []):
            section(f"Starting openclaw-gateway-{name} service")
            self.sh.run(
                ["bash", "-c",
                 f"systemctl --user enable --now openclaw-gateway-{name}.service"],
                check=False)

            exec_cmd = ["openshell", "sandbox", "exec", "-n", name, "--no-tty", "--"]
            for i in range(10):
                rc, out, _ = self.sh.run(
                    exec_cmd + [
                    "curl", "-sf", "http://127.0.0.1:18789/health"
                ], check=False)
                if rc == 0 and "ok" in out:
                    log("openclaw gateway ready")
                    break
                log(f"  waiting for openclaw gateway... (attempt {i+1})")
                if not self.sh.dry_run:
                    time.sleep(3)
            else:
                log("WARN: openclaw gateway health check failed")
        self._pending_gateway_services = []


# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

class Verifier:
    def __init__(self, shell):
        self.sh = shell
        self.passed = 0
        self.failed = 0

    def check(self, desc, cmd):
        rc, out, _ = self.sh.run(cmd, check=False)
        if rc == 0:
            log(f"PASS  {desc}")
            self.passed += 1
        else:
            log(f"FAIL  {desc}")
            self.failed += 1
        return rc == 0, out

    def _ws_args(self, ws_name):
        if ws_name != "default":
            return ["--workspace", ws_name]
        return []

    def verify_profiles(self, profiles):
        banner("VERIFICATION")
        for profile in profiles:
            log(f"\nProfile: {profile.name}")
            for ws in profile.workspaces:
                if not ws.enabled:
                    continue
                ws_flag = self._ws_args(ws.name)
                log(f"\n  Workspace: {ws.name}")

                if ws.name != "default":
                    ok, out = self.check(
                        f"workspace '{ws.name}'",
                        ["openshell", "workspace", "list"])
                    if ok and ws.name not in (out or ""):
                        log(f"FAIL  workspace '{ws.name}' not in output")
                        self.passed -= 1
                        self.failed += 1

                for prov in ws.providers:
                    if not prov.enabled:
                        continue
                    self.check(
                        f"provider '{prov.name}' in '{ws.name}'",
                        ["openshell", "provider", "get",
                         prov.name] + ws_flag)

                for sb in ws.sandboxes:
                    if not sb.enabled:
                        continue
                    self.check(
                        f"sandbox '{sb.name}' in '{ws.name}'",
                        ["openshell", "sandbox", "get",
                         sb.name] + ws_flag)
                    if sb.providers:
                        _, out = self.check(
                            f"sandbox '{sb.name}' provider list",
                            ["openshell", "sandbox", "provider",
                             "list", sb.name] + ws_flag)
                        for prov_name in sb.providers:
                            if prov_name in (out or ""):
                                log(f"  PASS  '{sb.name}' "
                                    f"has provider '{prov_name}'")
                                self.passed += 1
                            else:
                                log(f"  FAIL  '{sb.name}' "
                                    f"missing provider '{prov_name}'")
                                self.failed += 1

        banner(f"Results: {self.passed} passed, {self.failed} failed")
        if self.failed > 0:
            log("STATUS: INCOMPLETE")
        else:
            log("STATUS: ALL PASSED")
        return self.failed == 0


# ---------------------------------------------------------------------------
# Main orchestrator
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="BOM-driven agent configuration for SAW")
    parser.add_argument("--profiles-dir", required=True)
    parser.add_argument("--oidc-gateway", default="")
    parser.add_argument("--mtls-gateway", default="openshell-local")
    parser.add_argument("--nemoclaw-cli-image", default="")
    parser.add_argument("--dashboard-route", default="")
    parser.add_argument("--governance-profiles-dir",
                        default="/governance-profiles")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    # --- Parse profiles ---
    profiles = parse_profiles(args.profiles_dir)
    if not profiles:
        log("No profiles found, nothing to do")
        return

    total_ws = sum(len(p.workspaces) for p in profiles)
    total_sb = sum(len(sb) for p in profiles for ws in p.workspaces
                   for sb in [ws.sandboxes])
    banner(f"BOM Apply: {len(profiles)} profile(s), "
           f"{total_ws} workspace(s)")

    oidc_gw = args.oidc_gateway or os.environ.get("OPENSHELL_GATEWAY", "")
    sh = Shell(dry_run=args.dry_run)

    # --- Phase 1: Gateway setup ---
    banner("Phase 1: Gateway Setup")
    gw = GatewaySetup(sh, oidc_gw, args.mtls_gateway)

    oidc_token = os.environ.get("OIDC_TOKEN", "")
    gw.configure_oidc(
        oidc_token,
        os.environ.get("OIDC_ISSUER", ""),
        os.environ.get("OIDC_CLIENT_ID", "openshell-cli"),
    )
    gw.register_mtls_gateway()
    gw.grant_default_workspace_access()
    gw.enable_providers_v2()

    # --- Phase 2: Deploy profiles ---
    deployer = WorkspaceDeployer(sh, gw, args.governance_profiles_dir)
    for profile in profiles:
        banner(f"Phase 2: Profile '{profile.name}' "
               f"({len(profile.workspaces)} workspace(s))")

        for ws in profile.workspaces:
            log(f"\n  Workspace: {ws.name}")
            log(f"  {'─' * 50}")

            if not ws.enabled:
                log("  (disabled, skipping)")
                continue

            deployer.create_workspace(ws)

            # Create non-inference providers before sandboxes (needed for
            # --provider attachment at sandbox create time). Inference
            # providers are created after openclaw onboard to avoid duplicates.
            enabled_provs = [p for p in ws.providers if p.enabled]
            inference_provs = []
            non_inference_provs = []
            for p in enabled_provs:
                if p.type in PROVIDER_CRED_MAP or p.type == "nvidia":
                    inference_provs.append(p)
                else:
                    non_inference_provs.append(p)
            if non_inference_provs:
                section(f"Providers ({len(non_inference_provs)}) "
                        f"in workspace '{ws.name}'")
                for prov in non_inference_provs:
                    cred = resolve_credential(prov)
                    deployer.create_provider(prov, cred, ws.name)

            # Create sandboxes
            nemoclaw_cli_installed = False
            for sb in ws.sandboxes:
                if not sb.enabled:
                    log(f"  Sandbox '{sb.name}' disabled, skipping")
                    continue
                section(f"Sandbox '{sb.name}' (type={sb.type})")

                if sb.type == "nemoclaw":
                    # Nemoclaw flow (matches feat/fix-docker-golden-image):
                    # 1. Install nemoclaw CLI
                    # 2. nemoclaw onboard (configures provider)
                    # 3. Fallback: openshell provider create
                    # 4. openshell sandbox create
                    # 5. Start openclaw gateway inside sandbox
                    if not nemoclaw_cli_installed:
                        cli_img = args.nemoclaw_cli_image or \
                            os.environ.get("NEMOCLAW_CLI_IMAGE", "")
                        if cli_img:
                            deployer.install_nemoclaw_cli(cli_img)
                            nemoclaw_cli_installed = True

                    is_full_ref = sb.image and ("/" in sb.image
                                                or ":" in sb.image)
                    if is_full_ref:
                        deployer.sh.run(
                            ["sudo", "docker", "pull", sb.image],
                            check=False)

                    prov = find_provider(ws, sb.providers)
                    cred = resolve_credential(prov) if prov else None
                    mismatch = check_provider_type_mismatch(prov) if prov else None
                    if mismatch:
                        log(f"ERROR: {mismatch} — skipping nemoclaw "
                            f"onboard for '{sb.name}'.")
                    elif prov and cred:
                        nc_prov = prov.nemoclaw_provider or prov.type
                        log(f"nemoclaw onboard --agent {sb.agent or 'openclaw'}"
                            f" (provider={nc_prov})")
                        ok = deployer.onboard_nemoclaw(sb, prov, cred)
                        if not ok:
                            log("nemoclaw onboard failed, "
                                "configuring provider manually")
                            deployer.create_provider(prov, cred, ws.name)

                    deployer.create_sandbox_generic(sb, ws.name)
                    prov_id = prov.type if prov else "nvidia"
                    model = sb.model or (prov.model if prov else "")
                    deployer.start_openclaw_gateway(
                        sb.name, args.dashboard_route or "",
                        workspace_name=ws.name,
                        provider_id=prov_id,
                        model_id=model or "",
                        gateway_pre_start=sb.gateway_pre_start)

                elif sb.type == "openclaw":
                    deployer.create_sandbox_generic(sb, ws.name)
                    prov_id = os.environ.get("INFERENCE_PROVIDER", "nvidia")
                    model = sb.model or os.environ.get(
                        "INFERENCE_MODEL", "")
                    deployer.start_openclaw_gateway(
                        sb.name, args.dashboard_route or "",
                        workspace_name=ws.name,
                        provider_id=prov_id,
                        model_id=model or "",
                        gateway_pre_start=sb.gateway_pre_start)
                    # Create inference providers AFTER openclaw onboard to
                    # avoid duplicate provider names in OpenClaw's config,
                    # then attach them to the sandbox.
                    ws_args = (["--workspace", ws.name]
                               if ws.name != "default" else [])
                    inference_set = False
                    for ip in inference_provs:
                        cred = resolve_credential(ip)
                        deployer.create_provider(ip, cred, ws.name)
                        sh.run(["openshell", "sandbox", "provider", "attach",
                                sb.name, ip.name] + ws_args,
                               check=False)
                        if not inference_set:
                            inf_model = (ip.model
                                         or os.environ.get("INFERENCE_MODEL", "")
                                         or model)
                            if inf_model:
                                sh.run(["openshell", "inference", "set",
                                        "--provider", ip.name,
                                        "--model", inf_model,
                                        "--no-verify"], check=False)
                                inference_set = True

                else:
                    # Generic: just create the sandbox
                    deployer.create_sandbox_generic(sb, ws.name)

    # --- Phase 3: Run proxy-setup scripts ---
    for profile in profiles:
        for ws in profile.workspaces:
            if not ws.enabled:
                continue
            ws_dir = Path(args.profiles_dir) / profile.name / ws.name
            proxy_script = ws_dir / "proxy-setup.sh"
            if proxy_script.exists():
                for sb in ws.sandboxes:
                    if not sb.enabled:
                        continue
                    section(f"Running proxy-setup.sh for '{sb.name}'")
                    sh.run(["bash", str(proxy_script), sb.name, ws.name],
                           check=False)

    # --- Phase 3b: Start deferred gateway services ---
    deployer.start_pending_gateway_services()

    # --- Phase 4: Verify ---
    if not args.dry_run:
        verifier = Verifier(sh)
        ok = verifier.verify_profiles(profiles)
        if not ok:
            # Without this, the setup Job reports "Complete" even when the
            # BOM apply only partially succeeded — verified live: a run with
            # 9 passed / 1 failed still showed Job status Complete, with the
            # only signal being "STATUS: INCOMPLETE" buried in the full log.
            raise SystemExit(1)


if __name__ == "__main__":
    main()
