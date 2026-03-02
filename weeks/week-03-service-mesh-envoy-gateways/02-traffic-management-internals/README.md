# Traffic Management Internals: Priority LB, Locality, Weighted Shifting, Failover

## What you should be able to do
- Explain step-by-step how Envoy selects an endpoint using priority levels, locality weights, and outlier ejection state, and where `overprovisioning_factor` fits into the spillover calculation.
- Describe how outlier detection creates a passive health feedback loop and how `consecutive_5xx`, `base_ejection_time`, and `max_ejection_percent` interact to prevent total endpoint ejection.
- Debug traffic-shifting brownouts, panic-threshold masking, and circuit breaker overflow using Envoy's admin API stats and the `/clusters` endpoint.

## Mental Model

The two-layer architecture is the foundation. The control plane (Istio Pilot, Envoy Gateway, a hand-rolled xDS server) declares intent: which endpoints belong to which priority level, what locality weights apply, and what the outlier detection policy is. The data plane (Envoy) executes decisions at wire speed using only what it holds in memory. Envoy never calls back to the control plane at request time. This separation is what makes sub-millisecond failover possible — the entire endpoint selection algorithm is a few hundred nanoseconds of in-process logic against a data structure that was last updated when the control plane pushed an EDS response.

Priority levels give operators a clean way to express "prefer region A, fall back to region B." Every `LocalityLbEndpoints` group in a `ClusterLoadAssignment` carries a `priority` integer (0 = highest). Envoy's priority load balancer tracks the aggregate health percentage of each priority level at all times. When the healthy percentage of P0 drops below a threshold derived from `overprovisioning_factor`, Envoy starts spilling traffic to P1 proportional to the deficit. This is not a binary flip — it is continuous rebalancing. A P0 cluster that is 70% healthy and has an `overprovisioning_factor` of 1.4 is still considered fully covering demand, so no spill occurs. This prevents unnecessary failover during routine pod restarts.

Locality-weighted routing layers on top of priority selection. Within a single priority level, endpoint groups can be annotated with a `locality` (region + zone + subzone) and a `load_balancing_weight`. Envoy distributes traffic across localities in proportion to these weights, then within each locality uses the cluster's `lb_policy` (ROUND_ROBIN, LEAST_REQUEST, RING_HASH, MAGLEV) to pick an individual endpoint. Zone-aware routing in Istio uses this mechanism: the control plane annotates endpoints with the pod's zone label and assigns weights so that Envoy in `us-east-1a` preferentially sends traffic to endpoints in `us-east-1a`. This reduces cross-zone data transfer costs and latency without the operator writing any explicit routing rules.

Outlier detection closes the feedback loop. It is passive — Envoy observes upstream response codes and connection-level errors on live traffic rather than sending synthetic health check probes. When a configured threshold is crossed (e.g., five consecutive 5xx responses from an endpoint), Envoy ejects that endpoint from the load balancer for `base_ejection_time * num_previous_ejections`. The ejection duration grows with repeat offenses. `max_ejection_percent` caps how much of the cluster can be ejected at once, preventing a cascade where a bad deployment poisons the outlier detector into removing every endpoint. The interaction with `panic_threshold` is subtle: if ejections push the healthy percentage below `panic_threshold` (default 50%), Envoy abandons health-aware selection entirely and distributes across all endpoints including ejected ones. This "panic mode" is a circuit breaker of last resort — it keeps the cluster serving at degraded quality rather than returning `UH` (no healthy upstream) to every caller.

## Key Concepts

