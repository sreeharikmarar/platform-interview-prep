# Capstone: Design a Next-Gen Platform

## What you should be able to do

- Present a coherent end-to-end platform architecture that separates developer intent (CRDs, policy declarations) from infrastructure realization (controllers, xDS snapshots, cloud provider APIs), and explain why that separation matters for operability and evolution.
- Articulate the multi-tenancy model in concrete terms: what is isolated per tenant, what is shared, what the blast radius of a misconfiguration is, and how isolation is enforced at the network, identity, and RBAC layers.
- Describe how platform changes — CRD schema versions, controller updates, policy rule changes — are rolled out safely across hub and spoke clusters without breaking in-flight tenant workloads.
- Explain how inference workloads are integrated as a first-class platform service: InferenceService CRD, GPU quota, token budget enforcement, and the Envoy-based inference gateway.
- Debug a tenant service outage by reasoning systematically from symptoms through the full platform stack: Git state, ArgoCD sync, CRD status, controller reconciliation events, spoke cluster resource state, mesh config, and Envoy access logs.

## Mental Model

The central idea of a next-generation platform is that infrastructure is a compiler problem. Developers express what they want — a service with three replicas, mTLS enforced, exposed on a specific subdomain, rate-limited to 500 RPS — using CRDs that read like a high-level programming language. Platform controllers then compile that declaration into the specific, version-coupled infrastructure objects that the underlying systems understand: Kubernetes Deployments, Envoy VirtualService and DestinationRule objects, certificate Secrets, NetworkPolicy rules, and xDS configuration snapshots. This mirrors the architecture of a compiler: there is a frontend (CRD admission validation and schema enforcement, analogous to parsing and type-checking), an intermediate representation (internal reconciliation state held in controller memory and in status subresources, analogous to IR), and a backend (the actual writes to etcd, xDS snapshot cache, Terraform state, and Argo workflow triggers that produce real infrastructure).

The analogy is useful because it highlights where errors surface. A bug in the frontend — a missing required field in the CRD schema, a validating webhook that allows a malformed value — propagates silently until the backend tries to compile it and fails. A bug in the IR layer — a controller that misinterprets a feature flag in the CRD spec — may produce syntactically valid infrastructure that behaves incorrectly at runtime. A bug in the backend — an xDS snapshot that omits a route, or a Terraform plan that deletes a load balancer — has immediate blast radius on live traffic. Understanding where each class of error originates, and how to detect it before it reaches production, is what distinguishes a mature platform design from a collection of automation scripts.

Multi-tenancy is the first-class concern that shapes every other design decision. The fundamental question is: what is the unit of isolation? There are three canonical answers: namespace-per-team (shared cluster, namespace isolation), cluster-per-team (dedicated cluster, strong isolation, high operational overhead), and virtual cluster (vcluster or similar, shared physical nodes but isolated API server, a middle path). Each maps to a different blast radius for a misconfiguration. Namespace isolation relies entirely on NetworkPolicy enforcement and RBAC — a cluster-scoped resource leak or a cluster-admin escape is catastrophic. Cluster-per-team has hard limits on scale because platform engineering capacity cannot grow linearly with team count. Virtual clusters offer isolation at the control plane level while sharing the data plane, but they introduce a two-level scheduling problem and complicate observability because pod metrics live on the physical cluster but namespace context lives in the virtual cluster.

Lifecycle management is the problem most platforms underinvest in relative to initial provisioning. Provisioning a tenant namespace takes minutes. Upgrading the service mesh sidecar version across 200 tenant namespaces without breaking in-flight connections, rolling back when the new version increases error rates, and auditing the full change history for compliance requires months of platform investment. GitOps addresses the audit trail problem: every infrastructure state is committed, reviewed, and applied through ArgoCD or Flux, which means the diff between intended state (Git) and actual state (cluster) is always computable. But GitOps does not solve progressive delivery — that requires the platform to wrap ArgoCD sync with automated canary promotion and SLO-gated rollback logic, so that a bad platform config change is detected and reverted before it reaches all tenants.

Observability as a platform primitive means that a tenant who onboards to the platform at 9am on a Monday automatically has working dashboards, alerts, and distributed traces by 9:05am, without filing a ticket or writing any Prometheus configuration. This is achievable because the platform knows the contract: every tenant service exposes metrics on a standard port, has a standard label set, and is enrolled in the service mesh for trace propagation. The platform controller generates a PrometheusRule and Grafana dashboard resource at onboarding time, keyed to the tenant's namespace and service labels. Tenants own their SLOs; the platform provides the instrumentation scaffolding.

AI workload support requires the platform to extend its resource model beyond CPU and memory quotas. GPU is a scarce, non-fungible resource class. An inference service is not just a Deployment — it is a combination of a GPU-backed Deployment, a model artifact pull job, a warm-up script, an Envoy route with token-budget enforcement in the ext_authz filter, and a model version catalog entry. The platform must manage the full lifecycle of that composite object through a single InferenceService CRD, and it must enforce resource quotas that speak in tokens-per-second and GPU-hours rather than CPU millicores.

## Key Concepts

