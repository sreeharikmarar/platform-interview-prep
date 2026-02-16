# Informers, Caches & Indexers

## Overview

Informers are the foundation of efficient Kubernetes controllers. They transform the expensive LIST+WATCH API pattern into local in-memory caches, dramatically reducing API server load and enabling controllers to scale. Understanding informers, the reflector/DeltaFIFO/store pipeline, and custom indexers is essential for building production-grade controllers.

## What You Should Be Able to Do

After mastering this topic, you should be able to:

- Explain how LIST+WATCH populates and maintains local caches
- Describe the reflector, DeltaFIFO, and store components and their roles
- Implement ResourceEventHandlerFuncs to react to resource changes
- Use SharedInformerFactory to avoid duplicate watches
- Create custom indexers for efficient lookups beyond namespace/name
- Configure resync periods and understand their impact
- Debug informer cache issues like stale reads and watch disconnections
- Explain how informers reduce API server load compared to polling

## Mental Model

**Informers convert expensive API server calls into local cache reads**:
- **LIST** seeds the cache with current state at startup
- **WATCH** streams incremental updates to keep cache fresh
- **Resync** periodically requeues all items to handle missed events or external drift
- **Indexers** maintain secondary indexes (like "by owner", "by label") for fast lookups
- **Correctness comes from reconciliation, not perfectly fresh reads**

Think of informers like a newspaper subscription: instead of going to the newsstand (API server) every time you want news (resource state), you get a daily delivery (WATCH events) and keep old issues (cache) for reference. Occasionally you check if you missed any issues (resync).

## Core Concepts

### The LIST+WATCH Pattern

Kubernetes controllers use LIST+WATCH to stay synchronized with cluster state:

```
1. LIST: Fetch all resources of a type (expensive, returns full state)
2. WATCH: Open long-lived connection for incremental updates
3. On WATCH disconnect: Re-LIST and re-WATCH

Without informers:
  Controller -> API server LIST (/api/v1/pods) [100 pods, 100KB response]
  Controller -> API server LIST (/api/v1/pods) [100 pods, 100KB response]
  Controller -> API server LIST (/api/v1/pods) [100 pods, 100KB response]
  (Repeated every reconcile = API server overload)

With informers:
  Controller -> API server LIST (/api/v1/pods) [100 pods, 100KB response, ONCE]
  Controller -> API server WATCH (/api/v1/pods?watch=1&resourceVersion=12345)
    <- ADDED pod-101
    <- MODIFIED pod-50
    <- DELETED pod-23
  Controller reads from local cache (no API calls)
```

### Informer Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                      API Server                              │
│                    (etcd backend)                            │
└────────────┬─────────────────────────────┬───────────────────┘
             │ LIST                        │ WATCH
             │ (initial sync)              │ (stream updates)
             v                             v
┌────────────────────────────────────────────────────────────────┐
│  Reflector                                                     │
│  - Issues LIST to get initial state + resourceVersion         │
│  - Opens WATCH connection from that resourceVersion           │
│  - Handles watch errors and reconnects                        │
│  - Feeds updates into DeltaFIFO                               │
└────────────┬───────────────────────────────────────────────────┘
             │ Enqueues Add/Update/Delete events
             v
┌────────────────────────────────────────────────────────────────┐
│  DeltaFIFO (Delta First-In-First-Out)                         │
│  - Queues deltas (Added, Modified, Deleted, Sync)            │
│  - Deduplicates: multiple updates → single item               │
│  - Ensures ordering: updates processed in order               │
└────────────┬───────────────────────────────────────────────────┘
             │ Pop() items in order
             v
┌────────────────────────────────────────────────────────────────┐
│  Event Handler (ResourceEventHandlerFuncs)                    │
│  - OnAdd(obj)    - called when object created                 │
│  - OnUpdate(old, new) - called when object modified           │
│  - OnDelete(obj) - called when object deleted                 │
│  - Typically enqueues keys into controller work queue         │
└────────────┬───────────────────────────────────────────────────┘
             │ Updates cache and triggers handlers
             v
