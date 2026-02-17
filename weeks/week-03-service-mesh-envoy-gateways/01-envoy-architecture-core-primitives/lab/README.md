# Lab: Envoy Architecture & Core Primitives

This lab walks through Envoy's static bootstrap configuration hands-on using Docker. You will observe the listener and cluster primitives, explore the admin API, read config dumps, trigger known response flags (NR, UH), and interpret Envoy stats — the exact skills needed to debug Envoy-based proxies in production (Istio, Gateway API, etc.).

## Prerequisites

- Docker installed and running
- `curl` available on the host
- Basic understanding of HTTP proxying concepts
- `jq` recommended for parsing JSON output (optional but helpful)

## Step-by-Step Instructions

### 1. Start the upstream service

```bash
docker run --rm -d --name upstream -p 18080:80 hashicorp/http-echo -text="hello from upstream"
```

**What's happening**: `http-echo` is a minimal HTTP server that responds with the given text body and a 200 status code. It stands in for any real backend service. Port 18080 on the host maps to port 80 inside the container.

**Verification**:
```bash
curl -v http://localhost:18080
```

Expected output includes:
```
< HTTP/1.1 200 OK
hello from upstream
```

---

### 2. Start Envoy with static config

```bash
docker run --rm -d \
  --name envoy \
  -p 10000:10000 \
  -p 9901:9901 \
  -v $PWD/lab/envoy.yaml:/etc/envoy/envoy.yaml \
  envoyproxy/envoy:v1.30-latest
```

**What's happening**: Envoy starts with a static bootstrap config mounted from your local `envoy.yaml`. On startup Envoy reads this file once and builds its internal config graph:

- **Listener** on `0.0.0.0:10000` — accepts inbound TCP connections
- **HttpConnectionManager (HCM)** filter — parses HTTP/1.1, routes requests, emits access logs
- **Route config** — matches all prefixes (`/`) on any virtual host domain (`*`) and sends traffic to the `upstream` cluster
- **Cluster** named `upstream` — resolves `host.docker.internal:18080` via STRICT_DNS, uses ROUND_ROBIN load balancing
- **Admin interface** on `0.0.0.0:9901` — exposes live config, stats, and management endpoints

Port 10000 is the proxy ingress. Port 9901 is the admin API — never expose this externally in production.

**Verification**:
```bash
curl http://localhost:10000/
```

Expected:
```
hello from upstream
```

Check that both containers are running:
```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

---

### 3. Explore the admin interface

The admin API at `:9901` is Envoy's operational control plane. It provides read access to live config, stats, and limited write operations (drain, pause listeners, etc.).

```bash
# List all available admin endpoints
curl -s http://localhost:9901/help
```

Hit the most useful endpoints:

```bash
# Current server state and version
curl -s http://localhost:9901/server_info | jq .

# All configured listeners (name, address, filter chain)
curl -s http://localhost:9901/listeners

# All clusters with current health and endpoint state
curl -s http://localhost:9901/clusters

# Raw stats counters and gauges (thousands of entries)
curl -s http://localhost:9901/stats | head -40
```

**What's happening**: These endpoints read directly from Envoy's in-memory state, not from a config file. This is authoritative — if config was pushed via xDS and the file is stale, the admin API still reflects what Envoy is actually doing.

**Observe**: `/listeners` shows `listener_0::0.0.0.0:10000`. `/clusters` shows `upstream::` entries with endpoint health and connection pool stats.

---

### 4. Inspect the config graph via config_dump

`/config_dump` returns the complete internal representation of all Envoy config objects as JSON. This is the primary tool for verifying that xDS pushes were applied correctly.

```bash
# Full config dump (large output — pipe to jq or less)
curl -s http://localhost:9901/config_dump | jq 'keys'
```

Expected keys: `["BootstrapConfig", "ClustersConfigDump", "ListenersConfigDump", "RoutesConfigDump", "SecretsConfigDump"]`

```bash
# Inspect only the listener config
curl -s 'http://localhost:9901/config_dump?resource=dynamic_listeners' | jq .

# Static listeners (what we configured) are under a different key
curl -s http://localhost:9901/config_dump | jq '.configs[] | select(.["@type"] | contains("ListenersConfigDump"))'
```

Drill into the route table:
```bash
curl -s http://localhost:9901/config_dump \
  | jq '.configs[] | select(.["@type"] | contains("RoutesConfigDump")) | .static_route_configs[].route_config.virtual_hosts[].routes'
