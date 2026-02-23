#!/bin/bash
#
# veth-bridge-demo.sh
#
# Simulates what a CNI bridge plugin does when wiring two pods into the cluster network:
#   1. Creates two network namespaces (ns-pod-a, ns-pod-b)
#   2. Creates a Linux bridge (cni0) with a gateway IP
#   3. Creates veth pairs and connects each to the bridge and to a pod namespace
#   4. Assigns IPs and default routes inside each pod namespace
#   5. Adds iptables rules for external egress (MASQUERADE)
#   6. Tests pod-to-pod connectivity and external egress
#   7. Cleans up all created resources
#
# Usage:
#   sudo ./veth-bridge-demo.sh            # Run full demo (setup + test + teardown)
#   sudo ./veth-bridge-demo.sh setup      # Setup only (leaves resources for manual inspection)
#   sudo ./veth-bridge-demo.sh teardown   # Teardown only (clean up a previous setup)
#
# Requirements:
#   - Linux host with root access
#   - iproute2, iptables, iputils-ping installed
#
# These namespaces and addresses are used:
#   ns-pod-a  10.244.0.10/24
#   ns-pod-b  10.244.0.20/24
#   cni0 bridge  10.244.0.1/24  (default gateway for both pods)

set -euo pipefail

# --- Configuration -----------------------------------------------------------
NS_POD_A="ns-pod-a"
NS_POD_B="ns-pod-b"
BRIDGE_NAME="cni0"
BRIDGE_IP="10.244.0.1"
POD_CIDR="10.244.0.0/24"
IP_POD_A="10.244.0.10"
IP_POD_B="10.244.0.20"
PREFIX_LEN="24"
VETH_HOST_A="veth-pod-a"
VETH_HOST_B="veth-pod-b"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Helpers -----------------------------------------------------------------

log_step() {
    echo -e "\n${BLUE}==> $1${NC}"
}

log_ok() {
    echo -e "  ${GREEN}[OK]${NC} $1"
}

log_warn() {
    echo -e "  ${YELLOW}[WARN]${NC} $1"
}

log_fail() {
    echo -e "  ${RED}[FAIL]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "This script must be run as root (or with sudo)."
        exit 1
    fi
}

check_dependencies() {
    local missing=0
    for cmd in ip iptables ping; do
        if ! command -v "$cmd" &>/dev/null; then
            log_fail "Required command not found: $cmd"
            missing=1
        fi
    done
    if [[ $missing -ne 0 ]]; then
        echo "Install missing packages and re-run."
        exit 1
    fi
}

# Returns 0 if the network namespace exists, 1 otherwise
ns_exists() {
    ip netns list 2>/dev/null | grep -q "^${1}\b"
}

# Returns 0 if the link exists in the root namespace, 1 otherwise
link_exists() {
    ip link show "$1" &>/dev/null
}

# --- Teardown ----------------------------------------------------------------
# Idempotent: safe to run even if resources do not exist.

teardown() {
    log_step "Teardown: removing all lab resources"

    # Remove network namespaces (this also removes any veth ends inside them)
    if ns_exists "$NS_POD_A"; then
        ip netns delete "$NS_POD_A"
        log_ok "Deleted namespace $NS_POD_A"
    else
        log_warn "Namespace $NS_POD_A does not exist — skipping"
    fi

    if ns_exists "$NS_POD_B"; then
        ip netns delete "$NS_POD_B"
        log_ok "Deleted namespace $NS_POD_B"
    else
        log_warn "Namespace $NS_POD_B does not exist — skipping"
    fi

    # Remove host-side veth ends (may already be gone if ns was deleted)
    if link_exists "$VETH_HOST_A"; then
        ip link delete "$VETH_HOST_A"
        log_ok "Deleted veth $VETH_HOST_A"
    fi

    if link_exists "$VETH_HOST_B"; then
        ip link delete "$VETH_HOST_B"
        log_ok "Deleted veth $VETH_HOST_B"
    fi

    # Remove the bridge
    if link_exists "$BRIDGE_NAME"; then
        ip link set "$BRIDGE_NAME" down
        ip link delete "$BRIDGE_NAME"
        log_ok "Deleted bridge $BRIDGE_NAME"
    else
        log_warn "Bridge $BRIDGE_NAME does not exist — skipping"
    fi

    # Remove iptables rules (use -D; errors are suppressed if rule doesn't exist)
    iptables -t nat -D POSTROUTING -s "${POD_CIDR}" ! -o "${BRIDGE_NAME}" -j MASQUERADE 2>/dev/null \
        && log_ok "Removed MASQUERADE rule from POSTROUTING" \
        || log_warn "MASQUERADE rule was not present — skipping"

    iptables -D FORWARD -i "${BRIDGE_NAME}" -j ACCEPT 2>/dev/null \
        && log_ok "Removed FORWARD ACCEPT rule (ingress cni0)" \
        || true

    iptables -D FORWARD -o "${BRIDGE_NAME}" -j ACCEPT 2>/dev/null \
        && log_ok "Removed FORWARD ACCEPT rule (egress cni0)" \
        || true

    echo ""
    log_ok "Teardown complete. Run 'ip netns list' and 'ip link show' to confirm."
}

