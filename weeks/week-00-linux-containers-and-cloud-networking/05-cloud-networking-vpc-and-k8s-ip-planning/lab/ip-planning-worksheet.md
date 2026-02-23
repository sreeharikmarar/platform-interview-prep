# IP Planning Worksheet: GKE VPC & CIDR Design

This standalone worksheet covers CIDR notation fundamentals, GKE secondary range sizing math, and four practical exercises culminating in a full IP exhaustion diagnosis from real kubectl output. Complete each exercise before reading the answer key at the bottom.

---

## CIDR Notation Refresher

CIDR (Classless Inter-Domain Routing) notation expresses an IP range as a base address and a prefix length. The prefix length is the number of fixed bits; the remaining bits are host bits. Host count = `2^(32 - prefix)`. In practice, two addresses are reserved (network address and broadcast), so usable addresses = `2^(32 - prefix) - 2` for host assignments. For Kubernetes CIDR planning, we use the total IP count (not usable), because GKE's IPAM counts the full block including the network and broadcast addresses.

| CIDR Prefix | Total IPs         | In plain numbers  | Common use in GKE                         |
|-------------|-------------------|-------------------|-------------------------------------------|
| /8          | 2^24 = 16,777,216 | ~16.7 million     | Never used for a single cluster           |
| /10         | 2^22 = 4,194,304  | ~4.2 million      | Super-range for an entire environment     |
| /12         | 2^20 = 1,048,576  | ~1 million        | Super-range for a large region            |
| /14         | 2^18 = 262,144    | 262,144           | Pod secondary range for 1,024-node cluster|
| /16         | 2^16 = 65,536     | 65,536            | Pod secondary range for 256-node cluster  |
| /18         | 2^14 = 16,384     | 16,384            | Pod range for 64-node cluster             |
| /20         | 2^12 = 4,096      | 4,096             | Node primary range; Service secondary range|
| /21         | 2^11 = 2,048      | 2,048             | Pod range for 8-node cluster              |
| /22         | 2^10 = 1,024      | 1,024             | Node primary range (small cluster)        |
| /24         | 2^8  = 256        | 256               | Per-node pod CIDR allocation (max-pods=110)|
| /26         | 2^6  = 64         | 64                | Per-node pod CIDR (max-pods-per-node=32)  |
| /28         | 2^4  = 16         | 16                | Very small subnet; rarely used for pods   |

**Critical relationship for GKE**: When `max-pods-per-node=110`, GKE allocates a `/24` per node. When `max-pods-per-node=32` or lower, GKE allocates a `/26` per node. The per-node prefix length determines how many nodes fit into the pod secondary range.

**Nodes-per-secondary-range formula**:
```
max_nodes = (2^(32 - secondary_range_prefix)) / (2^(32 - per_node_prefix))
          = 2^(per_node_prefix - secondary_range_prefix)
```

Example: secondary range = `/14`, per-node = `/24`:
`max_nodes = 2^(24 - 14) = 2^10 = 1,024`

---

## Exercise 1: Design Subnetting for a 500-Node GKE Cluster

**Scenario**: You are building a new production GKE cluster. The requirements are:
- Target steady-state: 500 nodes
- Must accommodate autoscaler peaks of 700 nodes and simultaneous rolling upgrades (max surge: 50 additional nodes)
- `max-pods-per-node`: 110 (default), meaning each node gets a `/24` pod block
- Must reserve headroom to grow to 1,000 nodes without CIDR changes
- Use the `10.0.0.0/8` address space

**Your task**: Choose:
1. Primary subnet range (node NIC IPs)
2. Pod secondary range
3. Service secondary range

Show your CIDR math for each. State the maximum node count your pod secondary range supports.

**Work space:**

```
Step 1: Size the pod secondary range
  Target max nodes = 1,000 (headroom goal)
  Per-node allocation = /24 = 256 IPs per node
  Required secondary range size = 1,000 x 256 = 256,000 IPs
  Nearest CIDR that is >= 256,000: /14 = 262,144 IPs

  Max nodes supported by /14 at /24-per-node:
    = 2^(24 - 14) = 2^10 = 1,024 nodes   ✓ (meets the 1,000-node goal)

Step 2: Size the primary range (node IPs)
  We need 1,024 IPs for nodes (to match pod range capacity)
  /22 = 1,024 IPs — exactly sufficient
  Use /20 = 4,096 IPs for generous headroom and alignment convenience
  (Reason: primary ranges are cheap and can be used for future node pools
   in the same subnet, and /20 is a round number in GCP's subnet sizing)

Step 3: Size the service secondary range
  Services are ClusterIP addresses — one per Service object
  Large platforms have hundreds to low thousands of services
  /20 = 4,096 addresses — sufficient for any realistic service count
  (A /24 = 256 addresses is dangerously small; always use /20 or larger)
```

