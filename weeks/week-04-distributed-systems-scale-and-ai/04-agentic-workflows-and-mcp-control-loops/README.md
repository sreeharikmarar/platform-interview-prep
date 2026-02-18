# Agentic Workflows & MCP-Style Control Loops

## What you should be able to do

- Explain how an agent control loop maps directly onto the Kubernetes reconciliation pattern, naming each phase and its safety invariants.
- Describe MCP (Model Context Protocol) and articulate why standardized tool interfaces matter for building safe, auditable agentic automation.
- Identify the four highest-risk failure modes in agentic workflows and give concrete mitigations for each.
- Walk through a complete Ingress-to-Gateway API migration agent: discovery, translation, dry-run validation, canary apply, verification, and rollback.

---

## Mental Model

The best mental model for understanding agentic workflows is the Kubernetes controller. A Kubernetes controller runs a reconciliation loop: it observes the current state of the cluster, computes a diff against desired state, acts by making API calls to close that gap, updates its own status to reflect what it did, and then waits for the next trigger. An AI agent runs exactly the same loop. It observes its environment — by calling tools that read cluster state, check service health, or query a metrics backend — then plans a sequence of actions by reasoning over the observations, acts by calling write-capable tools, verifies that the actions had the intended effect, and reconciles any discrepancy before declaring success. The cognitive difference between a Kubernetes controller and an agent is that a controller's "plan" is hardcoded into its reconcile function, while an agent's plan is generated at runtime by a language model. Everything else — the safety properties you need, the audit requirements, the idempotency constraints, the rollback mechanisms — is identical.

This isomorphism is not a metaphor. It has direct operational consequences. Level-triggered reconciliation, the core property of Kubernetes controllers, means the controller does not care whether it is responding to a create event or an update event or a periodic re-sync: it always computes desired minus actual and closes the gap. An agent built on the same principle should not care whether it is responding to a human request, an alert, or a scheduled trigger: it should always read current state first, never assume the state from its previous run is still valid, and always verify after each action. This is the antidote to the most common agentic failure mode: acting on stale observations. A controller that tried to "remember" cluster state across reconcile invocations would be dangerous; an agent that trusts its context window as a ground-truth representation of cluster state is equally dangerous.

Safety boundaries in a Kubernetes controller come from RBAC: the controller's ServiceAccount is granted exactly the permissions it needs and nothing more. The same principle applies to agentic automation. Every tool an agent can call represents a potential blast radius. A tool that can delete arbitrary namespaces is as dangerous in an agent's hands as it would be if given to a junior engineer with a bash script. Least-privilege tool design means read tools are always safe and should never require confirmation, write tools that are reversible require a diff or dry-run before execution, and destructive or irreversible write tools require an explicit human approval gate before the agent proceeds. This is not an LLM-specific concern: it is the same defense-in-depth you would apply to any automation system. The LLM just makes the authorization decisions at runtime rather than at code-compile time, which raises the stakes for getting the permission boundaries right.

The final property worth internalizing is progressive rollout. Kubernetes deployments roll out incrementally — one pod at a time, with readiness gates blocking the next replica until the current one is healthy. An agent driving infrastructure changes should apply the same discipline: make the change to a canary cluster first, verify that synthetic traffic and real traffic behave correctly, and only then promote the change to production clusters. This is not about distrusting the agent; it is about acknowledging that any automation system — human-coded or LLM-generated — can have bugs, and the safest way to discover them is in an environment where the blast radius is bounded. The combination of least-privilege tools, idempotent tool design, dry-run validation, and canary-first rollout gives you a safety envelope within which you can trust agentic automation to operate unsupervised on routine changes, reserving human gates only for changes above a configurable risk threshold.

---

## Key Concepts

**MCP (Model Context Protocol)**: A standardized JSON-RPC-over-stdio or JSON-RPC-over-HTTP protocol for LLM-to-tool communication. The server exposes a `tools/list` endpoint returning a JSON Schema for each available tool, and the client (the LLM runtime) calls `tools/call` with a tool name and arguments. Think of MCP as xDS for agents: just as xDS decouples Envoy from its control plane by standardizing the resource discovery protocol, MCP decouples LLM reasoning from specific tool implementations by standardizing the call interface. An MCP server wrapping the Kubernetes API can expose tools like `kubectl_get`, `kubectl_apply`, `kubectl_diff`, and `kubectl_delete` with precise JSON Schema input validation and scope constraints.

