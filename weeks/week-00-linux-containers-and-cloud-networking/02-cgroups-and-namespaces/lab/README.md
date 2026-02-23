# Lab: cgroups and Namespaces

This lab builds hands-on intuition for the two kernel primitives that make containers work. You will create namespace isolation with `unshare`, enforce memory limits with cgroups, trigger a deliberate OOM kill, and mount an overlayfs by hand — the exact mechanics that a container runtime performs when starting a container.

## Prerequisites

- Linux host or VM (not macOS — these kernel features are Linux-only). A WSL2 instance or a Linux VM (Ubuntu 22.04 LTS recommended) works.
- Root access (`sudo -i` or run as root). Most exercises require root.
- Packages: `util-linux` (provides `unshare`, `nsenter`), `cgroup-tools` or `cgroupctl`, `iproute2`, `curl`, `jq`.
- cgroups v2 unified hierarchy is assumed. Verify with: `cat /sys/fs/cgroup/cgroup.controllers` — if that file exists, you have cgroupsv2.
- On Ubuntu: `sudo apt-get update && sudo apt-get install -y util-linux iproute2 curl jq cgroup-tools`

```bash
# Confirm cgroupsv2
cat /sys/fs/cgroup/cgroup.controllers
# Expected output includes: cpuset cpu io memory hugetlb pids rdma

# Confirm kernel version (5.4+ required for all features)
uname -r
```

---

## Exercise 1: PID Namespace Isolation with unshare

In this exercise you create a new PID namespace and observe that the shell inside it sees only its own process tree, while the host sees everything.

### Step 1: Start a shell in a new PID namespace

```bash
# --pid creates a new PID namespace
# --fork is required when --pid is used: unshare forks before exec so the
#        child becomes PID 1 in the new namespace (otherwise unshare itself
#        would be PID 1 which prevents it from exec'ing correctly)
# --mount-proc remounts /proc so tools like ps read the new namespace's data
sudo unshare --pid --fork --mount-proc /bin/bash
```

**What's happening**: The kernel calls `unshare(CLONE_NEWPID)` for the current process, then forks. The child process becomes PID 1 in the new PID namespace. `/proc` is remounted fresh from the new PID namespace's view, so `ps` and `/proc/<pid>/` entries reflect only processes in this namespace.

**Verification** (inside the unshare shell):
```bash
# See your PID — should be 1
echo $$

# List all visible processes — should be only bash and ps
ps aux
# Expected: only PID 1 (bash) and PID 2 (ps)

# The /proc directory only contains PIDs from this namespace
ls /proc | grep -E '^[0-9]+$' | sort -n
# Expected: only 1, 2 (or similar small numbers)
```

### Step 2: Observe from the host (second terminal)

Open a second terminal (do not exit the unshare shell). On the host:

```bash
# List all processes with ps and find the bash we launched
ps aux | grep "unshare\|/bin/bash"

# The container's PID 1 has a REAL PID on the host (e.g., 98234)
# Its own PID namespace thinks it is PID 1
# Note the host PID — it will be much larger than 1
```

**What's happening**: PID namespaces are hierarchical. The host's PID namespace (the root namespace) can see all processes in all child namespaces. The child namespace can only see its own processes. This is why `kubectl exec` on the host can `kill -9 <container-pid>` using the host PID, even though inside the container that same process is PID 1.

### Step 3: Demonstrate PID 1 init behavior

```bash
# Still inside the unshare shell
# Start a background sleep
sleep 1000 &
SLEEP_PID=$!
echo "Sleep is PID $SLEEP_PID inside the namespace"

# Kill PID 1 (the bash shell)
# When PID 1 in a PID namespace exits, all other processes in the namespace receive SIGKILL
# To test: exit the shell (type exit or press Ctrl-D)
# The sleep process will be killed automatically
exit
```

**Verification** (back on host):
```bash
# Confirm the sleep process no longer exists
ps aux | grep "sleep 1000"
# Should show nothing — killed when PID 1 exited
```

---

## Exercise 2: Mount Namespace and Rootfs Isolation

Create a minimal isolated filesystem view using a mount namespace.

### Step 1: Create a minimal rootfs

