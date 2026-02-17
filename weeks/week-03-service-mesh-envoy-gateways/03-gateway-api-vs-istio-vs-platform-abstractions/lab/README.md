# Lab: Gateway API vs Istio vs Platform Abstraction — Side-by-Side Comparison

## Prerequisites

- Familiarity with Kubernetes resource model (namespaces, Services, Deployments)
- Basic understanding of Envoy routing concepts (clusters, virtual hosts, weighted splits)
- No running cluster required — this is a YAML reasoning and trade-off analysis lab

## Learning Objectives

- Express the same routing intent in three different API layers and identify what each layer can and cannot represent
- Map Gateway API HTTPRoute fields to their Envoy xDS equivalents
- Identify the specific capabilities that Istio adds beyond Gateway API (subsets, circuit breakers, retry policies, fault injection)
- Articulate the "Why not just Gateway API?" argument with concrete field-level evidence
- Understand the ownership model and where validation happens at each layer

## Scenario

You are implementing the following routing intent for an API service:

> Route all traffic matching path prefix `/api` to a stable backend (`my-svc` v1). If the request also carries the header `x-canary: true`, route 90% to v1 and 10% to a canary backend (v2). Apply a 3-retry policy on 5xx responses. Protect the upstream with a circuit breaker that opens after 5 consecutive gateway errors.

---

## Step 1: Express the Intent in Gateway API

Open `gateway-api-example.yaml`. The file contains three resources that together implement the routing intent using the Gateway API standard.

```bash
cat lab/gateway-api-example.yaml
```

Key things to observe:

- `GatewayClass` (cluster-scoped): declares the controller that will program Envoy. `spec.controllerName: istio.io/gateway-controller` means Istio's Gateway API implementation will reconcile Gateways of this class.
- `Gateway` (in `namespace: infra`): owned by the infrastructure team. The listener specifies port, protocol, and hostname. `allowedRoutes.namespaces.from: All` permits routes from any namespace to attach — in production you would use `Selector` with a label selector.
- `HTTPRoute` (in `namespace: app`): owned by the application team. The `parentRefs` attachment to the Gateway in `namespace: infra` requires a `ReferenceGrant` in that namespace (see the YAML for the example ReferenceGrant).
- The weight split (90/10) is expressed in `spec.rules[].backendRefs[].weight`. The header match for `x-canary: true` is expressed in `spec.rules[].matches[].headers[]`.

What Gateway API cannot express in this scenario:

- No retry policy field in HTTPRoute (GEP-713 policy attachment for retries is not yet widely implemented)
- No circuit breaker — no equivalent of `outlierDetection` or `connectionPool` anywhere in the Gateway API resource model
- No distinction between pod subsets (v1, v2) at the API level — backendRefs point to Kubernetes Services, so v1 and v2 must be separate Services

---

## Step 2: Express the Intent in Istio VirtualService + DestinationRule

Open `istio-example.yaml`. The file contains three resources that implement the same intent plus the capabilities Gateway API cannot express.

```bash
cat lab/istio-example.yaml
```

Key things to observe:

- `Gateway` (Istio's own CRD, not Gateway API): attached to the ingress gateway pod via `spec.selector.istio: ingressgateway`. This is a different resource from `gateway.networking.k8s.io/v1/Gateway`.
- `VirtualService`: the `spec.http[]` rules list matches in order (first match wins). The header-match rule is listed first because it is more specific. Each route entry references a `destination.subset` (e.g., `v1`, `v2`) — these map to distinct Envoy clusters.
- `spec.http[].retries` provides what Gateway API cannot: `attempts: 3`, `perTryTimeout: 2s`, `retryOn: 5xx,connect-failure,refused-stream`.
- `spec.http[].fault` enables fault injection for testing — no equivalent in Gateway API.
- `DestinationRule`: `spec.subsets` defines label selectors that istiod uses to build distinct Envoy Cluster objects. Without a matching DestinationRule, the VirtualService's subset references result in zero-endpoint clusters and `UH` 503s.
- `trafficPolicy.outlierDetection` maps to Envoy's `outlier_detection` block in the Cluster proto: `consecutiveGatewayErrors: 5` opens the circuit after 5 consecutive gateway errors.
- `trafficPolicy.connectionPool` maps to Envoy's `circuit_breakers` block: `http.http1MaxPendingRequests: 100`.

What Istio adds beyond Gateway API:

- Retry policy with per-try timeout and retry-on conditions
- Fault injection (delay and abort for chaos testing)
- Traffic mirroring (`mirror` and `mirrorPercentage`)
- Subset-level routing (pod-label-based endpoint selection via DestinationRule)
- Circuit breaker and outlier detection per destination
- mTLS policy via PeerAuthentication (not shown here but applies to the destination)

---

## Step 3: Express the Intent in a Hypothetical Platform Abstraction CRD

The following is a hypothetical internal CRD that a platform team might define. It is not a real Kubernetes API — it represents the kind of higher-level abstraction that platform teams build above Gateway API and Istio.

```yaml
# Internal platform CRD (hypothetical — not a real K8s resource)
# Group: platform.example.com / Kind: AppRoute
apiVersion: platform.example.com/v1
kind: AppRoute
metadata:
  name: my-api-route
  namespace: app
spec:
  # Teams specify their service, not a Gateway or VirtualService
  service: my-svc
  port: 8080

  # Path prefix — the platform controller validates ownership
  # (team may only claim paths under their namespace prefix)
  pathPrefix: /api

  # Canary config — platform controller generates DestinationRule subsets
  # and VirtualService weight rules from this single block
  canary:
    service: my-svc-v2     # must be a Service in same namespace
    weight: 10             # percentage; 100 - weight goes to stable
    headerTrigger:
      name: x-canary
      value: "true"

  # Retry policy — platform controller generates VirtualService retries block
  retries:
    attempts: 3
    perTryTimeout: 2s
    retryOn: 5xx

  # Circuit breaker — platform controller generates DestinationRule outlierDetection
  circuitBreaker:
    consecutiveGatewayErrors: 5
    interval: 30s
    baseEjectionTime: 30s
```

The platform controller reconciling this `AppRoute` would:

1. Validate that `my-svc` and `my-svc-v2` are Services in `namespace: app`
2. Check that `my-svc-v2` has pods with the expected version label
3. Generate a `DestinationRule` with subsets `stable` and `canary` matching the respective pod labels
4. Generate a `VirtualService` with the header-match canary rule and retry policy
5. Optionally also generate an `HTTPRoute` referencing the Gateway in `namespace: infra` (if the team uses Gateway API ingress)
6. Surface `EndpointsNotFound` or `SubsetLabelMismatch` conditions in `status` if validation fails

---

## Step 4: Trade-offs Comparison Table

| Dimension                  | Gateway API HTTPRoute              | Istio VirtualService + DestinationRule    | Platform Abstraction CRD             |
|----------------------------|------------------------------------|-------------------------------------------|--------------------------------------|
| **API group**              | `gateway.networking.k8s.io`        | `networking.istio.io`                     | `platform.example.com` (internal)    |
| **Ownership**              | App team (Route), Infra (Gateway)  | App team (VS), Mesh team (DR)             | App team (limited fields)            |
| **Portability**            | Any conformant controller          | Istio only                                | Internal only                        |
| **Retry policy**           | Not in spec (GEP-713, future)      | `spec.http[].retries`                     | Translated to VS retries             |
| **Circuit breaker**        | No equivalent                      | DR `trafficPolicy.outlierDetection`       | Translated to DR outlierDetection    |
| **Subset routing**         | No (routes to Service only)        | DR `subsets` + VS `destination.subset`   | Translated to DR subsets             |
| **mTLS policy**            | No equivalent                      | `PeerAuthentication`                      | Platform-owned PeerAuthentication    |
| **Cross-ns authorization** | `ReferenceGrant` (explicit)        | `exportTo` (implicit, less granular)     | Webhook-enforced ownership           |
| **Fault injection**        | No equivalent                      | `spec.http[].fault`                       | Optional field (if platform exposes) |
| **Upgrade coupling**       | Stable spec (SIG-managed)          | Tied to Istio control plane version       | Stable API; controller upgrades      |
| **Validation depth**       | Schema + parentRef/ReferenceGrant  | Schema + istiod webhook                  | Schema + endpoint existence check    |
| **Debugging surface**      | `status.parents[].conditions`      | `istioctl proxy-config`, `istioctl x authz` | Platform CRD status + proxy-config |

---

## Step 5: Why Not Just Gateway API?

Gateway API solves the Kubernetes-native ingress ownership model but leaves three specific gaps that mesh deployments require.

**Gap 1: No cluster-level traffic policy.** Gateway API routes traffic to a Kubernetes Service. Istio's DestinationRule routes traffic to a labeled subset of pods behind a Service and applies per-subset connection pool limits, outlier detection, and load-balancing policy. In a canary deployment, the ability to limit connections to the canary subset (in case it has a memory leak) without affecting the stable subset requires DestinationRule — there is no HTTPRoute equivalent.

**Gap 2: No retry or circuit-breaker semantics in the standard spec.** The GEP-713 policy attachment mechanism is the long-term answer, but as of 2025, `BackendLBPolicy` and `BackendTLSPolicy` exist, while retry and timeout policies are still in the proposal stage and not implemented across all controllers. Istio's VirtualService has had `spec.http[].retries` with `attempts`, `perTryTimeout`, and `retryOn` since its early releases. For services that require resilience to transient upstream errors, relying on unimplemented GEP-713 is not a production option.

**Gap 3: No mTLS policy surface.** Gateway API has no resource equivalent to `PeerAuthentication`. Enforcing STRICT mTLS for a workload, managing PERMISSIVE mode during a migration window, or overriding mTLS per-port requires Istio CRDs. Gateway API's `BackendTLSPolicy` (v1alpha2) controls the TLS from the gateway to the backend Service, which is a different concern from the sidecar-level mTLS that PeerAuthentication governs.

**The counterargument for Gateway API:** Portability. A cluster that switches from Istio to Cilium Gateway API, Envoy Gateway, or Contour does not need to rewrite HTTPRoutes — they are controller-agnostic. VirtualService and DestinationRule are entirely Istio-specific. For organizations that want to avoid Istio lock-in, the missing capabilities in Gateway API are an acceptable limitation if the workloads do not require subset routing, complex retry policies, or mTLS enforcement at the sidecar level.

**The platform abstraction answer:** Build internal CRDs that are controller-agnostic at the team API surface, and translate to whichever combination of Gateway API and Istio CRDs the current control plane supports. When Istio adds a native Gateway API implementation that covers retries and circuit breakers (which is the direction Istio is moving), the platform controller's translation layer updates — team-facing CRDs do not change.

---

## Expected Outcomes

After completing this lab you should be able to:

- Open `gateway-api-example.yaml` and explain which Envoy xDS object each field maps to (GatewayClass → controller claim, Gateway listener → LDS Listener, HTTPRoute weight → RDS weighted_clusters)
- Open `istio-example.yaml` and identify which fields have no Gateway API equivalent (retries, outlierDetection, subsets, fault injection)
- State the three specific Gateway API gaps (no cluster policy, no retries in spec, no mTLS surface) without referring to notes
- Describe the ReferenceGrant requirement for cross-namespace HTTPRoute attachment and explain why it exists
- Explain when a platform abstraction CRD is justified versus when raw Gateway API or Istio CRDs are sufficient