**Agent as reconciler**: The structural equivalence between an agent and a Kubernetes controller. Tools are the agent's API clients. Tool results are the agent's status observations. The agent's generated plan is its reconcile function. The idempotency requirement, the status update discipline, and the retry-with-backoff pattern all carry over from controller design.

**Idempotent tool design**: A tool is idempotent if calling it twice with the same arguments produces the same result as calling it once. `kubectl apply` is idempotent because it computes a server-side diff and only writes if there is a change; `kubectl create` is not idempotent because a second call fails with `AlreadyExists`. Agents must be given idempotent write tools wherever possible, because re-execution on retry or re-plan must not produce duplicate resources.

**Dry-run and diff gating**: Before executing a write tool, the agent calls the equivalent dry-run tool to preview the effect. `kubectl apply --dry-run=server` sends the manifest to the API server, runs all admission webhooks, and returns what would change — without committing to etcd. The dry-run result is fed back into the agent's context so it can reason about whether the intended change matches the actual effect before proceeding.

**Blast-radius calculator**: A tool or heuristic in the safety layer that quantifies the impact of a proposed change. For a resource deletion, blast radius might be the number of Pods that would be terminated. For a Gateway route change, it might be the estimated percentage of traffic affected. Changes above a configurable blast-radius threshold require a human approval gate before the agent proceeds.

**Human approval gate**: A synchronous pause in the agent loop where the agent presents its plan and the computed blast radius to a human operator and waits for explicit approval before continuing. The gate is not optional for destructive or high-blast-radius actions. It is implemented as a tool call that blocks until a webhook or Slack interaction endpoint receives an approval signal.

**Audit log**: An append-only record of every tool call the agent made, every tool result it received, and the reasoning trace that connected observations to actions. The audit log must be written before the tool call completes so that a partial execution can be reconstructed. In Kubernetes terms, this maps to `kubectl --audit-log-path` — the API server records every mutating request regardless of outcome.

**Progressive rollout (canary-first)**: The discipline of applying agent-driven changes to a canary environment first, verifying correctness, and only then promoting to production. In code, this means the agent's tool set includes both `apply_to_staging` and `apply_to_production` tools, and the agent is instructed never to call `apply_to_production` before `verify_staging_health` returns success.

**Level-triggered observation**: Reading current cluster state from the API server at the start of every reconcile rather than relying on cached state from a previous run. The agent re-observes before every planning step, not once at session start. This prevents the stale-observation failure mode where the agent acts on a plan derived from a snapshot that no longer reflects reality.

**Tool scope scoping**: Limiting a tool's operational scope to a specific namespace, cluster, or resource type via parameters that are enforced server-side, not by the agent's reasoning. A `kubectl_apply` tool scoped to `namespace=staging` must reject calls that attempt to write to `kube-system` at the MCP server level, not rely on the LLM to never attempt it.

**Reconciliation trace**: The structured log of the agent's current loop iteration: what it observed, what diff it computed, what actions it took, and what verification it ran. The trace is the agent's equivalent of a controller's reconcile log and is the primary debugging artifact when the agent makes an unexpected change.

---

## Internals

### Agent Control Loop Architecture

The agent control loop has five phases, each with a distinct safety responsibility. The phases are not a suggestion: skipping any phase — particularly the verify phase — is how agentic automation causes production incidents.

**Phase 1: Observe**

The agent calls read-only tools to construct a ground-truth snapshot of the environment relevant to its goal. For a migration agent, this means listing all Ingress resources across target namespaces, reading their annotations and spec, listing existing Gateway and HTTPRoute resources to detect partial prior runs, reading the current Gateway API CRD version to confirm schema compatibility, and checking DNS and TLS certificate state. Every read tool call returns a structured JSON result that the MCP client appends to the agent's context window. The observe phase is always idempotent and never requires human approval. It produces a structured observation document: a JSON object describing current state. The agent must not infer state — if a piece of state is not in the observation document, the agent must call a tool to read it before acting on it. This is the level-triggered principle applied to agent design.

