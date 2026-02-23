#!/bin/bash
# unshare-demo.sh
#
# Demonstrates Linux namespace isolation using unshare(1).
# Shows PID namespace isolation, mount namespace with a custom rootfs view,
# and network namespace with isolated interfaces.
#
# This script performs the same operations a container runtime performs
# when creating a container, minus the OCI lifecycle hooks.
#
# REQUIREMENTS:
#   - Must run as root (sudo ./unshare-demo.sh)
#   - Linux kernel 4.6+ (user namespaces, cgroup namespaces)
#   - util-linux >= 2.27 (unshare with --pid --fork --mount-proc)
#   - iproute2 (ip command for network namespace wiring)
#
# USAGE:
#   sudo ./unshare-demo.sh [demo]
#
#   Demos:
#     pid      -- PID namespace isolation
#     mount    -- Mount namespace with minimal rootfs
#     net      -- Network namespace with veth pair
#     all      -- Run all demos in sequence (default)

set -euo pipefail

# ────────────────────────────────────────────────────────────────────────────
# Safety checks
# ────────────────────────────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root." >&2
  echo "       Run: sudo $0 $*" >&2
  exit 1
fi

# Verify required tools are present
for cmd in unshare nsenter ip mount umount; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: Required command '$cmd' not found. Install util-linux and iproute2." >&2
    exit 1
  fi
done

# Verify we are on Linux
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "ERROR: This script requires Linux. macOS does not support Linux namespaces." >&2
  exit 1
fi

# ────────────────────────────────────────────────────────────────────────────
# Utility functions
# ────────────────────────────────────────────────────────────────────────────

BOLD="\033[1m"
RESET="\033[0m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"

header() {
  echo ""
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}${CYAN}  $1${RESET}"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
}

step() {
  echo ""
  echo -e "${BOLD}${GREEN}── $1${RESET}"
}

note() {
  echo -e "${YELLOW}   NOTE: $1${RESET}"
}

pause() {
  echo ""
  echo -e "${BOLD}Press ENTER to continue...${RESET}"
  read -r
}

# Cleanup registry so we can clean up on EXIT
CLEANUP_FUNCS=()

cleanup_all() {
  echo ""
  echo "Cleaning up resources..."
  for fn in "${CLEANUP_FUNCS[@]}"; do
    $fn 2>/dev/null || true
  done
  echo "Cleanup complete."
}
trap cleanup_all EXIT

# ────────────────────────────────────────────────────────────────────────────
# Demo 1: PID Namespace Isolation
# ────────────────────────────────────────────────────────────────────────────

demo_pid() {
  header "Demo 1: PID Namespace Isolation"

  echo ""
  echo "Namespaces isolate what a process can SEE, not what it can USE."
  echo "A PID namespace gives a process its own PID number space."
  echo "The first process in a new PID namespace gets PID 1."
  echo ""
  echo "The host sees ALL processes (child namespaces are visible to parent)."
  echo "The container sees ONLY its own PID namespace."
  echo ""

  step "1. Show host PID count before creating the namespace"
  echo "   Number of processes on the host:"
  ps aux --no-headers | wc -l

  step "2. Show what unshare --pid does under the hood"
  echo "   unshare(1) calls unshare(2) with CLONE_NEWPID, then fork()+exec()"
  echo "   The forked child gets PID 1 in the new namespace."
  echo "   --mount-proc remounts /proc from the new namespace's view."
  echo ""
  echo "   System call sequence:"
  echo "     unshare(CLONE_NEWPID | CLONE_NEWNS)"
  echo "     fork()"
  echo "     mount('proc', '/proc', 'proc', ...)"
  echo "     exec('/bin/bash')"

  step "3. Launch an interactive shell in a new PID namespace"
  note "The shell below is PID 1 in its own namespace."
  note "Type 'ps aux' to see only processes in this namespace."
  note "Type 'echo \$\$' to confirm your PID is 1."
  note "Type 'exit' to return here."
  echo ""

  # unshare flags:
  #   --pid     : create a new PID namespace
  #   --fork    : fork before exec (required for --pid; child becomes PID 1)
  #   --mount-proc : remount /proc from the new PID namespace perspective
  #
  # The resulting shell is a child process; this script continues after exit.
  unshare --pid --fork --mount-proc /bin/bash || true

  step "4. Verify: host PID count is unchanged"
  echo "   Number of processes on the host (same as before):"
  ps aux --no-headers | wc -l
  echo ""
  echo "   The isolated namespace created no net new processes visible to the host"
  echo "   beyond the bash shell itself (which IS visible to the host)."
}