# --- Setup -------------------------------------------------------------------

setup() {
    log_step "Step 1: Creating network namespaces (simulating pod network namespaces)"

    if ns_exists "$NS_POD_A"; then
        log_warn "Namespace $NS_POD_A already exists — skipping creation"
    else
        ip netns add "$NS_POD_A"
        log_ok "Created namespace $NS_POD_A"
    fi

    if ns_exists "$NS_POD_B"; then
        log_warn "Namespace $NS_POD_B already exists — skipping creation"
    else
        ip netns add "$NS_POD_B"
        log_ok "Created namespace $NS_POD_B"
    fi

    # Bring up loopback inside each namespace (required for localhost connectivity)
    ip netns exec "$NS_POD_A" ip link set lo up
    ip netns exec "$NS_POD_B" ip link set lo up
    log_ok "Loopback interfaces are up in both namespaces"

    echo ""
    echo "  Each namespace now contains only lo (DOWN→UP). Routing table is empty."
    echo "  These namespaces are analogous to the network namespace that kubelet"
    echo "  creates for the pause container before calling the CNI plugin."

    # -------------------------------------------------------------------------
    log_step "Step 2: Creating the Linux bridge cni0 (simulating the on-node virtual switch)"

    if link_exists "$BRIDGE_NAME"; then
        log_warn "Bridge $BRIDGE_NAME already exists — skipping creation"
    else
        ip link add "$BRIDGE_NAME" type bridge
        ip addr add "${BRIDGE_IP}/${PREFIX_LEN}" dev "$BRIDGE_NAME"
        ip link set "$BRIDGE_NAME" up
        log_ok "Created bridge $BRIDGE_NAME with IP ${BRIDGE_IP}/${PREFIX_LEN}"
    fi

    echo ""
    echo "  $BRIDGE_NAME is a software L2 switch. Its IP ($BRIDGE_IP) is the"
    echo "  default gateway for all pods on this node. Flannel names this cni0;"
    echo "  kubenet names it cbr0."

    # -------------------------------------------------------------------------
    log_step "Step 3: Creating veth pair for pod-a and connecting it"

    # Create veth pair; one end will be moved into ns-pod-a
    # (If a partial setup from a previous run left veth-pod-a, delete it first)
    if link_exists "$VETH_HOST_A"; then
        ip link delete "$VETH_HOST_A"
        log_warn "Removed stale $VETH_HOST_A before recreating"
    fi

    # Create the veth pair: host side = VETH_HOST_A, pod side = eth0
    # The pod side is named eth0 temporarily (in root ns); it will be moved
    ip link add "$VETH_HOST_A" type veth peer name eth0

    # Move the eth0 end into ns-pod-a's network namespace.
    # After this call, eth0 is ONLY visible inside ns-pod-a.
    ip link set eth0 netns "$NS_POD_A"

    # Enslave the host-side end to the bridge (making it a bridge port)
    ip link set "$VETH_HOST_A" master "$BRIDGE_NAME"
    ip link set "$VETH_HOST_A" up

    # Configure inside ns-pod-a: assign IP and bring up interfaces
    ip netns exec "$NS_POD_A" ip addr add "${IP_POD_A}/${PREFIX_LEN}" dev eth0
    ip netns exec "$NS_POD_A" ip link set eth0 up

    # Add default route inside pod-a pointing to the bridge IP
    ip netns exec "$NS_POD_A" ip route add default via "$BRIDGE_IP" dev eth0

    log_ok "veth pair created: host=$VETH_HOST_A (enslaved to $BRIDGE_NAME)  pod=eth0 (in $NS_POD_A)"
    log_ok "Assigned IP ${IP_POD_A}/${PREFIX_LEN} to eth0 in $NS_POD_A"
    log_ok "Default route: via $BRIDGE_IP in $NS_POD_A"

    # -------------------------------------------------------------------------
    log_step "Step 4: Creating veth pair for pod-b and connecting it"

    if link_exists "$VETH_HOST_B"; then
        ip link delete "$VETH_HOST_B"
        log_warn "Removed stale $VETH_HOST_B before recreating"
    fi

    ip link add "$VETH_HOST_B" type veth peer name eth0
    ip link set eth0 netns "$NS_POD_B"
    ip link set "$VETH_HOST_B" master "$BRIDGE_NAME"
    ip link set "$VETH_HOST_B" up

    ip netns exec "$NS_POD_B" ip addr add "${IP_POD_B}/${PREFIX_LEN}" dev eth0
    ip netns exec "$NS_POD_B" ip link set eth0 up
    ip netns exec "$NS_POD_B" ip route add default via "$BRIDGE_IP" dev eth0

    log_ok "veth pair created: host=$VETH_HOST_B (enslaved to $BRIDGE_NAME)  pod=eth0 (in $NS_POD_B)"
    log_ok "Assigned IP ${IP_POD_B}/${PREFIX_LEN} to eth0 in $NS_POD_B"
    log_ok "Default route: via $BRIDGE_IP in $NS_POD_B"

    # -------------------------------------------------------------------------
    log_step "Step 5: Enabling IP forwarding and iptables rules for external egress"

    # IP forwarding must be enabled for the host to route packets between interfaces
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    log_ok "ip_forward enabled ($(cat /proc/sys/net/ipv4/ip_forward))"

    # MASQUERADE: packets from pod CIDR going out any interface except cni0 itself
    # get their source IP rewritten to the host's outbound interface IP.
    # The '! -o cni0' condition exempts pod-to-pod same-node traffic.
    iptables -t nat -A POSTROUTING -s "${POD_CIDR}" ! -o "${BRIDGE_NAME}" -j MASQUERADE
    log_ok "Added MASQUERADE rule: src $POD_CIDR out !${BRIDGE_NAME} -> MASQUERADE"

    # Allow forwarding of all traffic through the bridge
    iptables -A FORWARD -i "${BRIDGE_NAME}" -j ACCEPT
    iptables -A FORWARD -o "${BRIDGE_NAME}" -j ACCEPT
    log_ok "Added FORWARD ACCEPT rules for bridge $BRIDGE_NAME"

    echo ""
    echo "  Setup complete. Both pod namespaces are wired into $BRIDGE_NAME."
    echo ""
    echo "  State summary:"
    echo "    ns-pod-a: eth0=${IP_POD_A}/${PREFIX_LEN}  gateway=${BRIDGE_IP}"
    echo "    ns-pod-b: eth0=${IP_POD_B}/${PREFIX_LEN}  gateway=${BRIDGE_IP}"
    echo "    bridge:   ${BRIDGE_NAME} ${BRIDGE_IP}/${PREFIX_LEN}"
    echo ""
    echo "  Try manual inspection:"
    echo "    sudo ip netns exec ns-pod-a ip addr show"
    echo "    sudo ip netns exec ns-pod-a ip route show"
    echo "    bridge fdb show dev cni0"
}

