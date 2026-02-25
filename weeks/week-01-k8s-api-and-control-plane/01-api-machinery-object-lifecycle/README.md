# Kubernetes API Machinery & Object Lifecycle

## What you should be able to do
- Explain apiserver request path end-to-end.
- Interpret resourceVersion/generation/conditions.
- Reason about eventual consistency.

## Mental model

Think of Kubernetes as a distributed database (etcd) with an HTTP API layer (kube-apiserver) that enforces access control and schema validation, combined with a set of independent reconciliation loops (controllers) that watch the database and perform actions to make reality match the declared state. Unlike traditional imperative systems where you tell the computer what to do, Kubernetes uses a declarative model: you declare what you want (desired state), write it to the API, and the system continuously works to make it so (actual state).

The API server is not just a simple REST interface to etcd - it's the gatekeeper that authenticates every request, checks authorization, validates schema, applies admission policies, and then persists the validated object to etcd. After persistence, it notifies watchers about the change. This watch mechanism is critical: controllers don't poll for changes; they maintain long-lived HTTP connections that stream updates in real-time.

The eventual consistency model is fundamental. When you `kubectl apply` a Deployment, the API server writes it to etcd immediately, but the Deployment controller hasn't created the ReplicaSet yet, the ReplicaSet controller hasn't created Pods yet, the Scheduler hasn't assigned nodes yet, and kubelet hasn't started containers yet. Each component operates independently on its local cache, reconciling its piece of the world. The `resourceVersion` field acts like a vector clock, allowing clients to detect concurrent modifications and controllers to checkpoint their progress.

Understanding this architecture explains why Kubernetes is resilient (controllers can restart and pick up where they left off), eventually consistent (changes propagate through the system in stages), and extensible (you can add new controllers watching new resource types without modifying core components). The trade-off is complexity: debugging requires tracing through multiple asynchronous reconciliation loops rather than following a single execution path.

## Key Concepts

- **runtime.Object**: The base interface in Go that all Kubernetes objects implement (provides GetObjectKind, DeepCopyObject)
- **resourceVersion**: Opaque string representing the etcd revision; used for optimistic concurrency control and watch bookmarking
- **generation**: Increments when spec changes; allows controllers to detect when user intent has changed
- **observedGeneration**: Controller writes this to status after reconciling; if observedGeneration < generation, reconciliation is pending
- **Watch**: Long-lived HTTP GET request using chunked transfer encoding that streams ADDED/MODIFIED/DELETED events
- **Informer**: Client-side component that watches a resource type, maintains a local cache (Store), and notifies event handlers
- **metadata.uid**: Immutable unique identifier for object lifetime; changes if you delete and recreate an object with the same name

## API Resource Structure

Every Kubernetes object has a precise identity within a taxonomy of groups, versions, kinds, and resources. Understanding this taxonomy is essential for writing RBAC rules, building dynamic clients, and reasoning about CRD design.

### GVK and GVR

A resource type is identified in two complementary ways:

- **Group/Version/Kind (GVK)** — the *type* identity used in Go code and manifests. Example: `apps/v1/Deployment`. Kind is the PascalCase Go type name.
- **Group/Version/Resource (GVR)** — the *HTTP path* identity used in REST calls and RBAC rules. Example: `apps/v1/deployments`. Resource is the lowercase plural form.

The mapping between GVK and GVR is maintained by `runtime.DefaultRESTMapper`. Most of the time the resource is just the lowercased, pluralised kind, but exceptions exist (e.g., `Endpoints` kind maps to `endpoints` resource — already plural).

```
GVK: apps/v1/Deployment        GVR: apps/v1/deployments
     ───┬ ─┬ ──────┬                ───┬ ─┬ ──────────┬
     group ver  kind              group ver   resource
```

### API Group Organization

| Category | apiVersion format | URL prefix | Examples |
|----------|------------------|------------|----------|
| Core (legacy) group `""` | `v1` | `/api/v1/...` | Pod, Service, ConfigMap, Secret, Namespace |
| Named groups | `<group>/<version>` | `/apis/<group>/<version>/...` | `apps/v1`, `batch/v1`, `networking.k8s.io/v1` |

