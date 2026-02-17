# Service Identity Propagation & Isolation Boundaries

## What you should be able to do
- Explain SPIFFE identity, SVIDs, and how Istio issues and rotates workload certificates end-to-end via SDS.
- Explain the confused deputy problem and the mechanisms (XFCC header, JWT propagation, AUTO_PASSTHROUGH) that preserve or restore principal context across gateway hops.
- Design isolation boundaries (xDS, CA, trust, ownership) for a multi-team or multi-cluster mesh and articulate what each boundary protects against.

## Mental Model

In a zero-trust service mesh, identity is not a username or an IP address — it is a cryptographic proof tied to the workload's code and runtime context. The SPIFFE standard formalizes this: every workload in a SPIFFE-compliant mesh has a SPIFFE ID, a URI of the form `spiffe://trust-domain/ns/namespace/sa/service-account`. The trust domain is the root of authority — all workloads within the same trust domain share a root CA, and certificates signed by that CA encode the workload's SPIFFE ID in the X.509 Subject Alternative Name (SAN) field. At the TLS layer, both sides present their SVID (SPIFFE Verifiable Identity Document) during the handshake, and each side validates the peer's certificate against its trust bundle (the set of trusted CA roots). The result is mutual authentication: the client knows it is talking to the correct server, and the server knows which workload is making the request. This is the foundation on which AuthorizationPolicy evaluates `source.principal` — the string form of the peer's SPIFFE ID.

The challenge arrives at gateway boundaries. When a sidecar in service A initiates an mTLS connection to service B, the SAN from A's certificate is directly available to B's sidecar after the handshake. No extra mechanism is needed: A proves its identity cryptographically, and B's AuthorizationPolicy can match on `source.principal: "cluster.local/ns/team-a/sa/service-a"`. But when traffic crosses an East-West Gateway or an ingress gateway, the gateway terminates the original mTLS session and originates a new one toward the upstream. The new TLS session presents the gateway's SVID, not the original caller's. From the upstream's perspective, the connection came from the gateway, not from the original workload. If the upstream's AuthorizationPolicy requires a specific `source.principal`, it sees the gateway's principal and denies the request. This is the confused deputy problem: the gateway holds privilege (network access to the upstream) without the proper principal context, and the upstream cannot distinguish a legitimate forwarded request from a lateral movement attempt that exploited the gateway.

Principal propagation is the set of mechanisms that solve the confused deputy problem. Envoy has a built-in mechanism: the `x-forwarded-client-cert` (XFCC) header, which Envoy populates with the peer certificate details from the downstream mTLS session before forwarding the request upstream. The header carries the SPIFFE URI, the certificate hash, and optionally the DNS SANs — enough for the upstream to reconstruct who originally made the request. A second mechanism is JWT-based propagation: the gateway extracts the caller's identity from a JWT in the `Authorization` header (validated by `RequestAuthentication`) and forwards the JWT or a signed derivative upstream; the upstream's `RequestAuthentication` validates the JWT and surfaces the caller's principal in the `request.auth.principal` field of `AuthorizationPolicy`. The AUTO_PASSTHROUGH mode on East-West Gateways sidesteps the problem entirely: the gateway forwards the raw TLS bytes without terminating the session, so the mTLS handshake between the originating sidecar and the destination sidecar completes end-to-end and the SPIFFE identity is never interrupted.

Isolation boundaries are the structural mechanism for managing blast radius, upgrade independence, and policy ownership in a large mesh. A boundary is a point where configuration, credentials, or trust is explicitly separated. The four boundary types are: xDS boundary (separate control planes, so a bad xDS push in one domain cannot affect another), CA boundary (separate intermediate CAs, so a compromised CA in one domain cannot issue certificates accepted in another), trust boundary (separate trust domains, so AuthorizationPolicy in one domain can block all traffic from another domain unless explicitly permitted), and ownership boundary (separate namespaces and RBAC, so a team can only modify resources within their own scope). Designing these boundaries is a first-order concern when building a multi-tenant platform: without them, a single misconfigured workload, a rogue istiod push, or a certificate compromise can affect every service in the mesh.

## Key Concepts

