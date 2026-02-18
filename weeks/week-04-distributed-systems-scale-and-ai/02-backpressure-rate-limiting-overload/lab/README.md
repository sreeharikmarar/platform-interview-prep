# Lab: Backpressure, Rate Limiting & Overload Protection

This lab demonstrates Envoy circuit breaking and retry budgets using Docker containers only — no Kubernetes cluster required. You will observe how aggregate circuit breaker limits produce 503 overflow responses under load, inspect the precise stats Envoy exposes to diagnose circuit state, hot-reload threshold changes without restarting the proxy, and see how `retry_budget` bounds retry amplification when a backend becomes slow.

## Learning Objectives

By the end of this lab you should be able to:

- Read Envoy circuit breaker stats from the admin `/clusters` and `/stats` endpoints
- Identify `UO` (upstream overflow) and `UT` (upstream request timeout) response flags in access logs
- Explain the difference between `max_connections`, `max_pending_requests`, and `max_requests`
- Explain why `retry_budget.budget_percent` prevents retry storms better than per-request `num_retries`
- Describe the observable sequence of events when a backend slows down and a circuit breaker trips

## Prerequisites

- Docker installed and running (Docker Desktop on Mac or Docker Engine on Linux)
- `curl` available on the host
- `jq` installed (`brew install jq` on Mac, `apt install jq` on Linux)
- `hey` HTTP load generator installed (`brew install hey` on Mac, or `go install github.com/rakyll/hey@latest`)
- Ports 8080, 9901, and 10000 free on the host machine

All files referenced below are in this directory (`lab/`). Run commands from the `lab/` directory or adjust paths accordingly.

---

## Step 1: Start a simple HTTP backend with configurable delay

The backend is a minimal Python HTTP server that reads `DELAY_MS` from the environment and sleeps before responding. This lets you simulate healthy, slow, and timing-out backends by changing a single environment variable.

```bash
docker run --rm -d \
  --name backend \
  -p 8080:8080 \
  -e DELAY_MS=0 \
  python:3.12-slim \
  python3 -c "
import os, time, http.server, socketserver

DELAY_MS = int(os.environ.get('DELAY_MS', '0'))
PORT = 8080

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if DELAY_MS > 0:
            time.sleep(DELAY_MS / 1000.0)
        body = f'ok delay={DELAY_MS}ms\n'.encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, fmt, *args):
        print(f'[{self.address_string()}] {fmt % args}', flush=True)

print(f'Starting on port {PORT} DELAY_MS={DELAY_MS}', flush=True)
with socketserver.TCPServer(('', PORT), Handler) as httpd:
    httpd.allow_reuse_address = True
    httpd.serve_forever()
"
```

**What's happening**: The backend listens on port 8080 inside the container, mapped to port 8080 on the host. With `DELAY_MS=0` it responds immediately — this is the healthy-backend baseline. The server handles one request at a time per Python thread (single-threaded by default), which deliberately limits its concurrency to make the circuit breaker easy to trip.

**Verify**:
```bash
curl -s http://localhost:8080/
```

Expected output:
```
ok delay=0ms
```

Check that the container is running:
```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

---

## Step 2: Start Envoy with circuit breaker configuration

The `envoy-circuit-breaker.yaml` in this directory configures Envoy with intentionally tight circuit breaker limits: `max_connections: 3`, `max_pending_requests: 1`, `max_requests: 3`, `max_retries: 1`. These values are far below what you would set in production but they make the circuit breaker observable at the concurrency levels this lab generates.

```bash
docker run --rm -d \
  --name envoy \
  -p 10000:10000 \
  -p 9901:9901 \
  -v "$(pwd)/envoy-circuit-breaker.yaml:/etc/envoy/envoy.yaml" \
  envoyproxy/envoy:v1.30-latest \
  envoy -c /etc/envoy/envoy.yaml --log-level info
