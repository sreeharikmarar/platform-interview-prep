# Lab: Traffic Management Internals — Priority Failover & Outlier Detection

This lab demonstrates Envoy's priority-based load balancing and active health checking using a static bootstrap config. You will observe how Envoy routes all traffic to a P0 (primary) cluster, detects endpoint failure via active HTTP health checks, and spills over to a P1 (failover) cluster — then recovers when the primary comes back. You will read cluster state and health metrics directly from the admin API throughout, which is the same skill needed to debug Istio, Contour, or any Envoy-based proxy in production.

## Prerequisites

- Docker installed and running
- `curl` available on the host
- `jq` available (used for parsing admin API JSON output)
- Completed lab 01 (Envoy Architecture & Core Primitives) or familiarity with Envoy listeners and clusters

## Step-by-Step Instructions

### 1. Start two upstream services (primary and failover)

```bash
docker run --rm -d --name upA -p 18081:80 hashicorp/http-echo -text="primary"
docker run --rm -d --name upB -p 18082:80 hashicorp/http-echo -text="failover"
```

**What's happening**: Two instances of `http-echo` simulate distinct backend tiers. `upA` on port 18081 represents the P0 (highest priority) endpoint. `upB` on port 18082 represents the P1 (failover) endpoint. Each returns a distinct body so you can see which tier is serving traffic from `curl` output alone.

**Verification**:
```bash
curl http://localhost:18081
# Expected: primary

curl http://localhost:18082
# Expected: failover
```

Both upstreams are healthy and ready. Envoy will only hit `upB` when it determines `upA` is unavailable.

---

### 2. Start Envoy with the priority failover config

```bash
docker run --rm -d \
  --name envoy \
  -p 10000:10000 \
  -p 9901:9901 \
  -v $PWD/lab/envoy-priority.yaml:/etc/envoy/envoy.yaml \
  envoyproxy/envoy:v1.30-latest
```

**What's happening**: Envoy starts with `envoy-priority.yaml`. The config defines:

- **Listener** on `0.0.0.0:10000` — accepts inbound HTTP connections
- **Route** using `weighted_clusters`: `primary` at weight 100, `failover` at weight 0. All traffic normally goes to `primary`.
- **Cluster `primary`** — `STRICT_DNS` pointing to `host.docker.internal:18081`. Has an active HTTP health check: 2 second interval, 1 second timeout, 1 failure marks unhealthy, 1 success marks healthy again.
- **Cluster `failover`** — `STRICT_DNS` pointing to `host.docker.internal:18082`. No active health check configured; used as a static destination when the route shifts weight.
- **Admin interface** on `0.0.0.0:9901`

The weight=0 on the failover cluster means Envoy's router allocates it zero share of new requests under normal conditions. When the primary cluster has no healthy endpoints, Envoy's priority spillover logic re-evaluates and routes to the next available priority tier.

**Verification**:
```bash
curl http://localhost:10000
# Expected: primary
```

Confirm all three containers are running:
```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

---

### 3. Inspect cluster health via the admin API

The `/clusters` endpoint is your primary operational view into Envoy's current understanding of upstream health. Read it before inducing any failure so you have a baseline.

```bash
curl -s http://localhost:9901/clusters
```

**What's happening**: The output lists every cluster Envoy knows about, one entry per line, in the format:

```
<cluster_name>::<field>::<value>
```

Look for these fields in the `primary` cluster section:

```bash
curl -s http://localhost:9901/clusters | grep "^primary::"
```

Key fields to read:

| Field | Meaning |
|-------|---------|
| `membership_total` | Total endpoints configured in the cluster |
| `membership_healthy` | Endpoints currently passing health checks |
| `membership_degraded` | Endpoints in a degraded state (partial health) |
| `health_flags` | Per-endpoint health state flags (see below) |
| `priority` | Priority level of the endpoint group (0 = highest) |

Health flag values:

| Flag | Meaning |
|------|---------|
| `/healthy` | Active health check passing — endpoint is in rotation |
| `/failed_active_hc` | Active health check failed — endpoint excluded from LB |
| `/pending_active_hc` | Health check has not yet returned a result (startup window) |

**Observe**: At baseline, `primary::membership_healthy` should be `1` and `primary::health_flags` for the endpoint should show `/healthy`. The `failover` cluster has no active health check, so its endpoint will also show `/healthy` by default.

---

### 4. Inspect stats at baseline

Before inducing failure, record the baseline stats so you can see what changes during failover.

```bash
# Health check stats for the primary cluster
curl -s http://localhost:9901/stats | grep "cluster.primary.health_check"

