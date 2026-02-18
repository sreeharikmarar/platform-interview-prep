# Lab: Agentic Workflows — Ingress to Gateway API Migration

This lab walks through the structured process an automated agent would follow to migrate Ingress resources to Gateway API HTTPRoutes. You'll practice the observe-plan-act-verify pattern with safety gates at each step, building the same muscle memory a production migration agent would use.

## Prerequisites

- kind installed
- kubectl 1.28+
- jq installed
- Gateway API CRDs installed (instructions below)
- Basic familiarity with Ingress and HTTPRoute resources

## Setup

### 1. Start the cluster and install Gateway API CRDs

```bash
# Create a kind cluster
./scripts/kind-up.sh prep

# Install Gateway API CRDs (standard channel)
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml

# Verify CRDs are installed
kubectl get crd | grep gateway
```

**What's happening**: Gateway API CRDs (GatewayClass, Gateway, HTTPRoute, ReferenceGrant) are installed into the cluster. These are the target resources our migration agent will produce.

**Verification**:
```bash
kubectl get crd httproutes.gateway.networking.k8s.io
# Should show: httproutes.gateway.networking.k8s.io   ...   Established
```

---

### 2. Create a GatewayClass and Gateway

```bash
# Create a GatewayClass (using the example implementation)
kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: example
spec:
  controllerName: example.com/gateway-controller
EOF

# Create a Gateway that HTTPRoutes will attach to
kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: main-gateway
  namespace: default
spec:
  gatewayClassName: example
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: Same
    - name: https
      protocol: HTTPS
      port: 443
      tls:
        mode: Terminate
        certificateRefs:
          - name: static-tls-secret
      allowedRoutes:
        namespaces:
          from: Same
EOF
```

**What's happening**: We create the Gateway infrastructure that HTTPRoutes will attach to. This is the equivalent of the IngressClass + controller that Ingress resources reference.

**Verification**:
```bash
kubectl get gateway main-gateway
kubectl get gatewayclass example
```

---

### 3. Apply the sample Ingress resources (the "existing state")

```bash
kubectl apply -f lab/sample-ingress.yaml
```

**What's happening**: Three Ingress resources are created representing typical production configurations:
- `app-frontend`: Simple host-based routing to a frontend service
- `app-api`: Multi-path routing to versioned API backends (v1, v2) with CORS
- `app-static`: TLS-terminated routing with caching annotations

**Observe**: Note the nginx-specific annotations — these represent configuration that must be translated to Gateway API equivalents or documented as requiring separate handling.

**Verification**:
```bash
kubectl get ingress
# Should show 3 Ingress resources

# Inspect the annotations (these are what the agent must handle)
kubectl get ingress -o json | jq '.items[] | {name: .metadata.name, annotations: .metadata.annotations}'
```

---

### 4. Phase 1: Discovery — List and extract Ingress configurations

```bash
# Discovery script: extract structured data from all Ingress resources
kubectl get ingress -o json | jq '[.items[] | {
  name: .metadata.name,
  namespace: .metadata.namespace,
  annotations: .metadata.annotations,
  tls: (.spec.tls // []),
  rules: [.spec.rules[] | {
    host: .host,
    paths: [.http.paths[] | {
      path: .path,
      pathType: .pathType,
      serviceName: .backend.service.name,
      servicePort: .backend.service.port.number
    }]
  }]
}]' > /tmp/ingress-discovery.json

# Review the discovery output
cat /tmp/ingress-discovery.json | jq .
```

**What's happening**: This is the "observe" phase. The agent reads all existing Ingress resources and extracts a structured representation. In a production agent, this would be a tool call that returns structured JSON for the LLM to reason about.

**Observe**: The output should show 3 entries with their hosts, paths, backends, and annotations. Note which annotations have Gateway API equivalents (ssl-redirect, timeouts) and which don't (configuration-snippet).

**Verification**:
```bash
# Count discovered resources
cat /tmp/ingress-discovery.json | jq 'length'
# Should output: 3

# List all unique annotations that need translation
cat /tmp/ingress-discovery.json | jq '[.[].annotations | keys[]] | unique'
```

---

### 5. Phase 2: Translation — Convert Ingress to HTTPRoute

```bash
# Translation script: generate HTTPRoute YAML from discovery data
cat /tmp/ingress-discovery.json | jq -r '.[] | "---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: \(.name)-route
  namespace: \(.namespace)
  labels:
    migrated-from: ingress
    original-ingress: \(.name)
spec:
  parentRefs:
    - name: main-gateway
      namespace: default
  hostnames:
    - \(.rules[0].host)
  rules:" + ([.rules[].paths[] | "    - matches:
        - path:
            type: \(if .pathType == "Exact" then "Exact" else "PathPrefix" end)
            value: \(.path)
      backendRefs:
        - name: \(.serviceName)
          port: \(.servicePort)"] | join("\n"))' > /tmp/httproutes.yaml

# Review the generated HTTPRoutes
cat /tmp/httproutes.yaml
```

**What's happening**: This is the "plan" phase. The agent translates each Ingress into an equivalent HTTPRoute. Key translation decisions:
- `pathType: Prefix` becomes `type: PathPrefix`
- `pathType: Exact` becomes `type: Exact`
- `parentRefs` replaces `ingressClassName`
- Labels track the migration origin for rollback

**Observe**: The generated YAML should have 3 HTTPRoute resources. Some annotations (CORS, timeouts) are not translated — these would need HTTPRoute filters or policy attachments.

**Verification**:
```bash
# Count generated HTTPRoutes
grep -c "kind: HTTPRoute" /tmp/httproutes.yaml
# Should output: 3
```

---

