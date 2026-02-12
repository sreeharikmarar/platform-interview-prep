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

**What's happening**: This creates a policy with CEL expressions that validate Deployment resources. The policy checks:
- Deployment must have a `team` label
- Replica count must not exceed 10
- Container images must not use `latest` tag

**Verification**:
```bash
kubectl get validatingadmissionpolicy
kubectl get validatingadmissionpolicy require-labels -o yaml
```

Expected: Policy is created with status showing it's been compiled successfully.

---

### 2. Create a policy binding

```bash
kubectl apply -f lab/policy-binding.yaml
```

**What's happening**: The binding activates the policy for specific resources. It specifies:
- Which policy to use (policyName: require-labels)
- Which namespaces it applies to (via namespaceSelector)
- What action to take on violation (validationActions: [Deny])

Without a binding, policies are inactive.

**Verification**:
```bash
kubectl get validatingadmissionpolicybinding
kubectl describe validatingadmissionpolicybinding require-labels-binding
```

---

### 3. Try to create a Deployment without required label

```bash
kubectl apply -f lab/bad-deploy.yaml
```

**What's happening**: This Deployment manifest is missing the `team` label. The admission policy's CEL expression `has(object.metadata.labels.team)` evaluates to false, causing denial.

**Expected output**:
```
Error from server (Forbidden): admission webhook "validating.admission.policy.k8s.io" denied the request: ValidatingAdmissionPolicy 'require-labels' with binding 'require-labels-binding' denied request: Deployment must have 'team' label
```

**Observe**: The request was rejected at admission time, before persisting to etcd.

---

### 4. Create a Deployment with required label

```bash
kubectl apply -f lab/good-deploy.yaml
```

**What's happening**: This manifest includes `team: platform` label and uses a tagged image (not `latest`). All CEL validations pass.

**Expected**: Deployment created successfully.

**Verification**:
```bash
kubectl get deploy good-deploy -o jsonpath='{.metadata.labels.team}'
# Should output: platform

kubectl get deploy good-deploy -o jsonpath='{.spec.template.spec.containers[0].image}'
# Should output: nginx:1.25 (not latest)
```

---

### 5. Test replica count validation

```bash
# Try to create a Deployment with 15 replicas (exceeds limit of 10)
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: too-many-replicas
  labels:
    team: platform
spec:
  replicas: 15
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:1.25
EOF
```

**Expected output**:
```
Error: ... denied request: Deployments cannot exceed 10 replicas
```

**Observe**: The CEL expression `object.spec.replicas <= 10` evaluated to false.

---

### 6. Test image tag validation

```bash
# Try to use 'latest' tag
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: latest-tag
  labels:
    team: platform
spec:
  replicas: 3
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:latest
EOF
```

**Expected output**:
```
Error: ... denied request: Container images must not use 'latest' tag
```

**Observe**: CEL expression validates image tags across all containers.

---

### 7. Test with dry-run

```bash
# Policies still run in dry-run mode
kubectl apply --dry-run=server -f lab/bad-deploy.yaml
```

**Expected**: Still rejected (policies evaluate even in dry-run).

This is important for CI/CD validation - you can test manifests without actually creating resources.

---

### 8. Check policy status and metrics

```bash
# View policy conditions
kubectl get validatingadmissionpolicy require-labels -o jsonpath='{.status.conditions}'

# If API server exposes metrics (requires access to API server metrics endpoint)
# kubectl port-forward -n kube-system pod/kube-apiserver-control-plane 6443:6443
# curl -k https://localhost:6443/metrics | grep apiserver_validating_admission_policy
```

**Observe**: Conditions show if the policy is type-checked and ready.

---

### 9. Scope policy to specific namespaces

```bash
# Create a namespace without the policy
kubectl create namespace dev
kubectl label namespace dev environment=development

# Update binding to only apply to prod namespace
kubectl patch validatingadmissionpolicybinding require-labels-binding --type=merge -p '
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

### 10. Temporarily disable policy

```bash
# Delete the binding (policy still exists but is inactive)
kubectl delete validatingadmissionpolicybinding require-labels-binding

# Now bad deploys are allowed
kubectl apply -f lab/bad-deploy.yaml -n prod
```

**Expected**: Deployment created successfully (no binding = no enforcement).

**Restore**:
```bash
kubectl apply -f lab/policy-binding.yaml
```

---

## Cleanup

```bash
kubectl delete deploy --all --all-namespaces
kubectl delete validatingadmissionpolicybinding require-labels-binding
kubectl delete validatingadmissionpolicy require-labels
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