- **Intent vs Realization**: The CRD is the intent — it captures what a developer or team wants, using domain vocabulary (AppService, TenantNamespace, InferenceModel). The realization is what the controller produces: raw Kubernetes objects, Envoy xDS snapshots, and cloud provider API calls. Keeping intent and realization separate means developers are shielded from infrastructure churn; a cloud provider API change requires a controller update, not a developer manifest change.

- **Compiler Pattern**: The platform controller pipeline mirrors a compiler: parse (validate the CRD against its OpenAPI v3 schema via the validating webhook), analyze (reconcile dependencies — does the referenced ServiceAccount exist? Is the target namespace provisioned?), optimize (merge overlapping NetworkPolicy rules, deduplicate route entries), and emit (write the generated child resources to the cluster and push the xDS snapshot). Each stage has a distinct failure mode and a distinct recovery action.

- **Hub-Spoke Topology**: The hub cluster runs all platform control-plane components: ArgoCD, the platform CRD API server extension, policy engine (Kyverno or OPA Gatekeeper), the xDS control plane (Istiod or custom), and the platform controllers. Spoke clusters run tenant workloads and the data plane (Envoy sidecars, ingress gateways, GPU nodes). The hub is authoritative; spokes are eventually consistent projections of hub state.

- **Multi-Tenancy Model (namespace-per-team)**: Each team gets one or more namespaces in a spoke cluster, with a ResourceQuota (CPU, memory, GPU hours), a LimitRange, a NetworkPolicy that denies cross-namespace traffic by default, a RoleBinding to a team-scoped role, and a SPIFFE workload identity trust domain scoped to the namespace. Cluster-scoped resources (ClusterRole, ClusterRoleBinding, CRDs, PodSecurityAdmission policies) are managed exclusively by the platform team; tenants cannot create or modify them.

- **Lifecycle Management**: Platform changes follow a three-phase rollout: hub-first (update CRD schema or controller image on hub, validate with dry-run reconciliation), canary-spoke (apply to 5% of spoke clusters, hold for one hour, evaluate error rates against the `platform_reconcile_errors_total` metric and SLO dashboards), then full-rollout (progressive wave across remaining spokes via ArgoCD ApplicationSet with sync waves). Rollback is automated: a `SLOViolationAlert` firing during canary phase triggers the ArgoCD sync to revert the target Application to the previous git SHA.

- **GitOps as Audit Trail**: Every platform object — namespace provisioning, quota allocation, policy assignment, CRD install — is committed to a Git repository as a structured manifest. ArgoCD syncs these to clusters and records the sync result in Application status. This means the full history of who changed what, when, and what the resulting cluster state was is auditable without relying on etcd event history, which has limited retention.

- **Identity and Isolation (SPIFFE)**: Every workload in the platform receives a SPIFFE Verifiable Identity Document (SVID) from the trust anchor running on the hub. The SVID encodes the trust domain, namespace, and service account as a URI SAN: `spiffe://platform.example.com/ns/team-a/sa/frontend`. Envoy's SDS integration in each sidecar fetches the SVID from the local SPIFFE agent (SPIRE node agent or Istio's citadel-equivalent) via the SDS API. mTLS between services is enforced at the Envoy level using the SVID, so network-level identity is cryptographically bound and not dependent on Kubernetes RBAC alone.

- **NetworkPolicy Enforcement**: The platform installs a default-deny NetworkPolicy in every tenant namespace at provisioning time. Tenants explicitly declare permitted ingress and egress sources in their AppService CRD spec; the platform controller translates these declarations into NetworkPolicy objects. A CNI with NetworkPolicy enforcement (Cilium, Calico, or equivalent) is a platform prerequisite. `cilium monitor` or `kubectl exec` into a Cilium pod with `hubble observe` provides per-packet visibility for debugging.

- **Observability as Primitive**: The `TenantNamespace` platform CRD has a field `spec.observability.enabled: true` (default true). When the platform controller provisions the namespace, it also creates: a `PrometheusRule` (alerting rules keyed to `namespace` label), a `GrafanaDashboard` custom resource (a pre-built service dashboard with the namespace injected as a variable), a `TracingPolicy` (sampling rate and propagation headers), and a ServiceMonitor for any service that has the annotation `platform.example.com/scrape: "true"`. Tenants inherit observability at zero configuration cost.

- **AI Workload Support via InferenceService CRD**: The platform defines an `InferenceService` CRD (distinct from the KServe resource of the same name but analogous in intent) that encapsulates a GPU-backed model serving deployment. The controller reconciles it into: a `Deployment` with GPU node selector and `nvidia.com/gpu` resource requests, a `ModelPullJob` to fetch the model artifact, an Envoy `RouteConfiguration` update via xDS that routes `/v1/models/<name>` traffic to the deployment, and an `ExtAuthzPolicy` that enforces per-tenant token budgets via the ext_authz filter chain. GPU quota is managed through a `ResourceQuota` with `requests.nvidia.com/gpu` and a platform-level `InferenceQuota` CR that caps tokens-per-second.

- **Agent Automation Layer**: A platform agent — deployed as a Kubernetes CronJob with tightly scoped RBAC — handles routine operations that would otherwise require on-call engineer intervention: automated namespace cleanup when a `TenantNamespace` has `spec.expiresAt` in the past, GPU quota rebalancing when cluster utilization exceeds 85%, and incident correlation that joins ArgoCD sync events with Prometheus alerts to produce a structured incident summary in the `PlatformIncident` CR. The agent uses the `controller-runtime` client with impersonation to operate only within its assigned namespace scope.