# ────────────────────────────────────────────────────────────────────────────
# Demo 2: Mount Namespace with Minimal Rootfs
# ────────────────────────────────────────────────────────────────────────────

ROOTFS_DIR="/tmp/unshare-demo-rootfs"

cleanup_rootfs() {
  umount "${ROOTFS_DIR}/proc" 2>/dev/null || true
  rm -rf "${ROOTFS_DIR}"
}

build_rootfs() {
  step "Building a minimal rootfs in ${ROOTFS_DIR}"

  rm -rf "${ROOTFS_DIR}"
  mkdir -p "${ROOTFS_DIR}"/{bin,lib,lib64,proc,sys,dev,tmp,etc}

  # Copy bash and the minimal binaries we need inside the chroot
  for bin in bash ls cat echo mount ps; do
    bin_path=$(command -v "$bin" 2>/dev/null || true)
    if [[ -n "$bin_path" ]]; then
      cp "$bin_path" "${ROOTFS_DIR}/bin/"
    fi
  done

  # Copy required shared libraries for each binary
  for bin in bash ls cat echo; do
    bin_path=$(command -v "$bin" 2>/dev/null || true)
    if [[ -z "$bin_path" ]]; then continue; fi
    ldd "$bin_path" 2>/dev/null | grep -oE '/[^ ]+\.so[^ ]*' | while read -r lib; do
      if [[ -f "$lib" ]]; then
        libdir="${ROOTFS_DIR}$(dirname "$lib")"
        mkdir -p "$libdir"
        cp "$lib" "$libdir/" 2>/dev/null || true
      fi
    done
  done

  # Copy the dynamic linker
  for linker in \
      /lib64/ld-linux-x86-64.so.2 \
      /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 \
      /lib/ld-linux-x86-64.so.2; do
    if [[ -f "$linker" ]]; then
      linker_dir="${ROOTFS_DIR}$(dirname "$linker")"
      mkdir -p "$linker_dir"
      cp "$linker" "$linker_dir/"
      break
    fi
  done

  # Minimal /etc/passwd so bash doesn't complain
  echo "root:x:0:0:root:/root:/bin/bash" > "${ROOTFS_DIR}/etc/passwd"

  echo "   Rootfs created at ${ROOTFS_DIR}:"
  ls "${ROOTFS_DIR}/"
}

demo_mount() {
  header "Demo 2: Mount Namespace with Isolated Rootfs"

  echo ""
  echo "A mount namespace isolates the process's view of the filesystem."
  echo "Combined with chroot, the process sees a completely different /"
  echo "from the host. This is how container images work: the image layers"
  echo "are assembled into a merged overlayfs and chroot'd into."
  echo ""
  echo "Mount operations inside the namespace do NOT appear in the host's"
  echo "mount table because they occur after CLONE_NEWNS."
  echo ""

  # Register cleanup first so it runs even if build fails
  CLEANUP_FUNCS+=("cleanup_rootfs")

  build_rootfs

  step "Launching shell in isolated mount namespace"
  note "Inside the shell: ls / shows only our minimal rootfs."
  note "The host's /etc, /home, /var are not visible."
  note "Type 'ls /' and 'ls /bin' to explore."
  note "Type 'exit' to return to the host."
  echo ""

  # Mount /proc for ps inside the chroot, then pivot the root
  # We do this inside the unshare so the mount stays in the new namespace
  unshare --mount bash -c "
    # Mount /proc inside the new mount namespace at our rootfs location
    mount -t proc proc '${ROOTFS_DIR}/proc'

    # chroot into the minimal rootfs and exec bash
    # Note: pivot_root is more correct than chroot for production use
    # (pivot_root fully switches the root; chroot does not remove the old root
    #  from the filesystem tree). For this demo, chroot is sufficient.
    echo ''
    echo 'You are now inside the isolated mount namespace.'
    echo 'The root filesystem is the minimal rootfs we built.'
    echo ''
    chroot '${ROOTFS_DIR}' /bin/bash || true
  " || true

  step "Verifying host mount table is clean"
  echo "   Checking that /proc is NOT mounted at ${ROOTFS_DIR}/proc from the host's view:"
  if mount | grep "${ROOTFS_DIR}/proc" &>/dev/null; then
    echo "   WARNING: mount leaked into host namespace (this would not happen in a real container runtime)"
    echo "   Cleaning up..."
    umount "${ROOTFS_DIR}/proc" 2>/dev/null || true
  else
    echo "   Confirmed: no mount leak. The namespace kept mounts isolated."
  fi
}

