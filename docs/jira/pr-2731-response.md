# Response to PR #2731 Review

@johntmyers — thank you for the detailed review. I deployed the **original upstream interceptor** (built from `NVIDIA/OpenShell` main, zero changes) and ran two tests to reproduce the issue. You were right on the core question — `SubmitPolicyAnalysis` denial does not cause the 403.

## Test setup

- Built `governance-interceptor:orig` from `NVIDIA/OpenShell` main via OpenShift BuildConfig (no code changes)
- Deployed it in place of our fork build
- Registered a Brave Search provider (`--type brave --credential BRAVE_API_KEY=<key>`)
- Created a sandbox with `--provider brave`

## Test 1: `providers_v2_enabled=true` (profile endpoints composed into sandbox policy)

```
> CONNECT api.search.brave.com:443 HTTP/1.1
< HTTP/1.1 200 Connection Established

< HTTP/1.1 301 Moved Permanently
< Location: https://api-dashboard.search.brave.com
```

**Result: Proxy allowed the connection.** Both `SubmitPolicyAnalysis` calls returned `decision="allow"`. No 403.

## Test 2: `providers_v2_enabled=false` (profile endpoints NOT composed into sandbox policy)

```
> CONNECT api.search.brave.com:443 HTTP/1.1
< HTTP/1.1 403 Forbidden
< Content-Type: application/json
< Content-Length: 146
```

**Result: Proxy returned 403.** Here's the key — the timeline from gateway logs:

```
02:41:47  ExecSandbox: curl -sv --max-time 10 'https://api.search.brave.com/'
                       ← proxy returns 403 immediately (endpoint not in network policy)

02:41:56  SubmitPolicyAnalysis  decision="allow"   ← sandbox principal (first call)
02:41:56  SubmitPolicyAnalysis  decision="deny"    ← second call (grpc status_code=7)
```

The 403 came from the proxy at `02:41:47`. The `SubmitPolicyAnalysis` denial happened **9 seconds later** at `02:41:56`, asynchronously — exactly as you described. The deny did not cause the 403.

## What's actually happening

There **is** a `SubmitPolicyAnalysis` denial in the upstream interceptor — the second of two calls gets `decision="deny"`. But you're correct that:

1. It's **async** — the proxy already made its network-policy decision and returned 403 before the interceptor even sees `SubmitPolicyAnalysis`
2. The **403 is from the proxy's network policy**, not the interceptor — when `providers_v2_enabled=false`, the brave profile endpoints aren't composed into the sandbox policy, so the proxy correctly blocks the CONNECT
3. The first `SubmitPolicyAnalysis` call (sandbox principal) is **allowed** — confirming `CachedOpenShellClient` does attach the sandbox bearer token

## Root cause of my original issue

The original 403 I attributed to the interceptor was actually caused by missing `providers_v2_enabled=true`. Without it, the sandbox's network policy doesn't include the brave profile endpoints regardless of the interceptor's behavior. The fix that unblocked our brave search flow was:

1. Adding a `brave.yaml` provider profile to the governance policy
2. Enabling `providers_v2_enabled=true`
3. Creating sandboxes with `--provider brave` to compose the profile endpoints into the sandbox's network policy

The interceptor change was applied at the same time, so it appeared causal — but it wasn't.

## One secondary finding

There **is** a denied `SubmitPolicyAnalysis` call (the second one, at grpc status_code=7). This doesn't cause any connection failures, but I'm curious what principal that second call carries — it might be worth understanding why it's denied even if it's harmless. Happy to dig into that separately if it's of interest.

## Action

I'll close this PR and issue #2730. The governance interceptor's `validate_submit_policy_analysis` principal check is working as intended. Thank you for pushing back — it forced me to get the actual evidence and find the real root cause.