┌────────────────────────────────────────────────────────────────┐
│  Store (ThreadSafeStore + Indexers)                           │
│  - In-memory cache of objects (keyed by namespace/name)       │
│  - Supports Get(), List(), ListKeys()                         │
│  - Maintains custom indexes for fast lookups                  │
│  - Thread-safe for concurrent reads                           │
└────────────────────────────────────────────────────────────────┘
             ^
             │ Controller reads from cache (not API server)
┌────────────┴───────────────────────────────────────────────────┐
│  Controller Reconcile Loop                                     │
│  - Reads objects from informer cache (fast, local)            │
│  - Writes updates to API server (slow, remote)                │
└────────────────────────────────────────────────────────────────┘
```

### Basic Informer Setup

```go
package main

import (
    "fmt"
    "time"

    corev1 "k8s.io/api/core/v1"
    "k8s.io/apimachinery/pkg/labels"
    "k8s.io/client-go/informers"
    "k8s.io/client-go/kubernetes"
    "k8s.io/client-go/tools/cache"
    "k8s.io/client-go/tools/clientcmd"
)

func main() {
    // Create Kubernetes client
    config, err := clientcmd.BuildConfigFromFlags("", clientcmd.RecommendedHomeFile)
    if err != nil {
        panic(err)
    }
    clientset, err := kubernetes.NewForConfig(config)
    if err != nil {
        panic(err)
    }

    // Create SharedInformerFactory
    informerFactory := informers.NewSharedInformerFactory(clientset, 10*time.Hour)

    // Get Pod informer
    podInformer := informerFactory.Core().V1().Pods()

    // Add event handlers
    podInformer.Informer().AddEventHandler(cache.ResourceEventHandlerFuncs{
        AddFunc: func(obj interface{}) {
            pod := obj.(*corev1.Pod)
            fmt.Printf("Pod ADDED: %s/%s\n", pod.Namespace, pod.Name)
        },
        UpdateFunc: func(oldObj, newObj interface{}) {
            oldPod := oldObj.(*corev1.Pod)
            newPod := newObj.(*corev1.Pod)
            // Only log if spec changed (not status-only updates)
            if oldPod.ResourceVersion != newPod.ResourceVersion {
                fmt.Printf("Pod UPDATED: %s/%s\n", newPod.Namespace, newPod.Name)
            }
        },
        DeleteFunc: func(obj interface{}) {
            pod := obj.(*corev1.Pod)
            fmt.Printf("Pod DELETED: %s/%s\n", pod.Namespace, pod.Name)
        },
    })

    // Start informers
    stopCh := make(chan struct{})
    defer close(stopCh)
    informerFactory.Start(stopCh)

    // Wait for caches to sync
    if !cache.WaitForCacheSync(stopCh, podInformer.Informer().HasSynced) {
        panic("Failed to sync informer cache")
    }

    fmt.Println("Informer cache synced, watching for changes...")

    // Read from cache (not API server!)
    pods, err := podInformer.Lister().Pods("default").List(labels.Everything())
    if err != nil {
        panic(err)
    }
    fmt.Printf("Found %d pods in default namespace (from cache)\n", len(pods))

    // Block forever
    <-stopCh
}
```

### SharedInformerFactory

SharedInformerFactory prevents duplicate watches when multiple controllers watch the same resource type:

```go
// WITHOUT SharedInformerFactory (BAD: duplicate watches)
func setupControllers(clientset kubernetes.Interface) {
    // Controller 1 creates its own Pod informer
    informer1 := cache.NewSharedIndexInformer(...)

    // Controller 2 creates its own Pod informer
    informer2 := cache.NewSharedIndexInformer(...)

    // Result: Two separate WATCH connections to API server for Pods
    // Result: Two separate in-memory caches of all Pods
}

