# Lab: Multi-Cluster Routing — Failure Domain Mapping and Failover Matrix

This lab is a design exercise with an optional simulation component. The primary output is a documented multi-cluster topology with a failover matrix that maps to concrete Envoy EDS priority configuration. No running cluster is required for steps 1–4. Step 5 is optional and uses two kind clusters with NodePort-based EWG simulation.

## Prerequisites

- Familiarity with Istio East-West Gateway concepts (see topic README)
- `kubectl` and `istioctl` installed (for Step 5)
- Docker and `kind` installed (for Step 5 only)
- Review `ewg-topology.yaml` in this directory before starting

## Topology for This Lab

You are a platform engineer responsible for a three-cluster mesh with the following topology:

```
  REGION: us-east-1                      REGION: us-west-2
  ┌──────────────────────────┐           ┌────────────────────────┐
  │  cluster-a               │           │  cluster-c             │
  │  zone: us-east-1a        │           │  zone: us-west-2a      │
  │  zone: us-east-1b        │           │                        │
  │                          │           │  workloads:            │
  │  workloads:              │           │  - payment-service     │
  │  - frontend              │           │  - fraud-detection     │
  │  - order-service         │           │                        │
  │  - payment-service       │           └────────────────────────┘
  │                          │
  └──────────────────────────┘
  ┌──────────────────────────┐
  │  cluster-b               │
  │  zone: us-east-1c        │
  │                          │
  │  workloads:              │
  │  - order-service (DR)    │
  │  - payment-service (DR)  │
  │                          │
  └──────────────────────────┘
```

cluster-b is a dedicated disaster-recovery cluster in the same region as cluster-a but in a separate availability zone. cluster-c is the cross-region cluster used for global distribution of payment-service and fraud-detection.

---

## Step 1: Map Failure Domains and Place Gateways

Draw (on paper or in a text file) the full topology. For each cluster, answer:

1. What failure scenarios does this cluster need to survive?
   - Zone failure: loss of a single AZ within cluster-a
   - Cluster failure: loss of cluster-a control plane (etcd or API server)
   - Region failure: loss of the entire us-east-1 region

2. Where does each EWG sit, and why?
   - Each cluster gets exactly one EWG, deployed in its own namespace (`istio-system`) and exposed via a cloud LoadBalancer on port 15443. The EWG must be in a separate deployment from the north-south ingress gateway — they serve different purposes and need independent scaling.
   - EWG placement is per-cluster, not per-zone. This is a deliberate trade-off: a single EWG per cluster is simpler to operate, but a zone-level failure that takes out the nodes running EWG pods can disrupt cross-cluster traffic. Mitigation: schedule EWG pods with anti-affinity across zones (see `ewg-topology.yaml` for the affinity spec).

3. When is a Tier-2 warranted in this topology?
   - Not required for a two-cluster setup. Warranted at three or more clusters when you want a single routing decision point for failover orchestration, or when you need to hide internal cluster topology from the north-south ingress (the ingress talks only to the Tier-2, not to individual EWGs).
   - For this topology: a Tier-2 in front of cluster-a and cluster-b EWGs provides a single endpoint for order-service consumers in cluster-c. Without a Tier-2, cluster-c sidecars must be configured with both EWG-A and EWG-B endpoints and their own priority ordering.

**Expected output**: a labeled topology diagram noting failure domains, EWG placement per cluster, and whether a Tier-2 is used and why.

---

## Step 2: Build the Failover Matrix

For each service in the topology, define the failover ordering (P0/P1/P2) across clusters. P0 = primary, P1 = first failover target, P2 = second failover target.

| Service | P0 (primary) | P1 (first failover) | P2 (second failover) | Notes |
|---|---|---|---|---|
| frontend | cluster-a | cluster-b | — | frontend is us-east only; no cross-region |
| order-service | cluster-a | cluster-b | — | DR only; order-service is not deployed in us-west-2 |
| payment-service | cluster-a | cluster-c | cluster-b | cross-region active; cluster-b is last resort |
| fraud-detection | cluster-c | cluster-a | — | primary in us-west-2; cluster-a is fallback |

Answer the following questions for each row:
- What triggers promotion from P0 to P1? (outlier detection consecutive failures, active health check failure, manual override)
- What is the expected latency impact of each failover level?
- What is the replication lag risk at each level? (does cluster-b have fully current data for payment-service when cluster-a fails?)

---

