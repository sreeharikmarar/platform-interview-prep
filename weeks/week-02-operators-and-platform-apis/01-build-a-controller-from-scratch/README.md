# Build a Controller from Scratch

## Overview

Building Kubernetes controllers is the foundation of platform engineering. Controllers enable declarative infrastructure management by continuously reconciling desired state (spec) with actual state (status). This topic covers the core patterns every controller must implement: spec/status contracts, finalizers for safe deletion, and idempotent reconciliation.

## What You Should Be Able to Do

After mastering this topic, you should be able to:

- Design clear spec/status contracts for custom resources
- Implement idempotent reconciliation loops that handle retries gracefully
- Use finalizers to ensure safe deletion and cleanup of external resources
- Track reconciliation state with status conditions and observedGeneration
- Handle common failure modes like dangling finalizers and reconciliation storms
- Explain controller patterns in technical interviews with production examples

## Mental Model

**A controller is a domain reconciler**:
- **Spec** represents the desired state (user intent)
- **Status** represents the observed reality (current state)
- **Reconcile loop** continuously drives reality toward intent
- **Finalizers** ensure safe deletion by blocking until cleanup completes
- **Idempotency** ensures reconciliation is safe to run repeatedly

Think of controllers as thermostats: they observe the temperature (status), compare it to the desired temperature (spec), and take actions (heat/cool) to reconcile the difference. Like a thermostat, controllers run continuously and handle external changes (someone opens a window).

## Core Concepts

### Spec/Status Split

The spec/status pattern is fundamental to Kubernetes API design:

```go
// Good: Clear separation of concerns
type DatabaseSpec struct {
    Engine      string `json:"engine"`      // User declares intent
    Version     string `json:"version"`
    InstanceType string `json:"instanceType"`
}

type DatabaseStatus struct {
    Phase      string      `json:"phase"`           // Controller reports reality
    Endpoint   string      `json:"endpoint"`
    Conditions []Condition `json:"conditions"`
    ObservedGeneration int64 `json:"observedGeneration"`
}
```

**Key principles**:
- **Spec is immutable after creation** (or requires validation on updates)
- **Only users modify spec**; controllers never write to spec
- **Only controllers modify status**; users read status
- **Status is disposable**; it can always be reconstructed by observing the world

### Conditions

Status conditions provide structured, actionable information about resource state:

```go
type Condition struct {
    Type               string      `json:"type"`               // e.g., "Ready", "Progressing"
    Status             string      `json:"status"`             // "True", "False", "Unknown"
    LastTransitionTime metav1.Time `json:"lastTransitionTime"` // When status last changed
    Reason             string      `json:"reason"`             // Machine-readable reason
    Message            string      `json:"message"`            // Human-readable details
}
```

**Standard condition types**:
- **Ready**: Resource is fully operational and serving traffic
- **Progressing**: Resource is being created/updated (transitional state)
- **Degraded**: Resource is operational but with reduced functionality
- **Available**: Resource has minimum required replicas ready

Example from a real production database controller:

```yaml
status:
  conditions:
  - type: Ready
    status: "False"
    lastTransitionTime: "2024-01-15T10:30:00Z"
    reason: BackupInProgress
    message: "Database is being backed up before upgrade"
  - type: Progressing
    status: "True"
    lastTransitionTime: "2024-01-15T10:25:00Z"
    reason: UpgradingVersion
    message: "Upgrading from 14.2 to 15.1"
```

### ObservedGeneration

ObservedGeneration tracks which version of the spec the controller has reconciled:

```go
// In your reconcile loop:
func (r *DatabaseReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    db := &v1alpha1.Database{}
    if err := r.Get(ctx, req.NamespacedName, db); err != nil {
        return ctrl.Result{}, client.IgnoreNotFound(err)
    }

    // Check if we've already reconciled this generation
    if db.Status.ObservedGeneration == db.Generation {
        // Spec hasn't changed; we may still need to reconcile external drift
    }

    // ... reconcile logic ...

    // Update status with current generation
    db.Status.ObservedGeneration = db.Generation
    if err := r.Status().Update(ctx, db); err != nil {
        return ctrl.Result{}, err
    }

    return ctrl.Result{}, nil
}
```

