# Lab: Admission Webhooks & ValidatingAdmissionPolicy

This lab demonstrates in-cluster policy enforcement using ValidatingAdmissionPolicy (CEL-based, no external webhook needed).

## Prerequisites

- Kubernetes 1.26+ (ValidatingAdmissionPolicy is beta in 1.26, GA in 1.30)
- Running cluster
- kubectl 1.26+

## Step-by-Step Instructions

### 1. Create a ValidatingAdmissionPolicy

```bash
kubectl apply -f lab/validating-policy.yaml
```

**What's happening**: This creates a ValidatingAdmissionPolicy and its binding in one file. The policy checks that Deployments have an `owner` label. The binding activates the policy with `validationActions: [Deny]`.

**Verification**:
```bash
kubectl get validatingadmissionpolicy
kubectl get validatingadmissionpolicy require-owner-label -o yaml

# Check the binding was also created
kubectl get validatingadmissionpolicybinding
kubectl describe validatingadmissionpolicybinding require-owner-label-binding
```

Expected: Policy and binding are created. Policy status shows it's been compiled successfully.

---

### 2. Try to create a Deployment without required label

```bash
kubectl apply -f lab/bad-deploy.yaml
```

**What's happening**: The `no-owner` Deployment has no `owner` label. The CEL expression `has(object.metadata.labels) && has(object.metadata.labels.owner)` evaluates to false, causing denial.

**Expected output**:
```
Error from server (Forbidden): ... ValidatingAdmissionPolicy 'require-owner-label' with binding 'require-owner-label-binding' denied request: deployment must have metadata.labels.owner
```

**Observe**: The request was rejected at admission time, before persisting to etcd.

---

### 3. Create a Deployment with required label

```bash
kubectl apply -f lab/good-deploy.yaml
```

**What's happening**: The `with-owner` Deployment has `owner: platform` label. The CEL validation passes.

**Expected**: Deployment created successfully.

**Verification**:
```bash
kubectl get deploy with-owner -o jsonpath='{.metadata.labels.owner}'
# Should output: platform

kubectl get deploy with-owner -o jsonpath='{.spec.template.spec.containers[0].image}'
# Should output: nginx:1.27
```

---

### 4. Verify the CEL expression's defensive null check

```bash
# Create a Deployment with NO labels at all (not even an empty map)
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: no-labels-at-all
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test
  template:
    metadata:
      labels:
        app: test
    spec:
      containers:
      - name: app
        image: nginx:1.27
EOF
```

**What's happening**: The CEL expression uses `has(object.metadata.labels) && has(object.metadata.labels.owner)`. The first check prevents a null-pointer error when labels are absent entirely. Without it, `has(object.metadata.labels.owner)` would fail on a nil map.

**Expected**: Rejected — no `owner` label.

**Observe**: The defensive `has()` chain is a CEL best practice for nested field access.

---

### 5. Test with dry-run

```bash
# Policies still run in dry-run mode
kubectl apply --dry-run=server -f lab/bad-deploy.yaml
```

**Expected**: Still rejected (policies evaluate even in dry-run).

This is important for CI/CD validation - you can test manifests without actually creating resources.

---

### 6. Check policy status and metrics

```bash
# View policy conditions
kubectl get validatingadmissionpolicy require-owner-label -o jsonpath='{.status.conditions}'

# If API server exposes metrics (requires access to API server metrics endpoint)
# kubectl port-forward -n kube-system pod/kube-apiserver-control-plane 6443:6443
# curl -k https://localhost:6443/metrics | grep apiserver_validating_admission_policy
```

**Observe**: Conditions show if the policy is type-checked and ready.

---

### 7. Scope policy to specific namespaces

```bash
# Create a namespace without the policy
kubectl create namespace dev
kubectl label namespace dev environment=development

# Update binding to only apply to prod namespace
kubectl patch validatingadmissionpolicybinding require-owner-label-binding --type=merge -p '
{
  "spec": {
    "matchResources": {
      "namespaceSelector": {
        "matchLabels": {
          "environment": "production"
        }
      }
    }
  }
}'

# Create prod namespace
kubectl create namespace prod
kubectl label namespace prod environment=production

# Try to create bad deploy in dev (should succeed - policy doesn't apply)
kubectl apply -f lab/bad-deploy.yaml -n dev

# Try to create bad deploy in prod (should fail - policy applies)
kubectl apply -f lab/bad-deploy.yaml -n prod
```

**Observe**: Namespace selectors control policy scope. Policies can be scoped to subsets of the cluster.

---

### 8. Temporarily disable policy

```bash
# Delete the binding (policy still exists but is inactive)
kubectl delete validatingadmissionpolicybinding require-owner-label-binding

# Now bad deploys are allowed
kubectl apply -f lab/bad-deploy.yaml -n prod
```

**Expected**: Deployment created successfully (no binding = no enforcement).

**Restore**:
```bash
kubectl apply -f lab/validating-policy.yaml
```

---

## Cleanup

```bash
kubectl delete deploy --all --all-namespaces
kubectl delete -f lab/validating-policy.yaml
kubectl delete namespace dev prod
```

---

## Key Takeaways

1. **ValidatingAdmissionPolicy** provides in-process validation without external webhooks
2. **CEL expressions** are type-safe and evaluated by the API server
3. **Policy bindings** activate policies and control scope via namespace/object selectors
4. **Validation happens before persistence** - invalid objects never reach etcd
5. **Dry-run mode** still runs policies, useful for CI/CD validation
6. **Namespace selectors** allow progressive rollout (test in dev, enforce in prod)
7. **Policies are declarative** - managed as Kubernetes resources, versionable in Git

## Comparison to External Webhooks

| Feature | ValidatingAdmissionPolicy | External Webhook |
|---------|---------------------------|------------------|
| Latency | <1ms (in-process) | 10-100ms (HTTP) |
| Availability | High (built-in) | Depends on webhook pods |
| Complexity | Low (no certs, services) | High (TLS, deployment) |
| Expressiveness | Limited (CEL only) | Unlimited (full code) |
| External calls | Not possible | Supported |
| Use case | Structural validation | Complex business logic |

## Extension Ideas

- Add parameterized policies that read configuration from ConfigMaps
- Use `auditAnnotations` to log policy decisions without blocking requests
- Combine with mutating webhooks (policy validates, webhook fixes)
- Integrate policy violations into monitoring/alerting