## Step 3: Map the Failover Matrix to Envoy EDS Priority Config

Open `ewg-topology.yaml`. It contains an Istio `DestinationRule` that configures locality-aware routing with priority levels for `payment-service`. Study the `trafficPolicy.connectionPool`, `trafficPolicy.outlierDetection`, and the `ServiceEntry` `endpoints` locality annotations.

Work through these questions:

1. How does Istio translate the `DestinationRule.trafficPolicy.outlierDetection` block into Envoy outlier detection config on the sidecar? Name the xDS field.
   - Answer: it populates `Cluster.outlier_detection` in CDS, including `consecutive_5xx`, `interval`, `base_ejection_time`, and `max_ejection_percent`.

2. How do the `endpoints[].locality` and `endpoints[].priority` fields in a `ServiceEntry` map to Envoy's `ClusterLoadAssignment.endpoints[].locality` and `ClusterLoadAssignment.endpoints[].priority` in EDS?
   - Answer: they map directly — istiod translates ServiceEntry endpoint localities to EDS `LocalityLbEndpoints.locality` (region/zone/subzone) and preserves the priority integer. Envoy uses the priority to implement overflow: when all priority-N endpoints are below the panic threshold, it spills to priority-N+1.

3. What is the `panic_threshold` and when does Envoy ignore health status entirely?
   - Answer: `panic_threshold` defaults to 50%. When fewer than 50% of endpoints in the highest-priority group are healthy, Envoy enters "panic mode" and routes to all endpoints (healthy and unhealthy) to avoid sending all traffic to a tiny healthy pool. For cross-cluster failover, this means if half your local endpoints fail, Envoy may start routing to all local endpoints rather than failing over to the remote cluster — which is often not the desired behavior. Override with `common_lb_config.healthy_panic_threshold: 0` to force strict failover.

4. For the `payment-service` failover matrix (cluster-a P0, cluster-c P1, cluster-b P2): write the `ServiceEntry` `endpoints` block that expresses this priority ordering. Reference the format used in `ewg-topology.yaml`.

---

## Step 4: Identify Blast Radius for Each Failure Scenario

For each failure scenario below, answer: which services are affected, what is the user-visible impact, and how long does automatic recovery take?

**Scenario A: Single zone failure (us-east-1a loses network)**
- Affected clusters: cluster-a (partial — only the us-east-1a nodes)
- EWG impact: if EWG pods are only on us-east-1a nodes, cross-cluster routing from cluster-a breaks until EWG pods reschedule on us-east-1b
- Recovery: EWG pod reschedule + health check detection on consuming sidecars = 30–90 seconds without Tier-2; near-instant with Tier-2 (Tier-2 has EWG health check via active probing)
- Mitigation: EWG anti-affinity across zones (see `ewg-topology.yaml` pod anti-affinity spec)

**Scenario B: Full cluster-a failure (control plane unreachable)**
- Affected clusters: cluster-a is dark; cluster-b and cluster-c must absorb cluster-a traffic
- EWG impact: EWG-A is unreachable; consuming clusters must failover their EDS endpoint tables to P1 clusters
- Discovery lag: cluster-b and cluster-c istiods were watching cluster-a's API server; when it goes down, the remote watch fails. istiod in cluster-b and cluster-c will stop receiving updates but will retain the last known endpoint set. They will not proactively remove cluster-a endpoints unless outlier detection on consuming sidecars ejects them
- Recovery: outlier detection ejects stale cluster-a endpoints within 1–3 failure cycles (typically 30–60 seconds of retries); Envoy overflows to P1 automatically
- Risk: if cluster-b's services had been scaling during cluster-a's outage, cluster-b's endpoint count may be stale from the perspective of cluster-c (cluster-c's istiod was watching cluster-b, not affected by cluster-a failure)

**Scenario C: EWG-A capacity exhaustion during failover**
- Affected: all cross-cluster traffic routed through EWG-A (A→B, A→C, and any traffic using A as a transit point)
- Symptoms: `listener.0.0.0.0_15443.downstream_cx_active` saturates; new connections get `503 UO` (upstream overflow)
- Detection: `downstream_cx_active` gauge on EWG pods; alerting threshold should be 70% of max_connections
- Mitigation: pre-scale EWG replicas before a planned failover drill; use HPA with a custom metric on active connection count; verify EWG resource requests/limits are set to allow burstable scaling