```bash
# Create a directory structure that will serve as the container's rootfs
mkdir -p /tmp/myrootfs/{bin,lib,lib64,proc,sys,dev,tmp}

# Copy bash and the minimal libraries it needs
cp /bin/bash /tmp/myrootfs/bin/
cp /bin/ls   /tmp/myrootfs/bin/
cp /bin/cat  /tmp/myrootfs/bin/

# Copy required shared libraries (ldd shows dependencies)
ldd /bin/bash | awk '/=>/{print $3}' | xargs -I{} cp {} /tmp/myrootfs/lib/ 2>/dev/null
cp /lib64/ld-linux-x86-64.so.2 /tmp/myrootfs/lib64/ 2>/dev/null || \
  cp /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 /tmp/myrootfs/lib/ 2>/dev/null
# Also copy for ls
ldd /bin/ls | awk '/=>/{print $3}' | xargs -I{} cp {} /tmp/myrootfs/lib/ 2>/dev/null
```

### Step 2: Create a new mount namespace with its own root

```bash
# --mount creates a new mount namespace (isolated mount table)
# --pid + --fork + --mount-proc for PID isolation too
# chroot switches the root to our minimal rootfs
sudo unshare --mount --pid --fork bash -c '
  # Mount proc in the new namespace so bash can read /proc
  mount -t proc none /tmp/myrootfs/proc

  # Change root to our minimal filesystem
  # pivot_root is preferred over chroot but requires more setup
  chroot /tmp/myrootfs /bin/bash
'
```

**What's happening**: Inside the chroot, the process sees only `/tmp/myrootfs` as `/`. The mount namespace means that this mount operation (proc mounted at `/tmp/myrootfs/proc`) is visible only inside this namespace — it does not appear in the host's mount table.

**Verification** (inside the chroot shell):
```bash
# List root directory — should see only our minimal tree
ls /
# Expected: bin lib lib64 proc sys dev tmp

# Confirm we cannot see the host filesystem
ls /etc 2>&1
# Expected: bash: ls: command not found (if /bin/ls didn't copy right)
# or: ls: cannot access '/etc': No such file or directory

# Check that /proc is mounted
ls /proc/
# Should see process entries
```

### Step 3: Verify mount isolation from the host

```bash
# In a second terminal on the host:
cat /proc/mounts | grep myrootfs
# Should show the bind mount of proc inside /tmp/myrootfs/proc
# This is visible on the host because it happens before the namespace is fully isolated
# In a real container runtime, the mount happens AFTER CLONE_NEWNS, making it invisible

mount | grep myrootfs
```

**Cleanup**:
```bash
# Exit the chroot shell, then on the host:
sudo umount /tmp/myrootfs/proc 2>/dev/null
rm -rf /tmp/myrootfs
```

---

## Exercise 3: Manual cgroup Creation and Memory Limit Enforcement

Create a cgroup manually and enforce a memory limit on a shell process. This is exactly what `runc` does when starting a container with `resources.limits.memory`.

### Step 1: Create a cgroup

```bash
# cgroups v2: create a subdirectory under the system root
# We create a child of the root cgroup
sudo mkdir /sys/fs/cgroup/lab-demo

# Verify the kernel auto-created control files
ls /sys/fs/cgroup/lab-demo/
# Expected: cgroup.controllers, cgroup.events, cgroup.max.depth,
#           cgroup.procs, cgroup.subtree_control, cgroup.threads, ...
#           memory.current, memory.events, memory.max, cpu.max, etc.
```

### Step 2: Enable controllers and set limits

```bash
# Enable memory and cpu controllers on this cgroup
# (must be enabled in the parent first — check parent's cgroup.subtree_control)
cat /sys/fs/cgroup/cgroup.subtree_control
# Should include: memory cpu

# If not, enable them:
echo "+memory +cpu" | sudo tee /sys/fs/cgroup/cgroup.subtree_control

# Set memory limit to 50MB (50 * 1024 * 1024 = 52428800)
echo "52428800" | sudo tee /sys/fs/cgroup/lab-demo/memory.max

# Set CPU limit to 50% of one CPU (50ms per 100ms period)
echo "50000 100000" | sudo tee /sys/fs/cgroup/lab-demo/cpu.max

# Verify the limits are set
cat /sys/fs/cgroup/lab-demo/memory.max
# Expected: 52428800

cat /sys/fs/cgroup/lab-demo/cpu.max
# Expected: 50000 100000
```

