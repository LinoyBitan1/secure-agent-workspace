# OpenShell: v-type credential placeholders not resolved at egress

**Project:** APPENG
**Type:** Bug
**Component:** OpenShell Supervisor
**Priority:** High
**Labels:** openshell, credential_resolution, supervisor, two_vm

## Summary

The OpenShell supervisor creates two types of credential placeholders for sandbox env vars:
- `s`-type (`openshell:resolve:env:s<hex>_<key>`) — created per `sandbox exec` session
- `v`-type (`openshell:resolve:env:v<number>_<key>`) — created at sandbox creation / provider attachment

Only `s`-type placeholders are resolved by the supervisor's egress proxy. `v`-type placeholders return `500 {"error":"credential_unavailable","message":"Credential placeholder could not be resolved"}`.

Both types are injected by the supervisor. Both should be resolvable.

## Reproduction

1. Create a provider with a credential and attach it to a sandbox:
   ```bash
   openshell provider create --name gmail-read --type gmail-read --credential access_token=placeholder
   openshell sandbox create --name mail-proxy --from <image> --provider gmail-read --no-tty -- sh -c "echo ready"
   ```

2. From a fresh `sandbox exec`, the credential resolves:
   ```bash
   openshell sandbox exec -n mail-proxy --no-tty -- \
     sh -c 'curl -H "Authorization: Bearer $access_token" https://gmail.googleapis.com/gmail/v1/users/me/labels'
   # access_token = s-type placeholder → supervisor resolves → 200
   ```

3. A long-running process started via `sandbox exec` reads the env var at startup. The process gets a `v`-type placeholder (from the container env):
   ```bash
   openshell sandbox exec -n mail-proxy --no-tty -- /sandbox/gmail-read-proxy
   # Proxy reads access_token at startup → gets v-type → sends in Authorization header
   # Supervisor returns 500 credential_unavailable
   ```

4. If the process is killed and restarted (new exec session), it gets an `s`-type and works:
   ```bash
   # Kill old process, systemd restarts the exec → new s-type → 200
   ```

## Evidence

Debug logging from the proxy binary shows:

**Failing (v-type):**
```
[DEBUG] forward: placeholder=openshell:resolve:env:v15921495936660677...
[DEBUG] forward: response status=500 Internal Server Error
```

**Working (s-type, after restart):**
```
[DEBUG] forward: placeholder=openshell:resolve:env:s125dfd4c09264788f...
[DEBUG] forward: response status=200 OK
```

Same binary, same sandbox, same supervisor proxy, same SSL cert, same credential. Only the placeholder prefix differs.

**curl from fresh exec (always s-type):**
```bash
$ echo $access_token
openshell:resolve:env:s125dfd4c09264788fb992b6398c63458686e9d11d8569eb89eefdd37e3d5ccb1_access_token

$ curl -H "Authorization: Bearer $access_token" https://gmail.googleapis.com/...
# 200 OK
```

## Impact

Any sandbox process that:
1. Reads a provider credential from env at startup
2. Uses it for outbound HTTPS requests through the supervisor proxy

...will fail with `credential_unavailable` unless the process is restarted after credential refresh is configured. This forces a restart-after-configure deployment pattern.

## Workaround

Restart the sandbox command's systemd service after running `configure-gmail-refresh` (or any operation that changes the credential). The new exec session gets a fresh `s`-type placeholder.

```bash
systemctl --user restart openshell-sandbox-mail-proxy.service
```

## Expected Behavior

Both `v`-type and `s`-type placeholders should be resolvable by the supervisor's egress proxy. The supervisor created both — it should resolve both.

## Environment

- OpenShell gateway/supervisor: 0.0.110
- Sandbox runtime: podman
- Provider profile: `auth_style: bearer`, `header_name: authorization`
- Credential refresh: `oauth2_refresh_token` (working, `status: refreshed`)
