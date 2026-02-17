# Gateway API vs Istio APIs vs Platform Abstractions

## What you should be able to do
- Describe the three-layer ownership model: infrastructure team owns GatewayClass and Gateway, application teams own Routes and VirtualServices, and the platform team governs the abstraction layer above both.
- Explain why Gateway API alone is insufficient for enterprise mesh deployments and name the specific gaps: no DestinationRule equivalent, no mTLS policy surface, limited retry and circuit-breaker semantics.
- Diagnose failures that span layers — policy conflicts, cross-namespace routing rejections, and upgrade coupling between CRD versions and control-plane versions.

## Mental Model

Think of these three layers as a separation of concerns enforced by API design, not just organizational convention. The bottom layer is Kubernetes infrastructure: something has to own the actual load balancer, TLS certificate, and listener configuration. Gateway API's `GatewayClass` and `Gateway` resources formalize that ownership. A GatewayClass is owned by the infrastructure team and declares which controller manages gateways of that type (the `spec.controllerName` field). A Gateway is owned by the team that provisions the load balancer — in most enterprises, the network or platform SRE team — and specifies listeners, ports, and allowed namespaces. HTTPRoute resources are owned by application teams and attach to the Gateway via a `parentRef`. This hierarchy is intentional: it enforces a policy boundary between "who can expose a gateway listener" and "who can attach routes to an existing gateway."

The middle layer is Istio's CRD model. Where Gateway API is a Kubernetes SIG project defining portable, controller-agnostic abstractions, Istio's CRDs are mesh-specific and semantically richer. A `VirtualService` can express retry policies, fault injection, mirror traffic, and apply to traffic inside the mesh without touching any gateway. A `DestinationRule` configures how Envoy treats a cluster: connection pool settings, circuit breaker thresholds, outlier detection, and load-balancing policy. An `AuthorizationPolicy` enforces which workloads can call which other workloads, operating at the L7 level with JWT claims as match criteria. These objects have no direct equivalents in Gateway API. `ServiceEntry` brings external services into the mesh registry so VirtualService routing rules can apply to egress traffic. The tradeoff is portability: Istio CRDs are Istio-specific and encode assumptions about how istiod programs Envoy sidecars.

The top layer — the platform abstraction — exists because neither Gateway API nor Istio CRDs solve the operational problems that appear at scale in multi-tenant clusters. When 30 teams each own VirtualServices and AuthorizationPolicies, you get policy sprawl: conflicting retry policies, overlapping header matchers, authorization rules that block traffic across service versions after a rename. The platform team needs a single opinionated interface that generates Gateway API and Istio resources from higher-level intent, applies organization-wide defaults (TLS version, circuit breaker thresholds, audit logging), enforces tenancy isolation (a route in namespace `team-a` must not be able to steal traffic from `team-b`), and manages lifecycle across control-plane upgrades. This is why platform teams build internal CRDs — not because they add new routing features, but because they add governance, validation, and lifecycle management that the lower layers cannot provide.

The ownership model determines where validation lives. Gateway API uses `ReferenceGrant` as an explicit cross-namespace authorization mechanism: a Route in `namespace: app` cannot reference a Gateway in `namespace: infra` unless an `ReferenceGrant` in `namespace: infra` explicitly allows it. This prevents namespace-boundary violations at the API server level, before any controller runs. Istio's model is less strict: a `VirtualService` can reference a `Gateway` in another namespace using the `namespace/name` format, relying on RBAC at the Kubernetes level rather than a purpose-built grant object. The platform abstraction layer typically adds a third layer of validation via admission webhooks: rejecting requests that violate organizational policy before either the Gateway API controller or istiod processes them.

## Key Concepts

