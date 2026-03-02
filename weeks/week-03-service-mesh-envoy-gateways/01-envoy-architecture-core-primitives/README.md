# Envoy Architecture: Listeners, Filter Chains, Routes, Clusters, Endpoints

## What you should be able to do
- Explain Envoy request path end-to-end, naming each layer and the config objects that govern it.
- Explain xDS snapshots, ADS ordering, and what happens when a control plane pushes a bad config.
- Debug NR (no route), UH (no healthy upstream), TLS handshake failures, and xDS sync failures quickly using the admin API.

## Mental Model

Think of Envoy as a programmable network proxy whose entire behavior is described by a directed config graph. Every connection that arrives is walked down this graph: a Listener accepts the socket, a FilterChain is selected based on connection metadata, a set of network and HTTP filters process the bytes, a RouteConfiguration picks a Cluster, and the Cluster selects an Endpoint to forward traffic to. The graph is expressed as a set of protobuf messages, and Envoy holds the entire thing in memory. Nothing is read from disk at request time.

What makes this architecture powerful is that the config graph is decoupled from the data plane. Envoy does not know or care how its config was assembled. It only speaks a protocol called xDS (the "discovery service" API), which is a set of gRPC streaming RPCs. A control plane (Istio Pilot, Envoy Gateway, Contour, a hand-rolled management server) pushes snapshots of config objects over xDS, and Envoy applies them atomically. Because the entire in-memory graph is swapped at once, Envoy can hot-reload routes, certificates, and cluster membership without dropping connections or restarting the process. This is the core insight that distinguishes Envoy from nginx or HAProxy in dynamic cloud-native environments.

Control planes use this decoupling deliberately. Istio's istiod translates Kubernetes Service objects, VirtualServices, and DestinationRules into Envoy's native xDS types and pushes them to every sidecar. Envoy Gateway translates Gateway API resources (HTTPRoute, TLSRoute) into the same xDS types and pushes them to a standalone gateway Envoy fleet. From Envoy's perspective, the source of config is irrelevant. This is also why you can swap control planes without changing anything about how Envoy processes traffic.

The xDS protocol has an important ordering constraint: Clusters must exist before Routes reference them, and Endpoints (ClusterLoadAssignment) must exist before a Cluster is considered healthy. When using Aggregated Discovery Service (ADS) over a single gRPC stream, the control plane is responsible for pushing types in the correct dependency order. If it does not, Envoy will NACK (negative-acknowledge) the config update and continue using the previous snapshot, which is exactly the right behavior for a proxy that needs to never enter an invalid state.

## Key Concepts

- **Listener**: A named socket binding (address + port + optional UNIX domain socket). The root of the config graph. Envoy binds one OS socket per Listener. Multiple Listeners can share a port via `SO_REUSEPORT` at the OS level.
- **FilterChain**: A list of network-level filters associated with a set of matching criteria (SNI server name, ALPN protocol, source IP CIDR, destination port). The first FilterChain whose match criteria are satisfied wins. A Listener has an ordered list of FilterChains plus a default fallback.
- **HttpConnectionManager (HCM)**: The most important network filter. It implements HTTP/1.1, HTTP/2, and HTTP/3 parsing, manages HTTP streams, runs the HTTP filter chain, performs route matching, and forwards requests to upstream clusters. Virtually all traffic management in Envoy flows through HCM.
- **RouteConfiguration**: A named set of VirtualHosts attached to an HCM. Envoy evaluates RouteConfigurations against the `:authority` (Host) header to select a VirtualHost.
- **VirtualHost**: A group of routes that applies to one or more domain names. Matches against the `:authority` header. Contains an ordered list of Route entries.
- **Route**: A single routing rule inside a VirtualHost. Matches on path (prefix/exact/regex), headers, and query parameters. The match action is either a route to a cluster (with optional cluster weighting for traffic splitting), a redirect, or a direct response.
- **Cluster**: An upstream service definition. Specifies how Envoy connects to a set of backends: load balancing policy (ROUND_ROBIN, LEAST_REQUEST, RING_HASH, MAGLEV), connection pool settings, circuit breaker thresholds, health check config, and TLS context for upstream connections.
- **ClusterLoadAssignment (CLA)**: The xDS object (sent via EDS) that gives a Cluster its actual endpoint set. Contains a list of `LocalityLbEndpoints`, each scoped to a region/zone/subzone with an optional priority and load balancing weight.
- **Endpoint**: A single backend instance, expressed as an IP address + port inside a ClusterLoadAssignment. Can have an associated health status (HEALTHY, UNHEALTHY, DRAINING, TIMEOUT, DEGRADED).
- **xDS (LDS/RDS/CDS/EDS/SDS)**: The family of discovery service APIs. LDS = Listener Discovery Service, RDS = Route Discovery Service, CDS = Cluster Discovery Service, EDS = Endpoint Discovery Service, SDS = Secret Discovery Service (certificates and private keys). Each is a separate gRPC streaming RPC, or all can be multiplexed over a single ADS stream.
- **ADS (Aggregated Discovery Service)**: A single bidirectional gRPC stream that multiplexes all xDS resource types. The control plane controls the order in which resources are sent. Required for correct dependency ordering (CDS before RDS, EDS before CDS is marked ready).
- **ECDS (Extension Config Discovery Service)**: An xDS extension that allows individual HTTP filters or network filters within an HCM to have their configs delivered dynamically. Introduced to allow per-route or per-virtual-host filter config updates without replacing the entire HCM.
- **Envoy admin interface**: An HTTP server (default port 9901) that exposes runtime diagnostics. Critical endpoints: `/config_dump` (full in-memory config graph as JSON), `/clusters` (per-cluster stats including outlier ejection counts), `/listeners` (active listeners), `/stats` (all Envoy metrics in Prometheus-compatible text format), `/logging` (change log verbosity at runtime), `/healthcheck/fail` (manually mark Envoy unhealthy for graceful drain).

