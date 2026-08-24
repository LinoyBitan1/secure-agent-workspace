# Upstream Bug: Gateway interceptor HTTPS endpoint fails — tls-native-roots not applied

**Repo:** NVIDIA/OpenShell
**Type:** Bug
**Component:** gateway-interceptors

## Title

`bug(gateway-interceptors): HTTPS interceptor endpoint fails — tls-native-roots not applied without explicit tls_config()`

## Body

### Description

Gateway interceptor connections to HTTPS endpoints fail with `transport error` because `Endpoint::connect()` in `connect_endpoint()` does not call `.tls_config()`, so tonic's `tls-native-roots` feature is never applied to the channel.

The gateway's other HTTPS clients (e.g., OIDC via `reqwest`) connect successfully to the same endpoints using the same system CA trust store.

### Steps to Reproduce

1. Deploy a governance interceptor with a TLS endpoint
2. Configure the gateway with:
   ```toml
   [[openshell.gateway.interceptors]]
   name           = "governance"
   grpc_endpoint  = "https://governance-interceptor.example.com"
   ```
3. Ensure the endpoint's CA is in the system trust store (`update-ca-trust`)
4. Start the gateway

### Expected Behavior

Gateway connects to the interceptor over HTTPS, trusting the system CA store (same as `reqwest` does for OIDC).

### Actual Behavior

```
Error: configuration error: gateway interceptor initialization failed:
  interceptor transport error: connect https://governance-interceptor-...: transport error
```

Meanwhile, `curl` and the gateway's own OIDC client (`reqwest` / `hyper-rustls`) connect to the same endpoint successfully using the same CA.

### Root Cause

In `crates/openshell-gateway-interceptors/src/plan.rs` line 860-872:

```rust
async fn connect_endpoint(endpoint: &str) -> Result<Channel> {
    Endpoint::from_shared(endpoint.to_string())
        .map_err(|e| ...)?
        .connect()       // ← no .tls_config() called
        .await
        .map_err(|e| ...)
}
```

Tonic's `tls-native-roots` feature (enabled in `Cargo.toml`) makes native root certificates *available* but does not apply them automatically. `Endpoint::connect()` requires explicit `.tls_config(ClientTlsConfig::new())` to enable TLS with native roots.

### Suggested Fix

```rust
async fn connect_endpoint(endpoint: &str) -> Result<Channel> {
    let endpoint = endpoint.trim();
    if let Some(path) = endpoint.strip_prefix("unix://") {
        return connect_unix_endpoint(PathBuf::from(path)).await;
    }
    let mut ep = Endpoint::from_shared(endpoint.to_string())
        .map_err(|e| InterceptorError::Config(...))?;
    if endpoint.starts_with("https://") {
        ep = ep.tls_config(tonic::transport::ClientTlsConfig::new())
            .map_err(|e| InterceptorError::Config(...))?;
    }
    ep.connect().await
        .map_err(|e| InterceptorError::Transport(...))
}
```

### Environment

- OpenShell gateway 0.0.96
- tonic 0.14 with `features = ["channel", "tls-native-roots"]`
- Fedora 44 / RHEL 9

### Workaround

Run the interceptor on localhost (`http://127.0.0.1:18081`) — no TLS needed for loopback.

### Related

- #2623 — feat: add shared alpha extension authentication and custom CA transport
- #2612 — fix(gateway-interceptors): configure connect timeout and HTTP/2 keepalive on interceptor gRPC channel