### Step 3: Add a process to the cgroup and verify limits apply

```bash
# Start a bash shell and add it to the cgroup
# cgexec (from cgroup-tools) is the clean way, or write the PID directly
sudo cgexec -g memory:lab-demo bash &
CGROUP_BASH_PID=$!
echo "Launched bash PID: $CGROUP_BASH_PID"

# Or manually: write the PID to cgroup.procs
# echo $CGROUP_BASH_PID | sudo tee /sys/fs/cgroup/lab-demo/cgroup.procs

# Verify the PID is in the cgroup
cat /sys/fs/cgroup/lab-demo/cgroup.procs
# Expected: shows $CGROUP_BASH_PID

# Check current memory usage
cat /sys/fs/cgroup/lab-demo/memory.current
# Expected: a small number (bash's RSS, a few MB)

# Check memory limit is enforced
cat /sys/fs/cgroup/lab-demo/memory.max
# Expected: 52428800

kill $CGROUP_BASH_PID 2>/dev/null
```

**What's happening**: The kernel enforces `memory.max` on any process whose PID appears in `cgroup.procs`. Writing to `memory.max` does not affect the process immediately — it only activates when the process tries to allocate beyond the limit. All children of a process in a cgroup are automatically added to the same cgroup.

---

## Exercise 4: Trigger a Deliberate OOM Kill

Create a process that intentionally exceeds its memory limit and observe the kernel OOM kill.

### Step 1: Write a memory-eating script

```bash
cat > /tmp/eat-memory.sh << 'SCRIPT'
#!/bin/bash
# Allocate memory in a loop until we hit the cgroup limit
# Each iteration creates a 10MB string (10 * 1024 * 1024 chars)
echo "Starting memory allocation. PID: $$"
echo "Current cgroup memory limit:"
cat /sys/fs/cgroup/$(cat /proc/self/cgroup | grep '^0:' | cut -d: -f3)/memory.max 2>/dev/null \
  || cat /sys/fs/cgroup/memory/$(cat /proc/self/cgroup | grep memory | cut -d: -f3)/memory.limit_in_bytes 2>/dev/null \
  || echo "(unable to read — check cgroup path)"

DATA=""
i=0
while true; do
  # Append 10MB of data — forces memory allocation
  DATA="${DATA}$(head -c 10485760 /dev/urandom | base64)"
  i=$((i+1))
  echo "Allocated ~${i}0 MB"
  sleep 0.1
done
SCRIPT
chmod +x /tmp/eat-memory.sh
```

### Step 2: Run the script in the memory-limited cgroup

```bash
# Set a lower limit for a more responsive demo: 30MB
echo "31457280" | sudo tee /sys/fs/cgroup/lab-demo/memory.max

# Run the memory-eating script inside the cgroup
# cgexec adds the process to the cgroup before exec
sudo cgexec -g memory:lab-demo /tmp/eat-memory.sh
```

**What's happening**: The script continuously allocates memory. When it tries to allocate beyond 30MB, the kernel first attempts to reclaim page cache. Since there is nothing to reclaim (the allocations are anonymous memory from `base64`), the kernel invokes the OOM killer within the `lab-demo` cgroup scope. The script's process receives SIGKILL (signal 9) and exits.

**Verification**:
```bash
# Check the OOM kill count in the cgroup
cat /sys/fs/cgroup/lab-demo/memory.events
# Expected to include: oom_kill 1 (or more)

# Check the kernel ring buffer for the OOM kill event
sudo dmesg -T | grep -i "oom\|killed process" | tail -5
# Expected: lines like "oom-kill:constraint=CONSTRAINT_MEMCG,..."
# showing the process name, PID, and which cgroup triggered it
```

### Step 3: Read the OOM kill details