- **SPIFFE (Secure Production Identity Framework For Everyone)**: An open standard for workload identity. Defines the SPIFFE ID format, the SVID format, and the SPIFFE Workload API for delivering SVIDs to workloads without secrets management overhead.
- **SPIFFE ID**: A URI uniquely identifying a workload: `spiffe://trust-domain/ns/namespace/sa/service-account`. Encoded in the X.509 SAN field (type URI) of an X.509-SVID.
- **SVID (SPIFFE Verifiable Identity Document)**: The credential that proves a SPIFFE identity. Two forms: X.509-SVID (a TLS certificate with the SPIFFE ID in the SAN, used for mTLS) and JWT-SVID (a signed JWT carrying the SPIFFE ID as the `sub` claim, used for application-layer identity propagation).
- **Trust domain**: The administrative root of authority for a SPIFFE deployment. All SVIDs within a trust domain are signed by the same root CA (or an intermediate CA chaining to that root). Istio's default trust domain is `cluster.local`.
- **Trust bundle**: The set of root CA certificates that a workload trusts for validating peer SVIDs. Workloads only accept SVIDs signed by a CA in their trust bundle. In Istio, delivered to Envoy via SDS (the `ROOTCA` secret).
- **SPIRE**: The SPIFFE Runtime Environment — a production-grade implementation of the SPIFFE specification. Manages workload attestation, SVID issuance, and trust bundle distribution. An alternative to Istio's built-in CA when stricter attestation (TPM, hardware-bound) is required.
- **Istiod CA / Citadel**: Istio's built-in certificate authority. Issues X.509-SVIDs to workload sidecars. Signs certificates with the intermediate CA in the `cacerts` secret in `istio-system`; if no `cacerts` is provided, Istio self-signs a root CA. Rotates workload certs before TTL expiry (default cert lifetime: 24 hours, rotation at ~80% of lifetime).
- **SDS (Secret Discovery Service)**: The xDS API that delivers TLS certificates and private keys to Envoy dynamically. Sidecars request their workload certificate (`default`) and the trust bundle (`ROOTCA`) via SDS from istiod. This enables certificate rotation without any Envoy restart or config push — only a new SDS response is needed.
- **x-forwarded-client-cert (XFCC)**: An HTTP header that Envoy populates with the client certificate details from the downstream mTLS session. Fields: `By` (server cert SAN), `Hash` (cert fingerprint), `Cert` (URL-encoded cert), `URI` (SPIFFE URI), `DNS` (DNS SANs). Controlled by `forward_client_cert_details` in the HCM config. Set to `SANITIZE_SET` on gateways to strip any incoming XFCC and replace it with the gateway's own validated downstream cert info.
- **PeerAuthentication**: Istio resource that configures mTLS mode for inbound connections to a workload or namespace. `STRICT` requires all inbound connections to present a valid mTLS client certificate. `PERMISSIVE` allows both mTLS and plaintext. `DISABLE` turns off mTLS termination.
- **RequestAuthentication**: Istio resource that configures JWT validation for incoming requests. Specifies the issuer URL and JWKS endpoint. A validated JWT surfaces the caller's claims (including `sub`) in `request.auth.claims` and the principal in `request.auth.principal`, usable in AuthorizationPolicy.
- **AuthorizationPolicy**: Istio's L4/L7 access control resource. Evaluates `source.principal` (mTLS peer identity), `source.namespace`, `request.auth.principal` (JWT identity), `request.auth.claims` (arbitrary JWT claims), HTTP method, path, and headers. Applied per-workload or per-namespace via label selectors.
- **Confused deputy problem**: A security vulnerability where an intermediary (gateway) holds elevated privilege without the proper principal context. In a mesh, the gateway presents its own SVID to upstreams; without XFCC propagation or JWT forwation, the upstream cannot enforce per-caller AuthorizationPolicy and must either trust all traffic from the gateway or block it entirely.
- **Isolation boundary types**: xDS boundary (separate control plane per domain), CA boundary (separate intermediate CAs per domain), trust boundary (separate trust domains with explicit federation), ownership boundary (namespace and RBAC scoping per team).

## Internals

### SPIFFE Identity & mTLS Handshake

Istiod acts as both the SPIFFE Workload API and the certificate authority for the mesh. When a pod starts, the sidecar (Envoy) boots and immediately opens a gRPC stream to istiod's SDS endpoint (port 15012 on the same node, via UDS, or port 15012 in-cluster). The sidecar sends an SDS `DiscoveryRequest` for the secret named `default` (its own workload certificate) and for `ROOTCA` (the trust bundle). Istiod validates the sidecar's Kubernetes service account token (projected volume at `/var/run/secrets/kubernetes.io/serviceaccount/token`) against the Kubernetes API to establish the workload's identity — this is attestation. It then signs an X.509 certificate with the SPIFFE ID `spiffe://cluster.local/ns/<namespace>/sa/<service-account>` in the SAN field and returns it via SDS. The private key is generated in-process in istiod and transmitted in the SDS response; it is never stored on disk.

