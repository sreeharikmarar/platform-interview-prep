# Inference Gateways & L7 Routing for AI Workloads

## What you should be able to do

- Explain why inference traffic requires a dedicated gateway layer distinct from a standard HTTP reverse proxy, naming the specific properties (request duration, cost asymmetry, GPU saturation mechanics) that make conventional L7 routing insufficient.
- Describe the full request path through an inference gateway: TLS termination, model-name extraction from the request body, tenant identification, token budget enforcement, queue-depth-aware backend selection, streaming response parsing, and post-response budget decrement.
- Design a token-rate-limiting scheme for multi-tenant inference, including how tokens are counted on the response path from a streaming SSE or chunked HTTP body, and how budgets are persisted and enforced across multiple gateway replicas.
- Explain the InferenceModel and InferencePool CRD pattern from the Kubernetes Gateway API inference extension, and how it maps to existing Gateway API primitives (HTTPRoute, BackendLBPolicy).
- Debug GPU queue buildup, noisy-neighbor token exhaustion, silent model canary regressions, and KV cache thrashing using real metrics from vLLM, TGI, and Envoy.

## Mental Model

Think of an inference gateway as a toll booth system on a GPU highway where every car is a different size, travels at a different speed, costs a wildly different amount, and the road itself has a hard capacity measured not in bandwidth but in parallel compute contexts. A standard HTTP reverse proxy assumes requests are milliseconds long and roughly uniform in cost. A POST to `/v1/chat/completions` that sends a 4-token prompt and gets a 4-token answer might complete in 80ms and cost one-tenth of a GPU-second. The identical endpoint receiving a 4000-token system prompt and generating a 2000-token response might run for 45 seconds and hold a KV cache slot the entire time. The gateway cannot treat these as equivalent work units, and its routing, admission, and back-pressure logic must reflect that asymmetry.

The first implication is that routing cannot be purely path-based. Upstream services in a traditional gateway are selected by HTTP method and URL path. Inference requests all arrive on the same path (`/v1/chat/completions` or `/generate`) regardless of which model they target. The actual routing key — the model name, the requested adapter, the required context length — lives inside the JSON request body. An inference gateway must parse the body before it can route the request, which means it operates more like a message broker with content-based routing than like an HTTP reverse proxy with path-based routing.

The second implication is that admission control must be queue-aware, not just rate-limited. A GPU pod running vLLM or Text Generation Inference (TGI) has a finite number of continuous batching slots. When those slots fill, new requests either queue inside the serving process or get rejected. A gateway that blindly forwards requests to a backend with a saturated queue makes the problem worse: the GPU pod's queue grows, per-request latency climbs, and time-to-first-token (TTFT) degrades for all tenants simultaneously. The correct behavior is for the gateway to observe queue depth per backend — via a metrics scrape or a health endpoint — and refuse admission when queue depth exceeds a threshold, returning a 429 with a `Retry-After` header rather than a request that will sit in the GPU queue for minutes. This is load shedding at the right layer.

The third implication is that cost is denominated in tokens, not requests. A multi-tenant platform cannot give each tenant a request-per-second limit because a tenant that sends exclusively long-generation requests consumes orders of magnitude more GPU time than one sending short Q&A requests. The correct unit of accounting is tokens: tokens consumed in the prompt (input tokens, which drive KV cache population) and tokens generated in the response (output tokens, which drive autoregressive decode time). The gateway enforces a per-tenant token budget measured in tokens-per-minute. This requires the gateway to parse the streaming response — typically Server-Sent Events (SSE) with `data:` chunks containing JSON — count the tokens emitted, and decrement the tenant's budget in real time. The budget state must be shared across all gateway replicas (typically via Redis or a distributed counter service) to prevent tenants from exploiting multi-replica fan-out.

The Kubernetes Gateway API working group has formalized this problem space with the Inference Extension: two new CRDs, `InferenceModel` and `InferencePool`, that sit above the existing HTTPRoute machinery. An `InferenceModel` is a routing target that carries the model name (matching the `model` field in the request body), traffic weights for canary splits, and a reference to a criticality class. An `InferencePool` is a set of GPU pods (selected by label) with a declared capacity and scheduling policy. Gateway implementations that support the inference extension (Envoy-based implementations using ext_proc, custom gateways built with the Gateway API conformance suite) translate these CRDs into per-request routing decisions, exactly as Istio translates VirtualService into xDS Route entries.

## Key Concepts

- **Model routing**: Routing decisions are made on the value of the `model` field in the JSON request body, not on the HTTP path. All standard inference API paths (`/v1/chat/completions`, `/v1/completions`, `/generate`, `/v2/models/MODEL/generate`) accept a `model` parameter. The gateway must buffer the request body (or use a streaming body parser), extract the model name, perform a lookup against its routing table, and forward to the correct backend cluster. This is implemented in Envoy via `ext_proc` (external processing filter) or a Wasm plugin that reads `body.model`, sets a dynamic metadata key, and the router filter uses that metadata key in a `metadata_match` route condition.

- **Token-rate limiting**: Per-tenant limits expressed as tokens-per-minute (TPM) for input tokens and output tokens separately. Input tokens are known before forwarding (count the prompt tokens client-side or use a tokenizer on the gateway). Output tokens are counted on the response streaming path, requiring the gateway to parse each SSE `data:` chunk, extract the `choices[0].delta.content` or `usage.completion_tokens` fields, accumulate the count, and decrement the tenant's budget bucket. The `usage` field on the final `[DONE]` chunk gives the authoritative total; intermediate counting is approximate. Budget state is kept in Redis with a sliding window counter using `INCRBY` and `EXPIRE`.