**Why this matters**:
- `metadata.generation` is incremented by API server whenever spec changes
- `status.observedGeneration` tells users if controller has processed the latest spec
- Mismatch indicates controller is behind (reconciliation lag)
- Critical for understanding whether changes have taken effect

### Finalizers

Finalizers block deletion until controllers complete cleanup:

```go
const databaseFinalizer = "database.example.com/finalizer"

func (r *DatabaseReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    db := &v1alpha1.Database{}
    if err := r.Get(ctx, req.NamespacedName, db); err != nil {
        return ctrl.Result{}, client.IgnoreNotFound(err)
    }

    // Handle deletion
    if !db.DeletionTimestamp.IsZero() {
        if controllerutil.ContainsFinalizer(db, databaseFinalizer) {
            // Perform cleanup of external resources
            if err := r.deleteExternalDatabase(ctx, db); err != nil {
                // Cleanup failed; requeue and try again
                return ctrl.Result{}, err
            }

            // Remove finalizer to allow deletion
            controllerutil.RemoveFinalizer(db, databaseFinalizer)
            if err := r.Update(ctx, db); err != nil {
                return ctrl.Result{}, err
            }
        }
        return ctrl.Result{}, nil
    }

    // Add finalizer if missing
    if !controllerutil.ContainsFinalizer(db, databaseFinalizer) {
        controllerutil.AddFinalizer(db, databaseFinalizer)
        if err := r.Update(ctx, db); err != nil {
            return ctrl.Result{}, err
        }
    }

    // Normal reconciliation...
    return ctrl.Result{}, nil
}
```

**Finalizer lifecycle**:
1. Controller adds finalizer when resource is created
2. User deletes resource (kubectl delete)
3. API server sets `deletionTimestamp` but doesn't delete yet
4. Controller sees `deletionTimestamp`, performs cleanup
5. Controller removes finalizer
6. API server completes deletion (removes from etcd)

**Critical gotchas**:
- **Dangling finalizers** are the #1 cause of "stuck" resources
- Always have a timeout/escape hatch for cleanup operations
- Consider idempotency: cleanup may run multiple times if controller crashes
- Use unique finalizer names to avoid conflicts with other controllers

### Idempotency

Controllers must be safe to run repeatedly on the same input:

```go
// BAD: Not idempotent - creates duplicate databases
func (r *DatabaseReconciler) reconcileDatabase(ctx context.Context, db *v1alpha1.Database) error {
    // Always creates a new database, even if one exists
    return r.CloudProvider.CreateDatabase(db.Spec.Name, db.Spec.Config)
}

// GOOD: Idempotent - check before creating
func (r *DatabaseReconciler) reconcileDatabase(ctx context.Context, db *v1alpha1.Database) error {
    existing, err := r.CloudProvider.GetDatabase(db.Spec.Name)
    if err != nil && !IsNotFound(err) {
        return err
    }

    if existing == nil {
        // Database doesn't exist; create it
        return r.CloudProvider.CreateDatabase(db.Spec.Name, db.Spec.Config)
    }

    // Database exists; check if update is needed
    if needsUpdate(existing, db.Spec) {
        return r.CloudProvider.UpdateDatabase(db.Spec.Name, db.Spec.Config)
    }

    return nil
}
```

**Idempotency strategies**:
- **Check before acting**: Read current state, compare to desired state
- **Create-or-update**: Use APIs that create if missing, update if exists
- **Immutable infrastructure**: Delete and recreate instead of in-place updates
- **Status tracking**: Record what actions completed to avoid retrying

### Controller Reconcile Loop