- **CRD Versioning and Conversion Webhooks**: As the platform CRD schema evolves, older versions are kept in the `versions` list with `served: true` until all tenants have migrated. A conversion webhook — deployed as a Deployment on the hub — translates between versions in both directions. The webhook is tested via `kubectl convert` dry-runs and a CI integration test that creates objects in v1alpha1 and reads them back as v1beta1. CRD storage version is migrated by running the `kube-storage-version-migrator` after the new version is deployed, which re-reads and re-writes all stored objects to the current storage version without downtime.

## Internals

### 1. Developer Experience: Git Push to Live Traffic

The full path from developer intent to live traffic has eight stages. Understanding each stage and what can fail at each is the core of platform debugging.

Stage 1: Developer edits an `AppService` manifest in their team's Git repository. The manifest declares `spec.replicas: 3`, `spec.image: "registry.example.com/team-a/api:v2.1.0"`, `spec.expose.hostname: "api.team-a.example.com"`, `spec.trafficPolicy.rateLimit: 500`, and `spec.mesh.mtls: enforced`. This is intent — no Kubernetes object types are referenced.

Stage 2: The pull request triggers a CI pipeline that runs `kubectl apply --dry-run=server -f appservice.yaml` against the hub cluster. The API server routes the request to the `AppService` validating webhook, which checks required fields, validates image format, and rejects any reference to namespaces outside the team's allowed list. The dry-run response confirms the object would be accepted.

Stage 3: The PR is merged. ArgoCD, watching the team's Git repository via a GitRepository source, detects the new commit within 30 seconds (configurable via `spec.syncPolicy.automated.selfHeal` and poll interval). ArgoCD's Application controller computes a diff between the desired manifests in Git and the live cluster state via a three-way merge, then applies the diff.

Stage 4: The `AppService` object lands in the hub cluster's etcd. The platform `AppService` controller, running on the hub, receives a watch event for the new or changed object. The controller's Reconcile function runs. It reads the full `AppService` spec, resolves dependencies (verifies the target namespace exists, the referenced ServiceAccount exists, the image registry is in the approved allowlist), and then generates a set of child resources:
- A `Deployment` object targeted at the appropriate spoke cluster via ClusterAPI or Cluster-scoped labels for ArgoCD to sync.
- A `Service` and `VirtualService` (Istio) or `HTTPRoute` (Gateway API) targeting the Deployment.
- A `DestinationRule` with `trafficPolicy.tls.mode: ISTIO_MUTUAL` for mTLS enforcement.
- A `RateLimitPolicy` CR (or EnvoyFilter with a rate-limit descriptor) for the 500 RPS cap.
- An `Ingress` or `Gateway` rule for the exposed hostname.

