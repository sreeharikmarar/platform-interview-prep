# Backpressure, Rate Limiting & Overload Protection

## What you should be able to do

- Explain how a retry storm propagates through a call graph and calculate the amplification factor from individual retry budgets.
- Configure Envoy circuit breakers (per-cluster thresholds, overflow stats) and explain the difference between circuit breaking and outlier detection.
- Describe the three layers of overload defense — admission control at the edge, circuit breakers between services, and retry budgets within clients — and map each to a concrete Kubernetes or Envoy mechanism.
- Diagnose a metastable failure and explain why the system cannot self-recover without external intervention.
- Explain timeout hierarchy in Envoy and why mismatched timeouts cause resource leaks.

## Mental Model

Every system is a pipe with a finite drain rate. Requests flow in one end, processing consumes capacity, and responses flow out the other. The pipe's cross-sectional area is determined by CPU, memory, thread pool size, connection pool limits, and downstream service latency. When inflow exceeds drain rate even briefly, the queue in front of the pipe grows. Latency is queue depth divided by drain rate (Little's Law). A queue that grows without bound is a system that is failing in slow motion.

The first instinct when a system slows is to retry. This is correct when the failure is transient and isolated — a single pod restart, a momentary GC pause. But retries are catastrophically wrong when the cause of slowness is insufficient capacity, because each retry is additional inflow to an already overwhelmed pipe. If service A is slow because service B is overloaded, and A retries every timed-out request twice, A is now sending three times the original load to B. If B also retries upstream to C, the amplification compounds: three times from A times three times from B equals nine times the original load on C. This is a retry storm, and it is one of the most common causes of complete outage in otherwise well-designed distributed systems.

What makes retry storms especially dangerous is that they are self-reinforcing. Higher load means higher latency means more timeouts means more retries means higher load. The system cannot self-recover from this loop because the pressure is entirely internal — there is no reduction in external load, only amplification of it. This is the definition of a metastable failure: a state that is stable under normal operating conditions, but once perturbed past a threshold by an external event (a flash crowd, a deployment, a dependent service restart), the system's own coping mechanisms amplify the perturbation until the system collapses. The pernicious property of metastable failures is that the triggering event is long gone by the time the collapse is visible, making root cause analysis difficult.

The three-layer defense against overload works at different points in the blast radius propagation. The first layer is admission control at the edge: rate limiting, request prioritization, and load shedding before requests enter the system. If you can reduce inflow to match drain rate, the queue stabilizes. This is the most efficient defense because it stops the problem before it consumes any resources. The second layer is circuit breakers between services: when a dependency is degraded, stop sending requests to it and return fast failures instead of queuing indefinitely. Fast failures are cheaper than slow failures because they release the caller's resources (threads, connections, file descriptors) immediately. The third layer is retry budgets within clients: limiting the fraction of total requests that may be retries, so that retry amplification is bounded by design rather than by accident.

The most dangerous failure class is not hard failure — a service that is completely dead returns errors quickly, circuit breakers trip, and the blast radius is bounded. The most dangerous class is gray failure: a service that is degraded but not dead, responding slowly enough to consume caller resources but fast enough to evade simple health checks. A service at 500ms response time when normal is 10ms will exhaust caller thread pools long before its error rate triggers an alert. Gray failures require latency-sensitive health checking, not just error-rate monitoring. Outlier detection in Envoy addresses this by tracking per-endpoint success rate and response time, not just whether the connection can be established.

## Key Concepts

- **Retry budget**: A policy that limits retries to a fixed percentage of total request volume rather than a fixed count per request. For example, a 10% retry budget on a service handling 10,000 RPS allows at most 1,000 retries per second in aggregate, regardless of how many individual requests are failing. Envoy implements this with `retry_budget` on the cluster's `circuit_breakers` block: `budget_percent` sets the percentage and `min_retry_concurrency` sets a floor so low-volume services still get some retry headroom. This is distinct from `num_retries` in a route's `retry_policy`, which is a per-request cap (max retries on a single request). Both limits apply independently: a request respects its `num_retries` cap, but the cluster's `max_retries` circuit breaker threshold stops all retries if the number of in-flight retries exceeds the budget. The budget prevents the amplification math from becoming unbounded.

- **Circuit breaker (Envoy)**: A set of thresholds on an Envoy Cluster that limits the volume of outstanding work sent to that cluster's endpoints. The four thresholds are: `max_connections` (total number of TCP connections Envoy will open to all endpoints in the cluster; new connection attempts beyond this are rejected with overflow), `max_pending_requests` (HTTP/1.1 requests waiting for a connection because the pool is saturated; excess requests receive a 503 immediately rather than queuing), `max_requests` (total in-flight HTTP/2 requests on all connections; excess requests receive a 503), and `max_retries` (number of in-flight retries across all connections; new retry attempts are rejected when this is reached). Each threshold has a corresponding overflow counter in Envoy stats: `cluster.<name>.upstream_cx_overflow`, `cluster.<name>.upstream_rq_pending_overflow`, `cluster.<name>.upstream_rq_overflow`, and `cluster.<name>.upstream_rq_retry_overflow`. These counters are the first thing to check when diagnosing unexpected 503s from a healthy backend. Circuit breakers in Envoy are not stateful in the Hystrix sense (they do not have OPEN/HALF-OPEN/CLOSED states); they are instantaneous rate caps. This is a fundamental design difference: Envoy circuit breakers prevent overload in the present, while Hystrix-style breakers detect past failure and temporarily block the circuit.

