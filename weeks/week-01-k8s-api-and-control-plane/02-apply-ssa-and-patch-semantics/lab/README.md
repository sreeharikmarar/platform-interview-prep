# Lab: Server-Side Apply & Patch Semantics

This lab demonstrates field ownership conflicts, SSA vs client-side apply, patch type differences, and managedFields inspection.

## Prerequisites

- Running Kubernetes cluster
- kubectl 1.22+ (SSA enabled by default)
- jq and yq for JSON/YAML processing

## Step-by-Step Instructions

### 1. Create deployment with client-side apply (legacy)

```bash
kubectl apply -f lab/deploy.yaml
```

**What's happening**: kubectl reads the manifest, fetches current server state, computes a three-way merge using the last-applied-configuration annotation, and sends a Strategic Merge Patch.

**Observe**: The deployment is created with an annotation storing the manifest.

**Verification**:
```bash
# Check for the annotation
kubectl get deploy ssa-demo -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}' | jq '.'

# See managedFields (kubectl-client-side-apply owns all fields via Update operation)
kubectl get deploy ssa-demo -o json | jq '.metadata.managedFields[] | {manager, operation}'
```

Expected: Annotation contains full manifest JSON, managedFields shows "kubectl-client-side-apply" with operation "Update".

---

### 2. Apply the same manifest with SSA as "alice"

```bash
kubectl apply --server-side --field-manager=alice -f lab/deploy.yaml
```

