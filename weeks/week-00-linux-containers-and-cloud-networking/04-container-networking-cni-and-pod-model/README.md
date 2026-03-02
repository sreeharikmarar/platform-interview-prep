# Container Networking, CNI & the Pod Network Model

## What you should be able to do

- Trace a TCP packet from pod A on node 1 to pod B on node 2, naming every kernel data structure the packet traverses: eth0, veth pair, Linux bridge, host routing table, VXLAN/BGP encapsulation, and the reverse path.
- Explain what a CNI plugin does, what inputs it receives, and what it must create in the pod's network namespace before the container process starts.
- Describe the Kubernetes pod networking model in one sentence and explain why it eliminates an entire class of NAT-related bugs that plagued pre-Kubernetes container platforms.
- Diagnose four failure modes — missing CNI binary, podCIDR exhaustion, ARP flooding, eBPF/iptables conflict — using real `ip`, `iptables`, `crictl`, and `kubectl` commands.

## Mental Model

Every network interface in Linux belongs to exactly one network namespace. A network namespace is a complete, isolated copy of the kernel's networking stack: its own loopback, its own set of physical and virtual interfaces, its own routing table, its own iptables rules, its own ARP table, its own port space. When the container runtime creates a pod, it first creates a new network namespace for that pod (via `unshare(CLONE_NEWNET)` or `clone()`). At the moment of creation, the namespace has only a loopback interface and cannot reach anything. The CNI plugin's entire job is to wire this isolated namespace into the broader cluster network so packets can flow in and out.

The wiring mechanism is a veth pair. A veth pair is a virtual Ethernet cable: two virtual interfaces bound together at the kernel level such that any packet written to one end immediately appears on the other end. CNI creates a veth pair, moves one end into the pod's network namespace (naming it `eth0` there), and leaves the other end in the host's root network namespace (naming it something like `vethXXXXXX`). The host end of the pair is then plugged into a Linux bridge — a virtual Layer 2 switch implemented in the kernel that performs MAC learning, ARP proxying, and frame forwarding between all attached ports. Every pod on the node has one veth end in the bridge. The bridge has an IP address on the node's podCIDR subnet and acts as the default gateway for all pods on that node.

The Kubernetes pod networking model has three rules enforced by convention rather than code: every pod gets a unique, routable IP address; pods can reach any other pod by that IP without NAT; and nodes can reach pods directly without NAT. This "flat network" contract is what makes service discovery simple — a pod's IP is its address everywhere in the cluster. The mechanism for enforcing this contract differs by CNI implementation: overlay networks (Flannel, Cilium in VXLAN mode) wrap the original IP packet in an outer UDP/VXLAN header to route across nodes that don't have pod routes; underlay networks (Calico BGP, AWS VPC CNI) advertise pod IPs directly into the node's routing infrastructure so the original packet is routed without encapsulation. Both satisfy the model; they differ in complexity, overhead, and what the underlying network must support.

eBPF is fundamentally changing where this logic runs. Traditional CNI implementations use iptables for service load balancing (kube-proxy), NAT on egress, and policy enforcement. iptables is a sequential rule chain that the kernel walks per packet — every DNAT rule for a service adds one more entry to traverse. With 10,000 services, a single packet traverses 10,000+ iptables entries before reaching a verdict. Cilium replaces this with eBPF programs attached at TC (Traffic Control) and XDP (eXpress Data Path) hooks that implement policy, load balancing, and NAT as JIT-compiled bytecode maps — O(1) lookups instead of O(N) chain traversal — and can replace kube-proxy entirely.

## Key Concepts

- **Linux network namespace**: A full isolated copy of the kernel's network stack. Has its own loopback (`lo`), Ethernet interfaces, routing table, ARP table, conntrack table, and iptables rules. Created via `clone(CLONE_NEWNET)` or `unshare -n`. New namespaces start with only `lo`; all other interfaces must be explicitly added.