## Internals

### Request Path

1. **Listener acceptance (socket bind, SO_REUSEPORT)**: The OS delivers an accepted TCP connection to one of Envoy's worker threads (Envoy is single-threaded per event loop, with N worker threads mapped to `--concurrency`). The Listener's accept filters run first (e.g., `listener_filter` for original destination detection or `tls_inspector` for SNI/ALPN sniffing before the FilterChain is selected). `SO_REUSEPORT` allows multiple worker threads to each own a separate socket on the same address:port, eliminating the thundering herd problem.

2. **Filter chain matching (SNI, ALPN, source IP)**: Envoy evaluates the Listener's `filter_chains` in order against the connection's metadata. The `tls_inspector` listener filter populates `transport_protocol` (e.g., `tls` or `raw_buffer`) and `application_protocols` (ALPN, e.g., `h2`, `http/1.1`) and `server_names` (SNI). The first FilterChain whose `filter_chain_match` block satisfies all criteria wins. If none match, `default_filter_chain` is used. If that is absent, the connection is closed. This mechanism enables a single port 443 listener to serve different TLS certificates and different HCM configs based on SNI alone.

3. **TLS termination (SDS certificate fetch)**: If the selected FilterChain has a `DownstreamTlsContext`, Envoy performs TLS termination using BoringSSL. Certificates are provided via SDS rather than static config: Envoy sends an SDS request for the named secret (e.g., `kubernetes://my-cert`) and the control plane responds with the certificate chain and private key bytes. SDS enables certificate rotation without any config push from the control plane — only a new SDS response is needed. After TLS terminates, the plaintext bytes are handed to the network filter chain.

4. **HTTP connection manager processing**: The HCM is a `NetworkFilter` that handles all HTTP semantics. It assembles HTTP/1.1 or HTTP/2 frames into logical HTTP streams (`Http::StreamDecoder`), manages flow control, enforces `max_request_headers_kb`, applies `server_header_transformation` (server name stripping/overriding), and gates access to the route table. One HCM instance runs per connection; it can multiplex many HTTP/2 streams on that connection.

5. **HTTP filter chain (router, auth, rate limit)**: Each HCM has an ordered `http_filters` list. Filters run sequentially on the request path (decode direction) and in reverse on the response path (encode direction). Common filters: `envoy.filters.http.ext_authz` (calls an external gRPC/HTTP auth service, can short-circuit with 403), `envoy.filters.http.ratelimit` (calls an external rate limit service), `envoy.filters.http.jwt_authn` (validates JWT locally), `envoy.filters.http.lua` (runs Lua scripts), `envoy.filters.http.wasm` (runs Wasm modules), and finally `envoy.filters.http.router` which must always be last.