Key named groups:
- `apps` — Deployment, StatefulSet, DaemonSet, ReplicaSet
- `batch` — Job, CronJob
- `networking.k8s.io` — Ingress, NetworkPolicy
- `rbac.authorization.k8s.io` — Role, ClusterRole, RoleBinding, ClusterRoleBinding
- `apiextensions.k8s.io` — CustomResourceDefinition

The core group has no group prefix because it predates the group mechanism — `apiVersion: v1` is shorthand for group `""`, version `v1`.

### Version Semantics

Versions follow a maturity progression: `v1alpha1` → `v1beta1` → `v1`.

Two flags on each version determine how it behaves at the API server:

- **`served: true`** — the API server accepts requests at this version (visible in `kubectl api-versions`)
- **`storage: true`** — objects are persisted in etcd at this version; exactly one version per resource must be the storage version

When a CRD serves multiple versions (e.g., `v1alpha1` and `v1`), conversion webhooks translate between the served version and the storage version. Objects written at `v1alpha1` are converted to the storage version before persistence and converted back when read at `v1alpha1`. This is visible in the lab CRD (`lab/crd.yaml`), which defines a single version `v1` with both `served: true` and `storage: true`.

### Object Anatomy

Every Kubernetes object is composed of four sections:

```yaml
apiVersion: apps/v1          # ─┐
kind: Deployment              # ─┘ TypeMeta
metadata:                     # ─── ObjectMeta
  name: nginx
  namespace: default
  uid: 8a1b2c3d-...
  resourceVersion: "1234"
  generation: 3
  creationTimestamp: "2025-01-01T00:00:00Z"
  labels: { ... }
  annotations: { ... }
  ownerReferences: [ ... ]
  finalizers: [ ... ]
  managedFields: [ ... ]
spec:                         # ─── Spec (desired state)
  replicas: 3
  template: { ... }
status:                       # ─── Status (observed state)
  availableReplicas: 3
  observedGeneration: 3
  conditions: [ ... ]
```

| Section | Purpose | Who writes | Notes |
|---------|---------|-----------|-------|
| **TypeMeta** | `apiVersion` + `kind` — identifies the type | System | Not persisted in etcd (derived from the storage path) |
| **ObjectMeta** | Identity, versioning, ownership, field management | System + user (labels, annotations, finalizers) | `resourceVersion` changes on every write; `generation` only on spec change |
| **Spec** | User's desired state | User / GitOps controller | Writing here increments `metadata.generation` |
| **Status** | System's observed state | Controllers | Separate `/status` subresource; does **not** increment `generation` |

The spec/status split enforces a clear contract: users declare intent in spec, controllers report reality in status. RBAC can restrict who writes each.

### API Discovery

Clients discover available resources dynamically:

| Endpoint | Returns | CLI equivalent |
|----------|---------|---------------|
| `GET /apis` | All API groups and their versions | `kubectl api-versions` |
| `GET /apis/<group>/<version>` | All resources in that group/version (verbs, namespaced, etc.) | `kubectl api-resources` |
| `GET /api/v1` | Core group resources | — |

`kubectl api-resources` aggregates discovery docs from all groups to build its table. Discovery is cached client-side (`~/.kube/cache/discovery/`). Aggregated API servers (e.g., metrics-server) register via `APIService` objects, which tell the kube-apiserver to proxy requests for their group/version.

### Subresources

Subresources are nested endpoints beneath a resource's URL that have independent RBAC and semantics:

| Subresource | URL pattern | Purpose |
|-------------|-------------|---------|
| `/status` | `…/widgets/demo/status` | Separate RBAC for spec writers vs status writers |
| `/scale` | `…/deployments/nginx/scale` | Standardized interface for HPA — reads/writes `spec.replicas` |
| `/log` | `…/pods/nginx/log` | Stream container logs |
| `/exec` | `…/pods/nginx/exec` | Exec into container (WebSocket upgrade) |

CRDs opt into subresources explicitly:
```yaml
subresources:
  status: {}                    # enables /status endpoint
  scale:                        # enables /scale endpoint for HPA
    specReplicasPath: .spec.replicas
    statusReplicasPath: .status.replicas
```

Without `subresources.status: {}`, updates to `.status` go through the main endpoint and increment `generation` — defeating the spec/status contract.

