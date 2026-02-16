# GitOps Reconciliation vs Controller Reconciliation

## What you should be able to do

- Explain the difference between GitOps reconciliation (Git → API server) and controller reconciliation (API server → external world)
- Understand Server-Side Apply (SSA) and field manager ownership to prevent conflicts
- Describe drift detection, prevention, and resolution strategies
- Design proper ownership boundaries to avoid "drift wars" between GitOps and controllers
- Handle deletion ordering and cascading deletes safely

## Mental model

There are two distinct reconciliation loops in modern Kubernetes platforms:

1. **GitOps reconciliation (Git → API)**: Tools like ArgoCD and Flux continuously sync YAML manifests from Git into the API server. They ensure cluster state matches Git. This is *declarative configuration management*.

2. **Controller reconciliation (API → World)**: Controllers watch Kubernetes resources and reconcile external reality (cloud resources, databases, certificates) to match desired state in the API. This is *side effect materialization*.

These loops operate independently. GitOps owns the spec fields of resources, controllers own status fields. Conflicts arise when both touch the same fields. Server-Side Apply (SSA) provides field-level ownership to prevent overwrites, but you must design clear boundaries.

## Internals

### GitOps Reconciliation

GitOps tools like ArgoCD perform continuous drift detection:
1. Fetch manifests from Git repository
2. Render templates (Helm, Kustomize, etc.) into raw YAML
3. Apply to cluster using `kubectl apply --server-side` or client-side apply
4. Compare live state to desired state
5. Report drift and optionally auto-sync to fix it

ArgoCD's reconciliation loop runs every 3 minutes by default (configurable). It uses List+Watch on resources it manages, so it's notified immediately when cluster state changes. When drift is detected, ArgoCD can:
- Auto-sync: immediately apply Git state to fix drift
- Manual sync: require human approval
- Alert only: notify but don't fix

### Controller Reconciliation

Controllers use the standard Kubernetes reconciliation pattern:
1. Watch resources via informer
2. Enqueue changes to work queue
3. Reconcile function reads desired state from API
4. Compare to external reality (cloud APIs, databases, etc.)
5. Take action to converge external state to match desired state
6. Update resource status to reflect current reality

Controllers typically don't modify spec fields—they read spec and write status. But some controllers *do* modify spec, like:
- HorizontalPodAutoscaler modifies Deployment.spec.replicas
- Cluster autoscaler modifies node pool sizes
- Cert-manager may inject fields into Secret spec

This is where conflicts with GitOps arise.

### Server-Side Apply and Field Managers

SSA (introduced in Kubernetes 1.18, stable in 1.22) solves the "who owns which field" problem. Every apply operation declares a field manager name. The API server tracks which manager last set each field in `metadata.managedFields`.

Example after SSA apply:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
  managedFields:
  - manager: argocd-controller
    operation: Apply
    apiVersion: apps/v1
    time: "2024-01-15T10:00:00Z"
    fieldsType: FieldsV1
    fieldsV1:
      f:spec:
        f:replicas: {}
        f:template:
          f:spec:
            f:containers: {}
  - manager: horizontal-pod-autoscaler
    operation: Update
    apiVersion: apps/v1
    time: "2024-01-15T10:05:00Z"
    fieldsType: FieldsV1
    fieldsV1:
      f:spec:
        f:replicas: {}
  - manager: my-controller
    operation: Apply
    apiVersion: apps/v1
    time: "2024-01-15T10:10:00Z"
    fieldsType: FieldsV1
    fieldsV1:
      f:status:
        f:conditions: {}
```

In this example, both `argocd-controller` and `horizontal-pod-autoscaler` modified `spec.replicas`. The last writer (HPA) owns the field. If ArgoCD tries to set replicas again, it will conflict with HPA's ownership.

SSA handles conflicts in three ways:
1. **Shared ownership**: If managers set the same field to the same value, both own it
2. **Forced ownership**: Using `--force-conflicts` flag, a manager can steal ownership
3. **Conflict error**: By default, conflicting writes fail with an error

### Ownership Boundaries

Best practices for avoiding conflicts:

**1. GitOps owns spec, controllers own status:**

```yaml
# ArgoCD applies this
spec:
  replicas: 3
  template:
    spec:
      containers:
      - name: app
        image: myapp:v1

# Controller updates this
status:
  ready: true
  conditions:
  - type: Ready
    status: "True"
```

**2. Split resources by manager:**

For resources where both GitOps and controllers need to modify spec, split into separate resources. Example:

```yaml
# GitOps manages the Deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  replicas: 3  # Static from Git, no HPA

---
# HPA is NOT in Git, managed by a controller
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: my-app-hpa
spec:
  scaleTargetRef:
    name: my-app
  minReplicas: 3
  maxReplicas: 10
```

**3. Use annotations to coordinate:**

Controllers can read annotations set by GitOps to adjust behavior:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  annotations:
    autoscaling.example.com/enabled: "true"
    autoscaling.example.com/max: "20"
spec:
  replicas: 5  # Initial, HPA can override
```

The controller creates HPA only if annotation is present.

### Drift Detection vs Drift Prevention

**GitOps perspective (drift detection):** Git is the source of truth. Detect when cluster differs from Git and fix it by re-applying Git state. This works great for configuration but conflicts with controllers that legitimately modify resources.

**Controller perspective (drift prevention):** API server is the source of truth. Controllers continuously reconcile external state to match API state. If external state drifts (e.g., someone manually modifies a cloud resource), the controller detects and fixes it.

The key insight: GitOps detects drift *within the cluster* (cluster vs Git), controllers detect drift *outside the cluster* (external world vs cluster). They operate on different planes and should not conflict if boundaries are clear.

