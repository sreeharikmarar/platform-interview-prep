# Lab: Service Identity Propagation & Isolation Boundaries

This lab is a structured analysis and design exercise. No running cluster is required for steps 1–4. Step 5 requires `kubectl` and `istioctl` with access to an Istio-enabled cluster. The primary outputs are a documented principal propagation trace, a threat model table, and a set of AuthorizationPolicy resources.

## Prerequisites

- Familiarity with SPIFFE identity and Istio mTLS concepts (see topic README)
- `kubectl` and `istioctl` installed (for step 5)
- `openssl` installed (for certificate inspection commands)
- Review `mtls-config.yaml` in this directory before starting — it contains the Istio resources referenced in steps 4 and 5

## Topology for This Lab

You are a platform engineer for a three-service application with the following request path:

```
  external client (OIDC JWT bearer token)
       │
       │ HTTPS (JWT in Authorization header)
       ▼
  INGRESS GATEWAY (ns: istio-system, sa: istio-ingressgateway)
  - Validates JWT via RequestAuthentication
  - Terminates downstream TLS
  - Originates new mTLS to service-a
  - Injects XFCC header: URI=spiffe://cluster.local/ns/team-a/sa/service-a
       │
       │ mTLS (Envoy SVID: istio-ingressgateway)
       │ HTTP headers: Authorization (JWT), XFCC
       ▼
  SERVICE-A (ns: team-a, sa: service-a)
  - AuthorizationPolicy: source.principal = istio-ingressgateway
  - AuthorizationPolicy: request.auth.claims[role] = "admin"
  - Originates mTLS to service-b as itself
       │
       │ mTLS (Envoy SVID: service-a)
       │ HTTP headers: JWT forwarded
       ▼
  SERVICE-B (ns: team-b, sa: service-b)
  - AuthorizationPolicy: source.principal = service-a
  - AuthorizationPolicy: request.auth.claims[scope] = "payments.write"
```

---

## Step 1: Inspect SVID Certificates

Use the commands below to understand what a workload certificate looks like and how to extract the SPIFFE ID from it. This step can be run against any Istio-proxied pod in a live cluster, or analyzed against the example output provided below.

```bash
# Dump the workload certificate (X.509-SVID) for service-a
# The "-o json" flag gives you the raw base64-encoded certificate bytes
istioctl proxy-config secret deploy/service-a.team-a -o json | \
  jq -r '.dynamicActiveSecrets[] | select(.name == "default") |
  .secret.tlsCertificate.certificateChain.inlineBytes' | \
  base64 -d | openssl x509 -noout -text

# What to look for in the output:
#   Subject: O=<trust-domain>
#   X509v3 Subject Alternative Name:
#     URI:spiffe://cluster.local/ns/team-a/sa/service-a
#   Validity:
#     Not Before: ...
#     Not After:  ...  (should be ~24h from Not Before)
#   Issuer: O=cluster.local  (the istiod intermediate CA)

# Dump the trust bundle (ROOTCA) to see which CAs are trusted
istioctl proxy-config secret deploy/service-a.team-a -o json | \
  jq -r '.dynamicActiveSecrets[] | select(.name == "ROOTCA") |
  .secret.validationContext.trustedCa.inlineBytes' | \
  base64 -d | openssl x509 -noout -subject -issuer -fingerprint

# Compare the issuer fingerprint across two pods to confirm they share a root CA
# If fingerprints differ, you have a trust bundle mismatch

# Check certificate expiry programmatically
istioctl proxy-config secret deploy/service-a.team-a -o json | \
  jq -r '.dynamicActiveSecrets[] | select(.name == "default") |
  .secret.tlsCertificate.certificateChain.inlineBytes' | \
  base64 -d | openssl x509 -noout -enddate
# Output: notAfter=Feb 18 10:00:00 2026 GMT
# Alert threshold: if this is within 2 hours of now, SDS rotation may have failed

# Check what the ingress gateway's SVID looks like
# This is the identity it presents to upstreams when forwarding requests
istioctl proxy-config secret deploy/istio-ingressgateway.istio-system -o json | \
  jq -r '.dynamicActiveSecrets[] | select(.name == "default") |
  .secret.tlsCertificate.certificateChain.inlineBytes' | \
  base64 -d | openssl x509 -noout -text | grep "URI:"
# Expected: URI:spiffe://cluster.local/ns/istio-system/sa/istio-ingressgateway
```