**Phase 2: Plan**

The agent reasons over the observation document to produce a plan: an ordered list of tool calls with their arguments and the rationale for each step. The plan is not executed during the plan phase. It is written to the reconciliation trace as a proposed action sequence. A well-designed agent system renders the plan as a structured JSON object, not free-form prose, because structured plans can be validated against a schema before execution. The plan includes: the specific objects to create or modify, the expected before-state for each object (for drift detection), the expected after-state, and the verification steps that will confirm success. The plan document is what a human reviewer sees during the approval gate and is the primary artifact for understanding what the agent intends to do.

**Phase 3: Dry-run Validation**

Before executing any write operation, the agent calls dry-run tools for each planned write. `kubectl apply --dry-run=server` submits the manifest to the API server, runs all admission webhooks and validation, and returns the server's proposed response without writing to etcd. The dry-run result is compared against the expected after-state from the plan. If there is a mismatch — a webhook mutated the object in an unexpected way, a validation error was returned, or the object already exists with a conflicting owner — the agent halts, updates the plan, and re-enters the dry-run phase rather than proceeding to execution. This phase catches the largest class of agent errors: schema mismatches, permission errors, and conflicting state that was not visible during observation.

**Phase 4: Act**

The agent executes the planned write operations in order, one at a time. Each tool call is logged to the audit trail before the call is made. The agent checks the response from each tool call against the expected after-state. If a tool call returns an error, the agent does not continue to the next step: it halts, records the failure to the reconciliation trace, and evaluates whether the partial execution requires rollback. The act phase applies operations in dependency order: Gateway before HTTPRoute, HTTPRoute before deleting the old Ingress. Dependency ordering is not the agent's responsibility to reason about from scratch on every run — it must be encoded in the plan template or enforced by the tool definitions.

**Phase 5: Verify**

After all write operations complete, the agent calls verification tools to confirm that the intended outcome was achieved. Verification is not just checking that the objects were created: it means checking that traffic is flowing correctly, that health checks are passing, and that no error-rate spike appeared in the minutes following the change. For a Gateway API migration, verification includes: `kubectl get httproutes -n <namespace>` to confirm objects exist, `kubectl get gateway -n <namespace>` to confirm the gateway is programmed, and synthetic HTTP probes via curl or a dedicated health-check tool to confirm end-to-end routing. The verify phase is what distinguishes a safe agent from an automation script that fires and forgets. A failed verification triggers rollback, not retry.

---

### MCP Protocol Flow

MCP defines a client-server protocol where the LLM runtime is the client and tool implementations are servers. The flow for a single tool invocation is:

1. The MCP client calls `tools/list` on the server at session initialization. The server returns an array of tool descriptors, each with a `name`, `description`, and `inputSchema` (JSON Schema). The LLM receives these descriptors as part of its system context.
2. During the plan phase, the LLM selects a tool by name and generates a JSON arguments object that conforms to the tool's `inputSchema`. The MCP client validates the arguments against the schema before sending the call — this is the first validation layer and catches obvious type errors without a round-trip to the server.
3. The client sends a `tools/call` request with `{"name": "kubectl_apply", "arguments": {"manifest": "...", "namespace": "staging", "dry_run": true}}`. The server executes the tool, applies any server-side scope constraints (rejecting calls that attempt to write outside the allowed namespace regardless of what the arguments say), and returns a result object with `content` and `isError` fields.
4. The MCP client appends the result to the LLM's context as a tool result message. The LLM continues reasoning from the updated context. The entire exchange is logged to the reconciliation trace.

The critical security property of MCP is that scope constraints live in the server, not in the LLM prompt. Telling the LLM "only modify the staging namespace" in a system prompt is a soft constraint that can be overridden by prompt injection or model error. Enforcing namespace scope in the MCP server's tool handler is a hard constraint that no LLM reasoning can bypass.

