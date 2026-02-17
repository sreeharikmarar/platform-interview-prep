# Talk Tracks

## Q: Explain this in one minute.

**Answer:**

Multi-cluster routing is the problem of ensuring traffic can cross cluster boundaries safely, with deterministic failover when a cluster or zone fails, while preserving workload identity across the trust boundary. The mechanism is the East-West Gateway: an Envoy instance deployed in each cluster, exposed on port 15443, that operates in AUTO_PASSTHROUGH mode. Rather than terminating TLS and inspecting HTTP, the EWG reads the SNI field of the incoming TLS ClientHello — a value like `outbound_.8080_._.backend.default.svc.cluster.local` — and uses it to select the upstream cluster, forwarding the raw TLS bytes without modification. This means the mTLS session established between the source sidecar and the destination sidecar passes through the EWG intact, and the destination's PeerAuthentication policy can validate the SPIFFE identity as if the connection came from within the same cluster. The control plane — Istio istiod in multi-primary mode — discovers remote endpoints by watching remote cluster API servers via kubeconfig secrets (the remote secret model), and publishes them to local sidecars via EDS with the EWG IP as the gateway address. A Tier-2 gateway sits above multiple EWGs and centralizes the failover decision: it knows which EWGs are healthy, applies priority-based routing across clusters, and contains blast radius to a single routing decision point rather than distributing that complexity into every sidecar.

---

## Q: Walk me through the internals.

**Answer:**

