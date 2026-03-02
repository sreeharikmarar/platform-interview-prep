# Scheduler Internals & Placement Decisions

## What you should be able to do
- Explain filter/score/bind.
- Diagnose unschedulable pods.
- Understand taints/tolerations and affinity.

## Mental model

The Kubernetes scheduler is a specialized controller that solves a constraint satisfaction problem: given a pod with resource requests, affinity rules, and tolerations, find the best node to run it on. Unlike other controllers that reconcile custom resources, the scheduler watches for unscheduled pods (those with .spec.nodeName empty) and writes a Binding object to assign them to nodes.

Think of scheduling as a three-stage pipeline: filter removes infeasible nodes (insufficient CPU/memory, taints without matching tolerations, wrong zone), score ranks remaining nodes by quality (spread across zones, prefer less-utilized nodes, affinity preferences), and bind writes the node assignment and updates the pod. This separation allows pluggable policies - you can write custom filter and score plugins without modifying core scheduler logic.

The scheduler is pessimistic: it makes decisions based on the cluster state at scheduling time, but that state can change before kubelet actually starts the container. If a node fails after binding but before kubelet pulls the image, the pod enters a failed state and the controller manager detects it needs rescheduling. If resource limits are wrong and the pod OOMKills, that's not a scheduling failure - scheduling was correct given the declared requests.

Understanding the decoupling between scheduler and controllers is critical. The scheduler doesn't create pods or delete them - it only assigns nodes. The Deployment controller creates ReplicaSets, the ReplicaSet controller creates Pods, the scheduler binds them to nodes, kubelet starts containers, and the controller watches for pod failures. This modularity means you can replace the scheduler with a custom implementation without changing other components, which is exactly what batch systems like Volcano and Kueue do for gang scheduling and queue management.

## Key Concepts

- **Scheduling Queue**: Priority queue holding pods to be scheduled; organized into activeQ (ready), backoffQ (retry later), and unschedulableQ (waiting for cluster state change)
- **Filter Plugins**: Predicates that determine if a node is feasible; return true/false with optional reason
- **Score Plugins**: Functions that rank feasible nodes from 0-100; scheduler sums weighted scores
- **Bind Plugins**: Write the pod-node assignment; default creates a Binding object
- **Preemption**: Evicting lower-priority pods to make room for higher-priority ones
- **Pod Priority**: Integer value from PriorityClass; higher values schedule first and can preempt lower
- **Node Affinity**: Required/preferred rules for which nodes a pod can schedule on (label selectors)
- **Pod Affinity/Anti-Affinity**: Co-locate or spread pods relative to other pods (topologyKey)
- **Taints**: Key-value pairs on nodes that repel pods unless they have matching tolerations
- **Tolerations**: Key-value pairs on pods allowing them to schedule on tainted nodes
- **Topology Spread Constraints**: Evenly distribute pods across topology domains (zones, nodes)

## Internals

### Scheduling Cycle

1. **Pod Watch**: Scheduler's Informer watches for pods with `.spec.nodeName == ""` (unscheduled pods). The Pending phase is a consequence of having no node assigned, not a filter criterion.

2. **Enqueue**: Unscheduled pods are added to the scheduling queue. The queue is a priority queue - pods with higher `.spec.priority` (from PriorityClass) are dequeued first.

3. **Snapshot**: Scheduler takes a consistent snapshot of cluster state (all nodes, their capacity/allocatable, all running pods) from its cache. This snapshot is used for the entire scheduling cycle to avoid race conditions.

4. **Filter Phase**: For each node, run filter plugins in order. If any returns false, the node is excluded. Common filters:
   - **NodeResourcesFit**: Check if node has enough CPU/memory/ephemeral-storage for pod.requests
   - **NodeName**: If pod.spec.nodeName is set, only that node passes
   - **NodeUnschedulable**: Exclude nodes with .spec.unschedulable=true (cordoned)
   - **TaintToleration**: Exclude nodes with taints unless pod has matching tolerations
   - **NodeAffinity**: Check pod.spec.affinity.nodeAffinity required rules
   - **PodTopologySpread**: Check if placing pod on this node violates spread constraints
   - **VolumeBinding**: Check if required PVs can bind to this node (for local volumes)