### GVK / GVR Reference Table

| Kind | apiVersion (GVK) | Resource (GVR) | URL path (namespaced) |
|------|------------------|----------------|-----------------------|
| Pod | `v1` | `pods` | `/api/v1/namespaces/{ns}/pods` |
| Service | `v1` | `services` | `/api/v1/namespaces/{ns}/services` |
| ConfigMap | `v1` | `configmaps` | `/api/v1/namespaces/{ns}/configmaps` |
| Namespace | `v1` | `namespaces` | `/api/v1/namespaces` (cluster-scoped) |
| Deployment | `apps/v1` | `deployments` | `/apis/apps/v1/namespaces/{ns}/deployments` |
| StatefulSet | `apps/v1` | `statefulsets` | `/apis/apps/v1/namespaces/{ns}/statefulsets` |
| Job | `batch/v1` | `jobs` | `/apis/batch/v1/namespaces/{ns}/jobs` |
| Ingress | `networking.k8s.io/v1` | `ingresses` | `/apis/networking.k8s.io/v1/namespaces/{ns}/ingresses` |
| ClusterRole | `rbac.authorization.k8s.io/v1` | `clusterroles` | `/apis/rbac.authorization.k8s.io/v1/clusterroles` (cluster-scoped) |
| CRD | `apiextensions.k8s.io/v1` | `customresourcedefinitions` | `/apis/apiextensions.k8s.io/v1/customresourcedefinitions` (cluster-scoped) |
| Widget (lab) | `demo.io/v1` | `widgets` | `/apis/demo.io/v1/namespaces/{ns}/widgets` |

## Internals

### Request Path (Write)

1. **Authentication**: kube-apiserver receives the request (typically HTTPS on port 6443 or 443). Authentication plugins run in order (x509 client certs, bearer tokens, OIDC, webhook, etc.) to establish identity. The system extracts user/groups/extra claims.

2. **Authorization**: RBAC authorizer checks if the authenticated user has permission for the requested verb (create/get/update/delete) on the API group/resource. Node authorizer restricts kubelets to their own pods. Webhook authorizers can call external systems.

3. **Mutating Admission**: Mutating admission webhooks run in configured order. Each can modify the object (inject sidecars, set defaults, add labels). The MutatingAdmissionPolicy feature provides in-process CEL-based mutations. The ServiceAccount admission controller injects default service account tokens.

4. **Schema Validation**: The API server validates the object against its OpenAPI v3 schema (from CRD or built-in types). This ensures required fields are present and types match.

5. **Validating Admission**: Validating admission webhooks run (can reject but not modify). ValidatingAdmissionPolicy (CEL-based) runs in-tree. These enforce business logic like "prod namespace can't use latest tag."

6. **Etcd Persistence**: The API server serializes the object to protobuf (by default) or JSON and writes it to etcd using a transactional compare-and-swap. The etcd ModRevision becomes the resourceVersion. For updates, the server checks the client-provided resourceVersion matches current state (optimistic locking).

7. **Watch Notification**: The API server's watch cache (cacher) maintains in-memory state and streams events to all watchers for that resource type. This happens after etcd commit, so clients never see a write that isn't durable.

### Watch Path (Read)

1. **Establishing Watch**: Client sends `GET /apis/GROUP/VERSION/RESOURCE?watch=1&resourceVersion=12345`. The server doesn't close the connection; instead it sends a stream of JSON objects (kind: ADDED/MODIFIED/DELETED).

2. **Watch Cache**: The cacher maintains a sliding window of recent events in memory. If the client's resourceVersion is within the window, the server replays events from memory. If too old (410 Gone), the client must list and relist.

3. **Informer Pattern**: Client libraries (client-go) provide SharedInformer, which manages the watch, reconnects on errors, maintains a local cache (Store indexed by namespace/name), and invokes registered event handlers (OnAdd/OnUpdate/OnDelete).

4. **Reflector**: Inside the Informer, the Reflector component runs the watch and list operations, detects resourceVersion too old errors, and performs relist with exponential backoff.

### Controller Reconciliation