The reconcile function is called whenever:
- A watched resource changes (create, update, delete)
- A requeue is requested (manual or automatic)
- The resync period expires (typically 10 hours)

```go
func (r *DatabaseReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    log := log.FromContext(ctx)

    // 1. Fetch the resource
    db := &v1alpha1.Database{}
    if err := r.Get(ctx, req.NamespacedName, db); err != nil {
        if apierrors.IsNotFound(err) {
            // Resource deleted; nothing to do (finalizer already handled cleanup)
            return ctrl.Result{}, nil
        }
        return ctrl.Result{}, err
    }

    // 2. Handle deletion (finalizer logic)
    if !db.DeletionTimestamp.IsZero() {
        return r.reconcileDelete(ctx, db)
    }

    // 3. Add finalizer if missing
    if !controllerutil.ContainsFinalizer(db, databaseFinalizer) {
        controllerutil.AddFinalizer(db, databaseFinalizer)
        if err := r.Update(ctx, db); err != nil {
            return ctrl.Result{}, err
        }
    }

    // 4. Reconcile the actual resource
    result, err := r.reconcileNormal(ctx, db)
    if err != nil {
        // Update status to reflect error
        r.updateCondition(db, "Ready", "False", "ReconcileError", err.Error())
        if statusErr := r.Status().Update(ctx, db); statusErr != nil {
            log.Error(statusErr, "Failed to update status")
        }
        return result, err
    }

    // 5. Update status to reflect success
    db.Status.ObservedGeneration = db.Generation
    r.updateCondition(db, "Ready", "True", "ReconcileSuccess", "Database is ready")
    if err := r.Status().Update(ctx, db); err != nil {
        return ctrl.Result{}, err
    }

    return result, nil
}
```

**Return values**:
- `ctrl.Result{}, nil`: Reconciliation succeeded; don't requeue
- `ctrl.Result{Requeue: true}, nil`: Reconciliation succeeded but requeue immediately
- `ctrl.Result{RequeueAfter: 5*time.Minute}, nil`: Reconciliation succeeded; check again in 5 minutes
- `ctrl.Result{}, err`: Reconciliation failed; requeue with exponential backoff

## Internals: How Reconciliation Works

### The Request Flow

```
┌─────────────────────┐
│  User applies YAML  │
│  kubectl apply -f   │
└──────────┬──────────┘
           │
           v
┌─────────────────────┐
│  API Server         │
│  - Validates spec   │
│  - Writes to etcd   │
│  - Increments .gen  │
└──────────┬──────────┘
           │
           v
┌─────────────────────┐
│  Informer (Watch)   │
│  - Detects change   │
│  - Updates cache    │
│  - Triggers handler │
└──────────┬──────────┘
           │
           v
┌─────────────────────┐
│  Work Queue         │
│  - Deduplicates     │
│  - Rate limits      │
│  - Provides backoff │
└──────────┬──────────┘
           │
           v
┌─────────────────────┐
│  Reconcile()        │
│  - Reads from cache │
│  - Reconciles state │
│  - Updates status   │
└──────────┬──────────┘
           │
           v
┌─────────────────────┐
│  External System    │
│  (Cloud API, etc.)  │
└─────────────────────┘
```

### controller-runtime Architecture

```go
// SetupWithManager registers watches and configures the controller
func (r *DatabaseReconciler) SetupWithManager(mgr ctrl.Manager) error {
    return ctrl.NewControllerManagedBy(mgr).
        For(&v1alpha1.Database{}).                    // Primary resource to watch
        Owns(&corev1.Secret{}).                       // Watch Secrets owned by Database
        Watches(
            &corev1.ConfigMap{},                      // Watch ConfigMaps
            handler.EnqueueRequestsFromMapFunc(r.findDatabasesForConfigMap),
        ).
        WithOptions(controller.Options{
            MaxConcurrentReconciles: 2,                // Parallel reconcile workers
        }).
        Complete(r)
}
```

