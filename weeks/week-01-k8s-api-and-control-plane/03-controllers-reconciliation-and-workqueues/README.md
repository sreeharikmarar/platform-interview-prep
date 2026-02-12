# Controllers, Reconciliation & Work Queues

## What you should be able to do
- Explain level-based reconciliation.
- Explain informers/queues/backoff.
- Design safe idempotent reconcilers.

## Mental model

Kubernetes controllers implement the reconciliation pattern: a continuous feedback loop that observes current state, compares it to desired state, and takes actions to eliminate the difference. Unlike imperative systems where you issue commands ("start this container"), controllers are declarative - you state what you want (a Deployment with 3 replicas) and the controller continuously works to make reality match your declaration.

The key insight is that controllers are level-triggered, not edge-triggered. They don't care about events like "a pod was deleted" - they only care about the current state snapshot: "there are 2 pods but should be 3." This makes controllers resilient to missed events, network partitions, and restarts. If a controller crashes for 10 minutes, when it comes back up it reads current state from its cache and reconciles any drift that accumulated. There's no need to replay a log of events.

Work queues decouple event handling from reconciliation. When an Informer receives a watch event (pod created/updated/deleted), the event handler doesn't process it immediately - it extracts the object's key (namespace/name) and adds it to a rate-limited queue. Worker goroutines pull keys from the queue and call the reconcile function. This provides natural batching (multiple updates to the same object collapse into one reconcile), rate limiting (exponential backoff after failures), and parallelism (multiple workers processing different objects).

The reconcile function must be idempotent and side-effect-free in terms of Kubernetes state. It reads from local cache (not the API server), computes the desired set of child objects, and compares with actual. If they match, it's a no-op. If they differ, it creates/updates/deletes to converge. Critically, the controller doesn't track what it did last time - it compares current desired vs current actual every time. This enables self-healing: if someone manually deletes a pod, the next reconcile detects the missing pod and recreates it, even though the controller didn't "see" the delete event.

## Key Concepts

- **Informer**: Client-side component that watches a resource type, maintains a local cache (Store/Indexer), and invokes event handlers (AddFunc/UpdateFunc/DeleteFunc)
- **Reflector**: Component inside Informer that manages the watch stream, handles reconnection, and performs periodic relist to resync cache
- **SharedInformerFactory**: Factory that creates Informers and ensures multiple controllers watching the same resource share one watch connection
- **Lister**: Read-only interface to the Informer cache, used in reconcile to fetch objects without hitting the API server
- **Work Queue**: Rate-limited FIFO queue that holds object keys (namespace/name) to be reconciled; provides Add/Get/Done methods
- **Rate Limiting**: Exponential backoff for failed reconciles (5ms, 10ms, 20ms, ... capped at ~16 minutes)
- **Reconcile**: Function signature `reconcile(ctx context.Context, req Request) (Result, error)` that processes one object
- **Requeue**: Return value signaling the controller should retry this key after a delay (Result{Requeue: true, RequeueAfter: 5*time.Minute})
- **Level-triggered**: Controller logic based on current state snapshot, not on event history
- **Idempotency**: Reconcile can be called multiple times with same input and produces same outcome

## Internals

### Informer Architecture

1. **Watch Stream Setup**: Reflector calls `client.Watch()` for the resource type, specifying a resourceVersion (starting point). The API server returns a long-lived HTTP connection streaming JSON events.

2. **Event Processing**: Reflector receives ADDED/MODIFIED/DELETED events. For each:
   - Extracts the object
   - Updates the local Store (cache) keyed by namespace/name
   - Invokes registered event handlers in order

3. **Periodic Resync**: Reflector periodically (default 10 hours) calls List to fetch all objects and compares with cache. For any differences, it synthesizes UPDATE events. This ensures eventual consistency even if watch events are missed.

4. **Cache Structure**: The Store is typically a thread-safe map with indexers. Default index is namespace/name. You can add custom indices (e.g., by label selector) for efficient queries.