- **GatewayClass**: A cluster-scoped resource that declares a class of gateways managed by a specific controller, identified by `spec.controllerName` (e.g., `istio.io/gateway-controller`, `gateway.envoyproxy.io/gatewayclass-controller`). Acts as a CRD-based factory: all Gateways referencing this class are reconciled by that controller.
- **Gateway**: A namespace-scoped resource that specifies one or more listeners (protocol, port, TLS mode, hostname) and declares which Routes may attach to it via `spec.listeners[].allowedRoutes` (namespace selectors and Route kinds). The infrastructure team owns this object.
- **HTTPRoute**: A namespace-scoped resource that attaches to a Gateway via `spec.parentRefs` and defines routing rules using matches (path, headers, query params) and `spec.rules[].backendRefs` with optional `weight` for traffic splitting. Application teams own this object.
- **GRPCRoute**: Gateway API resource purpose-built for gRPC traffic matching on service name and method name, following the same parentRef/backendRef model as HTTPRoute. Avoids the path-prefix workaround previously needed to route gRPC with HTTPRoute.
- **ReferenceGrant**: A Gateway API resource (namespace-scoped, in the target namespace) that explicitly authorizes a cross-namespace reference. A Route in `namespace: app` referencing a Gateway in `namespace: infra` requires a `ReferenceGrant` in `namespace: infra` with `spec.from[].namespace: app`. Without it, the parentRef is silently ignored by the controller.
- **VirtualService**: Istio CRD that configures how Envoy routes traffic to a service. Can apply to gateway ingress, sidecar egress, or intra-mesh traffic. Expresses host-based routing, weight-based splits, header matching, retry policies (`attempts`, `perTryTimeout`, `retryOn`), fault injection (`delay`, `abort`), and traffic mirroring. Attached to a mesh Gateway via `spec.gateways`.
- **DestinationRule**: Istio CRD that configures how Envoy treats a destination cluster. Fields: `trafficPolicy.connectionPool` (TCP/HTTP connection limits), `trafficPolicy.outlierDetection` (consecutive errors and ejection interval), `trafficPolicy.loadBalancer` (ROUND_ROBIN, LEAST_CONN, RANDOM, CONSISTENT_HASH), `subsets` (label selectors that map to Envoy cluster variants used in VirtualService weight splits).
- **ServiceEntry**: Istio CRD that registers an external service (outside the mesh) into Istio's service registry, enabling VirtualService routing rules and DestinationRule traffic policies to apply to egress traffic. `spec.resolution` controls DNS, static IP, or dynamic endpoint discovery.
- **AuthorizationPolicy**: Istio CRD that enforces access control at L7. `spec.rules[].from` matches source principals (SPIFFE identities), namespaces, or IP blocks; `spec.rules[].to` matches HTTP methods, paths, and ports; `spec.rules[].when` adds JWT claim conditions. Default-deny when any AuthorizationPolicy exists in a namespace.
- **PeerAuthentication**: Istio CRD that configures mTLS mode for a workload or namespace. `spec.mtls.mode: STRICT` rejects plaintext; `PERMISSIVE` accepts both (used during migration). Applied per-port via `spec.portLevelMtls`. Sets the `DownstreamTlsContext` in the Envoy sidecar's listener filter chain.
- **Gateway API conformance profiles**: The Gateway API project defines conformance levels (Core, Extended, Implementation-specific). Core features (basic HTTPRoute routing) must be implemented identically by all conformant controllers. Extended features (request mirroring, header modification) are optional but must behave as specified if implemented. Implementation-specific features are controller-specific extensions with no portability guarantees.
- **Policy attachment (GEP-713)**: A Gateway API extension mechanism that allows policy resources (timeout policies, retry policies, rate limit policies) to attach to Gateway API resources using a `targetRef` field. Defines an inheritance model: a policy on a Gateway applies to all Routes unless a more-specific policy on a Route overrides it. Still maturing — most production deployments use VirtualService retry policies instead.

## Internals

### Gateway API Resource Model

The Gateway API hierarchy has a strict parent-child attachment model designed for role separation. The chain is: `GatewayClass` -> `Gateway` -> `Route` -> `Service`. Each link in the chain carries an authorization check.