- **veth pair**: Two virtual Ethernet interfaces linked at the kernel level. A packet injected into one end (`vethXXX` in root ns) immediately emerges from the other end (`eth0` in pod ns), and vice versa. They are created together with `ip link add veth0 type veth peer name veth1`. Moving one end to a different namespace with `ip link set veth1 netns <pid>` establishes the link between the root ns and the pod ns.

- **Linux bridge**: A software Layer 2 switch (virtual switch) in the kernel. Learns MAC addresses from traffic, forwards frames to the correct port, handles ARP proxy, and can broadcast to all ports for unknown destinations. Kubernetes CNI plugins typically name the bridge `cni0` (Flannel) or `cbr0` (kubenet). The bridge IP (e.g., `10.244.0.1/24`) is the default gateway for all pods on the node and is the interface the host uses to reach pods.

- **iptables / Netfilter**: The kernel's packet filtering and NAT framework. Netfilter exposes five hooks in the packet path: `PREROUTING`, `INPUT`, `FORWARD`, `OUTPUT`, `POSTROUTING`. Two tables are critical for container networking: the `nat` table (DNAT for incoming packets via `PREROUTING`, SNAT/MASQUERADE for outgoing packets via `POSTROUTING`) and the `filter` table (FORWARD chain controls routing between interfaces, ACCEPT for pod-to-pod, DROP for policy enforcement). kube-proxy writes thousands of rules to the nat table to implement service ClusterIP → pod IP translation.