```

**What's happening**: Envoy reads the static bootstrap config and builds its internal state:

- Listener on `0.0.0.0:10000` accepting inbound HTTP connections
- Route: all traffic to cluster `backend`, route timeout 5s
- Retry policy: up to 2 retries on `503`, with `retry_budget.budget_percent: 20.0`
- Cluster `backend`: resolves `host.docker.internal:8080` via STRICT_DNS
- Circuit breaker thresholds: `max_connections: 3`, `max_pending_requests: 1`, `max_requests: 3`, `max_retries: 1`
- Outlier detection: eject after 3 consecutive 5xx, `base_ejection_time: 30s`

`host.docker.internal` is a Docker-provided DNS name that resolves to the host machine's IP — this lets the Envoy container reach the backend container via the host port binding.

**Verify**:
```bash
# Single request through Envoy should succeed
curl -s http://localhost:10000/
```

Expected:
```
ok delay=0ms
```

Check the Envoy admin interface is reachable:
```bash
curl -s http://localhost:9901/server_info | jq '.state'
```

Expected: `"LIVE"`

---

## Step 3: Send 20 parallel requests and observe overflow

With `max_connections: 3` and `max_pending_requests: 1`, Envoy can maintain at most 3 active connections plus queue 1 additional request. Any request that arrives when the connection pool is full and the pending queue is also full is immediately rejected with 503 and the `UO` response flag.

```bash
hey -n 20 -c 20 http://localhost:10000/
```

**What's happening**: `hey` sends 20 requests with concurrency 20 — all 20 requests are in flight simultaneously. Envoy opens up to 3 connections to the backend. Up to 1 additional request waits in the pending queue. The remaining 16 requests (20 - 3 - 1) are rejected immediately with 503 `UO`.

**Observe**:

`hey` prints a summary including a status code breakdown. Expect something close to:
```
Status code distribution:
  [200] 4 responses
  [503] 16 responses
```

The exact numbers depend on timing, but the majority of responses should be 503.

Check the access log for `UO` flags:
```bash
docker logs envoy --tail 25
```

Look for lines where the response code is `503` and the response flags field shows `UO`:
```
[...] "GET / HTTP/1.1" 503 UO 0 81 0 - ...
```

`UO` = upstream overflow. The proxy rejected the request before establishing a connection — the backend never received it.

**Verification**: Confirm via the admin stats endpoint:
```bash
curl -s http://localhost:9901/stats | grep -E "upstream_rq_pending_overflow|upstream_cx_overflow"
```

Expected (numbers will vary):
```
cluster.backend.upstream_rq_pending_overflow: 16
```

A non-zero `upstream_rq_pending_overflow` counter confirms the circuit breaker tripped. The counter is monotonically increasing — it does not reset when the circuit recovers.

---

## Step 4: Inspect the admin /clusters endpoint for live circuit breaker state

The admin `/clusters` endpoint shows per-cluster health, connection pool metrics, and circuit breaker state in real time. This is the first place to look when debugging 503 overflow events.

```bash
curl -s http://localhost:9901/clusters | grep -A 30 "^backend::"
```

Key fields to read:

```
backend::default_priority::max_connections: 3
backend::default_priority::max_pending_requests: 1
backend::default_priority::max_requests: 3
backend::default_priority::max_retries: 1
backend::default_priority::remaining_cx: 0            <- 0 means pool is full
backend::default_priority::remaining_rq: 0
backend::host.docker.internal:8080::cx_active: 3      <- all connections in use
backend::host.docker.internal:8080::rq_active: 3
backend::host.docker.internal:8080::rq_error: 0       <- backend not throwing errors
```

The `remaining_cx` and `remaining_rq` gauges are only populated when `track_remaining: true` is set in the circuit breaker config — which this config does. They let you alert before the breaker trips (e.g., alert when `remaining_cx < 2`) rather than only detecting overflow after requests have already been rejected.

```bash
# Watch circuit breaker stats update in real time (refresh every 2 seconds)
watch -n 2 'curl -s http://localhost:9901/stats | grep -E "upstream_rq_pending|upstream_cx_active|overflow|remaining"'
```

While the watch is running, send another load burst in a separate terminal:
```bash
hey -n 30 -c 30 -q 0 http://localhost:10000/
```

Observe `upstream_rq_pending_overflow` incrementing and `remaining_cx` dropping to zero during the burst.

---

## Step 5: Increase circuit breaker limits and observe higher throughput

Envoy does not support hot-reloading a static config file. To change thresholds you need to restart Envoy with an updated config. Stop the current Envoy and launch a new instance with higher limits.

```bash
docker stop envoy