- **priority**: Integer field on `LocalityLbEndpoints` (0 = highest priority). Envoy always tries the lowest-numbered priority first. Multiple locality groups can share the same priority level; they are treated as peers within that level.
- **LocalityLbEndpoints**: A group of endpoints sharing a `Locality` (region/zone/subzone), a `priority`, and an optional `load_balancing_weight`. The unit of locality-aware load balancing in a `ClusterLoadAssignment`.
- **locality_weight** (`load_balancing_weight` on `LocalityLbEndpoints`): Relative weight for distributing traffic across locality groups within the same priority level. If group A has weight 100 and group B has weight 50, group A receives 2/3 of the traffic. Absent weights cause equal distribution.
- **overprovisioning_factor**: A multiplier (default 1.4, i.e., 140%) applied to the healthy percentage of the current priority level before deciding whether spillover is needed. If P0 has 80% healthy endpoints, the effective coverage is 80 * 1.4 = 112%, which exceeds 100%, so no P1 spillover occurs. This prevents unnecessary failover during routine pod restarts that briefly drop healthy percentage below 100%.
- **panic_threshold**: The minimum healthy-endpoint percentage below which Envoy ignores health status and distributes traffic across all endpoints (including ejected ones). Default 50%. Prevents `UH` (no healthy upstream) at the cost of sending traffic to known-bad endpoints. Configurable per cluster via `common_lb_config.healthy_panic_threshold`.
- **outlier_detection**: The passive health checking subsystem in Envoy's cluster config. Monitors live traffic for error signals and ejects misbehaving endpoints from the load balancer without requiring synthetic probes.
- **consecutive_5xx**: Number of consecutive upstream HTTP 5xx responses from an endpoint before it is ejected. Default 5. Also counts locally-originated errors (connection failures, reset streams) if `split_external_local_origin_errors` is false.
- **consecutive_gateway_failure**: Number of consecutive upstream responses that are gateway-level failures (502, 503, 504) before ejection. Distinct from `consecutive_5xx` because these specifically indicate the upstream gateway failed, not the application. Default 5.
- **base_ejection_time**: Initial duration an endpoint remains ejected after its first ejection event. Each subsequent ejection for the same endpoint multiplies this by the ejection count: `base_ejection_time * num_ejections`. Default 30s.
- **max_ejection_percent**: Cap on the percentage of endpoints in a cluster that outlier detection is allowed to eject simultaneously. Default 10%. Prevents a bad deployment from causing outlier detection to eject every endpoint and trigger a full-cluster `UH`.
- **weighted_clusters**: A `Route` action that distributes traffic across multiple clusters according to integer weights. Used for canary releases (e.g., 95 to `api-stable`, 5 to `api-canary`). The weights are relative integers; Envoy normalizes them. Distinct from EDS locality weights — weighted clusters operate at the route level, locality weights operate inside a single cluster.
- **retry_policy**: Per-route or per-virtual-host config specifying conditions under which Envoy retries a request (e.g., `5xx`, `gateway-error`, `connect-failure`, `retriable-4xx`) and the maximum number of retries. Interacts with outlier detection: a retried request to a different endpoint may count separately toward that endpoint's outlier counters, accelerating ejection of a bad endpoint during a retry storm.
- **circuit_breakers**: Cluster-level resource limits that shed load rather than queue indefinitely. Fields: `max_connections` (TCP connections to upstream), `max_pending_requests` (requests queued waiting for a connection), `max_requests` (concurrent active requests), `max_retries` (concurrent active retries). Overflow is tracked by `upstream_rq_pending_overflow` and `upstream_rq_retry_overflow` counters.

## Internals

### Priority Load Balancing Algorithm

Envoy recalculates priority distribution on every request using the current health state of each priority level's endpoints. The steps are deterministic and synchronous — no locks, no external calls.

1. **Compute healthy percentage for each priority level**: For each `LocalityLbEndpoints` group, Envoy counts endpoints in `HEALTHY` or `DEGRADED` state (not `UNHEALTHY`, `DRAINING`, or currently ejected by outlier detection). The healthy percentage for priority P is `(healthy_endpoint_count / total_endpoint_count) * 100`.

2. **Apply overprovisioning factor**: Envoy multiplies the healthy percentage by `overprovisioning_factor` (default 1.4). This gives an "effective coverage" percentage for each priority level. A P0 group that is 80% healthy has effective coverage of 112%, which is treated as 100% — full coverage.