- **Outlier detection (distinction from circuit breaking)**: Outlier detection is Envoy's passive health checking mechanism. It tracks per-endpoint error rates and latency over a rolling time window. Endpoints that exceed thresholds (e.g., `consecutive_5xx: 5` gateway errors, or `consecutive_local_origin_failure: 3` connection failures) are ejected from the load balancing pool for an `base_ejection_time` duration (doubling on each subsequent ejection up to `max_ejection_time`). `max_ejection_percent` caps the fraction of endpoints that can be simultaneously ejected, preventing outlier detection from taking down the entire cluster on a correlated failure. Circuit breakers operate at the cluster level and are about limiting total outstanding work. Outlier detection operates at the endpoint level and is about routing around individual bad pods. Both mechanisms can trigger 503s, but for different reasons: overflow counters mean the cluster is overloaded; outlier ejection means individual endpoints are unhealthy.

- **Load shedding**: The deliberate rejection of requests to protect service stability, returning a failure response immediately rather than queuing indefinitely. There are two meaningful status codes: HTTP 503 (Service Unavailable) means the server is overloaded and cannot process the request at all — the client should not retry or should retry with significant jitter and backoff. HTTP 429 (Too Many Requests) means the client has exceeded a rate limit — the client should back off and retry after the interval indicated by the `Retry-After` response header. The distinction matters for client behavior: 503 typically warrants exponential backoff with high jitter; 429 warrants waiting until the rate limit window resets. Returning 503 quickly is almost always better than queuing: a queued request consumes memory, holds a connection, and typically times out on the client side anyway, resulting in a 503 after waiting. Envoy's local rate limiter returns 429 with configurable response headers. Envoy's circuit breaker overflow returns 503.

- **Fairness and priority (weighted fair queuing, tenant-aware rate limiting)**: Without fairness, a single tenant sending high volume can exhaust shared connection pools and degrade all other tenants — the noisy neighbor problem. Weighted fair queuing allocates capacity in proportion to assigned weights, so a tenant with weight 2 gets twice the capacity of a tenant with weight 1, and neither can starve the other entirely. Tenant-aware rate limiting tracks quotas per tenant identifier (typically a JWT claim or API key) rather than per source IP. Envoy's global rate limit service (accessed via `envoy.filters.http.ratelimit` filter) supports descriptors that compose multiple attributes (remote address, header value, authenticated user) into a hierarchical rate limit key. A common pattern is: global rate of 100,000 RPS for all traffic, per-tenant rate of 10,000 RPS per authenticated user, per-route rate of 1,000 RPS for expensive endpoints. All three limits apply simultaneously; the most restrictive binding wins.