The certificate is loaded into Envoy's `DownstreamTlsContext` (for inbound connections) and `UpstreamTlsContext` (for outbound connections). When service A connects to service B, the handshake proceeds:

1. A's Envoy initiates a TLS ClientHello to B's Envoy, with ALPN `istio` or `h2`.
2. B's Envoy presents its X.509-SVID (containing B's SPIFFE URI in the SAN).
3. A's Envoy validates B's certificate against the `ROOTCA` trust bundle. It also enforces SAN matching: the `combined_validation_context.match_subject_alt_names` in the `UpstreamTlsContext` ensures A only accepts connections to endpoints with the expected SPIFFE URI for service B.
4. A presents its X.509-SVID. B validates against `ROOTCA`.
5. After the handshake, B's Envoy has the peer's SPIFFE URI available as the `source.principal` for AuthorizationPolicy evaluation. Envoy's `rbac` network filter or the `ext_authz` HTTP filter evaluates the policy.

Istio rotates workload certificates automatically. The default `workloadCertTtl` is 24 hours; istiod pushes a new SDS response at approximately 20 hours (80% of TTL). Envoy applies the new certificate without any connection disruption — existing TLS sessions continue using the old cert; new sessions use the new cert. The old cert remains in memory until its TTL expires. If SDS rotation fails (istiod unreachable), Envoy continues using the existing cert until its `notAfter` field is reached, at which point new TLS connections cannot be established.

### Principal Propagation Across Gateways

The confused deputy failure mode manifests when a gateway terminates the mTLS session from a downstream caller and originates a new one to the upstream. The upstream sees the gateway's SPIFFE URI as `source.principal`, not the original caller's. Consider:

```
client (spiffe://cluster.local/ns/team-a/sa/client)
  → ingress gateway (spiffe://cluster.local/ns/istio-system/sa/istio-ingressgateway)
    → service-b (sees gateway's principal, not client's)
```

Service-b's AuthorizationPolicy evaluating `source.principal: "cluster.local/ns/team-a/sa/client"` will deny the request because the presented principal is the gateway's SA, not the client's SA.

Three mechanisms address this:

1. **XFCC header (Envoy-native, L7 mTLS environments)**: Configure the gateway's HCM with `forward_client_cert_details: SANITIZE_SET` and `set_current_client_cert_details: {uri: true}`. When the gateway receives an mTLS connection from the client, it strips any existing XFCC header (preventing spoofing from external callers) and adds a new XFCC header encoding the client's SPIFFE URI. The upstream receives the request with an XFCC header like `XFCC: URI=spiffe://cluster.local/ns/team-a/sa/client;Hash=abc123`. The upstream can inspect this header in application code or use an Envoy Lua/Wasm filter to extract the principal. Note: XFCC is an HTTP header, so it requires HTTP-layer visibility at the gateway (the gateway must terminate TLS and speak HTTP).

2. **JWT-based propagation (cross-domain or cross-trust-boundary)**: The originating workload obtains a JWT-SVID from the SPIFFE Workload API or a JWT signed by its identity provider. The JWT carries the caller's `sub` claim (e.g., `spiffe://cluster.local/ns/team-a/sa/client`). The gateway validates the JWT using `RequestAuthentication` and forwards it (or exchanges it for a new short-lived JWT) to the upstream. The upstream's `RequestAuthentication` validates the JWT and exposes `request.auth.principal` for AuthorizationPolicy. This pattern is essential when crossing trust domain boundaries where XFCC from a foreign cluster cannot be validated without shared root CA.

3. **AUTO_PASSTHROUGH (EWG pattern, transparent to identity)**: When an East-West Gateway uses `mode: AUTO_PASSTHROUGH`, it does not terminate TLS. The mTLS session is established directly between the source sidecar and the destination sidecar, with the EWG acting as a TCP forwarder. The SPIFFE identity from the source sidecar's SVID is directly validated by the destination sidecar, as if the EWG were not in the path. This is the cleanest solution for intra-mesh cross-cluster traffic because identity is never broken. The trade-off is that the EWG cannot inspect or modify HTTP headers, apply rate limiting, or enforce L7 policies — it is a pure TCP proxy.

### Isolation Boundaries

An isolation boundary is a deliberate architectural decision to break a shared resource (control plane, CA, trust domain, ownership scope) into separate instances. Each boundary type has a different protection guarantee and a different operational cost:

**xDS boundary**: Separate istiod instances per domain, each managing a separate set of namespaces or clusters. A bad xDS push from istiod-A (e.g., a VirtualService that accidentally matches all traffic and sends it to a blackhole cluster) affects only the namespaces managed by istiod-A. Istiod-B's namespaces continue operating normally. The xDS boundary also decouples upgrade schedules: istiod-A can be upgraded to Istio 1.19 while istiod-B stays on 1.18, allowing staged rollouts across the fleet. In Istio, xDS boundaries are implemented via `Sidecar.spec.egress.hosts` scoping (limiting which services each namespace sees) and `Revision`-based installations (multiple istiod Deployments with separate control plane labels).

**CA boundary**: Separate intermediate CAs per domain, all signed by the same root CA. CA-A issues certificates to sidecars in domain-A; CA-B issues certificates to sidecars in domain-B. A compromise of CA-A's private key allows an attacker to issue valid SVIDs for any workload in domain-A, but not for workloads in domain-B (whose certificates were signed by CA-B, a different intermediate). The root CA — typically managed by an HSM or Vault PKI — remains uncompromised. Cross-boundary communication requires both domains to trust each other's intermediate CAs, which is configured via the shared root CA in the trust bundle. In Istio, separate intermediate CAs are configured by providing different `cacerts` secrets per cluster or per istiod revision.

**Trust boundary**: Separate trust domains with explicit federation for cross-boundary communication. Workloads in trust domain `team-a.example.com` only accept SVIDs signed by CAs in `team-a.example.com`'s trust bundle. To allow a workload in `team-b.example.com` to call across the boundary, the operator must: (a) configure `MeshConfig.trustDomainAliases` to accept SVIDs from `team-b.example.com`, and (b) configure `AuthorizationPolicy` with an explicit `source.principal` allowing the cross-domain identity. Without explicit permission, all cross-domain traffic is denied. This is the strictest form of boundary — it requires deliberate policy to permit any cross-boundary call, making it appropriate for compliance boundaries (PCI scope, SOC2 boundary) where implicit trust is not acceptable.

**Ownership boundary**: Namespace-level RBAC that restricts which teams can create or modify Istio resources. A team's namespace has an `AuthorizationPolicy` that only the team's ServiceAccounts can trigger; they cannot modify the `istio-system` namespace or other teams' namespaces. The `Sidecar` resource limits the egress destinations a namespace can reach, preventing a misconfigured workload from sending traffic to services it should not know about. Ownership boundaries are the lowest-cost boundary type — they run within a single istiod and trust domain — but they protect against misconfiguration and lateral movement within a shared cluster.

## Architecture Diagram

```
  TRUST DOMAIN: cluster.local
  ┌──────────────────────────────────────────────────────────────────────────────┐
  │                                                                              │
  │  NAMESPACE: team-a                         NAMESPACE: team-b                │
  │  CA: istiod (intermediate CA-A)            CA: istiod (intermediate CA-A)   │
  │                                                                              │
  │  ┌─────────────────────────┐               ┌────────────────────────────┐   │
  │  │ client                  │               │ service-b                  │   │
  │  │ SVID: spiffe://...      │               │ SVID: spiffe://...         │   │
  │  │ /ns/team-a/sa/client    │               │ /ns/team-b/sa/service-b    │   │
  │  │                         │               │                            │   │
  │  │ [sidecar]               │               │ [sidecar]                  │   │
  │  │  UpstreamTlsContext     │               │  DownstreamTlsContext      │   │
  │  │  SAN match: team-b      │               │  AuthorizationPolicy:      │   │
  │  └──────────┬──────────────┘               │  source.principal =        │   │
  │             │ mTLS (SVID)                  │  "cluster.local/ns/        │   │
  │             │                              │   team-a/sa/client"        │   │
  │             │                              └──────────▲─────────────────┘   │
  │             │                                         │                     │
  │             │                              ┌──────────┴─────────────────┐   │
  │             │ XFCC header injected          │ INGRESS GATEWAY            │   │
  │             └──────────────────────────────►  SVID: istio-ingressgateway │   │
  │                                            │  forward_client_cert_details│   │
  │                                            │  : SANITIZE_SET             │   │
  │                                            │  XFCC: URI=spiffe://...     │   │
  │                                            │  /ns/team-a/sa/client       │   │
  │                                            └────────────────────────────┘   │
  │                                                                              │
  └──────────────────────────────────────────────────────────────────────────────┘

  CROSS-TRUST-DOMAIN (cluster-a → cluster-b via EWG in AUTO_PASSTHROUGH):
  ┌──────────────────────────┐          ┌─────────────────────────────────────┐
  │  TRUST DOMAIN: cluster-a │          │  TRUST DOMAIN: cluster-b            │
  │                          │          │                                     │
  │  sidecar-a               │          │  EWG (AUTO_PASSTHROUGH)             │
  │  SVID: spiffe://         │ mTLS raw │  port 15443, SNI-based TCP forward  │
  │  cluster-a/ns/ns-a/      ├─────────►│  (does NOT terminate TLS)           │
  │  sa/service-a            │          │           │                         │
  │                          │          │           │ raw TLS bytes forwarded │
  │                          │          │           ▼                         │
  │                          │          │  sidecar-b                          │
  │                          │          │  validates sidecar-a's SVID via     │
  │                          │          │  trust bundle federation            │
  │                          │          │  (cluster-a root CA in bundle)      │
  └──────────────────────────┘          └─────────────────────────────────────┘

  SDS CERTIFICATE DELIVERY (per workload):
  istiod ──(gRPC SDS push)──► Envoy sidecar
    secret "default"  → workload X.509-SVID (cert + private key)
    secret "ROOTCA"   → trust bundle (root CA cert)
  Rotation: istiod pushes new SDS response at ~80% of cert TTL (default: ~20h of 24h)
  Envoy hot-swaps cert; no restart required; existing TLS sessions unaffected
```

