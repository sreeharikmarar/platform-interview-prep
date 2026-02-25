# Admission Chain: Mutating/Validating Webhooks & Policy

## What you should be able to do
- Explain admission ordering.
- Decide webhook vs controller vs data-plane.
- Design webhooks to minimize blast radius.

## Mental model

Admission control is the last checkpoint before an object is persisted to etcd - think of it as the bouncer at the door who validates your ID, stamps your hand, and enforces house rules before you enter the club. Unlike authorization which answers "can this user perform this action?", admission answers "should this specific object be allowed into the cluster?" and can modify the object before accepting it.

The admission chain runs after authentication and authorization but before schema validation and persistence. It consists of two phases: mutating admission runs first (can modify objects - inject sidecars, set defaults, add labels), then validating admission runs second (can reject but not modify - enforce policies like "prod namespace requires resource limits"). This ordering is critical: validators see the object after all mutations have been applied, so they can validate the final state.

Admission webhooks are user-defined HTTPS endpoints that the API server calls during the admission chain. You register a MutatingWebhookConfiguration or ValidatingWebhookConfiguration that specifies which resources to intercept (matching rules on API group/version/resource) and where to send them (service reference or URL). The API server serializes the object as an AdmissionReview request, POSTs it to your webhook, and expects an AdmissionReview response with `allowed: true/false` and optional patches.

The critical insight is that admission is synchronous and on the write path - every `kubectl apply` blocks until all webhooks respond or timeout. This makes admission powerful for enforcing invariants (no latest tags in prod, all workloads have mesh sidecar) but dangerous if misconfigured (slow webhook blocks all creates cluster-wide). Design admission webhooks to be fast (<100ms p99), deterministic (same input always produces same output), and highly available (use failurePolicy carefully). For long-running validation (e.g., scanning images), use asynchronous patterns like admission control creating a pending object, then a controller scanning and updating status, and another validating webhook checking status on read.

## Key Concepts

- **AdmissionReview**: API object wrapping admission requests/responses; contains the object being admitted, user info, and old object (for updates)
- **MutatingWebhookConfiguration**: Registers a mutating webhook with match rules, service reference, CA bundle, and failurePolicy
- **ValidatingWebhookConfiguration**: Registers a validating webhook (can reject but not modify)
- **ValidatingAdmissionPolicy**: In-process CEL-based validation (Kubernetes 1.26+, GA in 1.30) - no external webhook needed
- **Admission Policy Binding**: Links a ValidatingAdmissionPolicy to resources via parameterRef and matchConstraints
- **Match Rules**: Specifies which operations (CREATE/UPDATE/DELETE) on which API groups/versions/resources trigger the webhook
- **Object Selector / Namespace Selector**: Label selectors to filter which objects/namespaces the webhook applies to
- **Failure Policy**: What happens if webhook is unavailable - `Fail` (reject request) or `Ignore` (skip webhook)
- **Timeout**: How long API server waits for webhook response (default 10s, max 30s)
- **Reinvocation Policy**: Whether to call webhook again if another webhook mutates the object (`Never` or `IfNeeded`)
- **Side Effects**: Declaration of whether webhook has side effects (`None`, `NoneOnDryRun`, `Some`, `Unknown`)

## Internals

### Admission Request Flow

1. **Authentication & Authorization**: User authenticates, RBAC checks pass. Request enters admission chain.

2. **Mutating Admission Phase**:
   - Built-in mutating plugins run first (e.g., ServiceAccount admission injects default SA token, DefaultStorageClass sets default PVC class)
   - External mutating webhooks run in order of creation (no guaranteed ordering between webhooks)
   - For each matching webhook:
     - API server constructs AdmissionReview request with:
       - `.request.object`: New object being created/updated
       - `.request.oldObject`: Previous version (for UPDATEs)
       - `.request.userInfo`: Who made the request
       - `.request.operation`: CREATE/UPDATE/DELETE
     - API server POSTs to webhook URL over HTTPS (validates TLS cert against CA bundle)
     - Webhook responds with AdmissionReview:
       - `.response.allowed: true/false`
       - `.response.patchType`: JSONPatch
       - `.response.patch`: base64-encoded JSON Patch operations
     - If allowed and patch provided, API server applies patch to object
     - If not allowed, request is rejected immediately with `.response.status.message`
   - All mutations accumulate - final object is result of all patches