// WITH SharedInformerFactory (GOOD: shared watch and cache)
func setupControllers(clientset kubernetes.Interface) {
    factory := informers.NewSharedInformerFactory(clientset, 10*time.Hour)

    // Both controllers use the same Pod informer
    podInformer := factory.Core().V1().Pods()

    controller1.SetupInformer(podInformer)
    controller2.SetupInformer(podInformer)

    // Result: Single WATCH connection to API server for Pods
    // Result: Single in-memory cache shared by both controllers
}
```

**Key benefits**:
- **Reduced API server load**: Only one WATCH per resource type, not one per controller
- **Lower memory usage**: Single cache instead of duplicate caches
- **Consistent view**: All controllers see the same cached state
- **Automatic lifecycle management**: Factory handles starting/stopping informers

### ResourceEventHandlerFuncs

Event handlers are triggered when the cache is updated:

```go
// Simple handler: just log events
podInformer.Informer().AddEventHandler(cache.ResourceEventHandlerFuncs{
    AddFunc: func(obj interface{}) {
        pod := obj.(*corev1.Pod)
        log.Printf("Pod added: %s/%s", pod.Namespace, pod.Name)
    },
    UpdateFunc: func(oldObj, newObj interface{}) {
        oldPod := oldObj.(*corev1.Pod)
        newPod := newObj.(*corev1.Pod)
        log.Printf("Pod updated: %s/%s", newPod.Namespace, newPod.Name)
    },
    DeleteFunc: func(obj interface{}) {
        pod := obj.(*corev1.Pod)
        log.Printf("Pod deleted: %s/%s", pod.Namespace, pod.Name)
    },
})

// Controller handler: enqueue work items
podInformer.Informer().AddEventHandler(cache.ResourceEventHandlerFuncs{
    AddFunc: func(obj interface{}) {
        key, err := cache.MetaNamespaceKeyFunc(obj)
        if err == nil {
            workqueue.Add(key) // Enqueue "namespace/name" for reconciliation
        }
    },
    UpdateFunc: func(oldObj, newObj interface{}) {
        key, err := cache.MetaNamespaceKeyFunc(newObj)
        if err == nil {
            workqueue.Add(key)
        }
    },
    DeleteFunc: func(obj interface{}) {
        key, err := cache.DeletionHandlingMetaNamespaceKeyFunc(obj)
        if err == nil {
            workqueue.Add(key)
        }
    },
})
```

**Important patterns**:
- **Enqueue keys, not objects**: Objects can be large; queues should be lightweight
- **Use DeletionHandlingMetaNamespaceKeyFunc for deletes**: Handles tombstones correctly
- **Filter events in handlers**: Avoid reconciling every status update
- **Don't block in handlers**: Event processing must be fast; do heavy work in reconcile

### Custom Indexers

Indexers enable fast lookups beyond the default namespace/name key:

```go
// Default index: by namespace/name
pod, err := podInformer.Lister().Pods("default").Get("my-pod")

// Custom index: by node name (find all pods on a node)
nodeNameIndexer := cache.Indexers{
    "byNodeName": func(obj interface{}) ([]string, error) {
        pod := obj.(*corev1.Pod)
        return []string{pod.Spec.NodeName}, nil
    },
}

podInformer := cache.NewSharedIndexInformer(
    listWatcher,
    &corev1.Pod{},
    resyncPeriod,
    nodeNameIndexer, // Pass custom indexers
)

// Use custom index for fast lookups
podsOnNode, err := podInformer.GetIndexer().ByIndex("byNodeName", "node-1")
// Returns all pods on node-1 without iterating entire cache

// Real-world example: Index pods by owner reference
ownerIndexer := cache.Indexers{
    "byOwner": func(obj interface{}) ([]string, error) {
        pod := obj.(*corev1.Pod)
        owner := metav1.GetControllerOf(pod)
        if owner == nil {
            return nil, nil
        }
        return []string{string(owner.UID)}, nil
    },
}

// Find all pods owned by a ReplicaSet
pods, err := podInformer.GetIndexer().ByIndex("byOwner", replicaSet.UID)
```

**When to use custom indexers**:
- Finding child resources by parent UID (owner references)
- Listing resources by label or annotation
- Grouping resources by node, namespace, or custom field
- Avoiding full cache scans with List + filter

**Performance comparison**:
```go
// WITHOUT custom indexer: O(n) scan of cache
func findPodsOnNode(lister v1.PodLister, nodeName string) ([]*corev1.Pod, error) {
    allPods, err := lister.List(labels.Everything())
    if err != nil {
        return nil, err
    }
    var result []*corev1.Pod
    for _, pod := range allPods {
        if pod.Spec.NodeName == nodeName {
            result = append(result, pod)
        }
    }
    return result, nil // Scanned ALL pods
}

