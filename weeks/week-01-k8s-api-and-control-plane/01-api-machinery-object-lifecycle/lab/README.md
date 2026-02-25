# Lab: API Machinery & Object Lifecycle

This lab demonstrates Kubernetes API fundamentals: resourceVersion, generation, optimistic locking, watch streams, and the distinction between spec and status.

## Prerequisites

- kind installed
- kubectl 1.28+
- Basic understanding of CRDs

## Step-by-Step Instructions

### 1. Start the cluster

```bash
./scripts/kind-up.sh prep
```

**Observe**: kind creates a local Kubernetes cluster with etcd, API server, and controllers running as containers.

**Verification**:
```bash
kubectl cluster-info
kubectl get nodes
```

You should see one control-plane node in Ready state.

---

### 2. Create the Custom Resource Definition

```bash
kubectl apply -f lab/crd.yaml
```

**What's happening**: The API server validates the CRD schema, persists it to etcd at `/registry/apiextensions.k8s.io/customresourcedefinitions/widgets.demo.io`, and the APIExtensions controller starts serving the new `/apis/demo.io/v1/widgets` endpoint.

**Observe**: The CRD defines the schema for Widget resources.

**Verification**:
```bash
# Check that the CRD is established (ready to accept Widget instances)
kubectl get crd widgets.demo.io -o jsonpath='{.status.conditions[?(@.type=="Established")].status}'
# Should output: True

# See the API group and version
kubectl api-resources | grep widget
# Should show: widgets, demo.io/v1

# Inspect the full schema
kubectl get crd widgets.demo.io -o yaml | less
```

---

### 3. Create a Widget instance

```bash
kubectl apply -f lab/widget.yaml
```

**What's happening**:
1. API server receives the request, authenticates/authorizes
2. Validates the Widget against the CRD's OpenAPI schema
3. Runs admission webhooks (none configured for this resource)
4. Persists to etcd at `/registry/demo.io/widgets/default/demo`
5. Assigns metadata.uid (unique identifier), resourceVersion (etcd revision), and generation (starts at 1)
6. Watch cache notifies any controllers watching widgets

**Observe**: The newly created object has metadata populated by the API server.

**Verification**:
```bash
# Check that the widget exists
kubectl get widgets
# Should show: demo

# Extract key metadata fields
kubectl get widget demo -o jsonpath='{.metadata.uid}'
echo ""
kubectl get widget demo -o jsonpath='{.metadata.resourceVersion}'
echo ""
kubectl get widget demo -o jsonpath='{.metadata.generation}'
echo ""

# Full YAML
kubectl get widget demo -o yaml
```

Expected: uid is a UUID, resourceVersion is a positive integer (etcd revision), generation is 1.

---

### 4. Update the spec (simulate user changing desired state)

```bash
kubectl patch widget demo --type=merge -p '{"spec":{"size":"large"}}'
```

**What's happening**:
1. API server reads current object from etcd
2. Merges the patch into spec.size
3. Increments metadata.generation (because spec changed)
4. Writes back to etcd with new resourceVersion
5. Watch cache sends MODIFIED event

**Observe**: Both resourceVersion and generation increment.

**Verification**:
```bash
# Check new values
kubectl get widget demo -o jsonpath='RV: {.metadata.resourceVersion}, Gen: {.metadata.generation}'
echo ""

# Verify spec.size changed
kubectl get widget demo -o jsonpath='{.spec.size}'
echo ""
```

Expected: resourceVersion is higher, generation is 2, spec.size is "large".

---

### 5. Update the status subresource (simulate controller reconciliation)

```bash
kubectl patch widget demo --subresource=status --type=merge -p '{"status":{"observedGeneration":2,"conditions":[{"type":"Ready","status":"True","lastTransitionTime":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}]}}'
```

**What's happening**:
1. Status subresource update bypasses spec validation
2. resourceVersion increments (etcd write occurred)
3. generation does NOT increment (spec unchanged)
4. Controllers use this pattern to report reconciliation results

