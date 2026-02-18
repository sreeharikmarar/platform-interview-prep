# Lab: Capstone — Design a Next-Gen Platform

This lab is a design exercise, not a hands-on cluster lab. You'll produce a platform design document, architecture diagrams, failure mode analysis, and a spoken talk track. This simulates the system design interview format where you present and defend an architecture.

## Prerequisites

- Markdown editor (VS Code, Obsidian, or any text editor)
- Drawing tool for architecture diagrams (Excalidraw, draw.io, or ASCII in your editor)
- All previous weeks completed (weeks 01-04 topics 01-04)
- 2-3 hours of focused time

## Step-by-Step Instructions

### 1. Initialize the design document

```bash
# Copy the design template to your working directory
cp lab/design-template.md design-doc.md
```

**What's happening**: The template provides section headers and guiding questions for each area of the platform design. Your job is to fill in every section with concrete decisions, specific technology choices, and trade-off reasoning.

**Guidance**:
- Write as if you're preparing a design doc for your team — specific enough to implement, not vague hand-waving
- Every technology choice should have a "why" and a "what we considered instead"
- Use concrete numbers where possible (how many namespaces, pods, clusters, GPUs)
- Reference patterns from weeks 01-04 by name (e.g., "level-triggered reconciliation" not just "controller")

**Review criteria**: Each section should be 150-300 words with at least one concrete decision and one trade-off acknowledged.

---

### 2. Draw the hub-spoke architecture diagram

Create an architecture diagram showing the control flow and data flow between components.

**Required elements**:
- Hub cluster with: ArgoCD, platform controllers, Istiod/xDS control plane, policy engine, cluster registry
- 2-3 spoke clusters with: tenant namespaces, Envoy sidecars, ingress gateway, east-west gateway
- At least one GPU-enabled spoke with inference gateway
- Control flow arrows: Git -> ArgoCD -> Hub controllers -> Hub etcd -> ArgoCD -> Spokes
- Data flow arrows: Client -> DNS -> Ingress GW -> Sidecar -> Workload
- Identity flow: SPIRE hub CA -> SPIRE agents -> Envoy SDS

**Guidance**:
- ASCII art is perfectly acceptable — clarity matters more than aesthetics
- Label every arrow with what flows over it (xDS, mTLS, ArgoCD sync, etc.)
- Show the separation between control plane (hub) and data plane (spokes)

**Review criteria**: Someone unfamiliar with your design should be able to trace a request from client to backend and understand where each policy enforcement point lives.

---

### 3. Draw the tenant HTTP request path

Create a detailed request path diagram for a tenant's HTTP request flowing through the platform.

**Required elements**:
- External client
- DNS resolution
- Ingress gateway (TLS termination, rate limiting)
- Envoy sidecar (mTLS, AuthorizationPolicy)
- Application container
- Response path back

**At each hop, annotate**:
- What security check happens (TLS, mTLS, RBAC, AuthZ)
- What observability signal is emitted (access log, trace span, metric)
- What failure mode is possible (timeout, circuit break, 403, 503)

**Guidance**:
```
Client -> [DNS] -> Ingress GW -> [mTLS] -> Sidecar -> App -> Response
              |         |              |          |
           DNS miss   rate limit    AuthzPolicy  app error
           -> NXDOMAIN -> 429       -> 403       -> 500
```

**Review criteria**: For each hop, you should be able to name the failure mode, the metric that detects it, and the mitigation.

---

### 4. Draw the inference request path

Create a request path diagram for an AI inference request.

**Required elements**:
- Client sending inference request with model name in header/body
- Inference gateway (model routing, token budget check, queue admission)
- GPU pod (vLLM/TGI serving)
- Streaming response with token counting
- Budget decrement on response completion

**At each stage, annotate**:
- What decision is made (which model version, which backend, admit or reject)
- What metric is emitted (TTFT, tokens/sec, queue depth, budget remaining)
- What the failure mode is (budget exceeded -> 429, queue full -> 503, GPU OOM -> 500)