# --- Tests -------------------------------------------------------------------

run_tests() {
    local failures=0

    log_step "Test 1: pod-a can ping itself (loopback sanity)"
    if ip netns exec "$NS_POD_A" ping -c 1 -W 2 127.0.0.1 &>/dev/null; then
        log_ok "ping 127.0.0.1 from $NS_POD_A succeeded"
    else
        log_fail "ping 127.0.0.1 from $NS_POD_A failed"
        failures=$((failures + 1))
    fi

    log_step "Test 2: pod-a can reach the bridge gateway (first hop)"
    if ip netns exec "$NS_POD_A" ping -c 2 -W 2 "$BRIDGE_IP" &>/dev/null; then
        log_ok "ping $BRIDGE_IP from $NS_POD_A succeeded"
    else
        log_fail "ping $BRIDGE_IP from $NS_POD_A failed"
        failures=$((failures + 1))
    fi

    log_step "Test 3: pod-a can reach pod-b (same-node pod-to-pod path)"
    echo "  Sending 3 ICMP packets from $IP_POD_A to $IP_POD_B ..."
    if ip netns exec "$NS_POD_A" ping -c 3 -W 2 "$IP_POD_B"; then
        log_ok "pod-a -> pod-b connectivity: PASS"
    else
        log_fail "pod-a -> pod-b connectivity: FAIL"
        failures=$((failures + 1))
    fi

    log_step "Test 4: pod-b can reach pod-a (reverse direction)"
    if ip netns exec "$NS_POD_B" ping -c 2 -W 2 "$IP_POD_A" &>/dev/null; then
        log_ok "pod-b -> pod-a connectivity: PASS"
    else
        log_fail "pod-b -> pod-a connectivity: FAIL"
        failures=$((failures + 1))
    fi

    log_step "Test 5: ARP cache inspection — bridge has learned both pod MACs"
    local fdb_entries
    fdb_entries=$(bridge fdb show dev "$BRIDGE_NAME" | grep -v "permanent" | wc -l)
    if [[ "$fdb_entries" -ge 2 ]]; then
        log_ok "Bridge FDB has $fdb_entries dynamic entries (expected >= 2 after ping traffic)"
    else
        log_warn "Bridge FDB has $fdb_entries dynamic entries — may not have learned MACs yet"
        echo "    (run a ping first; MAC learning requires at least one frame to have been forwarded)"
    fi
    bridge fdb show dev "$BRIDGE_NAME" | while read -r line; do
        echo "    $line"
    done

    log_step "Test 6: ARP table inside pod-a"
    echo "  ARP cache in $NS_POD_A:"
    ip netns exec "$NS_POD_A" ip neigh show | while read -r line; do
        echo "    $line"
    done

    log_step "Test 7: External egress via MASQUERADE (requires host internet access)"
    echo "  Attempting to reach host's default gateway from pod-a ..."
    local host_gw
    host_gw=$(ip route show default | awk '/default/ {print $3}' | head -1)
    if [[ -n "$host_gw" ]]; then
        if ip netns exec "$NS_POD_A" ping -c 2 -W 3 "$host_gw" &>/dev/null; then
            log_ok "pod-a -> host gateway ($host_gw): PASS (MASQUERADE is working)"
        else
            log_warn "pod-a -> host gateway ($host_gw): could not reach — may be firewall-blocked on host"
        fi
    else
        log_warn "Could not determine host default gateway — skipping external egress test"
    fi

    echo ""
    if [[ $failures -eq 0 ]]; then
        echo -e "${GREEN}All required tests passed.${NC}"
    else
        echo -e "${RED}$failures test(s) failed. Check the output above for details.${NC}"
        return 1
    fi
}

