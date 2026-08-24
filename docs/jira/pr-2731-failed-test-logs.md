# PR #2731 — Failed Test Logs (providers_v2_enabled=false)

**Date:** 2026-08-13
**Interceptor:** upstream `NVIDIA/OpenShell` main (no code changes)
**Image:** `governance-interceptor:latest` built from `NVIDIA/OpenShell.git` main branch
**Setup:** Fresh VM, setup job ran, brave provider registered, `providers_v2_enabled` NOT set

## Curl output (403)

```
* Uses proxy env variable no_proxy == '127.0.0.1,localhost,::1'
* Uses proxy env variable https_proxy == 'http://10.200.0.1:3128'
*   Trying 10.200.0.1:3128...
* CONNECT tunnel: HTTP/1.1 negotiated
* allocate connect buffer
* Establish HTTP proxy tunnel to api.search.brave.com:443
> CONNECT api.search.brave.com:443 HTTP/1.1
> Host: api.search.brave.com:443
> User-Agent: curl/8.14.1
> Proxy-Connection: Keep-Alive
>
< HTTP/1.1 403 Forbidden
< Content-Type: application/json
< Content-Length: 146
< Connection: close
<
* CONNECT tunnel failed, response 403
* closing connection #0
```

## Gateway logs — timeline

```
# Curl starts at 03:31:04
03:31:04  ExecSandbox (relay): command started
          command_preview=curl -sv --max-time 10 'https://api.search.brave.com/'
          ← proxy returns 403 immediately (endpoint not in sandbox network policy)

# SubmitPolicyAnalysis fires 9 seconds AFTER the 403
03:31:13  SubmitPolicyAnalysis  decision="allow"   (sandbox principal — first call)
03:31:13  SubmitPolicyAnalysis  decision="deny"    grpc.status_code=7 (second call)
```

## Full SubmitPolicyAnalysis gateway log entries

```
Aug 13 03:31:13 openshell-gateway: gateway interceptor evaluated
  interceptor=governance binding_id=govern-submit-policy-analysis
  phase="validate" method=SubmitPolicyAnalysis
  decision="allow" patch_count=0 log_annotations={}

Aug 13 03:31:13 openshell-gateway: gateway interceptor evaluated
  interceptor=governance binding_id=govern-submit-policy-analysis
  phase="validate" method=SubmitPolicyAnalysis
  decision="deny" patch_count=0 log_annotations={}
  rpc.grpc.status_code=7 otel.status_code="ERROR"
```

## Earlier SubmitPolicyAnalysis calls (background policy aggregation, before curl)

Every 10 seconds, the sandbox aggregator flushes `SubmitPolicyAnalysis`. The pattern is consistent — two calls per flush, one allowed, one denied:

```
03:30:13  SubmitPolicyAnalysis  decision="deny"   grpc.status_code=7
03:30:13  SubmitPolicyAnalysis  decision="allow"

03:30:23  SubmitPolicyAnalysis  decision="deny"   grpc.status_code=7
03:30:23  SubmitPolicyAnalysis  decision="allow"

03:30:33  SubmitPolicyAnalysis  decision="allow"
03:30:33  SubmitPolicyAnalysis  decision="deny"   grpc.status_code=7
```

## Interceptor logs

```
policy reload propagation enabled through gateway endpoint https://127.0.0.1:17670
loaded provider profiles: brave, gemini, github, nvidia, slack, web-search
loaded governance policy sha256:v2:30f87c7c458a8aa7855d462bedcd4ac9f7b15b3bc1867a1c6aeeed21e5e630a2 from /config/policy/policy.yaml
governance interceptor listening on 0.0.0.0:18081
```

## Analysis

1. **The 403 is from the proxy**, not the interceptor — the proxy blocks `CONNECT api.search.brave.com:443` because the endpoint is not in the sandbox's network policy
2. **`SubmitPolicyAnalysis` denial is async** — fires 9 seconds after the proxy already returned 403
3. **The deny does not cause the 403** — it happens on the background aggregation path, not the connection path
4. **Root cause**: without `providers_v2_enabled=true`, the brave profile endpoints are not composed into the sandbox's network policy, so the proxy has no rule allowing `api.search.brave.com`

## Comparison: same test with providers_v2_enabled=true

```
> CONNECT api.search.brave.com:443 HTTP/1.1
< HTTP/1.1 200 Connection Established

< HTTP/1.1 301 Moved Permanently
< Location: https://api-dashboard.search.brave.com
```

Connection succeeds because the brave profile endpoints ARE in the sandbox's network policy.