- **Jitter and exponential backoff**: Exponential backoff increases the wait time between retries to reduce pressure on an overloaded system. Without jitter, all clients that failed at the same moment will retry at the same moment (the "synchronized retry" problem), causing a thundering herd. The decorrelated jitter formula (from Marc Brooker's research) produces the lowest client-observable latency while avoiding synchronization: `sleep = min(cap, random_between(base, previous_sleep * 3))`. This differs from full jitter (`sleep = random_between(0, min(cap, base * 2^attempt))`), which has lower mean wait but higher variance, and equal jitter (`sleep = min(cap, base * 2^attempt) / 2 + random_between(0, min(cap, base * 2^attempt) / 2)`), which bounds variance at the cost of higher mean. In practice, decorrelated jitter is preferred for client libraries retrying against services; full jitter is acceptable for background jobs where latency matters less than throughput.

- **Timeout hierarchy**: Envoy has four timeout scopes that nest inside each other. Connection timeout (`connect_timeout` on the Cluster) is how long Envoy will wait to establish a TCP connection to an upstream endpoint — typically 250ms to 1s. Request timeout (`timeout` on the Route) is the total time from when Envoy sends the request to when the response must be complete — this is the budget for the entire upstream processing including network transfer. The idle timeout (`idle_timeout` on the HCM) is how long a connection can be idle before Envoy closes it, preventing connection pool staleness. The stream idle timeout (`stream_idle_timeout` on the HCM) is how long an individual HTTP/2 stream can go without any data transfer. Mismatched timeouts cause resource leaks: if the client's timeout is shorter than Envoy's route timeout, the client gives up and moves on, but Envoy continues holding the upstream connection and waiting for a response that nobody will read. This wastes connection pool slots and can cause `max_requests` thresholds to be hit by abandoned in-flight requests. The rule is: client timeout must be longer than Envoy's route timeout, which must be longer than the upstream's own processing deadline.

- **Metastable failure**: A system state in which normal operating conditions are stable, but a perturbation (a traffic spike, a deployment rollout, a dependent service restart) drives the system into a positive feedback loop that prevents self-recovery. The canonical example: service A is healthy at 1,000 RPS. A GC pause on one pod causes latency to spike. Clients time out and retry. Retries increase load by 50%. The extra load causes more GC pressure. More GC means more latency spikes. More latency means more timeouts means more retries. The system cannot shed the excess load because the retries are internally generated. The triggering event (the GC pause) has resolved, but the system is now stuck at an elevated load level that it cannot process. External intervention is required: traffic must be shed or clients must be forced to back off. The protection against metastable failures is: retry budgets (bound amplification), circuit breakers (stop adding work to an overloaded service), and load shedding with non-retryable status codes (break the retry loop).

- **Kubernetes API Priority and Fairness (APF)**: The Kubernetes API server's own rate limiting mechanism, introduced to replace the simpler `--max-requests-inflight` flag. APF assigns every API request to a PriorityLevelConfiguration (e.g., `leader-election`, `workload-high`, `workload-low`, `global-default`) and a FlowSchema that matches requests by user, group, verb, resource, and namespace. Each priority level gets a configurable number of concurrency shares and a queue depth. Requests that exceed the concurrency limit are queued (up to the configured depth), then shed with 429. APF prevents a single controller from flooding the API server and starving kubelet or etcd heartbeat requests. The `flowcontrol.apiserver.k8s.io` API group manages these objects. Operators should create custom PriorityLevelConfigurations for their controllers to avoid sharing the `global-default` pool.

- **ResourceQuota and LimitRange as admission control**: ResourceQuota enforces aggregate resource caps per namespace — total CPU, memory, and object count. When a new Pod or PVC would exceed the quota, the admission webhook rejects it with 403, preventing the namespace from consuming disproportionate cluster resources. LimitRange sets default requests and limits for containers that do not specify them, and enforces minimum and maximum bounds. Together they implement admission control at the Kubernetes scheduler level: the cluster can only admit as much work as it has capacity to run. PodDisruptionBudgets (PDBs) are the complement for drain rate: they limit how many pods of a deployment can be simultaneously unavailable during voluntary disruptions (node drains, rolling updates), which is equivalent to rate-limiting the pace of work removal from the pool.

## Internals

### Envoy Circuit Breaker Internals

Envoy circuit breakers are implemented as atomic counters maintained per-cluster per-thread, aggregated across threads for threshold comparison. The implementation in `source/common/upstream/cluster_manager_impl.cc` (and the `CircuitBreakerImpl` class) tracks four counters for each `RoutingPriority` level (DEFAULT and HIGH). The DEFAULT priority handles ordinary traffic; HIGH priority is reserved for requests marked with `x-envoy-upstream-rq-timeout-ms` header or routed via `retry_priority`. This separation ensures that health check and retry traffic (HIGH priority) does not consume the same budget as normal traffic.

The four thresholds and their overflow counters:

`max_connections` tracks the total number of active TCP connections Envoy has open to the cluster's endpoints. When a new connection is needed (because there is no idle connection in the pool) and the current count is at `max_connections`, Envoy does not open a new connection. Instead, the pending request is placed in the pending queue (governed by `max_pending_requests`). The stat `cluster.<name>.upstream_cx_overflow` increments each time a connection attempt is rejected by this check.

`max_pending_requests` tracks the number of HTTP/1.1 requests waiting for an available connection. HTTP/1.1 connections are not multiplexed, so each request needs an exclusive connection. If all connections are busy and the pending count is at `max_pending_requests`, the new request is immediately rejected with 503 and `cluster.<name>.upstream_rq_pending_overflow` increments. This is the most commonly triggered overflow in HTTP/1.1 environments under load.

`max_requests` tracks total in-flight HTTP/2 requests across all connections. HTTP/2 is multiplexed, so a single connection can carry many concurrent streams. `max_requests` caps the aggregate stream count. When a new request would exceed this, it is immediately rejected with 503 and `cluster.<name>.upstream_rq_overflow` increments.

`max_retries` tracks the number of in-flight retry attempts across all connections. This is the circuit breaker that prevents retry storms at the cluster level. When the in-flight retry count reaches `max_retries`, new retry attempts are rejected (the request fails instead of being retried) and `cluster.<name>.upstream_rq_retry_overflow` increments. This counter is the most important signal for detecting a retry storm in progress. Note that the retry budget (`retry_budget` block) and `max_retries` work together: `retry_budget.budget_percent` dynamically computes the budget as a percentage of current `max_requests` usage, making it adaptive to traffic volume.

The interaction between circuit breakers and outlier detection is additive: both can independently remove capacity from the effective pool. Outlier detection ejects individual endpoints; circuit breakers cap aggregate work to the surviving endpoints. A cluster with 10 endpoints where outlier detection has ejected 3 is now a 7-endpoint cluster from the load balancer's perspective, and the circuit breaker thresholds apply to the remaining 7. If the 7 surviving endpoints cannot handle the load within the threshold limits, the overflow counters increment. This is the correct behavior — the circuit breaker protects the remaining healthy endpoints from being crushed while the cluster is partially degraded.

To inspect the current circuit breaker state at runtime:

```bash
# Current in-flight counts and thresholds (key: cx_open, rq_open, rq_pending_open)
curl -s http://localhost:9901/stats | grep 'circuit_breakers\|upstream_cx_overflow\|upstream_rq_overflow\|upstream_rq_pending_overflow\|upstream_rq_retry_overflow'

# Per-cluster detail including current connection counts
curl -s http://localhost:9901/clusters | grep -A 20 "cluster_name::"

# Full circuit breaker config as delivered by CDS
curl -s http://localhost:9901/config_dump | \
  jq '.configs[] | select(.["@type"] | contains("ClustersConfigDump")) | .dynamic_active_clusters[] | {name: .cluster.name, cb: .cluster.circuit_breakers}'
```

### Rate Limiting Architecture

Envoy supports two fundamentally different rate limiting mechanisms that complement each other. Local rate limiting (`envoy.filters.http.local_ratelimit`) runs entirely within the Envoy process, using a per-listener or per-cluster token bucket. No external call is made. This makes it extremely fast and available even when the external rate limit service is down. The token bucket parameters are `max_tokens` (bucket capacity), `tokens_per_fill` (refill amount), and `fill_interval` (refill period). Local rate limiting is enforced per Envoy instance, not globally across the fleet — if you have 10 Envoy pods and set `max_tokens: 100`, the effective global limit is 1,000 RPS (100 per instance times 10 instances). This is acceptable for coarse-grained protection but not for per-tenant quota enforcement.

Global rate limiting (`envoy.filters.http.ratelimit`) calls an external gRPC rate limit service (implementing the `envoy.service.ratelimit.v3.RateLimitService` proto) on every request (or on a configured percentage of requests). The filter constructs a `RateLimitRequest` containing a list of descriptors. Each descriptor is a list of key-value pairs derived from request attributes (remote address, authority, path, headers, authenticated principal). The rate limit service evaluates each descriptor against its configured limits and returns `OK` or `OVER_LIMIT` for each. If any descriptor is `OVER_LIMIT`, Envoy returns 429. The external service maintains global counters in a shared store (typically Redis) so all Envoy instances share the same quota pool.

The descriptor hierarchy enables a multi-tenant rate limiting policy. A typical configuration:

```yaml
# Envoy HTTP filter config for the global rate limit filter
http_filters:
- name: envoy.filters.http.ratelimit
  typed_config:
    "@type": type.googleapis.com/envoy.extensions.filters.http.ratelimit.v3.RateLimit
    domain: my_api          # logical grouping in the rate limit service
    failure_mode_deny: false # fail-open: allow requests if rate limit service is unreachable
    rate_limit_service:
      grpc_service:
        envoy_grpc:
          cluster_name: rate_limit_cluster
      transport_api_version: V3
    # Per-route rate limit actions are defined on the route itself:
    # rate_limits:
    # - actions:
    #   - remote_address: {}
    #   - request_headers:
    #       header_name: "x-tenant-id"
    #       descriptor_key: "tenant"
```

`failure_mode_deny: false` (fail-open) means that if the rate limit service is unavailable, requests are allowed through. `failure_mode_deny: true` (fail-closed) means requests are rejected with 500 if the service is unreachable. Fail-open is the standard choice for a rate limiter: an unavailable rate limiter should not take down the API. Fail-closed is appropriate only for security-critical rate limits where the cost of allowing excess requests exceeds the cost of dropping legitimate ones.

The local rate limiter should always be deployed alongside the global rate limiter as a backstop. If the global service is slow, the local limiter provides a coarser but immediate line of defense.

### Retry Storm Propagation

A retry storm is an amplification cascade where each layer's retry policy multiplies the load seen by downstream layers. Consider a three-service call graph with each service configured for 3 retries on 5xx (a common default):

```
  External Client
       │
       │  1 original request
       ▼
  +----------+
  | Service A |  route retry_policy: num_retries: 3
  +----------+
       │
       │  up to 4 attempts (1 original + 3 retries) per client request
       ▼
  +----------+
  | Service B |  route retry_policy: num_retries: 3
  +----------+
       │
       │  up to 4 attempts per A→B attempt
       │  = up to 4 x 4 = 16 B→C requests per original client request
       ▼
  +----------+
  | Service C |  (the overloaded dependency)
  +----------+

  Amplification factor = (1 + retries_A) x (1 + retries_B) = 4 x 4 = 16x
  At 1,000 RPS external load: Service C sees up to 16,000 RPS
```

The amplification factor grows exponentially with the depth of the call graph and the retry count at each layer. With 5 services each retrying 3 times: 4^4 = 256x amplification. This means a transient 1% error rate at the deepest layer, triggering retries, can produce 256x the original load on that layer within a single timeout window.

The mitigation is not to eliminate retries but to bound their aggregate count. With a 10% retry budget at each layer, the maximum retry amplification is capped:

```
  Service A: max 10% of RPS as retries = 1.1x multiplier to B at most
  Service B: max 10% of RPS as retries = 1.1x multiplier to C at most
  Total amplification: 1.1 x 1.1 = 1.21x (versus 16x without budget)
```

Retry budgets absorb transient failures without amplifying them into storms, while `max_retries` circuit breakers provide a hard stop when the budget is exceeded.

### Kubernetes-Level Overload Protection

Kubernetes itself has a multi-layer overload protection stack that mirrors the Envoy-level concepts.

The API server implements API Priority and Fairness (APF) as its own admission control and rate limiting. The `FlowSchema` objects match incoming API requests to priority buckets using a rule system similar to RBAC: match by user, group, serviceAccount, verb, resource, namespace, and name. Matched requests are counted against a `PriorityLevelConfiguration` that sets `nominalConcurrencyShares` (relative weight) and queue depth. The API server sheds load by returning 429 with `Retry-After` headers when a priority level's queue is full. The `flowcontrol.apiserver.k8s.io/v1` API group manages these objects. Monitor `apiserver_flowcontrol_rejected_requests_total` labeled by `priority_level` and `reason` (queue-full vs timeout).

ResourceQuota acts as admission control at the namespace boundary. The admission webhook checks whether a new object creation would exceed the namespace's quota before allowing it. This is stateful admission control: the quota is tracked across all resources in the namespace, not just per-request. When an operator creates many resources rapidly (e.g., a templating loop creating hundreds of ConfigMaps), ResourceQuota prevents namespace exhaustion and isolates the impact.

PodDisruptionBudgets (PDBs) rate-limit the drain side of the capacity equation. When the cluster autoscaler drains a node or a rolling deployment updates pods, PDBs enforce that at most `maxUnavailable` (or at least `minAvailable`) pods are simultaneously unavailable. Without PDBs, a rolling deployment could take down enough replicas that the remaining pods are overloaded — the deployment itself causes the overload event. PDBs are the Kubernetes analog of a circuit breaker on the deployment process.

HorizontalPodAutoscaler (HPA) with `scaleUp` stabilization window is the Kubernetes analog of capacity-based admission control. The stabilization window prevents HPA from scaling up immediately in response to a brief spike (which could be a retry storm) and then scaling back down, causing oscillation. During a genuine sustained load increase, HPA adds capacity, which increases the drain rate and eventually stabilizes the queue. During a retry storm, HPA might scale up toward the amplified load — this is why circuit breakers and retry budgets must be applied before autoscaling can help: you need to bound the inflow before adding capacity helps.

### Queue Theory and Utilization

Little's Law states that in a stable system, the average number of items in the system (L) equals the arrival rate (lambda) times the average time an item spends in the system (W): `L = λ × W`. Rearranging: `W = L / λ`. This has two critical implications for service latency under load.

First, queue depth predicts latency. If a service has 100 requests in queue and processes 50 per second, average wait time is 2 seconds — before a single line of application code runs. Observing queue depth (e.g., `cluster.<name>.upstream_rq_pending_active`) gives you an early warning of latency degradation before timeout rates rise.

Second, and more counterintuitively, utilization has a non-linear effect on latency. The Erlang-C formula (and M/M/1 queue model as an approximation) shows that at low utilization (under 50%), queue length is negligible and latency is close to service time. As utilization approaches 80%, queue length begins growing noticeably. Above 80% utilization, queue length grows rapidly and latency becomes highly variable. Above 90% utilization, queue length is theoretically unbounded for bursty traffic. This is why the conventional wisdom of "run at 70-80% CPU" is not arbitrary — it preserves enough headroom for burst absorption without non-linear latency degradation.

The practical implication for platform engineering: horizontal scaling targets and HPA thresholds should maintain utilization below 70-75%, not the absolute maximum. Targeting 90% CPU utilization creates a system that operates acceptably at steady state but collapses under any perturbation.

## Architecture Diagram

```
  INBOUND TRAFFIC
       │
       │  N RPS (with spikes, retries, background traffic)
       ▼
  ┌─────────────────────────────────────────────────────────┐
  │  LAYER 1: EDGE ADMISSION CONTROL                        │
  │                                                         │
  │  Global Rate Limit Service (Redis-backed)               │
  │  ├── per-tenant quota:   10,000 RPS per API key         │
  │  ├── per-route quota:    1,000 RPS for /expensive       │
  │  └── global quota:       100,000 RPS total              │
  │                                                         │
  │  Local Rate Limiter (per-Envoy token bucket)            │
  │  └── backstop:           5,000 RPS per pod (fail-safe)  │
  │                                                         │
  │  Result: excess requests → 429 + Retry-After header     │
  └──────────────────────────┬──────────────────────────────┘
                             │  admitted requests only
                             ▼
  ┌─────────────────────────────────────────────────────────┐
  │  LAYER 2: CIRCUIT BREAKER (per upstream Cluster)        │
  │                                                         │
  │  max_connections:      1024  (cx overflow → 503)        │
  │  max_pending_requests:  512  (rq_pending overflow → 503)│
  │  max_requests:         4096  (rq overflow → 503)        │
  │  max_retries:           128  (retry overflow → no retry)│
  │                                                         │
  │  Outlier Detection (per endpoint):                      │
  │  ├── consecutive_5xx: 5   → eject for 30s              │
  │  ├── consecutive_local_origin_failure: 3               │
  │  └── max_ejection_percent: 50%                         │
  │                                                         │
  │  Result: overflow → fast 503 (not queued wait)          │
  └──────────────────────────┬──────────────────────────────┘
                             │
                             ▼
  ┌─────────────────────────────────────────────────────────┐
  │  LAYER 3: RETRY BUDGET (per client route)               │
  │                                                         │
  │  retry_policy:                                          │
  │    retry_on: 5xx,reset,connect-failure                  │
  │    num_retries: 2         (per-request cap)             │
  │  retry_budget:                                          │
  │    budget_percent: 10%    (10% of max_requests)         │
  │    min_retry_concurrency: 3                             │
  │                                                         │
  │  Result: retry amplification bounded to 1.1x max        │
  └──────────────────────────┬──────────────────────────────┘
                             │
                             ▼
  ┌─────────────────────────────────────────────────────────┐
  │  LAYER 4: TIMEOUT HIERARCHY                             │
  │                                                         │
  │  connect_timeout (Cluster):     250ms                   │
  │  route timeout (Route):         10s    ← owns budget    │
  │  stream_idle_timeout (HCM):     60s                     │
  │  idle_timeout (HCM):            300s                    │
  │                                                         │
  │  Rule: client_timeout > route_timeout > upstream_slo    │
  │  Violation: resource leak (abandoned in-flight requests) │
  └──────────────────────────┬──────────────────────────────┘
                             │
                             ▼
  ┌─────────────────────────────────────────────────────────┐
  │  LAYER 5: LOAD SHEDDING (upstream service)              │
  │                                                         │
  │  Queue depth threshold:  >100 pending → shed with 503   │
  │  CPU threshold:          >85% sustained → shed          │
  │  Response code:          503 (do not retry)             │
  │                              or 429 (retry after N sec) │
  │                                                         │
  │  Result: early rejection preserves CPU for in-flight     │
  └──────────────────────────┬──────────────────────────────┘
                             │
                             ▼
  ┌─────────────────────────────────────────────────────────┐
  │  LAYER 6: GRACEFUL DEGRADATION                          │
  │                                                         │
  │  Feature flags:  disable expensive operations           │
  │  Cache serving:  return stale data with Cache-Control   │
  │  Partial results: return available data, omit slow deps │
  │  Static fallback: serve cached 200 for known paths      │
  │                                                         │
  │  Result: degraded but functional response to client     │
  └─────────────────────────────────────────────────────────┘
```

## Failure Modes & Debugging

### 1. Retry Storm Cascade (Exponential 5xx Amplification)

**Symptoms**: A brief spike in 5xx errors (perhaps triggered by a deployment or a downstream dependency restarting) causes an exponential increase in total request volume. Envoy stats show `upstream_rq_retry` and `upstream_rq_retry_overflow` counters climbing rapidly. The 5xx rate increases instead of recovering. Total inbound RPS on downstream services rises above the original client-driven load. `cluster.<name>.upstream_rq_pending_overflow` starts incrementing as connection pools saturate. Cluster latency p99 climbs from tens of milliseconds to seconds. The original triggering event (a pod restart, a transient 5xx) has resolved, but the system does not recover — error rates plateau at a high level or continue rising.

**Root Cause**: Per-request retry counts are set without a corresponding cluster-level retry budget. Each layer in the call graph independently retries failed requests up to `num_retries` times. The triggering event (e.g., a pod restart causing 2-3 seconds of 503s) causes a wave of retries. Those retries hit the now-recovered service, but the load is multiplied by the retry factor at each layer. If the multiplied load exceeds service capacity, the service starts returning 5xx again, causing another wave of retries. The system enters a positive feedback loop. The absence of `max_retries` circuit breaker thresholds or `retry_budget` means there is no upper bound on retry amplification.

**Blast Radius**: Affects the entire call graph downstream from the triggering service. If the triggering service is a shared dependency (a database proxy, an authentication service, a feature flag API), the blast radius spans all services that depend on it. Connection pools on all dependent services saturate, causing `max_pending_requests` overflow and 503s for all traffic, not just the traffic to the affected dependency. An availability incident that should have been 503s on one route for 10 seconds becomes a complete outage on all routes for several minutes.

**Mitigation**: Configure `max_retries` on the cluster's circuit breaker to a value proportional to the cluster's steady-state concurrency (a common starting point is 10-20% of `max_requests`). Add `retry_budget` with `budget_percent: 10` to all clusters. Set `retry_on` to only the error classes that are genuinely transient: `reset,connect-failure,retriable-4xx` — do not retry on `5xx` generically because 5xx from an overloaded service is not a transient error. Add `x-envoy-retry-on: reset,connect-failure` as a default and require services to explicitly opt in to 5xx retries only for idempotent read operations.

**Debugging**:
```bash
# Watch retry overflow counter in real-time (increment rate reveals storm)
watch -n 1 'curl -s http://localhost:9901/stats | grep upstream_rq_retry'

# Identify which cluster is the source of retries
curl -s http://localhost:9901/stats | grep 'upstream_rq_retry' | sort -t: -k3 -rn | head -20

# Check current in-flight retry count vs threshold (max_retries)
curl -s http://localhost:9901/stats | grep -E 'upstream_rq_retry_open|upstream_rq_retry_overflow'

# Inspect the retry policy on the route that is generating retries
curl -s http://localhost:9901/config_dump | \
  jq '.. | .retry_policy? // empty | select(. != null)'

# Check retry budget configuration on the cluster
curl -s http://localhost:9901/config_dump | \
  jq '.configs[] | select(.["@type"] | contains("ClustersConfigDump")) | .dynamic_active_clusters[] | {name: .cluster.name, retry_budget: .cluster.circuit_breakers.thresholds[].retry_budget}'

# See response flags in access logs — UO = upstream overflow, URX = retry exhausted
kubectl logs -n NAMESPACE POD_NAME -c istio-proxy | \
  awk '{print $12}' | sort | uniq -c | sort -rn | head -20

# For Istio: check pilot push rate (high push rate during storm = xDS churn amplifying)
kubectl exec -n istio-system deploy/istiod -- \
  curl -s localhost:15014/metrics | grep pilot_xds_push
```

---

### 2. Circuit Breaker Misconfiguration (Thresholds Too Tight, False Positive 503s)

**Symptoms**: A backend service that is fully healthy (low latency, low error rate, all pods passing health checks) is returning 503s to callers. The 503s are not coming from the backend — they are generated by Envoy locally. Envoy access logs show `%RESPONSE_FLAGS%` as `UO` (upstream overflow). The `cluster.<name>.upstream_cx_overflow` or `cluster.<name>.upstream_rq_pending_overflow` counters are incrementing. The backend's own metrics show no corresponding 5xx events — the requests are being rejected before they reach the backend. The circuit breaker stat `cluster.<name>.upstream_rq_active` is at or above the configured `max_requests` threshold even though the upstream is not actually at capacity.

**Root Cause**: The circuit breaker thresholds (`max_connections`, `max_pending_requests`, `max_requests`) were set based on a previous capacity estimate that is now too low for current traffic levels, or they were set to defaults without adjustment for the actual service characteristics. Envoy's default circuit breaker values (1,024 connections, 1,024 pending requests, 1,024 requests, 3 retries) are deliberately conservative. A high-concurrency HTTP/2 service may legitimately need 10,000+ concurrent requests. A service handling long-polling or streaming responses will have high `upstream_rq_active` counts that are entirely expected. Circuit breakers set too low for a streaming service will trip continuously, creating artificial 503s on a healthy backend.

**Blast Radius**: False positive circuit breaker trips affect all traffic to the cluster, not just the traffic that would have caused overload. Unlike outlier detection (which affects individual endpoints), a circuit breaker overflow affects all requests to the cluster simultaneously. A too-tight `max_connections` threshold in a north-south gateway creates 503s for all tenants even though the backend is healthy. This is often more damaging than the overload the circuit breaker was intended to prevent.

**Mitigation**: Set circuit breaker thresholds based on observed peak concurrency plus a safety margin, not on defaults. Monitor `cluster.<name>.upstream_rq_active` (current in-flight requests), `cluster.<name>.upstream_cx_active` (current connections), and `cluster.<name>.upstream_rq_pending_active` (current pending queue depth) under normal peak load. Set thresholds at 2-3x the observed peak to allow for burst headroom while still providing an upper bound. For HTTP/2 services, `max_connections` can be much lower than `max_requests` because one connection carries many streams. For HTTP/1.1 services, `max_connections` and `max_requests` are approximately equal (one request per connection). Review thresholds after each significant traffic growth milestone.

**Debugging**:
```bash
# Confirm UO (upstream overflow) is the response flag — not UH or 5xx from upstream
kubectl logs -n NAMESPACE deploy/ENVOY_DEPLOY | grep '"UO"'

# Check current active vs threshold for each circuit breaker dimension
curl -s http://localhost:9901/stats | grep -E \
  'upstream_cx_active|upstream_cx_overflow|upstream_rq_active|upstream_rq_overflow|upstream_rq_pending_active|upstream_rq_pending_overflow'

# Compare active counts to configured thresholds
curl -s http://localhost:9901/config_dump | \
  jq '.configs[] | select(.["@type"] | contains("ClustersConfigDump")) | .dynamic_active_clusters[] | select(.cluster.name == "TARGET_CLUSTER") | .cluster.circuit_breakers'

# Verify the backend is actually healthy (distinguish false positive from real overload)
# If backend metrics show no 5xx and low latency, thresholds are too tight
kubectl exec -n NAMESPACE POD_NAME -- curl -s http://localhost:METRICS_PORT/metrics | \
  grep -E 'http_server_requests_total|request_duration'

# Check upstream_rq_active trend (steady high value = streaming service, needs higher max_requests)
# Check upstream_cx_active (near max_connections = need to raise limit or add HTTP/2)
curl -s http://localhost:9901/stats | grep "cluster.TARGET_CLUSTER.upstream"

# Temporarily observe what the natural peak is before adjusting
# (do not adjust thresholds during an active incident without understanding the cause)
curl -s http://localhost:9901/stats | grep 'upstream_rq_active' | awk -F'[:.]' '{print $NF}'
```

---

### 3. Thundering Herd After Outage Recovery

**Symptoms**: A downstream service recovers from an outage (pods are healthy, readiness probes passing). Within seconds, the service experiences another wave of high load and begins returning 5xx errors again. Upstream callers report a brief healthy window followed by immediate re-degradation. Envoy stats show a sudden spike in `upstream_rq_total` immediately after endpoint health is restored. CPU and memory on the recovering service spike before gradually returning to normal. The pattern repeats in waves — the service partially recovers, gets crushed, partially recovers, gets crushed.

**Root Cause**: During the outage, all upstream callers have been queuing failed requests or accumulating retried requests. When the service comes back online and Envoy's outlier detection or active health checks clear the ejected endpoints, all queued work is immediately dispatched simultaneously. Additionally, all callers whose retry timers fire at approximately the same moment (because they all started retrying at the same time when the outage began) produce synchronized bursts. Without jitter in the retry backoff, the synchronized retry waves recur periodically at intervals equal to the retry timeout, crushing the newly recovered service repeatedly.

The Kubernetes-level mechanism amplifying this: when a pod restarts after an OOMKill or CrashLoopBackoff, it may become Ready before its JVM (or runtime) is fully warmed up. A Java service with a cold JIT and cold caches handles much lower RPS than a warmed service, so even normal load can overwhelm it during the warm-up window, causing it to fail its readiness probe again and restart, resetting the cycle.

**Blast Radius**: The recovering service, which may be critical infrastructure (an auth service, a configuration service, a database proxy). Each restart cycle adds latency to the recovery timeline. Without intervention, the service may never successfully recover from the outage because each recovery attempt is immediately overwhelmed by the backlog.

**Mitigation**: Four complementary strategies. First, use decorrelated jitter in retry backoff so retries are distributed over time rather than synchronized. Second, configure Envoy's slow start mode (`slow_start_config` on the cluster's load balancing policy) to ramp up the fraction of traffic sent to a newly healthy endpoint over a configurable window (e.g., 30 seconds), rather than sending full traffic immediately. Third, add a startup probe in Kubernetes that validates application warmup (not just TCP liveness) before the readiness probe allows traffic. Fourth, configure `panic_threshold` to be lower than 50% on critical services, or use weighted endpoint routing to gradually shift traffic to recovered endpoints rather than switching all at once.