# --- Main --------------------------------------------------------------------

main() {
    check_root
    check_dependencies

    local command="${1:-demo}"

    case "$command" in
        setup)
            setup
            echo ""
            echo "Resources are set up. Inspect them manually, then run:"
            echo "  sudo $0 teardown"
            ;;
        teardown)
            teardown
            ;;
        test)
            # Run tests against an already-set-up environment
            run_tests
            ;;
        demo)
            # Full demo: setup + test + teardown
            echo "========================================================"
            echo " veth-bridge-demo.sh — CNI pod networking simulation"
            echo "========================================================"
            echo ""
            echo "This script creates two network namespaces, wires them"
            echo "through a Linux bridge, and tests connectivity — mirroring"
            echo "exactly what the CNI bridge plugin does for each pod."
            echo ""

            # Register teardown to run on script exit (Ctrl-C, error, or normal exit)
            # so resources are always cleaned up when running in demo mode.
            trap teardown EXIT

            setup
            echo ""
            run_tests
            echo ""
            echo "Tests complete. Cleaning up (teardown runs automatically on exit)..."
            # teardown will be called by the EXIT trap
            ;;
        *)
            echo "Usage: $0 [setup|teardown|test|demo]"
            echo ""
            echo "  demo      Run full demonstration: setup, test, teardown (default)"
            echo "  setup     Create namespaces, bridge, veth pairs, iptables rules"
            echo "  teardown  Remove all resources created by setup"
            echo "  test      Run connectivity tests against an existing setup"
            exit 1
            ;;
    esac
}

main "$@"