```

**What's happening**: In a static config, all resources appear under `static_*` keys. In an xDS-managed Envoy (e.g., inside Istio), you would see `dynamic_*` keys populated by the control plane (Pilot/istiod). The shape of the JSON is identical — this is how Istio's `istioctl proxy-config` works under the hood.

**Observe**: The route entry shows `match.prefix: "/"` pointing to `route.cluster: "upstream"` — this is the exact YAML you wrote, parsed into Envoy's internal proto representation.

---

### 5. Observe access logs

Envoy's HCM emits an access log line per request. By default in this config it logs to stdout, which Docker captures.

Make a few requests first:
```bash
for i in $(seq 1 5); do curl -s http://localhost:10000/ > /dev/null; done
```

Now inspect the access logs:
```bash
docker logs envoy
```

**What's happening**: Each log line follows Envoy's default access log format:
```
[2024-01-15T10:23:01.123Z] "GET / HTTP/1.1" 200 - 0 22 4 3 "-" "curl/8.4.0" "req-id-xyz" "host.docker.internal:18080" "192.168.65.254:18080"
```

Fields (left to right): timestamp, method+path+protocol, response code, response flags, bytes received, bytes sent, duration ms, upstream duration ms, referer, user-agent, x-request-id, upstream host (resolved), upstream address.

The **response flags** field (the `-` after `200`) is critical for debugging. A dash means no flags. Flags like `NR` and `UH` appear here when things go wrong — you will trigger these in the next steps.

---

### 6. Trigger a route mismatch (NR — No Route)

The `NR` response flag means Envoy received a request but found no matching route. The proxy rejects the request before it touches any cluster. The current `envoy.yaml` uses `domains: ["*"]` which catches all Host headers, so we need to restart Envoy with a stricter config to observe `NR`.

Stop the current Envoy and launch one that only accepts `Host: example.com`:

```bash
docker stop envoy

docker run --rm -d \
  --name envoy \
  -p 10000:10000 \
  -p 9901:9901 \
  envoyproxy/envoy:v1.30-latest \
  /usr/local/bin/envoy --config-yaml "
static_resources:
  listeners:
  - name: listener_0
    address:
      socket_address: { address: 0.0.0.0, port_value: 10000 }
    filter_chains:
    - filters:
      - name: envoy.filters.network.http_connection_manager
        typed_config:
          '@type': type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          stat_prefix: ingress_http
          route_config:
            name: local_route
            virtual_hosts:
            - name: vhost
              domains: ['example.com']
              routes:
              - match: { prefix: '/' }
                route: { cluster: upstream }
          http_filters:
          - name: envoy.filters.http.router
            typed_config: { '@type': type.googleapis.com/envoy.extensions.filters.http.router.v3.Router }
  clusters:
  - name: upstream
    connect_timeout: 0.25s
    type: STRICT_DNS
    lb_policy: ROUND_ROBIN
    load_assignment:
      cluster_name: upstream
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address: { address: host.docker.internal, port_value: 18080 }
admin:
  access_log_path: /tmp/admin_access.log
  address:
    socket_address: { address: 0.0.0.0, port_value: 9901 }
"
```

Now send a request with a Host header that does not match `example.com`:

```bash
# No matching virtual host — produces NR
curl -v -H "Host: other.example.com" http://localhost:10000/
```

Expected response:
```
< HTTP/1.1 404 Not Found
no virtual host matched
```

Check the access log for the `NR` flag:
```bash
docker logs envoy --tail 3
```

Expected log line:
```
[...] "GET / HTTP/1.1" 404 NR 0 22 0 - "-" "curl/8.4.0" ...
```

Send a correctly matched request to confirm routing still works when the Host is right:
```bash
curl -s -H "Host: example.com" http://localhost:10000/
```

Restore Envoy to the original file-based config for the remaining steps:
```bash
docker stop envoy
docker run --rm -d \
  --name envoy \
  -p 10000:10000 \
  -p 9901:9901 \
  -v $PWD/lab/envoy.yaml:/etc/envoy/envoy.yaml \
  envoyproxy/envoy:v1.30-latest
```

**What's happening**: `NR` fires when the HCM's route table has no `VirtualHost` whose `domains` list matches the request's `:authority` (Host) header, or no `Route` whose `match` criteria match the request path/headers. In Istio sidecars this is one of the most common failure modes — a pod sends traffic to a hostname not registered in the mesh's service registry, and the sidecar returns `502 Bad Gateway` with response flag `NR`.

---

### 7. Trigger no healthy upstream (UH)

`UH` means "No Healthy Upstream" — the route matched a cluster, but the cluster had zero healthy endpoints. This is distinct from a connection refused — Envoy never attempts the connection.

```bash
# Stop the upstream container
docker stop upstream
```

```bash
# Wait a moment for Envoy's health state to update (STRICT_DNS resolves periodically)
sleep 2

