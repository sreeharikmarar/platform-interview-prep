# Multi-Cluster Routing: East-West Gateways, Tier-2 Gateways, Failure Domains

## What you should be able to do
- Explain the full data path of a cross-cluster request — from sidecar through EWG to remote cluster — naming the specific Envoy and Istio objects at each hop.
- Describe the difference between an East-West Gateway and a Tier-2 Gateway, and articulate when you need each.
- Design a deterministic failover matrix for a multi-cluster service topology and map it to EDS priority levels.

## Mental Model

Multi-cluster routing is an exercise in expressing failure domains and trust boundaries in machine-readable form. A failure domain is any unit of correlated failure: a zone (rack-level power), a region (cloud provider AZ group), a cluster (a single Kubernetes control plane). The goal of multi-cluster routing is to ensure that traffic can survive the loss of any single failure domain with bounded blast radius, and that the routing system itself does not become a single point of failure. The first design question is always: what are my failure domains, and which services must survive each category of failure?

East-West Gateways (EWGs) are the data plane mechanism that makes cross-cluster traffic possible inside a service mesh. An EWG is an Envoy instance deployed in each cluster specifically to relay traffic between clusters. Unlike a north-south ingress gateway that terminates TLS and routes based on HTTP semantics, an EWG operates in AUTO_PASSTHROUGH mode: it reads the SNI field from the incoming TLS handshake and uses that to select an upstream cluster, without terminating the TLS session. The mTLS from the originating sidecar passes through the EWG intact, meaning the workload identity (SPIFFE SVID) is preserved end-to-end and the destination sidecar can enforce PeerAuthentication policy normally. The EWG is a tunnel, not a proxy.

Tier-2 Gateways sit above EWGs as an aggregation and isolation layer. Where an EWG connects exactly two clusters, a Tier-2 sits in front of multiple EWGs and makes routing decisions: it knows which clusters are healthy, applies the failover ordering, and can shift traffic deterministically based on weights. The Tier-2 is where you implement multi-region failover logic rather than pushing that complexity into every individual service. In large organizations, the Tier-2 also provides a clear blast radius boundary — a misconfigured EWG in cluster B only affects traffic routed through that specific EWG; the Tier-2 can detect the failure and route around it. Think of the EWG as a dumb tunnel and the Tier-2 as the intelligent router that decides which tunnel to use.

The control plane's responsibility in multi-cluster routing is to maintain a consistent and current view of endpoints across all clusters and publish it via xDS to the appropriate sidecars and gateways. Istio solves this with the remote secret model: each cluster's istiod is given credentials (a kubeconfig-style secret) to watch the Kubernetes API server of every other cluster in the mesh. Istiod in cluster A watches Services and Endpoints in cluster B, constructs EDS entries for those remote endpoints with the EWG of cluster B as the gateway address, and pushes that to sidecars in cluster A. The sidecar believes it is talking directly to a remote pod IP; Envoy actually sends the connection to the EWG, which forwards it. The correctness of the entire system depends on the control plane maintaining fresh endpoint data — endpoint discovery latency is a first-class operational concern.

## Key Concepts

