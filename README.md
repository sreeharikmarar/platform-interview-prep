# Platform Interview Prep — 5 Weeks

A structured, hands-on curriculum for senior/staff platform engineer and infrastructure interviews. Covers Linux foundations, container internals, cloud networking, Kubernetes internals, operator patterns, Envoy and service mesh, and distributed systems at scale.

## Why this repo exists

Platform engineering interviews at the senior+ level go far beyond "deploy a pod." Interviewers expect you to reason about API machinery internals, explain how controllers reconcile state, diagnose scheduler failures, and design multi-cluster gateway architectures — all while articulating trade-offs and failure modes clearly.

This repo is a 5-week study plan that builds that depth systematically, starting with Linux and container foundations (week 00) before progressing to Kubernetes internals and distributed systems. Each topic pairs deep conceptual understanding with runnable labs and rehearsed talk tracks so you can both *understand* and *articulate* the material under interview pressure.

## What's inside

Each of the 25 topics follows a consistent format:

| File | Purpose |
|------|---------|
| `README.md` | Mental model, detailed internals, architecture diagrams, key concepts, failure modes with debugging steps |
| `talk-tracks.md` | Interview-style Q&A — concise answers you can rehearse and adapt |
| `lab/` | Lightweight, runnable exercises (Kind cluster) with step-by-step instructions and observations |

## Weekly curriculum

| Week | Theme | Topics |
|------|-------|--------|
| **00** | Linux, Containers & Cloud Networking | Linux processes/signals/filesystem, cgroups & namespaces, container internals (OCI/runtimes), container networking (CNI/pod model), cloud networking (VPC/IP planning) |
| **01** | Kubernetes API & Control Plane | API machinery & object lifecycle, SSA & patch semantics, controllers & reconciliation, admission webhooks & policy, scheduler internals |
| **02** | Operators & Platform APIs | Build a controller from scratch, informers/caches/indexers, leader election & HA, CRD versioning & conversion, GitOps vs controller reconciliation |
| **03** | Service Mesh, Envoy & Gateways | Envoy architecture & core primitives, traffic management internals, Gateway API vs Istio vs platform abstractions, multi-cluster routing, identity propagation & isolation |
| **04** | Distributed Systems & Scale | Control plane scale (etcd/apiserver), backpressure & rate limiting, inference gateways & routing, agentic workflows & control loops, capstone platform design |

## How to use this repo

1. **Study one topic per day** (roughly 1-2 hours). Read the README, then run the lab.
2. **Rehearse talk tracks out loud.** The goal is fluency, not memorization — adapt the answers to your own experience.
3. **Follow the interview rubric** (see below) when practicing answers to any question.
4. **Build on it.** The talk tracks and labs are starting points. Add your own production stories and extend the labs.

## Interview rubric — how to sound Staff+

Every answer should follow this structure:

1. **Mental model first** — one-sentence framing of the concept
2. **Internals** — critical path, component names, ordering
3. **Trade-offs** — why this design, what alternatives exist
4. **Failure modes + observability** — what breaks, how you detect and mitigate it
5. **Production story** — one concrete example from your experience

## Repo structure

```
README.md                    # This file
scripts/
  kind-up.sh               # Spin up a Kind cluster for labs
  kind-down.sh             # Tear down the Kind cluster
weeks/
  week-00-linux-containers-and-cloud-networking/
  week-01-k8s-api-and-control-plane/
  week-02-operators-and-platform-apis/
  week-03-service-mesh-envoy-gateways/
  week-04-distributed-systems-scale-and-ai/
```

## Prerequisites

- Linux machine or VM (week 00 labs use `unshare`, `nsenter`, `/proc`, cgroup filesystem)
- Docker and [Kind](https://kind.sigs.k8s.io/) for local clusters
- `kubectl`, `yq`, and `jq`
- Familiarity with Kubernetes at the practitioner level (you've run clusters in production before)
- Week 00 (Linux/containers/networking) is a prerequisite for weeks 01-04 — start there if you're unsure about container primitives