// WITH custom indexer: O(1) lookup
func findPodsOnNode(indexer cache.Indexer, nodeName string) ([]*corev1.Pod, error) {
    objs, err := indexer.ByIndex("byNodeName", nodeName)
    // Direct index lookup, no iteration
}
```

### Resync Period

The resync period controls how often cached items are re-enqueued for reconciliation:

```go
// Create informer with 10-hour resync
informerFactory := informers.NewSharedInformerFactory(clientset, 10*time.Hour)
```

**What resync does**:
1. Every 10 hours, all items in cache are re-sent through event handlers
2. Event handlers trigger with `OnUpdate(obj, obj)` for each item
3. Controllers reconcile all resources, checking for drift

**When to use resync**:
- **Detect external drift**: Cloud resources modified outside Kubernetes
- **Recover from missed watch events**: Network glitches can drop events
- **Heal inconsistent state**: Reconcile everything periodically

**Tradeoffs**:
- **Shorter period (1h)**: More CPU/API load, faster drift detection
- **Longer period (24h)**: Less load, slower drift detection
- **No resync (0)**: Minimum load, relies on controllers to detect drift
- **controller-runtime default**: 10 hours (good balance for most use cases)

**Important gotcha**: Resync does NOT re-LIST from API server—it just re-triggers handlers from cache. To force a fresh LIST (e.g., after API server restart), restart your controller.

## Internals: How Informers Work

### Reflector: LIST+WATCH Engine

The Reflector is responsible for keeping the cache synchronized with the API server:

```go
// Simplified reflector logic (pseudocode)
func (r *Reflector) Run(stopCh <-chan struct{}) {
    // Phase 1: LIST to get initial state
    list, resourceVersion, err := r.listerWatcher.List(options)
    items := extractListItems(list)

    // Populate DeltaFIFO with initial state
    for _, item := range items {
        r.store.Add(item)
    }

    // Phase 2: WATCH for updates starting from resourceVersion
    for {
        watcher, err := r.listerWatcher.Watch(resourceVersion)

        // Process watch events
        for event := range watcher.ResultChan() {
            switch event.Type {
            case watch.Added:
                r.store.Add(event.Object)
            case watch.Modified:
                r.store.Update(event.Object)
            case watch.Deleted:
                r.store.Delete(event.Object)
            case watch.Error:
                // Re-LIST and re-WATCH on error
                goto Relist
            }
            resourceVersion = event.Object.GetResourceVersion()
        }

        // Watch closed unexpectedly; re-LIST and re-WATCH
        Relist:
        continue
    }
}
```

**Key behaviors**:
- **LIST on startup**: Seeds cache with all existing resources
- **WATCH from resourceVersion**: Only receives changes after LIST
- **Reconnect on error**: Re-LIST to get current state, then re-WATCH
- **Backoff on repeated failures**: Exponential backoff prevents thundering herd

### DeltaFIFO: Ordered Update Queue

DeltaFIFO ensures updates are processed in order and deduplicated:

```
Timeline:
  t=0: Pod created (ResourceVersion=100)
  t=1: Pod updated (ResourceVersion=101)
  t=2: Pod updated (ResourceVersion=102)
  t=3: Pod deleted

Without DeltaFIFO:
  Handler called 4 times:
    OnAdd(rv100), OnUpdate(rv100, rv101), OnUpdate(rv101, rv102), OnDelete(rv102)

With DeltaFIFO:
  Events queued: [Added(rv100), Modified(rv101), Modified(rv102), Deleted]
  If processing is slow, queue compacts to: [Added(rv100), Deleted]
  Handler called: OnAdd(rv100), OnDelete(rv102)
  (Skipped intermediate updates since final result is deletion)
```

**Delta types**:
- **Added**: Object created
- **Modified**: Object updated (spec or status)
- **Deleted**: Object removed
- **Sync**: Resync event (object still exists, re-reconcile)

**Deduplication logic**:
- Multiple updates to same object → single entry with latest state
- Add followed by immediate delete → removed entirely (never existed)

### Cache Consistency Model

Informer caches are **eventually consistent**:

```
t=0: User runs: kubectl create pod my-pod
t=1: API server persists pod to etcd
t=2: API server sends WATCH event to reflector
t=3: Reflector adds pod to DeltaFIFO
t=4: Event handler processes add
t=5: Cache updated with pod