---

### Tool Design Patterns

Tools fall into three safety tiers with different execution requirements.

**Tier 1: Read tools.** Always safe, never require confirmation, never require dry-run. Examples: `kubectl_get`, `kubectl_list`, `kubectl_describe`, `metrics_query`, `logs_fetch`. These can be called any number of times with no side effects. They form the observation and verification phases of the loop.

**Tier 2: Reversible write tools.** Require a dry-run before execution, logged before execution, but do not require human approval for changes below the blast-radius threshold. Examples: `kubectl_apply` (apply or update), `kubectl_patch`, `helm_upgrade`. These tools always accept a `dry_run: bool` parameter. The agent is instructed to call every write tool in dry-run mode first, verify the result matches the plan, and only then call it with `dry_run: false`.

**Tier 3: Destructive or irreversible write tools.** Require dry-run, blast-radius calculation, and human approval gate before execution. Examples: `kubectl_delete`, `namespace_delete`, `dns_record_delete`, `certificate_revoke`. The human approval gate is implemented as a blocking tool call: `request_human_approval(plan_summary, blast_radius)` which does not return until a human approves or rejects via an external interface (Slack bot, PagerDuty webhook, or web UI).

---

### Safety Architecture

The safety architecture has four independent layers. Each layer is a distinct control: they are not redundant alternatives but defense-in-depth.

**Layer 1: RBAC and tool scope.** The MCP server's Kubernetes client runs under a ServiceAccount with the minimum RBAC permissions needed for the agent's defined tasks. A migration agent needs `get`, `list` on Ingress, `create`, `update` on HTTPRoute and Gateway, and `get` on Services. It does not need `delete` on any namespace-scoped resource during the migration phase. Scope constraints in the MCP server enforce namespace targeting even if the LLM generates a request targeting the wrong namespace.

**Layer 2: Blast-radius calculator.** Before each write tool call (in non-dry-run mode), the safety layer computes a blast-radius estimate. For resource creates: zero (additive change). For resource updates: number of dependent pods affected, estimated traffic percentage rerouted. For resource deletes: number of currently-running workloads that depend on the deleted resource. If the blast radius exceeds a configurable threshold (e.g., more than 5% of production traffic), the action is automatically escalated to a human approval gate.

**Layer 3: Human approval gate.** For Tier 3 tool calls and for any action that exceeds the blast-radius threshold, the agent pauses and presents the plan, the dry-run diff, and the blast radius calculation to a human operator. The gate times out after a configurable window (default 30 minutes) and defaults to rejection on timeout, not approval. The approval event is logged to the audit trail.

**Layer 4: Rollback plan.** Before executing the act phase, the agent generates a rollback plan: the sequence of tool calls that would restore the prior state if verification fails. For a Gateway API migration, the rollback plan is: delete all created HTTPRoute and Gateway objects, verify the original Ingress objects are still present (they were not deleted during migration), and confirm traffic returns to the Ingress-based routing. The rollback plan is stored in the reconciliation trace and is automatically executed if the verify phase fails.

---

### Real Example: Ingress-to-Gateway API Migration Agent

This example walks through a complete agent execution for migrating three Ingress resources to Gateway API HTTPRoutes in a staging cluster.

**Observe phase:**

```
tool: kubectl_list
args: {"resource": "ingress", "namespace": "app", "output": "json"}
result: [
  {"name": "app-frontend", "host": "app.example.com", "paths": [{"path": "/", "backend": "frontend-svc:80"}]},
  {"name": "app-api",      "host": "api.example.com", "paths": [{"path": "/v1/*", "backend": "api-v1-svc:80"}, {"path": "/v2/*", "backend": "api-v2-svc:80"}]},
  {"name": "app-static",   "host": "static.example.com", "paths": [{"path": "/", "backend": "static-svc:80"}], "tls": [{"secretName": "static-tls", "hosts": ["static.example.com"]}]}
]

tool: kubectl_list
args: {"resource": "httproute", "namespace": "app", "output": "json"}
result: []  # no prior migration artifacts

tool: kubectl_get
args: {"resource": "crd", "name": "httproutes.gateway.networking.k8s.io"}
result: {"version": "v1", "served": true}  # Gateway API v1 is available
```