# ────────────────────────────────────────────────────────────────────────────
# Demo 3: Network Namespace with veth Pair
# ────────────────────────────────────────────────────────────────────────────

NETNS_NAME="unshare-demo-net"
VETH_HOST="veth-host-demo"
VETH_CONT="veth-cont-demo"
HOST_IP="172.31.100.1"
CONT_IP="172.31.100.2"

cleanup_netns() {
  ip netns del "${NETNS_NAME}" 2>/dev/null || true
  ip link del "${VETH_HOST}" 2>/dev/null || true
}

demo_net() {
  header "Demo 3: Network Namespace with veth Pair"

  echo ""
  echo "A network namespace isolates the entire network stack:"
  echo "  - Network interfaces (eth0, lo)"
  echo "  - Routing table"
  echo "  - iptables/nftables chains"
  echo "  - Socket table (netstat/ss output)"
  echo "  - Port bindings"
  echo ""
  echo "Two containers can each bind port 8080 without conflict because"
  echo "each has its own port space inside its network namespace."
  echo ""
  echo "A veth (virtual ethernet) pair connects the container namespace"
  echo "to the host: one end lives in the container, one end on the host bridge."
  echo "This is the exact mechanism CNI plugins (Flannel, Calico, Cilium) use."
  echo ""

  # Register cleanup
  CLEANUP_FUNCS+=("cleanup_netns")

  step "1. Create a named network namespace"
  ip netns add "${NETNS_NAME}"
  echo "   Created: ${NETNS_NAME}"
  ip netns list

  step "2. Show the new namespace has only loopback (no eth0 yet)"
  echo "   Interfaces inside ${NETNS_NAME}:"
  ip netns exec "${NETNS_NAME}" ip link list
  echo ""
  note "Only lo is present. It's down. No routes. No external connectivity."

  step "3. Create a veth pair"
  echo "   veth pair: ${VETH_HOST} (host) <──> ${VETH_CONT} (container)"
  ip link add "${VETH_HOST}" type veth peer name "${VETH_CONT}"
  echo "   Created:"
  ip link show "${VETH_HOST}"

  step "4. Move one end of the veth pair into the container namespace"
  ip link set "${VETH_CONT}" netns "${NETNS_NAME}"
  echo "   ${VETH_CONT} is now inside namespace ${NETNS_NAME}"
  echo ""
  echo "   From the host, ${VETH_CONT} is no longer visible:"
  ip link show "${VETH_CONT}" 2>&1 || echo "   (correct: not found on host)"

  step "5. Configure IP addresses on both ends"
  # Host side
  ip addr add "${HOST_IP}/24" dev "${VETH_HOST}"
  ip link set "${VETH_HOST}" up
  echo "   Host side: ${HOST_IP}/24 on ${VETH_HOST} (up)"

  # Container side (inside the namespace)
  ip netns exec "${NETNS_NAME}" ip addr add "${CONT_IP}/24" dev "${VETH_CONT}"
  ip netns exec "${NETNS_NAME}" ip link set "${VETH_CONT}" up
  ip netns exec "${NETNS_NAME}" ip link set lo up
  echo "   Container side: ${CONT_IP}/24 on ${VETH_CONT} (up)"

  step "6. Test connectivity across the namespace boundary"
  echo "   Pinging container (${CONT_IP}) from host:"
  ping -c 3 -W 2 "${CONT_IP}" || {
    echo "   WARNING: ping failed. Check if host routing is set up correctly."
  }

  echo ""
  echo "   Pinging host (${HOST_IP}) from inside the namespace:"
  ip netns exec "${NETNS_NAME}" ping -c 3 -W 2 "${HOST_IP}" || {
    echo "   WARNING: ping failed from inside namespace."
  }

  step "7. Demonstrate port space isolation"
  echo "   Starting a netcat listener on port 8080 inside the container namespace..."
  # Start a brief listener inside the namespace
  ip netns exec "${NETNS_NAME}" bash -c \
    'echo "container listener" | nc -l -p 8080 &'
  NC_PID=$!
  sleep 0.3

  echo "   Checking that the port is NOT visible from the host socket table:"
  ss -tlnp | grep 8080 || echo "   Confirmed: port 8080 on the host is NOT bound."
  echo ""
  echo "   The container's port 8080 is completely isolated from the host's port 8080."
  echo "   A second container could also bind port 8080 in its own network namespace."

  kill $NC_PID 2>/dev/null || true

  step "8. Show the full network state inside the namespace"
  echo "   Interfaces and addresses inside ${NETNS_NAME}:"
  ip netns exec "${NETNS_NAME}" ip addr show
  echo ""
  echo "   Routes inside ${NETNS_NAME}:"
  ip netns exec "${NETNS_NAME}" ip route show
}