Controller reading cache at:
  t=0-4: Pod doesn't exist in cache (stale read)
  t=5+:  Pod exists in cache (fresh)
```

**Implications**:
- **Reads are from cache, not API server**: Fast but potentially stale
- **Staleness is typically <100ms**: WATCH latency is very low
- **Correctness via reconciliation**: Controllers must handle missing objects
- **No strong consistency guarantees**: Cache may lag reality

**Safe patterns**:
```go
// SAFE: Handle not found errors
pod, err := podLister.Pods("default").Get("my-pod")
if apierrors.IsNotFound(err) {
    // Pod was deleted or not yet cached; reconcile accordingly
}

// UNSAFE: Assume cache is perfectly synchronized
pod := podLister.Pods("default").Get("my-pod")
// Panics if pod was just created and cache not synced yet
```

## Common Failure Modes

### 1. Watch Connection Failures

**Symptom**: Informer cache becomes stale; controller misses updates

**Root causes**:
- Network partitions between controller and API server
- API server restarts
- etcd compaction (resourceVersion too old)
- Firewall drops long-lived TCP connections

**Detection**:
```bash
# Check for watch reconnections in controller logs
kubectl logs -n controller-system deployment/my-controller | grep "watch.*closed"

# Look for reflector errors
kubectl logs -n controller-system deployment/my-controller | grep "reflector.*error"
```

**Mitigation**:
- Reflector automatically re-LISTs and re-WATCHEs (no manual intervention needed)
- Use reasonable resync periods (10h) to recover from missed events
- Monitor `reflector_watch_duration_seconds` metric (short durations = frequent reconnects)

### 2. Cache Memory Pressure

**Symptom**: Controller OOMKilled; increasing memory usage over time

**Root causes**:
- Watching large resources (ConfigMaps with multi-MB data)
- Cluster with 10,000+ resources of watched type
- Informer factory never garbage collected (leak)
- Too many custom indexers storing duplicate data

**Example**: Watching all Pods in a 5,000-node cluster:
```
Average pod size: 10 KB
Total pods: 50,000
Memory for cache: 50,000 * 10 KB = 500 MB

With 3 custom indexers storing references: ~600 MB total
```

**Mitigation**:
```go
// Use namespace-scoped informers when possible
factory := informers.NewSharedInformerFactoryWithOptions(
    clientset,
    resyncPeriod,
    informers.WithNamespace("my-namespace"), // Only cache this namespace
)

// Use label selectors to reduce cache size
factory := informers.NewSharedInformerFactoryWithOptions(
    clientset,
    resyncPeriod,
    informers.WithTweakListOptions(func(opts *metav1.ListOptions) {
        opts.LabelSelector = "app=my-app" // Only cache matching pods
    }),
)

// Set memory limits and monitor usage
resources:
  limits:
    memory: 512Mi
  requests:
    memory: 256Mi
```

### 3. Resync Storms

**Symptom**: Sudden spike in reconciliations every N hours; API server load spike

**Root cause**: All informers resync simultaneously, triggering reconciliation of all resources

**Example timeline**:
```
t=0h:    All controllers start
t=10h:   All informers resync simultaneously
         - Controller 1: Reconciles 10,000 deployments
         - Controller 2: Reconciles 5,000 services
         - Controller 3: Reconciles 50,000 pods
         API server: 65,000 status updates in 10 seconds
```

**Mitigation**:
```go
// Stagger resync periods across controllers
controller1Factory := informers.NewSharedInformerFactory(clientset, 10*time.Hour)
controller2Factory := informers.NewSharedInformerFactory(clientset, 11*time.Hour)
controller3Factory := informers.NewSharedInformerFactory(clientset, 12*time.Hour)

