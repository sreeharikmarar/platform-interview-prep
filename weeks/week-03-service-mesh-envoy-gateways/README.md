# Week 03: Service Mesh, Envoy, and Gateways

## Overview

This week focuses on the core primitives and operational patterns underlying modern service mesh and gateway infrastructure. You'll develop a deep understanding of Envoy's architecture, traffic management internals, and how control planes (Istio, Linkerd, Envoy Gateway, Consul Connect) leverage these primitives to deliver platform capabilities like traffic shifting, multi-cluster routing, and identity-based security.

## Prerequisites

Before starting this week, you should have:

- **Envoy Basics**: Familiarity with the concepts of listeners, clusters, and routes
- **Kubernetes Networking**: Understanding of Services, Endpoints/EndpointSlices, kube-proxy, DNS
- **TLS Fundamentals**: Certificate validation, SNI, mTLS handshake flow
- **HTTP/2 and gRPC**: Protocol mechanics, particularly for xDS APIs
- **Load Balancing Concepts**: Round robin, least request, consistent hashing

If you need to brush up, the official Envoy documentation and Kubernetes networking guides are excellent resources.

## Week Objectives

By the end of this week, you will be able to:

1. Trace an HTTP request through Envoy's full config graph (Listener → FilterChain → Filter → Route → Cluster → Endpoint)
2. Explain how xDS APIs (LDS, RDS, CDS, EDS, SDS) enable dynamic configuration and what control planes do
3. Debug common failure modes (NR, UH, UF, TLS handshake failures) using Envoy's admin interface
4. Design traffic management strategies using priority-based load balancing, locality-aware routing, and weighted cluster shifting
5. Understand circuit breaking, outlier detection, retry budgets, and timeout hierarchies
6. Map high-level platform abstractions (Gateway API, VirtualService, TrafficPolicy) to low-level Envoy primitives
7. Reason about multi-cluster routing, east-west gateway design, and tier-2 failover patterns
8. Articulate identity propagation models (SPIFFE/SPIRE, Istio identity, workload certificates) and isolation boundaries

## Topics

### 01. Envoy Architecture: Core Primitives

Deep dive into Envoy's request processing model, configuration graph, xDS protocol, threading model, hot restart, admin interface, and debugging techniques. This is the foundation for everything else.

**Time estimate:** 6-8 hours (including lab exercises)

### 02. Traffic Management Internals

Priority-based load balancing, locality-aware routing, weighted cluster shifting, load balancing algorithms, outlier detection, circuit breaking, retry policies, timeout hierarchy, rate limiting, and failover patterns.

**Time estimate:** 6-8 hours (including lab exercises)

### 03. Gateway API vs Istio vs Platform Abstractions

Comparing Kubernetes Gateway API, Istio VirtualService/DestinationRule, Envoy Gateway, and custom platform abstractions. Understanding the layering, trade-offs, and when to use each.

**Time estimate:** 4-6 hours

### 04. Multi-Cluster Routing: East-West Gateway and Tier-2 Failover

East-west gateways for cross-cluster communication, tier-2 failover architectures, control plane federation models, service discovery across clusters, and operational patterns for multi-cluster mesh.

**Time estimate:** 5-7 hours

### 05. Identity Propagation and Isolation Boundaries

SPIFFE/SPIRE, Istio identity model, workload certificates, JWT propagation, AuthN/AuthZ policies, network boundaries vs workload identity boundaries, and multi-tenancy isolation strategies.

**Time estimate:** 5-7 hours

## Suggested Study Order

1. **Start with 01-envoy-architecture-core-primitives**: You cannot reason about service mesh behavior without understanding the Envoy config graph and xDS protocol. Complete the lab to build muscle memory.

2. **Move to 02-traffic-management-internals**: Traffic management is where Envoy shines. Understand the primitives (priority, locality, weights, health checks, outlier detection) before layering on control plane abstractions.