6. **Route matching (domain + path/header/query)**: The router filter consults the RouteConfiguration to find a matching Route. Matching is hierarchical: first the `:authority` header selects a VirtualHost (most-specific domain wins: exact > wildcard-prefix > wildcard), then routes within the VirtualHost are evaluated in order (first match wins). Route match criteria are AND'd: a route requiring prefix `/api/` AND header `x-version: v2` AND query parameter `debug=true` must satisfy all three. The matched Route carries per-route config including `timeout`, `retry_policy`, `request_mirror_policy` (traffic shadowing), `rate_limits`, and per-filter config overrides.

7. **Cluster selection and load balancing**: If the Route action is `route` (not redirect or direct_response), Envoy selects a cluster. For weighted cluster traffic splitting, a random number determines which cluster receives the request. The selected Cluster's load balancer implementation runs: ROUND_ROBIN uses a per-thread atomic counter, LEAST_REQUEST tracks active requests per endpoint, RING_HASH maps a hash of a request header to a consistent-hash ring of endpoints, MAGLEV implements Google's Maglev consistent hashing. The load balancer respects cluster-level circuit breaker thresholds (`max_connections`, `max_pending_requests`, `max_requests`, `max_retries`).

8. **Endpoint selection (health-aware, priority, locality)**: Within the chosen Cluster, the ClusterLoadAssignment provides endpoints grouped by `LocalityLbEndpoints`. Envoy first selects a priority level (level 0 unless all level-0 endpoints are unhealthy, in which case it overflows to level 1). Within a priority, it applies locality-weighted load balancing if zone-aware routing is configured. Individual endpoints that have been ejected by the outlier detection subsystem (passive health checking) are excluded. The active health checker (if configured with `health_checks`) also removes endpoints that fail health checks. The result is the actual upstream IP:port Envoy will connect to.

9. **Upstream connection and request forwarding**: Envoy draws a connection from the per-cluster, per-thread connection pool (`Http1::ConnPool` or `Http2::ConnPool`). If no idle connection exists and the pool is below `max_connections`, a new TCP connection is established (with optional upstream TLS using `UpstreamTlsContext` and SDS). The request headers and body are forwarded. Envoy adds `x-forwarded-for`, `x-envoy-upstream-service-time`, and any headers specified by the Route's `request_headers_to_add`. Retry logic (on 5xx, connect failure, reset) is governed by the `retry_policy` from the Route or VirtualHost.

10. **Response path and access logging**: The response travels back through the HTTP filter chain in encode direction (router → ratelimit → ext_authz → ... filters in reverse). Envoy measures `upstream_response_time_ms` and records the response flags (e.g., `NR`, `UH`, `UF`, `RL`, `UMSDR`). Access log is written after the response completes (or on a configurable stream completion timeout). Access log filters can limit logging to only error responses (`status_code_filter`) or sampled traffic (`runtime_filter`). The access log format supports command operators like `%RESPONSE_FLAGS%`, `%UPSTREAM_CLUSTER%`, `%UPSTREAM_HOST%`, `%DURATION%`, and `%BYTES_RECEIVED%/%BYTES_SENT%`.

### xDS Configuration Path

Config flows from the control plane to Envoy over a long-lived gRPC stream (ADS). The sequence for a new Envoy process connecting to its control plane:

1. Envoy opens a gRPC connection to the management server address (e.g., `istiod.istio-system.svc:15010`).
2. Envoy sends a `DiscoveryRequest` for each resource type it needs, starting with LDS (Listeners).
3. The control plane responds with a `DiscoveryResponse` containing the current snapshot for that type, stamped with a `version_info` string.
4. Envoy applies the config and sends an ACK (`DiscoveryRequest` with matching `version_info` and empty `error_detail`). If the config is invalid, Envoy sends a NACK with `error_detail` explaining the problem and continues using the previous version.
5. On ADS, the control plane must push CDS before RDS (because Routes reference Clusters by name, and Envoy will NACK an RDS response that references an unknown cluster). EDS responses for a cluster should be pushed before or immediately after the CDS response for that cluster.
6. When Kubernetes services change (pod added, Service created, VirtualService modified), the control plane recomputes affected snapshots and pushes incremental updates using `DeltaDiscoveryRequest`/`DeltaDiscoveryResponse` (delta xDS) or full state updates (SotW xDS). Envoy responds with ACK or NACK.

## Architecture Diagram

