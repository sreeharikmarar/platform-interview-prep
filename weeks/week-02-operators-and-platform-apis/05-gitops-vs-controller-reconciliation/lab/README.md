# Lab: GitOps vs Controller Reconciliation Conflicts

## Objective

Demonstrate ownership conflicts between GitOps (simulated with kubectl apply) and a controller, observe drift wars, explore Server-Side Apply field managers, and practice resolving conflicts with proper ownership boundaries.

## Prerequisites

- Kubernetes cluster (kind, minikube, or cloud)
- kubectl configured
- jq installed (for JSON parsing)

## Step 1: Create a Simple Deployment via Client-Side Apply

We'll simulate GitOps using `kubectl apply` (client-side apply by default).

**deployment.yaml:**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: drift-demo
  namespace: default
spec:
  replicas: 3
  selector:
    matchLabels:
      app: drift-demo
  template:
    metadata:
      labels:
        app: drift-demo
    spec:
      containers:
      - name: nginx
        image: nginx:1.25
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
```

Apply it:

```bash
kubectl apply -f deployment.yaml
```

Inspect the managedFields to see who owns fields:

```bash
kubectl get deployment drift-demo -o yaml | grep -A 30 managedFields
```

You should see a manager called `kubectl-client-side-apply` owning most fields, with a large `last-applied-configuration` annotation.

## Step 2: Simulate a Controller Modifying the Deployment

Simulate a controller (like HPA) modifying `spec.replicas` using `kubectl patch`:

```bash
kubectl patch deployment drift-demo --type=merge -p '{"spec":{"replicas":5}}'
```

Check managedFields again:

```bash
kubectl get deployment drift-demo -o jsonpath='{.metadata.managedFields}' | jq '.[] | select(.manager | contains("kubectl"))'
```

You'll see `kubectl-patch` now owns `spec.replicas`. The client-side apply manager no longer owns this field.

## Step 3: Simulate GitOps Re-Applying (Drift War)

Re-apply the original deployment.yaml (which has replicas: 3):

```bash
kubectl apply -f deployment.yaml
```

Check the replicas:

```bash
kubectl get deployment drift-demo -o jsonpath='{.spec.replicas}'
```

It's back to 3. The client-side apply silently overwrote the controller's change. This is a drift war—if the controller patches it back to 5, and you apply again, they fight forever.

## Step 4: Switch to Server-Side Apply

Now use Server-Side Apply (SSA) to prevent silent overwrites.

```bash
kubectl apply --server-side --field-manager=gitops-manager -f deployment.yaml
```

Check managedFields:

```bash
kubectl get deployment drift-demo -o jsonpath='{.metadata.managedFields}' | jq '.[] | select(.manager == "gitops-manager")'
```

You should see `gitops-manager` owns most fields. SSA relies on `managedFields` instead of the `last-applied-configuration` annotation. However, kubectl may still maintain the annotation for backward compatibility when using the default field manager.

## Step 5: Simulate Controller Update with SSA Conflict

Patch replicas again, simulating a controller:

```bash
kubectl patch deployment drift-demo --type=merge -p '{"spec":{"replicas":7}}' --field-manager=hpa-controller
```

Check who owns replicas now:

```bash
kubectl get deployment drift-demo -o jsonpath='{.metadata.managedFields}' | jq '.[] | select(.fieldsV1 | has("f:spec")) | select(.fieldsV1["f:spec"] | has("f:replicas"))'
```

You should see `hpa-controller` owns `spec.replicas`.

Now try to re-apply with SSA:

```bash
kubectl apply --server-side --field-manager=gitops-manager -f deployment.yaml
```

This should **fail** with an error like:

```
Apply failed with 1 conflict: conflict with "hpa-controller": .spec.replicas
```

SSA detected the conflict and blocked the apply. This prevents the drift war.

## Step 6: Resolve Conflict with Force

You can force GitOps to steal ownership:

```bash
kubectl apply --server-side --field-manager=gitops-manager --force-conflicts -f deployment.yaml
```

Now GitOps owns replicas again. Check:

```bash
kubectl get deployment drift-demo -o jsonpath='{.spec.replicas}'
# Should be 3

kubectl get deployment drift-demo -o jsonpath='{.metadata.managedFields}' | jq '.[] | select(.manager == "gitops-manager") | .fieldsV1'
```

`gitops-manager` now owns `spec.replicas`. But this is dangerous—you've broken the controller's ability to manage replicas.

## Step 7: Proper Resolution - Remove Replicas from GitOps

The correct fix is to remove `spec.replicas` from the GitOps-managed YAML, letting the controller own it exclusively.

**deployment-no-replicas.yaml:**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: drift-demo
  namespace: default
spec:
  # replicas field removed
  selector:
    matchLabels:
      app: drift-demo
  template:
    metadata:
      labels:
        app: drift-demo
    spec:
      containers:
      - name: nginx
        image: nginx:1.25
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
```