Start at the source sidecar. The application in cluster A makes a request to `backend.default.svc.cluster.local`. The iptables redirect rule intercepts the outbound connection and hands it to the sidecar's Envoy on port 15001. The sidecar's Envoy has an EDS entry for `backend` that lists the remote pod IPs in cluster B, with a `gatewayAddress` pointing to EWG-B's LoadBalancer IP. Envoy initiates a mTLS connection to EWG-B on port 15443, setting the SNI to `outbound_.8080_._.backend.default.svc.cluster.local`. At EWG-B, the Listener on port 15443 has a filter chain using `TcpProxy` with `cluster` set to the SNI value — Envoy maps the incoming SNI directly to a cluster name, which points to the actual pod IPs of `backend` in cluster B's pod network. EWG-B opens a new TCP connection to the selected pod, forwarding the raw TLS bytes; the destination sidecar receives the connection, terminates TLS, and validates the SPIFFE SVID from the source workload against its PeerAuthentication policy. The entire data path has two Envoy hops (source sidecar → EWG-B → destination sidecar) and two TLS sessions (source-to-EWG and EWG-to-destination in AUTO_PASSTHROUGH mode are actually the same session — the EWG does not terminate; it's a TCP forward). The control plane path that enables this is: istiod-A watches cluster B's API server via the remote secret, imports `backend`'s Endpoints, wraps them with the EWG-B gateway address in a ServiceEntry, and pushes EDS to all sidecars in cluster A.

---

## Q: What can go wrong?

**Answer:**

The three highest-blast-radius failures are asymmetric endpoint discovery, stale endpoints during remote cluster rollouts, and trust boundary mismatches.

Asymmetric endpoint discovery means cluster A's sidecars can reach cluster B's services but cluster B's sidecars cannot reach cluster A's. The cause is almost always a broken remote secret: the kubeconfig in the `istio-system` secret has expired credentials or the referenced service account has lost RBAC permissions to the remote API server. Because the failure is directional, it looks like a network partition but all infrastructure metrics are green. The detection signal is `pilot_remote_cluster_sync_errors` on istiod — if this counter is nonzero, istiod has lost its remote watch and the endpoint tables for that cluster are stale.

Stale endpoints during remote rollouts are a timing problem inherent in multi-hop endpoint propagation. When a pod in cluster B is terminated during a rolling update, cluster B's Endpoints object is updated immediately, but the change must travel: cluster B API server → istiod-B → istiod-A (via remote watch) → EDS push to cluster A sidecars. This chain takes 1–8 seconds. During that window, cluster A sidecars route requests to the terminating pod's IP; the EWG forwards the connection, but the pod has already stopped accepting connections, and the request fails. Outlier detection on the sidecar ejects the stale endpoint after the first failure, but that first request is lost. The mitigation is `preStop` sleep hooks on the pods in the remote cluster, buying time for the control plane to propagate the removal before the pod stops listening.

Trust boundary mismatches are the most dangerous because they can be silent. If clusters were bootstrapped with different root CAs, the mTLS handshake at the destination sidecar fails because the presented SVID is not signed by a trusted root. With `PeerAuthentication: STRICT`, requests fail with a TLS error. With `PeerAuthentication: PERMISSIVE`, requests fall back to plaintext — traffic appears to succeed but workload identity is not being enforced, which is a security regression that metrics won't surface.

---

## Q: How would you debug it?

**Answer:**

Start from the failure direction — asymmetric failures point to control plane state, symmetric failures point to data plane or network. For asymmetric routing (A→B works, B→A fails), the first check is istiod's view of the remote cluster: `kubectl logs -n istio-system deploy/istiod --context cluster-b | grep -E "remote|sync|error"`. If istiod-B is logging errors watching cluster A's API server, you've found the root cause before touching any data plane. Validate the remote secret directly: extract the kubeconfig from the secret, run `kubectl --kubeconfig=/tmp/cluster-a.kubeconfig get services -A`, and see if it returns results. If not, the credentials are invalid and the secret needs to be regenerated.

For cross-cluster 503 errors that don't have a clear control plane cause, work through the data path hops. First check what endpoints the source sidecar has: `istioctl proxy-config endpoint deploy/frontend.default --cluster "outbound|8080||backend.default.svc.cluster.local"`. If the endpoint table is empty or missing the remote EWG IP, the EDS push has not happened — return to istiod. If the endpoint table has entries, check if they are marked HEALTHY or EJECTED via outlier detection. For TLS failures, `istioctl proxy-config secret deploy/frontend.default` dumps the live workload certificate including issuer and expiry. Compare the issuer fingerprint with `kubectl get secret cacerts -n istio-system -o jsonpath='{.data.ca-cert\.pem}' | base64 -d | openssl x509 -noout -fingerprint` on both clusters. If the fingerprints differ, you have a trust boundary mismatch. For EWG-specific failures, `kubectl exec -n istio-system deploy/istio-eastwestgateway -- curl -s localhost:15000/stats | grep -E "cx_active|overflow|ssl.fail"` tells you whether the EWG is saturated, dropping connections, or failing TLS sessions before a single byte of application data is exchanged.

---

## Q: How would you apply this in a platform engineering context?

**Answer:**

The primary platform engineering application is building a resilient multi-region service topology with defined failover SLOs. The design starts with a failure domain matrix: you enumerate your services, classify each by availability requirement (can this service go dark if us-east-1 loses a zone? what about if it loses the entire region?), and then express the failover ordering as EDS priority levels in Istio DestinationRules. Services that must survive zone failure get local-zone endpoints at priority 0, cross-zone (same region) endpoints at priority 1. Services that must survive regional failure add remote cluster endpoints at priority 2. This matrix is codified in `DestinationRule` resources and applied via GitOps — it is not a runbook to be executed during an incident but a configuration that is tested continuously.

The EWG fleet is a platform team responsibility, not an application team responsibility. Platform engineers deploy and size EWGs based on failure scenario traffic projections: if region A fails and all A traffic shifts to region B, how many connections per second will EWG-B need to handle? EWGs are sized for peak failover load, not steady-state load, because steady-state cross-cluster traffic is minimal under locality-aware routing. This is a common gap — teams size EWGs based on monitoring that shows near-zero cross-cluster traffic, then discover the EWGs are the bottleneck during the first real failover drill.

From a trust and security perspective, the platform team owns the shared root CA and the istiod `cacerts` provisioning lifecycle. Every cluster joining the mesh gets an intermediate CA signed by the shared root before it is connected via remote secrets. This ensures mTLS identity is valid across cluster boundaries from day one. The remote secret credentials use a least-privilege service account in each remote cluster with read access only to the resources istiod needs: Services, Endpoints, Pods, ConfigMaps, Nodes. These credentials are rotated on a short schedule (7–30 days) via a controller, and `pilot_remote_cluster_sync_errors` is a top-level SLI on the mesh reliability dashboard. An error here means the failover guarantee is silently broken until it is fixed.