```
  ┌───────────────────────────────────────────────────────────────────────┐
  │                        CONTROL PLANE                                  │
  │    (Istio istiod / Envoy Gateway / Contour / custom mgmt server)      │
  │                                                                       │
  │  Kubernetes API Watch                                                 │
  │  (Services, Endpoints, VirtualServices, HTTPRoutes, Secrets, ...)     │
  │                          │                                            │
  │                          ▼                                            │
  │                  Config Translator                                    │
  │                  (K8s → xDS types)                                    │
  │                          │                                            │
  │        LDS  RDS  CDS  EDS  SDS   (xDS DiscoveryResponses)            │
  └──────────────────────────┼────────────────────────────────────────────┘
                             │  gRPC ADS stream (port 15010 / 18000)
                             ▼  ACK / NACK
  ┌───────────────────────────────────────────────────────────────────────┐
  │                          ENVOY PROCESS                                │
  │                                                                       │
  │  ┌─────────────────────────────────────────────────────────────────┐ │
  │  │  LISTENER  (0.0.0.0:443)                                        │ │
  │  │                                                                 │ │
  │  │  ┌──────────────────────────────────────────────────────────┐  │ │
  │  │  │  FILTER CHAIN MATCH  (SNI=api.example.com, ALPN=h2)      │  │ │
  │  │  │                                                          │  │ │
  │  │  │  [DownstreamTlsContext] ◄── SDS secret fetch             │  │ │
  │  │  │                                                          │  │ │
  │  │  │  ┌────────────────────────────────────────────────────┐  │  │ │
  │  │  │  │  HTTP CONNECTION MANAGER (network filter)          │  │  │ │
  │  │  │  │                                                    │  │  │ │
  │  │  │  │  HTTP Filter Chain (decode ▼ / encode ▲)           │  │  │ │
  │  │  │  │    ├── jwt_authn                                   │  │  │ │
  │  │  │  │    ├── ext_authz                                   │  │  │ │
  │  │  │  │    ├── ratelimit                                   │  │  │ │
  │  │  │  │    └── router ──────────────────────────────────┐  │  │  │ │
  │  │  │  │                                                 │  │  │  │ │
  │  │  │  │  ROUTE CONFIGURATION ◄── RDS                    │  │  │  │ │
  │  │  │  │    VirtualHost: api.example.com                 │  │  │  │ │
  │  │  │  │      Route: prefix=/v1  → cluster: api-v1       │  │  │  │ │
  │  │  │  │      Route: prefix=/v2  → cluster: api-v2       │  │  │  │ │
  │  │  │  │      Route: prefix=/    → redirect 301          │  │  │  │ │
  │  │  │  └──────────────────────────┬─────────────────────┘  │  │  │ │
  │  │  │                             │                         │  │  │ │
  │  │  └─────────────────────────────┼─────────────────────────┘  │  │ │
  │  └───────────────────────────────┼──────────────────────────────┘  │ │
  │                                  │                                  │ │
  │            ┌─────────────────────┘                                  │ │
  │            ▼                                                         │ │
  │  ┌─────────────────────────────┐   ◄── CDS                          │ │
  │  │  CLUSTER: api-v1            │                                     │ │
  │  │  lb_policy: LEAST_REQUEST   │                                     │ │
  │  │  circuit_breakers:          │                                     │ │
  │  │    max_connections: 1024    │                                     │ │
  │  │  health_checks: [HTTP /hz]  │                                     │ │
  │  │                             │                                     │ │
  │  │  LOAD ASSIGNMENT ◄── EDS    │                                     │ │
  │  │  LocalityLbEndpoints:       │                                     │ │
  │  │    zone=us-east-1a:         │                                     │ │
  │  │      10.0.1.5:8080 HEALTHY  │                                     │ │
  │  │      10.0.1.6:8080 HEALTHY  │                                     │ │
  │  │    zone=us-east-1b:         │                                     │ │
  │  │      10.0.2.7:8080 EJECTED  │ ◄── outlier detection               │ │
  │  └─────────────────────────────┘                                     │ │
  └───────────────────────────────────────────────────────────────────────┘
```

## Failure Modes & Debugging

### 1. NR - No Route Found (Route Mismatch / Missing VirtualHost)

