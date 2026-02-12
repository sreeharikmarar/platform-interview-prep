# Lab: Controllers, Reconciliation & Work Queues

This lab demonstrates controller patterns: watching resources, maintaining a cache, reconciling parent-child relationships, owner references, and garbage collection.

## Prerequisites

- Running Kubernetes cluster
- kubectl 1.22+
- Basic understanding of ConfigMaps and Jobs

## Step-by-Step Instructions

### 1. Create a parent ConfigMap

```bash
kubectl apply -f lab/parent-cm.yaml
```

**What's happening**: We create a ConfigMap that will act as the "parent" resource. A controller will watch for this and create a "child" ConfigMap based on the parent's data.

**Verification**:
```bash
kubectl get cm parent -o yaml
```

Expected: ConfigMap with some data fields (e.g., `template: "Hello from parent"`).

---

### 2. Inspect the parent's initial state

```bash
# Check the data
kubectl get cm parent -o jsonpath='{.data}'

# Note the resourceVersion and UID (used for owner reference)
kubectl get cm parent -o jsonpath='{.metadata.resourceVersion} {.metadata.uid}'
```

**Observe**: Parent has data but no status (ConfigMaps don't have status subresource by default).

---

### 3. Run the reconciler Job

```bash
kubectl apply -f lab/reconciler-job.yaml
```

**What's happening**: The Job creates a pod that runs a simple controller script. This controller:
1. Watches for the parent ConfigMap
2. When detected, computes the desired child ConfigMap spec
3. Checks if child exists
4. If not, creates it with an owner reference to the parent
5. If yes, checks if it matches desired state and updates if needed

**Note**: In production, controllers run as Deployments with continuous reconciliation. For this lab, a Job demonstrates the pattern in a simpler form.

**Verification**:
```bash
# Check Job status
kubectl get job cm-reconciler

# Wait for it to complete
kubectl wait --for=condition=complete --timeout=60s job/cm-reconciler
```

---

### 4. Watch the reconciler logs

```bash
kubectl logs job/cm-reconciler
```

**What's happening**: The logs show the controller's logic:
- "Starting reconciler..."
- "Found parent ConfigMap: parent"
- "Computing desired child state..."
- "Child ConfigMap does not exist, creating..."
- "Child ConfigMap created successfully"
- "Reconciliation complete"

**Observe**: The controller reads state, computes desired state, compares with actual, and applies the diff.

---

### 5. Verify the child ConfigMap was created

```bash
kubectl get cm child -o yaml
```

**What's happening**: The controller created a child ConfigMap with:
- Data derived from the parent (e.g., transforming template)
- Owner reference pointing to the parent
- Labels indicating it was created by the controller

**Observe**:
```yaml
metadata:
  ownerReferences:
  - apiVersion: v1
    kind: ConfigMap
    name: parent
    uid: <parent-uid>
    controller: true
    blockOwnerDeletion: true
data:
  derived: "Processed: Hello from parent"
```

---

### 6. Inspect the owner reference

```bash
kubectl get cm child -o jsonpath='{.metadata.ownerReferences}'
```

**What's happening**: The owner reference establishes the parent-child relationship. When the parent is deleted, Kubernetes' garbage collector automatically deletes the child.

**Expected output**:
```json
[{"apiVersion":"v1","kind":"ConfigMap","name":"parent","uid":"...","controller":true,"blockOwnerDeletion":true}]
```

- `controller: true` means this owner is responsible for reconciling the child
- `blockOwnerDeletion: true` prevents parent deletion until child is deleted (optional)

---

### 7. Demonstrate reconciliation idempotency

```bash
# Re-run the reconciler
kubectl delete job cm-reconciler
kubectl apply -f lab/reconciler-job.yaml

# Check logs
kubectl logs job/cm-reconciler
```

**What's happening**: The controller runs again. This time, it finds the child already exists and matches desired state, so it does nothing.

**Expected logs**:
```
Starting reconciler...
Found parent ConfigMap: parent
Computing desired child state...
Child ConfigMap exists and matches desired state, no action needed
Reconciliation complete
```

**Observe**: Idempotency - running reconcile multiple times with the same input produces the same result without unnecessary updates.

---

### 8. Demonstrate reconciliation convergence (update parent)

```bash
# Update parent data
kubectl patch cm parent --type=merge -p '{"data":{"template":"Updated value"}}'

# Re-run reconciler
kubectl delete job cm-reconciler
kubectl apply -f lab/reconciler-job.yaml

# Check logs
kubectl logs job/cm-reconciler
```

**What's happening**: Parent data changed, so desired child state is different. The controller detects drift and updates the child.

**Expected logs**:
```
Child ConfigMap exists but differs from desired state
Updating child ConfigMap...
Child ConfigMap updated successfully
```

**Verify child was updated**:
```bash
kubectl get cm child -o jsonpath='{.data.derived}'
```

Expected: `"Processed: Updated value"`

---

### 9. Demonstrate garbage collection (delete parent)

```bash
# Delete the parent
kubectl delete cm parent

# Wait a moment for garbage collection
sleep 3

# Check if child still exists
kubectl get cm child
```

**What's happening**: When the parent is deleted, Kubernetes' garbage collector controller sees the child has an owner reference to the now-deleted parent. Since `blockOwnerDeletion: false` or the parent was force-deleted, the garbage collector deletes the child automatically.

**Expected output**:
```
Error from server (NotFound): configmaps "child" not found
```

**Observe**: Cascading deletion via owner references. The controller doesn't need special cleanup logic - Kubernetes handles it.

---

### 10. Additional exploration - owner reference options

```bash
# Recreate parent and child
kubectl apply -f lab/parent-cm.yaml
kubectl apply -f lab/reconciler-job.yaml

# Try to delete parent (will be blocked if blockOwnerDeletion: true)
kubectl delete cm parent
```

If `blockOwnerDeletion: true`, you'll get:
```
Error: cannot delete ConfigMap "parent" because it has dependents
```

To force delete:
```bash
kubectl delete cm parent --cascade=orphan
```

This deletes the parent but leaves the child orphaned (owner reference points to non-existent parent).

---

### 11. Simulate work queue behavior (conceptual)

In a real controller, events would be queued. Simulate rapid updates:

```bash
# Rapid fire updates to parent
for i in {1..5}; do
  kubectl patch cm parent --type=merge -p "{\"data\":{\"count\":\"$i\"}}"
  sleep 0.5
done

# In a real controller with work queue:
# - Each update triggers a watch event
# - Event handler enqueues the key "default/parent"
# - Queue deduplicates - only one entry exists
# - Worker picks it up once and reconciles to the final state (count=5)
# - Result: 5 events collapsed into 1 reconcile
```

---

## Cleanup

```bash
kubectl delete cm parent
kubectl delete job cm-reconciler
# Child will be auto-deleted via garbage collection
```

---

## Key Takeaways

1. **Controllers reconcile state**: They continuously compare desired vs actual and apply the diff
2. **Level-triggered**: Reconcile is based on current state snapshot, not event history
3. **Idempotency**: Running reconcile multiple times with same input is safe
4. **Owner references**: Establish parent-child relationships for automatic garbage collection
5. **Work queues**: Decouple event handling from reconciliation (batching, rate limiting, deduplication)
6. **Cache**: Controllers read from local cache (Informer), not the API server, for performance
7. **Eventual consistency**: Changes propagate asynchronously; controllers converge over time

## Extension Ideas

To build a real controller (not just a Job):

1. Use **controller-runtime** or **client-go** to set up Informers and work queues
2. Run as a **Deployment** with continuous reconciliation
3. Add **status subresource** to parent to track `observedGeneration` and conditions
4. Implement **predicates** to filter status-only updates
5. Add **metrics** (workqueue depth, reconcile duration)
6. Handle **finalizers** for custom cleanup logic before deletion
7. Use **SSA** with a fieldManager to safely update child resources
