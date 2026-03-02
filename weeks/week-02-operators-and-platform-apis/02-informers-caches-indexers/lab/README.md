# Lab: Informers, Caches & Indexers

## Objective

Build a custom controller using client-go informers to watch Pods and implement custom indexers for efficient lookups. Observe informer behavior including LIST+WATCH, cache sync, and resync periods.

## Prerequisites

- Kubernetes cluster (kind, minikube, or any cluster)
- Go 1.21+
- kubectl configured

## Part 1: Basic Informer Setup

Create a simple informer that watches Pods and logs events.

### Step 1: Initialize Go Module

```bash
mkdir informer-lab && cd informer-lab
go mod init informer-lab
go get k8s.io/client-go@v0.28.0
go get k8s.io/api@v0.28.0
go get k8s.io/apimachinery@v0.28.0
```

### Step 2: Create Basic Informer

Create `main.go`:

```go
package main

import (
    "context"
    "fmt"
    "os"
    "os/signal"
    "syscall"
    "time"

    corev1 "k8s.io/api/core/v1"
    "k8s.io/apimachinery/pkg/labels"
    "k8s.io/client-go/informers"
    "k8s.io/client-go/kubernetes"
    "k8s.io/client-go/tools/cache"
    "k8s.io/client-go/tools/clientcmd"
)

func main() {
    // Load kubeconfig
    config, err := clientcmd.BuildConfigFromFlags("", clientcmd.RecommendedHomeFile)
    if err != nil {
        panic(err)
    }

    clientset, err := kubernetes.NewForConfig(config)
    if err != nil {
        panic(err)
    }

    // Create SharedInformerFactory with 30-second resync (short for demo)
    informerFactory := informers.NewSharedInformerFactory(clientset, 30*time.Second)

    // Get Pod informer
    podInformer := informerFactory.Core().V1().Pods()

    // Add event handlers
    podInformer.Informer().AddEventHandler(cache.ResourceEventHandlerFuncs{
        AddFunc: func(obj interface{}) {
            pod := obj.(*corev1.Pod)
            fmt.Printf("[ADD] Pod: %s/%s - Phase: %s\n",
                pod.Namespace, pod.Name, pod.Status.Phase)
        },
        UpdateFunc: func(oldObj, newObj interface{}) {
            oldPod := oldObj.(*corev1.Pod)
            newPod := newObj.(*corev1.Pod)

            // Only log if generation changed (spec modified)
            if oldPod.Generation != newPod.Generation {
                fmt.Printf("[UPDATE-SPEC] Pod: %s/%s\n",
                    newPod.Namespace, newPod.Name)
            } else if oldPod.Status.Phase != newPod.Status.Phase {
                fmt.Printf("[UPDATE-STATUS] Pod: %s/%s - Phase: %s -> %s\n",
                    newPod.Namespace, newPod.Name,
                    oldPod.Status.Phase, newPod.Status.Phase)
            }
        },
        DeleteFunc: func(obj interface{}) {
            pod := obj.(*corev1.Pod)
            fmt.Printf("[DELETE] Pod: %s/%s\n", pod.Namespace, pod.Name)
        },
    })

    // Setup signal handling for graceful shutdown
    stopCh := make(chan struct{})
    sigCh := make(chan os.Signal, 1)
    signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
    go func() {
        <-sigCh
        fmt.Println("\nShutting down...")
        close(stopCh)
    }()

    // Start informers
    fmt.Println("Starting informers...")
    informerFactory.Start(stopCh)

    // Wait for cache to sync
    fmt.Println("Waiting for cache sync...")
    if !cache.WaitForCacheSync(stopCh, podInformer.Informer().HasSynced) {
        panic("Failed to sync cache")
    }
    fmt.Println("Cache synced! Watching for pod events...")

    // Demonstrate reading from cache
    pods, err := podInformer.Lister().Pods("default").List(labels.Everything())
    if err != nil {
        panic(err)
    }
    fmt.Printf("\nFound %d pods in 'default' namespace (from cache, not API server)\n\n", len(pods))

    // Block until shutdown signal
    <-stopCh
}
```

