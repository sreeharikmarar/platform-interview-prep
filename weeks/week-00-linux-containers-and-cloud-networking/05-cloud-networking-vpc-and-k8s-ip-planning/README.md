# Cloud Networking: VPC, Subnets, SNAT/DNAT & Kubernetes IP Planning

## What you should be able to do

- Design VPC subnetting for a production GKE cluster of any size, derive exact CIDR ranges for the primary node range and both secondary ranges (pod and service), verify the math, and explain the headroom decisions you made.
- Trace the full packet path from a pod to the internet, naming each network hop (veth, bridge, iptables MASQUERADE, Cloud NAT) and explaining what address translation happens at each step and why.
- Diagnose IP address exhaustion from `kubectl` node and pod output alone, calculate remaining capacity, and describe the recovery path — both the short-term workaround and the long-term fix.
- Explain the functional difference between VPC-native and routes-based GKE clusters, the 250-node hard limit in routes-based mode, the VPC peering secondary-range constraint, and the Multi-CIDR feature introduced in GKE 1.26 to recover from exhaustion without cluster recreation.

## Mental Model

A VPC (Virtual Private Cloud) is software-defined networking at the cloud-provider layer. The cloud provider's SDN control plane programs virtual switches and routers in the hypervisor fabric to implement the forwarding rules you define — subnets carve up address space, route tables tell packets where to go, firewall rules allow or deny at the connection level, and VPC peering connects the forwarding domains of two VPCs by exchanging their routing tables. In GCP, a VPC is global — a single VPC spans all regions and zones, with regional subnets carved from it. In AWS, a VPC is regional — you pay for separate VPCs per region and connect them with transit gateway or peering. Kubernetes on either platform must fit its pod and service network into this pre-existing fabric, and the choices made at cluster creation time determine the operational ceiling of the cluster for its entire lifetime.

VPC-native GKE clusters are the architecture where pods get real VPC IP addresses, not tunnel addresses. The mechanism is GCP's Alias IP feature: when a node VM boots, the node IPAM controller (running inside kube-controller-manager) allocates a `/24` block of pod IPs from the pod secondary range and adds those 256 IPs as alias IP ranges on the node's primary NIC. The VPC routing fabric knows about every alias IP range on every node NIC, so a packet sent from outside the cluster to a pod IP reaches the correct node NIC without any tunneling or overlay. Inside the node, the CNI plugin (typically Calico or the GCP CNI) assigns individual IPs from the `/24` slice to pods via veth pairs and routes them off the `cbr0` bridge. The result is a flat pod network where every pod IP is natively routable within the VPC — which enables direct integration with load balancers, VPC peering peers, and on-premises networks via VPN or Interconnect.

The IP exhaustion problem is the most common operational failure in under-planned GKE clusters, and it is invisible until it is already too late. The architecture means that three independent CIDR blocks must all be sized correctly at cluster creation: the primary subnet range (node IPs, typically `/20` for large clusters), the pod secondary range (all pod IPs across all nodes, typically `/14` for very large clusters), and the service secondary range (ClusterIP addresses, typically `/20`). When the pod secondary range is exhausted, nodes cannot join the cluster because the node IPAM controller cannot allocate a `/24` pod CIDR for them. When a node's own pod CIDR is full, new pods on that node stay `Pending`. Both failures look similar from the surface — nodes stuck `NotReady`, pods stuck `Pending` — but they have different root causes, different scopes, and different mitigations. The key operational question is always: at what layer is the exhaustion occurring — the cluster-wide pod secondary range, or an individual node's `/24` slice?

SNAT and DNAT are the two address translation operations that connect the private pod network to the public internet and to external load balancer traffic. SNAT (Source NAT) rewrites the source IP on packets leaving the cluster — when a pod initiates a connection to an external service, iptables MASQUERADE rules on the node rewrite the pod source IP to the node's IP before the packet leaves the NIC; Cloud NAT on the VPC edge then rewrites the node IP to a public IP from the NAT pool. DNAT (Destination NAT) is the inbound path — when an external client connects to a LoadBalancer Service VIP, the load balancer's backend routing maps the VIP to a node IP, and kube-proxy's iptables DNAT rules on the node map the NodePort to the actual pod IP and port. The address translation is stateful at both layers, and understanding which address each component sees is critical for debugging: a pod log shows its own pod IP, a backend server sees the Cloud NAT public IP, and a service mesh sidecar sees the pre-SNAT pod IP on node-local traffic but the post-DNAT pod IP on load-balanced traffic.

## Key Concepts