```yaml
# Slow start config on the Envoy cluster (ramp new endpoints over 60s)
load_assignment:
  cluster_name: my-service
  endpoints:
  - lb_endpoints: []  # populated by EDS
lb_policy: LEAST_REQUEST
least_request_lb_config:
  slow_start_config:
    slow_start_window: 60s          # ramp window duration
    aggression: 1.0                 # linear ramp (higher = more aggressive ramp-up)
```

**Debugging**:
```bash
# Watch endpoint health transitions in real-time
watch -n 2 'curl -s http://localhost:9901/clusters | grep -E "HEALTHY|UNHEALTHY|EJECTED"'

# Check outlier detection eject/uneject events
curl -s http://localhost:9901/stats | grep 'ejections'

# Identify if slow start is configured on the cluster
curl -s http://localhost:9901/config_dump | \
  jq '.. | .slow_start_config? // empty'

# Check endpoint weight during slow start (weight ramps from 0 to normal)
curl -s http://localhost:9901/clusters | grep -A 3 "weight"

# Look for synchronized retry waves in access log timestamps (burst pattern)
kubectl logs -n NAMESPACE deploy/UPSTREAM_SVC --since=10m | \
  awk '{print $1}' | cut -dT -f2 | cut -d. -f1 | sort | uniq -c | sort -rn | head -20

# Check Kubernetes pod restart history to identify the oscillation pattern
kubectl get events -n NAMESPACE --field-selector reason=BackOff | head -20
kubectl describe pod -n NAMESPACE POD_NAME | grep -A 5 'Last State'

# For JVM services: check startup probe vs readiness probe timing
kubectl describe pod -n NAMESPACE POD_NAME | grep -A 10 'Startup Probe\|Readiness Probe'
```