1. **GatewayClass is reconciled by a controller** identified by `spec.controllerName`. When the controller starts, it watches all GatewayClass objects and claims those matching its controller name by setting `status.conditions[type=Accepted]=True`. A GatewayClass that no controller claims has `Accepted=False` and no Gateways referencing it will be provisioned.

2. **Gateway listener attachment**: Each `spec.listeners[]` entry in a Gateway has a `allowedRoutes.namespaces` field that controls which namespaces can attach Routes. Modes: `Same` (same namespace only), `All` (any namespace), `Selector` (label selector on namespaces). The controller sets `status.listeners[].attachedRoutes` to the count of successfully attached Routes.

3. **Route parentRef resolution**: An HTTPRoute's `spec.parentRefs[]` names the Gateway (and optionally a specific listener by `spec.parentRefs[].sectionName`). The controller checks: (a) does the referenced Gateway exist? (b) does the listener's `allowedRoutes.kinds` permit HTTPRoute? (c) is there a valid ReferenceGrant if the namespaces differ? If any check fails, the HTTPRoute's `status.parents[].conditions` shows `Accepted=False` with a reason (e.g., `NotAllowedByListeners`, `RefNotPermitted`).

4. **Traffic splitting via backendRefs weight**: An HTTPRoute rule can list multiple `backendRefs[]` entries with `weight` fields. The Gateway controller translates these into Envoy `weighted_clusters` entries in a `RouteConfiguration`. A 90/10 split is expressed as two backendRefs with `weight: 90` and `weight: 10`. Weights are relative — the controller normalizes them. A zero-weight backendRef effectively removes traffic from that backend without removing the route rule.

5. **Header and path matching**: HTTPRoute matches are AND'd within a rule and OR'd across rules. A rule with `matches: [{path: {type: PathPrefix, value: "/api"}, headers: [{name: x-canary, value: "true"}]}]` only matches requests where both conditions are true. Multiple `matches[]` entries in the same rule create an OR. This is the same semantics as Envoy's route matching at the xDS level, because Gateway API controllers translate directly to `RouteConfiguration.virtual_hosts[].routes[]` with `match.prefix` and `match.headers[]`.

### Istio CRD Model

Istio's CRDs translate to xDS config on a different axis: they operate on the mesh service registry, not just on gateway listeners.

1. **VirtualService to xDS**: When istiod processes a VirtualService for `spec.hosts: [my-svc]`, it generates an Envoy `RouteConfiguration` for the outbound listener at the port matching `spec.http[].match[].port` (or all ports for the service). Weight-based splits become `weighted_clusters` entries. Each subset name (e.g., `v1`, `v2`) in `spec.http[].route[].destination.subset` must have a corresponding entry in the DestinationRule for that host; if it does not exist, Envoy gets a route to a cluster that has no endpoints, resulting in `UH` (upstream unhealthy) response flags.

2. **DestinationRule to Cluster config**: A DestinationRule for `spec.host: my-svc` produces multiple `Cluster` objects in CDS. The base cluster (`outbound|8080||my-svc.default.svc.cluster.local`) gets the `trafficPolicy` settings: `connectionPool.http.h2UpgradePolicy`, `outlierDetection.consecutiveGatewayErrors`, `loadBalancer.simple`. Each subset generates a distinct cluster variant (`outbound|8080|v1|my-svc.default.svc.cluster.local`) with the subset's label selector merged into the EDS query. This is the critical difference from Gateway API: there is no Gateway API equivalent of DestinationRule subsets. Gateway API routes to Services, not to labeled subsets of pod endpoints.

3. **Cross-namespace VirtualService reach**: A VirtualService can reference a Gateway in another namespace using `spec.gateways: ["infra/my-gateway"]`. It can also match traffic on `spec.hosts` that are in another namespace's service. Istio's RBAC (controlled by `exportTo` on the VirtualService and DestinationRule) determines whether a config object is visible to istiod's processing for other namespaces. `exportTo: ["."]` restricts visibility to the same namespace; `exportTo: ["*"]` makes it visible cluster-wide. This is less granular than Gateway API's ReferenceGrant, which requires explicit per-object authorization.