# Now send a request through Envoy
curl -v http://localhost:10000/
```

Expected response:
```
< HTTP/1.1 503 Service Unavailable
no healthy upstream
```

Inspect the access log immediately:
```bash
docker logs envoy --tail 5
```

Look for the response flags field — it will show `UH` instead of `-`:
```
[...] "GET / HTTP/1.1" 503 UH 0 19 0 - "-" "curl/8.4.0" ...
```

Confirm via stats:
```bash
curl -s http://localhost:9901/stats | grep -E "upstream_cx_none_healthy|membership_healthy"
```

**What's happening**: With `type: STRICT_DNS`, Envoy resolves `host.docker.internal:18080` on an interval. When the upstream stops, the DNS entry may still resolve but TCP connections will fail. Envoy marks the endpoint as unhealthy (or removes it if health checks are configured), and returns `503 UH` before making any outbound connection. This is Envoy's fast-fail behavior — it does not hold connections waiting for backends to recover.

Restart the upstream to restore service:
```bash
docker run --rm -d --name upstream -p 18080:80 hashicorp/http-echo -text="hello from upstream"
sleep 2
curl http://localhost:10000/
```

---

### 8. Inspect stats

Envoy exposes a rich set of counters, gauges, and histograms via `/stats`. These map directly to what you see in Prometheus when Envoy's metrics endpoint is scraped.

```bash
# All cluster-level stats for the upstream cluster
curl -s http://localhost:9901/stats | grep "cluster.upstream"
```

Key stats to understand:

```bash
# Connection pool stats
curl -s http://localhost:9901/stats | grep -E "cluster\.upstream\.(upstream_cx|upstream_rq)"
```

| Stat | Meaning |
|------|---------|
| `upstream_cx_total` | Total outbound connections Envoy has opened to this cluster |
| `upstream_cx_active` | Currently open connections (connection pool gauge) |
| `upstream_rq_total` | Total HTTP requests forwarded to this cluster |
| `upstream_rq_2xx` | Requests that received a 2xx response |
| `upstream_rq_5xx` | Requests that received a 5xx response |
| `upstream_rq_pending_total` | Requests queued waiting for a connection (circuit breaker territory) |
| `membership_total` | Total endpoints known in the cluster |
| `membership_healthy` | Endpoints currently considered healthy |

```bash
# Listener stats — inbound request counts
curl -s http://localhost:9901/stats | grep "listener.0.0.0.0_10000"

# HTTP filter stats (per-route and per-vhost)
curl -s http://localhost:9901/stats | grep "http.ingress_http"
```

Generate some traffic and watch counters increment:
```bash
for i in $(seq 1 10); do curl -s http://localhost:10000/ > /dev/null; done
curl -s http://localhost:9901/stats | grep "upstream_rq_total"
```

For JSON-formatted stats (compatible with Prometheus text format parsing):
```bash
curl -s http://localhost:9901/stats?format=json | jq '.stats[] | select(.name | contains("upstream_rq_total"))'
```

---

## Cleanup

```bash
docker stop envoy upstream
```

Both containers were started with `--rm` so they will be automatically removed after stopping. Verify:
```bash
docker ps -a | grep -E "envoy|upstream"
```

---

## Key Takeaways

1. **Listeners and clusters are the two fundamental primitives**: a listener accepts inbound connections and chains filter stacks; a cluster represents an upstream service with its own load balancing, health checking, and circuit breaking config.

2. **The admin API at `:9901` is authoritative**: it shows what Envoy is actually running, not what a config file says. In xDS-managed environments (Istio), the running config often differs significantly from static manifests — always use `/config_dump` and `/clusters` to debug.

3. **Response flags are your first debugging signal**: `NR` (no route) means the proxy rejected the request before touching any backend; `UH` (no healthy upstream) means the cluster exists but has no available endpoints; `UC` (upstream connection failure) means a TCP failure; `URX` means the retry limit was exhausted. Each flag points to a different layer of the Envoy stack.

4. **Stats counters are the source of truth for traffic behavior**: `membership_healthy` tells you if Envoy considers your backends up; `upstream_rq_pending_overflow` tells you if circuit breakers are open; `upstream_rq_retry` tells you if retries are firing. These are the same metrics surfaced in Istio's Grafana dashboards.

5. **Static config is single-pass; xDS is live**: this lab uses a static bootstrap file that Envoy reads once at startup. In production (Istio, Contour, etc.) a control plane pushes config changes dynamically via the xDS APIs (LDS, RDS, CDS, EDS) without restarting Envoy — but the primitives (listeners, routes, clusters, endpoints) are identical.

6. **`host.docker.internal` is a Mac/Windows Docker DNS alias**: in a real Kubernetes sidecar, Envoy's clusters point to `127.0.0.1` (for localhost traffic interception) or to pod IPs delivered via EDS. The topology changes but the cluster configuration shape stays the same.