**Symptoms**: Clients receive `503 Service Unavailable` responses instantly (sub-millisecond). Envoy access logs show `%RESPONSE_FLAGS%` as `NR`. Upstream cluster stats show no increase in `upstream_rq_total`. The `%RESPONSE_CODE_DETAILS%` field in the access log reads `route_not_found`.

**Root Cause**: The router filter could not find a matching Route in the RouteConfiguration. This happens in three main scenarios: (a) the `:authority` header does not match any VirtualHost domain (including wildcard `*`), meaning the RouteConfiguration has no applicable VirtualHost; (b) the VirtualHost exists but no Route's match criteria (prefix, path, headers, query params) are satisfied; (c) the RDS resource was not yet received from the control plane, so the HCM has no RouteConfiguration at all (common at startup or after a NACK).

**Blast Radius**: Affects only the specific request or traffic class that cannot be routed. Does not impact other VirtualHosts or clusters. However, in a gateway serving many downstream services, a misconfigured catch-all route can result in `NR` for all traffic.

**Mitigation**: Always include a wildcard VirtualHost (`domains: ["*"]`) as a fallback. Use `direct_response` with a meaningful status and body rather than relying on implicit NR behavior. Pin RDS to use ADS so route delivery is coordinated with cluster delivery. Monitor the `envoy_http_downstream_rq_no_route` counter.

**Debugging**:
```bash
# Dump the full in-memory route table from the admin API
curl -s http://localhost:9901/config_dump | \
  jq '.configs[] | select(.["@type"] | contains("RoutesConfigDump")) | .dynamic_route_configs'

# Check which VirtualHosts are configured and their domains
curl -s http://localhost:9901/config_dump | \
  jq '.. | .virtual_hosts? // empty | .[].domains'

# See the response flags and response code details in access logs
# Access log format must include %RESPONSE_FLAGS% and %RESPONSE_CODE_DETAILS%
kubectl logs -n istio-system deploy/istio-ingressgateway | grep '"NR"'

# Check if RDS is synced (look for "version_info" in the dynamic route config)
curl -s http://localhost:9901/config_dump | \
  jq '.configs[] | select(.["@type"] | contains("RoutesConfigDump")) | .dynamic_route_configs[].version_info'

# Envoy stat: total NR responses
curl -s http://localhost:9901/stats | grep 'no_route'
```

---

### 2. UH - No Healthy Upstream (All Endpoints Ejected or Unhealthy)

**Symptoms**: Clients receive `503 Service Unavailable`. Envoy access logs show `%RESPONSE_FLAGS%` as `UH` (upstream unhealthy). The `%RESPONSE_CODE_DETAILS%` reads `no_healthy_upstream`. Cluster stats show `cx_connect_fail` or `ejections_detected_consecutive_5xx` incrementing. This can appear suddenly when a rolling deployment removes all healthy endpoints simultaneously.

**Root Cause**: The Cluster's load balancer has no usable endpoint. This occurs when: (a) outlier detection (passive health checking) has ejected all endpoints due to consecutive 5xx errors or consecutive gateway failures; (b) active health checks have marked all endpoints as unhealthy; (c) EDS has delivered an empty ClusterLoadAssignment or one where all endpoints have `health_status: UNHEALTHY`; (d) the circuit breaker's `max_connections` or `max_pending_requests` threshold is hit, causing pending requests to be shed.

**Blast Radius**: All requests to the affected cluster fail. If the cluster backs a critical dependency, this causes cascading failures. Traffic splitting to a backup cluster (via priority levels or weighted clusters) can absorb the blast if configured.

**Mitigation**: Configure `panic_threshold` (default 50%): if more than 50% of endpoints are unhealthy, Envoy ignores health status and distributes across all endpoints ("panic mode"). For outlier detection, tune `consecutive_5xx` threshold and `max_ejection_percent` so that a single bad pod does not eject the entire cluster. Use `priority` levels in EDS so a secondary region activates on primary failure. Monitor `envoy_cluster_upstream_cx_none_healthy` counter.

**Debugging**:
```bash
# View per-cluster health and ejection status from the admin API
# HEALTHY/UNHEALTHY/EJECTED annotations are shown inline
curl -s http://localhost:9901/clusters | grep -A5 "my-cluster"

# Full cluster config dump with health check results
curl -s http://localhost:9901/config_dump | \
  jq '.configs[] | select(.["@type"] | contains("ClustersConfigDump")) | .dynamic_active_clusters'

# Outlier detection stats per cluster
curl -s http://localhost:9901/stats | grep 'outlier_detection'

# EDS health status from the control plane side (Istio example)
istioctl proxy-config endpoint POD_NAME.NAMESPACE --cluster "outbound|8080||my-svc.default.svc.cluster.local"

# Check circuit breaker thresholds and current levels
curl -s http://localhost:9901/stats | grep 'circuit_breakers\|overflow'
```

