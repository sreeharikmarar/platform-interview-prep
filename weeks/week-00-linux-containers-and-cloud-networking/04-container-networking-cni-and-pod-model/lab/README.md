# Lab: Container Networking, CNI & the Pod Network Model

This lab manually recreates what a CNI plugin does when it wires a pod into the cluster network: creating network namespaces, building veth pairs, connecting them through a Linux bridge, configuring IP addresses and routes, adding iptables NAT rules, and testing connectivity. You will understand the exact kernel operations that occur between "pod scheduled" and "container starts" in every Kubernetes cluster.

## Prerequisites

- Linux host with root access (a VM or a node in a local cluster works; macOS requires a Linux VM because these primitives are Linux-only)
- Packages: `iproute2`, `iptables`, `iputils-ping` (usually pre-installed on any modern Linux distribution)
- No Kubernetes cluster required — this lab runs entirely on Linux network primitives
- Optional: the helper script `lab/veth-bridge-demo.sh` automates all steps and can serve as a reference

## Learning Objectives

After completing this lab you will be able to:
- Create and inspect Linux network namespaces using `ip netns`
- Build a veth pair and understand the kernel buffer relationship between its two ends
- Attach veth ends to a Linux bridge and observe MAC learning
- Trace why ARP resolution works across namespaces through the bridge
- Add iptables MASQUERADE rules that enable pods to reach external IPs
- Explain exactly what the CNI bridge plugin does and in what order

---

## Step 1: Verify your environment

```bash
# Confirm you are root (or have sudo)
whoami

# Verify required tools are available
ip link help 2>&1 | head -1
iptables --version
ping -c1 127.0.0.1 > /dev/null && echo "ping OK"

# Check that no conflicting namespaces from a previous run exist
ip netns list
```

**What's happening**: `ip netns` manages the `/var/run/netns/` directory. Each named network namespace is a bind-mounted file in that directory. Listing it shows you all persistent network namespaces on the host.

**Verification**: `ip netns list` should return nothing (or only entries unrelated to this lab). If you see `ns-pod-a` or `ns-pod-b`, run the cleanup section first.

---

## Step 2: Create two network namespaces (simulating two pods)

```bash
# Create namespace for "pod-a"
sudo ip netns add ns-pod-a

# Create namespace for "pod-b"
sudo ip netns add ns-pod-b

# Confirm they exist
ip netns list
# Expected output:
# ns-pod-b
# ns-pod-a
```

**What's happening**: `ip netns add` creates a new network namespace and bind-mounts it at `/var/run/netns/<name>`. The new namespace contains only a loopback interface (`lo`) in DOWN state. It has its own routing table (empty), its own iptables tables (default policy ACCEPT, no rules), and its own ARP table (empty). The host's network stack is completely isolated from these namespaces until you create veth pairs.

**Verification**:
```bash
# Inspect what interfaces exist inside ns-pod-a
sudo ip netns exec ns-pod-a ip link show
# Expected: only "lo" in DOWN state

# The namespace has an empty routing table
sudo ip netns exec ns-pod-a ip route show
# Expected: no output
```

---

## Step 3: Create the Linux bridge (simulating cni0)

```bash
# Create a Linux bridge named "cni0" in the root network namespace
sudo ip link add cni0 type bridge

# Assign an IP address (this will be the default gateway for both pods)
sudo ip addr add 10.244.0.1/24 dev cni0

# Bring the bridge up
sudo ip link set cni0 up

# Verify
ip link show cni0
ip addr show cni0
```

**What's happening**: A Linux bridge is a software Layer 2 switch. When created, it has no ports (slave interfaces) and no MAC entries in its forwarding table. It performs MAC learning: the first time it sees a frame from a MAC address on one of its ports, it records `MAC → port` in the FDB (Forwarding Database). Subsequent frames to that MAC are sent only to the known port rather than flooded to all ports. The IP address `10.244.0.1/24` on the bridge will act as the default gateway for both pod namespaces — analogous to the `cni0` bridge IP in Flannel or the `cbr0` IP in kubenet.

**Verification**:
```bash
ip link show cni0
# Should show: cni0: <BROADCAST,MULTICAST,UP,LOWER_UP> ...

ip addr show cni0
# Should show: inet 10.244.0.1/24

# Show the empty MAC forwarding table
bridge fdb show dev cni0
```

---

## Step 4: Create veth pairs and connect pods to the bridge

```bash
# Create veth pair for pod-a: one end is "veth-pod-a" (host), other is "eth0" (pod)
sudo ip link add veth-pod-a type veth peer name eth0

# Move the "eth0" end into ns-pod-a's namespace
# After this, "eth0" disappears from the root ns and appears only inside ns-pod-a
sudo ip link set eth0 netns ns-pod-a

# Attach the host-side end to the bridge
sudo ip link set veth-pod-a master cni0

# Bring up the host-side veth
sudo ip link set veth-pod-a up

# Assign IP to eth0 inside pod-a's namespace
sudo ip netns exec ns-pod-a ip addr add 10.244.0.10/24 dev eth0

# Bring up eth0 and loopback inside pod-a
sudo ip netns exec ns-pod-a ip link set eth0 up
sudo ip netns exec ns-pod-a ip link set lo up

# Add the default route inside pod-a pointing to the bridge IP
sudo ip netns exec ns-pod-a ip route add default via 10.244.0.1 dev eth0
```