**Plan phase (structured plan document):**

```json
{
  "goal": "Migrate 3 Ingress resources in namespace 'app' to Gateway API HTTPRoutes",
  "steps": [
    {"id": 1, "action": "create", "resource": "Gateway", "name": "app-gateway", "namespace": "app", "rationale": "HTTPRoutes require a parent Gateway"},
    {"id": 2, "action": "create", "resource": "HTTPRoute", "name": "frontend-route", "namespace": "app", "parentRef": "app-gateway", "rationale": "Replace app-frontend Ingress"},
    {"id": 3, "action": "create", "resource": "HTTPRoute", "name": "api-route",      "namespace": "app", "parentRef": "app-gateway", "rationale": "Replace app-api Ingress with both paths"},
    {"id": 4, "action": "create", "resource": "HTTPRoute", "name": "static-route",   "namespace": "app", "parentRef": "app-gateway", "rationale": "Replace app-static Ingress with TLS"},
    {"id": 5, "action": "verify", "check": "http_probe", "targets": ["app.example.com", "api.example.com/v1/health", "api.example.com/v2/health", "https://static.example.com"]},
    {"id": 6, "action": "create_pr", "description": "Open PR to delete original Ingress resources after 48h soak period"}
  ],
  "rollback": [
    {"action": "delete", "resource": "HTTPRoute", "names": ["frontend-route", "api-route", "static-route"]},
    {"action": "delete", "resource": "Gateway", "name": "app-gateway"},
    {"action": "verify", "check": "ingress_status", "namespace": "app"}
  ]
}
```

**Dry-run phase:**

```
tool: kubectl_apply
args: {"manifest": "<gateway.yaml>", "namespace": "app", "dry_run": true}
result: {"created": "Gateway/app-gateway", "warnings": [], "admission_mutations": []}

tool: kubectl_apply
args: {"manifest": "<httproute-frontend.yaml>", "namespace": "app", "dry_run": true}
result: {"created": "HTTPRoute/frontend-route", "warnings": [], "admission_mutations": []}
# ... repeated for api-route and static-route
```

**Act phase (abbreviated):**

```
tool: kubectl_apply
args: {"manifest": "<gateway.yaml>", "namespace": "app", "dry_run": false}
result: {"created": "Gateway/app-gateway", "uid": "a1b2c3d4"}

tool: kubectl_apply
args: {"manifest": "<httproute-frontend.yaml>", "namespace": "app", "dry_run": false}
result: {"created": "HTTPRoute/frontend-route", "uid": "b2c3d4e5"}
# ... repeated for remaining routes

tool: audit_log_write
args: {"action": "ingress_to_gateway_migration", "namespace": "app", "created": ["Gateway/app-gateway", "HTTPRoute/frontend-route", "HTTPRoute/api-route", "HTTPRoute/static-route"]}
```

**Verify phase:**

```
tool: kubectl_get
args: {"resource": "gateway", "name": "app-gateway", "namespace": "app"}
result: {"status": {"conditions": [{"type": "Programmed", "status": "True"}]}}

tool: http_probe
args: {"url": "http://app.example.com/", "expected_status": 200}
result: {"status": 200, "latency_ms": 42}

tool: http_probe
args: {"url": "https://static.example.com/", "expected_status": 200}
result: {"status": 200, "tls_verified": true}
```

Verification passes. The agent writes a summary to the reconciliation trace, creates a PR to delete the original Ingress resources after a 48-hour soak period, and marks the loop as complete.

---

## Architecture Diagram