- **GPU-aware scheduling**: Unlike CPU-bound backends where `LEAST_REQUEST` (active request count) is a reasonable proxy for load, GPU backends must account for token-length variance. Two concurrent requests may have completely different GPU memory and compute requirements. The correct load signal for a GPU backend is queue depth (the number of requests waiting in the continuous batch queue), not active request count. vLLM exposes `vllm:num_requests_waiting` on its Prometheus `/metrics` endpoint. TGI exposes `tgi_queue_size`. The gateway periodically scrapes these metrics (or reads them from a shared state sidecar) and uses the values to implement a least-outstanding-queue (LOQ) selection policy: route the incoming request to the backend with the shortest queue depth.

- **Canary for models**: Shifting traffic between model versions (e.g., `llama-3.1-8b` to `llama-3.1-8b-instruct-v2`, or a fine-tuned checkpoint to the base model) is expressed as a weighted split on the `InferenceModel` object. Unlike canaries for stateless HTTP services where you compare latency and error rate, model canaries require comparing *quality metrics*: win-rate from an LLM judge, task-specific benchmark scores, user thumbs-up rate from a feedback API. The gateway captures a request sample (10% of traffic) and emits request/response pairs to a logging sink. An async evaluation pipeline grades the responses. The canary weight is adjusted (manually or by a controller) based on quality, not just latency or 5xx rate. The `InferenceModel` CRD carries `targetModels` with per-version weights exactly for this workflow.

- **Time-to-first-token (TTFT)**: The latency from the gateway receiving the complete request to the gateway receiving the first streamed response chunk from the backend. This is the latency the user *perceives* as "the model is thinking." TTFT is dominated by: time waiting in the backend queue, time to populate the KV cache for the prompt (prefill phase), and network RTT. TTFT is distinct from total generation latency (which adds the decode phase for all output tokens) and from inter-token latency (ITL, also called time-per-output-token, TPOT). For interactive use cases, TTFT is the primary SLO metric. The gateway measures it by recording the timestamp when the first byte of the response body arrives and comparing to the request-send timestamp. Envoy's `%RESP(x-first-byte-timestamp)%` access log operator or an ext_proc filter can capture this. vLLM emits `vllm:time_to_first_token_seconds` as a histogram.

- **KV cache affinity**: GPU serving frameworks maintain a KV cache (key-value attention cache) in GPU HBM for recently processed token sequences. If a second request from the same session (or any request sharing a long common prefix, such as a fixed system prompt) lands on the same GPU pod, the prefill phase can skip recomputing the cached prefix and resume from where the cache left off. This is prefix caching, and it dramatically reduces TTFT for multi-turn conversations and batch workloads with shared prefixes. The gateway enforces KV cache affinity by consistent-hashing the session ID (or a canonical prefix hash) to a specific GPU pod. This maps to Envoy's `RING_HASH` or `MAGLEV` cluster load-balancing policy with `hash_policy` set on the route to use a session-specific header. Session affinity is configured at the Envoy level using `lb_policy: RING_HASH` or `MAGLEV` with a `hash_policy` on the route, rather than as a declarative CRD field.