**What to record**: For each workload in the topology, note its SPIFFE URI, its cert issuer, and its `notAfter` timestamp. Confirm all three use the same root CA fingerprint.

---

## Step 2: Trace Principal Propagation Across the 3-Hop Request Path

For each hop in the topology, answer the three questions below. Write your answers in a table.

**The request path:**
```
external client → ingress gateway → service-a → service-b
     hop 0              hop 1          hop 2       hop 3
```

**Questions for each hop:**

| Hop | Who connects to whom? | What identity (SVID) is presented? | What does the XFCC header contain? | What does AuthorizationPolicy evaluate? |
|-----|----------------------|-----------------------------------|-----------------------------------|----------------------------------------|
| 0→1 | external client → ingress gateway | no mTLS (public client, JWT only) | no XFCC (external connection) | JWT validated by RequestAuthentication |
| 1→2 | ingress gateway → service-a | gateway SVID: `spiffe://.../istio-system/sa/istio-ingressgateway` | XFCC injected: `URI=spiffe://.../ns/external-client` (from JWT sub claim) or empty if no downstream cert | source.principal = gateway SA; request.auth.principal = JWT sub |
| 2→3 | service-a → service-b | service-a SVID: `spiffe://.../ns/team-a/sa/service-a` | XFCC injected by service-a's sidecar: `URI=spiffe://.../ns/team-a/sa/service-a` | source.principal = service-a SA; request.auth.claims[scope] |

**Questions to answer for each hop:**

1. Which mTLS session carries which SVID? Is the originating workload's identity preserved or replaced?
2. If the XFCC header is present, is it set by the gateway or by a sidecar? What prevents a client from forging it?
3. What does `AuthorizationPolicy` actually see as `source.principal` — the true originator or the last hop's identity?

**Key insight**: Only the direct peer's mTLS identity is cryptographically provable at each hop. XFCC carries the prior hop's identity as an HTTP header — it is trustworthy only if the injecting gateway was configured with `SANITIZE_SET` and only for the specific hop relationship. A request that crosses three gateways can only reliably assert the identity of the immediately preceding gateway via mTLS; all prior identities in the chain depend on trusting each intermediate hop's XFCC handling.

---

## Step 3: Threat Model Exercise

For each attack vector below, identify: what the attacker can accomplish, what mitigates it, and whether you can detect it in access logs or metrics.

**Attack vector 1: External client injects XFCC header**
- Attacker sends: `GET /api/data HTTP/1.1` with `x-forwarded-client-cert: URI=spiffe://cluster.local/ns/kube-system/sa/admin`
- What happens if gateway has `forward_client_cert_details: FORWARD_ONLY`?
- What happens if gateway has `forward_client_cert_details: SANITIZE_SET`?
- Detection signal: compare `%REQ(x-forwarded-client-cert)%` in gateway access log vs value at upstream

**Attack vector 2: Gateway does not propagate XFCC (confused deputy)**
- Service-a's AuthorizationPolicy requires `source.principal = "cluster.local/ns/frontend/sa/frontend-sa"`
- Ingress gateway presents its own SVID: `cluster.local/ns/istio-system/sa/istio-ingressgateway`
- What is the user-visible impact? (403? 200? fallback to another policy?)
- What `%RESPONSE_CODE_DETAILS%` value appears in the upstream access log?
- What is the correct fix, and what are the trade-offs of each fix option?

**Attack vector 3: Trust bundle is stale after CA rotation**
- Cluster-a rotates its intermediate CA but does not update the `caCertificates` in cluster-b's `MeshConfig`
- Cluster-b's trust bundle still has the old root CA; new cluster-a SVIDs are signed by the new intermediate
- In `PeerAuthentication: STRICT`: what happens immediately? what happens after 24 hours (when certs rotate)?
- In `PeerAuthentication: PERMISSIVE`: what happens? is it detectable?
- What metric would alert you before traffic is affected?