3. **Determine if spillover to P1 is needed**: If P0's effective coverage exceeds 100%, all traffic goes to P0 and priority selection ends. If P0's effective coverage is below 100%, the deficit (100 - effective_coverage) is the percentage of traffic that must spill to P1. For example, if P0 has 50% healthy endpoints with a 1.4 factor: 50 * 1.4 = 70% effective coverage; 30% spills to P1.

4. **Apply locality weights within the selected priority**: Once a priority level is chosen, Envoy selects a locality group within that priority proportionally to `load_balancing_weight`. If weights are absent, all locality groups within the priority are treated equally.

5. **Apply the cluster lb_policy within the selected locality**: Within the chosen locality group, Envoy runs the endpoint selection algorithm configured by `lb_policy` (ROUND_ROBIN, LEAST_REQUEST, etc.) against only the healthy endpoints in that group.

6. **Panic mode override**: If after steps 1-2 the total healthy percentage across all priority levels (weighted by spillover allocation) falls below `panic_threshold` (default 50%), Envoy abandons health-aware selection. It distributes traffic as if all endpoints were healthy, regardless of ejection state. Panic mode is logged at WARN level and increments the `upstream_cx_none_healthy` counter. The intent is to keep serving degraded traffic rather than returning `UH` to all callers.

7. **Circuit breaker gate**: Before forwarding, Envoy checks the cluster's circuit breaker thresholds. If `max_pending_requests` is exceeded, the request is rejected immediately with `upstream_rq_pending_overflow` incremented and a 503 returned. This happens after endpoint selection but before the connection pool is consulted.

### Outlier Detection and Ejection

Outlier detection runs as a background subsystem per cluster. It processes success/failure signals emitted by the request path and makes ejection decisions asynchronously. The request path itself is not blocked by outlier detection logic.

1. **Error accounting**: After each upstream response, the request path emits a success or failure signal to the outlier detector for the specific endpoint used. Failures include: HTTP 5xx responses (if `consecutive_5xx > 0`), HTTP 502/503/504 responses (if `consecutive_gateway_failure > 0`), local origin errors like connection reset and connection timeout (counted separately if `split_external_local_origin_errors: true`).

2. **Ejection decision**: When an endpoint's consecutive failure counter reaches the configured threshold (`consecutive_5xx`, `consecutive_gateway_failure`, or `consecutive_local_origin_failure`), the outlier detector checks whether `max_ejection_percent` allows another ejection. If `(current_ejected_count + 1) / total_endpoints > max_ejection_percent`, the ejection is skipped to protect the cluster. If allowed, the endpoint's health status is set to EJECTED and it is removed from the load balancer's active endpoint set.

3. **Ejection duration with linear backoff**: The first ejection of an endpoint lasts `base_ejection_time` (e.g., 30s). The second ejection of the same endpoint lasts `2 * base_ejection_time`. The third lasts `3 * base_ejection_time`, capped at `max_ejection_time` (default 300s). This linear backoff prevents flapping — a consistently bad endpoint is kept out of rotation for progressively longer periods.

4. **Unejection (periodic check)**: Every `interval` (default 10s), the outlier detector scans all ejected endpoints. An endpoint is eligible for return if its ejection duration has elapsed. On return, its consecutive failure counter is reset to zero. If it immediately produces errors again, re-ejection occurs after `consecutive_5xx` more failures, and the ejection counter increments again.

5. **Interaction with panic mode**: As endpoints are ejected, the healthy percentage drops. If ejections push the healthy percentage below `panic_threshold`, Envoy enters panic mode and ignores the ejection state. This means the outlier detector is still running and still tracking failures, but the load balancer is no longer honoring its decisions. The ejections become invisible. This is the most dangerous interaction in traffic management: outlier detection appears to be working (the admin API shows ejected endpoints) but traffic is still being sent to them.

## Architecture Diagram