5. **Score Phase**: For each feasible node, run score plugins and sum weighted scores (0-100 per plugin). Common scorers:
   - **NodeResourcesBalancedAllocation**: Prefer nodes with balanced CPU/memory usage (avoid wasting resources)
   - **ImageLocality**: Prefer nodes that already have the container image (faster pod start)
   - **InterPodAffinity**: Prefer nodes that satisfy pod affinity preferences
   - **TaintToleration**: Penalize nodes with taints (even if tolerated)
   - **NodeAffinity**: Score nodes matching preferred nodeAffinity rules
   - **PodTopologySpread**: Prefer nodes that improve spread across topology domains

6. **Select**: Choose the node with the highest score. If there's a tie, pick one at random (to avoid thundering herd).

7. **Reserve**: Call Reserve plugins to reserve resources on the selected node (update accounting, claim volumes). This is part of the scheduling cycle but before async binding.

8. **Permit**: Optional plugins can delay binding (wait for external approval, quota check).

9. **Bind Phase (async)**: Move to a goroutine pool to avoid blocking the scheduling queue:
   - **WaitOnPermit**: Block if Permit plugin returned "wait"
   - **PreBind**: Call PreBind plugins (e.g., mount volumes)
   - **Bind**: Default binding plugin creates a Binding object: `POST /api/v1/namespaces/{ns}/pods/{name}/binding` with `{"target": {"name": "node-1"}}`
   - **PostBind**: Informational plugins (logging, metrics)

10. **Update Pod**: API server updates the pod's `.spec.nodeName` and kubelet on that node sees the pod and starts containers.

### Preemption

If no nodes pass filters, the scheduler enters preemption mode:

1. **Find Victims**: For each node, determine which lower-priority pods could be evicted to make room. A pod is a victim if its priority < pending pod's priority.

2. **Simulate Removal**: Virtually remove victim pods and re-run filters. If the node now passes, it's a candidate.

3. **Pick Best Node**: Score candidate nodes (prefer evicting fewer pods, lower total priority evicted).

4. **Nominate**: Set the pending pod's `.status.nominatedNodeName` to the chosen node (reservation).

5. **Evict Victims**: Delete victim pods (respecting terminationGracePeriodSeconds).

6. **Wait**: Scheduler doesn't immediately bind - it waits for victims to terminate and the node to pass filters, then schedules normally.

### Taints and Tolerations

**Taints** on nodes repel pods:
```yaml
apiVersion: v1
kind: Node
metadata:
  name: node-1
spec:
  taints:
  - key: dedicated
    value: gpu-workloads
    effect: NoSchedule  # or NoExecute or PreferNoSchedule
```

**Effects**:
- `NoSchedule`: Pods without matching toleration won't schedule (existing pods unaffected)
- `NoExecute`: Pods without toleration won't schedule AND existing pods are evicted
- `PreferNoSchedule`: Soft constraint - avoid but allow if necessary

**Tolerations** on pods allow scheduling on tainted nodes:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-pod
spec:
  tolerations:
  - key: dedicated
    operator: Equal
    value: gpu-workloads
    effect: NoSchedule
  containers: [...]
```

**Operators**:
- `Equal`: key and value must match
- `Exists`: only key must match (value ignored)

### Node Affinity

**Required** (hard constraint):
```yaml
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: topology.kubernetes.io/zone
            operator: In
            values: ["us-west-2a", "us-west-2b"]
```

Pod will NOT schedule if no nodes match.

**Preferred** (soft constraint):
```yaml
spec:
  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
          - key: disk-type
            operator: In
            values: ["ssd"]
```

Scheduler prefers nodes matching but will use others if needed.

### Pod Affinity / Anti-Affinity

**Pod Affinity** (co-locate):
```yaml
spec:
  affinity:
    podAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app: cache
        topologyKey: topology.kubernetes.io/zone