docker run --rm -d \
  --name envoy \
  -p 10000:10000 \
  -p 9901:9901 \
  envoyproxy/envoy:v1.30-latest \
  envoy --config-yaml "
admin:
  address:
    socket_address: { address: 0.0.0.0, port_value: 9901 }
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
            - name: backend
              domains: ['*']
              routes:
              - match: { prefix: '/' }
                route:
                  cluster: backend
                  timeout: 5s
                  retry_policy:
                    retry_on: connect-failure,refused-stream,unavailable,cancelled,retriable-status-codes
                    retriable_status_codes: [503]
                    num_retries: 2
                    per_try_timeout: 1.5s
                    retry_budget:
                      budget_percent: { value: 20.0 }
                      min_retry_concurrency: 1
          http_filters:
          - name: envoy.filters.http.router
            typed_config:
              '@type': type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
  clusters:
  - name: backend
    type: STRICT_DNS
    connect_timeout: 1s
    lb_policy: ROUND_ROBIN
    load_assignment:
      cluster_name: backend
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address: { address: host.docker.internal, port_value: 8080 }
    circuit_breakers:
      thresholds:
      - priority: DEFAULT
        max_connections: 25
        max_pending_requests: 50
        max_requests: 25
        max_retries: 5
        track_remaining: true
" --log-level info
```

**What's happening**: The new config raises `max_connections` from 3 to 25 and `max_pending_requests` from 1 to 50. These values are still below what a real service would handle but are large enough that 20 concurrent requests should fit within the pool without overflowing.

Run the same load test:
```bash
hey -n 20 -c 20 http://localhost:10000/
```

Expected result: all 20 responses are 200. The status code distribution should show no 503s:
```
Status code distribution:
  [200] 20 responses
```

Verify no overflow occurred:
```bash
curl -s http://localhost:9901/stats | grep upstream_rq_pending_overflow
```

Expected: `cluster.backend.upstream_rq_pending_overflow: 0`

This demonstrates the direct relationship between circuit breaker thresholds and request success rate. The backend is unchanged — only the proxy limits changed.

---

## Step 6: Add a retry budget and demonstrate bounded retries under load

The current config already has `retry_budget.budget_percent: 20.0`. To observe the budget in action you need a backend that fails intermittently so retries actually fire, and enough load to exhaust the budget.

Stop the current backend and start one that randomly returns 503:

```bash
docker stop backend

docker run --rm -d \
  --name backend \
  -p 8080:8080 \
  python:3.12-slim \
  python3 -c "
import os, time, random, http.server, socketserver

FAIL_RATE = float(os.environ.get('FAIL_RATE', '0.5'))
PORT = 8080

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if random.random() < FAIL_RATE:
            self.send_response(503)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'error\n')
        else:
            body = b'ok\n'
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
    def log_message(self, fmt, *args):
        print(f'[{self.address_string()}] {fmt % args}', flush=True)

print(f'Starting on port {PORT} FAIL_RATE={FAIL_RATE}', flush=True)
with socketserver.TCPServer(('', PORT), Handler) as httpd:
    httpd.allow_reuse_address = True
    httpd.serve_forever()
