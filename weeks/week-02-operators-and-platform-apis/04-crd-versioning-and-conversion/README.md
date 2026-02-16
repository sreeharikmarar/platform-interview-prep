# CRD Versioning & Conversion Webhooks

## What you should be able to do

- Explain the difference between served versions and storage version
- Design backwards-compatible schema changes and plan migration paths
- Implement conversion webhooks for non-compatible changes
- Understand round-trip conversion requirements and test for fidelity
- Debug conversion webhook failures and storage version migration issues

## Mental model

CRD evolution is API evolution. Just like Kubernetes core APIs (Deployment v1beta1 → v1), your CRDs will evolve over time. The API server stores all resources in a single storage version in etcd but can serve multiple versions to clients. When a client requests a version different from storage, the API server converts on the fly. For simple structural changes, the API server does conversion automatically. For complex changes, you must provide a conversion webhook. The critical constraint: conversions must be round-trip safe—converting v1→v2→v1 must yield the original object, or you'll lose data.

## Internals

### Storage Version vs Served Versions

A CRD can declare multiple versions in its spec. Exactly one version is marked as the **storage version** (`storage: true`). This is the version persisted to etcd. All other versions are **served versions** (`storage: false`) that clients can read and write.

When a client creates a resource using v1alpha1, the API server:
1. Validates the request against the v1alpha1 schema
2. Converts v1alpha1 to the storage version (if different)
3. Persists the storage version to etcd
4. Returns the object in the requested version (converting back if necessary)

Example CRD with multiple versions:

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: gateways.networking.example.com
spec:
  group: networking.example.com
  names:
    kind: Gateway
    plural: gateways
  scope: Namespaced
  versions:
  - name: v1alpha1
    served: true
    storage: false  # Not the storage version
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            properties:
              host:
                type: string
              port:
                type: integer
  - name: v1beta1
    served: true
    storage: true  # This is the storage version
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            properties:
              listeners:
                type: array
                items:
                  type: object
                  properties:
                    hostname:
                      type: string
                    port:
                      type: integer
  conversion:
    strategy: Webhook
    webhook:
      clientConfig:
        service:
          name: gateway-conversion-webhook
          namespace: gateway-system
          path: /convert
      conversionReviewVersions: ["v1"]
```

In this example, v1alpha1 had a single `host:port` pair. v1beta1 changed to a `listeners` array to support multiple hostnames. This is a non-compatible change requiring a webhook.

### Conversion Strategies

**None (default):** Only one version exists. No conversion needed.

**Automatic structural conversion:** For compatible changes where fields are added/removed but the structure is similar, the API server can convert automatically. This works when:
- Fields are added with defaults
- Fields are removed (data is dropped)
- Field names change but types are identical

Automatic conversion is limited. It doesn't handle:
- Restructuring (single field → array, or vice versa)
- Renaming with transformation (host → listeners[0].hostname)
- Semantic changes (splitting one field into two)

**Webhook conversion:** For complex changes, you deploy a webhook that receives a ConversionReview request containing the object in one version and returns it in another version.

### Conversion Webhook Protocol

The API server calls your webhook with a POST request containing a `ConversionReview`:

```json
{
  "apiVersion": "apiextensions.k8s.io/v1",
  "kind": "ConversionReview",
  "request": {
    "uid": "unique-id",
    "desiredAPIVersion": "networking.example.com/v1beta1",
    "objects": [
      {
        "apiVersion": "networking.example.com/v1alpha1",
        "kind": "Gateway",
        "metadata": {...},
        "spec": {
          "host": "example.com",
          "port": 443
        }
      }
    ]
  }
}
```

Your webhook must return a `ConversionReview` with converted objects:

```json
{
  "apiVersion": "apiextensions.k8s.io/v1",
  "kind": "ConversionReview",
  "response": {
    "uid": "unique-id",
    "result": {"status": "Success"},
    "convertedObjects": [
      {
        "apiVersion": "networking.example.com/v1beta1",
        "kind": "Gateway",
        "metadata": {...},
        "spec": {
          "listeners": [
            {"hostname": "example.com", "port": 443}
          ]
        }
      }
    ]
  }
}
```

The webhook must handle conversion in **both directions**: v1alpha1→v1beta1 and v1beta1→v1alpha1. Bidirectional conversion is required for round-trip fidelity.

### Round-Trip Fidelity

Round-trip fidelity means converting A→B→A produces the original A. This is critical because:
- Clients may read in one version and write in another
- The API server may convert multiple times during a single request
- Loss of data breaks controllers and user workflows

Example of **broken** round-trip:

```
v1alpha1: {host: "example.com", port: 443}
  ↓ convert to v1beta1
v1beta1: {listeners: [{hostname: "example.com", port: 443}]}
  ↓ convert back to v1alpha1
v1alpha1: {host: "example.com", port: 443}  ✅ Identical

v1beta1: {listeners: [{hostname: "a.com", port: 80}, {hostname: "b.com", port: 443}]}
  ↓ convert to v1alpha1
v1alpha1: {host: "a.com", port: 80}  ❌ Lost second listener!
  ↓ convert to v1beta1
v1beta1: {listeners: [{hostname: "a.com", port: 80}]}  ❌ Data loss
```

To preserve round-trip fidelity, use **annotations** to store data that doesn't fit in the target version:

```go
// Converting v1beta1 → v1alpha1 with data preservation
func convertV1beta1ToV1alpha1(in *v1beta1.Gateway) *v1alpha1.Gateway {
    out := &v1alpha1.Gateway{
        Spec: v1alpha1.GatewaySpec{
            Host: in.Spec.Listeners[0].Hostname,
            Port: in.Spec.Listeners[0].Port,
        },
    }

    // Store extra listeners in annotation for round-trip
    if len(in.Spec.Listeners) > 1 {
        extraListeners, _ := json.Marshal(in.Spec.Listeners[1:])
        out.Annotations = map[string]string{
            "gateway.example.com/extra-listeners": string(extraListeners),
        }
    }

    return out
}