- **East-West Gateway (EWG)**: An Envoy instance deployed per cluster, exposed via a LoadBalancer Service on port 15443, that relays cross-cluster mTLS traffic using SNI-based routing in AUTO_PASSTHROUGH mode. It does not terminate TLS.
- **AUTO_PASSTHROUGH**: An Istio Gateway mode where Envoy forwards raw TLS streams to upstreams selected by SNI, without inspecting or modifying the TLS payload. The SNI value encodes the destination service name, namespace, and cluster.
- **Tier-2 Gateway**: An Envoy or Istio gateway that aggregates multiple EWGs, applies failover ordering across clusters, and provides a single routing control point for multi-cluster traffic. Sits logically above EWGs in the traffic path.
- **Failure domain**: Any unit of correlated failure — zone, region, or cluster. Defining failure domains is the prerequisite to designing failover matrices and EDS priority levels.
- **Trust boundary**: The boundary across which SPIFFE trust domain validation applies. Clusters in the same trust domain share a root CA; clusters in different trust domains require explicit trust federation (cross-trust-domain SAN matching or trust bundle exchange).
- **SNI-based routing**: Routing decisions made on the `server_name` field of the TLS ClientHello without decrypting the payload. Enables a single EWG port to route traffic to any service in the remote cluster.
- **Remote secret model**: Istio's mechanism for multi-cluster endpoint discovery. A Kubernetes Secret containing a kubeconfig is created in each cluster's `istio-system` namespace; istiod uses it to watch the Kubernetes API of remote clusters and import their endpoints into the local EDS snapshot.
- **Primary-remote vs multi-primary**: Two Istio multi-cluster topologies. Multi-primary: each cluster runs its own istiod and watches all other clusters. Primary-remote: only one cluster runs istiod, which manages all clusters; remote clusters have no local istiod and are fully dependent on the primary's availability.
- **Endpoint discovery latency**: The delay between a pod becoming ready (or terminating) in a remote cluster and that change being reflected in the local cluster's EDS snapshot. In Istio, this is: pod ready → remote API server → remote istiod → local istiod (via remote secret watch) → EDS push → local sidecar ACK. Each hop adds latency, typically 1–10 seconds under normal conditions.
- **Locality-aware routing across clusters**: Extending Envoy's `LocalityLbEndpoints` priority mechanism to treat clusters as separate priority levels. Local cluster endpoints are priority 0; a geographically close cluster is priority 1; a distant fallback cluster is priority 2.
- **Deterministic failover matrix**: A pre-defined table mapping each service to its ordered list of clusters for failover (P0/P1/P2), derived from failure domain analysis. This is expressed in Envoy EDS as priority levels and in Istio as DestinationRule `trafficPolicy.outlierDetection` combined with ServiceEntry locality weights.
- **Split-horizon DNS**: A DNS design where the same hostname resolves to different IP addresses depending on the client's network location. In multi-cluster meshes, this is used to route same-zone or same-cluster traffic without crossing cluster boundaries when local endpoints are available.

## Internals

### East-West Gateway Architecture

The EWG is a standalone Envoy deployment distinct from the north-south ingress gateway. Its Istio Gateway resource uses `mode: AUTO_PASSTHROUGH` on port 15443 with a wildcard hosts selector (`"*.local"`). This produces an Envoy Listener on port 15443 whose filter chains are configured without an HCM. Instead, the Listener has a `TcpProxy` network filter that uses the SNI value as the cluster name — Envoy selects the upstream cluster based entirely on the TLS ClientHello's server name extension.

The SNI value in cross-cluster mTLS traffic is formatted as: `outbound_.8080_._.httpbin.default.svc.cluster.local`. This encodes the direction (outbound), port, subset, service name, namespace, and cluster domain. The EWG's Envoy reads this SNI and maps it to a cluster that represents the destination service on the remote cluster's pod network. The cluster points at the actual pod IPs of the destination service, discovered via EDS. From the destination sidecar's perspective, the connection arrived from an IP in the EWG's pod CIDR — it looks like any other inbound mTLS connection and the PeerAuthentication policy applies normally.

Cross-cluster endpoint discovery requires the source cluster's istiod to watch the remote cluster's API server. When the platform team creates a remote secret (`kubectl create secret generic cluster-b --from-file=cluster-b.kubeconfig -n istio-system --dry-run=client -o yaml | kubectl label ...`), istiod in cluster A starts a watch on cluster B's API server. It imports cluster B's Services and Endpoints into its local registry, maps each remote endpoint to a `ServiceEntry` with the EWG IP as the gateway address, and pushes this to local sidecars via EDS. The local sidecar routes traffic addressed to the remote service's ClusterIP through the EWG of cluster B. The EWG receives the connection, reads the SNI, and forwards it to the actual pod in cluster B. The sequence is: local sidecar → EWG-B (port 15443, SNI routing) → remote pod sidecar.

### Tier-2 Gateway Pattern

A Tier-2 gateway is warranted when you have three or more clusters and need centralized failover logic, or when you need to isolate the blast radius of a single cluster's EWG from the rest of the fleet. Without a Tier-2, each cluster's sidecars have direct EWG connections to every other cluster, which means a broken EWG in cluster C directly affects sidecars in cluster A and B. With a Tier-2, cluster A's sidecars only talk to the Tier-2; the Tier-2 decides whether to route to EWG-B, EWG-C, or neither based on active health state. The sidecar's blast radius is contained to the Tier-2.