## Failure Modes & Debugging

### 1. Confused Deputy — Gateway Presents Its Own Identity, Upstream Denies

**Symptoms**: Requests that pass through an ingress gateway or EWG (in non-passthrough mode) receive `403 RBAC: access denied` responses. The denial is logged by the upstream sidecar's access log with `%RESPONSE_CODE_DETAILS%` of `rbac_access_denied_matched_policy[ns[team-b]-policy[require-team-a]]`. The `source.principal` in the upstream's AuthorizationPolicy evaluation log shows the gateway's service account, not the originating workload's SA. Direct pod-to-pod calls (bypassing the gateway) succeed.

**Root Cause**: The ingress gateway terminates the mTLS session from the client and opens a new mTLS session to the upstream using the gateway's own SVID (`spiffe://cluster.local/ns/istio-system/sa/istio-ingressgateway`). The upstream's `AuthorizationPolicy` was written to match `source.principal` on the originating workload's SPIFFE URI. Since the gateway's SVID does not match, the policy denies the request. This is the confused deputy: the gateway presents the wrong principal. XFCC propagation was either not configured on the gateway or the upstream's AuthorizationPolicy does not inspect the XFCC header.

**Blast Radius**: All requests through the affected gateway path to services with strict `source.principal` AuthorizationPolicy are denied. Services using only `source.namespace` matching are not affected (the gateway's namespace is evaluated correctly). Services using `ALLOW_ANY` or no AuthorizationPolicy are not affected. The failure is scoped to the gateway-upstream pair where XFCC is not configured.

**Mitigation**: Configure the gateway's HCM with `forward_client_cert_details: SANITIZE_SET`. In Istio, this is done via an `EnvoyFilter` targeting the ingress gateway deployment and patching the HCM config. On the upstream side, either: (a) update `AuthorizationPolicy` to also allow the gateway's principal (coarse-grained, not recommended for strict zero-trust), or (b) use a Lua/Wasm filter on the upstream to extract the XFCC `URI` field and enforce principal matching in application code. For new architectures, prefer JWT-based propagation over XFCC: the gateway validates the caller's JWT via `RequestAuthentication` and forwards it; the upstream uses `request.auth.claims` in AuthorizationPolicy.

**Debugging**:
```bash
# Inspect the principal that the upstream sidecar sees from the gateway connection
# Look at access log fields: %DOWNSTREAM_PEER_URI_SAN% shows the mTLS peer's SPIFFE URI
kubectl logs -n team-b deploy/service-b -c istio-proxy | grep "rbac\|access_denied" | tail -20

# Check the XFCC header configuration on the gateway's HCM
istioctl proxy-config listener deploy/istio-ingressgateway.istio-system \
  --port 8443 -o json | jq '.[].filterChains[].filters[] |
  select(.name == "envoy.filters.network.http_connection_manager") |
  .typedConfig.forwardClientCertDetails'

# Check what principal the upstream sidecar evaluates for AuthorizationPolicy
# Enable debug logging on the upstream sidecar's rbac filter
istioctl proxy-config log deploy/service-b.team-b --level rbac:debug
kubectl logs -n team-b deploy/service-b -c istio-proxy | grep "rbac" | tail -30

# Verify the gateway's SVID (what principal it presents to upstreams)
istioctl proxy-config secret deploy/istio-ingressgateway.istio-system | head -5

# Check what XFCC value the upstream receives (add a debug route that echoes headers)
kubectl exec -n team-b deploy/service-b -c service-b -- \
  curl -s http://localhost:8080/debug/headers | grep -i xfcc
```

---

### 2. Trust Bundle Mismatch — Cross-Cluster mTLS Handshake Fails

**Symptoms**: Traffic between clusters fails at the TLS handshake layer. The source sidecar's access log shows `%RESPONSE_FLAGS%` as `UF` (upstream connection failure) with `%RESPONSE_CODE_DETAILS%` of `upstream_reset_before_response_started{connection_failure,tls_error}`. The destination sidecar (or EWG) shows `ssl.handshake_error` incrementing. `istioctl proxy-config secret` shows valid, unexpired certificates on both sides, but `openssl s_client` reveals that the destination rejects the source's certificate with `certificate verify failed (unable to get local issuer certificate)`. The clusters have different root CA fingerprints.

**Root Cause**: The two clusters were bootstrapped with different root CAs (different `cacerts` secrets, or one using the Istio self-signed root and the other using an external PKI root). The destination sidecar's trust bundle (`ROOTCA`) does not include the source cluster's root CA, so it cannot verify the source's SVID. With `PeerAuthentication: STRICT`, the handshake is rejected. With `PeerAuthentication: PERMISSIVE`, the session may fall back to plaintext, which is a silent security regression — traffic appears to succeed but is not authenticated or encrypted.

**Blast Radius**: All cross-cluster mTLS traffic between the two affected clusters fails. Services in `STRICT` mode see immediate 503 errors. Services in `PERMISSIVE` mode continue operating but without identity enforcement — effectively unauthenticated. The blast radius covers every service that relies on cross-cluster calls, including failover paths that appeared to work during steady-state but now produce silent plaintext fallbacks.

**Mitigation**: Provision a shared root CA before connecting any clusters to the mesh. Use a central PKI (Vault, AWS ACM Private CA, or cert-manager with a shared ClusterIssuer) to sign per-cluster intermediate CAs, then load those intermediates as the `cacerts` secret in each cluster's `istio-system` namespace before istiod starts. For clusters that already have divergent CAs, use Istio trust domain federation: configure `MeshConfig.caCertificates` with the remote cluster's root CA bundle (the `cacerts.pem` from the remote cluster), making each cluster explicitly trust the other's root. During migration, use `PeerAuthentication: PERMISSIVE` to allow both authenticated and plaintext connections, then switch to `STRICT` after trust federation is validated.

**Debugging**:
```bash
# Extract and compare root CA fingerprints from both clusters
kubectl get secret cacerts -n istio-system --context cluster-a \
  -o jsonpath='{.data.ca-cert\.pem}' | base64 -d | \
  openssl x509 -noout -fingerprint -subject -issuer

kubectl get secret cacerts -n istio-system --context cluster-b \
  -o jsonpath='{.data.ca-cert\.pem}' | base64 -d | \
  openssl x509 -noout -fingerprint -subject -issuer

# If fingerprints differ, the clusters have divergent root CAs — this is the root cause

# Inspect the trust bundle (ROOTCA) delivered to a sidecar via SDS
istioctl proxy-config secret deploy/service-a.team-a --context cluster-a | \
  grep -A5 "ROOTCA"

# Test TLS handshake directly to isolate the layer of failure
# (requires port-forwarding to the destination sidecar's inbound port 15006)
kubectl port-forward -n team-b deploy/service-b 15006:15006 --context cluster-b &
openssl s_client -connect localhost:15006 \
  -cert /path/to/source-svid.pem \
  -key /path/to/source-svid-key.pem \
  -CAfile /path/to/cluster-a-root.pem 2>&1 | grep -E "Verify|error|CONNECTED"

# Check ssl handshake failure stats on the destination EWG or sidecar
kubectl exec -n istio-system deploy/istio-eastwestgateway --context cluster-b -- \
  curl -s localhost:15000/stats | grep "ssl.*handshake\|ssl.*fail"

# Check MeshConfig trust domain and caCertificates fields
kubectl get configmap istio -n istio-system -o jsonpath='{.data.mesh}' | \
  grep -E "trustDomain|caCertificates|trustDomainAliases"
```

---

### 3. SVID Expiry / SDS Rotation Failure — New Connections Fail After Certificate TTL

**Symptoms**: Service calls that were working begin failing with TLS errors after a period of approximately 24 hours (default cert TTL) or after a specific event (istiod restart, node-level disruption). Envoy access logs on the source side show `UF` with `tls_error`. The Envoy admin API at `/certs` shows the workload certificate's `notAfter` timestamp has passed or is within seconds of expiring. `istioctl proxy-config secret` shows the certificate as `EXPIRED` or shows a `Last Rotation` timestamp that is stale. Active connections on the existing TLS session may still function (TLS sessions outlive the cert), but any new connection establishment fails.

**Root Cause**: Istiod failed to push a new SDS response before the certificate TTL expired. This can happen when: (a) the sidecar's SDS gRPC stream to istiod was disconnected (network policy change, istiod rolling restart) and the certificate expired before the stream reconnected; (b) istiod itself was overloaded and could not process SDS renewal requests in time; (c) a node-level issue caused the sidecar to restart, and on startup it received a certificate very close to its TTL with insufficient time to be renewed before the next rotation trigger. In Istio, workload cert rotation is initiated by istiod at `notAfter - (TTL * 0.2)`, but if the SDS stream is not established at that point, the renewal does not happen.

**Blast Radius**: Only the specific pod(s) whose certificate expired are affected. No new TLS sessions can be established from or to the affected pod. Existing long-lived connections (gRPC streams, WebSockets) may continue but cannot be re-established if dropped. In a high-restart environment (frequent rolling updates, node recycling), this can affect a larger fraction of the fleet simultaneously.

**Mitigation**: Monitor certificate expiry proactively. The metric `envoy_ssl_certificate_expiration_timestamp_seconds` (available from the Envoy admin API `/stats` in Prometheus format) carries the `notAfter` value as a Unix timestamp; alert when `notAfter - now() < 2h`. Ensure istiod has sufficient headroom: the SDS stream reconnection and certificate reissuance should complete within minutes; if istiod is taking longer, it is under-resourced. Increase istiod replicas and set `PILOT_CERT_PROVIDER` to use a faster signing backend. For emergency recovery, restarting the affected pod's sidecar (or the entire pod) causes a new SDS request on startup and istiod issues a fresh certificate.

**Debugging**:
```bash
# Check certificate expiry for a specific workload
istioctl proxy-config secret deploy/service-a.team-a -o json | \
  jq '.dynamicActiveSecrets[] | select(.name == "default") |
  .secret.tlsCertificate.certificateChain | .inlineBytes' | \
  base64 -d | openssl x509 -noout -dates

# Check all certificates loaded in Envoy via admin API
kubectl exec -n team-a deploy/service-a -c istio-proxy -- \
  curl -s localhost:15000/certs | jq '.certificates[] |
  {name: .cert_chain[0].subject_alt_names, expiry: .cert_chain[0].expiration_time}'

# Check when the last SDS rotation occurred (look for SDS response in logs)
kubectl logs -n team-a deploy/service-a -c istio-proxy | \
  grep -i "sds\|certificate\|rotation" | tail -20

# Check istiod's certificate signing metrics
kubectl exec -n istio-system deploy/istiod -- \
  curl -s localhost:15014/metrics | grep -E "citadel|cert_sign|sds"

# Check SDS connection state (is the stream active?)
kubectl exec -n team-a deploy/service-a -c istio-proxy -- \
  curl -s localhost:15000/stats | grep "sds.*"

# Force a certificate renewal by sending a new SDS request (restart the sidecar's xDS stream)
# In practice: restart the pod to trigger a fresh SDS request on startup
kubectl rollout restart deploy/service-a -n team-a
```

---

### 4. XFCC Header Spoofing — External Client Injects Forged Caller Identity

**Symptoms**: Application security audit or penetration test reveals that an external client can set an arbitrary `x-forwarded-client-cert` header in a request to the ingress gateway, and the header reaches the upstream service unchanged. The upstream application or Lua filter trusts the XFCC URI field as authoritative principal, allowing an attacker to impersonate any internal service account by including its SPIFFE URI in the XFCC header. No mTLS error is raised because the header is treated as metadata, not validated cryptographically.

**Root Cause**: The ingress gateway's HCM `forward_client_cert_details` is set to `FORWARD_ONLY` or `APPEND_FORWARD` instead of `SANITIZE_SET`. `FORWARD_ONLY` passes the incoming XFCC header through to the upstream without modification; `APPEND_FORWARD` adds the gateway's downstream cert info but also preserves any incoming XFCC values. Only `SANITIZE_SET` removes any incoming XFCC header (preventing injection from external clients) and replaces it with the gateway's validated downstream cert details. From the north-south ingress (where the downstream is a public client without a client certificate), `SANITIZE_SET` results in an empty XFCC header, which correctly signals to the upstream that there is no authenticated client identity to propagate.

**Blast Radius**: Any upstream that uses XFCC-based principal extraction for authorization decisions is potentially compromised. The attacker can claim to be any internal service account, bypassing `source.principal`-based AuthorizationPolicy that relies on XFCC. This is a horizontal privilege escalation: with access to the ingress gateway's HTTP endpoint, the attacker gains the ability to impersonate any identity within the mesh. North-south ingress gateways are the highest-risk injection point; east-west gateways in AUTO_PASSTHROUGH mode are not vulnerable (no HTTP layer, no XFCC injection vector).

**Mitigation**: Set `forward_client_cert_details: SANITIZE_SET` on all ingress gateway HCMs. This is non-negotiable for any gateway that accepts connections from untrusted networks. Apply a defense-in-depth rule: the upstream should never trust XFCC alone for high-privilege authorization decisions if the ingress path includes a non-mTLS leg. Prefer JWT-based propagation for cross-trust-domain or north-south identity claims, as JWTs are cryptographically signed and cannot be forged without the issuer's private key. Additionally, configure `PeerAuthentication: STRICT` on all upstream services so they only accept mTLS — this eliminates the plaintext injection path entirely.

**Debugging**:
```bash
# Verify the XFCC forwarding mode on the ingress gateway
istioctl proxy-config listener deploy/istio-ingressgateway.istio-system \
  -o json | jq '.[].filterChains[].filters[] |
  select(.name == "envoy.filters.network.http_connection_manager") |
  .typedConfig | {forwardClientCertDetails, setCurrentClientCertDetails}'

# Test XFCC injection from outside the cluster (should be stripped by SANITIZE_SET)
curl -H "x-forwarded-client-cert: URI=spiffe://cluster.local/ns/kube-system/sa/admin" \
  https://gateway.example.com/api/sensitive \
  -v 2>&1 | grep -i "xfcc\|forwarded"

# Confirm upstream does NOT receive the injected XFCC header
# (enable header echo endpoint on the upstream for this test)
kubectl exec -n team-b deploy/service-b -c service-b -- \
  curl -s http://localhost:8080/debug/headers | grep -i "xfcc\|client-cert"

# Check access logs on the gateway for the external request
kubectl logs -n istio-system deploy/istio-ingressgateway | \
  grep "sensitive" | tail -5

# Confirm PeerAuthentication is STRICT on the upstream namespace
kubectl get peerauthentication -n team-b -o yaml | grep "mode:"
```

## Lightweight Lab

See `lab/README.md` for the full identity propagation and threat modeling exercise. The lab covers SVID inspection, tracing principal propagation across a 3-hop request, threat modeling for each hop, isolation boundary design, and writing AuthorizationPolicy rules for fine-grained access control using both `source.principal` and `request.auth.claims`.

```bash
# Quick inspection: dump the workload certificate for any Istio-proxied pod
istioctl proxy-config secret deploy/<your-deploy>.<namespace> -o json | \
  jq -r '.dynamicActiveSecrets[] | select(.name == "default") |
  .secret.tlsCertificate.certificateChain.inlineBytes' | \
  base64 -d | openssl x509 -noout -text | grep -E "Subject Alternative|URI:|Not After"

# Confirm SPIFFE URI format: spiffe://cluster.local/ns/<namespace>/sa/<service-account>

# Inspect what principal an AuthorizationPolicy would evaluate
kubectl exec -n team-b deploy/service-b -c istio-proxy -- \
  curl -s localhost:15000/config_dump | jq '.. | .rules? // empty | .[].principals'
```

## What to commit
- Add a production story: document a real or hypothetical identity propagation incident — a service that was incorrectly authorized (or denied) because of a gateway identity boundary, how the issue was diagnosed using `istioctl proxy-config secret` and access log fields, and what configuration change fixed it.
- Map your team's services to isolation boundary types: which services share an istiod? which share a CA? are there compliance boundaries that require separate trust domains? Document the rationale for each boundary decision.
