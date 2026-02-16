# Leader Election & HA Controllers

## Overview

Leader election is critical for running highly available controllers in production. Multiple controller replicas can run simultaneously, but only one (the leader) actively reconciles resources. If the leader crashes, another replica automatically takes over. This ensures both high availability and prevents duplicate work or conflicting external side effects.

## What You Should Be Able to Do

After mastering this topic, you should be able to:

- Explain why leader election is necessary for controllers with external side effects
- Implement Lease-based leader election using client-go or controller-runtime
- Configure lease duration, renew deadline, and retry period appropriately
- Understand fencing tokens and split-brain prevention strategies
- Design controller sharding patterns for scaling beyond single-leader bottlenecks
- Debug stuck leases and leader flapping issues
- Compare lease-based election with etcd-based election
- Handle leader failover gracefully in production systems

## Mental Model

**Leader election prevents conflicting side effects, not duplicate reads**:
- **Idempotent reconciliation** handles reading the same resource multiple times
- **Leader election** prevents multiple controllers writing to external systems simultaneously
- **Split-brain** occurs when multiple leaders think they're active—must be prevented
- **Fencing tokens** ensure stale leaders can't corrupt state after losing leadership
- **Sharding** scales controllers horizontally by dividing resources among multiple leaders

Think of leader election like a single-key piano: multiple people can watch (read) the sheet music, but only one person should play (write) at a time. If that person faints, someone else quickly takes over playing, but you never want two people hitting keys simultaneously.

## Core Concepts

### Why Leader Election?

Controllers can be idempotent for reads—multiple replicas reading the same pod is harmless. But external side effects are NOT idempotent:

```
Scenario: Controller provisions cloud databases

Without leader election (2 replicas):
  Replica 1: Sees Database CRD "my-db"
  Replica 2: Sees Database CRD "my-db"

  Replica 1: Calls AWS RDS: CreateDatabase("my-db")
  Replica 2: Calls AWS RDS: CreateDatabase("my-db") <-- DUPLICATE!

  Result: Two AWS databases provisioned, or error conflict

With leader election:
  Replica 1: Elected leader, reconciles Database CRD
  Replica 2: Not leader, watches but doesn't reconcile

  Replica 1: Calls AWS RDS: CreateDatabase("my-db")

  Result: One database provisioned
```

**When you NEED leader election**:
- Provisioning external resources (cloud VMs, databases, DNS records)
- Mutating external systems (updating load balancers, firewalls)
- Side effects that can't be made idempotent (sending alerts, charging credit cards)
- Preventing wasted work on expensive operations

**When you DON'T NEED leader election**:
- Pure Kubernetes controllers (only mutating K8s resources)
- Controllers with perfect idempotency (e.g., ensuring a ConfigMap exists)
- Read-only controllers (exporters, dashboard aggregators)

### Lease-Based Leader Election

Kubernetes uses Lease objects (coordination.k8s.io/v1) for leader election:

```yaml
apiVersion: coordination.k8s.io/v1
kind: Lease
metadata:
  name: my-controller-leader
  namespace: controller-system
spec:
  holderIdentity: "replica-1-pod-xyz"  # Current leader's identity
  leaseDurationSeconds: 15              # Lease expires after 15s without renewal
  acquireTime: "2024-01-15T10:00:00Z"  # When current leader acquired lease
  renewTime: "2024-01-15T10:00:10Z"    # Last time leader renewed lease
  leaseTransitions: 3                   # How many times leadership changed
```

**How it works**:

```
┌─────────────────────────────────────────────────────────────┐
│  Controller Replica 1                                       │
│                                                             │
│  1. Try to acquire lease (UPDATE lease with my identity)   │
│  2. If acquire succeeds → I'm the leader                   │
│  3. Renew lease every 10s (before 15s expiration)         │
│  4. If renew fails → Lost leadership, stop reconciling    │
└─────────────────────────────────────────────────────────────┘
                              │
                              v
┌─────────────────────────────────────────────────────────────┐
│  API Server / etcd                                          │
│                                                             │
│  - Stores Lease object with current leader's identity      │
│  - Allows UPDATE only if lease expired or I'm current holder│
│  - Prevents split-brain via resourceVersion (optimistic lock)│
└─────────────────────────────────────────────────────────────┘
                              │
                              v
┌─────────────────────────────────────────────────────────────┐
│  Controller Replica 2                                       │
│                                                             │
│  1. Try to acquire lease (UPDATE fails - replica-1 owns it)│
│  2. Not leader, watch lease object for changes             │
│  3. If lease expires (renewTime + 15s < now) → try to acquire│
│  4. If acquire succeeds → I'm the new leader               │
└─────────────────────────────────────────────────────────────┘
```