The Tier-2 differs from an EWG in that it does not use AUTO_PASSTHROUGH. The Tier-2 terminates and re-originates TLS, making it a full L7 proxy. This gives it access to HTTP headers, path, and authority for routing decisions. It applies the failover ordering logic using Envoy's priority and locality-weighted load balancing across the EWG endpoints. When cluster B's EWG fails health checks on the Tier-2, the Tier-2 promotes cluster C endpoints from priority 1 to effective priority 0 (via the overflow mechanism). The individual sidecars see none of this; from their perspective they have a healthy connection to the Tier-2.

The cost of the Tier-2 is an extra network hop and an additional TLS termination/origination pair on every cross-cluster request. This typically adds 1–3ms of latency depending on the data center proximity. This cost is acceptable in active-passive or active-standby configurations where cross-cluster traffic is the exception. For hot active-active traffic patterns where cross-cluster calls are in the critical path, the EWG-direct model (no Tier-2) is preferred, with locality-aware routing in the sidecar doing the priority-based selection.

### Multi-Cluster Endpoint Publishing

Istio supports two multi-cluster topologies with different operational characteristics. In multi-primary mode, each cluster runs its own istiod, each istiod watches all other clusters via remote secrets, and each istiod pushes the complete endpoint set (local + remote) to its own cluster's sidecars. This is the recommended topology for production: each cluster is independently operable (if the cross-cluster API watch fails, the cluster continues serving local traffic with stale remote endpoints). The failure of one istiod only affects its own cluster.