3. **Schema Validation**: API server validates mutated object against OpenAPI schema (ensures required fields, correct types)

4. **Validating Admission Phase**:
   - Built-in validating plugins run (e.g., PodSecurity, LimitRanger, ResourceQuota)
   - ValidatingAdmissionPolicy controllers evaluate CEL expressions
   - External validating webhooks run in order
   - For each matching webhook:
     - API server sends AdmissionReview (same structure as mutating)
     - Webhook responds with allowed: true/false (no patches allowed)
     - If any webhook denies, entire request is rejected
   - All validators must pass

5. **Persistence**: If all admission checks pass, API server writes object to etcd

### ValidatingAdmissionPolicy (CEL-based)

Introduced in Kubernetes 1.26 as an in-process alternative to validating webhooks. Uses Common Expression Language (CEL) for validation logic.

**Example Policy**:
```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: require-labels
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
    - apiGroups: ["apps"]
      apiVersions: ["v1"]
      operations: ["CREATE", "UPDATE"]
      resources: ["deployments"]
  validations:
  - expression: "has(object.metadata.labels.team)"
    message: "Deployment must have 'team' label"
  - expression: "object.spec.replicas <= 10"
    message: "Deployments cannot exceed 10 replicas"
```

**Binding**:
```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: require-labels-binding
spec:
  policyName: require-labels
  validationActions: [Deny]
  matchResources:
    namespaceSelector:
      matchLabels:
        environment: production
```

**Advantages**:
- No external webhook (lower latency, higher availability)
- Declarative policy as code
- Type-safe CEL expressions validated at policy creation
- No TLS certificates to manage

**Limitations**:
- Cannot mutate objects
- CEL is less expressive than full programming languages
- Requires Kubernetes 1.26+

### Webhook Matching and Scoping

Webhooks use multiple filters to determine which requests to intercept:

1. **Match Rules** (resourceRules):
   ```yaml
   rules:
   - apiGroups: ["apps"]
     apiVersions: ["v1"]
     operations: ["CREATE", "UPDATE"]
     resources: ["deployments", "statefulsets"]
     scope: "Namespaced"  # or "Cluster" or "*"
   ```

2. **Object Selector**:
   ```yaml
   objectSelector:
     matchLabels:
       inject-sidecar: "true"
   ```
   Only objects with this label trigger the webhook.

3. **Namespace Selector**:
   ```yaml
   namespaceSelector:
     matchExpressions:
     - key: environment
       operator: In
       values: ["production", "staging"]
   ```
   Only objects in matching namespaces trigger the webhook.

4. **Match Policy**:
   - `Exact`: Only requests matching exact API group/version/resource trigger webhook
   - `Equivalent`: Requests to equivalent resources trigger (e.g., both `apps/v1` and `extensions/v1beta1` Deployments)

### Failure Handling

**failurePolicy: Fail**:
- Webhook timeout or error → request is rejected
- High security, low availability
- Use for critical policies (e.g., enforce no root containers)

**failurePolicy: Ignore**:
- Webhook timeout or error → request is accepted (webhook skipped)
- High availability, lower security
- Use for non-critical mutations (e.g., adding monitoring annotations)

**Best Practice**: Start with `Ignore` during rollout, switch to `Fail` after stability proven.

**timeoutSeconds**: Default 10s, max 30s. Set lower (5s) for fast-fail, higher for slow external validation.

### Reinvocation Policy

If webhook A mutates an object, and webhook B also matches the mutated object but ran before the mutation, should B run again?

- **reinvocationPolicy: Never** (default): B does not run again
- **reinvocationPolicy: IfNeeded**: B runs again if A's mutation changed fields relevant to B

Use `IfNeeded` when webhooks have dependencies (e.g., B validates fields that A injects).

### Side Effects and Dry Run