**What's happening**: kubectl sends the manifest with Content-Type: application/apply-patch+yaml and fieldManager=alice. The API server compares alice's fields with existing managedFields, sees kubectl-client-side-apply owns them, and transfers ownership to alice (no conflict because it's an initial SSA transition).

**Observe**: managedFields now includes an entry for alice with operation "Apply".

**Verification**:
```bash
kubectl get deploy ssa-demo -o json | jq '.metadata.managedFields[] | {manager, operation, fields: .fieldsV1 | keys}'
```

Expected: Two entries - "kubectl-client-side-apply" (Update) and "alice" (Apply). Alice owns most fields now.

---

### 3. Apply a different manifest as "bob" (expect conflict)

```bash
kubectl apply --server-side --field-manager=bob -f lab/deploy-bob.yaml
```

**What's happening**: deploy-bob.yaml sets different values (e.g., replicas: 2 instead of 1). Bob tries to claim fields owned by alice. The API server detects conflict and returns 409.

**Observe**: Command fails with conflict error listing which fields and which manager.

**Expected output**:
```
Error from server (Conflict): Apply failed with 1 conflict: conflict with "alice" using apps/v1 at: .spec.replicas
Please review the fields above and re-apply with --force-conflicts to force the change
```

---

### 4. Force bob to take ownership

```bash
kubectl apply --server-side --field-manager=bob --force-conflicts -f lab/deploy-bob.yaml
```

**What's happening**: `--force-conflicts` removes alice's ownership of conflicting fields and assigns them to bob. Bob now owns spec.replicas, alice owns other fields.

**Observe**: Apply succeeds, object is updated.

**Verification**:
```bash
# Check replicas changed
kubectl get deploy ssa-demo -o jsonpath='{.spec.replicas}'
# Should be 2 now

# Inspect ownership distribution
kubectl get deploy ssa-demo -o json | jq '.metadata.managedFields[] | select(.manager == "alice" or .manager == "bob") | {manager, fields: .fieldsV1}'
```

Expected: Bob owns spec.replicas, alice owns spec.template.spec.containers and other fields.

---

### 5. Demonstrate JSON Merge Patch replacing entire array

```bash
# First, check current containers
kubectl get deploy ssa-demo -o jsonpath='{.spec.template.spec.containers[*].name}'
# Should show: nginx (and possibly others)

# Apply a patch with one container using JSON Merge Patch
kubectl patch deploy ssa-demo --type=merge -p '{"spec":{"template":{"spec":{"containers":[{"name":"sidecar","image":"busybox:1.36"}]}}}}'

# Check containers again
kubectl get deploy ssa-demo -o jsonpath='{.spec.template.spec.containers[*].name}'
```

**What's happening**: JSON Merge Patch treats arrays atomically. The patch replaces the entire containers array with just [sidecar]. Any other containers (nginx, init containers) are deleted.

**Observe**: Only "sidecar" container remains. Original containers are gone!

**This is dangerous**: In production, this would delete Istio sidecar, monitoring agents, etc.

---

### 6. Rollback and demonstrate Strategic Merge Patch

```bash
# Reset to original state
kubectl apply -f lab/deploy.yaml

# Verify containers
kubectl get deploy ssa-demo -o jsonpath='{.spec.template.spec.containers[*].name}'

# Update nginx container's image using Strategic Merge Patch (default for kubectl patch)
kubectl patch deploy ssa-demo --type=strategic -p '{"spec":{"template":{"spec":{"containers":[{"name":"nginx","image":"nginx:1.25"}]}}}}'

# Check result
kubectl get deploy ssa-demo -o jsonpath='{.spec.template.spec.containers[*].name} {.spec.template.spec.containers[0].image}'
```

**What's happening**: Strategic Merge Patch uses patchMergeKey (name) to identify which container to update. It merges the nginx container's fields without touching other containers.

**Observe**: nginx container's image updated to 1.25, container list otherwise unchanged.

---

### 7. Demonstrate JSON Patch for precise operations

```bash
# Add an environment variable to the first container
kubectl patch deploy ssa-demo --type=json -p '[
  {"op":"add","path":"/spec/template/spec/containers/0/env","value":[{"name":"DEBUG","value":"true"}]}
]'

# Verify
kubectl get deploy ssa-demo -o jsonpath='{.spec.template.spec.containers[0].env}'

# Add a second env var
kubectl patch deploy ssa-demo --type=json -p '[
  {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"LOG_LEVEL","value":"info"}}
]'

# Verify both
kubectl get deploy ssa-demo -o jsonpath='{.spec.template.spec.containers[0].env[*].name}'
```

**What's happening**: JSON Patch provides precise operations. `path: "/spec/template/spec/containers/0/env/-"` uses the special index "-" to append to array.

**Observe**: Environment variables added without replacing other fields.

---

### 8. Inspect managedFields in detail

```bash
# Pretty-print managedFields
kubectl get deploy ssa-demo -o json | jq '.metadata.managedFields'

# See which manager owns spec.replicas
kubectl get deploy ssa-demo -o json | jq '.metadata.managedFields[] | select(.fieldsV1."f:spec"."f:replicas") | .manager'

# Count how many managers have touched this object
kubectl get deploy ssa-demo -o json | jq '.metadata.managedFields | length'
```

**What's happening**: managedFields is an array with one entry per manager. Each entry has fieldsV1 encoding the set of fields that manager owns.

**Observe**: The fieldsV1 structure uses "f:fieldname" notation for fields and "k:{key}" for array elements.

---

### 9. Demonstrate drift detection

```bash
# Apply with dry-run to see what would change
kubectl apply --server-side --field-manager=alice --dry-run=server -f lab/deploy.yaml

# Use kubectl diff (client-side, not SSA-aware but useful)
kubectl diff -f lab/deploy.yaml
```

**What's happening**: --dry-run=server sends the apply to the API server but doesn't persist. The server returns what the object would look like after apply.

**Observe**: If there's no output, the object matches the manifest. If there are differences, kubectl shows a diff.

---

### 10. Clean up client-side annotation

```bash
# Remove the last-applied-configuration annotation
kubectl annotate deploy ssa-demo kubectl.kubernetes.io/last-applied-configuration-

# Verify it's gone
kubectl get deploy ssa-demo -o jsonpath='{.metadata.annotations}'
```

**What's happening**: Trailing "-" in kubectl annotate removes the annotation. After migrating to SSA, this annotation is no longer needed and can be cleaned up.

---

## Additional Exploration

### Compare patch types side-by-side

```bash
# Save current state
kubectl get deploy ssa-demo -o yaml > current.yaml

# See what Strategic Merge would do
kubectl patch deploy ssa-demo --type=strategic --dry-run=server -o yaml -p '{"spec":{"replicas":10}}' > strategic-result.yaml

# See what JSON Merge would do
kubectl patch deploy ssa-demo --type=merge --dry-run=server -o yaml -p '{"spec":{"replicas":10}}' > merge-result.yaml

# Compare (should be identical for simple fields)
diff strategic-result.yaml merge-result.yaml
```

### Simulate GitOps conflict

```bash
# Terminal 1: Continuous apply loop (simulating GitOps controller)
while true; do
  kubectl apply --server-side --field-manager=gitops -f lab/deploy.yaml
  sleep 5
done

# Terminal 2: Manual change (simulating cluster admin)
kubectl scale deploy ssa-demo --replicas=10

# Observe: Next gitops apply detects drift and resets replicas to 3
```

---

## Cleanup

```bash
kubectl delete deploy ssa-demo
```

---

## Key Takeaways

1. **Client-side apply** uses annotation for three-way merge, **SSA** uses managedFields for ownership tracking
2. **Field conflicts** occur when different managers claim the same field; use --force-conflicts to steal ownership
3. **JSON Merge Patch** replaces entire arrays (dangerous), **Strategic Merge Patch** merges array elements by key (safe)
4. **JSON Patch** provides precise operations (add/remove/replace at specific paths)
5. **managedFields** shows exactly which manager owns which fields
6. Always use **--dry-run=server** to preview changes before applying
7. Migrate to **SSA** for multi-actor scenarios (GitOps + platform automation + manual changes)