```
  CONTROL PLANE (istiod / Envoy Gateway)
  ┌────────────────────────────────────────────────────────────────┐
  │  Kubernetes Watch: Services, Endpoints, DestinationRules, ...  │
  │                          │                                     │
  │              EDS (ClusterLoadAssignment)                       │
  │  LocalityLbEndpoints:                                          │
  │    priority=0, zone=us-east-1a, weight=100                     │
  │      10.0.1.5:8080 HEALTHY                                     │
  │      10.0.1.6:8080 HEALTHY                                     │
  │    priority=0, zone=us-east-1b, weight=100                     │
  │      10.0.2.7:8080 HEALTHY                                     │
  │    priority=1, zone=us-west-2a, weight=100   (failover)        │
  │      10.1.0.3:8080 HEALTHY                                     │
  └───────────────────────┬────────────────────────────────────────┘
                          │  xDS EDS push (gRPC ADS stream)
                          ▼
  ENVOY DATA PLANE
  ┌────────────────────────────────────────────────────────────────┐
  │                                                                │
  │  PRIORITY SELECTION                                            │
  │  ┌─────────────────────────────────────────────────────────┐  │
  │  │  P0 healthy%: 100  * overprovisioning_factor(1.4) = 140 │  │
  │  │  140 >= 100  →  all traffic to P0, no spillover         │  │
  │  │                                                          │  │
  │  │  [pod crash: P0 drops to 50% healthy]                   │  │
  │  │  P0 effective coverage: 50 * 1.4 = 70                   │  │
  │  │  deficit: 100 - 70 = 30  →  30% spills to P1           │  │
  │  └─────────────────────┬───────────────────────────────────┘  │
  │                        │                                       │
  │  LOCALITY SELECTION (within chosen priority)                   │
  │  ┌─────────────────────────────────────────────────────────┐  │
  │  │  zone=us-east-1a weight=100  (50% of locality traffic)  │  │
  │  │  zone=us-east-1b weight=100  (50% of locality traffic)  │  │
  │  │  lb_policy: LEAST_REQUEST  →  pick least-loaded healthy  │  │
  │  └─────────────────────┬───────────────────────────────────┘  │
  │                        │                                       │
  │  CIRCUIT BREAKER GATE                                          │
  │  ┌─────────────────────────────────────────────────────────┐  │
  │  │  max_pending_requests: 100                              │  │
  │  │  current_pending > 100  →  shed: upstream_rq_pending_   │  │
  │  │                              overflow++, return 503     │  │
  │  └─────────────────────┬───────────────────────────────────┘  │
  │                        │                                       │
  │  UPSTREAM CONNECTION → endpoint 10.0.1.5:8080                 │
  │                        │                                       │
  │  RESPONSE PATH                                                 │
  │  ┌─────────────────────▼───────────────────────────────────┐  │
  │  │  5xx response received                                  │  │
  │  │     ↓                                                   │  │
  │  │  OUTLIER DETECTION (passive, async)                     │  │
  │  │  consecutive_5xx counter for 10.0.1.5:8080 ++           │  │
  │  │  counter >= threshold (5)?                              │  │
  │  │    yes → ejected_count / total < max_ejection_percent?  │  │
  │  │      yes → EJECT  (duration = base_ejection_time * N)   │  │
  │  │      no  → skip ejection (protect cluster)              │  │
  │  │    no  → continue accumulating                          │  │
  │  └─────────────────────────────────────────────────────────┘  │
  │                                                                │
  │  PANIC MODE CHECK (runs before each endpoint selection)        │
  │  ┌─────────────────────────────────────────────────────────┐  │
  │  │  healthy% < panic_threshold(50)?                        │  │
  │  │    yes → ignore health/ejection, use all endpoints      │  │
  │  │    no  → normal health-aware selection                  │  │
  │  └─────────────────────────────────────────────────────────┘  │
  └────────────────────────────────────────────────────────────────┘
```

## Failure Modes & Debugging

### 1. Outlier Detection Thrashing — Rapid Eject/Uneject Cycling

**Symptoms**: Services show intermittent elevated error rates (5-15% 5xx) that never stabilize. The Envoy admin `/clusters` output shows endpoints cycling between HEALTHY and EJECTED. `envoy_cluster_outlier_detection_ejections_active` oscillates rather than staying zero. P99 latency spikes occur at `base_ejection_time` intervals as endpoints are unejected and immediately take live traffic again.