// Or disable resync entirely if not needed
controller1Factory := informers.NewSharedInformerFactory(clientset, 0) // No resync
```

### 4. Stale Reads

**Symptom**: Controller acts on outdated information; reconciliation doesn't see recent changes

**Root cause**:
- Reading from cache immediately after startup (before sync)
- Watch connection failed but reflector hasn't reconnected yet
- Controller crashes during LIST, restarts with old cache

**Debug**:
```go
// Check if cache has synced before reading
if !cache.WaitForCacheSync(stopCh, informer.HasSynced) {
    log.Fatal("Failed to sync cache")
}

// In reconcile, always handle not found errors
obj, err := lister.Get(key)
if apierrors.IsNotFound(err) {
    // Object may have been deleted or not yet in cache
    return reconcile.Result{}, nil
}
```

**Safe pattern**:
```go
// ALWAYS wait for cache sync before starting controllers
if !cache.WaitForCacheSync(stopCh, podInformer.HasSynced, svcInformer.HasSynced) {
    return fmt.Errorf("failed to sync informer caches")
}

// Start controller workers AFTER caches synced
for i := 0; i < workers; i++ {
    go controller.runWorker()
}
```

## Interview Signals

When discussing informers in interviews, demonstrate:

1. **Deep understanding of the architecture**: Name reflector, DeltaFIFO, store components without prompting

2. **Performance awareness**: Explain how informers reduce API server load and when to use custom indexers

3. **Failure mode knowledge**: Discuss watch reconnections, memory pressure, resync storms

4. **Production patterns**: Reference SharedInformerFactory, cache sync checks, event filtering

5. **Real-world tradeoffs**: Explain resync period choices and when to use namespace/label filtering

## Common Interview Mistakes

- **Confusing cache reads with API server reads**: "Lister.Get() calls the API server" (NO, it reads cache)
- **Not understanding eventual consistency**: Assuming cache is always perfectly synchronized
- **Forgetting about cache sync**: Starting reconciliation before `HasSynced()` returns true
- **Not knowing when to use custom indexers**: Doing O(n) cache scans instead of O(1) lookups
- **Misunderstanding resync**: Thinking resync re-LISTs from API server (NO, it re-enqueues from cache)

## Real-World Examples

### controller-runtime Informer Integration

```go
import (
    "sigs.k8s.io/controller-runtime/pkg/cache"
    "sigs.k8s.io/controller-runtime/pkg/client"
)

// controller-runtime Manager includes SharedInformerFactory
func main() {
    mgr, err := ctrl.NewManager(cfg, ctrl.Options{
        Scheme: scheme,
        Cache: cache.Options{
            DefaultNamespaces: map[string]cache.Config{
                "my-namespace": {}, // Limit cache to specific namespaces
            },
        },
    })

    // Client automatically reads from cache
    pod := &corev1.Pod{}
    err := mgr.GetClient().Get(ctx, types.NamespacedName{
        Namespace: "default",
        Name:      "my-pod",
    }, pod)
    // This reads from informer cache, not API server
}
```

### Kubernetes Scheduler Pod Informer

The scheduler uses custom indexers to find pods efficiently:

```go
// Index pods by node name
podInformer.Informer().AddIndexers(cache.Indexers{
    "nodeName": func(obj interface{}) ([]string, error) {
        pod := obj.(*v1.Pod)
        return []string{pod.Spec.NodeName}, nil
    },
})

// Find all pods on a node (for bin-packing decisions)
podsOnNode, err := podInformer.GetIndexer().ByIndex("nodeName", "node-1")
```

### kube-controller-manager Resync Usage

Built-in controllers use long resync periods (10h+) to recover from missed events while minimizing load.

## Related Topics

- [01-build-a-controller-from-scratch](../01-build-a-controller-from-scratch/README.md) - Controllers that use informers
- [03-leader-election-and-ha-controllers](../03-leader-election-and-ha-controllers/README.md) - Running informers at scale
- [Week 01: API Server Architecture](../../week-01-k8s-api-and-control-plane/) - Understanding LIST/WATCH internals

## Additional Resources

- [client-go Informers Documentation](https://github.com/kubernetes/client-go/tree/master/informers)
- [A Deep Dive Into Kubernetes Controllers](https://engineering.bitnami.com/articles/a-deep-dive-into-kubernetes-controllers.html)
- [Understanding Kubernetes Informers](https://github.com/kubernetes/sample-controller/blob/master/docs/controller-client-go.md)