```

Schedules pod in the same zone as pods with `app: cache` label.

**Pod Anti-Affinity** (spread):
```yaml
spec:
  affinity:
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchLabels:
              app: web
          topologyKey: kubernetes.io/hostname
```

Prefers nodes that don't have other `app: web` pods (spread across nodes).

### Topology Spread Constraints

More flexible than anti-affinity:
```yaml
spec:
  topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule  # or ScheduleAnyway
    labelSelector:
      matchLabels:
        app: web
```

Ensures at most 1 replica difference between zones. If zone-a has 3 `app: web` pods and zone-b has 1, the next pod must go to zone-b.


## Architecture Diagram

```
┌────────────────────────────────────────────┐
│  Deployment Controller                     │
│  - Creates ReplicaSet                      │
│  - ReplicaSet creates Pod                  │
└────────────┬───────────────────────────────┘
             │ Pod created with nodeName=""
             ▼
    ┌────────────────────┐
    │  Scheduling Queue  │
    │                    │
    │  ┌──────────────┐  │
    │  │ Priority Q   │  │
    │  │  - activeQ   │  │
    │  │  - backoffQ  │  │
    │  │  - unsched Q │  │
    │  └──────────────┘  │
    └─────────┬──────────┘
              │ Dequeue highest priority pod
              ▼
    ┌─────────────────────────────────────┐
    │  Scheduler Main Loop                │
    │                                     │
    │  1. Take cluster state snapshot    │
    │     (nodes, pods, PVs)             │
    │                                     │
    │  2. FILTER PHASE                   │
    │     For each node:                 │
    │     ┌──────────────────────────┐   │
    │     │ NodeResourcesFit        │   │ → ❌ Insufficient CPU
    │     │ TaintToleration         │   │ → ❌ No matching toleration
    │     │ NodeAffinity            │   │ → ✅ Pass
    │     │ PodTopologySpread       │   │ → ✅ Pass
    │     └──────────────────────────┘   │
    │     Feasible nodes: [node-2, node-3]│
    │                                     │
    │  3. SCORE PHASE                    │
    │     For each feasible node:        │
    │     ┌──────────────────────────┐   │
    │     │ BalancedAllocation: 85  │   │
    │     │ ImageLocality: 10       │   │
    │     │ InterPodAffinity: 50    │   │
    │     │ Total: 145              │   │
    │     └──────────────────────────┘   │
    │     Best node: node-2 (score: 145) │
    │                                     │
    │  4. RESERVE                        │
    │     Update resource accounting     │
    │                                     │
    │  5. BIND (async)                   │
    │     POST /api/v1/.../binding       │
    │     {"target": "node-2"}           │
    └─────────────────┬───────────────────┘
                      │
                      ▼
            ┌──────────────────┐
            │  API Server      │
            │  Update pod:     │
            │  nodeName=node-2 │
            └─────────┬────────┘
                      │ Watch event
                      ▼
            ┌──────────────────┐
            │  Kubelet         │
            │  (on node-2)     │
            │  - Pull image    │
            │  - Start container│
            └──────────────────┘
```

## Failure Modes & Debugging

### 1. Insufficient Resources (Resource Fragmentation)

**Symptoms**: Pods stuck in Pending state with SchedulerError events. Events say "0/5 nodes available: 3 Insufficient cpu, 2 node(s) had untolerated taint." Cluster has available capacity in aggregate but no single node has enough for the pod.

**Root Cause**: Pods request more resources than any individual node has available, or resources are fragmented across nodes. For example, cluster has 10 nodes each with 2 CPU available (20 total), but a pod requests 4 CPU. Or, many small pods have been placed, leaving nodes with unusable small fragments (1GB memory across many nodes but no pod fits).

**Blast Radius**: Affects specific pods with large resource requests or in clusters nearing capacity. Can cascade - if critical system pods (DNS, monitoring) can't schedule, the cluster becomes unhealthy. Autoscaler may add nodes but if the pod requests exceed single-node capacity, it won't help.

**Mitigation**:
- Right-size resource requests - don't over-request
- Use cluster autoscaler to add nodes when pending pods exist
- Use PriorityClass to ensure critical pods preempt lower-priority workloads
- Monitor resource utilization vs requests (overcommit ratio)
- For large pods, ensure nodes in the cluster can fit them (check node allocatable)
- Use ResourceQuota to prevent tenants from creating pods that can't fit

**Debugging**:
```bash
# Check pod events
kubectl describe pod pending-pod | grep Events -A 20
# Output: "0/5 nodes are available: 3 Insufficient cpu, 2 Insufficient memory"