Stage 5: The generated child resources are written back to the hub cluster under the appropriate spoke-targeted namespace. ArgoCD picks up these resources (they are tracked by the hub's platform Application) and syncs them to the target spoke cluster.

Stage 6: On the spoke cluster, the Deployment object is created. The scheduler assigns pods to nodes. Kubelet pulls the container image and starts the containers. Istiod on the spoke (or the hub acting as xDS control plane for the spoke) detects the new endpoints via the service discovery watch on the Kubernetes Endpoints API, updates its internal model, and pushes an xDS `EDS` update to all sidecar proxies in the mesh that need to know about the new service. A subsequent `RDS` push delivers the VirtualService route configuration.

Stage 7: The ingress gateway (an Envoy deployment fronting the spoke cluster) receives an `LDS`/`RDS` update from the xDS control plane adding the new route for `api.team-a.example.com`. The Envoy gateway's listener filter chain now matches SNI `api.team-a.example.com` and routes to the new cluster defined in CDS.

Stage 8: External DNS (ExternalDNS controller watching Service and Ingress objects) creates a DNS A record for `api.team-a.example.com` pointing to the ingress gateway's external IP. Traffic flows.

Total end-to-end latency from Git commit to live traffic: typically 2-5 minutes, dominated by ArgoCD sync poll interval (30s-3m), Deployment rollout time, and xDS convergence (typically under 5s for small fleets, under 30s for large fleets with thousands of proxies).

### 2. Control Plane Design: Hub Architecture

The hub cluster is purpose-built for control plane workloads. It does not run tenant workloads. Its key components and their interactions:

```
Hub Cluster Components
======================

[ArgoCD Application Controller]
  - Watches Git repositories (GitRepository CRs)
  - Computes desired state via kustomize/helm rendering
  - Syncs to hub and pushes spoke-targeted resources
  - Manages ApplicationSet for spoke fan-out

[Platform Controllers] (AppService, TenantNamespace, InferenceService, InferenceQuota)
  - Watch platform CRDs via Informer (SharedInformerFactory)
  - Reconcile: validate -> resolve deps -> generate children -> write status
  - Write generated child resources to hub (ArgoCD syncs to spokes)
  - Update .status.conditions and .status.observedGeneration

[Policy Engine: Kyverno]
  - ClusterPolicy resources enforce baseline requirements:
    all Deployments must have resource limits, readinessProbe, security context
  - Generate policies auto-create NetworkPolicy and RBAC in new namespaces
  - Mutate policies inject standard labels and annotations at admission time

[xDS Control Plane: Istiod (hub-mode) or Envoy Control Plane Service]
  - Watches Kubernetes services, endpoints, and Istio CRs across spoke clusters
    via remote-secret-based kubeconfig or Istio multi-cluster primary-remote setup
  - Maintains per-proxy xDS snapshot cache (go-control-plane SnapshotCache)
  - Pushes incremental xDS (delta xDS) to spoke Envoy proxies via gRPC stream

[Cluster Registry]
  - SpokeCluster CRs enumerate spoke clusters (name, region, tier, kubeconfig ref)
  - AppService controller reads SpokeCluster to determine placement
  - Used by ApplicationSet generators to fan out ArgoCD Applications

[Cert Manager + SPIRE Server]
  - Issues intermediate CAs per spoke cluster (trust bundle per cluster)
  - SPIRE Server on hub federates trust bundles to SPIRE agents on spokes
  - Workload SVIDs issued locally per spoke but rooted at hub's root CA
```

The hub cluster is sized for control plane throughput, not workload density. A hub serving 50 spoke clusters with 10,000 total namespaces needs generous etcd IOPS (NVMe-backed nodes), API server replicas for watch fan-out, and dedicated node pools for Istiod (xDS push throughput scales with proxy count).

### 3. Multi-Cluster Topology and Service Discovery

The canonical topology is hub-spoke with a primary-remote Istio configuration. The hub acts as the Istio primary — it runs Istiod and holds the mesh configuration. Each spoke is a remote cluster — it runs Envoy sidecars but no Istiod. The remote clusters connect to hub Istiod via a RemoteSecret that contains the spoke's kubeconfig. Istiod uses this kubeconfig to watch Services and Endpoints on each spoke and include them in its global service registry.

Cross-cluster service discovery works through ServiceEntry and the east-west gateway. When a pod in spoke-west calls `team-b-api.team-b.svc.cluster.local`, Envoy's outbound listener intercepts the call. If team-b-api does not exist in spoke-west, Envoy has no route for it. The platform controller, upon detecting the cross-cluster service dependency (declared in AppService `spec.dependencies`), creates a ServiceEntry in spoke-west that maps `team-b-api.team-b.svc.cluster.local` to the east-west gateway's external IP of spoke-east, with TLS mode ISTIO_MUTUAL. The east-west gateway (an Envoy deployment with `istio: eastwestgateway` label) in spoke-east exposes all services via SNI-based routing — the SNI value encodes the full service name, so the gateway can route to the correct upstream without decrypting the mTLS traffic.

Peer-to-peer topology (each cluster connects directly to others' east-west gateways) is simpler for small fleets but does not scale: connection count grows as O(N^2) for N clusters, and service discovery state must be synchronized across all peers. Hub-spoke grows as O(N) because only the hub aggregates global state.

### 4. Identity and Isolation in Depth

SPIFFE workload identity is the foundation. Every pod in the platform receives a SVID via Istio's built-in certificate provisioning (which implements SPIFFE) or via the SPIRE agent DaemonSet. The SVID is injected into the pod's Envoy sidecar via the SDS API — the sidecar fetches the certificate and private key from the local SPIRE agent's workload API socket at `/run/spire/sockets/agent.sock`. The Envoy sidecar presents this SVID as its client certificate when making outbound mTLS connections, and verifies the peer SVID against the trust bundle for peer's trust domain on inbound connections.

Network isolation is enforced in two layers. The first layer is Kubernetes NetworkPolicy, enforced by the CNI (Cilium in L3/L4 mode). The default-deny egress and ingress rules in each namespace mean pods cannot communicate across namespace boundaries unless explicitly permitted by NetworkPolicy. The second layer is Istio AuthorizationPolicy, enforced at L7 in the Envoy sidecar. An AuthorizationPolicy with `spec.source.principals` checks the SVID of the calling workload — not just its IP address — so even if a NetworkPolicy allows traffic between two pods, an AuthorizationPolicy can deny it based on the SVID trust domain or service account. This defense-in-depth means a compromised pod that spoofs its source IP is still rejected at the mTLS identity layer.

Namespace-level RBAC is generated by the TenantNamespace controller. The generated RoleBinding gives the team's group (sourced from the identity provider via OIDC claims) `edit` rights in their namespace and read rights on platform-generated resources (ServiceMonitors, PrometheusRules). CRD creation, ClusterRole creation, and admission webhook creation are explicitly excluded via a RoleBinding that uses a tightly scoped Role — not ClusterRole — ensuring tenant users cannot escalate privileges by modifying cluster-scoped resources.

### 5. Inference Gateway Integration

The InferenceService CRD is the platform's representation of a model serving deployment. A minimal InferenceService spec:

```yaml
apiVersion: platform.example.com/v1beta1
kind: InferenceService
metadata:
  name: llama-3-8b
  namespace: team-ai
spec:
  model:
    name: llama-3-8b-instruct
    version: "3.1"
    artifact: "s3://models/llama-3-8b-instruct/v3.1"
  serving:
    replicas: 2
    gpuClass: "nvidia-a100-40gb"
    gpuCount: 1
  tokenBudget:
    inputTokensPerMinute: 100000
    outputTokensPerMinute: 50000
  routing:
    hostname: "llama-3-8b.ai.team-ai.example.com"
    priority: high
```

The InferenceService controller reconciles this into:

1. A GPU-backed `Deployment` with `resources.limits."nvidia.com/gpu": 1`, `nodeSelector: gpu-class: nvidia-a100-40gb`, and an init container that runs `aws s3 sync s3://models/... /mnt/models/` to pull the artifact before serving starts.

2. An `ExtAuthzConfig` that references an ext_authz filter chain entry in Envoy. The ext_authz service is the platform's token budget enforcer — a gRPC service that tracks per-tenant token usage in Redis, enforces the `inputTokensPerMinute` limit, and returns `OK` or `PERMISSION_DENIED` with a `x-token-budget-remaining` header.

3. An xDS `RouteConfiguration` update (pushed via the platform's xDS control plane) that adds a new virtual host entry for `llama-3-8b.ai.team-ai.example.com` in the inference gateway's route table. The route has a per-filter config for `envoy.filters.http.ext_authz` referencing the token budget service, and a timeout of `spec.timeout_override: 300s` to accommodate long inference responses.

4. A `ResourceQuota` update in the `team-ai` namespace that decrements the team's `requests.nvidia.com/gpu` allowance by 2 (one GPU per replica, 2 replicas), preventing the team from exceeding their GPU allocation.

5. A `GrafanaDashboard` for inference-specific metrics: `inference_request_duration_seconds` (histogram), `inference_tokens_per_second` (gauge), `inference_queue_depth` (gauge), and `inference_token_budget_remaining` (gauge with alert when below 10%).

The inference gateway itself is a dedicated Envoy deployment (separate from the tenant ingress gateway) with a longer idle timeout, HTTP/2 streaming support, and gzip disabled (inference responses are already tokenized, not compressible). It is the single entry point for all AI traffic, which allows the platform to enforce token budgets, log all inference requests for cost attribution, and apply per-model canary routing (shifting 10% of traffic to a new model version while keeping 90% on the current version).

### 6. Agent Automation Layer

The platform agent runs as a Kubernetes CronJob on the hub cluster with a 5-minute schedule. It uses the `controller-runtime` manager with impersonation to scope its API server access to only the namespaces and resources it needs. The agent performs three categories of work:

**Routine maintenance**: Scanning for expired TenantNamespace objects (where `spec.expiresAt` is in the past) and triggering the namespace teardown workflow — draining pods, archiving audit logs to object storage, then deleting the namespace and its associated RBAC, NetworkPolicy, and observability resources via a cascading deletion controlled by owner references.

**Capacity management**: Reading GPU utilization from the Prometheus API (`avg_over_time(nvidia_gpu_duty_cycle[30m])` by node) and the per-team InferenceQuota resource. When cluster-wide GPU utilization exceeds 85%, the agent preempts low-priority InferenceService instances (those with `spec.routing.priority: low`) by scaling their Deployment to zero and updating their status condition to `Suspended: true`. When utilization drops below 70%, suspended services are resumed in priority order.

**Incident correlation**: Subscribing to `PlatformAlert` events (written by the alertmanager webhook receiver into the hub cluster as custom objects) and joining them with ArgoCD Application sync events and controller reconciliation error events from the platform controllers' own event stream. The agent generates a `PlatformIncident` CR that captures: the tenant affected, the failing component, the last successful Git SHA, the first failing reconcile timestamp, and a list of related metrics with their values at failure onset. This structured incident record is the starting point for on-call investigation instead of a raw alert.

### 7. Upgrade and Rollout Strategy

Platform upgrades follow a strict sequence to prevent cascading failures. The sequence for a controller image upgrade:

Step 1 — Hub dry-run: The new controller image is deployed to a `platform-system-canary` namespace on the hub with `--dry-run` mode (reads objects, computes desired state, logs diffs to stdout, does not write). This validates that the new controller can parse all existing CRD objects without panicking or producing invalid output.

Step 2 — Hub canary: The new image is deployed alongside the current image, handling 5% of reconcile events (implemented via a deterministic hash of the object name modulo 20, where the canary handles hash == 0). Error rate in `platform_reconcile_errors_total{controller="appservice",version="v2"}` is monitored for 30 minutes.

Step 3 — Hub full rollout: The old image is scaled down. The new image handles all reconcile events. Spoke resources are not yet changed.

Step 4 — Spoke wave 1: ArgoCD ApplicationSet with `syncWave: 1` applies the updated controller manifests to 5% of spoke clusters (selected by a cluster label `platform-tier: canary`). SLO dashboards for those spokes are reviewed.

Step 5 — Spoke full rollout: Remaining spokes are updated in waves of 10%, with a minimum 15-minute hold between waves. The ApplicationSet `syncPolicy.retry.backoff` is configured to pause rollout if `platform_reconcile_errors_total` on the target spoke increases by more than 5% relative to baseline during the hold window.

CRD schema version upgrades follow the same pattern but with an additional step: the conversion webhook is deployed and validated (via `kubectl convert` dry-run against a sample of live objects) before the new version is marked as the storage version. The `kube-storage-version-migrator` job runs after the new storage version is set, re-writing all existing objects. Migration progress is tracked in the StorageVersionMigration status resource.

## Architecture Diagram

```
                     NEXT-GEN PLATFORM: HUB-SPOKE ARCHITECTURE
                     ==========================================

  DEVELOPER
     |
     | git push (AppService, InferenceService, TenantNamespace manifests)
     v
  +--[Git Repository]--+
  |  team-a/           |
  |    appservice.yaml  |
  |    quota.yaml       |
  +--------------------+
           |
           | webhook / poll (30s)
           v
  +========================================+
  |           HUB CLUSTER                  |   <-- control plane only, no workloads
  |                                        |
  |  [ArgoCD App Controller]               |
  |       |                                |
  |       | generates ApplicationSet       |
  |       | syncs hub platform objects     |
  |       v                                |
  |  [Platform Controllers]                |
  |   AppService  TenantNamespace          |
  |   InferenceService  InferenceQuota     |
  |       |                                |
  |       | writes generated child CRs     |
  |       | (Deployment, VirtualService,   |
  |       |  NetworkPolicy, ServiceEntry,  |
  |       |  ExtAuthzPolicy, PrometheusRule)|
  |       v                                |
  |  [Hub etcd]  <-- source of truth       |
  |                                        |
  |  [Istiod / xDS Control Plane]          |
  |       |                                |
  |       | delta xDS (gRPC stream)        |
  |       | LDS/RDS/CDS/EDS/SDS            |
  |  [SPIRE Server]                        |
  |  [Kyverno Policy Engine]               |
  |  [Cert Manager]                        |
  |  [Cluster Registry]                    |
  |    SpokeCluster CRs                    |
  +========================================+
           |           |           |
           | ArgoCD    | ArgoCD    | ArgoCD
           | sync      | sync      | sync
           v           v           v
  +---------------+ +---------------+ +---------------+
  | SPOKE WEST    | | SPOKE EAST    | | SPOKE AI      |
  | (us-west-2)   | | (us-east-1)   | | (gpu-pool)    |
  |               | |               | |               |
  | [Tenant NS]   | | [Tenant NS]   | | [Tenant NS]   |
  |  team-a       | |  team-b       | |  team-ai      |
  |  team-c       | |  team-d       | |               |
  |               | |               | | [InferenceGW] |
  | [Envoy        | | [Envoy        |   Envoy + ext_  |
  |  Sidecars]    | |  Sidecars]    |   authz token   |
  | [Ingress GW]  | | [Ingress GW]  |   budget filter |
  | [EW Gateway]  | | [EW Gateway]  |               | |
  |               | |               | [GPU Nodes]   | |
  |   workloads   | |   workloads   |  A100 pool    | |
  +---------------+ +---------------+ +---------------+
           |                   |
           | mTLS (SPIFFE SVID)|
           | east-west         |
           +-------------------+
              cross-cluster
              service calls

  CONTROL FLOW:  Git -> ArgoCD -> Hub Controllers -> Hub etcd -> ArgoCD -> Spoke
  DATA FLOW:     Client -> DNS -> Ingress GW -> Envoy Sidecar -> Workload
  IDENTITY FLOW: SPIRE Hub CA -> SPIRE Agent (spoke) -> Envoy SDS -> mTLS SVID
  CONFIG FLOW:   Hub Istiod -> delta xDS gRPC -> Spoke Envoy Proxies
```

## Failure Modes and Debugging

### Failure 1: CRD Proliferation and Config Explosion

**Symptoms**: Platform engineers spend more time managing CRD schema migrations than building new features. Tenants file tickets because their AppService objects are rejected after a controller upgrade due to a new required field. etcd object count grows unbounded as orphaned child resources (VirtualServices, NetworkPolicies, PrometheusRules) accumulate from deleted or renamed AppService objects. `etcd_mvcc_db_total_size_in_bytes` grows steadily despite no increase in tenant count.

**Root Cause**: CRD schema is changed without a structured deprecation policy. New required fields are added to v1beta1 without preserving v1alpha1 serving. Generated child resources lack owner references — when the parent AppService is deleted, garbage collection does not run because the controller used a cross-namespace owner reference (unsupported) or forgot to set `ownerReferences` at all. Over time, the ratio of live child resources to live parent resources grows, consuming etcd storage and controller watch cache memory.

**Blast Radius**: Orphaned VirtualService objects cause Envoy route conflicts — multiple VirtualService objects matching the same hostname result in non-deterministic routing behavior, which Istio logs as a conflict but does not resolve automatically. Orphaned NetworkPolicy objects may inadvertently block traffic that tenants expect to be permitted. etcd quota exhaustion affects the entire hub cluster.

**Mitigation**: Enforce owner references on all generated child resources at the controller level — fail the reconcile if owner reference cannot be set rather than proceeding. Use garbage collection (the Kubernetes cascading deletion mechanism via `metadata.ownerReferences` with `blockOwnerDeletion: true`) to ensure child resources are cleaned up when parents are deleted. For cross-namespace children (generated resources live in a different namespace than the parent CRD), implement a finalizer on the parent that explicitly lists and deletes cross-namespace children before the parent is removed. Maintain a two-version minimum for all CRD schema versions: never mark a version as `served: false` until all stored objects have been migrated and confirmed via the StorageVersionMigration status. Add a CI test that creates 1,000 AppService objects, deletes them, and asserts that zero child resources remain after 60 seconds.

**Debugging**:

```bash
# Count total objects by resource type to identify accumulation
kubectl get appservice -A --no-headers | wc -l
kubectl get virtualservice -A --no-headers | wc -l
kubectl get networkpolicy -A --no-headers | wc -l

# Find orphaned VirtualServices (no matching AppService parent)
kubectl get virtualservice -A -o json | \
  jq '.items[] | select(.metadata.ownerReferences == null) | .metadata | {name, namespace}'

# Check etcd db size on hub
kubectl exec -n kube-system etcd-hub-control-plane -- \
  etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --write-out=table

# Count objects by type in etcd directly
kubectl exec -n kube-system etcd-hub-control-plane -- \
  etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/virtualservices --prefix --keys-only | wc -l

# Check StorageVersionMigration status for in-progress CRD migrations
kubectl get storageversionmigration -o wide
```

### Failure 2: Multi-Cluster Drift (Spoke Diverges from Hub Intent)

**Symptoms**: A tenant's service is running correctly on spoke-east but returning 503s on spoke-west, even though both spokes should have identical configuration. `kubectl get deployment team-a-api -n team-a` on spoke-west shows `1/3 Ready` (two pods in CrashLoopBackOff). The AppService status on the hub shows `Synced: true`. ArgoCD Application for spoke-west shows `Healthy` with the last sync 4 hours ago, but the actual pod failure happened 2 hours ago.

**Root Cause**: ArgoCD self-heal is configured with `respectedIgnoreDifferences` that excludes `status` and certain managed fields, causing it to not detect the pod-level failure as an out-of-sync condition (Application resource health is computed from Deployment rollout status, but a CrashLoopBackOff is not always immediately reflected in the Deployment's `status.conditions` in a way that ArgoCD recognizes as degraded). The underlying cause of the CrashLoopBackOff is a spoke-specific environment variable injection via a Kyverno mutate policy that is one version behind on spoke-west — it is injecting a deprecated database endpoint that was removed in the backend service.

**Blast Radius**: Single spoke affected. All tenants on spoke-west whose pods depend on the deprecated database endpoint are also in CrashLoopBackOff — this may be dozens of services. The platform's hub-level status shows everything as healthy, masking the outage from the on-call engineer's default dashboard.

**Mitigation**: Hub-level AppService status must aggregate spoke-level health, not just ArgoCD sync state. The platform controller should subscribe to the spoke's Deployment status via the remote kubeconfig and set `status.conditions[].type=SpokeHealthy` per spoke in the AppService status. Alerting on `appservice_spoke_unhealthy_total > 0` catches this class of failure. Kyverno ClusterPolicy versions must be managed through the same wave-based rollout as all other platform components — a policy version drift of more than one spoke-wave behind is a deployment policy violation.

**Debugging**:

```bash
# Check pod status on the failing spoke directly
kubectl --context spoke-west get pods -n team-a -l app=team-a-api
kubectl --context spoke-west describe pod -n team-a <failing-pod-name>
kubectl --context spoke-west logs -n team-a <failing-pod-name> --previous

# Compare Kyverno ClusterPolicy versions between spokes
kubectl --context spoke-west get clusterpolicy -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.resourceVersion}{"\n"}{end}'
kubectl --context spoke-east get clusterpolicy -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.resourceVersion}{"\n"}{end}'

# Check ArgoCD Application health status per spoke
argocd app list --output wide | grep spoke-west

# Check the AppService status on hub for spoke-specific conditions
kubectl get appservice team-a-api -n team-a -o jsonpath='{.status.conditions}' | jq .

# Check Kyverno audit report for policy violations on the failing spoke
kubectl --context spoke-west get polr -n team-a -o json | jq '.items[].results[] | select(.result == "fail")'
```

### Failure 3: Bad Platform Config Breaks All Tenants (Blast Radius of a Platform Change)

**Symptoms**: At 14:03, all VirtualService objects across the entire hub cluster are re-applied by ArgoCD after a platform controller upgrade. By 14:05, all tenant services on all spoke clusters become unreachable. Envoy access logs show `NR` (no route) for all external traffic. `istioctl proxy-config route` on affected pods shows empty route tables. `pilot_xds_push_errors_total` metric spikes to 2,000 per minute.

**Root Cause**: The upgraded platform controller has a bug in the VirtualService generation logic — it emits a VirtualService with `spec.hosts: []` (empty hosts list) instead of the correct hostname. Istiod rejects the invalid VirtualService at the xDS level (a VirtualService with no hosts is invalid per the Istio API) but does not delete the existing valid xDS routes that the previous version had pushed. However, because the controller also deleted and recreated the VirtualService objects (rather than patching them), Istiod's internal state went through a brief period where the old VirtualService was deleted and the new invalid one was created. During that window, Istiod pushed an xDS update removing the routes. Envoy accepted the removal and cleared its route table. The new invalid VirtualService was never translated into a valid xDS push, leaving all Envoy proxies with no routes.

**Blast Radius**: All tenants on all spoke clusters. This is the maximum blast radius for a platform change. The failure is simultaneous, affecting all traffic from the moment of the xDS route removal push.

**Mitigation**: The controller canary phase (handling 5% of objects) would have caught this if the canary had been run for long enough before hub full-rollout. The critical missing control is a dry-run validation gate: before writing any generated VirtualService object to the cluster, the controller should call `kubectl apply --dry-run=server` and assert that the returned object is syntactically valid (non-empty hosts list). This validation can be implemented as a pre-commit check in the Reconcile function using the `client.DryRun` option in controller-runtime. Additionally, the controller should patch existing objects rather than delete-and-recreate — an in-place patch preserves the old valid state if the patch is rejected, whereas delete-and-recreate has a window of no state.

**Debugging**:

```bash
# Confirm xDS route tables are empty on affected proxies
istioctl proxy-config route -n team-a <pod-name> --name http.8080

# Check Istiod push error rate
kubectl exec -n istio-system deploy/istiod -- curl -s http://localhost:15014/metrics | \
  grep pilot_xds_push_errors_total

# Check Istiod's current VirtualService model
istioctl analyze -n team-a

# Find VirtualServices with empty hosts
kubectl get virtualservice -A -o json | \
  jq '.items[] | select(.spec.hosts | length == 0) | .metadata | {name, namespace}'

# Force Istiod to reconcile by touching the relevant config objects
kubectl annotate virtualservice -n team-a team-a-api \
  platform.example.com/force-reconcile=$(date +%s) --overwrite

# Check pilot push logs for rejection reason
kubectl logs -n istio-system deploy/istiod | grep "invalid VirtualService" | tail -20

# Check platform controller logs for the buggy reconcile
kubectl logs -n platform-system deploy/appservice-controller | \
  grep "VirtualService" | grep -E "ERROR|generated|applying" | tail -50
```

### Failure 4: GPU Capacity Exhaustion

**Symptoms**: New InferenceService objects are stuck in `Pending` state — their generated Deployment has pods in `Pending` with event `0/12 nodes are available: 12 Insufficient nvidia.com/gpu`. Existing inference services are healthy. The platform dashboard shows GPU utilization at 98% across all GPU nodes. Low-priority tenants begin filing tickets that their inference services have been silently suspended without notification.

**Root Cause**: GPU nodes are over-committed at the InferenceQuota level. The platform's InferenceQuota controller correctly tracked quota at admission time, but an infrastructure event reduced the GPU node count — a cloud provider spot instance reclaim took 4 of 12 GPU nodes. The platform's ResourceQuota for `nvidia.com/gpu` is based on the node capacity at the time the quota was set, which is now higher than the actual available capacity. The quota enforcement admitted new InferenceService objects that physically cannot be scheduled.

**Blast Radius**: New InferenceService deployments fail to schedule. GPU capacity agent has preempted low-priority services but has not notified tenants (the agent writes to a PlatformIncident CR but does not yet send notifications). Existing high-priority inference services are unaffected.

**Mitigation**: The InferenceQuota controller must track allocatable GPU capacity in real time by watching NodeStatus for GPU-enabled nodes and updating a cluster-level capacity counter. InferenceService admission should be gated against allocatable capacity, not just quota headroom. Low-priority suspensions must generate a Kubernetes Event on the InferenceService object and trigger a platform notification (Slack webhook, email) via the alertmanager webhook receiver. Add a PodDisruptionBudget validation: before suspending a service, check that enough replicas remain running to serve pending requests.

**Debugging**:

```bash
# Check allocatable GPU capacity per node
kubectl get nodes -l gpu-class=nvidia-a100-40gb \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}'

# Check ResourceQuota usage vs hard limits in GPU namespaces
kubectl get resourcequota -A -o json | \
  jq '.items[] | select(.spec.hard["requests.nvidia.com/gpu"] != null) | {ns: .metadata.namespace, hard: .spec.hard, used: .status.used}'

# Check InferenceQuota status
kubectl get inferencequota -n team-ai -o yaml

# Find all Pending GPU pods and their events
kubectl get pods -A --field-selector=status.phase=Pending -o wide | grep gpu
kubectl get events -A --field-selector=reason=FailedScheduling | grep gpu

# Check capacity agent logs for preemption decisions
kubectl logs -n platform-system deploy/platform-agent | grep -E "preempt|suspend|GPU" | tail -30

# Check current node GPU utilization via Prometheus
kubectl exec -n monitoring deploy/prometheus -- \
  promtool query instant http://localhost:9090 \
  'avg by (node) (nvidia_gpu_duty_cycle)'
```

## Lightweight Lab

See `lab/README.md` for the full capstone design document lab. The lab guides you through producing a complete platform design document, hub-spoke architecture diagrams, request path diagrams for both HTTP and inference traffic, a failure mode analysis, and a 10-minute spoken talk track. The deliverable is a `design/` folder containing a structured design document (using `lab/design-template.md`), ASCII diagrams, and your written talk track.

## What to Commit

- Complete the design document using `lab/design-template.md` as the starting structure, filling every section with concrete decisions and trade-off reasoning for your platform context.
- Practice the talk track out loud until you can deliver the one-minute summary, architecture walkthrough, and two failure modes without consulting notes.
