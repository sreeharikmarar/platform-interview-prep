# Week 02: Operators and Platform APIs

## Overview

This week focuses on building production-grade Kubernetes controllers and operators. You'll go beyond basic Kubernetes usage to understand how to extend the platform itself, building the same patterns used by operators like cert-manager, external-dns, crossplane, and ArgoCD.

Controllers are the heart of Kubernetes' declarative model. They reconcile desired state (spec) with actual state (status), handle failures gracefully, and enable self-healing infrastructure. Mastering controller patterns is essential for platform engineers building internal developer platforms, custom resource abstractions, and infrastructure automation.

## Week Objectives

By the end of this week, you should be able to:

- Build a production-ready Kubernetes controller from scratch using controller-runtime
- Explain and implement informers, caches, and indexers for efficient resource watching
- Configure leader election for high-availability controller deployments
- Version and evolve CRDs safely with conversion webhooks
- Design ownership boundaries between GitOps and controller reconciliation
- Debug controller performance issues, reconciliation storms, and cache inconsistencies
- Discuss trade-offs in controller architecture during technical interviews

## Prerequisites

Before starting this week, you should have:

- Strong understanding of Kubernetes API fundamentals (Week 01)
- Familiarity with Go programming language (controller examples use Go)
- Access to a Kubernetes cluster (kind, minikube, or cloud cluster)
- `kubectl`, `go` (1.21+), and `kubebuilder` installed
- Basic understanding of client-go and API machinery concepts

## Topics

### 01. Build a Controller from Scratch
**Focus**: Spec/status contracts, finalizers, idempotent reconciliation

Learn the fundamental patterns for building controllers: designing clear spec/status contracts, using finalizers for safe deletion, and keeping reconciliation idempotent. Covers the Reconcile loop, status conditions, observedGeneration, and defensive programming patterns.

**Key concepts**: Reconcile loop, finalizers, status conditions, create-or-patch, observedGeneration

**Estimated time**: 4-6 hours

### 02. Informers, Caches & Indexers
**Focus**: Scaling watches, efficient resource lookups, cache consistency

Understand how controllers efficiently watch thousands of resources without overloading the API server. Covers LIST+WATCH mechanics, shared informer factories, cache indexers, and the trade-offs between cache freshness and scalability.

**Key concepts**: SharedInformerFactory, cache.Store, ResourceEventHandler, custom indexers, resync periods

**Estimated time**: 3-4 hours

### 03. Leader Election & HA Controllers
**Focus**: Multi-replica controllers, Lease-based coordination, sharding

Learn how to run controllers in high-availability mode with multiple replicas. Covers Lease-based leader election, takeover behavior, fencing tokens, and when to shard controllers across multiple leaders.

**Key concepts**: Lease resources, leader election, fencing, split-brain prevention, controller sharding

**Estimated time**: 3-4 hours

### 04. CRD Versioning & Conversion
**Focus**: API evolution, served vs storage versions, conversion webhooks

Master safe CRD evolution strategies for long-lived platform APIs. Covers versioning strategies (v1alpha1 → v1beta1 → v1), conversion webhooks, storage version migration, and maintaining round-trip compatibility.

**Key concepts**: Served vs storage versions, conversion webhooks, round-trip preservation, migration strategies

**Estimated time**: 4-5 hours

### 05. GitOps vs Controller Reconciliation
**Focus**: Ownership boundaries, SSA field managers, drift prevention

Understand the interaction between GitOps tools (ArgoCD, Flux) and custom controllers. Covers Server-Side Apply (SSA) field managers, ownership conflicts, drift detection, and designing clear boundaries between declarative Git state and controller-managed state.

**Key concepts**: Server-Side Apply, field managers, ownership conflicts, drift detection, reconciliation boundaries

**Estimated time**: 3-4 hours

## Suggested Study Order

1. **Start with 01-build-a-controller-from-scratch**: This establishes foundational controller patterns you'll use throughout the week.

2. **Move to 02-informers-caches-indexers**: Once you understand the reconcile loop, learn how controllers efficiently watch resources at scale.

3. **Then 03-leader-election-and-ha-controllers**: With the basics in place, learn how to run controllers in production with multiple replicas.

4. **Continue to 04-crd-versioning-and-conversion**: Now that you can build and run controllers, learn how to evolve your APIs over time.

5. **Finish with 05-gitops-vs-controller-reconciliation**: Synthesize everything by understanding how controllers interact with GitOps tooling in real platform environments.

## Study Approach

Each topic includes:

- **README.md**: Comprehensive technical deep-dive with code examples
- **talk-tracks.md**: Interview-ready explanations and common follow-up questions
- **lab/**: Hands-on exercises to reinforce concepts

Recommended approach:

1. Read the README.md thoroughly, taking notes on key concepts
2. Review talk-tracks.md and practice explaining concepts out loud
3. Complete the lab exercise, experimenting beyond the basic steps
4. Revisit README.md to connect lab observations with theory

## Interview Focus Areas

Platform engineering interviews at senior+ levels often focus on:

- **Controller design patterns**: Can you design clean spec/status contracts? Do you understand finalizers and deletion safety?
- **Production considerations**: How do you handle leader election, cache consistency, and reconciliation performance at scale?
- **API evolution**: Can you version CRDs safely? Do you understand the risks of conversion webhooks?
- **Platform architecture**: How do controllers fit into GitOps workflows? Where do ownership boundaries belong?
- **Debugging skills**: Can you debug reconciliation storms, cache staleness, and leader flapping?

This week prepares you to discuss these topics with depth and production experience.

## Real-World Context

The patterns you'll learn this week are used by:

- **cert-manager**: Manages TLS certificates with finalizers for cleanup and status conditions for certificate readiness
- **external-dns**: Uses leader election for HA and reconciles DNS records from Ingress/Service resources
- **crossplane**: Heavy use of CRD versioning and conversion for evolving infrastructure APIs
- **ArgoCD/Flux**: Implements GitOps reconciliation with SSA field managers to coexist with other controllers
- **Istio/Linkerd**: Watches Service/Pod resources with informers and indexers for efficient service mesh configuration

Understanding these patterns makes you a more effective consumer and builder of operator-based platforms.

## Additional Resources

- [Kubebuilder Book](https://book.kubebuilder.io/) - Comprehensive guide to building operators
- [controller-runtime Documentation](https://pkg.go.dev/sigs.k8s.io/controller-runtime) - Core library API docs
- [client-go Documentation](https://pkg.go.dev/k8s.io/client-go) - Lower-level client library
- [Kubernetes Sample Controller](https://github.com/kubernetes/sample-controller) - Reference implementation
- [Writing Controllers](https://kubernetes.io/docs/concepts/architecture/controller/) - Official Kubernetes docs

## Next Steps

After completing this week:

- **Week 03**: Service mesh, Envoy, and API gateways - apply controller patterns to understand how service meshes work
- **Week 04**: Distributed systems at scale - use your controller knowledge to understand coordination, consistency, and failure handling in distributed systems