**Root Cause**: The `interval` (re-evaluation period, default 10s) and `base_ejection_time` (default 30s) are too short relative to the upstream's error pattern. A noisy upstream that produces bursts of 5xx errors — common with JVM services during GC pauses, or applications with connection pool exhaustion — repeatedly crosses the `consecutive_5xx` threshold. Each ejection ends after `base_ejection_time`, the endpoint returns, immediately receives traffic, and if the underlying issue persists, is ejected again. The ejection counter increments on each cycle, so the ejection duration grows, but if the upstream recovers between cycles, the counter resets to zero and the cycle restarts.

**Blast Radius**: Thrashing degrades effective cluster capacity because ejected endpoints are unavailable. With `max_ejection_percent` at default 10%, only one endpoint in a 10-endpoint cluster can be ejected at once — but if multiple endpoints are noisy, they thrash in sequence. Client-facing error rates reflect the traffic that hits an endpoint in its brief recovery window before re-ejection.

**Mitigation**: Increase `base_ejection_time` to 60-120s and set `max_ejection_time` to 300s so persistent bad endpoints stay out longer. Tune `consecutive_5xx` upward (e.g., 10) to require more evidence before ejection. Enable `split_external_local_origin_errors: true` to distinguish between application errors and network errors — GC pauses cause connection resets (local origin), not 5xx (external). Set `success_rate_minimum_hosts` and `success_rate_request_volume` to use success-rate-based ejection instead of absolute consecutive counts, which is more resilient to bursty traffic.

**Debugging**:
```bash
# Watch active ejections per cluster in real time
watch -n 2 'curl -s http://localhost:9901/stats | grep "outlier_detection.ejections_active"'

# Per-cluster ejection event counters (total, consecutive 5xx, gateway error)
curl -s http://localhost:9901/stats | grep -E 'outlier_detection\.(ejections_total|ejections_detected_consecutive_5xx|ejections_detected_gateway_failure)'

# View which specific endpoints are currently EJECTED
curl -s http://localhost:9901/clusters | grep -A3 'EJECTED'

# Full outlier detection config for a cluster
curl -s http://localhost:9901/config_dump | \
  jq '.configs[] | select(.["@type"] | contains("ClustersConfigDump")) |
      .dynamic_active_clusters[] | select(.cluster.name == "my-cluster") |
      .cluster.outlier_detection'
```

---

### 2. Panic Threshold Masking Failures — Degraded Traffic to Bad Endpoints

**Symptoms**: A deployment pushes a bad version of a service. Error rates rise to 40-50% but never trigger a full outage. Outlier detection appears to be working (`ejections_active` is nonzero), yet bad traffic continues at high volume. The Envoy `/clusters` endpoint shows several endpoints as EJECTED, but `upstream_rq_5xx` is still climbing. PagerDuty does not fire because error rate stays just below the SLO threshold.

**Root Cause**: `panic_threshold` defaults to 50%. When outlier detection ejects enough endpoints to push the healthy percentage below 50%, Envoy enters panic mode and ignores the ejection state entirely — it load-balances across all endpoints, including the ejected (bad) ones. In a small cluster (e.g., 6 pods), ejecting 4 pods (67%) triggers panic mode. The 4 ejected bad pods are now back in rotation, each contributing bad responses. The outlier detector continues running and marking ejections, but the load balancer is not honoring them.

**Blast Radius**: All traffic to the cluster is affected once panic mode activates. Error rate roughly equals the fraction of bad endpoints in the cluster (e.g., 4/6 = 67% error rate). Callers that have retry policies will exhaust retries and begin failing. Downstream services that depend on this cluster cascade. The masking effect means the incident is initially misdiagnosed as "partial degradation" rather than "majority of instances are bad."

**Mitigation**: Lower `panic_threshold` to 20-30% for clusters where bad traffic is worse than no traffic. Set `max_ejection_percent` to 80-100% for clusters where you trust outlier detection to correctly identify bad endpoints. For canary deployments, keep canary clusters small (5-10% of traffic) so ejection of one canary pod does not push healthy% below panic threshold. Monitor `envoy_cluster_lb_healthy_panic` counter — a nonzero value means panic mode activated.