**Answer**:
- Primary subnet range: `10.0.0.0/20` (4,096 IPs for node NICs)
- Pod secondary range: `10.100.0.0/14` (262,144 IPs; supports 1,024 nodes at `/24`-per-node)
- Service secondary range: `10.200.0.0/20` (4,096 ClusterIP addresses)

**Maximum capacity**:
- Maximum nodes: 1,024 (limited by pod secondary range at `/24`-per-node)
- Maximum pods per node: 110 (enforced by `max-pods-per-node` flag)
- Maximum total pods: 1,024 nodes × 110 pods = 112,640 pods
- Maximum services: 4,094 (4,096 minus network and broadcast addresses)

**Verification checks**:
- `10.0.0.0/20` range: `10.0.0.0` – `10.0.15.255` ✓
- `10.100.0.0/14` range: `10.100.0.0` – `10.103.255.255` ✓
- `10.200.0.0/20` range: `10.200.0.0` – `10.200.15.255` ✓
- No overlap between the three ranges ✓
- All three are within `10.0.0.0/8` ✓

---

## Exercise 2: Calculate Max Nodes from a /20 Pod Range at max-pods-per-node=110

**Scenario**: A team provisioned a GKE cluster 14 months ago with a pod secondary range of `10.50.0.0/20`. The cluster uses the default `max-pods-per-node=110`. The cluster autoscaler is now reporting failures. How many nodes does this cluster support before the pod range is exhausted?

**Your task**: Calculate:
1. Total IPs in the `10.50.0.0/20` range
2. IPs allocated per node (given max-pods-per-node=110)
3. Maximum nodes before exhaustion
4. How many nodes are already allocated if you see this output:
   ```
   kubectl get nodes | grep -c Ready
   12
   ```
5. How many nodes can still be added before the range is full?

**Work space:**

```
Step 1: Size of /20
  /20 = 2^(32-20) = 2^12 = 4,096 IPs total

Step 2: Per-node IP allocation at max-pods-per-node=110
  GKE allocates /24 per node when max-pods-per-node is between 65 and 110
  /24 = 2^(32-24) = 2^8 = 256 IPs per node

Step 3: Maximum nodes
  max_nodes = total_IPs / IPs_per_node = 4,096 / 256 = 16 nodes

Step 4: Currently allocated
  12 nodes with Ready status (from kubectl output)
  Therefore 12 x 256 = 3,072 IPs allocated

Step 5: Remaining capacity
  Remaining IPs = 4,096 - 3,072 = 1,024 IPs
  Remaining /24 blocks = 1,024 / 256 = 4 nodes
```

**Answer**:
- Total IPs in `/20`: 4,096
- IPs per node at max-pods-per-node=110: 256 (one `/24` block per node)
- Maximum nodes: **16**
- Currently allocated: 12 nodes (12 × 256 = 3,072 IPs)
- Remaining capacity: **4 nodes** before the pod range is full

**Why this matters**: A 14-month-old cluster at 12 nodes has only 4 node-slots of headroom. A single autoscaling event driven by a traffic spike or a node pool rolling upgrade (which temporarily adds surge nodes) can exhaust this in minutes. Any autoscaling target above 16 nodes will silently fail — the autoscaler will provision the VM but the node will stay `NotReady` because the nodeIpamController cannot allocate a pod CIDR.

**If max-pods-per-node were 32 instead of 110**: GKE would allocate `/26` (64 IPs) per node instead of `/24`. Then: 4,096 / 64 = 64 nodes maximum. Lowering max-pods-per-node is one migration path when a cluster has exhausted its pod range — add a new node pool with lower max-pods-per-node to use smaller per-node CIDR allocations and fit more nodes into the same secondary range.

---

## Exercise 3: VPC Peering Scenario — Check for CIDR Overlap

**Scenario**: Your organization has two GKE clusters in the same GCP project. A platform team wants to peer their VPCs so that services in Cluster A can communicate with services in Cluster B without going through a load balancer.

