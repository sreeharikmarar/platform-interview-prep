# Talk Tracks

## Q: Explain this in one minute.

**Answer:**

Envoy's traffic management is a two-layer system. The control plane — Istio Pilot in practice — computes a desired distribution and pushes it to Envoy as a ClusterLoadAssignment (EDS) resource, encoding each endpoint with a `priority`, a `locality` (region/zone/subzone), and a `load_balancing_weight`. The data plane then executes that intent in real time using three interacting mechanisms: priority-based failover, locality-weighted load balancing, and outlier detection as a feedback loop.

Priority failover works on health percentage: Envoy always tries to keep 100% of traffic on the lowest-numbered priority (P0). If the fraction of healthy endpoints in P0 drops below a threshold — governed by `overprovisioning_factor`, which defaults to 1.4 — traffic spills into P1, then P2, proportional to how much capacity P0 is missing. Outlier detection is what marks endpoints unhealthy in the first place: it watches for consecutive 5xx responses, latency outliers, or TCP connect failures, and ejects offending hosts for a base ejection interval that grows with each repeated ejection.

This matters most in multi-cluster failover. In a well-configured setup, a regional failure triggers outlier ejections across all P0 endpoints, the health percentage drops below the spillover threshold, and traffic automatically shifts to P1 without a human touching anything. The entire mechanism is stateless per-request and sub-millisecond; the slow part is control-plane propagation, not the LB decision itself.

---

## Q: Walk me through the internals.

**Answer:**

A request arrives at Envoy's listener and is matched to a route, which resolves to a named cluster — say, `outbound|8080||checkout.prod.svc.cluster.local`. Envoy looks up that cluster's endpoint set, which is structured as a priority-ordered list of `LocalityLbEndpoints` entries. Each entry carries a `locality` struct (`region`, `zone`, `sub_zone`), a `priority` integer, a `load_balancing_weight`, and a list of `LbEndpoint` objects, each with an `HealthStatus` field and an address.

Step one is priority selection. Envoy computes the effective health percentage for P0 — `(healthy_endpoints / total_endpoints) * overprovisioning_factor`. If that product is >= 100, all traffic stays in P0. If it is 80 (for example), 80% of traffic goes to P0 and 20% spills to P1. The `overprovisioning_factor` of 1.4 means P0 must be below ~71% healthy before any spillover occurs, giving you a buffer against transient flaps.

Step two is locality weighting within the selected priority. If Envoy's own zone matches a `locality.zone` in the endpoint set, it preferentially routes there, weighted by `load_balancing_weight`. This is zone-aware routing: Envoy in `us-east-1a` will prefer endpoints labeled `us-east-1a` over `us-east-1b`, reducing cross-AZ traffic cost and latency.

Step three is endpoint selection within the chosen locality, using the configured `lb_policy` on the cluster — round-robin, least-request, or ring-hash. At this point, `HealthStatus` is consulted: endpoints marked `UNHEALTHY` or `DRAINING` are excluded. Active health check results (if configured via the `health_checks` block) and outlier detection ejections both set this status.

The outlier detection feedback loop closes the circle: after a request completes, Envoy inspects the response code and latency. If an endpoint accumulates `consecutive_5xx` errors beyond `consecutive_5xx` threshold (default 5), it is ejected and its `HealthStatus` flips to `UNHEALTHY`. This reduces the healthy-endpoint count, which feeds back into the priority-health-percentage calculation in step one, potentially triggering spillover to P1. The entire round-trip from failure to spillover can happen within a single-digit number of requests — typically faster than the control plane's next EDS push.

---

## Q: What can go wrong?

**Answer:**

**Failure 1: Outlier thrashing from noisy upstream health.**
If an upstream has intermittent errors — a flaky database connection that fails 10% of requests rather than failing consistently — outlier detection ejects the endpoint, the base ejection interval expires, the endpoint is returned to the pool, and the cycle repeats. Each ejection increments `cluster.<name>.outlier_detection.ejections_detected_consecutive_5xx` and `cluster.<name>.outlier_detection.ejections_total`. You'll see those counters ticking rapidly and `cluster.<name>.membership_healthy` oscillating. The blast radius is elevated error rate and unpredictable latency as requests are constantly redistributed. Mitigation is to tune `base_ejection_time` upward, increase `consecutive_5xx` threshold, or fix the upstream — thrashing is almost always a symptom of a real upstream problem being masked rather than resolved.

**Failure 2: Panic threshold masking a real brownout.**
When the fraction of healthy endpoints falls below the `panic_threshold` (default 50%), Envoy enters panic mode and routes to all endpoints regardless of health status. This is a deliberate availability-over-correctness tradeoff, but it means a cluster in brownout — where 60% of endpoints are returning 5xx — stops doing outlier ejections and sends traffic indiscriminately. The detection signal is `cluster.<name>.lb_healthy_panic` counter incrementing; if you see that rising alongside high error rates, you have a brownout being masked rather than recovered. Mitigation is lowering `panic_threshold` for critical services or pre-scaling to keep the healthy fraction above 50% even during partial failures.