3. **Study 03-gateway-api-vs-istio-vs-platform-abstractions**: Now that you understand the primitives, learn how different control planes and APIs map high-level intent to Envoy config.

4. **Advance to 04-multicluster-routing-ewgw-tier2**: Multi-cluster patterns combine everything you've learned. East-west gateways are just specialized Envoy instances with specific routing logic.

5. **Finish with 05-identity-propagation-and-isolation-boundaries**: Identity and isolation are cross-cutting concerns. Understanding them last allows you to see how they integrate with routing, traffic management, and multi-cluster patterns.

## Interview Focus Areas

For staff+ platform, infrastructure, or service mesh roles, expect deep technical discussions in these areas:

### Design Depth
- How would you design a multi-tenant gateway platform? What isolation boundaries would you enforce?
- How would you implement gradual traffic migration between clusters without dropping requests?
- What's your strategy for rolling out mesh upgrades (control plane and data plane) with zero downtime?

### Operational Expertise
- Walk me through debugging a "503 UH" error in production. What would you check first?
- How do you tune circuit breaker settings for a high-throughput service?
- Explain how you'd detect and mitigate a retry storm before it cascades.

### Architectural Trade-offs
- When would you use a sidecar model vs a node-local proxy (e.g., Linkerd2-proxy vs Envoy)?
- Compare the Gateway API to Istio's VirtualService/DestinationRule model. What are the trade-offs?
- Should east-west gateways live in the data plane or control plane cluster? Why?

### Production Scenarios
- You have 10ms p99 latency requirement. How does adding a sidecar impact this? How do you measure and optimize?
- A certificate rotation broke mTLS across 50% of the mesh. How do you recover?
- You need to deprecate an old service version. How do you use weighted routing to drain traffic safely?

## Real-World Context

These concepts are directly applicable to:

- **Istio**: The most popular service mesh, built on Envoy. Control plane generates xDS snapshots for sidecar and gateway Envoy instances.
- **Envoy Gateway**: Kubernetes-native API Gateway implementation of the Gateway API, powered by Envoy.
- **Linkerd**: Lightweight service mesh with its own Rust-based proxy, but shares many conceptual patterns with Envoy-based meshes.
- **Consul Connect**: HashiCorp's service mesh supporting both Envoy and a native proxy.
- **AWS App Mesh**: Managed service mesh using Envoy as the data plane.
- **Google Traffic Director**: GCP's fully managed service mesh control plane for Envoy.

## Study Tips

- **Run the labs**: Envoy's behavior is often counterintuitive until you see it in action. Running the labs and inspecting `/config_dump`, `/clusters`, and `/stats` builds intuition.
- **Read real config**: Find Istio-generated Envoy config (`istioctl proxy-config`) or Envoy Gateway config and trace the graph from listener to endpoint.
- **Draw diagrams**: Sketch the config graph, xDS flow, and multi-cluster topology on paper. Visual models help in interviews.
- **Practice talk tracks**: You'll be asked to "walk me through how Envoy handles this request" or "explain circuit breaking vs outlier detection." Practice crisp, accurate answers.
- **Know the failure modes**: Interviewers love operational depth. Memorize the common Envoy response flags (NR, UH, UF, URX, DC) and what causes them.

## Additional Resources

- [Envoy Documentation](https://www.envoyproxy.io/docs/envoy/latest/)
- [Envoy xDS Protocol](https://www.envoyproxy.io/docs/envoy/latest/api-docs/xds_protocol)
- [Istio Architecture](https://istio.io/latest/docs/ops/deployment/architecture/)
- [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/)
- [SPIFFE/SPIRE Documentation](https://spiffe.io/docs/)

---

**Total estimated time for this week:** 26-36 hours

This is dense material. Budget 4-6 hours per day over a week, or spread it over two weeks if working full-time. The investment pays off — service mesh expertise is highly valued in platform engineering roles.