```
  +---------------------------------------------------------------------------+
  |                        AGENT CONTROL LOOP                                 |
  |                                                                           |
  |  +----------+    +----------+    +----------+    +----------+            |
  |  |  OBSERVE |    |   PLAN   |    | DRY-RUN  |    |   ACT    |            |
  |  | (read    |--->| (generate|--->| (validate|--->| (execute |            |
  |  |  tools   |    |  plan    |    |  diff)   |    |  writes) |            |
  |  |  only)   |    |  struct) |    |          |    |          |            |
  |  +----------+    +----------+    +----------+    +----+-----+            |
  |       ^                               |                |                  |
  |       |                        [mismatch]        [error]                  |
  |       |                               |                |                  |
  |       |                               v                v                  |
  |       |                          REPLAN           ROLLBACK                |
  |       |                                                                   |
  |       |              +----------+                                         |
  |       +<-------------|  VERIFY  |<--- (after all writes complete)         |
  |       |              | (read    |                                         |
  |       |              |  tools + |                                         |
  |       |              |  probes) |                                         |
  |       |              +----+-----+                                         |
  |       |                   |                                               |
  |       |              [fail]                                               |
  |       |                   v                                               |
  |       |             EXECUTE ROLLBACK                                      |
  |       |                                                                   |
  |  [next trigger]                                                           |
  +---------------------------------------------------------------------------+

  SAFETY GATES (at each -> transition):

  OBSERVE -> PLAN        No gate (read-only)
  PLAN -> DRY-RUN        Schema validation of plan struct
  DRY-RUN -> ACT         Blast-radius check; human gate if above threshold
  ACT -> VERIFY          Audit log written before each write
  VERIFY -> DONE         All http probes + kubectl status checks must pass
  VERIFY [fail] ->       Automatic rollback; page on-call if rollback fails

  MCP TOOL TIERS:

  Tier 1 (Read)          kubectl_get, kubectl_list, metrics_query, logs_fetch
  Tier 2 (Write/Rev.)    kubectl_apply, kubectl_patch, helm_upgrade
  Tier 3 (Destructive)   kubectl_delete, namespace_delete  [requires human gate]

  SCOPE ENFORCEMENT (MCP server layer, not LLM prompt):

  +---------------------------+
  |    MCP SERVER             |
  |  +-----------------------+|
  |  | RBAC: least-privilege ||
  |  | Namespace scope check ||
  |  | Blast-radius calc     ||
  |  | Dry-run enforcement   ||
  |  | Audit log write       ||
  |  +-----------------------+|
  +---------------------------+
```

---

## Failure Modes & Debugging

### Failure 1: Non-idempotent action repeated, creating duplicate resources

**Symptoms:** The agent creates duplicate HTTPRoute objects with different UIDs but identical names (if using `kubectl create` instead of `kubectl apply`), or creates multiple Gateway objects in the same namespace. Alternatively, a failed mid-loop run left some objects created, and on re-run the agent creates them again instead of detecting the prior partial execution. The symptom in the cluster is duplicate routes causing ambiguous routing behavior, or a `AlreadyExists` error causing the agent to halt and retry infinitely.

**Root Cause:** The agent's write tool is `kubectl_create` (not idempotent) rather than `kubectl_apply` (idempotent). Alternatively, the observe phase did not check for existing HTTPRoute objects before planning, so the plan included creates for objects that already exist from a prior partial run.

**Blast Radius:** Ambiguous routing (two HTTPRoute objects matching the same hostname and path causes implementation-defined precedence behavior), failed agent loop (the agent cannot make progress), potential traffic errors if conflicting routes are both programmed.

**Mitigation:** All write tools must be `kubectl apply` semantics. The observe phase must explicitly list all resource types that the act phase will create, and the plan phase must detect existing objects and emit `update` instead of `create` when an object already exists. The idempotency contract must be enforced at the tool layer, not by trusting the agent's plan to be correct.

**Debugging:**

```bash
# Check for duplicate objects (should return 1 per route name)
kubectl get httproutes -n app -o json | jq '.items | group_by(.metadata.name) | map(select(length > 1))'

# Check reconciliation trace for the failed loop
kubectl logs -n agent-system deploy/migration-agent --since=1h | jq 'select(.phase == "act")'

# Verify apply vs create semantics in the MCP server tool handler
grep -n "kubectl create\|kubectl apply" /opt/mcp-server/tools/kubectl.go

# Check if the Gateway was programmed despite duplicates
kubectl get gateway app-gateway -n app -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}'
```