1. **Event Handling**: Informer calls controller's OnAdd/OnUpdate/OnDelete handlers. These extract the object key (namespace/name) and enqueue it into a rate-limited work queue (workqueue.RateLimitingInterface).

2. **Worker Pool**: The controller runs N worker goroutines (typically 1-5). Each calls queue.Get(), blocking until work arrives.

3. **Reconcile**: Worker calls the reconcile function with the key. Reconcile reads current state from the Informer cache (lister), compares with desired state, and performs actions (creates child objects, updates status, calls external APIs).

4. **Status Update**: Controllers typically update .status subresource with observedGeneration matching current .metadata.generation, condition status, and timestamps. Status updates bypass validation of spec fields and don't increment generation.

5. **Requeueing**: On error or if reconciliation is incomplete (waiting for external system), the controller returns an error or explicit requeue signal. The work queue applies rate limiting and exponential backoff (starts at 5ms, caps at ~16 minutes).


## Architecture Diagram

```
 ┌─────────────┐
 │   kubectl   │
 │   (client)  │
 └──────┬──────┘
        │ HTTPS (authn/authz)
        ▼
 ┌──────────────────────────────────────────┐
 │         kube-apiserver                   │
 │                                          │
 │  ┌────────────────────────────────┐     │
 │  │ Mutating Admission Chain       │     │
 │  │  webhook-1 → webhook-2 → ...   │     │
 │  └────────────┬───────────────────┘     │
 │               ▼                          │
 │  ┌────────────────────────────────┐     │
 │  │ Validation (OpenAPI Schema)    │     │
 │  └────────────┬───────────────────┘     │
 │               ▼                          │
 │  ┌────────────────────────────────┐     │
 │  │ Validating Admission Chain     │     │
 │  │  webhook-3 → policy-1 → ...    │     │
 │  └────────────┬───────────────────┘     │
 │               ▼                          │
 │  ┌────────────────────────────────┐     │
 │  │ Persist to etcd                │     │
 │  │ (CompareAndSwap with RV check) │     │
 │  └────────────┬───────────────────┘     │
 │               ▼                          │
 │  ┌────────────────────────────────┐     │
 │  │ Watch Cache (in-memory)        │     │
 │  │ Notify all watchers            │     │
 │  └────────────┬───────────────────┘     │
 └───────────────┼──────────────────────────┘
                 │ watch stream
                 ▼
        ┌────────────────┐
        │  Informer      │
        │  (client-side) │
        │                │
        │  ┌──────────┐  │
        │  │  Cache   │  │
        │  │ (Store)  │  │
        │  └──────────┘  │
        └────────┬───────┘
                 │ OnAdd/OnUpdate/OnDelete
                 ▼
        ┌────────────────┐
        │  Work Queue    │
        │  (rate-limited)│
        └────────┬───────┘
                 │ dequeue key
                 ▼
        ┌────────────────┐
        │  Reconcile()   │
        │  - read cache  │
        │  - compute Δ   │
        │  - write API   │
        │  - update sts  │
        └────────────────┘
```

## Failure Modes & Debugging

### 1. Admission Webhook Timeout / Unavailability

**Symptoms**: `kubectl apply` hangs for 10-30 seconds, then fails with "context deadline exceeded" or "connection refused." All creates/updates for matching resources are blocked. Users see 500 Internal Server Error.

**Root Cause**: The API server calls admission webhooks synchronously in the write path. If a webhook pod is down, slow, or unreachable (network policy, DNS), the API server waits until timeout (default 10s, max 30s). If `failurePolicy: Fail` (default), the request is rejected. If `failurePolicy: Ignore`, the webhook is skipped.

**Blast Radius**: Affects all creates/updates matching the webhook's rules. If the webhook matches `*/*` with `namespaceSelector: {}`, the entire cluster's write path is blocked. Critical for GitOps systems where operators continuously reconcile.

**Mitigation**:
- Set `failurePolicy: Ignore` for non-critical webhooks, or during initial deployment
- Use narrow `objectSelector` and `namespaceSelector` to limit scope
- Set `timeoutSeconds: 5` or lower for fast failure
- Run webhook pods with anti-affinity and PodDisruptionBudget
- Monitor webhook latency: `apiserver_admission_webhook_admission_duration_seconds` metric