- **InferenceModel CRD**: A Kubernetes custom resource in the `inference.networking.x-k8s.io` API group (Gateway API inference extension, currently in experimental status). It represents a logical model name that the gateway routes by. Key fields: `spec.modelName` (the value matched against `request.body.model`), `spec.poolRef` (reference to an InferencePool), `spec.targetModels` (list of `{name, weight}` entries for canary splits between actual backend model names), and `spec.criticality` (`Critical`, `Standard`, or `Sheddable` — used by the pool's admission controller to decide which traffic to drop under saturation). The gateway watches InferenceModel objects and synthesizes routing rules from them, conceptually equivalent to how Istio's VirtualService is translated into Envoy route entries.

- **InferencePool CRD**: Represents a pool of GPU-backed pods that serve inference requests. Key fields: `spec.selector` (label selector for pods in the pool), `spec.targetPortNumber` (the port serving the inference API), and a `spec.endpointPickerRef` (the current field name in the experimental API; earlier drafts used `extensionRef`) pointing to the Endpoint Picker Process (EPP) service that makes routing decisions. The gateway's endpoint selection for an InferencePool is not simple round-robin: the EPP scrapes each pod's Prometheus `/metrics` endpoint for live queue depth (e.g., `vllm:num_requests_waiting`) before selecting a pod. This is the mechanism that bridges Kubernetes Service routing with GPU-aware scheduling.

- **Continuous batching and its impact on routing**: vLLM and TGI use continuous batching (also called iteration-level scheduling or in-flight batching): the GPU does not wait for a request to finish before starting the next one. Instead, as decode steps complete and tokens are emitted, new requests are inserted into the batch. This means a GPU pod can simultaneously serve a request in its prefill phase and several requests in their decode phase. From the gateway's perspective, `num_requests_waiting` is the actionable signal (requests not yet in the batch) and `num_requests_running` is informational (requests actively consuming GPU cycles). Queue depth for admission purposes is `num_requests_waiting`.

- **LoRA adapter routing**: A single GPU pod loaded with a base model can serve multiple fine-tuned LoRA (Low-Rank Adaptation) adapters simultaneously. vLLM's LoRA serving allows specifying `--enable-lora` and dynamically loading adapters by name. The inference gateway routes to the correct adapter by reading `model` from the request body (adapter names follow a `base-model/adapter-name` convention) and selecting a backend pod that has the requested adapter loaded. This is multi-model serving on shared GPU memory. The `InferenceModel` CRD maps to adapters by configuring `targetModels[].name` to match the adapter-qualified model name.

- **Overload shedding by criticality class**: When GPU pool utilization exceeds a threshold (e.g., `num_requests_waiting > 10` across all pods), the gateway applies criticality-based admission: `Critical` requests (interactive, real-time) are always admitted; `Standard` requests are admitted up to a secondary threshold; `Sheddable` requests (batch, background) are rejected with `503 Service Unavailable` immediately. This implements a form of quality-of-service tiering at the gateway layer without requiring any changes to the GPU serving process. The criticality class is carried either as an HTTP header (`X-Inference-Criticality: Sheddable`) set by the upstream calling service or derived from the tenant's tier in the gateway's rate-limiting policy.

## Internals

### Request Flow Through an Inference Gateway

The following describes the complete request path through a production inference gateway, with each step naming the specific mechanism that implements it.

1. **TLS termination and connection acceptance**: The client connects to the gateway on port 443. The gateway's listener (in Envoy terms: a Listener with a `DownstreamTlsContext`) terminates TLS using a certificate delivered via SDS. Mutual TLS (mTLS) from the client is optional but recommended for service-to-service calls. After TLS, the plaintext HTTP/2 (or HTTP/1.1 with chunked transfer) stream is passed to the HTTP Connection Manager.

2. **JWT authentication and tenant ID extraction**: The `jwt_authn` HTTP filter (or an ext_authz call to an OPA/authorization service) validates the bearer token in the `Authorization` header. The JWT payload carries the tenant identifier (e.g., `sub` claim or a custom `x-tenant-id` claim). The filter extracts the tenant ID and writes it to dynamic metadata under a namespace (e.g., `envoy.filters.http.jwt_authn`). All subsequent filters in the chain read tenant ID from dynamic metadata, not from the raw request, so the tenant identity is a verified claim.

3. **Request body buffering and model-name extraction**: A Wasm plugin or ext_proc filter intercepts the request after authentication. Because the routing key is inside the JSON body, the filter buffers the complete request body (up to a configured maximum, e.g., 1MB — large enough for most prompts, configurable per tenant). It parses the JSON and extracts `body["model"]`. The extracted model name is written to dynamic metadata (e.g., `inference.model_name`). For streaming request bodies (rare in inference), the filter must buffer and re-emit. The body buffer limit is a critical configuration: set it too low and large prompts are rejected; set it too high and the gateway uses excessive memory during high concurrency.

4. **Model-to-pool routing**: The router filter reads `inference.model_name` from dynamic metadata and performs a lookup against the InferenceModel routing table (maintained in-memory and refreshed by watching the Kubernetes API via the gateway controller). The lookup returns the InferencePool reference and, if a canary is in progress, the weighted distribution of backend model names. A weighted random selection determines which actual backend model name (`target_model`) to use. The target model name is written as a request header (`X-Inference-Target-Model: llama-3.1-8b-v2`) so the backend pod's serving process can select the correct adapter or checkpoint. The request is matched to the Envoy cluster corresponding to the chosen InferencePool.

5. **Token budget check (pre-flight)**: Before the request is forwarded, the rate-limiting filter (either Envoy's `envoy.filters.http.ratelimit` calling an external Envoy Rate Limit service, or a custom ext_proc filter backed by Redis) checks the tenant's remaining token budget. The check is a Redis `GET` or `LRANGE` against the tenant's sliding-window counter key. For input tokens, the count can be estimated before forwarding by running the prompt through a tokenizer embedded in the ext_proc sidecar (using tiktoken or a model-specific tokenizer). If the estimated input token count would exceed the tenant's remaining budget, the gateway returns `429 Too Many Requests` with headers `X-RateLimit-Limit-Tokens`, `X-RateLimit-Remaining-Tokens`, and `Retry-After`. The `Retry-After` value is computed as `ceil((overage_tokens / tokens_per_second_refill_rate))`.

6. **Queue-depth-aware backend selection**: Within the chosen InferencePool cluster, the gateway does not use simple round-robin. Instead, it implements queue-aware load balancing. In the Envoy ext_proc model, the filter queries a lightweight sidecar (the "EPP" — Endpoint Picker Process, as named in the Gateway API inference extension reference implementation) over a local gRPC call. The EPP has a continuously refreshed in-memory map of `{pod_ip -> queue_depth}` built by scraping each pod's `/metrics` endpoint every 1-5 seconds. It returns the IP of the pod with the lowest `num_requests_waiting`. The ext_proc filter sets the `x-gateway-destination-endpoint` header to direct the request to that specific pod IP, bypassing the cluster's load-balancing policy for this request. If all pods have queue depth above the configured admission threshold, the ext_proc filter signals the gateway to return `503 Service Unavailable` immediately.

7. **Request forwarding to GPU pod**: The gateway establishes or reuses an HTTP/2 connection from the per-cluster connection pool to the selected GPU pod. For KV cache affinity (prefix caching), a session-identifying header (`X-Session-ID`) or a consistent hash on the model name plus a hash of the first N tokens of the system prompt is used to route to the same pod across turns. The gateway sets `X-Inference-Target-Model` on the upstream request so the serving process knows which adapter to activate. Connection pooling must account for long-lived connections: Envoy's `max_requests_per_connection` on the upstream cluster should be set to a high value (e.g., 10000) or 0 (unlimited) to prevent the gateway from cycling connections during a multi-minute generation.

8. **Streaming response handling and token counting**: The GPU pod sends the response as a stream of Server-Sent Events (SSE). Each event is a `data:` line containing a JSON object with a `choices[0].delta.content` field (OpenAI-compatible format). The final event is `data: [DONE]`. The gateway's ext_proc filter (or a Wasm plugin configured as a `response_body` filter) intercepts each SSE chunk as it passes through. The filter parses the JSON, extracts the delta content, counts the approximate number of tokens (using the same tokenizer as step 5, or by using the `usage.completion_tokens` field present on the final chunk of some serving implementations). A running total is maintained per-request in the filter's per-request state.

9. **Token budget decrement and observability emission**: On the SSE `[DONE]` event (or on stream close with a non-zero byte count), the ext_proc filter issues an asynchronous Redis `INCRBY tenant:{id}:output_tokens:window {count}` to decrement (or rather increment the usage counter against the budget ceiling). The call is made asynchronous (fire-and-forget with a timeout) to avoid adding latency on the response path for the final token. The filter also emits a metrics increment: `inference_gateway_tokens_total{tenant="...",model="...",direction="output"}` via a statsd or Prometheus push. Time-to-first-token is recorded by measuring the wall-clock time between when the request was forwarded to the backend and when the first SSE `data:` line was received. This value is emitted as `inference_gateway_ttft_seconds{model="...",tenant="..."}`.

10. **Access log and audit trail**: After the stream completes, the access log entry is written. The access log format includes `%DYNAMIC_METADATA(inference:model_name)%`, `%DYNAMIC_METADATA(jwt_authn:tenant_id)%`, `%BYTES_SENT%` (total response bytes), `%DURATION%` (total request duration including generation), and the custom `%DYNAMIC_METADATA(inference:output_tokens)%` field. This access log is the billing audit trail: total tokens consumed per request, per tenant, per model, with a timestamp and the upstream pod that served it.

### Envoy as an Inference Gateway

Envoy's native routing (HCM route matching on path and headers) is insufficient for inference traffic because the routing key is in the request body. There are two implementation patterns for routing by body content:

**Pattern 1: ext_proc (External Processing)**. An `envoy.filters.http.ext_proc` filter is inserted early in the HTTP filter chain. It calls an external gRPC service (the ext_proc server, which can be a sidecar or a separate process) for each request at the `REQUEST_BODY` phase. The ext_proc server receives the body, extracts `model`, writes it to a response header mutation (`x-inference-model: llama-3.1-8b`), and the router filter uses a header-based route match (`x-inference-model: llama-3.1-8b`) to select the correct cluster. This is the approach used by the Gateway API inference extension reference implementation (the EPP). The ext_proc server is also where queue-depth-aware endpoint selection happens: the EPP sets the `x-gateway-destination-endpoint` header in its response to direct Envoy to a specific pod IP.

**Pattern 2: Wasm plugin**. A Wasm filter (`envoy.filters.http.wasm`) compiled from Go or Rust reads the request body bytes, parses JSON using an embedded parser, sets dynamic metadata on the stream context, and the router filter reads metadata via `metadata_match` in the route configuration. Wasm avoids the gRPC round-trip overhead of ext_proc but is constrained by the Wasm sandbox (no direct access to external systems, no async I/O). For simple model-name extraction and header setting, Wasm is lower latency. For queue-depth queries requiring Redis or HTTP calls, ext_proc is required.

**Circuit breakers sized for GPU concurrency**: Envoy's cluster-level circuit breakers (`max_connections`, `max_pending_requests`, `max_requests`, `max_retries`) must be configured for inference workloads differently from standard HTTP services. A GPU pod running vLLM with 80GB HBM can sustain perhaps 20-40 concurrent requests in continuous batch mode before TTFT degrades sharply. Setting `max_requests` to 50 per pod ensures the circuit breaker sheds load before the GPU pod's internal queue grows unboundedly. `max_pending_requests` should be set to a small value (5-10) since requests pending in Envoy's connection pool are invisible to the backend's queue management. The `track_remaining` field on circuit breakers should be enabled so that `envoy_cluster_circuit_breakers_default_remaining_rq` is exposed as a metric.

### Queue-Aware Load Balancing

Standard Envoy `LEAST_REQUEST` policy tracks active request count per endpoint (the number of requests in flight on existing connections). For GPU inference, this is inadequate for two reasons. First, a request in its prefill phase (processing a 4000-token prompt) holds very different GPU resources than a request in its decode phase emitting one token per step. Active request count treats them identically. Second, vLLM and TGI queue requests internally before they enter the continuous batch. A pod may report zero active Envoy connections but have 15 requests queued internally.

The correct load signal is `vllm:num_requests_waiting` (for vLLM) or `tgi_queue_size` (for TGI), scraped from each pod's `/metrics` endpoint. The EPP (Endpoint Picker Process in the inference extension reference implementation) maintains a goroutine per pod that scrapes metrics every 2 seconds and updates an in-memory map. On each request, it finds the minimum-queue-depth pod that also meets any affinity constraints (e.g., has the requested LoRA adapter loaded) and returns its IP to the ext_proc filter.

A simpler approximation (no EPP required) is to use Envoy's `LEAST_REQUEST` with `active_request_bias` set to a high value (e.g., 3.0). This makes the load balancer strongly prefer pods with fewer active Envoy requests, which correlates imperfectly but usefully with queue depth. For production deployments, the EPP approach is preferred because it uses authoritative queue-depth data rather than a proxy metric.

vLLM's built-in queue management (using its async engine and scheduler) operates independently of the gateway. The gateway's role is to prevent admission when the pod is saturated, not to manage the pod's internal scheduling. There is a risk of double-queuing: a request queued in the gateway's connection pool and also queued inside vLLM. Minimizing `max_pending_requests` in Envoy's circuit breaker and using EPP-driven admission control reduces this risk.

### Token Counting on the Response Path

OpenAI-compatible inference APIs return streaming responses as SSE. Each event body is a JSON object:

```
data: {"id":"chatcmpl-abc","object":"chat.completion.chunk","choices":[{"delta":{"content":"Hello"},"index":0}]}

data: {"id":"chatcmpl-abc","object":"chat.completion.chunk","choices":[{"delta":{"content":" world"},"index":0}]}

data: [DONE]
```

The final chunk before `[DONE]` may include a `usage` field:

```
data: {"id":"chatcmpl-abc","choices":[{"delta":{},"finish_reason":"stop","index":0}],"usage":{"prompt_tokens":12,"completion_tokens":47,"total_tokens":59}}
```

Not all serving implementations emit the `usage` field. vLLM emits it when `stream_options.include_usage: true` is set in the request. TGI emits a single response object (not SSE by default) or SSE with a final `generated_text` event containing token count metadata.

The gateway's token counting strategy:

1. **Prefer `usage.completion_tokens` on the final chunk.** This is the authoritative count from the serving process. The ext_proc filter or Wasm plugin watches for the final non-`[DONE]` chunk, extracts `usage.completion_tokens`, and uses that as the definitive output token count.

2. **Fall back to approximate counting.** For implementations that do not emit `usage`, count the number of SSE chunks received (each chunk is approximately one token in greedy decoding, though speculative decoding can produce multiple tokens per chunk). Alternatively, run the accumulated `delta.content` through an embedded tokenizer. This introduces a small error (typically ±2%) that is acceptable for rate limiting.

3. **Inject `stream_options`**: The inference gateway can rewrite the request body before forwarding to inject `"stream_options": {"include_usage": true}` if the client did not set it. This guarantees the `usage` field on the final chunk at the cost of a body mutation pass. The ext_proc filter performs this mutation at `REQUEST_BODY` phase.

Input token counting (for pre-flight budget check) uses the tokenizer embedded in the ext_proc sidecar. The tokenizer must match the model family: tiktoken for GPT-4-class models, the LLaMA SentencePiece tokenizer for LLaMA-family models. The gateway maintains a model-to-tokenizer mapping loaded from a ConfigMap.

### Multi-Model Serving with LoRA Adapters

A production GPU fleet rarely runs one model per pod. GPU memory is expensive; loading multiple LoRA adapters on a single base model is the standard pattern for serving a portfolio of fine-tuned variants. vLLM supports this via `--enable-lora --max-loras 4 --max-lora-rank 16`, allowing up to 4 adapters to be hot-loaded simultaneously per pod.

From the gateway's perspective, routing to a LoRA adapter is identical to routing to a model: the `model` field in the request body carries the adapter-qualified name (e.g., `llama-3.1-8b/customer-support-v3`). The gateway's routing table maps this to an InferencePool whose pods have that adapter loaded. The gateway also sets `X-Inference-Target-Model: llama-3.1-8b/customer-support-v3` as a request header; vLLM reads this header (in its OpenAI-compatible server, via the `model` field in the request, which the gateway has already set correctly).

A complication arises when an adapter is requested but is not loaded on any pod in the pool. vLLM can dynamically load adapters from disk or from a model registry, but the load takes several seconds during which the pod cannot serve requests for that adapter. The gateway should treat "adapter not loaded" as a temporary unavailability (503 with retry) rather than a routing error (404), since the condition is transient. The EPP can track which adapters are loaded on each pod (by querying vLLM's `/v1/models` endpoint during its polling loop) and avoid routing to pods that have not yet loaded the requested adapter.

## Architecture Diagram

```
  CLIENT (application, agent, browser)
        |
        | HTTPS/2  POST /v1/chat/completions
        | {"model": "llama-3.1-8b", "messages": [...], "stream": true}
        |
        v
  +-------------------------------------------------------------------+
  |                    INFERENCE GATEWAY                              |
  |                                                                   |
  |  [1] TLS Termination  (SDS cert, DownstreamTlsContext)           |
  |        |                                                          |
  |  [2] JWT Authn        (tenant-id extracted from sub claim)        |
  |        |                                                          |
  |  [3] Body Buffer + Model Extraction  (ext_proc or Wasm)          |
  |        |  reads body["model"] -> dynamic_metadata["model_name"]  |
  |        |                                                          |
  |  [4] InferenceModel Lookup  (model_name -> InferencePool + weights)|
  |        |  canary split: 90% pool-a (v1), 10% pool-a (v2)        |
  |        |                                                          |
  |  [5] Token Budget Check  (Redis sliding window, 429 if exceeded)  |
  |        |  input token pre-count via embedded tokenizer            |
  |        |                                                          |
  |  [6] Queue-Depth Endpoint Selection  (EPP sidecar)               |
  |        |  scrapes vllm:num_requests_waiting per pod every 2s     |
  |        |  sets x-gateway-destination-endpoint to min-queue pod    |
  |        |  sheds load (503) if all pods exceed queue threshold     |
  |        |                                                          |
  |  [7] Request Forward  (HTTP/2 conn pool, X-Inference-Target-Model)|
  |        |                                                          |
  |  [8] Streaming Response Parse  (ext_proc response_body phase)    |
  |        |  counts SSE chunks / reads usage.completion_tokens      |
  |        |  measures TTFT on first data: chunk                     |
  |        |                                                          |
  |  [9] Budget Decrement + Metrics Emit  (async Redis INCRBY)       |
  |        |                                                          |
  | [10] Access Log  (model, tenant, input_tokens, output_tokens,    |
  |                   ttft_ms, total_duration_ms, upstream_pod)      |
  +-------------------------------------------------------------------+
        |                    |                    |
        v                    v                    v
  +----------+        +----------+        +----------+
  | GPU POOL A|        | GPU POOL B|        | GPU POOL C|
  | (llama-8b)|        |(llama-70b)|        |(llama-8b) |
  |           |        |           |        | +adapters |
  | pod-a1    |        | pod-b1    |        | pod-c1    |
  |   q=2     |        |   q=8     |        |   q=0  <--+-- selected
  | pod-a2    |        | pod-b2    |        | pod-c2    |
  |   q=5     |        |   q=12    |        |   q=3     |
  | pod-a3    |        | pod-b3    |        | pod-c3    |
  |   q=1  <--+        |   q=6     |        |   q=1     |
  |  selected |        |           |        |           |
  +----------+        +----------+        +----------+

  EPP (Endpoint Picker Process) sidecar scrapes
  vllm:num_requests_waiting per pod every 2s.
  Redis cluster holds per-tenant token budgets.

  InferenceModel CRDs:  llama-3.1-8b  -> pool-a (90%) + pool-c (10% canary)
                        llama-3.1-70b -> pool-b
                        llama-8b/svc-adapter -> pool-c (LoRA multi-model)
```

## Failure Modes & Debugging

### 1. GPU Queue Buildup and TTFT Degradation

**Symptoms**: The `inference_gateway_ttft_seconds` histogram's p95 and p99 climb steadily, even when overall request rate is not increasing. Users report the model "hanging" before the first token appears. The gateway's `inference_gateway_queue_depth{pool="pool-a"}` metric is high and growing. GPU pod CPU is low but `vllm:num_requests_waiting` is large (10-50 or more). Requests complete eventually but with long initial delays.

**Root Cause**: The gateway's admission control threshold is set too high (or not configured), allowing more requests into the backend queue than the GPU can drain in a reasonable time. TTFT scales linearly with queue depth at the serving process: each queued request ahead of yours must complete its prefill phase before yours begins. If the average prompt length is 1000 tokens and the GPU can process 5000 tokens/s in prefill, each queued request adds 200ms to your TTFT. At 20 queued requests, TTFT is 4 seconds before generation even begins. This is compounded if some requests in the queue have very long prompts (the prefill phase serializes in vLLM's chunked-prefill scheduler). The root cause is often a burst of long-context requests (e.g., document summarization, RAG with large retrieved chunks) that arrived simultaneously and all queued on the same pod.

**Blast Radius**: All tenants sharing the affected GPU pool experience TTFT degradation simultaneously. If the gateway does not isolate pools by criticality, a batch workload's burst can degrade interactive requests. The buildup can be self-reinforcing: clients with short timeouts retry, adding more requests to the queue, further increasing TTFT.

**Mitigation**: Set `max_pending_requests` in the Envoy cluster circuit breaker to a value proportional to the pool's sustainable throughput (start with `num_pods * 5`). Configure the EPP to reject admission when `num_requests_waiting > threshold` across all pods (threshold = `num_pods * 10` is a reasonable starting point). Separate GPU pools by criticality class: one pool for `Critical` traffic (interactive, small queue threshold), one for `Standard`, one for `Sheddable` (batch, can tolerate deep queues). Use vLLM's chunked prefill (`--enable-chunked-prefill`) to prevent long-context prefill from monopolizing the GPU scheduler.

**Debugging**:
```bash
# Scrape vLLM queue metrics directly from a GPU pod
kubectl exec -n inference deploy/inference-gateway -- \
  curl -s http://gpu-pod-a1.inference.svc:8080/metrics | \
  grep -E 'vllm:num_requests_waiting|vllm:num_requests_running|vllm:time_to_first_token'

# Check TTFT histogram from the gateway's Prometheus metrics
curl -s http://inference-gateway.inference.svc:9901/stats | \
  grep inference_gateway_ttft_seconds

# Check EPP's current view of queue depth per pod
kubectl logs -n inference deploy/inference-epp | grep 'queue_depth'

# Check Envoy circuit breaker remaining capacity per cluster
curl -s http://localhost:9901/stats | \
  grep 'circuit_breakers.*pool_a.*remaining'

# Watch queue depth live across all GPU pods in a pool
kubectl get pods -n inference -l pool=pool-a -o name | \
  xargs -I{} kubectl exec -n inference {} -- \
    curl -s localhost:8080/metrics | grep num_requests_waiting

# Check the p99 TTFT from an upstream pod's own histogram
kubectl exec -n inference pod/gpu-pod-a1 -- \
  curl -s localhost:8080/metrics | grep 'vllm:time_to_first_token_seconds_bucket'
```

---

### 2. Noisy Neighbor Exhausting Shared Token Budget

**Symptoms**: Tenants that share a rate-limiting tier begin receiving `429 Too Many Requests` responses even when their own recent usage was low. The `inference_gateway_tokens_total{tenant="tenant-b"}` metric shows spikes coinciding with the rate limit rejections. Tenant-A complains their requests are failing but Tenant-A's own dashboard shows low usage. Investigation reveals that the rate limit key is misconfigured to be shared across a tenant group rather than per-tenant.

**Root Cause**: Multi-tenant token budgets are only effective if each tenant has an isolated budget key. A common misconfiguration is using a group-level rate limit key (e.g., `tier:standard`) instead of a per-tenant key (e.g., `tenant:{tenant-id}`). This means one tenant consuming aggressively drains the shared bucket, causing rate limit rejections for all other tenants in the same tier. A second failure mode is Redis key expiry misconfiguration: if the sliding window key is set with `EXPIRE` at a shorter interval than the window duration, the counter resets prematurely and the effective limit is higher than intended, allowing a tenant to burst through.

**Blast Radius**: All tenants sharing the misconfigured rate limit key are affected. High-volume tenants effectively deny service to low-volume tenants in the same tier. In a platform with dozens of tenants, the blast radius is all tenants in the affected tier simultaneously.

**Mitigation**: Use per-tenant rate limit keys with the tenant ID extracted from the verified JWT claim (not from a client-supplied header, which can be spoofed). The rate limit descriptor passed to the Envoy Rate Limit service should include `tenant_id` as the innermost key. Regularly audit rate limit descriptor configuration by running the rate limit service with debug logging and verifying that each request maps to a unique tenant-scoped key. Alert when any single tenant consumes more than 50% of the tier-wide throughput (a heuristic for noisy neighbor detection): `sum(rate(inference_gateway_tokens_total[1m])) by (tenant) / sum(rate(inference_gateway_tokens_total[1m])) > 0.5`.

**Debugging**:
```bash
# Check the rate limit service's active keys and counters (envoy RLS debug endpoint)
kubectl exec -n inference deploy/rate-limit-service -- \
  curl -s localhost:6070/json | jq '.overLimitRequests | to_entries | sort_by(.value) | reverse | .[0:10]'

# Verify the rate limit descriptor being sent by the gateway for a specific tenant
# Enable debug logging on Envoy's rate limit filter
curl -s -X POST "http://localhost:9901/logging?level=debug"
kubectl logs -n inference deploy/inference-gateway | grep 'ratelimit.*descriptor'

# Inspect Redis keys for token budget counters
kubectl exec -n inference deploy/redis -- \
  redis-cli KEYS 'tenant:*:output_tokens:*' | head -20
kubectl exec -n inference deploy/redis -- \
  redis-cli MGET tenant:tenant-a:output_tokens:window tenant:tenant-b:output_tokens:window

# Check Envoy rate limit stats (over limit vs within limit)
curl -s http://localhost:9901/stats | grep 'ratelimit\.' | grep -E 'over_limit|ok'

# Compute per-tenant fraction of total tokens (Prometheus query)
# Run against your metrics backend:
# sum(rate(inference_gateway_tokens_total{direction="output"}[5m])) by (tenant)
#   / ignoring(tenant) sum(rate(inference_gateway_tokens_total{direction="output"}[5m]))
```

---

### 3. Model Canary Regression Undetected

**Symptoms**: A new model version (e.g., a fine-tuned checkpoint or a quantized variant) is receiving 10% of traffic via a canary split. Latency and error rates look normal on the gateway's standard dashboards. Three days later, customer support reports that responses from the model have become unhelpful or factually incorrect. Investigation reveals the canary model was the source. The quality regression was not detected because the gateway's SLOs only measured TTFT and 5xx rate, not response quality.

**Root Cause**: Model quality regressions are not visible to standard infrastructure metrics. A model that generates fluent but incorrect or off-topic responses produces 200 OK responses with normal latency. The gateway's circuit breakers and error rate monitors see no anomaly. Quality must be measured by evaluating the model's outputs, either through automated LLM-as-judge scoring or through user feedback signals (thumbs up/down, session abandonment, follow-up corrections). Without routing the sampled canary traffic to an evaluation pipeline, quality regressions are invisible until they accumulate enough user complaints to surface through support channels.

**Blast Radius**: The canary's 10% traffic split means 10% of users are affected by the quality regression. Depending on the use case (customer-facing summarization, code generation, medical documentation), a quality regression can cause significant downstream harm even at 10% traffic before it is detected.

**Mitigation**: Instrument the canary evaluation pipeline before increasing canary weight. The gateway should log request/response pairs for sampled canary traffic to a durable sink (S3, BigQuery, a logging cluster) with the `X-Inference-Canary-Version` header stamped on each logged pair. An async evaluation pipeline (a separate service or a batch job) periodically reads these pairs, submits them to an LLM judge or a task-specific evaluator, and writes quality scores to a time-series metric (`inference_canary_quality_score{model="llama-3.1-8b-v2",evaluator="llm_judge"}`). The canary controller (a Kubernetes controller watching InferenceModel objects) reads this metric and automatically pauses the canary (sets weight to 0) if the quality score drops below a threshold. Only after the quality score is stable at the baseline level does the controller promote the canary.

**Debugging**:
```bash
# Verify canary traffic split is configured correctly on the InferenceModel
kubectl get inferencemodel llama-3.1-8b -n inference -o yaml | \
  grep -A10 'targetModels'

# Check that canary responses are being tagged with the model version header
# (gateway should stamp X-Inference-Actual-Model on the response for logging)
kubectl logs -n inference deploy/inference-gateway | \
  grep '"model_version":"llama-3.1-8b-v2"' | tail -20

# Confirm the logging sink is receiving canary samples
# (check the log aggregator or S3 for canary-tagged entries)
aws s3 ls s3://inference-logs/canary/llama-3.1-8b-v2/ --recursive | tail -10

# Check the evaluation pipeline's quality score metric
curl -s http://inference-evaluator.inference.svc:9090/metrics | \
  grep inference_canary_quality_score

# Manually query a canary pod directly to compare output quality
CANARY_POD=$(kubectl get pod -n inference -l model=llama-3.1-8b-v2 -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n inference $CANARY_POD -- \
  curl -s -X POST localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"llama-3.1-8b-v2","messages":[{"role":"user","content":"What is 2+2?"}],"stream":false}' | \
  jq '.choices[0].message.content'

# Roll back canary to 0% immediately if regression confirmed
kubectl patch inferencemodel llama-3.1-8b -n inference --type=merge \
  -p '{"spec":{"targetModels":[{"name":"llama-3.1-8b-v1","weight":100}]}}'
```

---

### 4. KV Cache Thrashing Under Random Load Balancing

**Symptoms**: TTFT is higher than expected even when GPU queue depth is low. vLLM's `vllm:gpu_cache_usage_perc` metric is high (cache is full) but `vllm:num_requests_waiting` is low (not queued). The `vllm:cache_config_info` shows prefix caching is enabled but the cache hit rate (measured by comparing TTFT on repeated requests with the same prefix vs. novel requests) is near zero. The workload involves multi-turn chat sessions or batch requests with a shared system prompt.

**Root Cause**: Round-robin or random load balancing distributes requests across GPU pods without regard to which pod has the relevant KV cache entries. For a multi-turn session (turn 1 on pod-a1, turn 2 on pod-a3, turn 3 on pod-a2), each turn must re-compute the full KV cache for all previous turns from scratch. The cache is never warm for the current session on any pod. Similarly, a batch of requests that all share a 2000-token system prompt will each re-compute that prefix if they land on different pods, wasting prefill compute that could be served from cache. vLLM's prefix caching (enabled with `--enable-prefix-caching`) stores computed KV activations keyed by token sequence hash. If the same prefix arrives on the same pod, the prefill phase skips cached portions and TTFT is reduced proportionally to the shared prefix length. If the prefix arrives on a different pod, the cache is cold and the full prefill runs.

**Blast Radius**: TTFT is elevated for all sessions and batch workloads. GPU prefill utilization is high (wasteful recomputation) while cache hit rate is zero. For workloads where 60-70% of tokens are in a shared prefix (RAG with large retrieved documents, long system prompts for customer service bots), this represents a significant cost increase and TTFT increase simultaneously.

**Mitigation**: Enable session-affinity routing in the inference gateway. For multi-turn sessions, the client passes a `X-Session-ID` header (or the gateway generates a session token on the first turn and returns it as a cookie). The gateway uses consistent hashing on `X-Session-ID` to map the session to a fixed pod. In Envoy, this is `lb_policy: RING_HASH` on the cluster with `hash_policy: [{header: {header_name: "X-Session-ID"}}]` on the route. For batch workloads with shared prefixes, the gateway computes a canonical hash of the first 512 tokens of the system prompt and routes by that hash, co-locating all requests sharing the same prefix on the same pod. Set `minimum_ring_size: 1024` on the RING_HASH policy to reduce variance in the key distribution. Monitor cache hit rate by comparing `vllm:time_to_first_token_seconds` distributions between sessions with affinity-routed requests and baseline requests.

**Debugging**:
```bash
# Check vLLM prefix cache usage and hit rate
kubectl exec -n inference pod/gpu-pod-a1 -- \
  curl -s localhost:8080/metrics | grep -E 'cache_usage|prefix_cache'

# Verify that session-affinity routing is configured on the Envoy cluster
curl -s http://localhost:9901/config_dump | \
  jq '.configs[] | select(.["@type"] | contains("ClustersConfigDump")) | .dynamic_active_clusters[] | select(.cluster.name | contains("pool-a")) | .cluster.lb_policy'

# Confirm that RING_HASH policy and hash_policy are active on the route
curl -s http://localhost:9901/config_dump | \
  jq '.. | .hash_policy? // empty'

# Check that the X-Session-ID header is being set by clients
kubectl logs -n inference deploy/inference-gateway | \
  grep '"x-session-id"' | head -20

# Compare TTFT for requests with warm vs cold cache on a specific pod
# Send the same prompt twice to the same pod directly (bypassing LB)
FIRST_TTFT=$(kubectl exec -n inference pod/gpu-pod-a1 -- bash -c "
  time curl -s -X POST localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{\"model\":\"llama-3.1-8b\",\"messages\":[{\"role\":\"user\",\"content\":\"Summarize quantum computing in detail: ...\"}],\"stream\":true}' \
  | grep -m1 'data:' | date +%s%3N
" 2>&1)
echo "First request TTFT (cold cache): $FIRST_TTFT ms"

# Check ring hash distribution across pods (should be roughly even)
curl -s http://localhost:9901/clusters | grep -A3 'pool-a.*ring_hash'
```

## Lightweight Lab

See [lab/README.md](lab/README.md) for a hands-on exercise that deploys two simulated inference backends with configurable response delays and demonstrates weighted model routing, token budget enforcement, and TTFT measurement using `curl` and a mock SSE server.

The lab covers:
- Deploying a mock vLLM-compatible server that returns SSE responses with configurable delays and `usage` metadata.
- Configuring an Envoy proxy with an ext_proc sidecar that extracts `model` from the request body and enforces a Redis-backed token budget.
- Observing TTFT difference between a cold-cache baseline (random LB) and a session-affinity configuration (RING_HASH on `X-Session-ID`).
- Simulating a noisy-neighbor scenario and verifying that the per-tenant budget key isolates impact.

## What to commit

- Add a `lab/` directory with the mock inference server (a Go HTTP server serving SSE with configurable delays), an Envoy static config with ext_proc enabled, and a Redis deployment for token budget state.
- Map each failure mode's mitigation to the specific Envoy config field or vLLM flag that implements it (e.g., queue threshold -> `max_pending_requests` in `circuit_breakers`, session affinity -> `lb_policy: RING_HASH` + `hash_policy`).