**Cluster A design:**
- Primary subnet: `10.0.0.0/20`
- Pod secondary range: `10.100.0.0/16`
- Service secondary range: `10.200.0.0/20`

**Cluster B design:**
- Primary subnet: `10.1.0.0/20`
- Pod secondary range: `10.100.128.0/17`
- Service secondary range: `10.201.0.0/20`

**Your task**: Determine whether VPC peering is possible between Cluster A and Cluster B. Check for overlap between every pair of ranges (primary vs primary, pod vs pod, service vs service, and cross-type comparisons).

**Work space — determining range boundaries:**

```
Cluster A:
  Primary:  10.0.0.0   – 10.0.15.255    (/20, 4,096 IPs)
  Pod:      10.100.0.0 – 10.100.255.255  (/16, 65,536 IPs)
  Service:  10.200.0.0 – 10.200.15.255  (/20, 4,096 IPs)

Cluster B:
  Primary:  10.1.0.0   – 10.1.15.255    (/20, 4,096 IPs)
  Pod:      10.100.128.0 – 10.100.255.255 (/17, 32,768 IPs)
  Service:  10.201.0.0 – 10.201.15.255  (/20, 4,096 IPs)

Overlap checks:
  A-Primary  (10.0.0.0–10.0.15.255) vs B-Primary  (10.1.0.0–10.1.15.255):    NO overlap ✓
  A-Pod      (10.100.0.0–10.100.255.255) vs B-Pod (10.100.128.0–10.100.255.255):
    A-Pod ends at 10.100.255.255
    B-Pod starts at 10.100.128.0
    B-Pod is entirely within A-Pod's range                                      OVERLAP! ✗
  A-Service  (10.200.0.0–10.200.15.255) vs B-Service (10.201.0.0–10.201.15.255): NO overlap ✓
  Cross-type checks:
    A-Pod vs B-Primary: 10.100.x vs 10.1.x — no overlap ✓
    A-Pod vs B-Service: 10.100.x vs 10.201.x — no overlap ✓
    B-Pod vs A-Primary: 10.100.128.x vs 10.0.x — no overlap ✓
    B-Pod vs A-Service: 10.100.128.x vs 10.200.x — no overlap ✓
```

**Answer**: VPC peering is NOT possible. Cluster B's pod secondary range (`10.100.128.0/17`) is entirely contained within Cluster A's pod secondary range (`10.100.0.0/16`). GCP will reject the peering with a route overlap error, or if the peering is created it will cause routing failures where traffic from Cluster A destined to Cluster B's pod IPs is routed locally within Cluster A's VPC instead of across the peering.

**Fix**: Cluster B must be redesigned with a non-overlapping pod secondary range. Since Cluster A has `10.100.0.0/16`, Cluster B must choose a pod range outside `10.100.0.0`–`10.100.255.255`. An acceptable alternative for Cluster B: `10.104.0.0/16` (covers `10.104.0.0`–`10.104.255.255`), which does not overlap with any of Cluster A's ranges.

**Lesson**: The most dangerous overlap check is secondary range vs secondary range, not primary vs primary. Two teams using the "same standard template" for pod ranges will collide. Enforce CIDR assignments from a shared registry before cluster creation.

---

## Exercise 4: Diagnose IP Exhaustion from kubectl Node Output

**Scenario**: You receive a PagerDuty alert at 2am: "GKE cluster autoscaler unable to provision nodes for 30 minutes." You run several kubectl commands. Analyze the output below and answer the diagnostic questions.

**Command 1 output** — `kubectl get nodes -o wide`:
```
NAME            STATUS     ROLES    AGE   VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE
gke-prod-n001   Ready      <none>   45d   v1.28.3   10.10.0.5     <none>        ...
gke-prod-n002   Ready      <none>   45d   v1.28.3   10.10.0.6     <none>        ...
gke-prod-n003   Ready      <none>   44d   v1.28.3   10.10.0.7     <none>        ...
gke-prod-n004   Ready      <none>   44d   v1.28.3   10.10.0.8     <none>        ...
gke-prod-n005   Ready      <none>   43d   v1.28.3   10.10.0.9     <none>        ...
gke-prod-n006   Ready      <none>   43d   v1.28.3   10.10.0.10    <none>        ...
gke-prod-n007   Ready      <none>   42d   v1.28.3   10.10.0.11    <none>        ...
gke-prod-n008   Ready      <none>   42d   v1.28.3   10.10.0.12    <none>        ...
gke-prod-n009   NotReady   <none>   2m    v1.28.3   10.10.0.13    <none>        ...
gke-prod-n010   NotReady   <none>   1m    v1.28.3   10.10.0.14    <none>        ...
```