**Debugging**:
```bash
# Check webhook configuration
kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o yaml

# API server logs show webhook calls
kubectl logs -n kube-system kube-apiserver-KIND_CONTROL_PLANE | grep webhook

# Check if webhook service/endpoints exist
kubectl get svc,endpoints -n webhook-ns

# Test webhook directly (if it exposes /health)
kubectl run curl --rm -it --image=curlimages/curl -- curl -k https://webhook-svc.ns.svc:443/health
```

### 2. Etcd Performance Degradation

**Symptoms**: API server latency increases (p99 >1s for simple GETs). Watch events are delayed. Controllers fall behind. `kubectl get` is slow. Etcd metrics show high fsync duration or large DB size.

**Root Cause**: Etcd is a consensus-based system that persists every write to disk with fsync. Slow disk I/O (network-attached storage, IO contention), large database size (>8GB), or high write rate (>10k writes/sec) cause latency spikes. Defragmentation not running causes bloat.

**Blast Radius**: Cluster-wide. All API operations slow down. Controllers' Informer caches lag behind authoritative state. Status updates delay, causing cascading reconciliation failures. Scheduler can't bind pods quickly.

**Mitigation**:
- Use local SSD or provisioned IOPS volumes for etcd
- Keep etcd DB size <8GB (set `--quota-backend-bytes=8589934592`)
- Run defrag regularly: `etcdctl defrag --cluster`
- Reduce object churn (short-lived pods, high-frequency status updates)
- Use status subresources to avoid updating entire objects
- Monitor `etcd_disk_backend_commit_duration_seconds` (should be <25ms p99)

**Debugging**:
```bash
# Check etcd metrics
kubectl port-forward -n kube-system etcd-KIND_CONTROL_PLANE 2379:2379
curl http://localhost:2379/metrics | grep etcd_disk_backend_commit_duration_seconds

# Check DB size
etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --write-out=table

# Identify large objects in etcd
kubectl get all --all-namespaces -o json | jq '[.items[] | {kind, name: .metadata.name, size: (. | tostring | length)}] | sort_by(.size) | reverse | .[0:10]'
```

### 3. Controller Reconciliation Hot Loop

**Symptoms**: Controller CPU usage at 100%. Work queue depth grows unbounded (`workqueue_depth` metric spiking). Same keys requeue rapidly. Controller logs show continuous reconcile calls for the same object. Object's `metadata.generation` increments rapidly or status thrashes.

**Root Cause**: Non-idempotent reconciliation logic causes the controller to modify the object on every reconcile, triggering a new watch event, which triggers another reconcile. Example: setting a timestamp in spec on every reconcile, or updating status when nothing changed. Another cause: controller watches its own child objects but doesn't filter events, causing cascading reconciles.

**Blast Radius**: Affects the misbehaving controller and increases API server load. Can exhaust etcd write quota. Other controllers slow down due to API server contention. In extreme cases, causes OOMKill of the controller pod.

**Mitigation**:
- Make reconcile idempotent: only write if state has actually changed
- Use `generation`/`observedGeneration` to skip reconcile when spec hasn't changed
- Use event predicates (Predicate interface in controller-runtime) to filter out status-only updates
- Set rate limiting on work queue: `workqueue.NewRateLimitingQueue(workqueue.DefaultControllerRateLimiter())`
- Add reconcile duration histogram to identify slow reconciles

**Debugging**:
```bash
# Check work queue metrics
kubectl port-forward -n controller-ns deploy/my-controller 8080:8080
curl http://localhost:8080/metrics | grep workqueue

# Dump controller logs with timestamps
kubectl logs -n controller-ns deploy/my-controller --timestamps | grep "Reconciling"

# Check object's generation vs observedGeneration
kubectl get myresource example -o jsonpath='{.metadata.generation} {.status.observedGeneration}'

# Watch for rapid updates
kubectl get myresource example -w
```

### 4. ResourceVersion Conflict (Optimistic Locking Failure)

**Symptoms**: `kubectl apply` or controller update fails with "409 Conflict: the object has been modified; please apply your changes to the latest version and try again." Retries eventually succeed.