- **VPC (Virtual Private Cloud)**: A software-defined network in the cloud provider. In GCP, VPCs are global and span all regions; subnets are regional. In AWS, VPCs are regional; cross-region connectivity requires transit gateway or peering. A VPC contains subnets (CIDR blocks with their own routing tables), firewall rules (stateful connection filters applied at the VM NIC level), and route tables (next-hop rules that the SDN programs into the hypervisor fabric). VPC peering connects two VPCs by exchanging their route tables so traffic between them routes through the fabric without passing through the internet.

- **Primary subnet range**: The IP range assigned to node VMs. Each node gets one IP from this range on its primary NIC. In GKE, the primary range is a regular subnet CIDR (e.g., `10.0.0.0/20` = 4096 addresses). This range sizes the maximum number of nodes — a `/20` allows up to 4096 node IPs, which is far more than any single GKE cluster needs for nodes. Size generously because subnets cannot be resized without downtime.

- **Secondary ranges (Alias IP)**: GCP subnets support secondary CIDR ranges in addition to the primary range. GKE VPC-native clusters use two secondary ranges: one for pod IPs and one for service ClusterIPs. The pod secondary range (e.g., `10.100.0.0/14`) is allocated in `/24` slices to nodes — each node gets 256 pod IPs from this pool. The service secondary range (e.g., `10.200.0.0/20`) is used exclusively by kube-apiserver to assign ClusterIP addresses to Services. Both secondary ranges must be specified at cluster creation; they cannot be changed after the fact without cluster recreation (or Multi-CIDR in GKE 1.26+).

- **VPC-native vs routes-based GKE**: In routes-based clusters (legacy), GKE installs one static route per node pointing `node-pod-cidr → node-vm-ip`. GCP VPC has a hard limit of 250 routes per VPC network, which caps routes-based clusters at 250 nodes. In VPC-native clusters (Alias IP), pod CIDRs are alias ranges on the node NIC — the VPC fabric handles routing natively without static routes, supporting up to 15,000 nodes per VPC. Routes-based clusters also cannot be used with VPC peering (peered networks do not inherit static routes) or with Shared VPC. All new clusters should be VPC-native.

- **SNAT (Source NAT)**: Rewrites the source IP address on outgoing packets. When a pod (IP `10.100.5.10`) sends a packet to `8.8.8.8`, the packet traverses the node's veth pair and bridge, hits the iptables `POSTROUTING` chain, and the `MASQUERADE` rule rewrites the source IP to the node's primary IP (`10.0.0.5`). The node then sends the packet to the VPC gateway. If Cloud NAT is configured, the VPC NAT gateway rewrites the node IP to a public IP from the NAT pool before forwarding to the internet. SNAT is stateful: the NAT table records the mapping so return packets can be reverse-translated.

- **DNAT (Destination NAT)**: Rewrites the destination IP address on incoming packets. Two uses in Kubernetes. First, kube-proxy implements ClusterIP as DNAT: when a pod sends a packet to a ClusterIP (e.g., `10.200.0.5:80`), iptables DNAT rules in the `PREROUTING` chain rewrite the destination to a randomly selected pod IP from the Endpoints list (`10.100.8.3:8080`). Second, LoadBalancer Services: the cloud load balancer accepts traffic on the VIP, performs DNAT to a node IP on the NodePort, and kube-proxy's iptables rules then DNAT again from NodePort to pod IP. Two levels of DNAT, both transparent.