In primary-remote mode, a single primary istiod manages all clusters. Remote clusters run no istiod; their sidecars connect directly to the primary's xDS endpoint over the network. This is simpler to operate but introduces the primary cluster as a single point of failure: if the primary's istiod is unreachable, remote cluster sidecars cannot receive config updates. Remote sidecars continue serving traffic with their last known config (Envoy's ADS semantics preserve the last accepted snapshot), but new deployments, route changes, and certificate rotations stop propagating.

Endpoint discovery latency compounds across hops in multi-primary mode. A pod in cluster B that passes its readiness probe creates an Endpoints update in cluster B's API server. The local istiod in cluster B picks this up within 100–500ms (Informer resync). Istiod in cluster A is watching cluster B's API server via the remote secret; it picks up the change in another 100–500ms. Istiod in cluster A then pushes an EDS update to all affected sidecars in cluster A, each of which must ACK the update. Total latency from pod-ready to sidecar-active is typically 1–5 seconds under normal control plane load. During a failover, stale endpoints that have not yet been removed from EDS will receive traffic for this window — outlier detection on the sidecar or EWG will eject them after the first observed failure, but the first request may fail.

## Architecture Diagram

```
  REGION-A (us-east-1)                            REGION-B (us-west-2)
  ┌──────────────────────────────────┐             ┌──────────────────────────────────┐
  │  CLUSTER A (primary)             │             │  CLUSTER B                       │
  │                                  │             │                                  │
  │  ┌──────────┐   ┌─────────────┐  │             │  ┌──────────┐   ┌─────────────┐ │
  │  │ sidecar  │──►│  local svc  │  │             │  │ sidecar  │──►│  local svc  │ │
  │  └──────────┘   └─────────────┘  │             │  └──────────┘   └─────────────┘ │
  │       │                          │             │       ▲                          │
  │       │ cross-cluster            │             │       │ mTLS preserved           │
  │       ▼  (mTLS, SNI encoded)     │             │       │                          │
  │  ┌──────────┐                    │             │  ┌──────────┐                    │
  │  │  EWG-A   │◄──────────────────────────────►│  │  EWG-B   │                    │
  │  │ :15443   │   port 15443       │             │  │ :15443   │                    │
  │  │ SNI-route│   LoadBalancer IP  │             │  │ SNI-route│                    │
  │  └──────────┘                    │             │  └──────────┘                    │
  │       │                          │             │       │                          │
  │  istiod-A ──watch──► cluster-B   │             │  istiod-B ──watch──► cluster-A  │
  │  (remote secret)                 │             │  (remote secret)                 │
  └──────────────────────────────────┘             └──────────────────────────────────┘
                    │                                           │
                    └───────────────────┬───────────────────────┘
                                        │
                              ┌─────────▼──────────┐
                              │    TIER-2 GATEWAY   │
                              │  (optional layer)   │
                              │                     │
                              │  Routes to EWG-A    │
                              │  or EWG-B based on  │
                              │  health + priority  │
                              │                     │
                              │  P0: cluster-A      │
                              │  P1: cluster-B      │
                              └────────────────────-┘
                                        ▲
                                        │
                              north-south ingress
                              (client traffic)

  CONTROL PLANE CONNECTIONS:
  istiod-A ──(remote secret watch)──► cluster-B API server
  istiod-B ──(remote secret watch)──► cluster-A API server
  Both istiods push EDS to local sidecars with remote EWG IPs as gateway addresses
```

## Failure Modes & Debugging

### 1. Asymmetric Routing (One Cluster Sees Remote Endpoints, Other Does Not)

**Symptoms**: Requests from cluster A to cluster B succeed; requests from cluster B to cluster A fail with `503 NR` or `503 UH`. `istioctl proxy-status` in cluster B shows EDS for cluster A's services is empty or stale. No errors on the cluster A side. The asymmetry is the tell — if it were a network problem, both directions would fail.

**Root Cause**: The remote secret in cluster B is missing, expired, or references credentials that no longer have RBAC access to cluster A's API server. Istiod in cluster B cannot watch cluster A's Services and Endpoints, so it has never built EDS entries for cluster A. Cluster A's istiod has a valid secret for cluster B, so A→B traffic works. This frequently happens after cluster certificate rotation, kubeconfig expiry, or when the cluster A service account used by the remote kubeconfig has had its permissions revoked.

**Blast Radius**: All cross-cluster traffic from cluster B to cluster A is broken. Services in cluster B that depend on cluster A for any failover scenario are silently operating without their intended redundancy. North-south traffic entering cluster B that needs to reach services homed in cluster A is affected.

**Mitigation**: Automate remote secret rotation as part of cluster credential lifecycle. Use short-lived credentials for the remote watch service account and rotate via a controller. Monitor `pilot_remote_cluster_sync_errors` on each istiod and alert when it is nonzero. Validate remote secret health with a synthetic probe: a periodic check that istiod in each cluster can enumerate services from every other cluster via its imported endpoint cache.

**Debugging**:
```bash
# Check remote secrets in each cluster
kubectl get secrets -n istio-system -l istio/multiCluster=true

# Inspect istiod logs for remote watch errors
kubectl logs -n istio-system deploy/istiod | grep -E "remote|cluster|watch" | tail -30

# Check if istiod in cluster-B has imported endpoints from cluster-A
istioctl proxy-config endpoint deploy/my-service.default \
  --cluster "outbound|8080||my-svc.default.svc.cluster.local" \
  --context cluster-b-context

# Compare endpoint counts from each cluster context
istioctl proxy-status --context cluster-a-context | head -20
istioctl proxy-status --context cluster-b-context | head -20

# Verify the remote kubeconfig in the secret is valid
kubectl get secret cluster-a -n istio-system -o jsonpath='{.data.cluster-a\.kubeconfig}' | \
  base64 -d > /tmp/cluster-a.kubeconfig
kubectl --kubeconfig=/tmp/cluster-a.kubeconfig get services -A | head -10
```

---

### 2. Stale Endpoints Causing Cross-Cluster Failures During Rollouts

**Symptoms**: During a rolling deployment in cluster B, requests from cluster A intermittently fail with `503 UF` (upstream connection failure) or return 5xx responses. The failure window is 2–10 seconds per terminated pod. Retries on the cluster A side succeed on subsequent attempts. `cluster.outbound|8080||my-svc.default.svc.cluster.local.upstream_rq_5xx` counter increments on the EWG or on cluster A sidecars.

**Root Cause**: When cluster B terminates a pod during a rolling update, the Endpoints object in cluster B is updated immediately. However, the signal must propagate: cluster B API server → istiod-B → istiod-A (via remote watch) → EDS push to cluster A sidecars. During this propagation window (typically 2–8 seconds), cluster A sidecars still have the terminating pod's IP in their endpoint set. They send requests to that IP, the EWG in cluster B routes to it, and the request hits a pod in SIGTERM state that has already closed its listener. The first few requests to this stale endpoint fail before outlier detection ejects it.

**Blast Radius**: Affects only in-flight requests during rolling updates in a remote cluster. Not a steady-state failure. At scale (hundreds of pods rolling), the stale-endpoint window accumulates across many pods and can produce a sustained error rate rather than brief spikes.

**Mitigation**: Configure `preStop` lifecycle hooks on pods in cluster B to sleep for 5–10 seconds before shutdown, giving the control plane time to propagate endpoint removal before the pod stops accepting connections. Enable outlier detection on the cluster A side with a short `interval` (5s) so the first failed connection ejects the stale endpoint quickly. Set `minHealthPercent` in Istio DestinationRule's `trafficPolicy` so the outlier detector does not eject too aggressively. Use `terminationGracePeriodSeconds` that exceeds the expected endpoint propagation latency.

**Debugging**:
```bash
# Watch endpoint count in cluster-A's view of cluster-B's service during a rollout
watch -n2 "istioctl proxy-config endpoint deploy/frontend.default \
  --cluster 'outbound|8080||backend.default.svc.cluster.local' \
  --context cluster-a-context | grep -c HEALTHY"

# Check outlier detection ejections on the EWG in cluster-B
kubectl exec -n istio-system deploy/istio-eastwestgateway -- \
  curl -s localhost:15000/clusters | grep "outlier_detection"

# Measure endpoint propagation latency by timing a pod deletion
kubectl delete pod backend-abc-def -n default --context cluster-b-context &
time kubectl --context cluster-a-context exec -n default deploy/client -- \
  curl -s istiod.istio-system:15014/debug/endpointz | grep backend

# Envoy stats for stale-endpoint-related errors on a cluster-A sidecar
kubectl exec -n default deploy/frontend -c istio-proxy -- \
  curl -s localhost:15000/stats | grep "outbound.*backend.*upstream_rq_5xx"
```

---

### 3. Identity Mismatch Across Trust Boundaries

**Symptoms**: Cross-cluster requests fail with TLS handshake errors. Envoy access logs on the destination sidecar show `%RESPONSE_FLAGS%` as `DC` (downstream connection terminated) or the cluster's `ssl.fail` counter increments. `istioctl proxy-config secret` shows valid certificates on both sides, but the root CA certificates differ. `PeerAuthentication` policy on the destination denies the connection even though the application protocol is correct.

**Root Cause**: Two clusters have different root Certificate Authorities. Istio's mTLS relies on SPIFFE X.509 SVIDs signed by a shared root CA (or by intermediate CAs chained to the same root) to establish workload identity. If cluster A uses CA-1 and cluster B uses CA-2, then the sidecar in cluster B rejects the certificate presented by cluster A's EWG connection because it is not signed by a trusted root. This happens when clusters were bootstrapped independently, when CAs were rotated separately, or when different cert-manager issuers were used per cluster without federated trust.

**Blast Radius**: All cross-cluster mTLS traffic fails. This includes the EWG-to-sidecar hop and any direct pod-to-pod traffic. If PeerAuthentication is set to PERMISSIVE, requests may fall back to plaintext, which is a security regression, not a latency issue.

**Mitigation**: Use a shared intermediate CA model: a central PKI signs per-cluster Istio CAs (plugged in via `cacerts` secret in `istio-system`), all of which chain to the same root. When adding a new cluster, provision its Istio CA from the same root before joining it to the mesh. For clusters that already have divergent CAs, use Istio's trust domain federation by adding the remote trust bundle to each cluster's `MeshConfig.trustDomainAliases` and configuring `DestinationRule.trafficPolicy.tls.subjectAltNames` to accept SVIDs from both trust domains during the migration window.

**Debugging**:
```bash
# Inspect the root CA on each cluster's istiod
kubectl get secret cacerts -n istio-system -o jsonpath='{.data.ca-cert\.pem}' \
  --context cluster-a-context | base64 -d | openssl x509 -noout -subject -issuer -fingerprint

kubectl get secret cacerts -n istio-system -o jsonpath='{.data.ca-cert\.pem}' \
  --context cluster-b-context | base64 -d | openssl x509 -noout -subject -issuer -fingerprint

# Compare the fingerprints — they must match (same root) or chain to the same root
# Inspect the workload certificate presented by a pod in cluster-A
istioctl proxy-config secret deploy/frontend.default --context cluster-a-context

# Check TLS handshake failures on the EWG in cluster-B
kubectl exec -n istio-system deploy/istio-eastwestgateway -- \
  curl -s localhost:15000/stats | grep "ssl.fail\|handshake_error"

# Check trust domain configuration in MeshConfig
kubectl get configmap istio -n istio-system -o jsonpath='{.data.mesh}' | \
  grep -E "trustDomain|trustDomainAliases"
```

---

### 4. EWG Capacity Exhaustion

**Symptoms**: Cross-cluster request latency increases non-linearly with traffic volume. The EWG pods show CPU saturation. `listener.0.0.0.0_15443.downstream_cx_active` gauge is at or near the EWG Envoy's `max_connections` circuit breaker threshold. New cross-cluster connections receive `503` responses with response flag `UO` (upstream overflow) or `CC` (downstream connection rejection). Connections are being queued or dropped at the EWG listener.

**Root Cause**: All cross-cluster traffic for a cluster is funneled through a small EWG deployment (often defaulting to 1 replica). Envoy's connection pool is per-worker-thread, so single-replica EWGs with the default concurrency setting are limited in throughput. In high-traffic scenarios (burst traffic, failover event that redirects large volumes cross-cluster), the EWG becomes the throughput bottleneck. EWGs are often under-provisioned because in steady state (locality-aware routing sending most traffic local) they carry minimal load, masking the failure mode until a failover event occurs.

**Blast Radius**: All cross-cluster traffic for services that route through the saturated EWG. During a failover event where local cluster capacity is reduced and cross-cluster traffic spikes, this is precisely when EWG capacity is most critical and most likely to be exhausted simultaneously.

**Mitigation**: Scale EWG horizontally (3+ replicas with pod anti-affinity across zones). Use HPA on `envoy_listener_downstream_cx_active` or on EWG pod CPU. Right-size EWG resources based on peak failover traffic, not steady-state traffic. Set Envoy `--concurrency` to match the number of CPU cores available. Configure the EWG Service's `sessionAffinity: None` to distribute connections across all EWG replicas. Run load tests that simulate regional failover traffic volumes against the EWG fleet specifically.

**Debugging**:
```bash
# Check current active connections on all EWG pods
kubectl get pods -n istio-system -l app=istio-eastwestgateway -o name | \
  xargs -I{} kubectl exec -n istio-system {} -- \
  curl -s localhost:15000/stats | grep "downstream_cx_active"

# Check connection overflow (circuit breaker trips)
kubectl exec -n istio-system deploy/istio-eastwestgateway -- \
  curl -s localhost:15000/stats | grep -E "downstream_cx_overflow|upstream_cx_overflow|upstream_rq_pending_overflow"

# Check EWG pod CPU and memory
kubectl top pods -n istio-system -l app=istio-eastwestgateway

# Inspect listener-level connection stats
kubectl exec -n istio-system deploy/istio-eastwestgateway -- \
  curl -s localhost:15000/listeners | grep -A5 "15443"

# Check if any EWG pods are being OOMKilled (a sign of under-provisioning)
kubectl describe pods -n istio-system -l app=istio-eastwestgateway | \
  grep -A5 "OOMKilled\|Terminated"
```

## Lightweight Lab

Design exercise (no cluster required) — complete all steps using the reference topology and YAML in `lab/ewg-topology.yaml`:

```bash
# Step 1: Review the reference topology YAML
cat /path/to/lab/ewg-topology.yaml

# Step 2: Draw your 3-cluster failure domain map (see lab/README.md for the exercise)
# Clusters: cluster-a (us-east-1a, us-east-1b), cluster-b (us-east-1c), cluster-c (us-west-2a)
# Identify: failure domains, EWG placement, Tier-2 placement

# Step 3: Inspect what Istio EWG config looks like in a running cluster
# (requires a cluster with Istio multi-cluster configured)
kubectl get gateway istio-eastwestgateway -n istio-system -o yaml

# Step 4: Check what endpoints a sidecar has for a cross-cluster service
istioctl proxy-config endpoint deploy/frontend.default \
  --cluster "outbound|8080||backend.default.svc.cluster.local"

# Step 5: Verify remote cluster endpoint import (multi-primary)
kubectl get serviceentries -A | grep -v kubernetes
```

## What to commit
- Draw your actual or hypothetical multi-cluster topology, label failure domains, and annotate with EWG and Tier-2 placement rationale.
- Map your failover matrix (from lab) to the specific EDS priority levels in `ewg-topology.yaml` and note which scenarios are covered vs which require manual intervention.