---

### 4. Timeout Mismatch Causing Resource Leaks

**Symptoms**: `cluster.<name>.upstream_rq_active` climbs steadily over time even though throughput (RPS) is stable. Memory on the Envoy pod grows slowly. Eventually `max_requests` circuit breaker trips and clients begin receiving 503s with `UO` response flag. Connection counts (`upstream_cx_active`) also creep up. Restarting Envoy temporarily resolves the issue, but it recurs. The upstream service reports normal request completion rates and low latency — from its perspective everything is fine.

**Root Cause**: Client-side timeout is shorter than Envoy's route timeout. Clients send a request, set a 5-second client timeout, and give up when no response arrives in 5 seconds. From the client's perspective the request failed. But Envoy's route timeout is 30 seconds, so Envoy continues holding the upstream connection and waiting for a response for 25 more seconds after the client has disconnected. During those 25 seconds, the in-flight request counts (`upstream_rq_active`) remain elevated. If traffic is steady at 1,000 RPS and each abandoned request holds resources for 25 extra seconds, there are up to 25,000 orphaned in-flight requests consuming Envoy connection pool slots. This is a resource leak: the orphaned requests are not processing useful work but they are consuming `max_requests` headroom.

A second variant: `stream_idle_timeout` is set very high (or to 0, which means unlimited) on the HCM. Long-lived HTTP/2 connections where one side has half-closed the stream but not fully terminated it keep `upstream_rq_active` elevated indefinitely. gRPC streams are particularly susceptible because a gRPC client may close its send side but keep the stream open waiting for a server-side stream response.