### Leader Election Parameters

Three critical parameters control election behavior:

```go
import (
    "time"
    "k8s.io/client-go/tools/leaderelection"
    "k8s.io/client-go/tools/leaderelection/resourcelock"
)

config := leaderelection.LeaderElectionConfig{
    Lock: &resourcelock.LeaseLock{
        LeaseMeta: metav1.ObjectMeta{
            Name:      "my-controller",
            Namespace: "controller-system",
        },
        Client: clientset.CoordinationV1(),
        LockConfig: resourcelock.ResourceLockConfig{
            Identity: hostname, // Unique identity for this replica
        },
    },

    // Lease duration: how long leader holds lease without renewal
    LeaseDuration: 15 * time.Second,

    // Renew deadline: leader tries to renew within this time
    RenewDeadline: 10 * time.Second,

    // Retry period: how often non-leaders check if they can acquire
    RetryPeriod: 2 * time.Second,

    Callbacks: leaderelection.LeaderCallbacks{
        OnStartedLeading: func(ctx context.Context) {
            // Start controller reconciliation
        },
        OnStoppedLeading: func() {
            // Stop reconciliation, gracefully shut down
        },
        OnNewLeader: func(identity string) {
            // New leader elected (informational)
        },
    },
}
```

**Parameter tradeoffs**:

| Parameter | Shorter Value | Longer Value |
|-----------|---------------|--------------|
| LeaseDuration | Faster failover (5s) | Reduced API load (30s) |
| RenewDeadline | Faster leader failure detection (3s) | More tolerance for slow networks (20s) |
| RetryPeriod | Faster acquisition after expiry (1s) | Reduced API load (5s) |

**Production defaults** (controller-runtime):
- LeaseDuration: 15s
- RenewDeadline: 10s
- RetryPeriod: 2s

These balance failover speed (~15-20s) with API server load.

### client-go Leader Election

Basic client-go implementation:

```go
package main

import (
    "context"
    "fmt"
    "os"
    "time"

    metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
    "k8s.io/client-go/kubernetes"
    "k8s.io/client-go/tools/clientcmd"
    "k8s.io/client-go/tools/leaderelection"
    "k8s.io/client-go/tools/leaderelection/resourcelock"
)

func main() {
    config, _ := clientcmd.BuildConfigFromFlags("", clientcmd.RecommendedHomeFile)
    clientset, _ := kubernetes.NewForConfig(config)

    hostname, _ := os.Hostname()

    lock := &resourcelock.LeaseLock{
        LeaseMeta: metav1.ObjectMeta{
            Name:      "my-controller",
            Namespace: "default",
        },
        Client: clientset.CoordinationV1(),
        LockConfig: resourcelock.ResourceLockConfig{
            Identity: hostname,
        },
    }

    ctx, cancel := context.WithCancel(context.Background())
    defer cancel()

    leaderelection.RunOrDie(ctx, leaderelection.LeaderElectionConfig{
        Lock:            lock,
        LeaseDuration:   15 * time.Second,
        RenewDeadline:   10 * time.Second,
        RetryPeriod:     2 * time.Second,
        ReleaseOnCancel: true,
        Callbacks: leaderelection.LeaderCallbacks{
            OnStartedLeading: func(ctx context.Context) {
                fmt.Printf("%s: I am the leader!\n", hostname)
                runController(ctx) // Start actual controller work
            },
            OnStoppedLeading: func() {
                fmt.Printf("%s: Lost leadership, exiting\n", hostname)
                os.Exit(0) // Exit so orchestrator restarts us
            },
            OnNewLeader: func(identity string) {
                if identity == hostname {
                    return
                }
                fmt.Printf("%s: New leader elected: %s\n", hostname, identity)
            },
        },
    })
}

func runController(ctx context.Context) {
    // Run controller reconciliation loop
    ticker := time.NewTicker(5 * time.Second)
    defer ticker.Stop()

    for {
        select {
        case <-ctx.Done():
            return
        case <-ticker.C:
            fmt.Println("Reconciling resources...")
        }
    }
}
```

### controller-runtime Leader Election

controller-runtime integrates leader election into the Manager:

```go
package main

import (
    "os"
    "time"

    ctrl "sigs.k8s.io/controller-runtime"
    "sigs.k8s.io/controller-runtime/pkg/log/zap"
)

func main() {
    ctrl.SetLogger(zap.New())

    mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
        Scheme: scheme,

        // Enable leader election
        LeaderElection:          true,
        LeaderElectionID:        "my-controller.example.com",
        LeaderElectionNamespace: "controller-system",

        // Optional: customize lease parameters
        LeaseDuration: func() *time.Duration {
            d := 15 * time.Second
            return &d
        }(),
        RenewDeadline: func() *time.Duration {
            d := 10 * time.Second
            return &d
        }(),
        RetryPeriod: func() *time.Duration {
            d := 2 * time.Second
            return &d
        }(),
    })
    if err != nil {
        os.Exit(1)
    }

    // Add controllers to manager
    if err := (&MyReconciler{
        Client: mgr.GetClient(),
        Scheme: mgr.GetScheme(),
    }).SetupWithManager(mgr); err != nil {
        os.Exit(1)
    }

    // Start manager (handles leader election automatically)
    if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
        os.Exit(1)
    }
}
```

**What happens**:
1. Manager starts, attempts to acquire lease
2. If acquired, starts all controllers and informers
3. If not acquired, waits and retries
4. While leader, continuously renews lease
5. If lease renewal fails, stops controllers and exits

## Internals: How Lease-Based Election Works

### Optimistic Locking with ResourceVersion

Leases use Kubernetes' optimistic locking to prevent split-brain:

```
Timeline:
  t=0: Replica-1 is leader, lease.holderIdentity = "replica-1"

  t=10: Replica-1 renews lease:
    GET /apis/coordination.k8s.io/v1/leases/my-controller
      -> resourceVersion: "12345"
    lease.renewTime = now
    UPDATE lease with resourceVersion: "12345"
      -> Success, new resourceVersion: "12346"

  t=20: Network partition - Replica-1 can't reach API server

  t=35: Lease expired (15s since last renew)

  t=36: Replica-2 tries to acquire:
    GET /apis/coordination.k8s.io/v1/leases/my-controller
      -> renewTime is stale, lease is expired
    lease.holderIdentity = "replica-2"
    lease.acquireTime = now
    lease.renewTime = now
    UPDATE lease with resourceVersion: "12346"
      -> Success, Replica-2 is now leader

  t=40: Replica-1 network recovers, tries to renew:
    UPDATE lease with resourceVersion: "12346" (stale!)
      -> 409 Conflict (resourceVersion changed to "12347")
      -> Realizes it lost leadership, stops reconciling
```

**Key insight**: ResourceVersion acts as a fencing token. Stale leaders can't succeed in renewing because their resourceVersion is outdated.

### Lease Transition States

```
State 1: No leader (initial state)
  lease.holderIdentity = ""
  All replicas race to acquire
  First successful UPDATE wins

State 2: Leader active
  lease.holderIdentity = "replica-1"
  lease.renewTime updated every ~10s
  Other replicas watch but don't try to acquire

State 3: Leader failed (lease expired)
  lease.renewTime + 15s < now
  Lease is "expired" but holderIdentity still shows old leader
  First replica to UPDATE successfully becomes new leader

State 4: Graceful shutdown
  Leader calls lock.Release()
  Sets lease.holderIdentity = ""
  Other replicas immediately try to acquire
```

### Split-Brain Prevention

**Scenario: Network partition**:
```
Cluster partitioned into two segments:
  Segment A: Replica-1 (old leader) + some nodes
  Segment B: Replica-2 + API server/etcd

Segment A: Replica-1 thinks it's still leader
  Tries to renew lease → can't reach API server
  After RenewDeadline (10s), realizes renewal failed
  Stops reconciling and exits

Segment B: Replica-2 sees lease expired
  Acquires lease successfully
  Becomes new leader, starts reconciling

Result: Brief window (<10s) where no leader, then Replica-2 takes over
  No split-brain because Replica-1 stops before new leader starts
```

**Critical behavior**: Leaders MUST stop reconciling when renewal fails. This is why `OnStoppedLeading` should immediately exit or stop all work.

## Fencing Tokens and External Systems

Lease-based election prevents split-brain within Kubernetes, but external systems don't know about leases:

```
Problem:
  t=0:  Replica-1 is leader
  t=10: Replica-1 starts long-running operation (provision AWS database)
  t=15: Replica-1's lease expires (network issue)
  t=16: Replica-2 becomes leader
  t=17: Replica-2 starts provisioning the SAME AWS database
  t=20: Both API calls complete → DUPLICATE DATABASES

Solution: Fencing tokens
  - Include monotonically increasing token in external operations
  - External system rejects operations with stale tokens
```