**Attack vector 4: Compromised sidecar injects arbitrary claims**
- An attacker gains code execution in the sidecar container of service-a
- They attempt to modify the XFCC header before it reaches service-b
- Is this possible? (hint: the sidecar's Envoy controls header injection; the application cannot modify XFCC after injection)
- What does the threat boundary look like between the application process and the Envoy sidecar?

---

## Step 4: Isolation Boundary Design Exercise

**Scenario**: You are the platform engineer for an organization with the following structure:

```
  Organization: example-corp
  ├── Team Alpha: e-commerce frontend, product catalog
  │   - Compliance: no special requirements
  │   - Deployment: cluster-1 (us-east-1)
  │
  ├── Team Beta: payment processing, fraud detection
  │   - Compliance: PCI DSS scope (must be isolated from non-PCI workloads)
  │   - Deployment: cluster-1 (us-east-1) and cluster-2 (us-west-2)
  │
  └── Team Gamma: data analytics, ML pipeline
      - Compliance: no special requirements, but cannot read payment data directly
      - Deployment: cluster-2 (us-west-2)
```

**Design task**: For each of the four boundary types, decide whether a boundary is needed, where it should be placed, and what it protects.

| Boundary type | Needed? | Where? | Protects against |
|--------------|---------|--------|-----------------|
| xDS (separate istiod) | Yes — Beta needs separate istiod | Separate istiod revision for `pci` namespaces | A bad VirtualService in Alpha's namespace cannot affect Beta's routing |
| CA (separate intermediate) | Yes — Beta needs separate intermediate CA | Separate `cacerts` for the PCI istiod revision | A compromise of Alpha's CA cannot issue valid SVIDs for Beta's workloads |
| Trust domain | Consider — depends on whether Alpha↔Beta mTLS should be explicitly permitted | Separate trust domain (`pci.example-corp`) for Beta | All cross-domain traffic requires explicit AuthorizationPolicy; no implicit trust |
| Ownership (namespace + RBAC) | Yes — all teams | Separate namespaces, RBAC preventing cross-team resource modification | Team Alpha cannot modify Team Beta's AuthorizationPolicy or VirtualService |

**Questions to answer**:

1. Should Team Beta's PCI workloads use a separate trust domain or a separate CA under the same trust domain? What is the operational difference?
   - Separate trust domain: all cross-domain calls require `MeshConfig.trustDomainAliases` configuration AND explicit AuthorizationPolicy. Maximally strict. Hard to add new permitted callers.
   - Separate CA under same trust domain: cross-cluster mTLS works transparently (same root CA). Policy is enforced via AuthorizationPolicy only. Easier to operate; CA compromise has broader blast radius within the trust domain.

2. Team Gamma needs read access to aggregate (non-PII) payment statistics from Team Beta's analytics export API. How do you express this cross-boundary permission without granting Gamma access to Beta's raw payment processing endpoints?
   - Use `AuthorizationPolicy` on Beta's analytics-export service: allow `source.principal` = `cluster.local/ns/gamma/sa/analytics-sa` with HTTP path prefix `/api/v1/stats/aggregate`
   - Deny all other paths and methods explicitly with a `DENY` policy
   - Use `Sidecar` resource in Gamma's namespace to restrict egress to only the analytics-export service (not payment-processing or fraud-detection)

3. Write the `Sidecar` resource for Team Gamma's namespace that limits egress to only the services Gamma is permitted to call.

```yaml
# Sidecar resource limiting Team Gamma's egress destinations
# This limits the xDS config pushed to Gamma's sidecars to only the permitted services
# Reduces config volume AND prevents Gamma from discovering Beta's internal service topology
apiVersion: networking.istio.io/v1beta1
kind: Sidecar
metadata:
  name: gamma-egress-scope
  namespace: gamma
spec:
  egress:
  - hosts:
    # Allow calls to own namespace
    - "gamma/*"
    # Allow calls to Beta's analytics export only (not payment-processing or fraud-detection)
    - "beta/analytics-export.beta.svc.cluster.local"
    # Allow calls to istio-system for health checks and telemetry
    - "istio-system/*"
```

---

## Step 5: Write AuthorizationPolicy Rules for Fine-Grained Access Control

Open `mtls-config.yaml` in this directory. It contains the full set of Istio resources for the topology. Study the existing `AuthorizationPolicy` resources, then complete the following exercises.

**Exercise 5a: Combine mTLS peer identity and JWT claims**

Service-b needs to allow only requests where:
- The mTLS peer is `service-a` (from namespace `team-a`)
- AND the JWT carries a claim `scope` containing `payments.write`
- AND the HTTP method is `POST`
- AND the path starts with `/api/v1/payments`

Write the `AuthorizationPolicy` for service-b. Reference the format in `mtls-config.yaml`.

```yaml
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: service-b-payments-write
  namespace: team-b
spec:
  selector:
    matchLabels:
      app: service-b
  action: ALLOW
  rules:
  - from:
    - source:
        principals:
        # mTLS peer must be service-a in namespace team-a
        - "cluster.local/ns/team-a/sa/service-a"
    to:
    - operation:
        methods: ["POST"]
        paths: ["/api/v1/payments*"]
    when:
    # JWT must carry scope claim with value payments.write
    - key: request.auth.claims[scope]
      values: ["payments.write"]
```

**Exercise 5b: Default-deny with explicit allow-list**

Add a DENY-all-by-default policy for the `team-b` namespace that denies everything not explicitly allowed. In Istio, `DENY` policies take precedence over `ALLOW` policies. A common pattern is to use a namespace-wide `DENY` to block unauthenticated traffic, with service-level `ALLOW` policies for permitted callers.

```yaml
# Deny all traffic to team-b that does not have a valid mTLS peer certificate
# This blocks plaintext/unauthenticated requests even in PERMISSIVE mode
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: deny-unauthenticated
  namespace: team-b
spec:
  # No selector = applies to all workloads in the namespace
  action: DENY
  rules:
  - from:
    - source:
        # Deny requests that have no mTLS peer (empty principal = no client cert)
        notPrincipals: ["*"]
```

**Exercise 5c: Evaluate the policies against the request path**

For each of the following requests, state whether the request is ALLOWED or DENIED, and which policy rule triggers the decision.

| Request | From | JWT claims | Method | Path | Decision | Triggering rule |
|---------|------|-----------|--------|------|---------|----------------|
| Request A | service-a (mTLS) | scope=payments.write | POST | /api/v1/payments/123 | ALLOWED | service-b-payments-write (all conditions met) |
| Request B | service-a (mTLS) | scope=payments.read | POST | /api/v1/payments/123 | DENIED | service-b-payments-write (scope mismatch); deny-unauthenticated not triggered (has mTLS) |
| Request C | ingress-gateway (mTLS) | scope=payments.write | POST | /api/v1/payments/123 | DENIED | service-b-payments-write (principal mismatch: gateway SA not service-a) |
| Request D | no mTLS (plaintext) | none | GET | /health | DENIED | deny-unauthenticated (no mTLS peer = notPrincipals matches) |
| Request E | service-a (mTLS) | scope=payments.write | GET | /api/v1/payments/123 | DENIED | service-b-payments-write (method must be POST) |

---

## Key Takeaways

1. **mTLS proves the identity of the immediately preceding peer only.** The source sidecar's SVID is cryptographically validated, but every hop beyond that requires XFCC or JWT to carry prior identity — and those are only trustworthy if each intermediate gateway is configured correctly.

2. **XFCC is safe only with `SANITIZE_SET`.** `FORWARD_ONLY` and `APPEND_FORWARD` allow external injection of arbitrary SPIFFE URIs. For any gateway that accepts untrusted connections (internet-facing or tenant-shared), `SANITIZE_SET` is mandatory and should be enforced by the platform, not left to teams.

3. **Trust bundle mismatches are silent in `PERMISSIVE` mode.** Traffic appears to succeed but is unauthenticated. The operational requirement for multi-cluster meshes is a shared root CA provisioned before any cluster joins the mesh — not retrofitted after the fact.

4. **Isolation boundaries are organizational decisions, not just technical ones.** A CA boundary without a corresponding xDS boundary provides limited protection (a rogue istiod can still push bad config to all namespaces). Boundaries should be designed to match the trust model between teams and the blast radius acceptable for each failure class.

5. **`source.principal` in AuthorizationPolicy matches on the mTLS peer, not the original caller.** In a gateway architecture, the peer is the gateway, not the client application. Fine-grained per-caller authorization requires either XFCC inspection (for intra-mesh callers) or JWT claims (for external or cross-domain callers). Design your AuthorizationPolicy rules knowing which identity layer you are actually evaluating.