### Step 3: Run the Informer

```bash
# Terminal 1: Run the informer
go run main.go

# Terminal 2: Create some pods to trigger events
kubectl create ns informer-test
kubectl -n informer-test run nginx --image=nginx
kubectl -n informer-test run busybox --image=busybox --command -- sleep 3600

# Watch events in Terminal 1:
# [ADD] Pod: informer-test/nginx - Phase: Pending
# [UPDATE-STATUS] Pod: informer-test/nginx - Phase: Pending -> Running
# [ADD] Pod: informer-test/busybox - Phase: Pending
# [UPDATE-STATUS] Pod: informer-test/busybox - Phase: Pending -> Running

# Delete a pod
kubectl -n informer-test delete pod nginx

# Observe DELETE event in Terminal 1
```

**Observation**: Notice how the informer receives ADD, UPDATE, and DELETE events in real-time without polling.

## Part 2: Custom Indexers

Add custom indexers to enable efficient lookups.

### Step 4: Add Custom Index by Node Name

Modify `main.go` to add a custom indexer:

```go
package main

import (
    "context"
    "fmt"
    "os"
    "os/signal"
    "syscall"
    "time"

    corev1 "k8s.io/api/core/v1"
    metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
    "k8s.io/apimachinery/pkg/labels"
    "k8s.io/client-go/informers"
    "k8s.io/client-go/kubernetes"
    "k8s.io/client-go/tools/cache"
    "k8s.io/client-go/tools/clientcmd"
)

const (
    NodeNameIndex = "nodeName"
    OwnerIndex    = "owner"
)

func main() {
    config, err := clientcmd.BuildConfigFromFlags("", clientcmd.RecommendedHomeFile)
    if err != nil {
        panic(err)
    }
    clientset, err := kubernetes.NewForConfig(config)
    if err != nil {
        panic(err)
    }

    informerFactory := informers.NewSharedInformerFactory(clientset, 30*time.Second)
    podInformer := informerFactory.Core().V1().Pods()

    // Add custom indexers
    podInformer.Informer().AddIndexers(cache.Indexers{
        // Index pods by node name
        NodeNameIndex: func(obj interface{}) ([]string, error) {
            pod := obj.(*corev1.Pod)
            if pod.Spec.NodeName == "" {
                return nil, nil // Pod not scheduled yet
            }
            return []string{pod.Spec.NodeName}, nil
        },
        // Index pods by owner reference UID
        OwnerIndex: func(obj interface{}) ([]string, error) {
            pod := obj.(*corev1.Pod)
            owner := metav1.GetControllerOf(pod)
            if owner == nil {
                return nil, nil
            }
            return []string{string(owner.UID)}, nil
        },
    })

    stopCh := make(chan struct{})
    sigCh := make(chan os.Signal, 1)
    signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
    go func() {
        <-sigCh
        close(stopCh)
    }()

    informerFactory.Start(stopCh)

    if !cache.WaitForCacheSync(stopCh, podInformer.Informer().HasSynced) {
        panic("Failed to sync cache")
    }
    fmt.Println("Cache synced with custom indexers!")

    // Demonstrate custom index lookups
    time.Sleep(2 * time.Second) // Let some pods get scheduled

    // List all nodes
    nodes, err := clientset.CoreV1().Nodes().List(context.TODO(), metav1.ListOptions{})
    if err != nil {
        panic(err)
    }

    if len(nodes.Items) == 0 {
        fmt.Println("No nodes found")
        return
    }

    // Use custom indexer to find pods on first node (O(1) lookup)
    nodeName := nodes.Items[0].Name
    podsOnNode, err := podInformer.Informer().GetIndexer().ByIndex(NodeNameIndex, nodeName)
    if err != nil {
        panic(err)
    }

    fmt.Printf("\nPods on node %s (via custom indexer):\n", nodeName)
    for _, obj := range podsOnNode {
        pod := obj.(*corev1.Pod)
        fmt.Printf("  - %s/%s\n", pod.Namespace, pod.Name)
    }

    // Compare with O(n) list-and-filter approach
    start := time.Now()
    allPods, err := podInformer.Lister().List(labels.Everything())
    if err != nil {
        panic(err)
    }
    var filteredPods []*corev1.Pod
    for _, pod := range allPods {
        if pod.Spec.NodeName == nodeName {
            filteredPods = append(filteredPods, pod)
        }
    }
    listFilterTime := time.Since(start)

    start = time.Now()
    podsOnNode, _ = podInformer.Informer().GetIndexer().ByIndex(NodeNameIndex, nodeName)
    indexTime := time.Since(start)

    fmt.Printf("\nPerformance comparison:\n")
    fmt.Printf("  List+Filter: %v (%d pods scanned)\n", listFilterTime, len(allPods))
    fmt.Printf("  Custom Index: %v (direct lookup)\n", indexTime)
    fmt.Printf("  Speedup: %.2fx\n\n", float64(listFilterTime)/float64(indexTime))

    <-stopCh
}
```