```bash
# The memory.events file is the key diagnostic for per-cgroup OOM activity
cat /sys/fs/cgroup/lab-demo/memory.events
# Key fields:
#   oom           - number of times OOM was triggered but process survived (reclaim succeeded)
#   oom_kill      - number of processes killed by OOM within this cgroup
#   oom_group_kill - number of times all processes in group were killed together (v2 feature)
```

**Cleanup**:
```bash
sudo rmdir /sys/fs/cgroup/lab-demo
rm -f /tmp/eat-memory.sh
```

---

## Exercise 5: overlayfs Mount by Hand

Mount an overlayfs union filesystem manually, the same way a container runtime assembles a container's root filesystem from image layers.

### Step 1: Create the directory structure

```bash
# Create directories representing image layers and the container's rw layer
mkdir -p /tmp/overlay-demo/{lower1,lower2,upper,work,merged}

# Populate the lower layers (simulating image layers — read-only)
echo "base layer content" > /tmp/overlay-demo/lower2/base.txt
echo "app layer content"  > /tmp/overlay-demo/lower1/app.txt
echo "shared file — lower version" > /tmp/overlay-demo/lower1/shared.txt

ls /tmp/overlay-demo/lower1/
ls /tmp/overlay-demo/lower2/
```

### Step 2: Mount the overlayfs

```bash
# Mount with lowerdir (colon-separated, first = highest priority),
# upperdir (rw layer), workdir (required internal temp dir)
sudo mount -t overlay overlay \
  -o lowerdir=/tmp/overlay-demo/lower1:/tmp/overlay-demo/lower2,\
upperdir=/tmp/overlay-demo/upper,\
workdir=/tmp/overlay-demo/work \
  /tmp/overlay-demo/merged

# Verify the merged view
ls /tmp/overlay-demo/merged/
# Expected: app.txt  base.txt  shared.txt (all files from all layers merged)
```

**What's happening**: The overlay driver presents a union of all lower directories and the upper directory. Files in `lower1` take precedence over `lower2` for the same filename. The upper directory starts empty. `work` is required by the kernel for atomic copy-up operations.

### Step 3: Observe copy-on-write behavior

```bash
# Read a file from the lower layer (no copy-up — read is served directly)
cat /tmp/overlay-demo/merged/base.txt
# Expected: base layer content

# Now write to a lower-layer file — this triggers copy-up
echo "modified by container" > /tmp/overlay-demo/merged/base.txt

# Check: the upper layer now has a copy of base.txt
ls -la /tmp/overlay-demo/upper/
# Expected: base.txt appears in upper/

# Verify content in merged is the new version
cat /tmp/overlay-demo/merged/base.txt
# Expected: modified by container

# The original lower layer is unchanged
cat /tmp/overlay-demo/lower2/base.txt
# Expected: base layer content  (lower layer is NEVER modified)
```

**What's happening**: Writing to `merged/base.txt` triggered `copy_up()`. The full file was copied from `lower2/base.txt` to `upper/base.txt`, then the write was applied to the upper copy. The lower layer remains immutable.

### Step 4: Observe file deletion via whiteout

```bash
# Delete a file from the merged view
rm /tmp/overlay-demo/merged/app.txt

# Check the upper layer — a whiteout device file was created
ls -la /tmp/overlay-demo/upper/
# Expected: c--------- 1 root root 0, 0 <date> app.txt
# (character device with 0:0 major/minor = whiteout)

# The file is gone from the merged view
ls /tmp/overlay-demo/merged/
# Expected: base.txt  shared.txt  (app.txt is masked by the whiteout)

# But the original lower layer file still exists
ls /tmp/overlay-demo/lower1/
# Expected: app.txt  shared.txt  (unchanged)
```

### Step 5: Measure copy-up cost for a large file

```bash
# Create a large file in a lower layer
dd if=/dev/urandom of=/tmp/overlay-demo/lower1/bigfile.bin bs=1M count=50 2>&1
# This creates a 50MB file in the lower layer

# Remount to pick up the new lower layer file
sudo umount /tmp/overlay-demo/merged
sudo mount -t overlay overlay \
  -o lowerdir=/tmp/overlay-demo/lower1:/tmp/overlay-demo/lower2,\
upperdir=/tmp/overlay-demo/upper,\
workdir=/tmp/overlay-demo/work \
  /tmp/overlay-demo/merged

# Measure how long it takes to write ONE BYTE to the 50MB file
time bash -c 'echo x >> /tmp/overlay-demo/merged/bigfile.bin'
# Observe: this takes noticeably longer than writing to a new file
# because the entire 50MB is copied from lower to upper first

# Compare with writing a new file (no copy-up needed)
time bash -c 'echo x >> /tmp/overlay-demo/merged/newfile.txt'
# Much faster — writes directly to upper since no lower counterpart exists
```