**Observe**: resourceVersion changes but generation stays constant.

**Verification**:
```bash
# Check that generation didn't change
kubectl get widget demo -o jsonpath='RV: {.metadata.resourceVersion}, Gen: {.metadata.generation}, ObsGen: {.status.observedGeneration}'
echo ""

# View the status section
kubectl get widget demo -o jsonpath='{.status}' | jq
```

Expected: resourceVersion incremented, generation still 2, observedGeneration is 2 (controller is caught up).

---

### 6. Demonstrate watch streams

Run these in **two separate terminals**:

**Terminal 1** — start the watch:
```bash
kubectl get widget demo -w
```

**Terminal 2** — make a change:
```bash
kubectl patch widget demo --type=merge -p '{"spec":{"size":"small"}}'
```

When done, press **Ctrl-C** in Terminal 1 to stop the watch.

**What's happening**: `kubectl get -w` opens a long-lived HTTP connection with `?watch=1`. The API server streams JSON events (ADDED/MODIFIED/DELETED) as they occur. This is the same mechanism Informers use.

**Observe**: Terminal 1 prints a MODIFIED line when the patch is applied in Terminal 2.

---

### 7. Trigger an optimistic locking conflict

```bash
# Capture current resourceVersion
RV=$(kubectl get widget demo -o jsonpath='{.metadata.resourceVersion}')
echo "Current RV: $RV"

# Make an update (increments resourceVersion)
kubectl patch widget demo --type=merge -p '{"spec":{"size":"medium"}}'

# Try to update using the stale resourceVersion
# This simulates two clients updating concurrently
kubectl patch widget demo --type=merge -p "{\"metadata\":{\"resourceVersion\":\"$RV\"},\"spec\":{\"size\":\"huge\"}}"
```

**What's happening**: The second patch includes a stale resourceVersion. The API server's etcd write uses CompareAndSwap, checking that the current revision matches. It doesn't, so the write is rejected with 409 Conflict.

**Observe**: The second command should fail with a conflict error.

**Expected output**:
```
Error from server (Conflict): the object has been modified; please apply your changes to the latest version and try again
```

This is normal and expected - clients retry with the updated object. client-go's `RetryOnConflict` helper handles this automatically.

---

### 8. Additional exploration

#### View all API resources including custom ones

```bash
kubectl api-resources | grep widget
```

#### Check watch cache behavior (requires API server metrics)

```bash
# Port-forward to API server metrics endpoint (if enabled)
kubectl port-forward -n kube-system pod/kube-apiserver-prep-control-plane 6443:6443 &
PF_PID=$!
sleep 2

# This might not work in kind without additional config, but the pattern is:
# curl -k https://localhost:6443/metrics | grep apiserver_watch_cache

kill $PF_PID
```

#### Inspect etcd contents directly

```bash
kubectl exec -n kube-system etcd-prep-control-plane -- sh -c \
  "ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
   --cacert=/etc/kubernetes/pki/etcd/ca.crt \
   --cert=/etc/kubernetes/pki/etcd/server.crt \
   --key=/etc/kubernetes/pki/etcd/server.key \
   get /registry/demo.io/widgets/default/demo --print-value-only" | strings | head -20
```

**Observe**: The raw protobuf-encoded object stored in etcd. You'll see fragments of field names and values.

---

## Cleanup

```bash
kubectl delete widget demo
kubectl delete crd widgets.demo.io

# Or tear down the entire cluster
kind delete cluster --name prep
```

---

## Key Takeaways

1. **resourceVersion** changes on every update (spec, status, metadata) - it's the etcd revision
2. **generation** only increments when spec changes - controllers use this to avoid unnecessary reconciliation
3. **observedGeneration** in status indicates which spec version the controller has reconciled
4. Status subresource updates don't increment generation
5. Watch streams enable real-time propagation without polling
6. Optimistic locking via resourceVersion prevents lost updates in concurrent scenarios