**Command 2 output** — `kubectl get nodes -o json | jq -r '.items[] | [.metadata.name, (.spec.podCIDR // "NONE")] | @tsv'`:
```
gke-prod-n001   10.10.16.0/24
gke-prod-n002   10.10.17.0/24
gke-prod-n003   10.10.18.0/24
gke-prod-n004   10.10.19.0/24
gke-prod-n005   10.10.20.0/24
gke-prod-n006   10.10.21.0/24
gke-prod-n007   10.10.22.0/24
gke-prod-n008   10.10.23.0/24
gke-prod-n009   NONE
gke-prod-n010   NONE
```

**Command 3 output** — `kubectl get pods -A --field-selector spec.nodeName=gke-prod-n001 | wc -l`:
```
97
```
(96 pods plus the header line)

**Command 4 output** — `kubectl get events -A --field-selector reason=FailedScheduling | tail -3`:
```
NAMESPACE  LAST SEEN  REASON           OBJECT                    MESSAGE
default    45s        FailedScheduling  Pod/web-deploy-7d8b9-xxx  0/10 nodes are available: 2 node(s) had untolerated taint {node.kubernetes.io/not-ready: }, 8 Insufficient pods.
default    30s        FailedScheduling  Pod/web-deploy-7d8b9-yyy  0/10 nodes are available: 2 node(s) had untolerated taint {node.kubernetes.io/not-ready: }, 8 Insufficient pods.
default    15s        FailedScheduling  Pod/api-deploy-9c2f1-zzz  0/10 nodes are available: 2 node(s) had untolerated taint {node.kubernetes.io/not-ready: }, 8 Insufficient pods.
```

**Diagnostic questions:**

**Q1**: What is the pod secondary range of this cluster? How many total `/24` blocks does it contain?

**Q2**: How many `/24` blocks are currently allocated? How many remain?

**Q3**: What is causing `gke-prod-n009` and `gke-prod-n010` to be `NotReady`?

**Q4**: The FailedScheduling events say "8 Insufficient pods." What does this mean, and is it related to the NotReady nodes or a separate problem?

**Q5**: What is the fastest possible remediation that can be done in the next 5 minutes without cloud console access?

**Q6**: What is the correct long-term fix?

---

## Answer Key

### Exercise 1 Answer

Already embedded in Exercise 1 above with full work shown.

Summary: Primary `10.0.0.0/20`, pod `10.100.0.0/14` (1,024 max nodes), service `10.200.0.0/20`.

---

### Exercise 2 Answer

Already embedded in Exercise 2 above with full work shown.

Summary: `/20` pod range at `/24`-per-node = **16 nodes maximum**. With 12 nodes present, **4 nodes of headroom remain**.

---

### Exercise 3 Answer

Already embedded in Exercise 3 above with full work shown.

Summary: Peering fails because Cluster B's pod range (`10.100.128.0/17`) is a subset of Cluster A's pod range (`10.100.0.0/16`). Fix: choose a non-overlapping pod range for Cluster B such as `10.104.0.0/16`.

---

### Exercise 4 Answer

**Q1 answer**: The node pod CIDRs are `10.10.16.0/24` through `10.10.23.0/24`. These are consecutive `/24` blocks within `10.10.16.0` to `10.10.23.255`. The parent range that exactly contains these 8 blocks is `10.10.16.0/21` (8 × /24 blocks = 8 × 256 = 2,048 IPs = `/21`). The `/21` contains `2^(32-21) = 2^11 = 2,048 IPs`. At `/24`-per-node: `2,048 / 256 = 8 blocks total`.

**Q2 answer**: 8 blocks allocated (gke-prod-n001 through n008), 0 blocks remaining. The pod secondary range is completely exhausted.

**Q3 answer**: `gke-prod-n009` and `gke-prod-n010` are `NotReady` because they have no `spec.podCIDR` assigned. The nodeIpamController cannot allocate a `/24` block for them because the pod secondary range (`10.10.16.0/21`) is fully allocated. Without a pod CIDR, the CNI plugin cannot initialize the node network, so the node stays `NotReady` with the condition "network not ready."