### Deletion Ordering and Finalizers

Both GitOps and controllers must handle deletion carefully. Kubernetes uses finalizers to block deletion until cleanup is complete.

Controller pattern for deletion:
1. Watch for deletionTimestamp being set
2. Perform cleanup (delete cloud resources, revoke certificates, etc.)
3. Remove finalizer
4. Object is deleted from etcd

GitOps pattern for deletion:
1. Manifest removed from Git
2. GitOps tool detects object no longer in desired state
3. GitOps deletes object from cluster
4. If object has finalizers, deletion blocks until controllers remove them
5. GitOps waits for deletion to complete

Problems arise when:
- Controller is slow to remove finalizer, GitOps sync hangs
- Circular dependencies: A has finalizer waiting for B, B waiting for A
- Finalizer controller is not running, object is stuck forever

ArgoCD has deletion waves and sync phases to control ordering:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-1"  # Delete first
```

Lower wave numbers delete first. This ensures dependents delete before dependencies.

## Failure modes & debugging

### Drift Wars

**Symptom:** GitOps and a controller repeatedly overwrite each other's changes. Resource oscillates between two states.

**Example:**
```
ArgoCD sets Deployment.spec.replicas = 3
HPA sets Deployment.spec.replicas = 5 (based on CPU)
ArgoCD detects drift, resets to 3
HPA resets to 5
... infinite loop
```

**Detection:** Watch for frequent update events on the same field. Check `metadata.managedFields` to see which managers are fighting.

**Fix:** Remove `replicas` field from Git, let HPA own it exclusively. Or disable autosync in ArgoCD for that resource.

### Partial Apply Failures

**Symptom:** GitOps applies a set of resources, some succeed, some fail. Cluster is in partial state.

**Example:**
```
Apply order: Namespace → ConfigMap → Deployment
ConfigMap apply fails (quota exceeded)
Deployment apply fails (ConfigMap doesn't exist)
Namespace exists, but app is broken
```

**Detection:** Check ArgoCD app health status. Look for resources in "OutOfSync" or "Degraded" state.

**Fix:** Use sync waves to enforce ordering. Use sync hooks for pre/post actions. Enable auto-sync with retry.

### Stale Status from Controllers

**Symptom:** GitOps shows resource as healthy, but controller status shows errors.

**Example:**
```yaml
spec:
  enabled: true
status:
  ready: false
  error: "Failed to provision LoadBalancer"
```

GitOps tools may only check spec fields for drift, ignoring status. The app appears healthy in ArgoCD but is actually broken.

**Detection:** Add health checks in ArgoCD that inspect status conditions:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
spec:
  ignoreDifferences:
  - group: apps
    kind: Deployment
    jsonPointers:
    - /spec/replicas  # Ignore HPA changes
```

**Fix:** Configure ArgoCD health checks to inspect controller status fields. Use readiness gates.

### Deletion Stuck on Finalizers

**Symptom:** GitOps deletes a resource from Git, but resource stuck in "Terminating" state forever.

**Example:**
```bash
$ kubectl get certificate my-cert
NAME      READY   SECRET         AGE
my-cert   True    my-cert-tls    Terminating
```

Object has `metadata.deletionTimestamp` set but finalizer is not removed.

**Detection:** Check finalizers:

```bash
kubectl get certificate my-cert -o jsonpath='{.metadata.finalizers}'
```

**Fix:**
- Ensure finalizer controller is running
- Manually remove finalizer if controller is gone: `kubectl patch certificate my-cert --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]'`
- Add timeout annotations to ArgoCD to fail sync if deletion takes too long

### Field Manager Conflicts

**Symptom:** `kubectl apply` fails with "field managed by different manager" error.

**Example:**
```
error: Apply failed with 1 conflict: conflict with "my-controller": .spec.replicas
```

**Detection:** Inspect `metadata.managedFields` to see which manager owns the conflicting field.

**Fix:**
- Use `kubectl apply --force-conflicts` to steal ownership (dangerous, use carefully)
- Remove the field from YAML, let controller own it
- Use `kubectl apply --field-manager=<name>` to explicitly set manager name

## Interview Signals

**Strong candidates will:**
- Clearly distinguish GitOps (Git→API) from controllers (API→World)
- Explain SSA field ownership and managedFields
- Describe drift wars and how to avoid them with ownership boundaries
- Discuss deletion ordering with finalizers and sync waves
- Relate to real-world multi-manager scenarios (HPA + GitOps, etc.)

**Red flags:**
- Confusing GitOps with controllers or thinking they're the same
- Not understanding SSA or field managers
- Missing the spec vs status ownership pattern
- No strategy for handling deletion dependencies
- Thinking GitOps should own all fields

## Common Pitfalls

1. **GitOps managing HPA-scaled Deployments**: Leads to drift wars on `spec.replicas`
2. **Controllers modifying spec without SSA**: Causes field manager conflicts
3. **No deletion ordering**: Dependencies deleted before dependents, causing errors
4. **Ignoring status fields**: GitOps shows healthy but controllers report errors
5. **Forced SSA without understanding**: Steals ownership, breaks controllers
6. **Mixing client-side and server-side apply**: Inconsistent field ownership

## Key Takeaways

- GitOps reconciles Git → API server; controllers reconcile API → external world
- These are complementary loops, not competing ones
- Server-Side Apply (SSA) provides field-level ownership to prevent conflicts
- Best practice: GitOps owns spec, controllers own status; split when both need spec
- Use sync waves and finalizers to control deletion ordering
- Drift wars happen when managers fight over the same field—fix by clarifying ownership
- Monitor `metadata.managedFields` to debug field manager conflicts
