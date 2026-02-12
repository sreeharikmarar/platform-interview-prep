# kubectl apply, Server-Side Apply (SSA) & Patch Semantics

## What you should be able to do
- Explain patch types and safe usage.
- Explain SSA field ownership and conflicts.
- Avoid GitOps/controller config wars.

## Mental model

Before Server-Side Apply (SSA), `kubectl apply` performed client-side three-way merge: it compared the last-applied-configuration annotation, the current server state, and the new manifest to compute a patch. This was brittle - if multiple tools managed the same object (Helm, Flux, manual kubectl), they would overwrite each other's annotations and lose track of ownership. SSA fundamentally solves this by moving the merge logic into the API server and tracking which field manager owns each field in `metadata.managedFields`.

Think of SSA as a version control system for Kubernetes objects: each field manager (identified by a string like "kubectl-client-side-apply" or "flux-controller") claims ownership of specific fields. When you apply a manifest with SSA, you're declaring "I own these fields and want them set to these values." The API server records your claim in managedFields. If another manager tries to claim the same field, you get a conflict error unless you use force. This enables safe collaboration - the platform team can manage Gateway listeners via Terraform while tenant teams attach HTTPRoutes via GitOps without conflicts.

The three patch types (Strategic Merge Patch, JSON Merge Patch, JSON Patch) differ in how they handle arrays and deletions. Strategic Merge Patch uses special merge keys (like `name` for containers) to update array elements in place. JSON Merge Patch replaces entire arrays. JSON Patch provides precise operations (add/remove/replace at specific paths). SSA builds on top of these by adding field tracking and conflict detection, making it the preferred approach for declarative management in 2025.

Understanding field ownership is critical for platform engineering. In multi-tenant systems, you define clear boundaries: the platform owns infrastructure fields (resource requests, security contexts), tenant controllers own application fields (image tags, replicas), and admission webhooks enforce that tenants can't claim platform-owned fields. This prevents configuration drift and enables safe automated updates without coordination.

## Key Concepts

- **Field Manager**: A string identifier (e.g., "kubectl-client-side-apply", "flux", "terraform") that claims ownership of fields. Specified via `--field-manager` flag or `fieldManager` in the request.
- **managedFields**: Array in metadata tracking which manager owns which fields, with operation (Apply/Update), apiVersion, and field set (encoded).
- **Strategic Merge Patch (SMP)**: Kubernetes-specific patch type that uses `patchStrategy` and `patchMergeKey` from OpenAPI schema to merge arrays intelligently (e.g., merge containers by name).
- **JSON Merge Patch (RFC 7386)**: Standard JSON patch where `null` deletes fields and objects merge recursively. Arrays are replaced wholesale.
- **JSON Patch (RFC 6902)**: Array of operations: `{op: "add/remove/replace", path: "/spec/replicas", value: 3}`.
- **Server-Side Apply (SSA)**: Patch type where client sends full desired state with `?fieldManager=X`, server computes diff, detects conflicts, and updates managedFields.
- **Conflicts**: Occur when two field managers with different names try to own the same field. Resolved via `force: true` (steal ownership) or editing manifests to remove the field.

## Internals

### Client-Side Apply (Legacy)

1. **Annotation-based Tracking**: kubectl reads `kubectl.kubernetes.io/last-applied-configuration` annotation, which stores the last manifest as JSON.

2. **Three-Way Merge**: kubectl computes:
   - Fields in last-applied but not in new manifest → delete from server
   - Fields in new manifest → add/update on server
   - Fields only on server (not in last-applied or new) → keep (assumed owned by other actors)

3. **Patch Submission**: kubectl constructs a Strategic Merge Patch and sends PATCH request.

4. **Limitations**:
   - Annotation grows unbounded (1MB limit can be hit)
   - Only one manager (last to apply wins)
   - Deleting fields requires setting them to null explicitly
   - Doesn't track which fields kubectl actually manages

### Server-Side Apply (SSA)

1. **Apply Request**: Client sends `PATCH /apis/GROUP/VERSION/namespaces/NS/RESOURCE/NAME?fieldManager=mymanager` with `Content-Type: application/apply-patch+yaml`. Body contains the full desired state (partial objects allowed).

2. **Ownership Calculation**: API server compares incoming fields with existing `managedFields`. For each field in the apply:
   - If no manager owns it → claim ownership for `mymanager`
   - If `mymanager` owns it → update value
   - If different manager owns it → CONFLICT (unless `force: true`)

