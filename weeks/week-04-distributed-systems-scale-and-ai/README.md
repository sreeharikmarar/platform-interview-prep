# Week 04: Distributed Systems, Scale, and AI

## Overview

This week covers the advanced topics that distinguish senior and staff platform engineers: control plane scalability at the thousands-of-nodes level, distributed systems resilience patterns (backpressure, circuit breaking, overload protection), the emerging domain of AI/ML inference infrastructure, and agentic automation using LLM-driven control loops. These topics require synthesizing the foundational knowledge from weeks 01-03 and applying it to real-world problems at scale.

## Learning Objectives

By the end of this week, you should be able to:

- Diagnose and resolve control plane scalability bottlenecks in etcd, API server, and watch infrastructure at the 5,000+ node scale
- Design overload protection systems using retry budgets, circuit breakers, load shedding, and API Priority and Fairness
- Architect inference gateways that route AI workloads by model version, enforce per-tenant token budgets, and manage GPU-aware queue admission
- Apply Kubernetes reconciliation patterns to agentic workflows with appropriate safety boundaries, audit trails, and progressive rollout
- Debug cascading failures in distributed systems by tracing through asynchronous propagation paths and identifying amplification loops

## Topics

1. **Control Plane Scale: etcd, API Server, Watch Scalability, Sharding** - etcd write amplification and Raft consensus, API server admission latency, watch cache fan-out, API Priority and Fairness, controller sharding, separate etcd clusters
2. **Backpressure, Rate Limiting & Overload Protection** - Retry budgets, circuit breakers, load shedding, fairness and priority queuing, timeout hierarchy, metastable failures, Little's Law
3. **Inference Gateways & L7 Routing for AI Workloads** - Model-version routing, token-rate limiting, GPU-aware scheduling, queue-aware load balancing, canary for models, KV cache affinity, InferenceModel/InferencePool patterns
4. **Agentic Workflows & MCP-Style Control Loops** - Agent-as-reconciler pattern, MCP protocol, idempotent tool design, safety boundaries, blast-radius limits, audit and observability, progressive rollout

## Suggested Study Order

1. **Control Plane Scale** first - Establishes the foundation for understanding what breaks at scale and why. Directly builds on the API machinery and controller patterns from week 01.
2. **Backpressure & Rate Limiting** second - Builds on control plane scaling by introducing the distributed systems resilience patterns that protect services at scale. Connects Envoy knowledge from week 03 to overload protection.
3. **Inference Gateways** third - Applies L7 routing knowledge from week 03 to the AI domain. Requires understanding of queue theory and rate limiting from topic 02.
4. **Agentic Workflows** fourth - Extends the controller reconciliation pattern from week 01 into LLM-driven automation. Ties safety patterns to the platform engineering context.

Each topic takes 5-8 hours including reading, lab, and talk track practice.

## Connection to Platform Engineering

These patterns appear repeatedly in production platform engineering at scale:

- **Multi-tenant cluster sizing**: Understanding etcd write amplification and API server admission latency directly informs how many tenants a single cluster can support and when to shard
- **Shared gateway resilience**: Backpressure and circuit breaking patterns protect shared API gateways from noisy-neighbor effects, preventing one tenant's retry storm from cascading to others
- **GPU infrastructure management**: Inference gateways with token-rate limiting and queue-aware routing are essential for running shared AI/ML platforms where GPU time is the most expensive resource
- **Automated operations**: Agentic workflows with safety boundaries enable platform teams to automate migrations, incident response, and capacity planning without introducing uncontrolled blast radius

## Prerequisites

- Weeks 01-03 completed (API machinery, controllers, operators, service mesh, Envoy)
- Running Kubernetes cluster (kind script provided in `/scripts/kind-up.sh`)
- kubectl 1.28+
- Docker (for Envoy and backend container labs)
- etcdctl (for control plane scale lab)
- Familiarity with Envoy configuration (covered in week 03)
- Basic understanding of LLM inference concepts (prompts, tokens, streaming responses)