# Current membership counts
curl -s http://localhost:9901/stats | grep -E "cluster\.(primary|failover)\.membership"

# Upstream request counts
curl -s http://localhost:9901/stats | grep -E "cluster\.(primary|failover)\.upstream_rq_total"
```

**What's happening**: Envoy emits stats in the format `cluster.<name>.<stat_name>: <value>`. The health check counters increment as Envoy runs its background probes:

| Stat | Meaning |
|------|---------|
| `health_check.success` | Health check probes that received a 2xx response |
| `health_check.failure` | Health check probes that timed out or received a non-2xx response |
| `health_check.attempt` | Total health check probes sent |
| `membership_healthy` | Current gauge of healthy endpoints (decrements on failure) |
| `upstream_rq_total` | Total requests forwarded to this cluster |

Generate a few requests to populate `upstream_rq_total`:
```bash
for i in $(seq 1 5); do curl -s http://localhost:10000 > /dev/null; done
curl -s http://localhost:9901/stats | grep "cluster.primary.upstream_rq_total"
```

---

### 5. Observe priority failover — stop the primary upstream

```bash
docker stop upA
```

Wait for Envoy's health check to detect the failure. With `interval: 2s` and `unhealthy_threshold: 1`, Envoy needs at most one failed probe cycle to mark the endpoint unhealthy. Wait 3-4 seconds to be safe:

```bash
sleep 4
```

Now send traffic through Envoy:
```bash
curl http://localhost:10000
# Expected: failover
```

**What's happening**: Envoy's background health checker sent an HTTP GET to `host.docker.internal:18081`. The connection was refused (upA is stopped). The health check failed. With `unhealthy_threshold: 1`, one failure is enough to mark the endpoint `/failed_active_hc`. The `primary` cluster now has `membership_healthy: 0`.

With P0 having zero healthy endpoints, Envoy's priority load balancer spills over to P1 — the `failover` cluster. The weighted_clusters route still sends 100 weight to `primary` and 0 to `failover`, but Envoy's priority failover overrides the weight distribution when the higher-priority tier is exhausted.

**Verification**:
```bash
# Confirm health state changed
curl -s http://localhost:9901/clusters | grep "^primary::"

# Look for: primary::health_flags::host.docker.internal/18081::failed_active_hc
# and:      primary::membership_healthy::0
```

---

### 6. Inspect stats during failover

With the primary down and traffic flowing to failover, read the stats to confirm what Envoy is tracking:

```bash
# Health check failure counter should have incremented
curl -s http://localhost:9901/stats | grep "cluster.primary.health_check"

# membership_healthy should now be 0 for primary
curl -s http://localhost:9901/stats | grep "cluster.primary.membership_healthy"

# upstream_rq_total should be incrementing on the failover cluster
curl -s http://localhost:9901/stats | grep -E "cluster\.(primary|failover)\.upstream_rq_total"
```

Send more requests and watch the failover counter grow while the primary counter holds:

```bash
for i in $(seq 1 5); do curl -s http://localhost:10000; done
curl -s http://localhost:9901/stats | grep -E "cluster\.(primary|failover)\.upstream_rq_total"
```

**What's happening**: `cluster.primary.health_check.failure` increments each time the health check probe cannot reach upA. `cluster.failover.upstream_rq_total` increments for each user request that was rerouted. This is the exact signal you would alert on in production: a non-zero and growing `health_check.failure` combined with a drop in `membership_healthy` to zero indicates a cluster is fully down.

**Observe**: Note that Envoy continues probing upA even while it is marked unhealthy. This is how it will detect recovery — the active health check is always running in the background.

---

### 7. Restore the primary and observe failback

`--rm` containers are deleted on stop, so you need to re-launch upA with the same name and port:

```bash
docker run --rm -d --name upA -p 18081:80 hashicorp/http-echo -text="primary"
```

Wait for Envoy's health checker to succeed once. With `healthy_threshold: 1`, a single successful probe restores the endpoint to `/healthy`. Wait one full health check cycle:

```bash
sleep 4
```

Send traffic and observe the response:

```bash
curl http://localhost:10000
# Expected: primary
```

**What's happening**: Envoy's background health check sent a probe to `host.docker.internal:18081` and received a 200 response. With `healthy_threshold: 1`, one success is enough. The endpoint transitions from `/failed_active_hc` back to `/healthy`. `membership_healthy` returns to 1. The priority LB now has a healthy P0 tier and routes traffic back to `primary` exclusively.

**Verification**:
```bash
# Confirm endpoint is healthy again
curl -s http://localhost:9901/clusters | grep "^primary::"
# Look for: health_flags::host.docker.internal/18081::/healthy