# Check node allocatable vs available
kubectl describe nodes | grep -A 5 "Allocated resources"

# See what's actually using resources on nodes
kubectl top nodes

# Check pod resource requests
kubectl get pod pending-pod -o jsonpath='{.spec.containers[*].resources.requests}'

# Identify resource fragmentation
kubectl get nodes -o json | jq '.items[] | {name: .metadata.name, cpu: (.status.allocatable.cpu | tonumber), memory: (.status.allocatable.memory | tonumber)}'
```

### 2. Taint/Toleration Mismatch

**Symptoms**: Pods pending with events "0/5 nodes available: 5 node(s) had untolerated taint {key: value}." Nodes are available with capacity but pods can't schedule on them.

**Root Cause**: Nodes have taints that pods don't tolerate. Common scenarios:
- Nodes tainted for dedicated workloads (GPU, high-memory) but regular pods try to schedule
- Nodes have `node.kubernetes.io/not-ready` taint during maintenance
- Custom taints added for isolation (prod vs dev) without corresponding tolerations

**Blast Radius**: Affects pods without proper tolerations. If all nodes are tainted and no pods tolerate, nothing can schedule (cluster deadlock). Common during cluster upgrades when new nodes have taints but workloads haven't updated tolerations.

**Mitigation**:
- Document taint usage and ensure pods have tolerations before tainting nodes
- Use `PreferNoSchedule` instead of `NoSchedule` for soft isolation
- Keep at least some untainted nodes for general workloads
- Use node pools/groups with different taints for different workload types
- Test toleration changes in staging before prod

**Debugging**:
```bash
# List all node taints
kubectl get nodes -o json | jq '.items[] | {name: .metadata.name, taints: .spec.taints}'

# Check pod's tolerations
kubectl get pod pending-pod -o jsonpath='{.spec.tolerations}'

# Describe pod to see which taint blocked it
kubectl describe pod pending-pod | grep -i taint

# Temporarily remove taint to test (on a specific node)
kubectl taint nodes node-1 dedicated:NoSchedule-

# Or add toleration to pod
kubectl patch pod pending-pod --type=json -p='[{"op":"add","path":"/spec/tolerations","value":[{"key":"dedicated","operator":"Exists"}]}]'
```

### 3. Unsatisfiable Affinity/Anti-Affinity

**Symptoms**: Pods pending with events "0/5 nodes available: 5 node(s) didn't match pod affinity rules." Cluster has capacity but affinity constraints can't be satisfied.

**Root Cause**: Pod has `requiredDuringScheduling` affinity/anti-affinity that no node satisfies. Examples:
- Pod requires co-location with another pod (affinity) but that pod doesn't exist
- Pod has anti-affinity requiring it's the only instance per node, but all nodes already have an instance
- Node affinity requires a label (e.g., `zone=us-west-2a`) but no nodes have that label

**Blast Radius**: Affects specific pods with strict affinity rules. Can block rollouts if new pods can't satisfy anti-affinity with existing pods. Cascades if affinity references a service that's not deployed yet (chicken-and-egg).

**Mitigation**:
- Use `preferred` instead of `required` for soft constraints when possible
- Test affinity rules with `--dry-run=server` before applying
- Ensure topology domains (zones, nodes) have sufficient cardinality for anti-affinity
- For anti-affinity, set `topologyKey: kubernetes.io/hostname` to spread across nodes, or use `maxSkew` with TopologySpreadConstraints
- Monitor pod distribution to detect when anti-affinity is close to saturating

**Debugging**:
```bash
# Check pod's affinity rules
kubectl get pod pending-pod -o yaml | grep -A 20 affinity