# ────────────────────────────────────────────────────────────────────────────
# Show /proc/<pid>/ns/ files — namespace identity
# ────────────────────────────────────────────────────────────────────────────

demo_ns_identity() {
  header "Bonus: /proc/<pid>/ns/ — Namespace Identity Files"

  echo ""
  echo "Every process has namespace file descriptors under /proc/<pid>/ns/."
  echo "These are bind-mountable file descriptors that keep namespaces alive"
  echo "even after all processes in them have exited."
  echo ""
  echo "Two processes sharing the same inode number for a namespace type"
  echo "are in the same namespace. This is how the kernel knows which"
  echo "processes can see each other."
  echo ""

  step "This process's namespace file descriptors:"
  ls -la /proc/$$/ns/
  echo ""
  echo "   The numbers in brackets (e.g., net:[4026531992]) are inode numbers."
  echo "   Same inode = same namespace."
  echo ""

  step "Compare with a process in a different network namespace:"
  # Start a process in a new network namespace briefly
  unshare --net bash -c "ls -la /proc/\$\$/ns/net" &
  UNSHARE_PID=$!
  wait $UNSHARE_PID 2>/dev/null || true

  echo ""
  echo "   The net inode above differs from this process's net inode:"
  ls -la /proc/$$/ns/net
  echo ""
  echo "   Different inodes confirm different network namespaces."
  echo "   nsenter uses this: it opens the target's /proc/<pid>/ns/<type>"
  echo "   and calls setns(fd) to switch into that namespace."
}

# ────────────────────────────────────────────────────────────────────────────
# Main entrypoint
# ────────────────────────────────────────────────────────────────────────────

DEMO="${1:-all}"

case "$DEMO" in
  pid)
    demo_pid
    ;;
  mount)
    demo_mount
    ;;
  net)
    demo_net
    ;;
  ns)
    demo_ns_identity
    ;;
  all)
    demo_pid
    echo ""
    pause
    demo_mount
    echo ""
    pause
    demo_net
    echo ""
    pause
    demo_ns_identity
    ;;
  *)
    echo "Usage: sudo $0 [pid|mount|net|ns|all]"
    echo ""
    echo "  pid    -- PID namespace isolation demo"
    echo "  mount  -- Mount namespace with minimal rootfs demo"
    echo "  net    -- Network namespace with veth pair demo"
    echo "  ns     -- /proc/<pid>/ns/ namespace identity demo"
    echo "  all    -- Run all demos in sequence (default)"
    exit 1
    ;;
esac

echo ""
echo -e "${BOLD}${GREEN}Demo complete.${RESET}"
echo ""