" -e FAIL_RATE=0.5
```

**What's happening**: The backend now fails 50% of requests at random. Envoy will retry these failures up to `num_retries: 2` times per request — but the `retry_budget` caps total concurrent retries at 20% of in-flight requests.

Send sustained load at high concurrency:
```bash
hey -n 200 -c 25 http://localhost:10000/
```

During and after the run, check retry stats:
```bash
curl -s http://localhost:9901/stats | grep -E "upstream_rq_retry"
```

Key stats:
```
cluster.backend.upstream_rq_retry: 87            <- total retries issued
cluster.backend.upstream_rq_retry_success: 41    <- retries that resulted in 200
cluster.backend.upstream_rq_retry_overflow: 12   <- retries suppressed by budget
```

`upstream_rq_retry_overflow` is the critical one: a non-zero value means the retry budget was exhausted and Envoy stopped issuing retries for those requests. This is the budget working as designed — the backend load from retries is capped at 20% of the primary request load regardless of the error rate.

**Observe the math**: With 25 concurrent requests and a 20% budget, the maximum concurrent retries is 5. Total backend load from this gateway is bounded at 30 concurrent requests (25 primary + 5 retry), not 75 (25 primary + 50 retries at 2 per request).

Restore the healthy backend for the next step:
```bash
docker stop backend

docker run --rm -d \
  --name backend \
  -p 8080:8080 \
  -e DELAY_MS=0 \
  python:3.12-slim \
  python3 -c "
import os, time, http.server, socketserver

DELAY_MS = int(os.environ.get('DELAY_MS', '0'))
PORT = 8080

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if DELAY_MS > 0:
            time.sleep(DELAY_MS / 1000.0)
        body = f'ok delay={DELAY_MS}ms\n'.encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, fmt, *args):
        print(f'[{self.address_string()}] {fmt % args}', flush=True)

print(f'Starting on port {PORT} DELAY_MS={DELAY_MS}', flush=True)
with socketserver.TCPServer(('', PORT), Handler) as httpd:
    httpd.allow_reuse_address = True
    httpd.serve_forever()
"
```

---

## Step 7: Introduce backend slowdown and observe circuit breaker tripping

Now observe the full sequence: backend latency increases, connections accumulate in the pool, the circuit breaker trips, and requests are rejected with `UO`. Then the delay is removed and the circuit recovers.

First, restart Envoy with the tight circuit breaker limits from Step 2 so overflow is observable:

```bash
docker stop envoy

docker run --rm -d \
  --name envoy \
  -p 10000:10000 \
  -p 9901:9901 \
  -v "$(pwd)/envoy-circuit-breaker.yaml:/etc/envoy/envoy.yaml" \
  envoyproxy/envoy:v1.30-latest \
  envoy -c /etc/envoy/envoy.yaml --log-level info
```

Verify healthy baseline:
```bash
curl -s http://localhost:10000/
# Expected: ok delay=0ms
```

Now simulate backend degradation by increasing the delay to 3 seconds (above per-try timeout of 1.5s but below route timeout of 5s):

```bash
# Stop the fast backend
docker stop backend

# Start a slow backend with 3000ms delay
docker run --rm -d \
  --name backend \
  -p 8080:8080 \
  python:3.12-slim \
  python3 -c "
import os, time, http.server, socketserver

DELAY_MS = int(os.environ.get('DELAY_MS', '3000'))
PORT = 8080

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if DELAY_MS > 0:
            time.sleep(DELAY_MS / 1000.0)
        body = f'ok delay={DELAY_MS}ms\n'.encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, fmt, *args):
        print(f'[{self.address_string()}] {fmt % args}', flush=True)

print(f'Starting on port {PORT} DELAY_MS={DELAY_MS}', flush=True)
with socketserver.TCPServer(('', PORT), Handler) as httpd:
    httpd.allow_reuse_address = True
    httpd.serve_forever()