```bash
# Repeat for pod-b
sudo ip link add veth-pod-b type veth peer name eth0

sudo ip link set eth0 netns ns-pod-b

sudo ip link set veth-pod-b master cni0
sudo ip link set veth-pod-b up

sudo ip netns exec ns-pod-b ip addr add 10.244.0.20/24 dev eth0
sudo ip netns exec ns-pod-b ip link set eth0 up
sudo ip netns exec ns-pod-b ip link set lo up
sudo ip netns exec ns-pod-b ip route add default via 10.244.0.1 dev eth0
```

**What's happening**: Each `ip link set eth0 netns ns-pod-X` call moves the veth interface across namespace boundaries. After the move, the file descriptor that pointed to `eth0` in the root ns is gone from root ns — the interface lives exclusively in `ns-pod-X`. This is the same operation the CNI bridge plugin performs when it calls `netlink.LinkSetNsFd()`. The host-side veth (`veth-pod-a`, `veth-pod-b`) remains in the root ns and is enslaved to `cni0`, making it a port on the bridge.

**Verification**:
```bash
# Confirm interfaces inside each pod namespace
sudo ip netns exec ns-pod-a ip addr show
# Should show: lo (127.0.0.1/8) and eth0 (10.244.0.10/24)

sudo ip netns exec ns-pod-b ip addr show
# Should show: lo (127.0.0.1/8) and eth0 (10.244.0.20/24)

# Confirm both veth ends are enslaved to the bridge
bridge link show cni0
# Should show: veth-pod-a and veth-pod-b listed under cni0

# Confirm the routing table inside pod-a
sudo ip netns exec ns-pod-a ip route show
# Expected:
# default via 10.244.0.1 dev eth0
# 10.244.0.0/24 dev eth0 proto kernel scope link src 10.244.0.10
```

---

## Step 5: Test pod-to-pod connectivity (same node path)

```bash
# Ping from pod-a to pod-b
sudo ip netns exec ns-pod-a ping -c 3 10.244.0.20
```

**What's happening**: The packet from `ns-pod-a` is addressed to `10.244.0.20`, which is in the same /24 subnet as `eth0`. The kernel in `ns-pod-a` does an ARP request for `10.244.0.20`, sending it out `eth0`. The packet crosses the veth pair to `veth-pod-a` in the root ns. `cni0` receives it and floods the ARP request to all bridge ports (veth-pod-b and the bridge IP itself). `ns-pod-b`'s `eth0` receives the ARP request, the kernel replies with pod-b's MAC. `cni0` learns pod-b's MAC is reachable via `veth-pod-b`. The bridge forwards the reply to `veth-pod-a`. `ns-pod-a` now has pod-b's MAC in its ARP cache and sends the ICMP echo as an Ethernet frame directly to pod-b's MAC.

**Verification**:
```bash
# Expected: 3 packets transmitted, 3 received, 0% packet loss

# Also ping the bridge (gateway) from pod-a
sudo ip netns exec ns-pod-a ping -c 2 10.244.0.1

# Check the ARP cache inside pod-a — it should have entries now
sudo ip netns exec ns-pod-a ip neigh show
# Expected: 10.244.0.1 dev eth0 lladdr <mac> REACHABLE
#           10.244.0.20 dev eth0 lladdr <mac> REACHABLE

# Check the bridge MAC forwarding table — it has learned both pod MACs
bridge fdb show dev cni0
```

---

## Step 6: Enable external connectivity with iptables MASQUERADE

Without NAT, packets from pods to external IPs will leave the host with a source IP of `10.244.0.X`, which is not routable on the internet or VPC — replies will never arrive back.

```bash
# Enable IP forwarding on the host (required for routing between interfaces)
sudo sysctl -w net.ipv4.ip_forward=1

# Add a MASQUERADE rule: any traffic from the pod subnet leaving the host
# gets its source IP rewritten to the host's outbound interface IP
sudo iptables -t nat -A POSTROUTING -s 10.244.0.0/24 ! -o cni0 -j MASQUERADE

# Also enable forwarding for traffic passing through the bridge
sudo iptables -A FORWARD -i cni0 -j ACCEPT
sudo iptables -A FORWARD -o cni0 -j ACCEPT
```

**What's happening**: MASQUERADE is a form of SNAT where the replacement source IP is dynamically chosen to match the outgoing interface's IP (useful when the host IP is not static, e.g., cloud instances). When pod-a (`10.244.0.10`) sends a packet to `8.8.8.8`, the packet reaches the host root ns via the veth, gets routed to the physical NIC, and at POSTROUTING iptables rewrites the source to the host's physical IP. The remote server replies to the host IP, the kernel's conntrack table maps the reply back to the original `10.244.0.10`, and delivers it back to pod-a via the bridge. The `! -o cni0` condition ensures the rule does not apply to pod-to-pod traffic going through the bridge (which should be unmasqueraded).