**Debugging**:
```bash
# Detect panic mode activation (nonzero = panic mode has triggered)
curl -s http://localhost:9901/stats | grep 'lb_healthy_panic'

# Check current healthy vs total endpoint counts per cluster
curl -s http://localhost:9901/clusters | grep -E '(healthy|total)_weight|cx_active'

# See panic threshold configured for a cluster
curl -s http://localhost:9901/config_dump | \
  jq '.configs[] | select(.["@type"] | contains("ClustersConfigDump")) |
      .dynamic_active_clusters[] | select(.cluster.name == "my-cluster") |
      .cluster.common_lb_config.healthy_panic_threshold'

# Cross-reference: ejections are active but error rate is still high → panic mode
curl -s http://localhost:9901/stats | grep -E 'ejections_active|upstream_rq_5xx|lb_healthy_panic'
```

---

### 3. Weighted Shifting Brownout — Canary Traffic with Insufficient Outlier Detection

**Symptoms**: A gradual canary shift (starting at 1%, ramping to 100% over 30 minutes) initially appears healthy. At ~20% canary traffic, error rate begins rising but stays below 5%. At 50%, error rate is 8%. Metrics show the canary cluster (`api-canary`) has elevated `upstream_rq_5xx` but the stable cluster (`api-stable`) remains clean. The weighted shift continues because automation only pauses at 10% error rate.

**Root Cause**: Outlier detection is configured on the parent cluster but `weighted_clusters` in the route splits traffic between two distinct Envoy cluster objects (`api-stable` and `api-canary`). Each cluster has its own outlier detection state. The canary cluster starts with zero ejection history, so `base_ejection_time * 1 = 30s` for the first ejection. With only 3 canary pods and `max_ejection_percent: 10%` (default), at most 0 pods can be ejected (floor(3 * 0.10) = 0). Outlier detection is effectively disabled for a 3-pod cluster at default `max_ejection_percent`. All 3 canary pods remain in rotation regardless of their error rate.

**Blast Radius**: Proportional to the current canary weight. At 20% weight, 20% of total traffic sees the canary's error rate. The 80% on stable is clean, masking the incident in aggregate error rate dashboards. If automation continues the ramp, blast radius grows linearly with the canary weight. By the time the error rate breaches 10%, the canary may be at 80% weight.

**Mitigation**: For small canary clusters, set `max_ejection_percent: 100` so all pods can be ejected if they misbehave. Use success-rate-based outlier detection (`success_rate_stdev_factor`, `success_rate_minimum_hosts: 1`) instead of consecutive count thresholds, which require sufficient request volume to be meaningful. Implement a separate circuit breaker at the route level using Envoy's `envoy.filters.http.local_ratelimit` or an external progressive delivery controller (Flagger, Argo Rollouts) that monitors canary metrics independently of Envoy.

**Debugging**:
```bash
# Compare 5xx rates between the stable and canary clusters
curl -s http://localhost:9901/stats | grep -E '(api-stable|api-canary).*upstream_rq_5xx'

# Check outlier detection config and ejection state for each weighted cluster
curl -s http://localhost:9901/clusters | grep -A10 'api-canary'

# Verify max_ejection_percent is set high enough for small clusters
curl -s http://localhost:9901/config_dump | \
  jq '.configs[] | select(.["@type"] | contains("ClustersConfigDump")) |
      .dynamic_active_clusters[] |
      select(.cluster.name | startswith("api-canary")) |
      {name: .cluster.name, max_ejection_pct: .cluster.outlier_detection.max_ejection_percent}'

# See the current weighted cluster split (route-level config)
curl -s http://localhost:9901/config_dump | \
  jq '.. | .weighted_clusters? // empty | .clusters[]'
```

---

### 4. Circuit Breaker Overflow — max_pending_requests Too Low