3. **Merge Logic**: API server uses Strategic Merge Patch semantics (respecting patchStrategy from schema) but tracks ownership at field granularity. For arrays with merge keys (like `containers[name=nginx]`), ownership is per-array-element-field.

4. **managedFields Update**: Server writes/updates entry in `managedFields` array:
   ```yaml
   - manager: mymanager
     operation: Apply
     apiVersion: apps/v1
     time: "2025-01-15T12:00:00Z"
     fieldsType: FieldsV1
     fieldsV1:
       f:spec:
         f:replicas: {}
         f:template:
           f:spec:
             f:containers:
               k:{"name":"nginx"}:
                 f:image: {}
   ```

5. **Conflict Handling**: If conflict detected, server returns 409 with details: `"field 'spec.replicas' is managed by 'terraform' but apply from 'kubectl' attempted to claim it"`. Client can retry with `force: true` to steal ownership.

6. **Force Apply**: `kubectl apply --server-side --force-conflicts` or API parameter `force: true` removes other managers' ownership and claims for the requesting manager. Use with caution - can cause other controllers to misbehave.

### Patch Type Details

#### Strategic Merge Patch (default for kubectl apply)

Uses schema annotations:
- `patchStrategy: merge` + `patchMergeKey: name` → merge array elements by key
- `patchStrategy: replace` → replace entire array
- `patchStrategy: retainKeys` → delete keys not in patch

Example: Updating one container in a pod:
```yaml
spec:
  containers:
  - name: nginx  # patchMergeKey
    image: nginx:1.25  # Only this field updates; other containers unchanged
```

#### JSON Merge Patch (--type=merge)

Simple recursive merge:
- Objects merge field-by-field
- Arrays replace entirely
- `null` deletes the field

Example:
```bash
kubectl patch deploy nginx --type=merge -p '{"spec":{"replicas":null}}'  # Deletes replicas field
```

#### JSON Patch (--type=json)

Precise operations:
```bash
kubectl patch deploy nginx --type=json -p '[
  {"op":"replace","path":"/spec/replicas","value":5},
  {"op":"add","path":"/spec/template/spec/containers/0/env","value":[{"name":"FOO","value":"bar"}]},
  {"op":"remove","path":"/spec/strategy"}
]'
```

Useful for removing specific array elements or deeply nested fields.


## Architecture Diagram

```
┌────────────────────────────────────────────────────────────┐
│  Client: kubectl apply --server-side --field-manager=alice │
│                                                            │
│  Manifest (partial):                                      │
│    replicas: 3                                            │
│    image: nginx:1.25                                      │
└─────────────────┬──────────────────────────────────────────┘
                  │ PATCH with Content-Type: application/apply-patch+yaml
                  ▼
         ┌────────────────────┐
         │   kube-apiserver   │
         │                    │
         │ Current state:     │
         │   replicas: 5      │ ← managed by "bob"
         │   image: nginx:1.24│ ← managed by "alice"
         │   resources: {...} │ ← managed by "terraform"
         │                    │
         │ Apply logic:       │
         │ ┌────────────────┐ │
         │ │For each field  │ │
         │ │in apply patch: │ │
         │ │                │ │
         │ │replicas:       │ │
         │ │ owned by bob   │ │
         │ │ → CONFLICT!    │ │
         │ │                │ │
         │ │image:          │ │
         │ │ owned by alice │ │
         │ │ → UPDATE OK    │ │
         │ └────────────────┘ │
         └──────────┬─────────┘
                    │ (without force)
                    ▼
         ┌──────────────────────────────────────────┐
         │  409 Conflict                            │
         │  "field spec.replicas managed by 'bob'"  │
         └──────────────────────────────────────────┘

         (with force: true)
                    │
                    ▼
         ┌────────────────────┐
         │  Update object:    │
         │    replicas: 3     │ ← NOW managed by "alice" (stolen)
         │    image: nginx:1.25│ ← still managed by "alice"
         │                    │
         │  managedFields:    │
         │  - manager: alice  │
         │    fields:         │
         │      spec.replicas │
         │      spec.template.│
         │        spec.contai-│
         │        ners[nginx].│
         │        image       │
         │  - manager: terraform│
         │    fields:         │
         │      spec.template.│
         │        spec.contai-│
         │        ners[nginx].│
         │        resources   │
         └────────────────────┘
```

## Failure Modes & Debugging

### 1. Field Ownership Conflicts

**Symptoms**: `kubectl apply --server-side` fails with 409 Conflict: "Apply failed with 1 conflict: conflict with 'flux-controller' over field 'spec.replicas'". Different managers fight for the same field. GitOps reconciliation loops retry indefinitely.

