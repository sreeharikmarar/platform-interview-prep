# Lab: Inference Gateways & L7 Routing for AI Workloads

This lab simulates the core routing behaviors of an inference gateway using Envoy and two mock model-serving backends running in Docker. You will observe how weighted traffic splitting produces bimodal latency distributions, how tail latency degrades when slow backends receive more traffic, how circuit breakers protect against queue overflow, and how least-request load balancing outperforms round-robin when backend response times are heterogeneous — all of which are the exact mechanisms that govern GPU-backed inference routing in production systems like those built on vLLM, Triton Inference Server, or custom model servers behind Envoy-based gateways.

## Prerequisites

- Docker installed and running (Docker Desktop or Docker Engine)
- `curl` available on the host
- `jq` installed (`brew install jq` on macOS, `apt install jq` on Debian/Ubuntu)
- `hey` installed for load generation (`brew install hey` on macOS, or download from https://github.com/rakyll/hey)
- Basic familiarity with Envoy static config (listeners, clusters, weighted_clusters)
- Completed or reviewed: week-03/01-envoy-architecture-core-primitives

## Learning Objectives

By the end of this lab you will be able to:

- Explain why weighted cluster routing produces a bimodal latency distribution and predict the shape of that distribution from the weights and per-backend latencies
- Interpret Envoy circuit breaker stats (`upstream_rq_pending_overflow`) to confirm overflow protection is active
- Explain why LEAST_REQUEST outperforms ROUND_ROBIN for heterogeneous-latency backends
- Measure time-to-first-byte (TTFB) and explain why it is the correct metric for streaming inference responses

---

## Step 1: Start the two mock model backends

The two backends simulate a fast model version (v1, 100ms response time) and a slow model version (v2, 500ms response time). In a real inference system these represent the same model at different sizes or quantization levels, or a new version being evaluated in canary. Each backend is a minimal Python HTTP server that sleeps for a fixed duration and returns a JSON payload indicating which version handled the request.

```bash
# Start model-v1: fast backend, 100ms response latency, port 8081
docker run --rm -d \
  --name model-v1 \
  -p 8081:8080 \
  python:3.11-slim \
  python3 -c "
import http.server, json, time

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args): pass
    def do_GET(self):
        time.sleep(0.1)
        body = json.dumps({'model': 'v1', 'latency_ms': 100}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_POST(self):
        self.do_GET()

http.server.HTTPServer(('0.0.0.0', 8080), Handler).serve_forever()
"

# Start model-v2: slow backend, 500ms response latency, port 8082
docker run --rm -d \
  --name model-v2 \
  -p 8082:8080 \
  python:3.11-slim \
  python3 -c "
import http.server, json, time

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args): pass
    def do_GET(self):
        time.sleep(0.5)
        body = json.dumps({'model': 'v2', 'latency_ms': 500}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_POST(self):
        self.do_GET()

http.server.HTTPServer(('0.0.0.0', 8080), Handler).serve_forever()
"
```

**What's happening**: Both containers run embedded Python HTTP servers. The `time.sleep()` call simulates inference latency — in a real model server, this is the time the GPU spends computing the forward pass and generating tokens. Port 8081 on the host maps to v1, port 8082 to v2.

**Verification**:
```bash
curl -s http://localhost:8081/ | jq .
# Expected: {"model": "v1", "latency_ms": 100}

curl -s http://localhost:8082/ | jq .
# Expected: {"model": "v2", "latency_ms": 500}
```

**Observe**: Both backends respond correctly. The v2 response takes noticeably longer — you can feel the 400ms difference with a manual curl.

---

## Step 2: Start Envoy with 90/10 weighted split

```bash
# From the repository root
LAB_DIR="$(pwd)/weeks/week-04-distributed-systems-scale-and-ai/03-inference-gateways-and-routing/lab"

docker run --rm -d \
  --name envoy-inference \
  -p 10000:10000 \
  -p 9901:9901 \
  --add-host=host.docker.internal:host-gateway \
  -v "${LAB_DIR}/envoy-weighted.yaml:/etc/envoy/envoy.yaml" \
  envoyproxy/envoy:v1.30-latest
```

**What's happening**: Envoy starts with the `envoy-weighted.yaml` config from this lab directory. The route config uses `weighted_clusters` to split traffic 90% to `model_v1` (port 8081) and 10% to `model_v2` (port 8082). This mirrors a production canary deployment: 90% of inference traffic goes to the stable model version and 10% to the new version being validated. The `--add-host` flag is required on Linux hosts to resolve `host.docker.internal` — Docker Desktop sets this automatically on macOS and Windows.

**Verification**:
```bash
# Confirm Envoy is running and serving traffic
curl -s http://localhost:10000/ | jq .

# Check admin interface — both clusters should show healthy endpoints
curl -s http://localhost:9901/clusters | grep -E "model_v[12]"
```

**Observe**: The admin `/clusters` output shows both `model_v1` and `model_v2` clusters. Look for `health_flags::healthy` on each endpoint.

Confirm the weighted routing config is loaded:
```bash
curl -s http://localhost:9901/config_dump \
  | jq '.configs[] | select(.["@type"] | contains("RoutesConfigDump"))
        | .static_route_configs[].route_config.virtual_hosts[].routes[].route.weighted_clusters'
```

---

## Step 3: Send 100 requests and observe bimodal latency distribution

```bash
# Send 100 requests with 10 concurrent workers
hey -n 100 -c 10 http://localhost:10000/
```

**What's happening**: `hey` sends 100 HTTP GET requests with a concurrency of 10. With 90/10 weighted routing, approximately 90 requests will be handled by model_v1 (100ms latency) and approximately 10 requests by model_v2 (500ms latency). The latency distribution is not normal — it is bimodal, with two distinct peaks around 100ms and 500ms.

**Observe**: `hey` prints a latency histogram and percentile breakdown. Look for:
- A large cluster of responses around 100-120ms (the v1 pool)
- A small cluster of responses around 500-520ms (the v2 pool)
- p50 near 100ms (the dominant cluster)
- p95 and p99 pulled upward toward 500ms by the 10% v2 traffic

Record the p50, p95, and p99 values — you will compare them after Step 4.

**Verification**:
```bash
# Confirm the actual routing split matches the configured weights
curl -s http://localhost:9901/stats | grep -E "cluster\.model_v[12]\.upstream_rq_total"
```

The `upstream_rq_total` counter for `model_v1` should be approximately 90 and for `model_v2` approximately 10, with natural variance from the probabilistic weighted selection.

---

## Step 4: Shift weights to 50/50 and re-measure

Envoy static config requires a restart to update. Stop Envoy and restart with equal weights:

```bash
docker stop envoy-inference

# Restart with 50/50 weights using inline config
docker run --rm -d \
  --name envoy-inference \
  -p 10000:10000 \
  -p 9901:9901 \
  --add-host=host.docker.internal:host-gateway \
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
            - name: inference_vhost
              domains: ['*']
              routes:
              - match: { prefix: '/' }
                route:
                  weighted_clusters:
                    clusters:
                    - name: model_v1
                      weight: 50
                    - name: model_v2
                      weight: 50
                    total_weight: 100
          http_filters:
          - name: envoy.filters.http.router
            typed_config: { '@type': type.googleapis.com/envoy.extensions.filters.http.router.v3.Router }
  clusters:
  - name: model_v1
    connect_timeout: 1s
    type: STATIC
    lb_policy: ROUND_ROBIN
    load_assignment:
      cluster_name: model_v1
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address: { address: host.docker.internal, port_value: 8081 }
  - name: model_v2
    connect_timeout: 1s
    type: STATIC
    lb_policy: ROUND_ROBIN
    load_assignment:
      cluster_name: model_v2
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address: { address: host.docker.internal, port_value: 8082 }
    circuit_breakers:
      thresholds:
      - priority: DEFAULT
        max_pending_requests: 5
admin:
  access_log_path: /tmp/admin_access.log
  address:
    socket_address: { address: 0.0.0.0, port_value: 9901 }
"
```

Re-run the load test:
```bash
hey -n 100 -c 10 http://localhost:10000/
```

**What's happening**: With equal weights, approximately 50 requests go to v1 and 50 to v2. The bimodal distribution is now symmetric — two equally-sized clusters at 100ms and 500ms. The overall p50 shifts from ~100ms to ~300ms (the midpoint of the two distributions). p99 remains anchored near 500ms because the slow backend's tail dominates regardless of its traffic share.

**Observe**: Compare p50, p95, and p99 against the Step 3 measurement:
- p50 increases significantly (from ~100ms to ~300ms) — directly reflects the traffic proportion shift
- p95 and p99 remain close to 500ms — the slow backend sets the tail regardless of traffic weight
- The histogram now shows two roughly equal buckets rather than a dominant fast bucket with a small slow tail

This is the core lesson of weighted canary routing: **p50 tracks the traffic-weighted average of backend latencies, but p99 is dominated by the slowest backend in the mix**. Even 10% canary weight can make p99 appear to degrade if the canary is slower, even when the canary is healthy and functionally correct.

---

## Step 5: Observe circuit breaker overflow protection

The `model_v2` cluster in `envoy-weighted.yaml` has `max_pending_requests: 5`. This limits the number of requests queuing for an upstream connection to model_v2 to 5. Requests beyond this limit are immediately rejected with HTTP 503 and Envoy response flag `UO` (upstream overflow), rather than accumulating in an unbounded queue.

Restore the file-based config (which has the circuit breaker on v2):
```bash
docker stop envoy-inference

LAB_DIR="$(pwd)/weeks/week-04-distributed-systems-scale-and-ai/03-inference-gateways-and-routing/lab"
docker run --rm -d \
  --name envoy-inference \
  -p 10000:10000 \
  -p 9901:9901 \
  --add-host=host.docker.internal:host-gateway \
  -v "${LAB_DIR}/envoy-weighted.yaml:/etc/envoy/envoy.yaml" \
  envoyproxy/envoy:v1.30-latest
```

Send a burst of concurrent requests large enough to overflow the v2 pending queue:
```bash
# 200 requests, 50 concurrent — sufficient to overflow the v2 circuit breaker
hey -n 200 -c 50 http://localhost:10000/
```

**What's happening**: With 200 requests at 50 concurrency, approximately 10% (20 requests) will be routed to v2. v2 takes 500ms per request and has one connection available. Requests queued beyond the `max_pending_requests: 5` limit are rejected immediately with `UO` rather than waiting. In an inference system, an unbounded queue means requests pile up for minutes against a slow GPU pod — a fast fail with circuit breaking is better than a slow success that has already missed any useful latency SLO.

**Observe**:
```bash
# Check circuit breaker overflow counter on v2 cluster
curl -s http://localhost:9901/stats | grep "upstream_rq_pending_overflow"

# Check access logs for UO response flag
docker logs envoy-inference 2>&1 | grep " UO " | head -5
```

You should see a non-zero count for `cluster.model_v2.upstream_rq_pending_overflow` and access log lines with `503 UO`.

**Verification**: The `hey` output will show some `[503]` responses alongside `[200]` responses. The proportion of 503s in the v2 traffic confirms the circuit breaker is active. The v1 traffic should be entirely 200s.

---

## Step 6: Switch to LEAST_REQUEST load balancing

ROUND_ROBIN distributes requests evenly by count without regard to how long each request takes. LEAST_REQUEST routes each new request to the backend with the fewest active in-flight connections. For heterogeneous-latency workloads this avoids stacking requests on already-busy backends.

Start a second v2 replica to create a two-endpoint pool:
```bash
docker run --rm -d \
  --name model-v2b \
  -p 8083:8080 \
  python:3.11-slim \
  python3 -c "
import http.server, json, time

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args): pass
    def do_GET(self):
        time.sleep(0.5)
        body = json.dumps({'model': 'v2b', 'latency_ms': 500}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_POST(self):
        self.do_GET()

http.server.HTTPServer(('0.0.0.0', 8080), Handler).serve_forever()
"
```

Test ROUND_ROBIN across the two v2 replicas:
```bash
docker stop envoy-inference

docker run --rm -d \
  --name envoy-inference \
  -p 10000:10000 \
  -p 9901:9901 \
  --add-host=host.docker.internal:host-gateway \
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
            - name: inference_vhost
              domains: ['*']
              routes:
              - match: { prefix: '/' }
                route: { cluster: model_v2_pool }
          http_filters:
          - name: envoy.filters.http.router
            typed_config: { '@type': type.googleapis.com/envoy.extensions.filters.http.router.v3.Router }
  clusters:
  - name: model_v2_pool
    connect_timeout: 1s
    type: STATIC
    lb_policy: ROUND_ROBIN
    load_assignment:
      cluster_name: model_v2_pool
      endpoints:
      - lb_endpoints:
        - endpoint: { address: { socket_address: { address: host.docker.internal, port_value: 8082 } } }
        - endpoint: { address: { socket_address: { address: host.docker.internal, port_value: 8083 } } }
admin:
  access_log_path: /tmp/admin_access.log
  address:
    socket_address: { address: 0.0.0.0, port_value: 9901 }
"

sleep 1
echo "--- ROUND_ROBIN ---"
hey -n 100 -c 20 http://localhost:10000/
```

Now test LEAST_REQUEST:
```bash
docker stop envoy-inference

docker run --rm -d \
  --name envoy-inference \
  -p 10000:10000 \
  -p 9901:9901 \
  --add-host=host.docker.internal:host-gateway \
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
            - name: inference_vhost
              domains: ['*']
              routes:
              - match: { prefix: '/' }
                route: { cluster: model_v2_pool }
          http_filters:
          - name: envoy.filters.http.router
            typed_config: { '@type': type.googleapis.com/envoy.extensions.filters.http.router.v3.Router }
  clusters:
  - name: model_v2_pool
    connect_timeout: 1s
    type: STATIC
    lb_policy: LEAST_REQUEST
    load_assignment:
      cluster_name: model_v2_pool
      endpoints:
      - lb_endpoints:
        - endpoint: { address: { socket_address: { address: host.docker.internal, port_value: 8082 } } }
        - endpoint: { address: { socket_address: { address: host.docker.internal, port_value: 8083 } } }
admin:
  access_log_path: /tmp/admin_access.log
  address:
    socket_address: { address: 0.0.0.0, port_value: 9901 }
"

sleep 1
echo "--- LEAST_REQUEST ---"
hey -n 100 -c 20 http://localhost:10000/
```

**What's happening**: With two homogeneous 500ms backends, LEAST_REQUEST and ROUND_ROBIN produce similar results because both endpoints accumulate requests at the same rate. The contrast becomes significant when one backend is slower — a GPU pod with a 10-request queue will have 10 active connections while an idle pod has zero, and LEAST_REQUEST routes the next request to the idle pod. ROUND_ROBIN ignores this and alternates blindly. The stat below confirms LEAST_REQUEST is tracking active connection counts per endpoint.

**Observe**:
```bash
# Check that requests are distributed across endpoints
curl -s http://localhost:9901/stats | grep "cluster.model_v2_pool"
```

Look at the `upstream_cx_active` gauge per endpoint address — LEAST_REQUEST will show more even active connection distribution under load compared to ROUND_ROBIN's strict alternation.

---

## Step 7: Measure time-to-first-byte for streaming backends

In production inference, backends stream tokens via server-sent events (SSE). The user-perceived metric is time-to-first-token (TTFT), which maps directly to time-to-first-byte (TTFB) at the HTTP layer. Restart backends that simulate streaming responses with an initial delay before the first token.

```bash
docker stop model-v1 model-v2 model-v2b 2>/dev/null; true

# v1: 50ms TTFB — cache-warm prefill
docker run --rm -d \
  --name model-v1 \
  -p 8081:8080 \
  python:3.11-slim \
  python3 -c "
import http.server, time

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args): pass
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Transfer-Encoding', 'chunked')
        self.end_headers()
        time.sleep(0.05)
        self.wfile.write(b'data: {\"token\": \"hello\", \"model\": \"v1\"}\n\n')
        self.wfile.flush()
        time.sleep(0.1)
        self.wfile.write(b'data: [DONE]\n\n')
        self.wfile.flush()
    def do_POST(self):
        self.do_GET()

http.server.HTTPServer(('0.0.0.0', 8080), Handler).serve_forever()
"

# v2: 300ms TTFB — cold KV cache (full prefill required)
docker run --rm -d \
  --name model-v2 \
  -p 8082:8080 \
  python:3.11-slim \
  python3 -c "
import http.server, time

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args): pass
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Transfer-Encoding', 'chunked')
        self.end_headers()
        time.sleep(0.3)
        self.wfile.write(b'data: {\"token\": \"hello\", \"model\": \"v2\"}\n\n')
        self.wfile.flush()
        time.sleep(0.1)
        self.wfile.write(b'data: [DONE]\n\n')
        self.wfile.flush()
    def do_POST(self):
        self.do_GET()

http.server.HTTPServer(('0.0.0.0', 8080), Handler).serve_forever()
"
```

Restart Envoy with the file-based weighted config:
```bash
docker stop envoy-inference 2>/dev/null; true

LAB_DIR="$(pwd)/weeks/week-04-distributed-systems-scale-and-ai/03-inference-gateways-and-routing/lab"
docker run --rm -d \
  --name envoy-inference \
  -p 10000:10000 \
  -p 9901:9901 \
  --add-host=host.docker.internal:host-gateway \
  -v "${LAB_DIR}/envoy-weighted.yaml:/etc/envoy/envoy.yaml" \
  envoyproxy/envoy:v1.30-latest

sleep 1
```

Measure TTFB using curl's built-in timing:
```bash
# Measure TTFB across 10 requests
for i in $(seq 1 10); do
  curl -s -o /dev/null \
    -w "ttfb=%{time_starttransfer}s total=%{time_total}s\n" \
    http://localhost:10000/
done
```

**What's happening**: `curl`'s `time_starttransfer` is the elapsed time from when curl started the request until the moment the first byte of the response body is received. For an SSE stream, this is TTFT — the time from request initiation until the first `data:` token line arrives. `time_total` is the time until the stream closes. The gap between `time_starttransfer` and `time_total` represents the duration of the token generation stream — in this lab approximately 100ms for both backends.

**Observe**: With 90% traffic to v1 (50ms TTFB) and 10% to v2 (300ms TTFB), most requests show `ttfb=0.05x` and approximately 1 in 10 shows `ttfb=0.30x`. This directly models the KV cache hit vs. miss scenario: v1 represents a request that hits the prefix cache (short prefill), v2 represents a request that misses the cache and must recompute the full prompt (long prefill). KV cache affinity routing — consistently sending requests from the same session to the same backend — would eliminate v2-class TTFB for returning sessions.

**Verification**:
```bash
# Confirm Envoy is proxying the SSE stream without buffering
curl -N http://localhost:10000/
```

You should see `data:` lines appear with a visible delay between them (the `time.sleep(0.1)` in the backend), confirming Envoy forwards chunks as they arrive rather than buffering the full response.

---

## Cleanup

```bash
docker stop envoy-inference model-v1 model-v2 model-v2b 2>/dev/null; true
docker ps -a | grep -E "envoy-inference|model-v"
```

All containers were started with `--rm` and are removed automatically on stop. The final command should return no output.

---

## Key Takeaways

1. **Weighted routing creates bimodal latency distributions**: p50 tracks the traffic-weighted average of backend latencies; p99 is anchored to the slowest backend in the mix regardless of its weight. A 10% canary to a 500ms backend will not move p50 measurably but will pull p95 and p99 toward 500ms. Canary analysis requires looking at percentiles, not averages.

2. **Circuit breakers on slow backends prevent queue storms**: without `max_pending_requests`, a slow GPU pod accumulates an unbounded queue. Every request eventually succeeds but with wait time proportional to queue depth times processing time. The circuit breaker fast-fails when the queue limit is reached, allowing clients to retry against healthy backends. Watch `upstream_rq_pending_overflow` — a non-zero value confirms shedding is active.

3. **LEAST_REQUEST outperforms ROUND_ROBIN for heterogeneous backends**: a GPU pod processing a 32k-token context holds a connection for several seconds while an idle pod has zero active connections. ROUND_ROBIN alternates blindly; LEAST_REQUEST tracks active connection counts and routes to the least-loaded pod. The difference in p99 is most pronounced at high concurrency with variable request durations — exactly the inference workload profile.

4. **TTFB (time_starttransfer) is the correct metric for streaming inference**: `time_total` conflates TTFT with generation throughput. A model with low TTFT but high throughput has fast `time_starttransfer` and moderate `time_total`. A model with KV cache misses has slow `time_starttransfer` (expensive prefill) but similar `time_total`. Users perceive `time_starttransfer` as responsiveness. Route on TTFB when optimizing for interactive latency; route on throughput when optimizing for batch generation.

5. **Weight updates are the inference rollback mechanism**: unlike a Deployment rollback (pod replacement), changing weighted cluster weights in the gateway routing config takes effect on the next request with no pod disruption. In a production xDS-managed gateway (Gateway API, Istio VirtualService, or a custom control plane), a weight change propagates to all gateway replicas in under 5 seconds. Implement inference canary rollback as a weight update, not a Kubernetes Deployment rollback.