**Review criteria**: You should be able to explain why token-rate limiting is different from request-rate limiting and where KV cache affinity helps.

---

### 5. Write the failure mode analysis

Pick 3 failure scenarios from the list below (or create your own) and write a full analysis for each.

**Scenario options**:
- A platform controller release generates invalid VirtualService objects
- A spoke cluster's Kyverno policy version drifts behind the hub
- etcd quota is exhausted on the hub cluster
- A noisy tenant exhausts their token budget and gets 429s, but the budget window is misconfigured
- Spot instance reclaim removes GPU nodes, leaving InferenceService pods Pending
- A cross-cluster service call fails because the east-west gateway certificate expired

**For each scenario, write**:
- **Symptoms**: What the tenant sees, what the on-call engineer sees in dashboards
- **Root cause**: The underlying technical failure
- **Blast radius**: How many tenants/services are affected
- **Detection**: Which metric or alert fires first
- **Mitigation**: Immediate fix and long-term prevention
- **Debugging commands**: 3-5 specific kubectl/istioctl/etcdctl commands

**Review criteria**: Each failure analysis should be 200-400 words and include at least 3 specific debugging commands.

---

### 6. Write the 10-minute spoken talk track

Write a script you can deliver in ~10 minutes covering:

**Minute 1-2: Problem and approach** (the "one-minute summary" expanded)
- What problem does the platform solve?
- What's the key architectural insight (intent vs realization)?

**Minute 3-5: Architecture walkthrough**
- Hub-spoke topology with control and data flow
- Walk through the AppService lifecycle from Git push to running pod
- Multi-tenancy isolation layers

**Minute 6-7: Inference gateway deep dive**
- How AI workloads differ from traditional HTTP services
- Token-rate limiting and GPU-aware routing
- InferenceService CRD to running model

**Minute 8-9: Failure modes and operations**
- Pick 2 failure scenarios and walk through detection and mitigation
- Progressive rollout strategy for platform changes

**Minute 10: Evolution and trade-offs**
- What you'd build in year 1 vs year 3
- Key trade-offs you made and why

**Guidance**:
- Write it as prose, not bullet points — this is for speaking out loud
- Practice delivering it with a timer
- You should be able to answer follow-up questions on any section
- The goal is demonstrating depth, not breadth — it's better to go deep on 2-3 areas than shallow on everything

**Review criteria**: Read the script aloud. If it takes less than 8 minutes or more than 12 minutes, adjust. Every sentence should convey a specific technical decision or trade-off, not filler.

---

## Deliverables

After completing this lab, you should have:

```
design/
├── design-doc.md          # Completed design document (from template)
├── architecture-diagram   # Hub-spoke architecture (ASCII, PNG, or SVG)
├── request-path-diagram   # Tenant HTTP request flow
├── inference-path-diagram # AI inference request flow
├── failure-analysis.md    # 3 failure scenarios with full analysis
└── talk-track.md          # 10-minute spoken script
```

## Key Takeaways

1. **System design interviews test decision-making, not knowledge**: The interviewer wants to hear your trade-off reasoning, not a recitation of features. "I chose X because Y, and the trade-off is Z" is stronger than "X is the best practice."
2. **Concrete beats abstract**: "We use Istio AuthorizationPolicy checking SPIFFE SVIDs" is stronger than "we have identity-based access control." Name the actual resources, fields, and protocols.
3. **Failure modes demonstrate depth**: Anyone can draw a happy-path architecture. Describing what breaks and how you detect and recover from it shows production experience.
4. **The compiler analogy is powerful**: Framing the platform as "frontend (CRDs) -> IR (internal objects) -> backend (xDS, cloud APIs)" gives the interviewer a mental model they can hang follow-up questions on.
5. **Evolution shows maturity**: Describing what you'd build first and what you'd defer shows you understand that platforms are products with iterative roadmaps, not one-shot architectures.
