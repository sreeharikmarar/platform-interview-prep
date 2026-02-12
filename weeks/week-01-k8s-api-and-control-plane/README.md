# Week 01: Kubernetes API and Control Plane

## Overview

This week covers the foundational control plane components and patterns that power Kubernetes orchestration. You'll develop a deep understanding of how the API server processes requests, how state changes propagate through the system, and how controllers maintain desired state. This knowledge is critical for platform engineering roles where you design multi-tenant infrastructure, build operators, or debug production incidents in distributed systems.

## Learning Objectives

By the end of this week, you should be able to:

- Trace a Kubernetes API request from authentication through admission to etcd persistence and watch notification
- Explain eventual consistency semantics, resourceVersion, and generation/observedGeneration patterns
- Apply Server-Side Apply (SSA) correctly in multi-actor scenarios and resolve field ownership conflicts
- Design idempotent, level-triggered controllers using informers and work queues
- Configure admission webhooks and policies with appropriate failure modes and scope
- Diagnose scheduler placement failures using filter/score/bind mental models and pod events

## Topics

1. **API Machinery & Object Lifecycle** - Request path, etcd interactions, resourceVersion, eventual consistency
2. **Apply, SSA & Patch Semantics** - Field ownership, managedFields, conflict resolution, patch types
3. **Controllers, Reconciliation & Work Queues** - Level-triggered reconciliation, informers, idempotency
4. **Admission Webhooks & Policy** - Mutating/validating webhooks, ValidatingAdmissionPolicy, failure modes
5. **Scheduler & Placement** - Filter/score/bind, taints/tolerations, affinity, preemption

## Suggested Study Order

1. **API Machinery** first - Establishes the foundation for how Kubernetes stores and watches state
2. **Controllers** second - Builds on API machinery to understand the reconciliation pattern
3. **Apply & SSA** third - Adds detail on how clients safely mutate state with multiple actors
4. **Admission** fourth - Covers write-path validation and mutation hooks
5. **Scheduler** fifth - Specialized controller for pod placement decisions

Each topic takes 2-3 hours including reading, lab, and talk track practice.

## Connection to Platform Engineering

These patterns appear repeatedly in platform engineering and multi-tenant cluster management:

- **Multi-tenant resource quotas**: Admission webhooks enforce tenant quotas and policy boundaries (allowed registries, required security contexts) before workloads reach etcd
- **GitOps reconciliation**: Controllers watching cluster state and reconciling toward Git-declared state use the same watch/informer/workqueue pattern as built-in Kubernetes controllers
- **Custom resource operators**: Platform teams build operators that extend Kubernetes with domain-specific resources (databases, message queues, certificates) using controller patterns
- **Infrastructure placement**: Scheduler affinity/anti-affinity ensures ingress controllers and critical platform services spread across failure domains and avoid resource contention
- **Field ownership coordination**: SSA field managers prevent platform-managed infrastructure config from conflicting with tenant application manifests

## Prerequisites

- Running Kubernetes cluster (kind script provided in `/scripts/kind-up.sh`)
- kubectl 1.28+
- Basic familiarity with YAML manifests and kubectl apply
- Go types/interfaces are referenced but not required for labs