- **IP masquerade agent**: A DaemonSet (`ip-masq-agent`) that runs on every node and configures iptables MASQUERADE rules for traffic destined to non-RFC1918 addresses. For destinations within the VPC (RFC1918: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`), pods do not need MASQUERADE — the pod IP is natively routable within the VPC. For internet-bound traffic (non-RFC1918 destinations), MASQUERADE rewrites the source to the node IP so return traffic knows where to come back. The masquerade agent reads its config from a ConfigMap and can be customized to exclude specific subnets (e.g., on-prem subnets reachable via VPN that should see the real pod IP for logging or firewall policy).

- **Max pods per node and the /24 allocation**: GKE's default `max-pods-per-node` is 110. To fit 110 pods, GKE needs at least 110 IPs on each node. GKE allocates a `/24` (256 IPs) per node from the pod secondary range when max-pods-per-node is between 65 and 110. When max-pods-per-node is set to 32 or lower, GKE allocates a `/26` (64 IPs) instead, fitting 16x more nodes into the same pod secondary range. The `/24`-per-node allocation is the primary sizing input for pod secondary range math.

- **Subnetting math — node capacity formula**: `max_nodes = pod_secondary_range_size / ips_per_node_allocation`. With max-pods-per-node=110 (each node gets a `/24` = 256 IPs): a `/14` pod range = 262,144 IPs ÷ 256 = 1,024 nodes. A `/16` pod range = 65,536 IPs ÷ 256 = 256 nodes. A `/20` pod range = 4,096 IPs ÷ 256 = 16 nodes. Always design for 2x the expected node count to handle autoscaling peaks, fleet migration periods, and blue/green node pool upgrades where old and new nodes coexist temporarily.

- **IP exhaustion scenarios**: Three distinct failure layers. (1) Pod secondary range full: the node IPAM controller cannot allocate a `/24` for new nodes joining — `kubectl describe node` shows no `spec.podCIDR` assigned; autoscaler logs `"no IP ranges available"`; new nodes stay `NotReady`. (2) Node pod CIDR full: a node has all 256 IPs in its `/24` assigned to pods — new pods on that node stay `Pending` with the event `"0/N nodes are available: N Insufficient pods"`; other nodes with available IPs can still run pods. (3) Service range full: kube-apiserver cannot assign a ClusterIP — `kubectl create service` returns `"no available IP ranges"`; existing services are unaffected but no new services can be created.

- **VPC peering constraints**: When two VPCs are peered, their primary subnet ranges cannot overlap (the peering will fail if they do). Critically for GKE, the secondary ranges used for pods and services also participate in the overlap check for VPC peering — even though secondary ranges are not directly exchanged as routes, they must be non-overlapping with the peer VPC's ranges for GKE-specific network features (including GKE Hub integration) to work correctly. This is a common failure point when two teams independently design their GKE clusters and later try to peer the VPCs.

- **Private Google Access**: Nodes in a VPC-native cluster can be given private IP addresses only — no public IP assigned to the node NIC. Traffic from these nodes to Google APIs (Container Registry, Cloud Storage, Cloud Logging, Artifact Registry) goes to Google's private IP address ranges (`199.36.153.8/30` or `restricted.googleapis.com`) via the VPC routing fabric, never touching the public internet. This requires the subnet's `privateIpGoogleAccess` flag to be enabled and appropriate DNS entries for `*.googleapis.com` to resolve to the private range. Used in high-security environments where nodes must not have public IPs.

- **Multi-CIDR (GKE 1.26+)**: A GKE feature that allows adding additional pod secondary ranges to an existing cluster without recreating it. When the original pod secondary range approaches exhaustion, you can add a second secondary range to the cluster; the node IPAM controller starts allocating `/24` slices from both ranges for new nodes. New nodes can draw from either range. This is the primary recovery path when a cluster has exhausted its pod secondary range and you cannot immediately recreate the cluster — add a new secondary range in a non-overlapping CIDR and enable Multi-CIDR to extend the address pool without downtime.

- **Cloud NAT port exhaustion**: Cloud NAT assigns source ports from a pool to outgoing connections. By default, GCP allocates 64 ephemeral ports per VM for NAT. A node running 100 pods making concurrent external connections can exhaust its port allocation on the NAT gateway, causing new connections to fail with `"connect: cannot assign requested address"` or `"TCP connection timed out"`. The fix is to increase the `minPortsPerVm` setting on the Cloud NAT configuration or enable dynamic port allocation, which allows the NAT gateway to dynamically assign additional ports from the shared pool.

- **GKE node pool sizing and headroom**: Node pools are the unit of scaling in GKE. Each node pool can have a different machine type and max-pods-per-node setting, which changes its pod CIDR allocation size. A cluster with multiple node pools draws from the same pod secondary range. The total pod secondary range must accommodate the maximum node count across all node pools simultaneously, including the headroom for concurrent upgrade waves (where old and new node pool nodes coexist during a rolling upgrade). The standard headroom factor is 2x the maximum steady-state node count.

## Internals

### VPC-Native IP Allocation: From Cluster Creation to Pod Running

The IP allocation sequence in a VPC-native GKE cluster involves the cloud control plane, the Kubernetes node IPAM controller, and the CNI plugin. Understanding the handoffs between these layers explains both normal operation and failure modes.

At cluster creation time, the GKE control plane (the managed GKE API) validates that the specified primary subnet range and both secondary ranges exist in the VPC, are non-overlapping with each other and with any peered VPCs, and are large enough to support the requested initial node count. GKE then annotates the cluster with the secondary range names it will use for pods and services.

When a new node VM boots (triggered by the cluster autoscaler or a manual node pool resize), the sequence is:

1. **VM provisioning**: GCP creates the VM with the primary NIC getting one IP from the primary subnet range. The VM has no pod IPs yet — the alias IP range is not yet assigned.

2. **Node registration**: The kubelet on the new node registers with the API server, creating a Node object with no `spec.podCIDR` field set.

3. **IPAM controller allocation**: The `nodeIpamController` component in `kube-controller-manager` watches for Node objects without `spec.podCIDR`. It selects the next available `/24` block from the pod secondary range (tracking used ranges in a persistent bitmap stored in etcd), assigns it to the node by writing `spec.podCIDR` to the Node object, and simultaneously calls the GCE API to add the allocated `/24` as an alias IP range on the node's primary NIC.

4. **GCE alias IP programming**: GCP's SDN fabric programs the hypervisor to accept packets destined to any IP in the node's alias IP range and deliver them to that node's NIC. From this moment, the pod IPs are routable in the VPC even before any pods exist.

5. **CNI plugin initialization**: The CNI plugin (running as a DaemonSet or init container on the node) reads the node's `spec.podCIDR` and configures the `cbr0` bridge and local route table to route that subnet. It reserves the first IP for the bridge gateway address.

6. **Pod IP assignment**: When a pod is scheduled to the node, the kubelet calls the CNI plugin via the CNI API. The CNI plugin (using the `host-local` IPAM or the GCP-specific IPAM) selects an available IP from the node's `spec.podCIDR` range, creates a veth pair (one end in the container network namespace, one end on the `cbr0` bridge), assigns the IP to the container-side veth end, and returns the assigned IP to the kubelet. The kubelet writes the pod's IP to the Pod status.

The annotation `node.alpha.kubernetes.io/ttl` on the Node object records the IPAM allocation metadata. Inspecting `spec.podCIDR` and `spec.podCIDRs` (the multi-CIDR variant) on each Node object is the primary diagnostic for IPAM state.

### SNAT/DNAT Packet Trace: Pod to Internet and Return

A complete packet trace from a pod (`10.100.5.10`) on node `node-1` (`10.0.0.5`) sending a DNS query to `8.8.8.8:53`:

**Outbound path:**

1. Pod's kernel routes the packet. The pod network namespace has a default route via its `eth0` (the veth container end). The packet is sent to `10.100.5.1` (the bridge gateway IP) via `eth0`.

2. The veth pair carries the packet from the container namespace to the `cbr0` bridge in the node root namespace. The source IP is `10.100.5.10`, destination is `8.8.8.8`.

3. The `cbr0` bridge forwards the packet to the node's routing stack. The node's route table matches `0.0.0.0/0 via 10.0.0.1 dev eth0` (the VPC subnet gateway) — the packet is routed to the internet gateway.

4. Before leaving through `eth0`, the packet traverses iptables `POSTROUTING` in the `nat` table. The `MASQUERADE` rule matches: `! -d 10.0.0.0/8 -j MASQUERADE` (any non-RFC1918 destination, masquerade the source). iptables rewrites the source IP from `10.100.5.10` to `10.0.0.5` (the node's NIC IP) and creates a conntrack entry recording the translation.

5. The packet leaves the node NIC with source `10.0.0.5`, destination `8.8.8.8`. It enters the VPC fabric.

6. If Cloud NAT is configured on the subnet's router, the Cloud NAT gateway intercepts the packet and performs a second SNAT: source `10.0.0.5` → `34.102.50.3` (a public IP from the NAT pool). The Cloud NAT service records the mapping. The packet exits to the internet.

**Return path:**

1. `8.8.8.8` sends a response to `34.102.50.3`. Cloud NAT looks up the connection in its state table, reverses the translation: destination `34.102.50.3` → `10.0.0.5`. The packet re-enters the VPC.

2. The VPC fabric routes the packet to node `node-1` (IP `10.0.0.5`). The packet arrives at the node NIC.

3. iptables `PREROUTING` (actually, for established connections, conntrack handles this): the kernel's connection tracking table records that this connection's NAT mapping is source `10.100.5.10`. The packet's destination is rewritten: `10.0.0.5` → `10.100.5.10`. The conntrack `ESTABLISHED` match bypasses the full iptables rule evaluation.

4. The node routing table routes `10.100.5.10` to the `cbr0` bridge, which forwards via the veth pair to the pod. The pod receives the response with source `8.8.8.8`, destination `10.100.5.10` — its own IP, as expected.

The critical observation: the external server at `8.8.8.8` only ever sees the Cloud NAT public IP. The pod IP and node IP are both hidden. This affects services that log source IPs for security or analytics — those logs will show the NAT IP, not the pod IP, requiring Cloud NAT logging and correlation to trace back to the originating pod.

### IP Exhaustion Diagnosis: Commands and Calculation

When a node cannot join or a pod cannot start due to IP issues, the diagnostic sequence is:

**Step 1: Check node pod CIDR assignments**
```bash
# List all nodes and their assigned pod CIDRs
kubectl get nodes -o json | jq -r '.items[] | [.metadata.name, .spec.podCIDR // "UNASSIGNED"] | @tsv'
```

A node showing `UNASSIGNED` means the nodeIpamController could not allocate a `/24` — the pod secondary range is likely exhausted.

**Step 2: Calculate used vs available blocks in the pod secondary range**
```bash
# Count nodes with assigned CIDRs
ASSIGNED=$(kubectl get nodes -o json | jq '[.items[] | select(.spec.podCIDR != null)] | length')
echo "Nodes with pod CIDR: $ASSIGNED"

# Determine pod secondary range (check the cluster or node annotations)
kubectl get nodes -o json | jq -r '.items[0].metadata.annotations | to_entries[] | select(.key | contains("network")) | .key + ": " + .value'
```

If the pod secondary range is `10.100.0.0/14` (262,144 IPs) and `/24` blocks are allocated per node, maximum nodes = 262,144 / 256 = 1,024. If 1,000 nodes are assigned, only 24 blocks remain — each block is one node's capacity. Any autoscaling burst beyond 24 nodes will fail.

**Step 3: Check individual node capacity**
```bash
# For a specific node: how many IPs are used?
NODE=node-1
POD_CIDR=$(kubectl get node $NODE -o jsonpath='{.spec.podCIDR}')
echo "Node pod CIDR: $POD_CIDR"

# Count pods running on this node
PODS_ON_NODE=$(kubectl get pods -A -o json | jq --arg node "$NODE" \
  '[.items[] | select(.spec.nodeName == $node) | select(.status.phase == "Running")] | length')
echo "Pods running: $PODS_ON_NODE / $(kubectl get node $NODE -o jsonpath='{.status.allocatable.pods}')"
```

**Step 4: Check the nodeIpamController logs**
```bash
# In GKE, the controller manager runs as a managed component; check events instead
kubectl get events -A --field-selector reason=FailedCreate | grep -i "ip\|cidr\|range"

# On self-managed clusters, check controller-manager logs
kubectl logs -n kube-system -l component=kube-controller-manager | grep -i "ipam\|cidr\|no.*range"
```

**Recovery options in order of invasiveness:**
1. Delete stuck/evicted pods consuming CIDR slots (immediately frees IPs within a node's `/24`)
2. Drain and delete nodes with very few running pods (frees entire `/24` blocks back to the pool)
3. Add a second node pool with `max-pods-per-node=32` (gets `/26` allocations, 4x more nodes per secondary range unit)
4. Enable Multi-CIDR and add a new secondary range (GKE 1.26+, no cluster recreation required)
5. Recreate the cluster with a larger pod secondary range (last resort, requires migration)

## Architecture Diagram

```
  GCP VPC (global)
  ┌─────────────────────────────────────────────────────────────────────────────────┐
  │                                                                                 │
  │  Region: us-central1                                                            │
  │  ┌───────────────────────────────────────────────────────────────────────────┐  │
  │  │  Subnet: gke-nodes (primary range: 10.0.0.0/20)                          │  │
  │  │                                                                           │  │
  │  │  Secondary ranges attached to this subnet:                                │  │
  │  │  ┌─────────────────────────────────┐  ┌───────────────────────────────┐  │  │
  │  │  │  pod-range: 10.100.0.0/14       │  │  svc-range: 10.200.0.0/20    │  │  │
  │  │  │  (262,144 IPs, 1024 x /24 slots)│  │  (4,096 ClusterIP addresses) │  │  │
  │  │  └─────────────────────────────────┘  └───────────────────────────────┘  │  │
  │  │                                                                           │  │
  │  │  ┌──────────────────────┐  ┌──────────────────────┐                      │  │
  │  │  │  node-1              │  │  node-2              │                       │  │
  │  │  │  NIC: 10.0.0.5/20   │  │  NIC: 10.0.0.6/20   │                      │  │
  │  │  │  Alias: 10.100.0.0/24│ │  Alias: 10.100.1.0/24│                      │  │
  │  │  │                      │  │                      │                       │  │
  │  │  │  cbr0: 10.100.0.1   │  │  cbr0: 10.100.1.1   │                       │  │
  │  │  │  ┌────────────────┐  │  │  ┌────────────────┐  │                      │  │
  │  │  │  │ pod-a          │  │  │  │ pod-c          │  │                      │  │
  │  │  │  │ 10.100.0.10    │  │  │  │ 10.100.1.5     │  │                      │  │
  │  │  │  └────────────────┘  │  │  └────────────────┘  │                      │  │
  │  │  │  ┌────────────────┐  │  │  ┌────────────────┐  │                      │  │
  │  │  │  │ pod-b          │  │  │  │ pod-d          │  │                      │  │
  │  │  │  │ 10.100.0.11    │  │  │  │ 10.100.1.6     │  │                      │  │
  │  │  │  └────────────────┘  │  │  └────────────────┘  │                      │  │
  │  │  └──────────┬───────────┘  └──────────┬───────────┘                      │  │
  │  │             │                         │                                   │  │
  │  │             └────────────┬────────────┘                                   │  │
  │  │                          │ VPC SDN fabric (L2/L3 switching)               │  │
  │  │                          │ Routes alias IPs natively                      │  │
  │  └──────────────────────────┼───────────────────────────────────────────────┘  │
  │                             │                                                   │
  │  Cloud Router + Cloud NAT   │                                                   │
  │  ┌──────────────────────────▼───────────────────┐                              │
  │  │  Cloud NAT Gateway                           │                              │
  │  │  NAT IP pool: 34.102.50.0/28                 │                              │
  │  │                                              │                              │
  │  │  SNAT: 10.0.0.5 → 34.102.50.3               │                              │
  │  │  (node IP → public NAT IP)                   │                              │
  │  │  Pod MASQUERADE handled at iptables on node  │                              │
  │  │  before packet even reaches Cloud NAT        │                              │
  │  └──────────────────────────┬───────────────────┘                              │
  └─────────────────────────────┼───────────────────────────────────────────────────┘
                                │
                                ▼ Internet (8.8.8.8, etc.)

  Packet path (pod → internet):
  pod eth0 → veth → cbr0 bridge → node iptables MASQUERADE (pod IP → node IP)
  → node eth0 → VPC fabric → Cloud NAT SNAT (node IP → public IP) → internet

  Packet path (internet → pod, return):
  internet → Cloud NAT DNAT (public IP → node IP) → VPC fabric → node eth0
  → conntrack DNAT (node IP → pod IP) → cbr0 → veth → pod eth0

  DNAT path (ClusterIP → pod):
  pod → iptables PREROUTING DNAT (ClusterIP:port → pod-IP:port) → cbr0 or eth0 → destination pod

  IP allocation hierarchy:
  Secondary range: 10.100.0.0/14  (1,024 blocks of /24)
       └── node-1 gets 10.100.0.0/24  (256 IPs; pods use .10 through .254)
       └── node-2 gets 10.100.1.0/24  (256 IPs; pods use .10 through .254)
       └── node-N gets 10.100.(N-1).0/24
       └── ... up to 1,024 nodes before secondary range is full
```

## Failure Modes & Debugging

### 1. Pod Secondary Range Exhausted ("no IP addresses available in range set")

**Symptoms**: New nodes are created by the cluster autoscaler but stay in `NotReady` state indefinitely. `kubectl describe node <new-node>` shows no `spec.podCIDR` field. GKE cluster autoscaler logs contain `"IP allocation failed"` or `"no available IP ranges in alias-ip-range-set"`. Existing nodes and pods are completely unaffected — this failure is additive, not degrading. The node appears in `kubectl get nodes` with `STATUS: NotReady` and the `node.kubernetes.io/not-ready:NoSchedule` taint is automatically applied, preventing any pods from being scheduled on it. Cluster events show `FailedCreate` for the nodeIPAM controller.

**Root Cause**: The pod secondary range has been fully allocated to existing nodes. With `max-pods-per-node=110`, each node consumes one `/24` (256 IPs) from the secondary range. A `/20` pod secondary range (4,096 IPs) supports exactly 16 nodes. A `/21` supports 8. A `/22` supports 4. Any autoscaling event that would add a node beyond the range's capacity fails at the IPAM allocation step because there is no free `/24` block to assign.

**Blast Radius**: No new nodes can join the cluster. The autoscaler cannot scale out even if node CPU and memory are at capacity. Pod scheduling failures cascade if existing nodes are also resource-saturated — new pods stay `Pending` indefinitely because no nodes have scheduling capacity and no new nodes can be added. Stateless services degrade as pod count cannot keep up with load. This failure is gradual over weeks or months and is often not noticed until the cluster is already at capacity.

**Mitigation**:
- Immediate: Identify nodes with low pod utilization — if a node has only 5 pods running, its other 251 IPs are reserved but unused. Drain and delete such nodes to reclaim their `/24` blocks.
- Short-term: Lower `max-pods-per-node` on a new node pool and add nodes from the new pool. At `max-pods-per-node=32`, GKE allocates a `/26` (64 IPs) per node — 4x more nodes per secondary range unit.
- Medium-term: Enable Multi-CIDR (GKE 1.26+) and add a second secondary range to the cluster. New nodes can draw from either range.
- Long-term: Design new clusters with the formula `secondary_range_size = max_nodes * 256 * 2` (2x headroom) and prefer `/14` pod ranges for any cluster expected to exceed 100 nodes.

**Debugging**:
```bash
# Check which nodes have pod CIDRs assigned vs which are stuck unassigned
kubectl get nodes -o json | jq -r \
  '.items[] | [.metadata.name, (.spec.podCIDR // "UNASSIGNED"), .status.conditions[-1].type] | @tsv'

# Count total allocated /24 blocks
USED=$(kubectl get nodes -o json | jq '[.items[] | select(.spec.podCIDR != null)] | length')
echo "Allocated /24 blocks (nodes with pod CIDR): $USED"

# Check cluster autoscaler logs for IP range errors
kubectl logs -n kube-system -l app=cluster-autoscaler | grep -i "ip\|range\|alias\|cidr" | tail -30

# Inspect GKE cluster secondary ranges (requires gcloud)
gcloud container clusters describe <cluster-name> \
  --region=<region> \
  --format='yaml(ipAllocationPolicy)'

# Check for nodes with unusually low pod counts (candidates for drain/delete to free CIDRs)
kubectl get nodes -o json | jq -r \
  '.items[] | [.metadata.name, .status.allocatable.pods] | @tsv' | sort -k2 -n
```

---

### 2. Node Stuck NotReady — nodeIpamController Failure

**Symptoms**: A specific node is `NotReady` and `kubectl describe node <node>` shows `spec.podCIDR` is set, but the node reports `NetworkPlugin kubenet does not ensure pod network` or `cni plugin not initialized` in its conditions. The kube-controller-manager logs show repeated errors for the nodeIpamController. Alternatively, the node has `spec.podCIDR` set to a CIDR that overlaps with another node's CIDR — a split-brain scenario after a controller restart.

**Root Cause**: The nodeIpamController crashed or had its persistent state corrupted in etcd. On restart, it may attempt to reallocate a CIDR that was already assigned to another node, or it may fail to reconcile the GCE alias IP with the Node object's `spec.podCIDR`. This can also happen when a node is force-deleted from the Kubernetes API without proper drain — the alias IP range remains assigned in GCP but the Node object is gone, leaving the CIDR in an orphaned state that the controller does not re-use.

**Blast Radius**: The affected node cannot run pods. If the IPAM controller is completely broken (not just for one node), all new nodes will fail to get pod CIDRs and the cluster cannot grow. Existing pods on already-provisioned nodes continue running normally — this does not affect existing workloads.

**Mitigation**: Restart the kube-controller-manager pod (on managed GKE, trigger a control plane repair). Verify that the GCE alias IP ranges on each node's NIC exactly match the `spec.podCIDR` of the corresponding Node object. Manually reconcile any discrepancies by deleting the orphaned alias IP range in GCE and allowing the controller to re-allocate.

**Debugging**:
```bash
# Check for CIDR conflicts between nodes
kubectl get nodes -o json | jq -r '.items[] | [.metadata.name, .spec.podCIDR] | @tsv' | sort -k2

# Verify GCE alias IP ranges match Node spec.podCIDR (requires gcloud)
gcloud compute instances describe <node-vm-name> \
  --zone=<zone> \
  --format='yaml(networkInterfaces[].aliasIpRanges)'

# Check controller-manager logs for IPAM errors
kubectl logs -n kube-system -l component=kube-controller-manager \
  | grep -i "ipam\|nodecidr\|allocat" | tail -40

# Check node conditions for network readiness
kubectl describe node <node-name> | grep -A5 "Conditions:"
kubectl describe node <node-name> | grep -i "cni\|network\|cidr"
```

---

### 3. VPC Peering Failure — Secondary Range Overlap

**Symptoms**: Attempting to create a VPC peering connection between two GKE cluster VPCs fails with `"The peering route table is too large"` or `"Peering would result in network overlap"`. Alternatively, the peering succeeds but traffic between pods in the two clusters fails with no route or ICMP host-unreachable, even though the service IP ranges do not visually overlap. A cluster Interconnect or VPN extension to on-premises also fails to pass traffic to pod IPs.

**Root Cause**: GCP VPC peering requires that neither the primary subnet ranges nor the secondary ranges of the two VPCs overlap. This is because GCP's peering implementation imports routes for all subnets (primary and secondary) from the peer VPC. If two GKE clusters were independently designed with the same or overlapping pod secondary ranges (a common mistake when both teams copy a "standard" design), peering will either fail outright or succeed with silent routing failures where packets are incorrectly forwarded within the local VPC instead of being sent to the peer.

**Blast Radius**: The peering cannot be established or is broken. Any workload that requires cross-cluster or on-premises connectivity is completely blocked. This is particularly painful when discovered after both clusters are fully provisioned and running production workloads — the remediation requires either cluster recreation (with corrected CIDR ranges) or complex network address translation at the boundary.

**Mitigation**: Enforce CIDR allocation from a central registry (IPAM tool, Terraform workspace variable, Shared VPC design) that tracks all allocated ranges and prevents overlap at provisioning time. Use a consistent, hierarchical CIDR plan: allocate a `/10` per environment (prod/staging/dev), subdivide into per-region `/14` blocks, and within each region allocate per-cluster `/16` pod ranges and `/20` service ranges, all drawn from a tracked allocation sheet.

**Debugging**:
```bash
# Check effective routes in a VPC to identify overlaps (requires gcloud)
gcloud compute routes list \
  --filter="network=<vpc-name>" \
  --format='table(name,destRange,nextHopInstance)'

# Check secondary ranges currently in use by each subnet
gcloud compute networks subnets describe <subnet-name> \
  --region=<region> \
  --format='yaml(secondaryIpRanges)'

# Attempt to create the peering and capture the error
gcloud compute networks peerings create <peering-name> \
  --network=<local-vpc> \
  --peer-network=<peer-vpc> \
  --peer-project=<peer-project>

# List all VPC peerings and their imported routes to identify what is being conflicted
gcloud compute networks peerings list \
  --network=<vpc-name>
```

---

### 4. Cloud NAT Port Exhaustion — Intermittent Internet Connectivity Failures

**Symptoms**: Pods on specific nodes intermittently fail to connect to external services (`curl`, DNS lookups to external resolvers, image pulls from non-GCR registries). The failures are not consistent — they happen for some connections but not others on the same node. `dmesg` on the node or pod application logs show `"connect: cannot assign requested address"` or `"connection timed out"` to external IPs. Notably, connections within the VPC (pod-to-pod, pod-to-ClusterIP) work fine. The failures correlate with high outbound connection rates from specific nodes.

**Root Cause**: Cloud NAT maintains a mapping of `(node-IP, source-port, destination-IP, destination-port) → NAT-public-IP:NAT-port` for every active outgoing connection. By default, GCP allocates a static minimum of 64 source ports per VM from the NAT IP pool. When a single node has many concurrent outbound connections (e.g., 100 pods each making 5 concurrent HTTP connections to external APIs = 500 concurrent connections), it exceeds 64 ports. New connections cannot be mapped and are dropped with `EADDRNOTAVAIL`. This is particularly common with connection-pooled clients (gRPC with many streams, HTTP keep-alive clients with many concurrent streams) that hold connections open, exhausting the port allocation even at moderate request rates.

**Blast Radius**: Specific nodes with high egress connection rates lose the ability to make new external connections. If the affected workload is distributed across many nodes, only the high-traffic nodes are affected — creating partial, hard-to-reproduce failures. Pods on less-loaded nodes in the same cluster are unaffected. This looks like a flaky external service but is actually a local resource exhaustion.

**Mitigation**:
- Set `minPortsPerVm` to a higher value in the Cloud NAT configuration (e.g., 1024 or 4096). This is a per-VM reservation; increasing it reduces the total number of VMs the NAT IP pool can serve simultaneously.
- Enable dynamic port allocation on the Cloud NAT resource, which allows the gateway to assign additional ports from the shared pool on demand rather than pre-allocating a fixed amount per VM.
- Add additional NAT IP addresses to the Cloud NAT IP pool, increasing the total available port space.
- At the application level, implement connection pooling and limiting to reduce the number of concurrent outbound connections per pod.

**Debugging**:
```bash
# Check Cloud NAT metrics in GCP (via Cloud Monitoring, or gcloud)
# Key metric: router.googleapis.com/nat/port_usage per VM
# Any VM at 100% of its minPortsPerVm allocation is exhausted
gcloud compute routers get-nat-mapping-info <router-name> \
  --region=<region> \
  --nat-name=<nat-name>

# On the node: check for EADDRNOTAVAIL errors in the kernel log
# (requires SSH to node or privileged DaemonSet)
kubectl debug node/<node-name> -it --image=ubuntu -- bash -c "journalctl -k | grep 'EADDRNOTAVAIL\|cannot assign'"

# Check Cloud NAT logs in Cloud Logging (GCP Console or gcloud logging)
# Filter for the specific node's IP and look for translation_failed events
gcloud logging read \
  'resource.type="nat_gateway" AND jsonPayload.connection.src_ip="<node-ip>"' \
  --limit=50 --format=json | jq '.[].jsonPayload | {src_ip, dest_ip, outcome}'

# Check current NAT configuration (minPortsPerVm, dynamicPortAllocation)
gcloud compute routers describe <router-name> \
  --region=<region> \
  --format='yaml(nats)'

# Verify a pod can reach an internal IP but not an external IP (isolates NAT vs network)
kubectl exec -it <pod-name> -n <namespace> -- sh -c \
  "curl -sv --connect-timeout 5 http://10.0.0.1 2>&1 | head -5; \
   curl -sv --connect-timeout 5 http://8.8.8.8 2>&1 | head -5"
```
