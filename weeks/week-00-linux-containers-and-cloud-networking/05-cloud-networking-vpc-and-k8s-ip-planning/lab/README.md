# Lab: Cloud Networking, VPC IP Planning & SNAT/DNAT Packet Tracing

This lab is intentionally paper-based and simulation-based rather than requiring a live GKE cluster. Each exercise uses either CIDR calculation, real `kubectl` command outputs, or network tracing exercises that develop the diagnostic muscle memory without requiring cloud billing. Exercises 1-3 can be completed entirely offline. Exercises 4-5 require a local Kubernetes cluster (kind or minikube) to observe real iptables behavior.

## Prerequisites

- `kubectl` 1.28+ configured against any cluster (kind, minikube, GKE, or any other)
- `jq` for JSON parsing
- Basic understanding of CIDR notation (if not, start with `lab/ip-planning-worksheet.md` first)
- Optional: `gcloud` CLI for GKE-specific exercises

Estimated time: 2-3 hours for all exercises, or 45-60 minutes for exercises 1-3 alone.

---

## Exercise 1: CIDR Math — Verify Your Cluster's IP Capacity

This exercise builds intuition for the secondary range sizing formula by inspecting a real or simulated cluster.

**Step 1.1: Determine your cluster's pod secondary range**

On a real GKE cluster:
```bash
# List nodes and their assigned pod CIDRs
kubectl get nodes -o json | jq -r \
  '.items[] | [.metadata.name, (.spec.podCIDR // "UNASSIGNED")] | @tsv'
```

On a kind or minikube cluster (which uses a different IPAM model but still has pod CIDRs):
```bash
# kind assigns pod CIDRs from a default range — observe what was allocated
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.podCIDR}{"\n"}{end}'
```

**What's happening**: Each line in the output corresponds to one node and the `/24` (or smaller) block that has been allocated to it from the cluster-wide pod CIDR range. The pod CIDR assigned to each node is visible in `spec.podCIDR` on the Node object. The node IPAM controller (nodeIpamController) allocated this range when the node first registered.

**Step 1.2: Calculate remaining capacity**

Using the output from Step 1.1, calculate:
- How many nodes currently have pod CIDRs assigned: `ASSIGNED=$(kubectl get nodes -o json | jq '[.items[] | select(.spec.podCIDR != null)] | length' && echo $ASSIGNED)`
- What is the cluster's pod CIDR prefix length? (Look at the first octet of each node's `spec.podCIDR` to infer the parent range.)
- What is the maximum number of nodes the pod range can support?

Formula: `max_nodes = 2^(32 - cluster_pod_cidr_prefix) / 2^(32 - node_pod_cidr_prefix)`

Example: cluster pod CIDR = `/14`, node allocation = `/24`:
`max_nodes = 2^(32-14) / 2^(32-24) = 262144 / 256 = 1024`

**Verification**: The calculation is correct when:
- Your formula gives a whole number
- The node allocations you observed are all sub-blocks of the cluster pod CIDR
- The node CIDR prefix (`/24`, `/26`, etc.) matches the `max-pods-per-node` setting: max-pods-per-node=110 → `/24`; max-pods-per-node=32 → `/26`

**Step 1.3: Calculate IP utilization within a single node**
```bash
# Pick one node and count how many pods are running on it
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
POD_CIDR=$(kubectl get node $NODE -o jsonpath='{.spec.podCIDR}')
echo "Node: $NODE"
echo "Pod CIDR: $POD_CIDR"

# Count pods currently scheduled to this node
kubectl get pods -A -o wide --field-selector spec.nodeName=$NODE \
  | grep -v "Completed\|Evicted" | wc -l

# Compare to max-pods-per-node
kubectl get node $NODE -o jsonpath='{.status.allocatable.pods}'
echo " (max pods allocatable)"
```

**What's happening**: `status.allocatable.pods` is the enforced maximum pods per node, accounting for the `max-pods-per-node` kubelet flag and any DaemonSet pods that consume slots. When a pod is scheduled, its IP is drawn from `spec.podCIDR`. When it terminates and is fully deleted, the IP is returned. Pods in `Terminating` state still hold their IPs — this is a common source of "node appears full" confusion when a rolling update is in progress.

---

## Exercise 2: Simulated IP Exhaustion Troubleshooting

This exercise presents a kubectl output excerpt from an exhausted cluster. Your job is to identify the failure layer, calculate remaining capacity, and prescribe the correct remediation.

**Scenario**: You are on-call. The cluster autoscaler has been trying to add nodes for 45 minutes but is failing. Pods for a new deployment are stuck `Pending`. Here is what you observe:

**Output A — Node listing:**
```
NAME           STATUS     ROLES    AGE    VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE   KERNEL-VERSION
gke-prod-0001  Ready      <none>   18d    v1.28.3   10.0.0.5      <none>        ...        ...
gke-prod-0002  Ready      <none>   18d    v1.28.3   10.0.0.6      <none>        ...        ...
gke-prod-0003  Ready      <none>   17d    v1.28.3   10.0.0.7      <none>        ...        ...
gke-prod-0004  Ready      <none>   17d    v1.28.3   10.0.0.8      <none>        ...        ...
gke-prod-0005  Ready      <none>   16d    v1.28.3   10.0.0.9      <none>        ...        ...
gke-prod-0006  Ready      <none>   16d    v1.28.3   10.0.0.10     <none>        ...        ...
gke-prod-0007  Ready      <none>   15d    v1.28.3   10.0.0.11     <none>        ...        ...
gke-prod-0008  Ready      <none>   12d    v1.28.3   10.0.0.12     <none>        ...        ...
gke-prod-0009  Ready      <none>   12d    v1.28.3   10.0.0.13     <none>        ...        ...
gke-prod-0010  Ready      <none>   10d    v1.28.3   10.0.0.14     <none>        ...        ...
gke-prod-0011  Ready      <none>   10d    v1.28.3   10.0.0.15     <none>        ...        ...
gke-prod-0012  Ready      <none>   8d     v1.28.3   10.0.0.16     <none>        ...        ...
gke-prod-0013  Ready      <none>   8d     v1.28.3   10.0.0.17     <none>        ...        ...
gke-prod-0014  Ready      <none>   6d     v1.28.3   10.0.0.18     <none>        ...        ...
gke-prod-0015  Ready      <none>   6d     v1.28.3   10.0.0.19     <none>        ...        ...
gke-prod-0016  Ready      <none>   4d     v1.28.3   10.0.0.20     <none>        ...        ...
gke-prod-new1  NotReady   <none>   2m     v1.28.3   10.0.0.21     <none>        ...        ...
```

**Output B — Node spec excerpt for gke-prod-new1:**
```yaml
apiVersion: v1
kind: Node
metadata:
  name: gke-prod-new1
spec:
  # spec.podCIDR is absent (not set)
  podCIDRs: []
status:
  conditions:
  - type: Ready
    status: "False"
    reason: KubeletNotReady
    message: "runtime network not ready: NetworkPlugin kubenet does not ensure pod network"
```

**Output C — Pod CIDRs from existing nodes (abridged):**
```
gke-prod-0001   10.100.0.0/24
gke-prod-0002   10.100.1.0/24
gke-prod-0003   10.100.2.0/24
gke-prod-0004   10.100.3.0/24
gke-prod-0005   10.100.4.0/24
gke-prod-0006   10.100.5.0/24
gke-prod-0007   10.100.6.0/24
gke-prod-0008   10.100.7.0/24
gke-prod-0009   10.100.8.0/24
gke-prod-0010   10.100.9.0/24
gke-prod-0011   10.100.10.0/24
gke-prod-0012   10.100.11.0/24
gke-prod-0013   10.100.12.0/24
gke-prod-0014   10.100.13.0/24
gke-prod-0015   10.100.14.0/24
gke-prod-0016   10.100.15.0/24
gke-prod-new1   (none — not assigned)
```

**Questions to answer:**

1. What is the inferred pod secondary range CIDR and its size in IP addresses?
2. How many `/24` blocks are currently allocated?
3. How many `/24` blocks remain available?
4. What is preventing `gke-prod-new1` from becoming `Ready`?
5. What are the two immediate remediation options that do not require cluster recreation?

**What's happening**: The node `gke-prod-new1` has no `spec.podCIDR` because the nodeIpamController was unable to allocate a `/24` block. The existing nodes use `10.100.0.0/24` through `10.100.15.0/24` — sixteen consecutive `/24` blocks. The parent range that contains all of these is `10.100.0.0/20` (because the first 20 bits `10.100.0` are common to all 16 blocks, and the 4 variable bits select blocks 0-15). A `/20` contains exactly 4096 IPs = 16 × 256-IP blocks. All 16 are allocated.

**Verification (answers)**:
1. Pod secondary range: `10.100.0.0/20`, size: 4,096 IPs
2. Allocated `/24` blocks: 16 (one per existing node)
3. Available `/24` blocks: 0 — the range is full
4. The pod secondary range is exhausted; the nodeIpamController cannot allocate a `/24` for the new node
5. (a) Drain and delete an underutilized node to return its `/24` block; (b) Enable Multi-CIDR and add a second secondary range to the cluster

---

## Exercise 3: SNAT Packet Trace — Follow the Packet

This is a paper-based tracing exercise. For each scenario, trace the packet path and identify the source and destination IP at each hop.