---

### 3. TLS Handshake Failure (Certificate Mismatch, Expired Cert, SDS Delay)

**Symptoms**: Connections to Envoy (or from Envoy to upstream) fail with TLS errors. Clients see `SSL_ERROR_RX_RECORD_TOO_LONG`, `CERTIFICATE_VERIFY_FAILED`, or connection reset after the TLS ClientHello. Envoy access logs show `%RESPONSE_FLAGS%` as `UF` (upstream connection failure) or `DC` (downstream connection termination) with `%RESPONSE_CODE_DETAILS%` of `tls_error`. The `envoy_listener_ssl_connection_error` counter increments on the downstream side; `envoy_cluster_ssl_handshake_error` increments for upstream TLS failures.

**Root Cause**: Three distinct causes share similar symptoms. First, **certificate mismatch**: the certificate's `Subject Alternative Names` (SANs) do not match the hostname the client or Envoy is connecting to; this is common when a wildcard cert is updated to a more specific cert without updating the SAN list. Second, **expired certificate**: the certificate's `notAfter` field has passed; in mTLS environments this simultaneously breaks both directions. Third, **SDS delivery delay**: at startup or after a cert rotation, Envoy requests the new secret via SDS but the control plane has not yet pushed it; Envoy will not serve TLS on that FilterChain until the secret arrives, causing connections to be rejected or indefinitely pending.

**Blast Radius**: If the affected listener or cluster serves traffic for multiple virtual hosts (SNI-based routing), only the requests targeting the misconfigured SNI are affected. With mTLS (Istio PeerAuthentication), a single expired workload cert can take down all traffic to that pod. An SDS delay at startup in a high-traffic service causes a brief `ECONNREFUSED` storm during pod rollouts.

**Mitigation**: Automate certificate rotation using cert-manager or Istio's built-in SPIFFE/X.509 cert rotation (default 24h lifetime, rotated at ~50% of lifetime). Monitor certificate expiry with `server.days_until_first_cert_expiring` gauge (available from the Envoy admin API `/stats`) and alert when it drops below 2 days; for detailed cert expiry timestamps use the `/certs` admin endpoint or `istioctl proxy-config secret`. Use `SAN matching` in `UpstreamTlsContext.combined_validation_context` so upstream TLS fails closed on SAN mismatch rather than accepting any cert. For SDS delays at startup, configure `initial_fetch_timeout` in the SDS `ConfigSource` so Envoy fails fast and shows a clear error rather than hanging.

**Debugging**:
```bash
# Check SSL stats on the listener (downstream TLS)
curl -s http://localhost:9901/stats | grep 'ssl\.' | grep -E 'handshake|fail|error'

# Inspect the certificate currently loaded in memory (from admin API)
curl -s http://localhost:9901/certs | jq '.'

# Verify which SDS secret is configured and whether it has been delivered
curl -s http://localhost:9901/config_dump | \
  jq '.. | .tls_certificate_sds_secret_configs? // empty'

# Check if SDS secrets are in the dynamic secrets (version_info present means delivered)
curl -s http://localhost:9901/config_dump | \
  jq '.configs[] | select(.["@type"] | contains("SecretsConfigDump"))'

# Manually test TLS from outside (check SAN and expiry)
openssl s_client -connect localhost:443 -servername api.example.com </dev/null 2>&1 | \
  openssl x509 -noout -text | grep -E 'Not After|DNS:'

# For Istio mTLS, check the workload cert via the proxy-config command
istioctl proxy-config secret POD_NAME.NAMESPACE
```

---

### 4. xDS Sync Failure (Control Plane Unreachable or Config NACK'd)

**Symptoms**: Envoy continues serving traffic with a stale config snapshot. New Kubernetes Services or route rules do not take effect. The `envoy_control_plane_connected_state` gauge drops to 0. In Istio, `pilot_xds_push_errors` counter increments on the istiod side. Envoy logs show `gRPC config stream closed: 14, connection refused` or repeated `NACK` messages. After a NACK, `envoy_control_plane_xds_rejection_count` increments.