**Symptoms**: Under load, a fraction of requests fail immediately (sub-millisecond) with 503. The Envoy access log shows `%RESPONSE_FLAGS%` as `UO` (upstream overflow) and `%RESPONSE_CODE_DETAILS%` as `circuit_breaker_pending_requests_overflow`. The `upstream_rq_pending_overflow` counter increments rapidly. Backend services show no corresponding increase in `upstream_rq_5xx` — the errors are shed by Envoy before the request reaches the upstream.

**Root Cause**: `circuit_breakers.thresholds.max_pending_requests` (default 1024) is too low for the traffic volume. Pending requests are requests that have been accepted by Envoy but are waiting for a connection to become available from the connection pool (because all connections are at `max_requests` capacity, or no idle connection exists and `max_connections` is saturated). This is distinct from active requests and circuit-breaking on errors — it is pure resource saturation. Common triggers: a slow upstream (high latency → connections stay active longer → queue builds), sudden traffic spike, or a cluster that is correctly sized at steady state but cannot absorb burst traffic.

**Blast Radius**: Shed requests fail fast (503), which may be better than queueing them (adding latency). However, shedding during a traffic spike can cause upstream retries from callers, amplifying the total request volume. If `max_retries` is also saturated (`upstream_rq_retry_overflow` counter), retries are dropped too. In a microservice call chain, a single overloaded cluster with aggressive circuit breaking can shed requests that propagate 503s up the entire call graph.

**Mitigation**: Set `max_pending_requests` based on the product of maximum acceptable latency and expected request rate (Little's Law: L = lambda * W). For a service expecting 500 RPS with p99 latency of 200ms, the queue depth should be at least 500 * 0.2 = 100. Add headroom. Tune `max_connections` alongside `max_pending_requests`: a low `max_connections` causes the queue to fill because no new connections can be opened. Monitor `upstream_rq_pending_active` (current queue depth) in addition to `upstream_rq_pending_overflow` (shed count) to distinguish between "queue is full" and "queue is growing but not yet full."

**Debugging**:
```bash
# Count of requests shed due to pending queue overflow
curl -s http://localhost:9901/stats | grep 'upstream_rq_pending_overflow'

# Current pending queue depth (should be low at steady state)
curl -s http://localhost:9901/stats | grep 'upstream_rq_pending_active'

# Current circuit breaker state and thresholds
curl -s http://localhost:9901/stats | grep 'circuit_breakers'

# Full circuit breaker config for a cluster (max_connections, max_pending_requests, etc.)
curl -s http://localhost:9901/config_dump | \
  jq '.configs[] | select(.["@type"] | contains("ClustersConfigDump")) |
      .dynamic_active_clusters[] | select(.cluster.name == "my-cluster") |
      .cluster.circuit_breakers'

# Correlate: retry overflow (max_retries exhausted) alongside pending overflow
curl -s http://localhost:9901/stats | grep -E 'upstream_rq_(retry_overflow|pending_overflow|overflow)'
```

## Lightweight Lab

Simulate priority failover with two upstream containers and an Envoy config that sets one as P0 and one as P1. Stop the P0 upstream and observe Envoy automatically shift all traffic to P1.

```bash
docker run --rm -d --name upA -p 18081:80 hashicorp/http-echo -text="primary"
docker run --rm -d --name upB -p 18082:80 hashicorp/http-echo -text="failover"
docker run --rm -d --name envoy -p 10000:10000 -p 9901:9901 \
  -v $PWD/lab/envoy-priority.yaml:/etc/envoy/envoy.yaml \
  envoyproxy/envoy:v1.30-latest
curl http://localhost:10000/
docker stop upA
curl http://localhost:10000/
```

## What to commit
- Add a knob→primitive→failure-mode table mapping platform-level traffic features (canary, zone-aware routing, failover) to the specific Envoy config fields that implement them (`overprovisioning_factor`, `max_ejection_percent`, `max_pending_requests`) and the admin stats that indicate each failure mode (`lb_healthy_panic`, `upstream_rq_pending_overflow`, `ejections_active`).