**Key components**:
- **Manager**: Coordinates all controllers, manages shared caches and clients
- **Controller**: Runs the reconcile loop with work queue and rate limiting
- **Client**: Provides read (from cache) and write (to API server) operations
- **Cache**: Local in-memory store of resources, updated via watch
- **Predicates**: Filter which events trigger reconciliation

### Create-or-Update Pattern

The create-or-update pattern is essential for idempotent reconciliation:

```go
import (
    "sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
)

func (r *DatabaseReconciler) reconcileSecret(ctx context.Context, db *v1alpha1.Database) error {
    secret := &corev1.Secret{
        ObjectMeta: metav1.ObjectMeta{
            Name:      db.Name + "-credentials",
            Namespace: db.Namespace,
        },
    }

    // CreateOrUpdate will create if missing, update if exists
    op, err := controllerutil.CreateOrUpdate(ctx, r.Client, secret, func() error {
        // Set desired state - this function is called whether creating or updating
        secret.Data = map[string][]byte{
            "username": []byte(db.Spec.Username),
            "password": []byte(r.generatePassword()),
        }

        // Set owner reference for garbage collection
        return controllerutil.SetControllerReference(db, secret, r.Scheme)
    })

    if err != nil {
        return err
    }

    log.Info("Reconciled secret", "operation", op) // op is "created", "updated", or "unchanged"
    return nil
}
```

## Common Failure Modes

### 1. Dangling Finalizers

**Symptom**: Resource stuck in "Terminating" state forever

**Root cause**:
- Controller crashed/deleted before removing finalizer
- Cleanup operation has unrecoverable error
- Finalizer typo (controller looks for wrong finalizer string)

**Debug**:
```bash
# Check if resource has deletion timestamp
kubectl get database my-db -o jsonpath='{.metadata.deletionTimestamp}'

# Check finalizers
kubectl get database my-db -o jsonpath='{.metadata.finalizers}'

# Check controller logs for cleanup errors
kubectl logs -n controller-system deployment/database-controller
```

**Mitigation**:
- Implement cleanup timeouts
- Provide manual override annotation (e.g., `force-delete: "true"`)
- Use finalizer only when external resources need cleanup
- Test deletion flow extensively

### 2. Status Spam

**Symptom**: Controller updates status on every reconcile, even when nothing changed

**Root cause**:
- Not comparing current vs desired status before updating
- Updating timestamps unnecessarily
- Not using DeepEqual for comparison

**Impact**:
- Increased API server load
- etcd write amplification
- Watch event storms to other controllers

**Fix**:
```go
// BAD: Always updates status
func (r *Reconciler) updateStatus(ctx context.Context, db *Database) error {
    db.Status.Phase = "Ready"
    db.Status.LastUpdated = metav1.Now() // This ALWAYS changes!
    return r.Status().Update(ctx, db)
}

// GOOD: Only update if status actually changed
func (r *Reconciler) updateStatus(ctx context.Context, db *Database, newPhase string) error {
    if db.Status.Phase == newPhase {
        return nil // No change needed
    }
    db.Status.Phase = newPhase
    return r.Status().Update(ctx, db)
}
```

### 3. Reconcile Storms

**Symptom**: Controller reconciles same resource hundreds of times per second

**Root cause**:
- Controller's own writes trigger new reconciliation
- Requeue without delay on retriable errors
- Watching resources without predicates (every change triggers reconcile)

**Debug**:
```bash
# Check reconcile rate
kubectl logs -n controller-system deployment/database-controller | \
  grep "Reconciling" | wc -l

# Check work queue depth (requires metrics)
kubectl port-forward -n controller-system svc/controller-metrics 8080:8080
curl localhost:8080/metrics | grep workqueue_depth
```