### Fencing Token Pattern

```go
type Controller struct {
    leaseTransitions int32 // Increments on each new leader
}

func (c *Controller) OnStartedLeading(ctx context.Context) {
    atomic.AddInt32(&c.leaseTransitions, 1)
    c.runController(ctx)
}

func (c *Controller) reconcile(ctx context.Context, db *Database) error {
    fencingToken := atomic.LoadInt32(&c.leaseTransitions)

    // Include fencing token in external API call
    err := c.cloudProvider.CreateDatabase(db.Name, CloudOptions{
        FencingToken: fencingToken,
        // Cloud provider must track highest token seen per resource
        // Reject operations with lower tokens
    })

    if err == ErrStaleFencingToken {
        // We lost leadership during this operation; exit immediately
        os.Exit(1)
    }

    return err
}
```

**Real-world implementations**:
- AWS DynamoDB conditional writes (use resourceVersion as condition)
- Cloud provider tags (tag resources with "created-by-leader-generation: 5")
- Idempotency keys (use lease holderIdentity + leaseTransitions as key)

## Controller Sharding

When a single leader becomes a bottleneck (reconciling 100,000+ resources), shard the controller:

```
Single leader (bottleneck):
  Leader reconciles ALL 100,000 Databases
  Throughput limited by single process

Sharded leaders (scaled):
  Leader-1 reconciles Databases where hash(name) % 10 == 0 (10,000 DBs)
  Leader-2 reconciles Databases where hash(name) % 10 == 1 (10,000 DBs)
  ...
  Leader-10 reconciles Databases where hash(name) % 10 == 9 (10,000 DBs)

  Each leader has its own Lease object
```

### Implementing Sharding

```go
// Predicate filters resources based on shard
type ShardPredicate struct {
    ShardID    int
    ShardCount int
}

func (p ShardPredicate) Create(e event.CreateEvent) bool {
    return p.belongsToShard(e.Object.GetName())
}

func (p ShardPredicate) Update(e event.UpdateEvent) bool {
    return p.belongsToShard(e.ObjectNew.GetName())
}

func (p ShardPredicate) Delete(e event.DeleteEvent) bool {
    return p.belongsToShard(e.Object.GetName())
}

func (p ShardPredicate) belongsToShard(name string) bool {
    h := fnv.New32a()
    h.Write([]byte(name))
    shard := int(h.Sum32()) % p.ShardCount
    return shard == p.ShardID
}

// Setup sharded controller
func (r *DatabaseReconciler) SetupWithManager(mgr ctrl.Manager, shardID, shardCount int) error {
    return ctrl.NewControllerManagedBy(mgr).
        For(&v1alpha1.Database{}).
        WithEventFilter(ShardPredicate{
            ShardID:    shardID,
            ShardCount: shardCount,
        }).
        Complete(r)
}

// Deploy 5 shards with separate leader election per shard
// Deployment: my-controller-shard-0 (lease: my-controller-shard-0)
// Deployment: my-controller-shard-1 (lease: my-controller-shard-1)
// ...
```

**Sharding tradeoffs**:
- Increases throughput linearly with shard count
- More complex deployment (manage N deployments)
- Uneven load if hash distribution is skewed
- Resources can't be resharded without downtime (hash changes)

## Common Failure Modes

### 1. Leader Flapping

**Symptom**: Leadership changes every few seconds; constant disruption