**Root Cause**: Two clients (or one client with stale cache) attempt to update the same object concurrently. The API server's compare-and-swap check fails because the resourceVersion in the update request doesn't match the current etcd resourceVersion. This is expected behavior for optimistic concurrency control.

**Blast Radius**: Limited to the specific update. Client retries (with exponential backoff) usually succeed within seconds. Not harmful unless retry logic is missing or conflict rate is extremely high.

**Mitigation**:
- Use client-go's RetryOnConflict helper: `retry.RetryOnConflict(retry.DefaultRetry, func() error { ... })`
- Ensure controllers read from cache (Lister) before each update, not once at startup
- For SSA, conflicts only occur on fields managed by the same fieldManager
- Avoid manual updates of objects managed by controllers

**Debugging**:
```bash
# Read current resourceVersion
kubectl get deploy nginx -o jsonpath='{.metadata.resourceVersion}'

# Manually trigger conflict (two terminals)
# Terminal 1: kubectl edit deploy nginx  # change replicas to 3
# Terminal 2: kubectl edit deploy nginx  # change replicas to 5 (will conflict)

# Controller logs show retries
kubectl logs -n kube-system deploy/kube-controller-manager | grep "conflict"
```


## Lightweight Lab

```bash
# 1. Start a kind cluster if not already running
./scripts/kind-up.sh prep

# 2. Apply the CRD (CustomResourceDefinition) for Widget
# Observe: This creates the schema for a new API resource type
kubectl apply -f lab/crd.yaml
kubectl get crd widgets.demo.io -o yaml | grep "group:\|version:\|kind:"

# 3. Create a Widget instance
# Observe: The API server validates against the CRD schema, assigns resourceVersion and generation
kubectl apply -f lab/widget.yaml
kubectl get widget demo -o yaml | grep "resourceVersion:\|generation:\|uid:"

# 4. Inspect the full object
# Observe: metadata (resourceVersion, generation, uid, creationTimestamp), spec (your desired state), status (empty until a controller reconciles)
kubectl get widget demo -o yaml

# 5. Update the Widget spec
# Observe: resourceVersion increments (etcd revision changes), generation increments (spec changed)
kubectl patch widget demo --type=merge -p '{"spec":{"size":"large"}}'
kubectl get widget demo -o jsonpath='{.metadata.resourceVersion} {.metadata.generation}'

# 6. Update just the status (simulating a controller)
# Observe: resourceVersion increments but generation does NOT (status updates don't affect generation)
kubectl patch widget demo --subresource=status --type=merge -p '{"status":{"observedGeneration":1,"conditions":[{"type":"Ready","status":"True","lastTransitionTime":"2025-01-15T00:00:00Z"}]}}'
kubectl get widget demo -o jsonpath='{.metadata.resourceVersion} {.metadata.generation} {.status.observedGeneration}'

# 7. Watch for changes in real-time
# Observe: Opens a watch stream; any updates will print MODIFIED events
kubectl get widget demo -w &
WATCH_PID=$!
sleep 2
kubectl patch widget demo --type=merge -p '{"spec":{"size":"small"}}'
sleep 2
kill $WATCH_PID

# 8. Demonstrate optimistic locking (resourceVersion conflict)
# Observe: The second update fails because resourceVersion has changed
RV=$(kubectl get widget demo -o jsonpath='{.metadata.resourceVersion}')
kubectl patch widget demo --type=merge -p '{"spec":{"size":"medium"}}'
# This next command uses the stale resourceVersion and should fail
kubectl patch widget demo --type=merge -p "{\"metadata\":{\"resourceVersion\":\"$RV\"},\"spec\":{\"size\":\"huge\"}}"

# 9. Explore additional commands
# List all API resources (including our custom Widget)
kubectl api-resources | grep widget

# Check API server audit logs (if enabled) to see the request path
kubectl logs -n kube-system kube-apiserver-prep-control-plane | tail -20

# View etcd contents directly (advanced)
kubectl exec -n kube-system etcd-prep-control-plane -- sh -c \
  "ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
   --cacert=/etc/kubernetes/pki/etcd/ca.crt \
   --cert=/etc/kubernetes/pki/etcd/server.crt \
   --key=/etc/kubernetes/pki/etcd/server.key \
   get /registry/demo.io/widgets/default/demo" | strings
```