- **sideEffects: None**: Webhook is pure (no external calls, database writes, etc.). Safe for dry-run.
- **sideEffects: NoneOnDryRun**: Webhook skips side effects if `request.dryRun: true`
- **sideEffects: Some/Unknown**: Webhook has side effects, not safe for dry-run

API server skips webhooks with `sideEffects: Some` during `kubectl apply --dry-run=server`.


## Architecture Diagram

```
kubectl apply -f deployment.yaml
         │
         ▼
┌────────────────────────────────────────────┐
│  API Server Request Pipeline               │
│                                            │
│  1. Authentication                         │
│  2. Authorization (RBAC)                   │
│     ↓                                      │
│  ┌──────────────────────────────────────┐ │
│  │ 3. MUTATING ADMISSION                │ │
│  │                                      │ │
│  │  Built-in:                           │ │
│  │   - ServiceAccount (inject token)    │ │
│  │   - DefaultStorageClass              │ │
│  │                                      │ │
│  │  External Webhooks (parallel):       │ │
│  │   ┌─────────────────────────┐        │ │
│  │   │ POST /mutate            │        │ │
│  │   │ AdmissionReview req     │────┐   │ │
│  │   └─────────────────────────┘    │   │ │
│  │                                  │   │ │
│  │   ┌─────────────────────────┐    │   │ │
│  │   │ Sidecar Injector        │◄───┘   │ │
│  │   │ (istio, vault, etc.)    │        │ │
│  │   │                         │        │ │
│  │   │ AdmissionReview resp:   │        │ │
│  │   │  allowed: true          │        │ │
│  │   │  patch: [...]           │────┐   │ │
│  │   └─────────────────────────┘    │   │ │
│  │                                  │   │ │
│  │  Apply all patches ◄─────────────┘   │ │
│  │  (mutated object)                    │ │
│  └──────────────────────────────────────┘ │
│     ↓                                      │
│  4. Schema Validation (OpenAPI)            │
│     ↓                                      │
│  ┌──────────────────────────────────────┐ │
│  │ 5. VALIDATING ADMISSION              │ │
│  │                                      │ │
│  │  Built-in:                           │ │
│  │   - PodSecurity                      │ │
│  │   - ResourceQuota                    │ │
│  │   - LimitRanger                      │ │
│  │                                      │ │
│  │  ValidatingAdmissionPolicy (CEL):    │ │
│  │   - has(object.metadata.labels.team) │ │
│  │   - object.spec.replicas <= 10       │ │
│  │                                      │ │
│  │  External Webhooks (parallel):       │ │
│  │   ┌─────────────────────────┐        │ │
│  │   │ POST /validate          │        │ │
│  │   │ AdmissionReview req     │────┐   │ │
│  │   └─────────────────────────┘    │   │ │
│  │                                  │   │ │
│  │   ┌─────────────────────────┐    │   │ │
│  │   │ Policy Validator        │◄───┘   │ │
│  │   │                         │        │ │
│  │   │ AdmissionReview resp:   │        │ │
│  │   │  allowed: false         │        │ │
│  │   │  status: "no latest tag"│────┐   │ │
│  │   └─────────────────────────┘    │   │ │
│  │                                  │   │ │
│  │  If any denies → REJECT ◄────────┘   │ │
│  └──────────────────────────────────────┘ │
│     ↓ (all allowed)                        │
│  6. Persist to etcd                        │
└────────────────────────────────────────────┘
```

## Failure Modes & Debugging

### 1. Webhook Timeout / Unavailability (Cluster-Wide Write Blockage)

**Symptoms**: All `kubectl apply` commands hang for 10-30 seconds then fail with "context deadline exceeded" or "connection refused." Creates/updates for matching resources are blocked. Users see 500 Internal Server Error. API server logs show webhook call failures.

**Root Cause**: The API server calls webhooks synchronously in the write path. If the webhook pod is down (crashed, scaling to zero, node failure), network policy blocks traffic, DNS resolution fails, or the webhook is slow (>timeout), the API server waits until timeout. With `failurePolicy: Fail` (default), requests are rejected. If the webhook matches broad resources (`*/*`) with no selectors, the entire cluster's write path is blocked.