# Health check success counter should have incremented
curl -s http://localhost:9901/stats | grep "cluster.primary.health_check.success"

# Traffic should have returned to primary cluster
curl -s http://localhost:9901/stats | grep -E "cluster\.(primary|failover)\.upstream_rq_total"
```

---

### 8. Watch health check timing in real time

Envoy emits an access log entry on the admin port for each health check probe (routed to `/tmp/admin_access.log` inside the container). You can observe the probe cadence directly by watching the `health_check.attempt` stat increment over time:

```bash
# Poll the attempt counter every 2 seconds for 12 seconds
for i in $(seq 1 6); do
  echo -n "t=$((i*2))s attempt="
  curl -s http://localhost:9901/stats | grep "cluster.primary.health_check.attempt" | awk '{print $2}'
  sleep 2
done
```

**What's happening**: With `interval: 2s`, the counter should increment by approximately 1 every 2 seconds. The exact timing depends on jitter (Envoy adds a small random offset to spread probes when many clusters are configured). In production, health check interval is a tradeoff: shorter intervals detect failures faster but add probe traffic; longer intervals reduce overhead but increase the window of undetected failure.

**Observe**: In a cluster with many endpoints and a short interval, health check traffic can become significant. Envoy allows `interval_jitter` and `interval_jitter_percent` to spread probes over time.

---

### 9. Inspect the full config as Envoy sees it

Verify that the priority settings and health check config were parsed correctly:

```bash
# Extract cluster config from config_dump
curl -s http://localhost:9901/config_dump \
  | jq '.configs[] | select(.["@type"] | contains("ClustersConfigDump")) | .static_clusters[] | .cluster | {name: .name, health_checks: .health_checks, load_assignment: .load_assignment}'
```

**What's happening**: The `config_dump` endpoint shows Envoy's internal proto representation of all configured objects. The `load_assignment.endpoints[].priority` field shows the priority level assigned to each endpoint group. In the `primary` cluster, `priority: 0` is the highest priority. In the `failover` cluster, `priority: 1` is the next tier.

This is particularly useful in xDS-managed environments (Istio, Contour) where the config you declared in a CRD may have been transformed significantly before reaching Envoy — the config dump shows what Envoy actually received.

---

## Cleanup

```bash
docker stop envoy upA upB 2>/dev/null || true
```

All three containers were started with `--rm` so they are automatically removed on stop. Verify no containers remain:

```bash
docker ps -a | grep -E "envoy|upA|upB"
# Expected: no output
```

---

## Key Takeaways

1. **Active health checks are cluster-level, not route-level**: The health check config lives on the cluster object. Envoy probes each endpoint independently on the configured interval. The route only controls how requests are distributed across clusters — the cluster's own health check state controls which endpoints within that cluster are eligible.

2. **Priority spillover is automatic when healthy endpoints are exhausted**: When a cluster's `membership_healthy` drops to zero, Envoy's priority load balancer promotes the next priority tier (P1, then P2, etc.) into the active set. This happens inside Envoy without any control plane involvement — it is a local, in-process decision.

3. **`healthy_threshold` and `unhealthy_threshold` control hysteresis**: Setting these to 1 means one probe result flips the endpoint state immediately. In production, set `unhealthy_threshold: 2` or `3` to avoid flapping on transient timeouts, and `healthy_threshold: 2` to ensure recovery is stable before returning traffic.

4. **The admin `/clusters` endpoint is the ground truth for endpoint health**: In any Envoy-based system (Istio sidecar, ingress gateway, Contour, etc.), `curl http://localhost:15000/clusters` (port 15000 in Istio) shows you whether Envoy actually considers your backends up. A pod can be `Running` and `Ready` from Kubernetes' perspective while Envoy marks it `/failed_active_hc` — these health systems are independent.

5. **Stats counters tell the story of what happened**: `health_check.failure` increments on every failed probe; `membership_healthy` is a gauge that reflects the current count. Alerting on `membership_healthy == 0` for a production cluster is more reliable than alerting on individual probe failures, since a single missed probe under load is not unusual.

6. **Failback is governed by `healthy_threshold`, not by traffic**: Envoy does not use a gradual canary approach during failback. Once the endpoint accumulates `healthy_threshold` consecutive successful probes, it immediately re-enters full rotation. If you want gradual failback, use outlier detection with `base_ejection_time` alongside health checks — outlier detection manages ejection duration while health checks manage initial reachability.