- **CNI spec**: A specification (currently v1.0) defining a protocol between the container runtime and a network plugin. The plugin is a stateless binary on disk (e.g., `/opt/cni/bin/bridge`, `/opt/cni/bin/calico`). The runtime executes it with three environment variables: `CNI_COMMAND` (ADD, DEL, CHECK, VERSION), `CNI_NETNS` (path to the pod's network namespace file), and `CNI_CONTAINERID`. Configuration is passed on stdin as JSON. The plugin must: for ADD, create the network interface in `CNI_NETNS`, assign an IP address, configure routes, and return the assigned IP on stdout. No state is stored by the spec itself; IPAM plugins manage IP address allocation separately.

- **CNI plugin chain**: A CNI configuration can invoke multiple plugins sequentially via `plugins[]`. The first plugin is typically the interface plugin (creates the veth and bridge), the second is the IPAM plugin (allocates the IP from a pool and writes it back to the interface plugin's result), and subsequent plugins add capabilities like bandwidth limiting (`bandwidth` plugin enforces tc-based rate limits) and port mapping (`portmap` plugin writes iptables DNAT rules for `hostPort` bindings). Each plugin receives the previous plugin's result and augments it.

- **Pod networking model (Kubernetes mandate)**: Three invariants every compliant CNI must uphold: (1) every pod has a unique IP that is routable within the cluster; (2) pods on any node can reach pods on any other node using those IPs without NAT; (3) agents on a node can reach all pods on that node. This model means applications do not need to discover or manage NAT mappings — the pod IP a service registers is the same IP clients use to connect. It eliminates port-conflict problems (two pods can both listen on port 8080 because they have distinct IPs) and enables identity-based security policies that use IP as a pod identifier.

- **Overlay networking (VXLAN/GENEVE)**: A tunneling approach where pod-to-pod traffic across nodes is encapsulated in UDP packets. VXLAN wraps the original Ethernet frame in a UDP/IP header with a 24-bit VNI (VXLAN Network Identifier). The outer IP destination is the remote node's IP. The encap/decap is done by the `vxlan0` (or `flannel.1`) interface, which is a kernel VXLAN tunnel endpoint (VTEP). Flannel in VXLAN mode uses this approach. Pros: works on any L3 network without BGP; node VMs do not need to know pod routes. Cons: 50-byte overhead per packet, additional CPU for encap/decap, MTU must account for the outer header (set `--mtu` to node MTU minus 50).

- **Underlay networking (BGP / VPC-native)**: Pod routes are distributed directly into the node's routing infrastructure. Calico uses BGP (`BIRD` daemon) to advertise each node's podCIDR as a BGP route to every other node or to a BGP route reflector. AWS VPC CNI allocates pod IPs from the VPC subnet's secondary IP space and programs them directly as VPC routes — pods have real VPC-addressable IPs, cloud load balancers can route directly to pods. Pros: no encap overhead, cloud-native integration. Cons: requires BGP capability on the network fabric or VPC awareness; scaling limits (VPC route table entries have limits per region).

- **eBPF and Cilium**: eBPF (extended Berkeley Packet Filter) is a kernel VM that allows user-space programs to load verified bytecode into kernel hooks without writing kernel modules. Cilium loads eBPF programs at TC (Traffic Control) ingress/egress hooks on each veth endpoint and at XDP (eXpress Data Path) on physical NICs. These programs implement L3/L4/L7 policy, service load balancing via `bpf_redirect_neigh()`, NAT, and connection tracking entirely in eBPF maps (hash maps, LPM prefix tries) — O(1) lookups per connection. Cilium in kube-proxy-replacement mode removes all iptables service rules and handles ClusterIP, NodePort, and LoadBalancer entirely in eBPF, reducing per-packet cost from microseconds (iptables traversal) to nanoseconds (BPF map lookup).

- **kube-proxy modes**: Three modes. `iptables` mode (default): kube-proxy watches Service and Endpoints objects and writes iptables DNAT rules; for N services with M backends each, this creates O(N*M) iptables rules; rule evaluation is O(N) per packet. `IPVS` mode: uses the kernel's IP Virtual Server (IPVS) subsystem, which uses hash tables for O(1) service lookup; supports multiple scheduling algorithms (round-robin, least connections, source hashing); requires the `ip_vs*` kernel modules. `eBPF` (Cilium kube-proxy-replacement): removes kube-proxy entirely; all service translation is handled by eBPF programs; lowest overhead, fastest update propagation, supports DSR (Direct Server Return) for NodePort traffic.

- **conntrack (Connection Tracking)**: The kernel module (`nf_conntrack`) that maintains a table of all active network connections. When iptables NAT translates a packet (DNAT for incoming, SNAT for outgoing), conntrack records the original 5-tuple and the translated 5-tuple so reverse traffic is translated back automatically without additional rule lookups. Conntrack table size is bounded (`/proc/sys/net/netfilter/nf_conntrack_max`); on nodes handling high connection rates (e.g., a node running many short-lived connections), conntrack table exhaustion causes new connections to fail with `nf_conntrack: table full, dropping packet`. Monitor with `conntrack -S`.

- **podCIDR allocation**: The Kubernetes controller-manager allocates a unique CIDR block per node from the cluster-level `--cluster-cidr`. The node's `spec.podCIDR` field stores its allocated block. CNI plugins read this to set up IP address pools (Flannel reads it from the Node object; host-local IPAM reads `/var/lib/cni/networks/` for what's already allocated). Default `--node-cidr-mask-size` is `/24` for IPv4 (254 usable IPs per node) but is configurable. CIDR math: a cluster CIDR of `10.244.0.0/16` with `/24` per node supports 256 nodes; scaling beyond that requires a larger cluster CIDR.

- **Pause container (infra container)**: Every pod has a pause container (image: `registry.k8s.io/pause:3.9`) that owns the pod's network namespace and Linux IPC namespace. It runs a process that does nothing except hold the namespace open. All other containers in the pod (`kubectl apply -f pod.yaml` containers) are started with `--network=container:<pause-id>` (or equivalent), joining the pause container's network namespace. This ensures the network namespace outlives any individual container restart — if the app container crashes and restarts, the eth0 interface and IP remain intact because the pause container is still running.

## Internals

### Packet Walk: Pod-to-Pod Same Node

Consider two pods on the same node: pod-a (`10.244.0.10`) and pod-b (`10.244.0.20`), both on node-1 with bridge `cni0` at `10.244.0.1/24`.

1. **Application sends packet**: The app in pod-a calls `connect()` or `sendto()` targeting `10.244.0.20:8080`. The kernel builds an IP packet: src `10.244.0.10`, dst `10.244.0.20`.

2. **Routing in pod netns**: The pod's network namespace has a single route: `default via 10.244.0.1 dev eth0` (the bridge IP). The destination `10.244.0.20` is in the same `/24` subnet as `eth0` (`10.244.0.10/24`), so the kernel resolves it directly without using the default gateway. It does an ARP lookup for `10.244.0.20` in its ARP table.

3. **ARP resolution**: pod-a sends an ARP request out `eth0` asking "who has `10.244.0.20`?" The veth forwards it to the bridge `cni0`. The bridge floods the ARP request to all attached veth endpoints. pod-b's veth receives it, pod-b's kernel replies with pod-b's MAC address. The bridge learns pod-b's MAC is reachable via pod-b's veth port. The ARP reply traverses back to pod-a's eth0. pod-a now has MAC and sends the Ethernet frame.

4. **Kernel forwards**: The Ethernet frame leaves pod-a's `eth0`, traverses the veth pair kernel buffer, and emerges on the host side (`vethXXX`). The bridge `cni0` receives it on pod-a's port, looks up the destination MAC in its forwarding table, and forwards the frame to pod-b's veth port (`vethYYY`). The frame crosses into pod-b's network namespace via its veth, arriving on pod-b's `eth0`. pod-b's kernel processes the IP packet, the application receives it via `accept()`/`recvfrom()`.

5. **iptables involvement**: For same-node pod-to-pod traffic that does NOT go through a Service VIP, iptables is typically bypassed or traverses only the FORWARD chain with a blanket ACCEPT rule for the pod subnet. No NAT occurs.

### Packet Walk: Pod-to-Pod Different Nodes (VXLAN)

pod-a (`10.244.0.10`) on node-1 sends to pod-c (`10.244.1.10`) on node-2. Flannel VXLAN mode.

1. **Routing decision on node-1**: Inside pod-a's netns, `10.244.1.10` is not on the local subnet (`10.244.0.0/24`). The default route sends the packet to `10.244.0.1` (the bridge). The packet reaches `cni0` on node-1.

2. **Host routing table on node-1**: node-1's kernel routing table has an entry installed by Flannel: `10.244.1.0/24 via 10.244.1.0 dev flannel.1 onlink`. The kernel routes the packet to `flannel.1`, which is a VXLAN tunnel endpoint (VTEP). Flannel's daemon populates an FDB (Forwarding Database) entry: VXLAN packets for VTEP `10.244.1.0` should be sent to node-2's real IP (e.g., `192.168.1.2`).

3. **VXLAN encapsulation**: The `flannel.1` VXLAN interface encapsulates the original IP packet: it wraps it in an Ethernet frame (src MAC: flannel.1's MAC on node-1, dst MAC: flannel.1's MAC on node-2, from FDB), then in a VXLAN header (VNI = 1), then in a UDP packet (dst port 8472), then in an outer IP header (src `192.168.1.1` node-1, dst `192.168.1.2` node-2). The encapsulated packet is injected into the host's root network namespace and routed via the node's physical NIC.

4. **Transit across cloud network**: The outer IP packet traverses the VPC/datacenter network from node-1 to node-2 using the real node IPs. The cloud network has no knowledge of pod routes.

5. **VXLAN decapsulation on node-2**: node-2's kernel receives the UDP packet on port 8472. The `flannel.1` VXLAN driver recognizes it by VNI and port, strips the VXLAN/UDP/IP headers, and delivers the original IP packet (src `10.244.0.10`, dst `10.244.1.10`) to the kernel's routing stack.

6. **Local delivery on node-2**: node-2's routing table has `10.244.1.0/24 dev cni0`. The packet is forwarded to `cni0` bridge, then to pod-c's veth pair, and arrives at pod-c's `eth0`. pod-c's application receives the packet. The entire path appears to pod-c as a direct IP packet from pod-a with no NAT.

### Service Packet Path: ClusterIP DNAT and Hairpin NAT

A pod connects to a Service ClusterIP (e.g., `10.96.0.100:80`), which has two backing pod endpoints (`10.244.0.20:8080`, `10.244.1.20:8080`).

1. **Packet leaves pod**: src `10.244.0.10`, dst `10.96.0.100:80`. The ClusterIP `10.96.0.100` is not a real IP on any interface — it lives only in iptables rules.

2. **PREROUTING nat table (kube-proxy iptables rules)**: The packet hits the `PREROUTING` chain. kube-proxy has written rules: `KUBE-SERVICES` chain → match dst `10.96.0.100:80` → jump `KUBE-SVC-XXXXXX` chain. `KUBE-SVC-XXXXXX` randomly selects one endpoint using iptables statistic extension (`--probability 0.5`). The chosen endpoint is `10.244.0.20:8080`. iptables writes a DNAT rule: rewrite dst from `10.96.0.100:80` to `10.244.0.20:8080`. Conntrack records the translation.

3. **Post-DNAT routing**: The packet now has dst `10.244.0.20`. If the selected pod is on the same node, the kernel routes it through `cni0`. If the selected pod is remote, it follows the cross-node path.

4. **MASQUERADE for hairpin**: If pod-a (`10.244.0.10`) connects to a Service, and the DNAT selects pod-b on the same node (`10.244.0.20`), the src remains `10.244.0.10`. pod-b sends its reply back to `10.244.0.10` directly (same subnet), bypassing the bridge's NAT rules — the reply never traverses the POSTROUTING chain where conntrack would de-NAT it. This is the "hairpin" problem. kube-proxy mitigates this with a `MASQUERADE` rule in the KUBE-MARK-MASQ chain: packets destined for a pod endpoint from the same node are SNAT'd to the bridge IP (`10.244.0.1`) so the reply path goes back through the bridge and conntrack de-NAT applies correctly.

5. **Response path**: pod-b replies to `10.244.0.1` (the MASQUERADE'd source). The packet arrives at `cni0`, the conntrack table maps it back to the original connection (`src: 10.244.0.10, dst: 10.96.0.100`), and the packet is delivered to pod-a appearing to come from the Service VIP.

## Architecture Diagram

```
NODE 1                                          NODE 2
+---------------------------------------------------+   +---------------------------------------------------+
|                                                   |   |                                                   |
|  pod-a (netns-a)          pod-b (netns-b)        |   |  pod-c (netns-c)                                 |
|  +------------------+     +------------------+   |   |  +------------------+                            |
|  | eth0             |     | eth0             |   |   |  | eth0             |                            |
|  | 10.244.0.10/24   |     | 10.244.0.20/24   |   |   |  | 10.244.1.10/24   |                            |
|  | gw: 10.244.0.1   |     | gw: 10.244.0.1   |   |   |  | gw: 10.244.1.1   |                            |
|  +--------+---------+     +--------+---------+   |   |  +--------+---------+                            |
|           |  veth pair              |  veth pair  |   |           |  veth pair                           |
|      vethA0|                   vethB0|             |   |      vethC0|                                    |
|           |                         |             |   |           |                                      |
|  +--------+-----------+-------------+---------+   |   |  +--------+------------------------------+      |
|  |                 cni0 (bridge)                |  |   |  |                cni0 (bridge)          |      |
|  |            10.244.0.1/24                     |  |   |  |           10.244.1.1/24               |      |
|  +------------------------------+---------------+  |   |  +--------------+------------------------+      |
|                                 |                  |   |                 |                               |
|                         flannel.1 (VTEP)           |   |         flannel.1 (VTEP)                        |
|                         VXLAN encap/decap          |   |         VXLAN encap/decap                       |
|                                 |                  |   |                 |                               |
|               eth0 (192.168.1.1)|                  |   |                 |eth0 (192.168.1.2)             |
+-------------------------------+-+------------------+   +--+--------------+-------------------------------+
                                |                            |
                                |    UDP/8472 VXLAN          |
                                +----------------------------+
                                   (outer IP: node1→node2)

iptables (kube-proxy) on each node:
  nat/PREROUTING: ClusterIP DNAT → endpoint IP
  nat/POSTROUTING: MASQUERADE for same-node hairpin
  filter/FORWARD: ACCEPT for podCIDR traffic
```

## Failure Modes & Debugging

### 1. CNI Plugin Binary Missing — Pod Stuck in ContainerCreating

**Symptoms**: New pod is scheduled to a node and immediately enters `ContainerCreating`. It never transitions to Running. `kubectl describe pod <name>` shows an event: `networkPlugin cni failed to set up pod "<pod>" network: failed to find plugin "calico" in path [/opt/cni/bin]` or `unable to connect to CNI plugin: dial unix /var/run/calico/cni.sock: no such file or directory`. The pod's `.status.containerStatuses` is empty. Other pods on the same node may also be stuck.

**Root Cause**: The CNI plugin binary is missing from `/opt/cni/bin/` or the CNI daemon (Calico node, Flannel DaemonSet) is not running on that node and has not installed its binary. This happens after node replacement when the DaemonSet pod fails to start (image pull failure, insufficient resources, taint not tolerated), or when a node is added before the CNI DaemonSet has rolled out.

**Blast Radius**: All new pod scheduling to the affected node fails. Existing running pods are unaffected — their network namespaces are already configured and the kernel maintains them without the CNI binary. Node-level: complete scheduling blackout until resolved.

**Mitigation**: Ensure the CNI DaemonSet tolerates all taints (including `node.kubernetes.io/not-ready`), has a high priority class, and has its `PodDisruptionBudget` set to `minAvailable: 0` so rolling node upgrades don't block. Use `preferredDuringSchedulingIgnoredDuringExecution` anti-affinity to spread CNI pods. Alert on CNI DaemonSet rollout failures.

**Debugging**:
```bash
# Check which pods are stuck and on which node
kubectl get pods -A --field-selector=status.phase=Pending -o wide

# Describe the stuck pod for the CNI error event
kubectl describe pod <stuck-pod> -n <ns>

# Check CNI DaemonSet status on the problem node
kubectl get pods -n kube-system -l k8s-app=flannel -o wide | grep <node-name>
kubectl get pods -n kube-system -l k8s-app=calico-node -o wide | grep <node-name>

# SSH to the node and verify CNI binary presence
ls -la /opt/cni/bin/
ls -la /etc/cni/net.d/

# Check CNI daemon logs on the node
kubectl logs -n kube-system <flannel-pod-on-node>
kubectl logs -n kube-system <calico-node-pod-on-node>

# Check kubelet logs for CNI errors
journalctl -u kubelet --since "5 minutes ago" | grep -i cni
```

---

### 2. Node-Level podCIDR Exhaustion

**Symptoms**: New pods scheduled to a node stay in `ContainerCreating` with event `IPAM: failed to allocate for range 0: no IP addresses available in range set: 10.244.5.0/24`. Existing pods on the node run fine. `kubectl get node <name> -o yaml` shows `spec.podCIDR: 10.244.5.0/24`. `ip addr show cni0` on the node shows ~254 routes in the routing table. The node eventually becomes unschedulable for new pods.

**Root Cause**: The default podCIDR mask is `/24` (254 usable IPs per node). If a node runs more than ~250 pods (counting completed/failed pods whose IP may not yet be released, or system pods counting against the limit), IPAM runs out of IPs. This also happens when pods are deleted but the CNI IPAM state file (`/var/lib/cni/networks/<net-name>/`) is not cleaned up (stale allocations after a node crash). The host-local IPAM plugin stores one file per allocated IP; if the pod's DEL CNI call was never executed (crash, bug), the IP remains "allocated."

**Blast Radius**: New pod scheduling to the affected node fails. Node eventually accumulates `Failed` pods that exhaust IPs. Kubernetes scheduler health checks may cordon the node if pod failures exceed limits.

**Mitigation**: Set `--max-pods` on kubelet to stay below podCIDR size (default is 110; `/24` supports 254; use `/23` if running more than 110 pods per node). For AWS VPC CNI, each ENI has a fixed number of secondary IPs — tune `WARM_IP_TARGET` and `MINIMUM_IP_TARGET` to pre-allocate without waste. Alert on `kubelet_running_pods / kube_node_status_capacity_pods > 0.8`.

**Debugging**:
```bash
# Check current pod count per node vs capacity
kubectl get nodes -o custom-columns='NAME:.metadata.name,PODS:.status.allocatable.pods'
kubectl get pods -A -o wide | awk '{print $8}' | sort | uniq -c | sort -rn

# SSH to the node and inspect IPAM state
ls /var/lib/cni/networks/cbr0/     # Flannel/kubenet
ls /var/lib/cni/networks/k8s-pod-network/  # Calico

# Count allocated IPs
ls /var/lib/cni/networks/cbr0/ | grep -v 'last_reserved_ip\|lock' | wc -l

# Check for stale allocations (IPs held by non-existent pods)
# List running pod IPs on the node
kubectl get pods -A --field-selector=spec.nodeName=<node> -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}' | sort

# Compare with IPAM state - stale IPs are in IPAM but not in kubectl output
ls /var/lib/cni/networks/cbr0/ | grep -v 'last_reserved_ip\|lock' | sort

# Remove stale allocations (CAUTION: verify the IP is not in use first)
rm /var/lib/cni/networks/cbr0/10.244.5.23  # only if confirmed stale
```

---

### 3. ARP Flooding on Large L2 Node Networks

**Symptoms**: Network performance degrades as cluster grows past ~500 nodes. Physical switch CPU spikes. tcpdump on node NICs shows continuous ARP request bursts. Pod-to-pod latency increases cluster-wide. Cloud provider logs show "ARP storm" or VPC route table thrashing. The problem worsens as more pods are created.

**Root Cause**: In overlay-less L2 networks (or underlay BGP networks where pod IPs are native L3 but nodes share an L2 segment), as pod count grows, ARP table sizes on nodes and physical switches grow. Each new connection from pod-a to pod-b on a different node requires ARP resolution for the destination. With thousands of pods moving frequently (scaling events, pod churn), ARP cache entries expire and must be refreshed. On a shared L2 segment with 500 nodes, every ARP request is broadcast to all 500 nodes. At high pod churn rates, the sustained ARP broadcast traffic overwhelms switch CPU and saturates NIC interrupt queues. This is the primary scaling limit for flat L2 cluster networks beyond ~300 nodes.

**Blast Radius**: Network-wide performance degradation. Affects all pods, not just high-churn workloads. Switch CPU exhaustion can cause L2 forwarding delays that cascade into node-to-node connectivity issues, triggering Kubernetes node NotReady events.

**Mitigation**: Use overlay (VXLAN/GENEVE) mode to encapsulate pod traffic — the outer IP headers use node IPs, and node ARP table sizes are bounded by node count, not pod count. Enable ARP proxy on the bridge (`bridge-nf-call-iptables` and `proxy_arp` kernel params). For Calico, use BGP with `globalNetworkPolicy` to limit which nodes exchange pod routes directly. For AWS, use VPC CNI in prefix delegation mode to reduce the number of ENI IP allocations visible to the VPC ARP layer.

**Debugging**:
```bash
# Check ARP table size on a node
arp -n | wc -l
ip neigh show | wc -l
cat /proc/sys/net/ipv4/neigh/default/gc_thresh3  # ARP table size limit

# Watch ARP flood with tcpdump
tcpdump -i eth0 arp -c 100  # count ARP packets in 100-packet window

# Check bridge ARP/FDB table on the node
bridge fdb show
bridge fdb show | wc -l

# Monitor ARP table pressure via /proc/net/arp
wc -l /proc/net/arp

# Check if ARP cache is full (kernel drops entries when gc_thresh3 is reached)
dmesg | grep "neighbor table overflow"
# Or via kernel metrics
cat /proc/net/stat/arp_cache

# On Calico: check BGP peer status (BGP carries routes, reducing ARP need)
calicoctl node status
calicoctl get bgpPeers
```

---

### 4. eBPF/iptables Conflict — Cilium + kube-proxy Running Simultaneously

**Symptoms**: After installing Cilium with `kube-proxy-replacement: true`, some services are intermittently unreachable. `kubectl get pods -A` shows kube-proxy DaemonSet still running (not removed). Some ClusterIP connections succeed, others fail. `curl` to a ClusterIP hangs. Services with multiple endpoints show non-deterministic load balancing — some requests go to the right pod, others hit stale endpoints. `conntrack -L` shows duplicate entries with conflicting NAT mappings.

**Root Cause**: kube-proxy and Cilium eBPF programs both manage packet NAT and service translation for the same ClusterIPs, but via different mechanisms with no coordination. iptables rules (kube-proxy) run in the `PREROUTING` Netfilter hook. Cilium eBPF programs run at TC ingress/egress hooks on the veth interface, which executes before Netfilter. A packet entering a pod's veth is NAT'd by Cilium's eBPF program (src/dst rewrite), but the conntrack entry it creates is in the eBPF conntrack map, not the kernel conntrack table. When the reply comes back, if kube-proxy's Netfilter rules intercept it first and find no matching conntrack entry (because Cilium used its own tracking), they either drop it or forward incorrectly. The result is inconsistent connection behavior.

**Blast Radius**: All service traffic is potentially affected. Impact is proportional to which packets hit eBPF first vs iptables first, which varies by packet path (local vs cross-node). Production impact: intermittent service failures that are impossible to reproduce deterministically.

**Mitigation**: The fix is exclusive: either remove kube-proxy (`kubectl delete ds kube-proxy -n kube-system`) and install Cilium with `--set kubeProxyReplacement=true`, or run Cilium in compatibility mode (`--set kubeProxyReplacement=false`) and keep kube-proxy. Never run both in full service-management mode simultaneously. After removing kube-proxy, flush the old iptables rules with `iptables-save | grep -v KUBE | iptables-restore` or reboot the nodes to reset the iptables state.

**Debugging**:
```bash
# Verify kube-proxy is still running
kubectl get ds kube-proxy -n kube-system -o wide

# Check Cilium kube-proxy replacement status
kubectl exec -n kube-system ds/cilium -- cilium status | grep "KubeProxyReplacement"

# List iptables KUBE-* rules left by kube-proxy
iptables-save | grep -c KUBE
iptables -t nat -L -n --line-numbers | grep KUBE-SVC | head -20

# Check Cilium's service map
kubectl exec -n kube-system ds/cilium -- cilium service list

# Look for conntrack conflicts
conntrack -L -p tcp --dport 80 2>/dev/null | head -20

# Check Cilium eBPF policy/NAT maps
kubectl exec -n kube-system ds/cilium -- cilium bpf nat list | head -20

# Compare: does Cilium's service list match kube-proxy's iptables rules?
# Count services in each
kubectl exec -n kube-system ds/cilium -- cilium service list | wc -l
iptables -t nat -L KUBE-SERVICES --line-numbers | wc -l
```

## Cross-Reference

- **Week-00 topic 02** (cgroups and namespaces): Network namespaces are one of the seven Linux namespace types; topic 02 covers `clone(CLONE_NEWNET)` and `unshare` in depth.
- **Week-00 topic 05** (cloud networking and VPC): The CIDR math for podCIDR allocation and VPC-native mode CNI (AWS VPC CNI, GKE native mode) is covered there, including IP exhaustion diagnosis and subnet design.
- **Week-03 topic 01** (Envoy architecture): Istio's sidecar injection uses iptables REDIRECT rules inside the pod's network namespace to intercept traffic into Envoy. Understanding how the pod netns is wired (this topic) is prerequisite for understanding why `istio-init` container modifies iptables inside the pod namespace rather than at the node level.