5. **Lister Interface**: Controllers use `lister.Get(namespace, name)` to read from cache instead of API calls. This reduces API server load and provides consistent snapshot during reconcile.

### Work Queue Mechanics

1. **Enqueuing**: Event handlers (OnAdd/OnUpdate/OnDelete) extract the object key and call `queue.Add(key)`. The queue deduplicates - if the key is already queued, no duplicate is added. This provides natural coalescing.

2. **Rate Limiting Queue**: Wraps a basic queue with rate limiting. Types:
   - **ItemExponentialFailureRateLimiter**: Tracks failure count per item, applies exponential backoff (baseDelay * 2^failures, capped at maxDelay)
   - **ItemFastSlowRateLimiter**: Fast retries for N attempts, then slow retries
   - **BucketRateLimiter**: Token bucket limiting requests per second globally

3. **Worker Loop**: Controller starts N worker goroutines (typically 1-5). Each runs:
   ```go
   for queue.Get() {
       key := item.(string)
       err := reconcile(key)
       if err != nil {
           queue.AddRateLimited(key) // retry with backoff
       } else {
           queue.Forget(key) // reset backoff counter
       }
       queue.Done(key) // mark processing complete
   }
   ```

4. **Shutdown**: Controller signals workers to stop via context cancellation, waits for queue to drain (ShutDown()), and exits gracefully.

### Reconcile Loop

1. **Fetch Object**: Reconcile receives a key (namespace/name). It calls `lister.Get()` to fetch from cache. If not found, the object was deleted - clean up owned resources and return.

2. **Check ObservedGeneration**: Compare `status.observedGeneration` with `metadata.generation`. If equal, spec hasn't changed since last reconcile - might skip work or only check status conditions.

3. **Compute Desired State**: Based on spec, compute the set of child resources that should exist. For example, Deployment controller computes desired ReplicaSet based on `.spec.template`.

4. **Fetch Actual State**: List existing child resources (e.g., ReplicaSets owned by this Deployment) using cache or API calls. Use owner references to identify children.