4. **AuthorizationPolicy evaluation order**: Istio evaluates AuthorizationPolicies with a deny-first, then allow logic. If any `DENY` policy matches, the request is rejected regardless of `ALLOW` policies. Within `ALLOW` policies, the request proceeds only if at least one allows it. When no AuthorizationPolicy exists in a namespace, all traffic is allowed. When any AuthorizationPolicy exists with `action: ALLOW`, all traffic not matched by that policy is denied by default. This implicit default-deny is a common source of outages after adding the first AuthorizationPolicy in a previously open namespace.

### Platform Abstraction Layer

The platform abstraction layer is a set of internal CRDs and admission webhooks that sit above both Gateway API and Istio, translating platform intent into mesh and gateway config.

1. **Why it exists**: Application teams should not need to understand Envoy cluster semantics to deploy a canary. A platform CRD like `AppRoute` can expose three fields — `service`, `canaryService`, `canaryWeight` — and generate the corresponding HTTPRoute (or VirtualService + DestinationRule) automatically. This reduces the blast radius of misconfiguration: invalid `AppRoute` objects are rejected by the webhook before any mesh config is created.

2. **Multi-cluster lifecycle management**: Gateway API and Istio CRDs exist per-cluster. When a platform team manages 20 clusters, they need a control plane that syncs policy across clusters, handles CRD version migration during Istio upgrades, and provides a single API surface. Tools like ArgoCD ApplicationSets, Submariner, or internal GitOps controllers fill this role. The platform CRD is stable across Istio versions; the translation layer handles version differences.

3. **Tenancy isolation enforcement**: In a shared cluster, a VirtualService in `namespace: team-a` could accidentally (or maliciously) claim `spec.hosts: [team-b-svc]` if not prevented. The platform layer enforces namespace-scoped ownership via admission webhooks: a VirtualService may only list hosts that match services in its own namespace, or hosts explicitly granted by a platform-owned `HostGrant` resource. This is defense-in-depth on top of Istio's `exportTo` mechanism.

4. **Policy aggregation and cost attribution**: Platform-owned AuthorizationPolicies and PeerAuthentication objects set cluster-wide baselines (e.g., STRICT mTLS everywhere). Team-owned policies can only narrow scope (allow specific callers), never widen it (allow plaintext). This hierarchy is enforced by admission webhooks that validate that team-submitted `AuthorizationPolicy` objects do not conflict with the platform baseline. Cost attribution labels (`billing-team`, `cost-center`) are injected into generated Gateway API and Istio resources by the platform controller, so Prometheus metrics by cluster/subset are automatically tagged for chargeback.

## Architecture Diagram