**Verification**:
```bash
# Confirm ip_forward is enabled
cat /proc/sys/net/ipv4/ip_forward
# Expected: 1

# Check the iptables rules were added
iptables -t nat -L POSTROUTING -n -v | grep MASQ
# Expected: MASQUERADE line matching src 10.244.0.0/24

iptables -L FORWARD -n -v | grep cni0
# Expected: two ACCEPT lines referencing cni0

# Test external connectivity from pod-a (requires internet access on the host)
sudo ip netns exec ns-pod-a ping -c 2 8.8.8.8
# If the host has no internet access, ping the host's default gateway instead:
# GW=$(ip route show default | awk '/default/ {print $3}')
# sudo ip netns exec ns-pod-a ping -c 2 $GW
```

---

## Step 7: Inspect conntrack entries

```bash
# Install conntrack-tools if not present
# apt-get install -y conntrack   OR   yum install -y conntrack-tools

# Watch conntrack table during a ping from pod-a to pod-b
sudo conntrack -L -p icmp 2>/dev/null | grep 10.244

# Or start a watch in the background, then run ping
sudo conntrack -E &
CONNTRACK_PID=$!
sudo ip netns exec ns-pod-a ping -c 3 8.8.8.8
sleep 2
kill $CONNTRACK_PID 2>/dev/null

# List conntrack entries for the pod subnet
sudo conntrack -L --src 10.244.0.0/24 2>/dev/null | head -20
```

**What's happening**: The `conntrack` module tracks every stateful connection. For the MASQUERADE rule to reverse-translate replies correctly, conntrack must record the original 5-tuple (src pod IP, sport, dst, dport, protocol) and the translated 5-tuple (src host IP, sport, dst, dport, protocol). The `conntrack -L` output shows these pairs. For pod-to-pod traffic (no NAT), conntrack still tracks the connection for stateful FORWARD filtering but no address rewrite occurs.

---

## Step 8: Simulate a CNI DEL — clean teardown

```bash
# In a real CNI DEL call, the plugin removes the veth and releases the IP.
# Here we do it manually:

# Remove pod-a's veth from the bridge (the pod-side eth0 disappears with it)
sudo ip link delete veth-pod-a
# Deleting one end of a veth pair automatically deletes the other end.
# eth0 inside ns-pod-a is now gone.

# Verify: pod-a's namespace has no eth0
sudo ip netns exec ns-pod-a ip link show
# Expected: only lo remains (DOWN)

# Remove pod-b's veth
sudo ip link delete veth-pod-b

# Confirm pod-b namespace has no eth0
sudo ip netns exec ns-pod-b ip link show
# Expected: only lo remains (DOWN)
```

**What's happening**: When a veth pair is deleted, both ends are removed atomically. If the pod container is still running (in a real cluster), the application would immediately get `ENODEV` on any attempt to use `eth0`. kubelet triggers the CNI DEL call before stopping the pause container, so in practice `eth0` disappears before the application process exits.

---

## Cleanup

```bash
# Remove the network namespaces
sudo ip netns delete ns-pod-a
sudo ip netns delete ns-pod-b

# Remove the bridge
sudo ip link set cni0 down
sudo ip link delete cni0

# Remove the iptables rules added in step 6
sudo iptables -t nat -D POSTROUTING -s 10.244.0.0/24 ! -o cni0 -j MASQUERADE
sudo iptables -D FORWARD -i cni0 -j ACCEPT
sudo iptables -D FORWARD -o cni0 -j ACCEPT

# Verify cleanup
ip netns list
ip link show cni0 2>&1  # should say "Device cni0 does not exist"
iptables -t nat -L POSTROUTING -n | grep MASQ  # should be empty
```

---

## Key Takeaways

1. **A pod's network namespace is an isolated kernel network stack**. It has its own routing table, ARP table, and iptables rules. Changes inside it do not affect the host or other pods.

2. **A veth pair is a kernel-level virtual cable**. Moving one end into a network namespace is how the CNI plugin creates `eth0` inside the pod — there is no userspace copying; the kernel handles the packet transfer between both ends directly in the ring buffer.

3. **The Linux bridge is the on-node switching fabric**. It performs MAC learning and L2 forwarding between all pod veth endpoints on the node. The bridge IP is the default gateway for all pods on the node.

4. **iptables MASQUERADE enables external egress without requiring routable pod IPs**. This is how overlay-mode CNI plugins (Flannel VXLAN) allow pods to reach the internet — pod packets are SNAT'd to the node IP at the node boundary.

5. **CNI plugins are stateless binaries that perform exactly these steps**. Every call to `ip link set eth0 netns`, `ip addr add`, `ip route add`, and `iptables -A` in this lab corresponds to a `netlink` syscall inside the CNI binary. The CNI spec is just a convention for how the container runtime invokes that binary.

6. **Deleting one end of a veth deletes both ends**. This is why CNI DEL is a clean operation — the plugin only needs to `ip link delete veth-pod-X` in the root ns, and the pod-side `eth0` disappears automatically regardless of the namespace state.