5. **Diff and Reconcile**: Compare desired vs actual:
   - Missing child → Create it
   - Extra child → Delete it (unless it's from an old spec version to preserve)
   - Child exists but wrong spec → Update it

6. **Update Status**: Write `.status` subresource with:
   - `observedGeneration = metadata.generation`
   - Conditions (e.g., `Ready`, `Progressing`)
   - Summary fields (e.g., `replicas`, `readyReplicas`)

7. **Return**: Return nil if successful, error if transient failure (will requeue with backoff), or Result{RequeueAfter: duration} to check again later (e.g., waiting for external system).

### Owner References and Garbage Collection

Controllers use `metadata.ownerReferences` to establish parent-child relationships. When creating a child resource, the controller sets:

```yaml
ownerReferences:
- apiVersion: apps/v1
  kind: Deployment
  name: nginx
  uid: abc-123
  controller: true  # This owner is the controller
  blockOwnerDeletion: true  # Prevent parent deletion until children are gone
```

When the parent is deleted, the Garbage Collector controller automatically deletes all children with this owner reference (cascading delete). If `controller: false`, it's an informational reference only.

### Predicates and Filtering

To avoid unnecessary reconciles, controllers use predicates (filter functions):

- **GenerationChangedPredicate**: Only trigger on spec changes (metadata.generation increment)
- **ResourceVersionChangedPredicate**: Trigger on any change including status
- **AnnotationChangedPredicate**: Only trigger if specific annotations change
- **LabelChangedPredicate**: Only trigger if labels change

Example from controller-runtime:
```go
predicate.Funcs{
    UpdateFunc: func(e event.UpdateEvent) bool {
        return e.ObjectOld.GetGeneration() != e.ObjectNew.GetGeneration()
    },
}
```

This prevents status-only updates from triggering reconcile.


## Architecture Diagram

```
┌──────────────────────────────────────────────────────────┐
│  API Server                                              │
│  Watch stream: GET /api/v1/pods?watch=1&rv=12345         │
└────────────────────┬─────────────────────────────────────┘
                     │ HTTPS (chunked transfer)
                     │ Events: ADDED/MODIFIED/DELETED
                     ▼
          ┌──────────────────────┐
          │   Reflector          │
          │  - List & Watch      │
          │  - Reconnect logic   │
          │  - Periodic resync   │
          └──────────┬───────────┘
                     │ Objects
                     ▼
          ┌──────────────────────┐
          │   Store / Indexer    │
          │  (in-memory cache)   │
          │  Key: ns/name        │
          │  Value: full object  │
          └──────────┬───────────┘
                     │
         ┌───────────┴───────────┐
         │                       │
         ▼                       ▼
┌────────────────┐      ┌────────────────┐
│ Event Handlers │      │    Lister      │
│  OnAdd()       │      │  Get(ns,name)  │
│  OnUpdate()    │      │  List()        │
│  OnDelete()    │      └────────────────┘
└────────┬───────┘               │
         │ Extract key           │ Read cache
         ▼                       │
┌──────────────────────┐         │
│  Work Queue          │         │
│  (rate-limited)      │         │
│                      │         │
│  [ns/foo]           │         │
│  [ns/bar]           │         │
│  [ns/baz]           │         │
└──────────┬───────────┘         │
           │ Dequeue             │
           ▼                     │
  ┌─────────────────┐            │
  │  Worker Pool    │            │
  │  (N goroutines) │            │
  └────────┬────────┘            │
           │                     │
           ▼                     │
  ┌────────────────────────────┐ │
  │  Reconcile(key)            │ │
  │                            │ │
  │  1. lister.Get(key) ◄──────┘
  │  2. Compute desired state  │
  │  3. List actual children   │
  │  4. Diff and apply Δ       │
  │  5. Update status          │
  │  6. Return error/requeue   │
  └────────┬───────────────────┘
           │
           ├─ nil → queue.Forget(key)
           └─ error → queue.AddRateLimited(key)
                      (exponential backoff)
```

## Failure Modes & Debugging

### 1. Reconciliation Hot Loop

**Symptoms**: Controller CPU at 100%, work queue depth growing unbounded, same keys requeuing thousands of times per minute, API server request rate spiking, object's resourceVersion incrementing rapidly with no apparent changes.

**Root Cause**: Non-idempotent reconcile logic causes the controller to write the object on every reconcile, which triggers a new watch event, which enqueues the key again. Common causes:
- Setting timestamps in spec on every reconcile
- Updating status even when values haven't changed (status writer always increments resourceVersion)
- Not using equality checks before updates (e.g., `reflect.DeepEqual(desired, actual)`)
- Watching own status updates without filtering

**Blast Radius**: Affects the misbehaving controller and increases API server load. Can exhaust API server's etcd write quota. In extreme cases, OOMKills the controller pod due to unbounded queue growth. Other controllers slow down due to API server contention.

**Mitigation**:
- Make reconcile idempotent: only write if actual state differs from desired
- Use generation/observedGeneration to detect spec changes
- Compare status fields before updating: `if !equality.Semantic.DeepEqual(newStatus, oldStatus) { update() }`
- Use GenerationChangedPredicate to filter status-only updates from triggering reconcile
- Add rate limiting to work queue (default in controller-runtime)
- Monitor workqueue_depth and workqueue_adds_total metrics

**Debugging**:
```bash
# Check work queue metrics
curl http://controller:8080/metrics | grep workqueue_depth
curl http://controller:8080/metrics | grep workqueue_retries_total

# Watch object for rapid changes
kubectl get deployment nginx -w

# Check generation vs observedGeneration
kubectl get deployment nginx -o json | jq '{gen: .metadata.generation, obsGen: .status.observedGeneration, rv: .metadata.resourceVersion}'

# Dump controller logs with timestamps to see reconcile frequency
kubectl logs -n kube-system deploy/kube-controller-manager --timestamps | grep "Reconciling deployment/nginx"

# Profile the controller
kubectl port-forward -n controller-ns pod/my-controller 6060:6060
go tool pprof http://localhost:6060/debug/pprof/profile
```

### 2. Informer Cache Staleness (Watch Lag)

**Symptoms**: Controller makes decisions based on outdated state. For example, creates duplicate pods because cache doesn't reflect recently created pods. Reconcile logic looks correct but produces wrong results intermittently. Events show "FailedCreate: pods 'nginx-abc' already exists."

**Root Cause**: The Informer cache is eventually consistent - there's a delay between object creation/update in etcd and the watch event reaching the Informer. If reconcile runs during this window, it sees stale state. Common triggers:
- High API server latency (etcd slow)
- Network delays between controller and API server
- Reconcile triggered immediately after a write (same reconcile loop)
- Cache hasn't synced yet (controller started before cache warmed up)

**Blast Radius**: Limited to individual reconcile decisions. Can cause spurious errors that self-correct on next reconcile. Can create resource leaks if duplicate creates succeed with generated names. Rarely causes persistent issues because eventual consistency self-heals.

**Mitigation**:
- Wait for cache sync before starting workers: `cache.WaitForCacheSync(stopCh, informer.HasSynced)`
- Don't reconcile immediately after writing - let the watch event trigger the next reconcile
- Handle "already exists" errors gracefully (list and compare, or use SSA which is idempotent)
- For critical consistency, do a live API read instead of cache read (trade-off: higher latency)
- Add artificial delay with RequeueAfter for operations depending on cache consistency

**Debugging**:
```bash
# Check if Informer has synced
# In controller code: if !cache.WaitForCacheSync(...) { return error }

# Force a relist to resync cache
# (Not directly exposed, but restarting controller forces resync)

# Compare cache vs API server
kubectl get pod nginx-abc  # Live read
# vs controller cache (check logs showing what it sees)

# Monitor watch lag (requires custom metrics)
# Track time between object update and watch event arrival
```

### 3. External Side Effect Fencing Failure

**Symptoms**: Controller performs external actions (calling cloud API, creating DNS records, sending email) multiple times for the same object. For example, sending "deployment ready" notification 5 times, or creating duplicate load balancers in AWS.

**Root Cause**: Reconcile is called multiple times (retries, periodic resync, controller restart), and the external side effect isn't idempotent or fenced. Unlike Kubernetes object creation (which has unique UIDs and SSA), external systems may not provide idempotency. If reconcile calls CreateLoadBalancer() without checking if it exists, every reconcile creates a new LB.

**Blast Radius**: Resource leaks in external systems (orphaned cloud resources costing money), duplicate notifications annoying users, rate limiting in external APIs causing reconcile failures.

**Mitigation**:
- Check for existence before creating external resources (idempotency check)
- Use external resource IDs based on Kubernetes object UID (stable across reconciles)
- Track external resource IDs in object's status or annotations
- Use finalizers to clean up external resources when object is deleted
- Implement correlation IDs / request IDs for external API calls to detect duplicates
- Add status conditions like "ExternalResourceProvisioned: True" and check before re-provisioning

**Debugging**:
```bash
# Check object's status for external resource tracking
kubectl get myresource foo -o jsonpath='{.status.loadBalancerID}'

# Review controller logs for external API calls
kubectl logs -n controller-ns deploy/my-controller | grep "Creating LoadBalancer"

# Audit external system for orphaned resources
aws elb describe-load-balancers --query 'LoadBalancerDescriptions[?starts_with(LoadBalancerName, `k8s-`)]'

# Check for finalizers (should block deletion until cleanup)
kubectl get myresource foo -o jsonpath='{.metadata.finalizers}'
```

### 4. Work Queue Backoff Saturation

**Symptoms**: Controller stops processing new work. Work queue depth stays constant at a high number. All workers blocked on rate limiter. Latency from event to reconcile grows unboundedly. Logs show "rate limit exceeded" or long delays between reconcile attempts.

**Root Cause**: Too many keys in the queue are in backoff (due to repeated failures), and the rate limiter is blocking all workers. This happens when a large number of objects enter a failing state simultaneously (e.g., ImagePullBackOff for all pods due to registry down). The backoff for each key reaches maximum (16 minutes), and workers spend most time waiting.

**Blast Radius**: Controller becomes unresponsive to new events. Even healthy objects that need reconciliation are delayed. Cascading failure if the controller manages critical infrastructure.

**Mitigation**:
- Increase worker count to allow parallel processing of unblocked items
- Tune rate limiter parameters (lower max delay, faster backoff reset)
- Implement selective backoff - don't apply backoff for certain errors (e.g., "not found")
- Add separate queues for different priority levels
- Use circuit breaker pattern - stop retrying if error rate exceeds threshold
- Monitor and alert on workqueue_queue_duration_seconds p99

**Debugging**:
```bash
# Check queue depth and retry stats
curl http://controller:8080/metrics | grep 'workqueue_depth{name="myqueue"}'
curl http://controller:8080/metrics | grep 'workqueue_retries_total{name="myqueue"}'

# Check rate limiter delay
curl http://controller:8080/metrics | grep 'workqueue_longest_running_processor_seconds'

# Identify which keys are stuck
# (Requires custom logging in controller to track per-key backoff state)

# Temporary mitigation: restart controller to reset backoff
kubectl rollout restart -n controller-ns deploy/my-controller
```


## Lightweight Lab

```bash
# 1. Create a parent ConfigMap
kubectl apply -f lab/parent-cm.yaml
# Observe: Parent CM with some data

# 2. Inspect the parent
kubectl get cm parent -o yaml
# Observe: Contains data that a controller will use to create a child resource

# 3. Run a simple reconciler (implemented as a Job for this lab)
kubectl apply -f lab/reconciler-job.yaml
# Observe: Job creates a pod that acts as a one-shot controller

# 4. Watch the reconciler logs
kubectl logs job/cm-reconciler --follow
# Observe: Logs showing:
#   - Watching for parent ConfigMap
#   - Detected parent
#   - Computed desired child ConfigMap
#   - Created child ConfigMap
#   - Updated parent status (if implemented)

# 5. Verify child was created
kubectl get cm child -o yaml
# Observe: Child CM with owner reference pointing to parent, data derived from parent

# 6. Check owner reference
kubectl get cm child -o jsonpath='{.metadata.ownerReferences}'
# Observe: Reference to parent CM with controller: true

# 7. Demonstrate reconciliation (modify parent, see child update)
kubectl patch cm parent --type=merge -p '{"data":{"key":"new-value"}}'
# If the reconciler were a continuous controller, it would detect this and update child
# Since it's a Job, manually re-run or modify lab to use a Deployment

# 8. Demonstrate garbage collection (delete parent, child is auto-deleted)
kubectl delete cm parent
sleep 2
kubectl get cm child
# Observe: Child is automatically deleted due to ownerReference

# 9. Additional exploration: check work queue behavior
# (Requires a real controller with metrics endpoint)
# kubectl port-forward -n controller-ns deploy/my-controller 8080:8080
# curl http://localhost:8080/metrics | grep workqueue

# 10. Simulate reconcile idempotency
# Re-apply parent multiple times and verify child isn't recreated unnecessarily
kubectl apply -f lab/parent-cm.yaml
kubectl apply -f lab/reconciler-job.yaml
kubectl logs job/cm-reconciler | grep "Child already exists, no action needed"
```