**Verification of copy-up cost**: The first command should take significantly longer (seconds vs milliseconds) than the second. This demonstrates why writing to large files from image layers inside containers is expensive.

### Step 6: Cleanup

```bash
sudo umount /tmp/overlay-demo/merged
rm -rf /tmp/overlay-demo
```

---

## Exercise 6: Network Namespace Isolation

Create an isolated network namespace and wire it to the host with a veth pair, exactly as a CNI plugin does for a Pod.

```bash
# Create a new network namespace
sudo ip netns add container-demo

# Verify it exists
ip netns list
# Expected: container-demo

# The namespace has only a loopback interface (down by default)
sudo ip netns exec container-demo ip link list
# Expected: 1: lo: <LOOPBACK> ...

# Create a veth (virtual ethernet) pair
# veth0 stays on the host, veth1 moves into the container namespace
sudo ip link add veth0 type veth peer name veth1
sudo ip link set veth1 netns container-demo

# Configure the host-side interface
sudo ip addr add 192.168.100.1/24 dev veth0
sudo ip link set veth0 up

# Configure the container-side interface
sudo ip netns exec container-demo ip addr add 192.168.100.2/24 dev veth1
sudo ip netns exec container-demo ip link set veth1 up
sudo ip netns exec container-demo ip link set lo up

# Test connectivity: ping from host into the container namespace
ping -c 3 192.168.100.2
# Expected: 3 packets transmitted, 3 received

# Test from inside the namespace out to the host
sudo ip netns exec container-demo ping -c 3 192.168.100.1
# Expected: 3 packets transmitted, 3 received

# Run a command inside the isolated network namespace
sudo ip netns exec container-demo ip addr show
# Only veth1 and lo are visible — host's eth0, docker0, etc. are invisible
```

**What's happening**: `ip netns exec` calls `setns(2)` to enter the network namespace before executing the command — the same mechanism as `nsenter`. The container sees only its veth1 and lo interfaces. It has its own routing table, iptables chains, and socket table. Port 8080 in this namespace is completely independent of port 8080 on the host.

```bash
# Cleanup
sudo ip netns del container-demo
sudo ip link del veth0 2>/dev/null  # veth0 is auto-deleted when veth1 is removed
```

---

## Key Takeaways

1. **Namespaces are created with `clone(2)` flags** — `CLONE_NEWPID`, `CLONE_NEWNET`, etc. `unshare(1)` creates new namespaces for the current process; `nsenter(1)` joins existing namespaces of another PID.

2. **PID 1 in a PID namespace is special** — its exit sends SIGKILL to all other processes in the namespace, which is why container runtimes use an init process (tini, dumb-init) rather than running applications directly as PID 1.

3. **cgroups v2 uses a unified hierarchy** — all controllers under `/sys/fs/cgroup/`. Limits are written to pseudo-files like `memory.max` and `cpu.max`. Any process in `cgroup.procs` is subject to those limits.

4. **OOM selection is by `oom_score`, not by which container is at fault** — Kubernetes sets `oom_score_adj` based on QoS class. Guaranteed pods get -997; BestEffort pods get 1000.

5. **CFS throttling is period-based, not average-based** — a bursty container can be throttled at 30% average utilization if it consumes its quota in the first half of each period. Check `cpu.stat throttled_usec`.

6. **overlayfs copy-up is full-file, not block-level** — writing one byte to a large lower-layer file copies the entire file. Build container images so large files live in lower layers that applications never modify.

7. **veth pairs are the CNI primitive** — one end in the container's network namespace, one end on the host bridge. The same `ip netns` and `ip link` commands in this lab are executed by every CNI plugin (Flannel, Calico, Cilium) when a Pod is created.