// Converting v1alpha1 → v1beta1, restoring from annotation
func convertV1alpha1ToV1beta1(in *v1alpha1.Gateway) *v1beta1.Gateway {
    out := &v1beta1.Gateway{
        Spec: v1beta1.GatewaySpec{
            Listeners: []v1beta1.Listener{
                {Hostname: in.Spec.Host, Port: in.Spec.Port},
            },
        },
    }

    // Restore extra listeners from annotation
    if extra, ok := in.Annotations["gateway.example.com/extra-listeners"]; ok {
        var extraListeners []v1beta1.Listener
        json.Unmarshal([]byte(extra), &extraListeners)
        out.Spec.Listeners = append(out.Spec.Listeners, extraListeners...)
        delete(out.Annotations, "gateway.example.com/extra-listeners")
    }

    return out
}
```

This ensures no data is lost during conversion, even when moving between incompatible schemas.

### Storage Version Migration

When you change the storage version, existing objects in etcd remain in the old version until they're updated. This creates a mixed-version state. To migrate all objects to the new storage version:

1. Deploy the new CRD with the new storage version
2. Use the **storage version migrator** controller (kubernetes-sigs/kube-storage-version-migrator) to rewrite all objects
3. Alternatively, write a migration script that reads and writes each object, triggering conversion

Example migration script:

```bash
# Trigger storage migration by updating all objects
kubectl get gateways --all-namespaces -o json | \
  jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"' | \
  while read ns name; do
    kubectl get gateway -n "$ns" "$name" -o json | \
      kubectl replace -f -
  done
```

This reads each Gateway, then writes it back. The API server converts it to the new storage version on write.

## Failure modes & debugging

### Conversion Webhook Outage

If the webhook is unavailable, all reads and writes to the CRD fail. Clients get errors like:

```
Error from server: conversion webhook for networking.example.com/v1alpha1 failed: Post "https://gateway-conversion-webhook.gateway-system.svc:443/convert": dial tcp: connection refused
```

This is a **critical failure**. Even reading existing objects fails because the API server must convert them to the requested version. Mitigation:
- Run the webhook with multiple replicas and PodDisruptionBudget
- Monitor webhook latency and availability
- Have a rollback plan: change CRD conversion strategy back to `None` if webhook is broken

### Non-Lossy Conversion Failures

If your webhook doesn't preserve round-trip fidelity, users will lose data silently. Example:

```
User creates Gateway with 3 listeners in v1beta1
Controller reads it in v1alpha1 → only sees 1 listener (lost 2)
Controller updates status in v1alpha1
API server writes back to storage in v1beta1 → only 1 listener persisted
```

Detecting this requires testing. Write tests that convert objects in both directions and assert equality:

```go
func TestRoundTripFidelity(t *testing.T) {
    original := &v1beta1.Gateway{
        Spec: v1beta1.GatewaySpec{
            Listeners: []v1beta1.Listener{
                {Hostname: "a.com", Port: 80},
                {Hostname: "b.com", Port: 443},
            },
        },
    }

    // Convert v1beta1 → v1alpha1 → v1beta1
    v1alpha1Obj := convertV1beta1ToV1alpha1(original)
    roundTrip := convertV1alpha1ToV1beta1(v1alpha1Obj)

    if !reflect.DeepEqual(original, roundTrip) {
        t.Errorf("Round-trip conversion lost data: original=%+v, roundTrip=%+v", original, roundTrip)
    }
}
```

### Webhook Timeout or Latency

Webhook calls are synchronous and block API requests. If the webhook is slow, user requests timeout. Default timeout is 10 seconds. Monitor webhook duration and optimize conversion logic. Avoid expensive operations like external API calls inside the webhook.

### Incompatible Schema Changes

If you change the schema in a served version without updating the conversion webhook, validation fails. Example:

```
User creates Gateway in v1alpha1 with the old schema
Webhook converts to v1beta1
API server validates against new v1beta1 schema → validation error
```

Always update the conversion webhook before deploying CRD schema changes. Use a staged rollout:
1. Deploy new webhook with logic to handle old and new schemas
2. Deploy new CRD with updated schemas
3. Verify clients can use both versions
4. Deprecate old version after a grace period

## Interview Signals

**Strong candidates will:**
- Explain storage version vs served versions clearly
- Discuss round-trip fidelity and why it matters
- Describe webhook architecture and failure modes
- Relate this to long-lived platform APIs (like Kubernetes Gateway API evolution)
- Mention storage version migration and testing strategies

**Red flags:**
- Confusing storage version with served versions
- Not understanding that webhook failure breaks reads, not just writes
- Missing the importance of round-trip testing
- No migration plan when changing storage version

## Common Pitfalls

1. **Forgetting round-trip annotations:** Leads to silent data loss
2. **Deploying CRD before webhook is ready:** All requests fail until webhook is available
3. **Not testing conversion in both directions:** Subtle bugs appear in production
4. **Changing storage version without migrating existing objects:** Mixed-version state causes confusion
5. **Webhook has no HA:** Single replica restart causes API unavailability
6. **Tight coupling between webhook and API server version:** Webhook breaks during cluster upgrades

## Key Takeaways

- CRD versioning allows API evolution while maintaining backwards compatibility
- One storage version in etcd, multiple served versions for clients
- Conversion webhooks handle complex transformations between versions
- Round-trip fidelity is mandatory—test extensively
- Webhook outages block all API access, so run with HA and monitoring
- Storage version migration requires rewriting all existing objects
- Plan versioning strategy upfront for long-lived platform APIs