**Root Cause**: Two managers (e.g., kubectl and Flux) both declare ownership of the same field in their manifests. Neither uses `force`, so the API server rejects the second apply. This commonly happens when migrating from client-side to server-side apply, or when platform and tenant teams don't coordinate field boundaries.

**Blast Radius**: Affects specific objects managed by multiple tools. Can block deployments if the GitOps controller can't apply manifests. Creates drift where desired state in Git doesn't match cluster state.

**Mitigation**:
- Define clear field ownership boundaries upfront (document in runbooks/admission policies)
- Use different fieldManager names for different actors
- Apply `force: true` carefully during migrations to steal ownership intentionally
- Use admission webhooks to prevent tenants from claiming platform-managed fields
- Configure GitOps tools to use consistent fieldManager names across reconciliations

**Debugging**:
```bash
# Identify which manager owns the conflicting field
kubectl get deploy nginx -o yaml | yq '.metadata.managedFields'

# See exactly which fields each manager owns
kubectl get deploy nginx -o json | jq '.metadata.managedFields[] | {manager: .manager, fields: .fieldsV1}'

# Forcefully steal ownership (use with caution)
kubectl apply --server-side --field-manager=my-manager --force-conflicts -f manifest.yaml
```

### 2. Array Merge Semantics Surprises

**Symptoms**: Applying a manifest with one container replaces all containers instead of merging. Environment variables disappear when updating one entry. Volumes get duplicated or lost.

**Root Cause**: Misunderstanding patch strategies. Strategic Merge Patch merges arrays by patchMergeKey (e.g., containers by `name`), but only if you specify the key field. JSON Merge Patch replaces entire arrays. If you apply a partial manifest expecting merge but the array has `patchStrategy: replace`, you lose existing elements.

**Blast Radius**: Can delete sidecars injected by other controllers (e.g., Istio proxy, Vault agent). Can remove volumes or environment variables managed by other tools. Hard to detect until runtime when containers fail due to missing config.

**Mitigation**:
- Always include the merge key field (e.g., `name: nginx`) when patching arrays
- Use SSA with full manifests, not partial patches, to make intent explicit
- Test patches in staging to verify merge behavior
- Use JSON Patch (`--type=json`) for precise array element operations

**Debugging**:
```bash
# Check the patchStrategy for containers
kubectl explain deployment.spec.template.spec.containers --recursive | grep patchStrategy
# Output: patchStrategy=merge, patchMergeKey=name

# Verify current containers before applying
kubectl get deploy nginx -o jsonpath='{.spec.template.spec.containers[*].name}'

# Use dry-run to see what would change
kubectl apply --server-side --dry-run=server -f manifest.yaml
```

### 3. Drift Detection Loops

**Symptoms**: GitOps controller continuously reconciles the same object, always detecting drift. Object's resourceVersion increments rapidly. Controller logs show "applying manifest" repeatedly with no actual changes visible.

**Root Cause**: The controller applies a manifest that doesn't include fields set by other managers or defaulting, so SSA considers the object drifted. For example, controller applies `replicas: 3` but doesn't include `strategy` field, which platform team manages. Every reconcile, SSA sees the controller doesn't claim `strategy`, but it's present, so it looks like drift. Or, the Kubernetes API adds default values (like `imagePullPolicy: Always`) that aren't in the controller's manifest, causing continuous reapply.

**Blast Radius**: Wastes API server capacity with no-op writes. Increases etcd write load and wear. Makes audit logs noisy. Can hit rate limits or quota.

**Mitigation**:
- Controllers should read the object after apply and compare with desired state to detect true drift
- Include all fields the controller manages in the apply manifest (not just changed fields)
- Use structured merge diff to compare: `kubectl alpha diff -f manifest.yaml`
- Set `spec.replicas = nil` in controller code for fields it doesn't manage (Go client-go)
- Use predicates in controller-runtime to filter status-only updates

**Debugging**:
```bash
# Watch for rapid resourceVersion changes
kubectl get deploy nginx -w

# Compare managedFields before and after apply
kubectl get deploy nginx -o json | jq '.metadata.managedFields' > before.json
# Apply the manifest
kubectl apply --server-side --field-manager=my-controller -f manifest.yaml
kubectl get deploy nginx -o json | jq '.metadata.managedFields' > after.json
diff before.json after.json

# Use kubectl diff (client-side, not SSA-aware, but useful)
kubectl diff -f manifest.yaml
```

### 4. Client-Side Apply vs Server-Side Apply Conflicts