```
  LAYER 3: PLATFORM ABSTRACTION
  ┌─────────────────────────────────────────────────────────────────────────┐
  │  Platform CRDs (internal)         Owned by: Platform SRE Team          │
  │                                                                         │
  │  AppRoute         HostGrant       NetworkPolicy    CostCenter           │
  │  (canary intent)  (cross-ns auth) (baseline mTLS)  (attribution)       │
  │                                                                         │
  │  Platform Controller + Admission Webhooks                               │
  │  validates → generates → syncs across clusters                         │
  └──────────────────┬──────────────────────────┬──────────────────────────┘
                     │ generates                 │ generates
                     ▼                           ▼
  LAYER 2A: GATEWAY API               LAYER 2B: ISTIO CRDs
  ┌──────────────────────────────┐    ┌──────────────────────────────────┐
  │  Owned by: Infra / App Teams │    │  Owned by: App / Mesh Teams      │
  │                              │    │                                  │
  │  GatewayClass  (infra team)  │    │  VirtualService  (routing)       │
  │  Gateway       (infra team)  │    │  DestinationRule (cluster config) │
  │  HTTPRoute     (app team)    │    │  AuthorizationPolicy (L7 authz)  │
  │  ReferenceGrant(infra team)  │    │  PeerAuthentication (mTLS mode)  │
  │  GRPCRoute     (app team)    │    │  ServiceEntry    (ext services)  │
  └──────────────────┬───────────┘    └──────────────────┬───────────────┘
                     │ programs                          │ programs
                     ▼                                   ▼
  LAYER 1: ENVOY (DATA PLANE)
  ┌─────────────────────────────────────────────────────────────────────────┐
  │  istiod / Envoy Gateway controller / Contour / ...                      │
  │                                                                         │
  │  LDS: Listener + FilterChain (from Gateway listeners)                   │
  │  RDS: RouteConfiguration + VirtualHost (from HTTPRoute / VirtualService)│
  │  CDS: Cluster + circuit breaker (from DestinationRule)                  │
  │  EDS: Endpoints (from Service + Pod labels / subset selectors)          │
  │  SDS: TLS certificates (from cert-manager / Istio SPIFFE SVIDs)         │
  └─────────────────────────────────────────────────────────────────────────┘
```

## Failure Modes & Debugging

### 1. Policy Sprawl: Conflicting VirtualServices and AuthorizationPolicies

**Symptoms**: Traffic that worked last week now returns 403 or is routed to the wrong version. `kubectl get virtualservice -A` shows multiple VirtualServices claiming the same `spec.hosts` entry. Teams report intermittent failures that correlate with recent VirtualService changes in other namespaces. `istioctl analyze` emits `VirtualServiceUnreachableRule` or `ConflictingMeshGatewayVirtualServiceHosts` warnings.

**Root Cause**: Istio's VirtualService merging behavior: if multiple VirtualServices in different namespaces match the same host, istiod merges their `spec.http[]` rules in an unspecified order (in practice, by creation timestamp). The last writer wins on overlapping path prefixes. AuthorizationPolicy conflicts are harder to detect: a `DENY` policy in namespace A can block traffic that a `ALLOW` policy in namespace B explicitly permits, with no visible error on the ALLOW policy's status.

**Blast Radius**: Incorrect routing affects all pods that share the conflicting hostname. AuthorizationPolicy conflicts can silently block all cross-namespace traffic when the first ALLOW policy is added to a previously open namespace (implicit default-deny semantics), causing an outage that looks like a network failure rather than a policy failure.

**Mitigation**: Enforce single-writer ownership via admission webhook: a VirtualService may only list hosts that are Services in its own namespace. Use `exportTo: ["."]` on all team-owned VirtualServices to prevent accidental cluster-wide visibility. For AuthorizationPolicy, maintain a platform-owned baseline `ALLOW` policy that explicitly permits intra-namespace traffic; team-owned policies can only add additional allowed sources.

**Debugging**:
```bash
# Check for conflicting VirtualServices on the same host
istioctl analyze --all-namespaces 2>&1 | grep -E 'VirtualService|Conflict'

# See which VirtualServices istiod has merged for a given service
istioctl proxy-config routes POD_NAME.NAMESPACE --name <port> -o json | \
  jq '.[].virtualHosts[].routes[].match'

# Identify which AuthorizationPolicies affect a pod
istioctl x authz check POD_NAME.NAMESPACE

# Check what istiod's internal model looks like for a service
istioctl proxy-config cluster POD_NAME.NAMESPACE | grep my-svc

# Find all VirtualServices claiming a given hostname across namespaces
kubectl get virtualservice -A -o json | \
  jq '.items[] | select(.spec.hosts[] | contains("my-svc")) | {name: .metadata.name, ns: .metadata.namespace}'
```

---

### 2. Leaky Abstraction: Platform Layer Hides Envoy Config