---

### Failure 2: Drift between plan phase and act phase

**Symptoms:** The agent planned to create `HTTPRoute/frontend-route` and validated it via dry-run, but between the dry-run and the actual apply, another actor (a human engineer, a GitOps tool, or a parallel agent run) modified the target namespace. The apply fails with a conflict error, or worse, applies successfully but to a different state than what the dry-run validated. The verification phase then fails because the effective route configuration differs from the plan.

**Root Cause:** The gap between observation and action is not atomic. The agent observed state at T0, generated a plan, ran dry-run at T1, and applied at T2. Between T1 and T2, another mutation occurred. This is the Kubernetes watch cache equivalent of a controller using a stale informer cache snapshot to make a decision.

**Blast Radius:** Partial migration: some HTTPRoutes applied to a different state than intended. Potential traffic disruption if, for example, a Service was deleted between plan and apply and the HTTPRoute now references a non-existent backend.

**Mitigation:** The act phase must re-read the objects it is about to modify immediately before each write, not just during the observe phase. For updates to existing objects, use `kubectl apply` with the `resourceVersion` field set to the version observed during planning — the API server will reject the write with a 409 Conflict if another actor modified the object in the interim. This is the Kubernetes optimistic concurrency pattern.

**Debugging:**

```bash
# Check API server audit log for concurrent mutations in the target namespace
kubectl logs -n kube-system deploy/kube-apiserver | grep '"namespace":"app"' | grep '"verb":"update"\|"verb":"patch"' | tail -30

# Check resourceVersion mismatch in the apply error
kubectl logs -n agent-system deploy/migration-agent | grep "resourceVersion\|Conflict\|409"

# Re-observe current state after the failure
kubectl get httproutes,gateway,ingress -n app -o yaml

# Check if a GitOps tool (ArgoCD) is reconciling the same namespace concurrently
kubectl get appproject -n argocd -o json | jq '.items[] | select(.spec.destinations[].namespace == "app")'
argocd app list --output json | jq '.[] | select(.spec.destination.namespace == "app") | {name, syncStatus: .status.sync.status}'
```

---

### Failure 3: Permission escalation via crafted tool arguments

**Symptoms:** The agent (via prompt injection in a document it read, or via model error) generates tool call arguments that attempt to operate outside its designated scope: for example, calling `kubectl_apply` with a `namespace: kube-system` argument to create a privileged resource, or calling `kubectl_delete` with `resource: clusterrole` targeting a cluster-scoped resource the agent has no business touching. If scope enforcement is only in the prompt (not the tool server), these calls succeed.

**Root Cause:** Scope constraints were implemented as LLM instructions ("only modify the app namespace") rather than server-side enforcement in the MCP tool handler. The MCP server's Kubernetes client has broader RBAC permissions than the agent is supposed to use, trusting the LLM to self-limit.

**Blast Radius:** Potentially unlimited. If the agent's ServiceAccount has cluster-admin or broad cluster-scoped permissions, a single injected or hallucinated tool call can delete critical infrastructure, create privileged pods, or exfiltrate secrets.

**Mitigation:** MCP tool servers must enforce scope at the handler level. The `kubectl_apply` handler must read the `namespace` parameter and reject it with an error if it is not in the tool's configured allowed-namespaces list — regardless of what namespace appears in the manifest body. The ServiceAccount used by the MCP server's Kubernetes client must have RBAC that physically prevents operations outside the allowed scope. LLM instructions are a user-facing description of intent, not an access control mechanism.

**Debugging:**

```bash
# Audit tool call logs for out-of-scope namespace arguments
kubectl logs -n agent-system deploy/mcp-server | jq 'select(.tool == "kubectl_apply") | {namespace: .args.namespace, allowed: .scope_check}'

# Check MCP server ServiceAccount RBAC bindings
kubectl get rolebindings,clusterrolebindings -A -o json | jq '.items[] | select(.subjects[]?.name == "mcp-server-sa")'

# Review tool handler scope enforcement code
grep -n "allowed_namespaces\|namespace_check\|scope" /opt/mcp-server/tools/kubectl.go

# Check if any unexpected resources were created in sensitive namespaces
kubectl get all,rolebindings,clusterrolebindings -n kube-system --sort-by=.metadata.creationTimestamp | tail -20
```