**Mitigation**:
```go
// Use predicates to filter events
func (r *DatabaseReconciler) SetupWithManager(mgr ctrl.Manager) error {
    return ctrl.NewControllerManagedBy(mgr).
        For(&v1alpha1.Database{}).
        WithEventFilter(predicate.Funcs{
            UpdateFunc: func(e event.UpdateEvent) bool {
                // Only reconcile if spec changed (not status-only updates)
                oldGen := e.ObjectOld.GetGeneration()
                newGen := e.ObjectNew.GetGeneration()
                return oldGen != newGen
            },
        }).
        Complete(r)
}

// Implement exponential backoff for errors
func (r *DatabaseReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    // ... reconcile logic ...

    if err != nil {
        // Requeue with backoff (controller-runtime handles this automatically)
        return ctrl.Result{}, err
    }

    // For expected transient conditions, use explicit requeue
    if db.Status.Phase == "Provisioning" {
        return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
    }

    return ctrl.Result{}, nil
}
```

## Interview Signals

When discussing controllers in interviews, demonstrate:

1. **Deep understanding of the reconcile pattern**: Explain how controllers continuously converge reality toward intent, not just "apply changes once"

2. **Production awareness**: Discuss finalizers, idempotency, and status conditions without prompting

3. **Failure mode knowledge**: Name specific issues like dangling finalizers, reconcile storms, status spam

4. **Design thinking**: Propose clear spec/status contracts before writing code

5. **Real-world examples**: Reference production operators (cert-manager, crossplane, etc.) that use these patterns

## Common Interview Mistakes

- **Treating controllers like imperative scripts**: "When user creates X, do Y" instead of "Continuously ensure X results in Y"
- **Forgetting idempotency**: Not handling retries or controller restarts
- **Ignoring status conditions**: Using simple string status instead of structured conditions
- **Skipping finalizers**: Not discussing how to safely delete resources with external dependencies
- **Not mentioning observedGeneration**: Missing key mechanism for tracking reconciliation lag

## Real-World Examples

### cert-manager Certificate Controller

```go
// cert-manager tracks certificate renewal with status conditions
type CertificateStatus struct {
    Conditions []Condition `json:"conditions,omitempty"`
    NotBefore  *metav1.Time `json:"notBefore,omitempty"`
    NotAfter   *metav1.Time `json:"notAfter,omitempty"`
    RenewalTime *metav1.Time `json:"renewalTime,omitempty"`
}

// Finalizer ensures private key Secret is cleaned up
const certificateFinalizer = "cert-manager.io/certificate-finalizer"
```

### external-dns Endpoint Controller

```go
// external-dns reconciles DNS records from Kubernetes resources
// Uses owner records to track which DNS entries it manages
// Implements careful idempotency to avoid DNS flapping
```

### crossplane Managed Resource Pattern

```go
// Crossplane uses consistent spec/status contract across all infrastructure
type ResourceSpec struct {
    ForProvider  ProviderConfig  // Provider-specific config
    WriteConnectionSecretToRef *SecretReference // Where to write credentials
    DeletionPolicy DeletionPolicy // What to do on delete
}

type ResourceStatus struct {
    Conditions []Condition
    AtProvider ProviderStatus // Provider-specific status
}
```

## Related Topics

- [02-informers-caches-indexers](../02-informers-caches-indexers/README.md) - How controllers efficiently watch resources
- [03-leader-election-and-ha-controllers](../03-leader-election-and-ha-controllers/README.md) - Running controllers at scale
- [Week 01: API Machinery](../../week-01-k8s-api-and-control-plane/) - Understanding the underlying Kubernetes API

## Additional Resources

- [Kubebuilder Book - Controller Concepts](https://book.kubebuilder.io/cronjob-tutorial/controller-overview.html)
- [controller-runtime Reconciler Interface](https://pkg.go.dev/sigs.k8s.io/controller-runtime/pkg/reconcile)
- [Kubernetes API Conventions - Status](https://github.com/kubernetes/community/blob/master/contributors/devel/sig-architecture/api-conventions.md#spec-and-status)
- [Sample Controller](https://github.com/kubernetes/sample-controller) - Reference implementation