**Symptoms**: A team's AppRoute says traffic should be split 90/10, but Envoy is sending 100% to one backend. The platform CRD status shows `Reconciled=True`. The team has no access to the generated VirtualService or DestinationRule. Debugging requires access to Envoy admin APIs that the platform layer does not expose.

**Root Cause**: The platform controller generated the VirtualService correctly, but the DestinationRule `subsets` field references a label (`version: v2`) that does not match any pod because the deployment uses `release: v2` instead. Envoy's cluster for that subset has zero endpoints. The platform abstraction layer validated the AppRoute schema but not the pod-label alignment. The team sees a successful reconciliation status but Envoy sees `UH` (upstream unhealthy).

**Blast Radius**: Traffic to the canary subset silently falls through to `UH` 503s or, if the VirtualService lacks a fallback route, all traffic to the service fails. The platform layer's success status is misleading — reconciliation only means the CRD was translated, not that Envoy has healthy endpoints.

**Mitigation**: Platform controllers should extend their validation to check endpoint existence: if a generated DestinationRule subset selects zero pods, surface this in the platform CRD status as `EndpointsNotFound=True`. Expose read-only views of generated Envoy config in the platform API (e.g., a `kubectl plugin platform routes` command that wraps `istioctl proxy-config`). Do not hide the generated VirtualService — make it visible in the team's namespace with an `owner: platform-controller` label.

**Debugging**:
```bash
# Check if the subset has any endpoints
istioctl proxy-config endpoint POD_NAME.NAMESPACE \
  --cluster "outbound|8080|v2|my-svc.default.svc.cluster.local"

# See the generated clusters — a subset with zero endpoints shows MISSING
istioctl proxy-config cluster POD_NAME.NAMESPACE | grep my-svc

# Check pod labels vs DestinationRule subset selector
kubectl get pods -n app -l version=v2
kubectl get destinationrule my-svc -n app -o jsonpath='{.spec.subsets}'

# If endpoints are missing, the cluster stat shows no upstream requests
kubectl exec -n app POD_NAME -c istio-proxy -- \
  curl -s http://localhost:15000/stats | grep "outbound|8080|v2|my-svc" | grep upstream_rq
```

---

### 3. Upgrade Coupling: Istio CRD Version Tied to Control Plane

**Symptoms**: After an Istio upgrade from 1.18 to 1.20, existing VirtualService and DestinationRule objects that referenced deprecated fields (e.g., `spec.trafficPolicy.tls.mode: ISTIO_MUTUAL` replaced by `MUTUAL` enum variant changes) start failing validation. istiod logs show `validation failed for resource` on objects that were valid before the upgrade. The platform controller that generates these objects has not been updated to use the new field names.

**Root Cause**: Istio CRDs are versioned (`networking.istio.io/v1alpha3`, `v1beta1`, `v1`) and field semantics sometimes change across minor versions. The platform abstraction layer generates Istio CRDs using a template tied to the Istio version it was built against. Upgrading Istio without simultaneously updating the platform controller creates a mismatch. Unlike Gateway API controllers (which implement a versioned spec), Istio's CRD schema validation is the only enforcement point.

**Blast Radius**: Newly generated VirtualServices and DestinationRules fail to apply. Existing objects (already stored in etcd) continue to work until the Istio control plane drops support for old fields in its webhook validation, at which point they cannot be updated. Updates to any field on the object (even unrelated fields) trigger validation against the new schema and fail.

**Mitigation**: Pin the platform controller's Istio client library version to match the target Istio control plane version. Maintain a version matrix (platform-controller@X.Y requires istio@A.B). Run `istioctl analyze` in CI against generated manifests before deploying. Use `kubectl convert` or a migration job to update stored CRDs to the new API version before upgrading istiod.