### Step 5: Test Custom Indexers

```bash
# Run the indexer demo
go run main.go

# Create a deployment to see owner references
kubectl create deployment nginx --image=nginx --replicas=3

# The program will show:
# - Pods indexed by node name
# - Performance comparison between List+Filter vs Index lookup
# - Owner reference indexing (pods owned by ReplicaSet)
```

## Part 3: Observing Cache Behavior

### Step 6: Measure Cache Sync Time

Create `cache_test.go`:

```go
package main

import (
    "fmt"
    "time"

    "k8s.io/apimachinery/pkg/labels"
    "k8s.io/client-go/informers"
    "k8s.io/client-go/kubernetes"
    "k8s.io/client-go/tools/cache"
    "k8s.io/client-go/tools/clientcmd"
)

func main() {
    config, err := clientcmd.BuildConfigFromFlags("", clientcmd.RecommendedHomeFile)
    if err != nil {
        panic(err)
    }
    clientset, err := kubernetes.NewForConfig(config)
    if err != nil {
        panic(err)
    }

    informerFactory := informers.NewSharedInformerFactory(clientset, 0) // No resync
    podInformer := informerFactory.Core().V1().Pods()

    addCount := 0

    podInformer.Informer().AddEventHandler(cache.ResourceEventHandlerFuncs{
        AddFunc: func(obj interface{}) {
            addCount++
        },
    })

    stopCh := make(chan struct{})
    defer close(stopCh)

    // Measure time to sync
    fmt.Println("Starting cache sync...")
    start := time.Now()
    informerFactory.Start(stopCh)

    if !cache.WaitForCacheSync(stopCh, podInformer.Informer().HasSynced) {
        panic("Failed to sync")
    }
    duration := time.Since(start)

    allPods, _ := podInformer.Lister().List(labels.Everything())
    fmt.Printf("\nCache sync completed in %v\n", duration)
    fmt.Printf("Total pods cached: %d\n", len(allPods))
    fmt.Printf("ADD events triggered: %d\n", addCount)
    fmt.Printf("Average time per pod: %v\n", duration/time.Duration(len(allPods)))
}
```

Run the test:

```bash
# Create many pods first
kubectl create ns cache-test
for i in {1..100}; do
  kubectl -n cache-test run pod-$i --image=nginx
done

# Run cache test
go run cache_test.go

# Expected output:
# Cache sync completed in 234ms
# Total pods cached: 100
# ADD events triggered: 100
# Average time per pod: 2.34ms
```

## Part 4: Resync Behavior

### Step 7: Observe Resync Events

Create `resync_demo.go`:

```go
package main

import (
    "fmt"
    "time"

    corev1 "k8s.io/api/core/v1"
    "k8s.io/client-go/informers"
    "k8s.io/client-go/kubernetes"
    "k8s.io/client-go/tools/cache"
    "k8s.io/client-go/tools/clientcmd"
)

func main() {
    config, err := clientcmd.BuildConfigFromFlags("", clientcmd.RecommendedHomeFile)
    if err != nil {
        panic(err)
    }
    clientset, err := kubernetes.NewForConfig(config)
    if err != nil {
        panic(err)
    }

    // Create informer with 10-second resync (very short for demo)
    informerFactory := informers.NewSharedInformerFactory(clientset, 10*time.Second)
    podInformer := informerFactory.Core().V1().Pods()

    updateCount := 0
    lastResync := time.Now()

    podInformer.Informer().AddEventHandler(cache.ResourceEventHandlerFuncs{
        UpdateFunc: func(oldObj, newObj interface{}) {
            updateCount++
            oldPod := oldObj.(*corev1.Pod)
            newPod := newObj.(*corev1.Pod)

            // Resync events have identical old and new objects
            if oldPod.ResourceVersion == newPod.ResourceVersion {
                fmt.Printf("[RESYNC] Pod: %s/%s (UpdateCount: %d, Time since last resync: %v)\n",
                    newPod.Namespace, newPod.Name, updateCount, time.Since(lastResync))
                lastResync = time.Now()
            }
        },
    })

    stopCh := make(chan struct{})
    defer close(stopCh)

    informerFactory.Start(stopCh)
    cache.WaitForCacheSync(stopCh, podInformer.Informer().HasSynced)

    fmt.Println("Watching for resync events every 10 seconds...")
    fmt.Println("Press Ctrl+C to stop\n")

    time.Sleep(1 * time.Minute) // Run for 1 minute
}
```

Run and observe:

```bash
go run resync_demo.go

# You'll see resync events every 10 seconds for all cached pods:
# [RESYNC] Pod: default/nginx (UpdateCount: 1, Time since last resync: 10.002s)
# [RESYNC] Pod: default/busybox (UpdateCount: 2, Time since last resync: 12ms)
# ...
```

## Part 5: Watch Connection Resilience

### Step 8: Simulate Watch Failure

This demonstrates how the reflector handles watch connection failures.

```bash
# Terminal 1: Run the basic informer
go run main.go

# Terminal 2: Find the API server pod (if using kind/minikube)
kubectl -n kube-system get pods -l component=kube-apiserver

# Restart API server (simulates network partition)
kubectl -n kube-system delete pod <api-server-pod-name>

# Observe in Terminal 1:
# - WATCH connection closes
# - Reflector re-LISTs (you'll see a burst of events)
# - WATCH reconnects
# - Normal operation resumes

# Check logs for reflector messages:
# "reflector.go:xxx: watch of *v1.Pod ended with: too old resource version"
# "reflector.go:xxx: forcing resync"
```

## Key Takeaways

1. **LIST+WATCH Pattern**: Informers LIST once to seed cache, then WATCH for incremental updates
2. **SharedInformerFactory**: Prevents duplicate watches and caches across controllers
3. **Custom Indexers**: Enable O(1) lookups for common query patterns (by node, by owner, etc.)
4. **Resync Period**: Re-enqueues all cached items periodically for drift detection
5. **Eventually Consistent**: Cache may lag API server by <100ms; handle IsNotFound errors
6. **Resilient**: Reflector automatically handles watch failures with re-LIST+re-WATCH

## Cleanup

```bash
kubectl delete ns informer-test cache-test
rm -rf informer-lab/
```

## Interview Connection

When asked about informers in interviews, reference this lab:

- "I built a controller with custom indexers to find all pods on a node in O(1) time instead of scanning the entire cache"
- "I measured informer cache sync time and found it takes ~2ms per pod to populate the cache"
- "I experimented with resync periods and observed that resync doesn't re-LIST—it just re-triggers handlers from cache"
- "I simulated API server restarts and confirmed the reflector automatically re-LISTs and re-WATCHes with exponential backoff"