**Blast Radius**: Catastrophic if webhook matches all resources. Affects all controllers (can't update status), operators, GitOps reconciliation. Can cascade to control plane instability if controllers can't update leases. Critical path for incident response - can't apply fixes.

**Mitigation**:
- **Narrow scope**: Use objectSelector and namespaceSelector to limit blast radius (e.g., only namespaces with `inject-sidecar: true`)
- **Exclude critical namespaces**: Use namespaceSelector to exclude kube-system, kube-public
- **Set timeoutSeconds: 5** or lower for fast failure
- **Start with failurePolicy: Ignore**, switch to Fail after stability proven
- **Deploy webhook with high availability**: Multiple replicas, anti-affinity, PodDisruptionBudget
- **Monitor webhook latency**: `apiserver_admission_webhook_admission_duration_seconds` metric
- **Implement circuit breaker**: Webhook should fail open (allow: true) if external dependency is down

**Debugging**:
```bash
# Check webhook configurations
kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations

# Inspect specific webhook
kubectl get mutatingwebhookconfiguration istio-sidecar-injector -o yaml

# Check webhook service and endpoints
kubectl get svc,endpoints -n istio-system istio-sidecar-injector

# Check webhook pod status
kubectl get pods -n istio-system -l app=sidecar-injector

# API server logs show webhook calls and latency
kubectl logs -n kube-system kube-apiserver-control-plane | grep admission

# Test webhook endpoint directly
kubectl run curl --rm -it --image=curlimages/curl -- curl -k https://istio-sidecar-injector.istio-system.svc:443/inject -d '{}'

# Temporarily disable webhook (emergency)
kubectl delete mutatingwebhookconfiguration istio-sidecar-injector
```

### 2. Non-Deterministic Mutation (Apply Churn)

**Symptoms**: Same manifest applied repeatedly produces different results. Object's resourceVersion increments on every apply even when manifest unchanged. GitOps controller shows continuous drift. Logs show "updated object" on every reconcile. managedFields shows webhook fieldManager with changing values.

**Root Cause**: Webhook mutation logic is non-deterministic - it produces different output for the same input. Common causes:
- Injecting timestamps or random IDs into annotations
- Pulling external config that changes (e.g., webhook fetches sidecar image version from registry, version increments)
- Non-deterministic ordering of injected containers/volumes
- Different mutations based on time of day or load

**Blast Radius**: Affects specific objects matched by the webhook. Creates API server load from continuous updates. Makes it impossible to detect true drift. Can trigger downstream controllers to reconcile unnecessarily.

**Mitigation**:
- Make webhook mutations deterministic - same input always produces same output
- Don't inject timestamps or random values; use generation or resourceVersion if needed
- Sort injected arrays deterministically (e.g., containers by name)
- Cache external config with explicit versioning rather than "latest"
- Use SSA with webhook fieldManager to track which fields webhook owns
- Implement idempotency check: if webhook would produce same mutation, return original object unchanged

**Debugging**:
```bash
# Apply manifest twice and compare resourceVersions
kubectl apply --server-side --dry-run=server -o yaml -f manifest.yaml > first.yaml
kubectl apply --server-side --dry-run=server -o yaml -f manifest.yaml > second.yaml
diff first.yaml second.yaml

# Check managedFields for webhook fieldManager
kubectl get deploy nginx -o json | jq '.metadata.managedFields[] | select(.manager | contains("webhook"))'

# Watch for rapid updates
kubectl get deploy nginx -w

# Inspect webhook logs for mutation logic
kubectl logs -n webhook-ns deploy/webhook -f | grep "Mutating"
```

### 3. Policy Conflicts Between Webhooks

**Symptoms**: Different webhooks mutate the same field with different values. Object thrashes between states on each apply. Mutating webhook A sets image to `nginx:1.24`, webhook B sets it to `nginx:1.25`. Only the last webhook's mutation persists, causing unpredictable behavior.

**Root Cause**: Multiple webhooks claim ownership of the same field without coordination. Mutating webhooks run in undefined order (based on creation time), so the last one wins. Unlike SSA field managers, webhooks don't have explicit conflict detection - they just overwrite each other.

**Blast Radius**: Affects objects matched by conflicting webhooks. Causes non-deterministic final state depending on webhook ordering. Can violate security policies if restrictive webhook runs before permissive one.

**Mitigation**:
- Coordinate webhook scope with objectSelector to prevent overlap
- Use clear naming conventions for injected fields to avoid collisions
- Implement webhook ordering via dependencies (use reinvocationPolicy: IfNeeded)
- Consolidate related mutations into a single webhook when possible
- Document field ownership boundaries across webhooks
- Consider using SSA-aware webhooks that respect managedFields

**Debugging**:
```bash
# List all webhooks and their match rules
kubectl get mutatingwebhookconfigurations -o json | jq '.items[] | {name: .metadata.name, rules: .webhooks[].rules}'

# Check webhook execution order
kubectl logs -n kube-system kube-apiserver-control-plane | grep "calling webhook" | grep <object-name>

# Inspect object to see which mutations won
kubectl get deploy nginx -o yaml | grep -A 10 "image:"

# Test mutations in isolation
# Temporarily disable other webhooks and test one at a time
```

### 4. ValidatingAdmissionPolicy Evaluation Errors

**Symptoms**: Requests rejected with cryptic CEL errors like "evaluation failed: no such key: metadata." Policy that worked in test fails in prod. Inconsistent rejections for similar objects.

**Root Cause**: CEL expression references fields that don't exist on the object (e.g., `object.spec.replicas` on a Pod which has no replicas field). Expression has runtime errors (division by zero, nil pointer). Type mismatches (comparing string to int).

**Blast Radius**: Affects objects matched by the policy. Blocks valid requests due to policy bugs. Can be broad if policy matches many resource types.

**Mitigation**:
- Use CEL's `has()` function to check field existence: `has(object.spec.replicas) && object.spec.replicas > 5`
- Test policies with diverse object examples before deploying
- Use `failurePolicy: Ignore` during policy development
- Add defensive checks for optional fields
- Use policy binding's namespaceSelector to limit scope during rollout
- Monitor `apiserver_validating_admission_policy_check_total` metric for errors

**Debugging**:
```bash
# Check policy status for evaluation errors
kubectl get validatingadmissionpolicy require-labels -o yaml | grep -A 5 conditions

# View rejection message
kubectl apply -f invalid-deploy.yaml
# Error: admission webhook "require-labels" denied: Deployment must have 'team' label

# Test CEL expression in isolation (requires cel-go CLI or online evaluator)
# https://playcel.undistro.io/

# Check which objects the policy matches
kubectl get validatingadmissionpolicybinding require-labels-binding -o yaml

# Disable policy temporarily
kubectl delete validatingadmissionpolicybinding require-labels-binding
```


## Lightweight Lab

```bash
# 1. Apply a ValidatingAdmissionPolicy + binding (requires K8s 1.26+)
kubectl apply -f lab/validating-policy.yaml
# Observe: Creates policy requiring 'owner' label on Deployments, plus its binding

# 2. Try to create a Deployment without required label (should fail)
kubectl apply -f lab/bad-deploy.yaml
# Observe: Rejected with message "deployment must have metadata.labels.owner"

# 3. Create a Deployment with required label (should succeed)
kubectl apply -f lab/good-deploy.yaml
# Observe: Accepted and created

# 4. Check policy status
kubectl get validatingadmissionpolicy -o yaml
# Observe: Conditions showing if policy is active

# 5. Test policy in dry-run mode
kubectl apply --dry-run=server -f lab/bad-deploy.yaml
# Observe: Still rejected (policies run in dry-run)

# 6. Temporarily disable policy
kubectl delete validatingadmissionpolicybinding require-owner-label-binding
kubectl apply -f lab/bad-deploy.yaml
# Observe: Now succeeds (policy not bound)

# 7. Cleanup
kubectl delete -f lab/good-deploy.yaml
kubectl delete -f lab/validating-policy.yaml
```