**Debugging**:
```bash
# Check current CRD versions stored in etcd
kubectl get virtualservice -A -o json | jq '.items[].apiVersion' | sort | uniq

# Validate existing objects against the new istiod webhook
istioctl analyze --all-namespaces

# Check istiod validation webhook errors
kubectl get events -n istio-system | grep 'validation failed'

# See which fields istiod's webhook rejects on a specific object
kubectl apply -f /tmp/my-virtualservice.yaml --dry-run=server 2>&1

# Check the installed CRD schema version
kubectl get crd virtualservices.networking.istio.io -o jsonpath='{.spec.versions[*].name}'
```

---

### 4. Cross-Namespace Routing Without ReferenceGrant

**Symptoms**: An HTTPRoute in `namespace: app` references a Gateway in `namespace: infra` via `spec.parentRefs[0].namespace: infra`. The HTTPRoute shows `status.parents[].conditions[type=Accepted].status: False` with `reason: RefNotPermitted`. No traffic flows to the route even though the Gateway exists and has capacity for the listener. The Gateway's `status.listeners[].attachedRoutes` count does not increment.

**Root Cause**: Gateway API's cross-namespace reference model requires a `ReferenceGrant` in the target namespace (`infra`) that explicitly permits the source namespace (`app`) to reference the Gateway. Without it, the Gateway API controller ignores the parentRef. This is not a bug — it is the security model. The `ReferenceGrant` object acts as a capability grant: the `infra` team must explicitly opt in to allowing `app` team routes to attach. There is no default-allow for cross-namespace Gateway attachment.

**Blast Radius**: The route is silently not attached. Clients see connection refused or receive responses from a different route (if a fallback route is in place). The failure is not immediately visible because the Gateway itself continues to serve other routes normally. Only inspection of the HTTPRoute status reveals the reason.

**Mitigation**: The platform team should provision a `ReferenceGrant` in the shared Gateway namespace for each tenant namespace at onboarding time, as part of the namespace provisioning workflow. Do not require application teams to create ReferenceGrants manually — they are infrastructure objects and belong in the infra team's GitOps repository. Monitor for `Accepted=False` on HTTPRoute objects and alert the platform team.

**Debugging**:
```bash
# Check HTTPRoute attachment status
kubectl get httproute my-route -n app -o yaml | \
  yq '.status.parents[]'

# Verify ReferenceGrant existence in the Gateway namespace
kubectl get referencegrant -n infra

# Describe a ReferenceGrant to see which from/to it permits
kubectl get referencegrant allow-app-routes -n infra -o yaml

# Check how many routes the Gateway listener has attached
kubectl get gateway my-gateway -n infra -o jsonpath='{.status.listeners[*].attachedRoutes}'

# If using Istio as Gateway API controller, check its logs for the rejection reason
kubectl logs -n istio-system deploy/istiod | grep -i 'referencegrant\|RefNotPermitted'
```

## Lightweight Lab

This is a conceptual comparison lab. No running cluster is required. Work through the YAML files in the `lab/` directory to understand how the same routing intent is expressed across each layer, then reason through the trade-offs.

```bash
# Review the Gateway API example: GatewayClass, Gateway, HTTPRoute with 90/10 weight split
cat lab/gateway-api-example.yaml

# Review the Istio equivalent: Gateway, VirtualService, DestinationRule with retry and circuit breaker
cat lab/istio-example.yaml

# Compare the two approaches side by side using diff
diff <(grep -v '^#' lab/gateway-api-example.yaml) <(grep -v '^#' lab/istio-example.yaml)

# Identify: which fields have no equivalent in the other API?
# Gateway API HTTPRoute: no circuit breaker, no retry policy, no outlier detection
# Istio VirtualService: no ReferenceGrant equivalent, no listener-level namespace isolation
```

## What to commit
- Add talk track for "Why not just Gateway API?" grounded in specific API gaps: no DestinationRule equivalent (circuit breaker, outlier detection, connection pool), no mTLS policy surface (PeerAuthentication has no Gateway API equivalent), retry policies require GEP-713 policy attachment which is not yet widely implemented.
- Add notes on the ReferenceGrant security model as a canonical interview question: what happens without it, how to provision it at scale, and why it is designed this way.