# See if target pods exist (for podAffinity)
kubectl get pods -l app=cache
# If no results, podAffinity can't be satisfied

# Check node labels (for nodeAffinity)
kubectl get nodes --show-labels | grep us-west-2a

# Check pod distribution for anti-affinity
kubectl get pods -o wide -l app=web
# If all nodes have one, anti-affinity with topologyKey=hostname blocks next pod

# Temporarily relax affinity (change to preferred)
kubectl patch deployment myapp --type=json -p='[{"op":"replace","path":"/spec/template/spec/affinity/podAntiAffinity/requiredDuringSchedulingIgnoredDuringExecution","value":null}]'
```

### 4. PersistentVolume Binding Failure

**Symptoms**: Pods pending with events "0/5 nodes available: 5 node(s) had volume node affinity conflict." PVC is bound but pod can't schedule.

**Root Cause**: PersistentVolume has node affinity (common with local volumes or zone-restricted EBS) that limits which nodes can access it. Pod's other constraints (nodeSelector, affinity) conflict with the PV's node affinity. For example, PV is in zone-a but pod has nodeSelector requiring zone-b.

**Blast Radius**: Affects stateful workloads using local or zone-restricted storage. Can prevent StatefulSet rollouts if pods can't schedule in the zone where their PVs exist.

**Mitigation**:
- Use `volumeBindingMode: WaitForFirstConsumer` to delay PV binding until pod is scheduled
- Ensure pod's affinity rules are compatible with storage availability zones
- Use regional storage (e.g., multi-attach EBS, Portworx) to avoid single-zone constraints
- For local volumes, use node affinity on pods to match the PV's node

**Debugging**:
```bash
# Check PV's node affinity
kubectl get pv my-pv -o yaml | grep -A 5 nodeAffinity

# Check PVC's binding
kubectl get pvc my-pvc -o jsonpath='{.spec.volumeName}'

# Check pod's volume mounts and PVC references
kubectl get pod pending-pod -o yaml | grep -A 5 volumes

# Describe pod to see volume binding failure details
kubectl describe pod pending-pod | grep -i volume

# Check storage class binding mode
kubectl get sc -o yaml | grep volumeBindingMode
```


## Lightweight Lab

```bash
# 1. Taint all nodes to simulate dedicated workload nodes
kubectl taint nodes --all role=dedicated:NoSchedule
# Observe: Nodes now repel pods without matching tolerations

# 2. Try to create a pod without toleration (should stay Pending)
kubectl apply -f lab/pod-no-toleration.yaml
kubectl get pod no-toleration
# Observe: Pod is Pending

# 3. Check why it's pending
kubectl describe pod no-toleration | grep Events -A 10
# Observe: "0/N nodes are available: N node(s) had untolerated taint"

# 4. Create a pod with matching toleration (should schedule)
kubectl apply -f lab/pod-with-toleration.yaml
kubectl get pod with-toleration
# Observe: Pod is Running

# 5. Remove taints to restore normal scheduling
kubectl taint nodes --all role:NoSchedule-

# 6. Now the no-toleration pod should schedule
kubectl get pod no-toleration -w
# Observe: Pod transitions from Pending to Running

# 7. Test node affinity - label a node
kubectl label nodes <node-name> disktype=ssd

# 8. Create a pod with required node affinity
kubectl apply -f lab/pod-node-affinity.yaml
# Observe: Pod schedules only on the labeled node

# 9. Test pod anti-affinity - create multiple replicas
kubectl apply -f lab/deployment-anti-affinity.yaml
kubectl get pods -o wide -l app=spread
# Observe: Pods spread across nodes (if multiple nodes available)

# 10. Test topology spread constraints
kubectl apply -f lab/deployment-topology-spread.yaml
kubectl get pods -o wide -l app=topology-spread
# Observe: Even distribution across zones/nodes

# Cleanup
kubectl delete pods --all
kubectl delete deployments --all
kubectl label nodes --all disktype-
```