**Setup**:
- Node `node-1` primary NIC IP: `10.0.4.5/20`
- `node-1` pod CIDR: `10.100.15.0/24`
- Pod `app-server-7f2b` IP: `10.100.15.22`
- Service `my-svc` ClusterIP: `10.200.0.45`, port 80
- Pod `backend-66c9` IP: `10.100.3.8` (on `node-2`)
- Cloud NAT public IP pool: `34.110.50.0/28`
- Cloud NAT assigned public IP for `node-1`: `34.110.50.3`

**Scenario A**: `app-server-7f2b` sends an HTTP GET to `api.github.com` (internet, `140.82.121.4`).

Trace the source IP and destination IP at each of the following points:
1. Packet leaves pod `app-server-7f2b`'s `eth0`
2. Packet enters `cbr0` bridge on `node-1`
3. Packet is processed by iptables `POSTROUTING` on `node-1`
4. Packet leaves `node-1`'s primary NIC (`eth0`)
5. Packet processed by Cloud NAT gateway
6. Packet arrives at `140.82.121.4`

**Scenario B**: `app-server-7f2b` sends an HTTP request to ClusterIP `10.200.0.45:80`, which forwards to `backend-66c9` at `10.100.3.8:8080`.

Trace the source and destination IP at:
1. Packet sent by pod (destination: `10.200.0.45:80`)
2. After iptables `PREROUTING` DNAT on `node-1`
3. Packet leaves `node-1` into VPC fabric
4. Packet arrives at `node-2`'s `cbr0`
5. Packet delivered to `backend-66c9`

**What's happening**: Scenario A demonstrates the two-layer SNAT stack — first iptables MASQUERADE on the node (pod IP → node IP), then Cloud NAT (node IP → public IP). Scenario B demonstrates DNAT via kube-proxy iptables: the ClusterIP destination is rewritten to the actual pod IP before the packet leaves the node. The pod never sends a packet addressed to the ClusterIP; the translation is transparent.

**Verification (answers)**:

Scenario A:
1. src: `10.100.15.22`, dst: `140.82.121.4`
2. src: `10.100.15.22`, dst: `140.82.121.4` (bridge is layer 2, no IP change)
3. After MASQUERADE: src: `10.0.4.5`, dst: `140.82.121.4`
4. src: `10.0.4.5`, dst: `140.82.121.4`
5. After Cloud NAT SNAT: src: `34.110.50.3`, dst: `140.82.121.4`
6. src: `34.110.50.3`, dst: `140.82.121.4` (server sees NAT IP only)

Scenario B:
1. src: `10.100.15.22`, dst: `10.200.0.45:80`
2. After DNAT: src: `10.100.15.22`, dst: `10.100.3.8:8080`
3. src: `10.100.15.22`, dst: `10.100.3.8` (VPC routes this to `node-2` via alias IP)
4. src: `10.100.15.22`, dst: `10.100.3.8` (unchanged through fabric)
5. src: `10.100.15.22`, dst: `10.100.3.8` (pod sees originating pod IP as source)

---

## Exercise 4: Observe iptables MASQUERADE Rules on a Live Node

This exercise requires access to a node's network namespace — possible on kind or minikube without a privileged DaemonSet.

**Step 4.1: Identify iptables MASQUERADE rules**
```bash
# On a kind cluster, exec into the control-plane node container
docker exec -it kind-control-plane bash

# Inside the node, inspect the nat POSTROUTING chain
iptables -t nat -L POSTROUTING -n -v --line-numbers

# Look for MASQUERADE targets — these are the rules that SNAT pod traffic
# The rule typically looks like:
# MASQUERADE  all  --  10.244.0.0/16  !10.244.0.0/16  /* flannel masquerade */
# or for Calico:
# MASQUERADE  all  --  0.0.0.0/0     !224.0.0.0/4  ADDRTYPE match dst-type !LOCAL
```

**Step 4.2: Trace what happens for internet-bound traffic**
```bash
# From inside the kind node, check the PREROUTING chain too (shows DNAT rules from kube-proxy)
iptables -t nat -L PREROUTING -n -v | head -40

# For a specific ClusterIP service, trace the DNAT chain
# First get a ClusterIP
kubectl get svc -A | head -5

# Then trace the DNAT rules for that ClusterIP
CLUSTERIP=$(kubectl get svc kubernetes -o jsonpath='{.spec.clusterIP}')
iptables -t nat -L -n | grep -A5 "$CLUSTERIP" | head -20
```

**What's happening**: kube-proxy in iptables mode installs a chain of rules for every Service. The `PREROUTING` chain contains a rule that jumps to a service-specific chain (e.g., `KUBE-SVC-xxxx`) for traffic destined to the ClusterIP. That chain uses `statistic` probability matching to randomly select one of the pod endpoint chains (`KUBE-SEP-xxxx`), each of which performs a DNAT to the pod IP. The `POSTROUTING` chain contains the MASQUERADE rule that fires on egress.