**Blast Radius**: Grows slowly and silently until it triggers a circuit breaker overflow event, at which point all traffic to the cluster starts receiving 503s. Because the buildup is gradual, the incident appears sudden (the circuit breaker trip) but has been developing for hours. This pattern is a delayed bomb: the system is silently degrading, and the failure appears to come from nowhere.

**Mitigation**: Enforce the timeout hierarchy: `client_timeout > route_timeout > upstream_processing_SLO`. Set `stream_idle_timeout` to a value that matches the longest expected server-streaming operation (e.g., 5 minutes for a long-running export job). Never set it to 0 (unlimited). Add a `request_timeout` at the listener level as an absolute backstop: `max_connection_duration` on the HCM or `connection_duration_timeout` on the listener ensures no single connection lives forever. Use `x-envoy-expected-rq-timeout-ms` request header to propagate the remaining budget to upstream services so they can cancel work early when the budget is exhausted.

**Debugging**:
```bash
# Watch upstream_rq_active trend — steady growth under stable RPS = resource leak
watch -n 5 'curl -s http://localhost:9901/stats | grep upstream_rq_active'

# Compare active vs total (if active >> rate x expected_latency, there is a leak)
curl -s http://localhost:9901/stats | grep -E 'upstream_rq_active|upstream_rq_total|upstream_rq_completed'

# Check the configured route timeout (is it much longer than client timeout?)
curl -s http://localhost:9901/config_dump | \
  jq '.. | .routes? // empty | .[].route.timeout'

# Check stream_idle_timeout on the HCM (0 or very large = potential leak)
curl -s http://localhost:9901/config_dump | \
  jq '.. | .stream_idle_timeout? // empty'

# Look for abandoned connections — cx_destroy_remote_with_active_rq increments when
# the client disconnects while Envoy has an active upstream request
curl -s http://localhost:9901/stats | grep 'cx_destroy_remote_with_active_rq'

# If this counter is non-zero and climbing, clients are timing out before Envoy
# The fix: reduce route timeout to be <= client timeout
curl -s http://localhost:9901/stats | grep 'cx_destroy_local_with_active_rq'

# For gRPC streams specifically, check stream duration histogram
curl -s http://localhost:9901/stats | grep 'grpc\|stream_duration'

# Istio-specific: check the DestinationRule timeout setting (overrides route default)
kubectl get destinationrule -n NAMESPACE -o yaml | grep -A 3 'timeout'
```

## Lightweight Lab

See `lab/README.md` for a hands-on exercise that walks through configuring Envoy circuit breakers, triggering overflow with parallel load, and observing the overflow counters from the admin API. The lab also demonstrates the difference between `UO` (circuit breaker overflow) and `UH` (no healthy upstream) response flags, and shows how to tune `max_requests` based on observed `upstream_rq_active` peaks.

## What to commit

- Add a narrative connecting this overload protection architecture to a specific gateway resilience improvement you shipped: what thresholds you set, what overflow counters you monitored, and what failure mode you prevented.