**Failure 3: Circuit breaker overflow during traffic spikes.**
When a spike hits and the upstream is slow, Envoy's connection pool fills up. Requests that cannot acquire a connection within the pool limits are shed immediately with a 503 and the response flag `UO` (upstream overflow). The metric is `cluster.<name>.upstream_rq_pending_overflow`. This is distinct from a timeout or 5xx from upstream — the request never left Envoy. The failure mode is that circuit breaker limits (`max_pending_requests`, `max_connections`, `max_requests`) were sized for steady-state, not for the spike load, and the service sheds load without any upstream ever being at fault. Mitigation requires tuning thresholds based on actual P99 concurrency, not guessing, and using `upstream_rq_pending_active` as a leading indicator before overflow starts.

---

## Q: How would you debug it?

**Answer:**

Start at the Envoy admin endpoint. The `/clusters` page (`curl localhost:9901/clusters`) dumps the full state of every cluster: priority assignment, zone, endpoint addresses, health flags (`healthy`, `failed_active_hc`, `failed_outlier_check`, `failed_eds_health`), and current weight. This is the authoritative view of what Envoy thinks is healthy right now, independent of what the control plane intended to send.

Next, check outlier detection ejection stats. The counters `cluster.<name>.outlier_detection.ejections_detected_consecutive_5xx`, `ejections_detected_success_rate`, and `ejections_enforced_total` tell you whether ejections are happening, what type, and whether they are being enforced (enforcement can be disabled with `enforcing_consecutive_5xx: 0` for passive monitoring without actual ejection). If ejections are happening but errors persist, check `cluster.<name>.membership_healthy` — a low value here is the direct signal that priority spillover is imminent or already active.

For spillover confirmation, look at `cluster.<name>.lb_healthy_panic` (panic mode active), `cluster.<name>.upstream_cx_overflow` (connection pool exhausted), and `cluster.<name>.upstream_rq_pending_overflow` (request shed before sending). Cross-reference with the upstream cluster's `cluster.<name>.upstream_rq_5xx` and `upstream_rq_timeout` to separate Envoy-side shedding from upstream-side errors.

If the numbers look wrong relative to what Pilot should have configured, check xDS propagation. `pilot_xds_push_errors` and `pilot_eds_no_instances` on the Istiod side, and `envoy_control_plane_connected_state` on the proxy side, tell you whether the EDS update was pushed and received. A healthy cluster that looks sick in Envoy admin almost always means a stale EDS payload — verify with `istioctl proxy-config endpoints <pod> --cluster <cluster-name>` to see what endpoints Envoy currently holds.

---

## Q: How would you apply this in a platform engineering context?

**Answer:**

The primary control surface as a platform engineer is the Istio `DestinationRule` `trafficPolicy` block. The `outlierDetection` stanza maps directly to Envoy's outlier detection config: `consecutiveErrors`, `interval`, `baseEjectionTime`, `maxEjectionPercent`. The `connectionPool` stanza sets circuit breaker thresholds: `http.http1MaxPendingRequests`, `http.maxRequestsPerConnection`, `tcp.maxConnections`. And `loadBalancer.localityLbSetting` exposes priority and weight overrides — `distribute` for weighted shifting across zones, `failover` for explicit ordered priority assignment between regions. Platform teams should treat these as SLO knobs, not one-time configs: the right values for a payment service differ from a cache warmer.

For multi-cluster failover, the pattern is: P0 = local cluster, P1 = remote cluster, Istio ServiceEntry for the remote endpoints, locality set to separate regions. When the local cluster degrades past the `overprovisioning_factor` threshold, Envoy spills to P1 without a human operator involved. The critical operational concern is ensuring the failover cluster is pre-warmed — cold starts under sudden load are a common cause of cascading failure during failover events.

For canary deployments, locality weighting is less useful than Istio `VirtualService` weighted routing between subsets defined in `DestinationRule`. A 5%/95% canary split should use `VirtualService` `weight` fields, not `localityLbSetting`, because subset-based routing is explicitly tied to pod label selectors and is far more predictable. Locality weighting is for geographic distribution, not version distribution.

For platform SLO enforcement, circuit breakers are the mechanism. A service that has a 99.9% availability SLO should have `connectionPool` thresholds set such that it sheds load gracefully before the upstream exhausts resources and enters total failure. A useful heuristic: set `http1MaxPendingRequests` to the service's expected P99 concurrency at 2x normal load, monitor `upstream_rq_pending_overflow` in Prometheus with an alert threshold above zero, and treat any circuit breaker trips as a signal that either the threshold is wrong or the upstream needs capacity — never silently raise the limit without investigating why it was hit.