**Root causes**:
- Network instability causing lease renewal failures
- API server overload (slow lease UPDATE responses)
- Leader process CPU throttled (can't renew in time)
- Too aggressive parameters (LeaseDuration=5s, RenewDeadline=3s)

**Debug**:
```bash
# Check lease transitions
kubectl get lease -n controller-system my-controller -o jsonpath='{.spec.leaseTransitions}'
# High number (>10) indicates flapping

# Check lease holder history
kubectl get lease -n controller-system my-controller -w
# Watch holderIdentity change frequently

# Check controller logs
kubectl logs -n controller-system deployment/my-controller | grep "stopped leading"
# Frequent "stopped leading" messages
```

**Mitigation**:
- Increase LeaseDuration to 30s (tolerate longer network issues)
- Increase RenewDeadline to 20s (more time to renew)
- Set CPU requests/limits to prevent throttling
- Monitor API server latency (p99 should be <100ms)

### 2. Stuck Lease (No Leader)

**Symptom**: Lease shows old holder that doesn't exist; no active leader

**Root causes**:
- Leader pod deleted without calling Release()
- Leader namespace deleted
- Lease object stuck in old namespace (namespace finalizer issue)

**Debug**:
```bash
# Check current lease holder
kubectl get lease -n controller-system my-controller -o yaml

# Check if holder pod exists
kubectl get pod -n controller-system <holderIdentity>

# Check renewTime
# If renewTime + leaseDurationSeconds < now, lease is expired but not acquired
```

**Mitigation**:
```bash
# Manual intervention: delete lease to force re-election
kubectl delete lease -n controller-system my-controller

# Prevention: Always set ReleaseOnCancel: true
# This releases lease on context cancellation/SIGTERM
```

### 3. Split-Brain External Writes

**Symptom**: Duplicate external resources provisioned; conflicting updates

**Root cause**: Leader lost lease but continued reconciling before stopping

**Debug**:
- Check cloud provider audit logs for duplicate API calls
- Compare API call timestamps with lease transition times
- Look for controller logs after "stopped leading" message

**Mitigation**:
- Implement fencing tokens in external operations
- Use idempotency keys for cloud provider APIs
- Add context cancellation checks in reconcile loop
- Monitor `OnStoppedLeading` to ensure immediate shutdown

## Interview Signals

When discussing leader election in interviews, demonstrate:

1. **Clear understanding of when it's needed**: External side effects, not just duplicate reads

2. **Knowledge of trade-offs**: Explain LeaseDuration vs failover time vs API load

3. **Production awareness**: Discuss stuck leases, leader flapping, fencing tokens

4. **Sharding knowledge**: Explain when single leader bottlenecks and how to shard

5. **Comparison with alternatives**: Discuss etcd-based election, external systems (Consul, ZooKeeper)

## Common Interview Mistakes

- **Thinking leader election prevents duplicate reads**: It prevents duplicate WRITES to external systems
- **Not understanding fencing tokens**: Lease election only works within K8s; external systems need tokens
- **Ignoring failover time**: Choosing parameters without considering "how long until new leader?"
- **Not discussing sharding**: Single leader limits scale; need sharding for 100k+ resources
- **Forgetting graceful shutdown**: Leaders must stop immediately when losing lease

## Real-World Examples

### kube-controller-manager Leader Election

```bash
# Built-in Kubernetes controllers use leader election
kubectl get lease -n kube-system | grep kube-controller-manager

# Only one replica actively runs controllers
# Others wait as hot standbys
```

### cert-manager Leader Election

```yaml
# cert-manager Deployment with leader election
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cert-manager
spec:
  replicas: 3
  template:
    spec:
      containers:
      - name: cert-manager
        args:
        - --leader-elect=true
        - --leader-election-namespace=cert-manager
        - --leader-election-lease-duration=60s
        - --leader-election-renew-deadline=40s
        - --leader-election-retry-period=15s
```

### Crossplane Provider Leader Election

Crossplane providers use leader election per provider to scale horizontally while preventing duplicate cloud resource provisioning.

## Comparing Election Strategies

| Strategy | Pros | Cons | Use Case |
|----------|------|------|----------|
| Lease-based | Native K8s, simple, built into controller-runtime | Requires API server | Default choice for K8s controllers |
| etcd-based | Low-level, fast | Requires direct etcd access (not recommended) | Legacy, rarely used now |
| Consul/ZK | External, multi-cluster | Additional infrastructure | Multi-cluster or non-K8s systems |
| Database-based | Persistent, external | Requires DB, slower | Controllers outside K8s |

**Recommendation**: Use Lease-based election unless you have specific requirements for external systems.

## Related Topics

- [01-build-a-controller-from-scratch](../01-build-a-controller-from-scratch/README.md) - Controllers that need leader election
- [02-informers-caches-indexers](../02-informers-caches-indexers/README.md) - Informers run in all replicas, not just leader
- [Week 01: API Server Architecture](../../week-01-k8s-api-and-control-plane/) - Understanding lease objects

## Additional Resources

- [client-go Leader Election](https://github.com/kubernetes/client-go/tree/master/tools/leaderelection)
- [controller-runtime Leader Election](https://pkg.go.dev/sigs.k8s.io/controller-runtime/pkg/manager#Options)
- [Kubernetes Coordination API](https://kubernetes.io/docs/reference/kubernetes-api/cluster-resources/lease-v1/)
- [Leader Election in Distributed Systems](https://martinfowler.com/articles/patterns-of-distributed-systems/leader-follower.html)