**Symptoms**: Object has both `kubectl.kubernetes.io/last-applied-configuration` annotation (client-side) and managedFields entries (server-side). Applying the same manifest sometimes works, sometimes conflicts. Annotation grows beyond 256KB and gets truncated.

**Root Cause**: Mixing client-side apply (`kubectl apply` without `--server-side`) and server-side apply on the same object. Client-side apply uses the annotation for three-way merge, server-side uses managedFields. They track ownership differently, causing inconsistencies. The annotation is also written by client-side apply using Update operation, which creates a separate managedFields entry.

**Blast Radius**: Limited to objects managed inconsistently. Can cause unexpected field deletions when switching between modes. Makes ownership unclear.

**Mitigation**:
- Migrate fully to server-side apply (kubectl 1.18+, default in 1.22+)
- Use `kubectl apply --server-side` consistently
- Avoid mixing `kubectl apply` and `kubectl edit` (edit uses Update, apply uses Apply operation)
- Clean up old annotation after migration: `kubectl annotate deploy nginx kubectl.kubernetes.io/last-applied-configuration-`

**Debugging**:
```bash
# Check if annotation exists
kubectl get deploy nginx -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}' | wc -c

# See all managedFields operations
kubectl get deploy nginx -o json | jq '.metadata.managedFields[] | {manager, operation}'

# Migrate explicitly
kubectl apply --server-side --field-manager=kubectl-client-side-apply -f manifest.yaml
```


## Lightweight Lab

```bash
# 1. Create initial deployment with client-side apply (legacy)
kubectl apply -f lab/deploy.yaml
# Observe: Creates annotation kubectl.kubernetes.io/last-applied-configuration

# 2. Inspect the annotation
kubectl get deploy ssa-demo -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}' | jq
# Observe: Full manifest stored in annotation

# 3. Apply same manifest with SSA as "alice"
kubectl apply --server-side --field-manager=alice -f lab/deploy.yaml
# Observe: Creates managedFields entry for "alice" claiming all fields

# 4. Check managedFields
kubectl get deploy ssa-demo -o yaml | yq '.metadata.managedFields'
# Observe: Entry for alice with operation: Apply

# 5. Apply manifest with different replicas as "bob" (conflict expected)
kubectl apply --server-side --field-manager=bob -f lab/deploy-bob.yaml
# Observe: 409 Conflict error because alice owns spec.replicas

# 6. Force bob to take ownership
kubectl apply --server-side --field-manager=bob --force-conflicts -f lab/deploy-bob.yaml
# Observe: Bob now owns spec.replicas, alice still owns other fields

# 7. Check updated managedFields
kubectl get deploy ssa-demo -o json | jq '.metadata.managedFields[] | {manager, fields: .fieldsV1}'
# Observe: Both alice and bob have entries, owning different fields

# 8. Demonstrate JSON Merge Patch replacing containers
kubectl get deploy ssa-demo -o jsonpath='{.spec.template.spec.containers[*].name}'
# Observe: Current container names
kubectl patch deploy ssa-demo --type=merge -p '{"spec":{"template":{"spec":{"containers":[{"name":"sidecar","image":"busybox"}]}}}}'
kubectl get deploy ssa-demo -o jsonpath='{.spec.template.spec.containers[*].name}'
# Observe: Only sidecar remains - original containers REPLACED

# 9. Rollback and demonstrate Strategic Merge Patch
kubectl apply -f lab/deploy.yaml  # Reset
kubectl patch deploy ssa-demo --type=strategic -p '{"spec":{"template":{"spec":{"containers":[{"name":"nginx","image":"nginx:1.25"}]}}}}'
kubectl get deploy ssa-demo -o jsonpath='{.spec.template.spec.containers[*].name} {.spec.template.spec.containers[0].image}'
# Observe: nginx container updated IN PLACE using name as merge key

# 10. Demonstrate JSON Patch for precise operations
kubectl patch deploy ssa-demo --type=json -p '[{"op":"add","path":"/spec/template/spec/containers/0/env","value":[{"name":"DEBUG","value":"true"}]}]'
kubectl get deploy ssa-demo -o jsonpath='{.spec.template.spec.containers[0].env}'
# Observe: Environment variable added to first container

# 11. Additional exploration: compare patch types
kubectl get deploy ssa-demo -o yaml > original.yaml
# Try different patch types and diff results
kubectl patch deploy ssa-demo --type=merge -p '{"spec":{"replicas":5}}' --dry-run=server -o yaml > merge-result.yaml
diff original.yaml merge-result.yaml
```