**Root Cause**: Two failure modes. First, **control plane unreachable**: the gRPC connection to the management server is broken (istiod pod crash, network policy blocking port 15010, DNS resolution failure for the management cluster address). Envoy retries with exponential backoff but continues using the last successful snapshot, so existing traffic is unaffected but config changes do not propagate. Second, **config NACK**: the control plane pushed a syntactically valid but semantically invalid xDS config (e.g., a Route referencing a Cluster name that does not exist in the current CDS snapshot, an invalid regex in a route match, or a conflicting filter chain). Envoy rejects the update with a NACK, logs the error, and holds the previous config. This can leave a mixed state where some Envoy instances have accepted a new config and others have not (partial rollout).

**Blast Radius**: For control plane unreachable: existing traffic is unaffected, but no new config changes propagate. Deployments that depend on route updates (blue-green cutover, traffic shifting) are stuck. For NACK'd config: the Envoy instance is frozen at its last good snapshot. If this is a sidecar, new pods of the same service may get the good config while old pods do not, causing inconsistent routing behavior.

**Mitigation**: Run the control plane with multiple replicas and a PodDisruptionBudget. Use `connect_timeout` and `backoff.max_interval` on the ADS cluster config to control reconnect behavior. Monitor `envoy_control_plane_connected_state` (should always be 1 in steady state) and `envoy_control_plane_pending_requests` (should be near 0). For NACKs, add validation in the control plane pipeline (e.g., `envoyvalidator` or `xds-validator`) before pushing to Envoy. In Istio, check `pilot_xds_push_errors` and `pilot_xds_config_send_count` metrics.

**Debugging**:
```bash
# Check control plane connection status
curl -s http://localhost:9901/stats | grep 'control_plane'

# View the last received version of each xDS type and whether it was ACK'd or NACK'd
curl -s http://localhost:9901/config_dump | \
  jq '.configs[] | select(.["@type"] | contains("BootstrapConfigDump")) | .bootstrap.dynamic_resources'

# Check Envoy logs for NACK details (enable debug logging at runtime)
curl -s -X POST "http://localhost:9901/logging?level=debug"
# Then watch logs for "nack" or "rejected"
kubectl logs -n NAMESPACE POD_NAME -c istio-proxy | grep -i 'nack\|reject\|invalid'

# Istio-specific: check xDS push stats on the control plane
kubectl exec -n istio-system deploy/istiod -- \
  curl -s localhost:15014/metrics | grep pilot_xds

# Verify the xDS resource versions Envoy has accepted per type
# (LDS, RDS, CDS, EDS versions should all advance over time)
curl -s http://localhost:9901/stats | grep 'version_text'

# Force Envoy to reconnect (only in emergencies — restarts the xDS client)
# This is a last resort; in practice, fix the control plane config instead.
curl -s -X POST http://localhost:9901/reset_counters
```

## Lightweight Lab

Start a minimal Envoy with a static config (no control plane) to observe the config graph directly. The upstream is a simple HTTP echo server, and Envoy's admin interface lets you inspect the loaded config in real time.

```bash
# Start a minimal upstream HTTP server
docker run --rm -d --name upstream -p 18080:80 hashicorp/http-echo -text="hello from upstream"

# Start Envoy with your static config mounted in
# Port 10000 = Envoy listener (proxied traffic)
# Port 9901  = Envoy admin interface
docker run --rm -d --name envoy \
  -p 10000:10000 \
  -p 9901:9901 \
  -v $PWD/lab/envoy.yaml:/etc/envoy/envoy.yaml \
  envoyproxy/envoy:v1.30-latest

# Send a request through Envoy to the upstream
curl http://localhost:10000/

# Inspect the full in-memory config graph (Listeners → Clusters → Routes)
curl -s http://localhost:9901/config_dump | jq '.'

# Watch live cluster health and endpoint stats
curl -s http://localhost:9901/clusters

# Stream access logs and Envoy stats
curl -s http://localhost:9901/stats | grep -E 'downstream_rq|upstream_rq|no_route'
```

## What to commit
- Add mapping: platform gateway constructs → Envoy primitives (e.g., Istio Gateway/VirtualService → LDS/RDS, HTTPRoute → RDS VirtualHost/Route, DestinationRule → CDS Cluster config).