**Scenario D: Remote secret expiry (istiod-A loses watch on cluster-B)**
- Affected: A→B traffic fails silently (A-side sidecars have stale endpoint tables; new B pods are not visible to A)
- This is a silent degradation — existing connections to B that existed before the expiry may continue, but no new endpoint discovery happens. Rolling updates in B result in routing to removed pods.
- Detection: `pilot_remote_cluster_sync_errors{cluster="cluster-b"}` on istiod-A's Prometheus metrics; alert on this metric being greater than zero for more than 60 seconds

---

## Step 5 (Optional): Simulate with Two kind Clusters and NodePort EWG

This step simulates the EWG pattern using two kind clusters on a single machine. mTLS passthrough is approximated using a TcpProxy config. This is a functional test of the SNI routing mechanism, not a production-equivalent security setup.

```bash
# Create two kind clusters
kind create cluster --name cluster-a --config - <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
networking:
  podSubnet: "10.10.0.0/16"
  serviceSubnet: "10.20.0.0/16"
EOF

kind create cluster --name cluster-b --config - <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
networking:
  podSubnet: "10.30.0.0/16"
  serviceSubnet: "10.40.0.0/16"
EOF

# Verify both clusters are running
kubectl get nodes --context kind-cluster-a
kubectl get nodes --context kind-cluster-b

# Deploy a simple backend service in cluster-b
kubectl apply --context kind-cluster-b -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
    spec:
      containers:
      - name: backend
        image: hashicorp/http-echo:latest
        args: ["-text=response from cluster-b"]
        ports:
        - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: backend
  namespace: default
spec:
  selector:
    app: backend
  ports:
  - port: 5678
    targetPort: 5678
  type: ClusterIP
EOF

# Get cluster-b's kind node IP (used as the EWG entry point via NodePort)
CLUSTER_B_NODE_IP=$(kubectl get nodes --context kind-cluster-b -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
echo "Cluster-B node IP: $CLUSTER_B_NODE_IP"

# Deploy a NodePort service in cluster-b to simulate EWG external access
kubectl apply --context kind-cluster-b -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: ewg-sim
  namespace: default
spec:
  selector:
    app: backend
  ports:
  - port: 15443
    targetPort: 5678
    nodePort: 30443
  type: NodePort
EOF

# From cluster-a, send traffic to cluster-b via the NodePort (EWG simulation)
# In a real EWG, this connection would carry mTLS with an SNI header
# In this simulation, we verify basic cross-cluster connectivity
kubectl run -it --rm test-client --image=curlimages/curl --restart=Never \
  --context kind-cluster-a -- \
  curl -s http://${CLUSTER_B_NODE_IP}:30443

# Expected output: "response from cluster-b"

# Clean up
kind delete cluster --name cluster-a
kind delete cluster --name cluster-b
```

**What this simulates**: basic cross-cluster network reachability via a NodePort that approximates the EWG's external endpoint. In a real Istio EWG setup, replace the NodePort with a LoadBalancer Service and the backend with an actual Istio-proxied workload. The SNI routing mechanism requires the full Istio EWG Gateway resource with `mode: AUTO_PASSTHROUGH` (see `ewg-topology.yaml`).

---

## Key Takeaways

1. **Failure domains must be enumerated before topology is designed.** The failover matrix is the output of failure domain analysis, not an afterthought. EDS priority levels map directly to failure domain severity.

2. **EWG is a dumb tunnel; Tier-2 is the intelligent router.** The EWG does SNI-based TCP forwarding without TLS termination. The Tier-2 terminates TLS, reads HTTP, applies priority-based routing across EWGs, and is where multi-cluster failover logic is centralized.

3. **Endpoint discovery latency is a first-class design constraint.** The 1–8 second propagation chain (remote API server → remote istiod → local istiod → EDS push → sidecar ACK) means stale endpoints are a normal condition during rollouts. Design for it with `preStop` hooks and outlier detection tuning.

4. **Trust boundary failures are silent without correct metrics.** If root CAs diverge between clusters, `PeerAuthentication: PERMISSIVE` allows plaintext fallback. You need to monitor certificate issuer fingerprints and `pilot_remote_cluster_sync_errors` to detect trust failures before they become security incidents.

5. **EWGs must be sized for peak failover load, not steady-state load.** Locality-aware routing means EWGs carry near-zero traffic in steady state. A failover event that redirects regional traffic through an undersized EWG fleet is the highest-risk scenario. Load-test the EWG fleet specifically under simulated failover conditions.