### 6. Phase 3: Validate — Dry-run apply before committing

```bash
# Server-side dry-run validates against the cluster's API schema
kubectl apply --dry-run=server -f /tmp/httproutes.yaml 2>&1
```

**What's happening**: This is the safety gate between "plan" and "act." The dry-run sends the resources to the API server for full validation (schema, admission webhooks) without persisting them. If any HTTPRoute is invalid, the error appears here rather than in production.

**Observe**: All 3 HTTPRoutes should pass validation. If any fail, the error message tells you what to fix in the translation logic.

**Expected output**:
```
httproute.gateway.networking.k8s.io/app-frontend-route created (server dry run)
httproute.gateway.networking.k8s.io/app-api-route created (server dry run)
httproute.gateway.networking.k8s.io/app-static-route created (server dry run)
```

**Verification**:
```bash
# Ensure no errors in the dry-run output
kubectl apply --dry-run=server -f /tmp/httproutes.yaml 2>&1 | grep -c "error"
# Should output: 0
```

---

### 7. Phase 4: Apply — Create HTTPRoutes alongside existing Ingress

```bash
# Apply the translated HTTPRoutes
kubectl apply -f /tmp/httproutes.yaml

# Verify they exist alongside the Ingress resources
kubectl get httproutes
kubectl get ingress
```

**What's happening**: The agent applies the new HTTPRoutes without deleting the old Ingress resources. This is the "canary" approach — both configurations coexist until the HTTPRoutes are verified, then the Ingress resources are removed. In a production migration, traffic would shift gradually.

**Observe**: Both Ingress and HTTPRoute resources should be listed. The `migrated-from: ingress` label makes it easy to identify which HTTPRoutes came from the migration.

**Verification**:
```bash
# Check HTTPRoutes have the migration labels
kubectl get httproutes -l migrated-from=ingress
# Should show all 3 routes

# Inspect a specific HTTPRoute
kubectl get httproute app-api-route -o yaml
```

---

### 8. Phase 5: Verify — Confirm the migration is correct

```bash
# Compare Ingress hosts with HTTPRoute hostnames
echo "=== Ingress Hosts ==="
kubectl get ingress -o jsonpath='{range .items[*]}{.metadata.name}: {.spec.rules[*].host}{"\n"}{end}'

echo ""
echo "=== HTTPRoute Hostnames ==="
kubectl get httproutes -o jsonpath='{range .items[*]}{.metadata.name}: {.spec.hostnames[*]}{"\n"}{end}'

# Compare backend references
echo ""
echo "=== Ingress Backends ==="
kubectl get ingress -o json | jq '.items[] | {name: .metadata.name, backends: [.spec.rules[].http.paths[] | "\(.backend.service.name):\(.backend.service.port.number)"]}'

echo ""
echo "=== HTTPRoute Backends ==="
kubectl get httproutes -o json | jq '.items[] | {name: .metadata.name, backends: [.spec.rules[].backendRefs[] | "\(.name):\(.port)"]}'
```

**What's happening**: The agent verifies that every Ingress host/path/backend combination has a corresponding HTTPRoute entry. In production, you'd also run traffic tests (curl through the new gateway) and compare response codes.

**Observe**: Hosts and backends should match 1:1 between Ingress and HTTPRoute resources.

---

### 9. Document the rollback plan

```bash
# The rollback is straightforward because we didn't delete the Ingress resources
echo "=== Rollback Plan ==="
echo "1. Delete all migrated HTTPRoutes:"
echo "   kubectl delete httproutes -l migrated-from=ingress"
echo ""
echo "2. Verify Ingress resources are still intact:"
echo "   kubectl get ingress"
echo ""
echo "3. Verify traffic is flowing through Ingress (if gateway controller was active):"
echo "   curl -H 'Host: app.example.com' http://<ingress-ip>/"

# Test the rollback (non-destructive — just verify the selector works)
kubectl get httproutes -l migrated-from=ingress --no-headers | wc -l
# Should output: 3 (confirming the label selector catches all migrated routes)
```

**What's happening**: Every agent action should have a documented rollback. Because we kept the Ingress resources during migration, rollback is simply deleting the HTTPRoutes. The `migrated-from: ingress` label makes this a single command.

---

## Cleanup

```bash
# Remove migrated HTTPRoutes
kubectl delete httproutes -l migrated-from=ingress

# Remove original Ingress resources
kubectl delete -f lab/sample-ingress.yaml

# Remove Gateway and GatewayClass
kubectl delete gateway main-gateway
kubectl delete gatewayclass example

# Remove Gateway API CRDs (optional)
kubectl delete -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml

# Or tear down the entire cluster
kind delete cluster --name prep
```

---

## Key Takeaways

1. **Observe before acting**: The discovery phase builds a complete picture of existing state before any changes are made — an agent should never modify resources it hasn't fully inventoried.
2. **Dry-run is the critical safety gate**: Server-side dry-run catches schema errors, missing references, and admission policy violations without any side effects.
3. **Coexistence before cutover**: Applying new resources alongside old ones (rather than replacing) gives you a rollback path and allows gradual traffic shifting.
4. **Labels enable rollback**: Tagging migrated resources with their origin makes it trivial to identify and revert an entire migration with a single label selector.
5. **Annotations don't translate 1:1**: Nginx-specific annotations (configuration-snippet, CORS) require Gateway API policy attachments or filters — a production agent must flag these for manual review.
6. **The agent pattern maps to K8s controllers**: Observe (list resources) -> Plan (translate) -> Act (apply with dry-run gate) -> Verify (compare state) -> Reconcile (retry or escalate) is the same pattern as a Kubernetes controller's reconcile loop.