---

### Failure 4: Infinite retry loop consuming cost and producing repeated side effects

**Symptoms:** The agent fails at the verify phase (http_probe returns non-200), re-enters the observe phase, regenerates a plan that includes the same creates, and re-applies objects that are already correctly created. On each iteration, the agent either re-creates resources (if using non-idempotent tools), increments annotation values, or generates new audit trail entries. The loop runs indefinitely, consuming API quota and LLM inference cost, and the verify failure root cause (e.g., DNS propagation delay) goes unaddressed because the agent conflates "verification failed" with "the apply was wrong" rather than "we need to wait."

**Root Cause:** No retry budget or jitter is applied to the reconciliation loop. The agent has no concept of a "wait for convergence" action — it only knows how to observe, plan, and apply, not to wait and re-verify. This is equivalent to a Kubernetes controller that has no `requeueAfter` and re-queues on every error with no backoff.

**Blast Radius:** API server load from repeated list/apply calls, LLM inference cost (potentially hundreds of dollars for a long-running loop), repeated writes to the audit log making the trace unusable for debugging, and potential duplicate or conflicting resource states if any write tool is not fully idempotent.

**Mitigation:** Implement a maximum retry budget per loop invocation (e.g., 3 retries before halting and paging an operator). Add a `wait_and_verify` tool that the agent can call to pause for a configurable duration (e.g., 60 seconds for DNS propagation) before re-probing without re-applying. Separate "verification failed — retry verify" from "apply failed — re-plan and re-apply" in the control flow. Add circuit-breaker logic that detects if the same plan has been executed N times without progress and halts the loop.

**Debugging:**

```bash
# Check loop iteration count from reconciliation trace
kubectl logs -n agent-system deploy/migration-agent --since=2h | jq '.loop_iteration' | sort -n | tail -5

# Check verify phase failure reason per iteration
kubectl logs -n agent-system deploy/migration-agent | jq 'select(.phase == "verify") | {iteration: .loop_iteration, probe: .tool, result: .result.status}'

# Check if the same apply was called multiple times (idempotency verification)
kubectl logs -n agent-system deploy/mcp-server | jq 'select(.tool == "kubectl_apply" and .args.dry_run == false)' | jq -s 'group_by(.args.manifest) | map({manifest: .[0].args.manifest, count: length}) | sort_by(.count) | reverse | .[0:5]'

# Check LLM API spend by querying the inference gateway metrics
curl -s http://inference-gateway.internal/metrics | grep 'llm_tokens_total\|llm_requests_total'

# Check Gateway programming status - may be pending, not failed
kubectl get gateway app-gateway -n app -o jsonpath='{.status.conditions}' | jq .
kubectl describe httproute frontend-route -n app | grep -A 10 "Status:"
```

---

## Lightweight Lab

See `lab/README.md` for the full hands-on lab: **Ingress to Gateway API Migration**. The lab walks through a six-step agent workflow — discovery, translation, dry-run validation, apply, verification, and rollback documentation — using real Kubernetes manifests and shell scripts that simulate the agent's tool calls.

```bash
# Quick start: create the lab cluster and apply sample Ingresses
kind create cluster --name agent-lab
kubectl apply -f lab/sample-ingress.yaml
kubectl get ingress -A

# Run the discovery script (simulates agent observe phase)
bash lab/discover-ingresses.sh | jq .

# Run the translation script (simulates agent plan phase)
bash lab/translate-to-httproutes.sh | kubectl apply --dry-run=server -f -
```

---

## What to commit

- Connect this directly to the ingress-nginx to Topology Envoy Gateway migration agent work: document the plan document format and blast-radius thresholds you used in the real migration.
- Add a metrics-based verification script to the lab that checks `envoy_cluster_upstream_rq_xx` response codes after applying HTTPRoutes, closing the loop between agent verification and actual traffic signal.