**Step 4.3: Count rules and understand scale**
```bash
# Count total rules in the nat table
iptables -t nat -L -n | wc -l

# In a large cluster, this number climbs linearly with service and endpoint count
# Each service adds ~3 rules; each endpoint adds ~2 rules
# A 1000-service cluster with 5 pods each = 1000*3 + 5000*2 = 13,000 rules
# iptables traversal is O(N) per packet — this is why kube-proxy switched to IPVS
iptables -t nat -L -n | grep KUBE-SVC | wc -l
iptables -t nat -L -n | grep KUBE-SEP | wc -l
```

**Verification**: The number of `KUBE-SVC` chains should equal the number of Services in the cluster. The number of `KUBE-SEP` (service endpoint) chains should equal the total number of pod endpoints across all services.

---

## Exercise 5: CIDR Design Worksheet — Full Cluster Design

This is a design exercise. Complete it on paper or in a text editor before looking at the answer key in `lab/ip-planning-worksheet.md`.

**Scenario**: You are designing a new GKE cluster for a production platform. Requirements:
- Expected steady-state: 200 nodes running workloads
- Peak capacity (autoscaling + upgrades): must support 450 nodes simultaneously
- `max-pods-per-node`: 110 (default)
- Must peer with a second GKE cluster whose pod range is `172.20.0.0/14`
- Must connect via Cloud VPN to on-premises (`192.168.0.0/16`)
- Must not use the `10.0.0.0/8` range at all (it is already allocated to existing infrastructure)

**Your task**:

1. Choose a primary subnet range for node IPs. Justify the prefix length.
2. Choose a pod secondary range. Show the CIDR math for max nodes at max-pods-per-node=110. Verify no overlap with the peered cluster or on-premises.
3. Choose a service secondary range. Justify the prefix length.
4. Verify none of the three ranges overlap with each other or with the two external networks.
5. State the maximum node count and the maximum pod count your design supports.

**Hints**:
- Since `10.0.0.0/8` is off-limits, use `172.16.0.0/12` (private range) for the cluster networks
- The peered cluster already uses `172.20.0.0/14` — your pod range must not overlap
- On-premises uses `192.168.0.0/16` — your ranges must not overlap
- `172.16.0.0/12` covers `172.16.0.0` through `172.31.255.255`
- `172.20.0.0/14` covers `172.20.0.0` through `172.23.255.255`
- A safe pod range within `172.16.0.0/12` that does not overlap `172.20.0.0/14`: use `172.16.0.0/14` (covers `172.16.0.0`–`172.19.255.255`)

**What's happening**: This exercise forces you to think about CIDR selection as a global constraint-satisfaction problem, not just local sizing. A range that is large enough may still be unusable because it overlaps with peer networks, on-premises infrastructure, or the service range of the same cluster. In real production environments, CIDR selection is one of the most consequential networking decisions — it cannot be changed later without significant disruption.

**Verification**: Refer to `lab/ip-planning-worksheet.md` Exercise 3 for a similar worked example with answer key. For this exercise, an acceptable answer uses `172.28.0.0/20` for the node primary range (within `172.16.0.0/12`, outside the pod range and peered cluster range), `172.16.0.0/14` for pods (covers `172.16.0.0`–`172.19.255.255`, 262,144 IPs = 1,024 nodes at `/24`-per-node, no overlap with peered cluster's `172.20.0.0/14`), and `172.24.0.0/20` for services. Verify all three ranges are within `172.16.0.0/12` (`172.16.0.0`–`172.31.255.255`), non-overlapping with each other, and non-overlapping with the peered cluster (`172.20.0.0/14`) and on-premises (`192.168.0.0/16`).

---

## Key Takeaways

- The pod secondary range is the binding constraint for cluster node count. Size it at 2x your expected maximum node count times 256, or use `/14` for any cluster you expect to exceed 100 nodes.
- A `/16` pod range supports at most 256 nodes at max-pods-per-node=110. This is smaller than most people assume.
- iptables MASQUERADE on the node and Cloud NAT are two separate SNAT layers. Both must be present for internet connectivity from pods on nodes without public IPs.
- kube-proxy's iptables DNAT rules implement ClusterIP transparency — pods never know they are talking to a virtual IP.
- VPC peering requires non-overlapping secondary ranges, not just primary ranges. Design CIDR allocations from a central registry.
- IP exhaustion is diagnosed by checking `spec.podCIDR` on Node objects and calculating remaining `/24` blocks in the secondary range.
- Cloud NAT port exhaustion produces `EADDRNOTAVAIL` errors on pods and is diagnosed via Cloud NAT port usage metrics, not Kubernetes events.