**Q4 answer**: The FailedScheduling events saying "8 Insufficient pods" are a separate but related problem. The message means that all 8 `Ready` nodes reported "Insufficient pods" — that is, none of the 8 schedulable nodes had enough free pod capacity to fit the pending pod. Note that `kubectl get pods` showed 96 pods on gke-prod-n001 (out of 110 maximum), which is close to the limit. Even if pods are spread unevenly across nodes, the scheduler cannot place new pods if every node individually reports capacity full. The cluster is both range-exhausted (no new nodes can join) AND near-capacity on existing nodes (few pod slots remain on individual nodes). This is a dual failure: pod secondary range full AND per-node pod capacity nearly full.

**Q5 answer** (fastest 5-minute remediation):

```bash
# Step 1: Identify nodes with the fewest pods (candidates for drain to reclaim a /24 block)
kubectl get pods -A -o wide | awk 'NR>1 {print $8}' | sort | uniq -c | sort -n

# Step 2: If any node has very few pods (say <10), cordon and drain it
# This will return its /24 block to the pool for a new node to claim
kubectl cordon gke-prod-n006   # example: node with fewest pods
kubectl drain gke-prod-n006 --ignore-daemonsets --delete-emptydir-data --timeout=120s

# Step 3: Delete the drained node to return its /24 to the IPAM pool
kubectl delete node gke-prod-n006

# After deletion, the nodeIpamController will re-allocate that /24 to gke-prod-n009 or n010
# within ~30 seconds. Monitor with:
watch 'kubectl get nodes -o custom-columns="NAME:.metadata.name,CIDR:.spec.podCIDR,STATUS:.status.conditions[-1].type"'
```

This trades one node's capacity (and its running pods, which are rescheduled to other nodes) for the ability to add new nodes.

**Q6 answer** (long-term fix):

Enable Multi-CIDR on the GKE cluster (GKE 1.28+) and add a new secondary range. First, create a non-overlapping secondary range in the subnet (e.g., `10.10.24.0/21` as a second pod range). Then update the GKE cluster configuration to reference both secondary ranges. New nodes will be able to draw `/24` blocks from either range. No existing workloads are disrupted, and no cluster recreation is needed. After the expansion, the total pod range capacity doubles to 16 nodes (8 from each `/21`). To prevent recurrence, move to a `/14` pod secondary range in the next planned cluster refresh.

Additionally, implement monitoring: alert when `(allocated_node_cidrs / total_possible_node_cidrs) > 0.7` using GKE's node count metrics and the known secondary range size. This alert should fire with enough lead time (weeks, not hours) to take corrective action.

---

## Quick Reference Card

**GKE CIDR Planning Formula**:
```
max_nodes = 2^(per_node_cidr_prefix - secondary_range_prefix)

Where:
  max-pods-per-node > 64  →  per_node_cidr_prefix = 24  (/24 = 256 IPs)
  max-pods-per-node <= 32 →  per_node_cidr_prefix = 26  (/26 = 64 IPs)

Secondary range sizing:
  ≤ 16 nodes:   /20 pod range (4,096 IPs)   — minimal; do not use for production
  ≤ 64 nodes:   /18 pod range (16,384 IPs)  — small cluster; tight on headroom
  ≤ 256 nodes:  /16 pod range (65,536 IPs)  — medium cluster; standard minimum
  ≤ 1,024 nodes: /14 pod range (262,144 IPs) — large cluster; recommended default
  ≤ 4,096 nodes: /12 pod range (1M IPs)      — very large; rare

Always apply 2x headroom multiplier: if max steady-state is 200 nodes, design for 400.
Always use /20 (4,096 addresses) for the service secondary range.
Always use /20 or larger for the primary subnet range.
```

**Quick CIDR Overlap Check**:
```
Two CIDRs A and B overlap if and only if:
  A's start address <= B's last address
  AND B's start address <= A's last address

Example: Does 10.100.0.0/16 overlap 10.100.128.0/17?
  A: 10.100.0.0 – 10.100.255.255
  B: 10.100.128.0 – 10.100.255.255
  A's start (10.100.0.0) <= B's last (10.100.255.255)  → true
  B's start (10.100.128.0) <= A's last (10.100.255.255) → true
  → They overlap. B is entirely within A.
```