" -e DELAY_MS=3000
```

**What's happening**: The backend now takes 3 seconds per request. With `max_connections: 3`, Envoy opens 3 connections. Each connection holds for 3 seconds while waiting for a response. Any new request arriving in that 3-second window cannot get a connection — the pool is full. If `max_pending_requests: 1` is also full, the request is immediately rejected with `UO`.

Send concurrent load:
```bash
hey -n 30 -c 10 -t 10 http://localhost:10000/
```

The `-t 10` flag sets a client-side timeout of 10 seconds per request so `hey` does not give up before Envoy's route timeout fires.

**Observe**:
```bash
# Watch the live state during the load test (run in a second terminal)
watch -n 1 'curl -s http://localhost:9901/clusters | grep -E "cx_active|rq_active|rq_pending|overflow"'
```

Expected output during the load test:
```
backend::host.docker.internal:8080::cx_active: 3
backend::host.docker.internal:8080::rq_active: 3
backend::default_priority::remaining_cx: 0
cluster.backend.upstream_rq_pending_overflow: 7
```

The `UO` response flag appears in the access log for rejected requests:
```bash
docker logs envoy --tail 20
```

Look for:
```
[...] "GET / HTTP/1.1" 503 UO 0 81 0 - ...    <- circuit breaker overflow
[...] "GET / HTTP/1.1" 200 UT 0 0 1500 - ...  <- per-try timeout fired, retry issued
```

`UT` (upstream request timeout) fires when the per-try timeout (1.5s) expires before the backend responds. The 3s backend delay exceeds the 1.5s per-try timeout, so every request that gets a connection will time out and potentially trigger a retry — which then also times out.

Now restore the fast backend and observe recovery:

```bash
docker stop backend

docker run --rm -d \
  --name backend \
  -p 8080:8080 \
  python:3.12-slim \
  python3 -c "
import os, time, http.server, socketserver
DELAY_MS = 0; PORT = 8080
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'ok\n'
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, fmt, *args): pass
with socketserver.TCPServer(('', PORT), Handler) as httpd:
    httpd.allow_reuse_address = True
    httpd.serve_forever()
"
```

Wait a few seconds for open connections to drain, then test:

```bash
sleep 3
curl -s http://localhost:10000/
```

Expected: `ok`

The circuit breaker does not have a half-open state in Envoy's connection pool implementation — it recovers automatically as connections are released and the pool drains. Outlier detection ejection timers run independently: a host ejected by outlier detection remains out of rotation for `base_ejection_time` (30s in this config) regardless of backend recovery.

```bash
# Confirm recovery in stats — cx_active should drop to 0 when idle
curl -s http://localhost:9901/stats | grep "cx_active"
```

---

## Cleanup

```bash
docker stop envoy backend 2>/dev/null || true
```

Both containers were started with `--rm` so they are automatically removed after stopping.

Verify all containers are gone:
```bash
docker ps -a | grep -E "envoy|backend"
```

Expected: no output.

---

## Key Takeaways

1. **Circuit breaker thresholds gate concurrency, not throughput**. `max_connections` limits concurrent open TCP connections; `max_pending_requests` limits the queue depth. A fast backend fits many requests through 3 connections; a slow backend fills those connections immediately and starves every subsequent request.

2. **`UO` (upstream overflow) is the circuit breaker's fingerprint in the access log**. It fires when both the connection pool and the pending queue are full. It always means the proxy rejected the request before the backend received it — the backend saw nothing.

3. **`remaining_cx` and `remaining_rq` gauges let you alert before overflow**. Set `track_remaining: true` in the circuit breaker config and alert when `remaining_cx < 20%` of `max_connections` — you get warning before requests start failing.

4. **`retry_budget.budget_percent` prevents retry amplification**. Per-request `num_retries: 2` looks safe but 1,000 failing requests become 3,000 backend calls without a budget. A 20% budget caps retry overhead at 200 additional calls regardless of how many requests fail.

5. **Outlier detection and circuit breaking are complementary, not redundant**. Outlier detection removes individual bad pods (per-host); circuit breaking caps total cluster load (aggregate). You need both: without outlier detection, a single bad pod absorbs its fair share of traffic forever; without circuit breaking, a fully degraded cluster absorbs all connections across your fleet.

6. **Backend slowdowns fill connection pools faster than errors**. A backend that returns errors instantly frees its connection immediately. A backend that holds connections for 3 seconds while timing out fills the pool for the full duration. Slow backends are more dangerous to connection pool circuit breakers than fast-failing ones.

7. **The admin `/clusters` endpoint is the authoritative source for circuit state**. It shows live `cx_active`, `rq_pending`, `remaining_cx`, and endpoint health flags — what Envoy is actually doing, not what the config file says. Always check here before escalating.