Apply with SSA:

```bash
kubectl apply --server-side --field-manager=gitops-manager -f deployment-no-replicas.yaml
```

Now GitOps doesn't touch replicas. The controller can modify it freely without conflicts.

Simulate the controller setting replicas:

```bash
kubectl patch deployment drift-demo --type=merge -p '{"spec":{"replicas":10}}' --field-manager=hpa-controller
```

Re-apply GitOps:

```bash
kubectl apply --server-side --field-manager=gitops-manager -f deployment-no-replicas.yaml
```

No conflict! Replicas stays at 10. GitOps and controller coexist peacefully.

## Step 8: Inspect Field Ownership

View the complete field ownership tree:

```bash
kubectl get deployment drift-demo -o json | jq '.metadata.managedFields[] | {manager: .manager, fields: .fieldsV1}'
```

You should see:
- `gitops-manager` owns `spec.selector`, `spec.template`, etc.
- `hpa-controller` owns `spec.replicas`
- `kube-controller-manager` or `deployment-controller` owns `status`

This is the proper ownership boundary: GitOps owns most of spec, controller owns replicas, Kubernetes controllers own status.

## Step 9: Test Status Updates Don't Conflict

Controllers always update status, not spec (for well-behaved controllers). Verify GitOps doesn't touch status:

```bash
kubectl apply --server-side --field-manager=gitops-manager -f deployment-no-replicas.yaml
```

Check status ownership:

```bash
kubectl get deployment drift-demo -o jsonpath='{.metadata.managedFields}' | jq '.[] | select(.fieldsV1 | has("f:status"))'
```

You should see a Kubernetes controller (e.g., `kube-controller-manager`) owns status, not GitOps. They don't conflict.

## Step 10: Simulate Deletion with Finalizers

Add a finalizer to the Deployment to simulate a controller blocking deletion:

```bash
kubectl patch deployment drift-demo --type=json -p='[{"op":"add","path":"/metadata/finalizers","value":["example.com/block-deletion"]}]'
```

Try to delete:

```bash
kubectl delete deployment drift-demo
```

Check status:

```bash
kubectl get deployment drift-demo
```

It's stuck in `Terminating` state because the finalizer blocks deletion.

Simulate the controller finishing cleanup and removing the finalizer:

```bash
kubectl patch deployment drift-demo --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'
```

Now the Deployment is fully deleted.

## Step 11: Field Manager Conflict Example

Create a Deployment where two managers try to own the same field.

**deployment-conflict.yaml:**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: conflict-demo
  namespace: default
spec:
  replicas: 5
  selector:
    matchLabels:
      app: conflict-demo
  template:
    metadata:
      labels:
        app: conflict-demo
    spec:
      containers:
      - name: nginx
        image: nginx:1.25
```

Apply with manager A:

```bash
kubectl apply --server-side --field-manager=manager-a -f deployment-conflict.yaml
```

Now modify the file to replicas: 10 and apply with manager B:

```bash
sed 's/replicas: 5/replicas: 10/' deployment-conflict.yaml | kubectl apply --server-side --field-manager=manager-b -f -
```

This should fail with a conflict error. Both managers are trying to own `spec.replicas` with different values.

Inspect the conflict:

```bash
kubectl get deployment conflict-demo -o jsonpath='{.metadata.managedFields}' | jq '.[] | select(.manager | startswith("manager"))'
```

You'll see `manager-a` owns replicas: 5. `manager-b` tried to set it to 10 but was blocked.

Force manager B to take ownership:

```bash
sed 's/replicas: 5/replicas: 10/' deployment-conflict.yaml | kubectl apply --server-side --field-manager=manager-b --force-conflicts -f -
```

Now manager B owns the field:

```bash
kubectl get deployment conflict-demo -o jsonpath='{.spec.replicas}'
# Should be 10
```

## Clean Up

```bash
kubectl delete deployment drift-demo conflict-demo
```

## Key Takeaways

- **Client-side apply** silently overwrites fields, causing drift wars between GitOps and controllers
- **Server-Side Apply (SSA)** tracks field ownership in `metadata.managedFields` and fails on conflicts
- Proper ownership boundaries: GitOps owns spec (except fields controllers need), controllers own status and specific spec fields
- Use `--field-manager` to identify which manager owns which fields
- Use `--force-conflicts` carefully to steal ownership when necessary
- Remove fields from GitOps manifests if controllers need exclusive ownership
- Finalizers block deletion until controllers finish cleanup, which can cause resources to stuck in Terminating
- Always inspect `managedFields` when debugging field conflicts
