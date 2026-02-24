# Lab: Linux Processes, Signals, and the Filesystem

This lab explores the kernel mechanisms that underpin container behavior using only standard Linux tools available on any system or inside a running container. No Kubernetes cluster is required. You will inspect /proc directly, observe signal delivery behavior, exhaust inodes on a tmpfs filesystem, and measure capability differences between regular and privileged containers.

## Prerequisites

- A Linux system, macOS with Docker Desktop, or any system with Docker installed
- `docker` CLI available (for exercises that use containers)
- `strace` available (install with `apt-get install strace` or `yum install strace`; not available on macOS host — use a container)
- `capsh` available for capability decoding (`apt-get install libcap2-bin`)
- Basic familiarity with shell scripting

> **macOS users**: Run the week-00 lab container which has all required tools pre-installed:
> ```bash
> cd weeks/week-00-linux-containers-and-cloud-networking
> ./lab-start.sh --build   # first time
> ./lab-start.sh           # subsequent runs
> ```
> Inside the container, lab scripts are at `/labs/01/`.

The exercises are designed to run sequentially but each section is independent. Estimated time: 60-90 minutes.

---

## Exercise 1: Explore /proc for a Running Process

This exercise familiarizes you with /proc as the primary source of process state.

### Step 1.1 — Launch a long-running process to inspect

```bash
# Start a sleep process in the background
sleep 9999 &
SLEEP_PID=$!
echo "Sleep PID: $SLEEP_PID"
```

### Step 1.2 — Read process status fields

```bash
# Read the full status file
cat /proc/$SLEEP_PID/status
```

**What's happening**: The kernel dynamically generates this file from the process's `task_struct`. Fields of interest:
- `State: S` — the process is in interruptible sleep (waiting for the timer to expire)
- `Pid` / `PPid` — PID and parent PID (should be your shell's PID)
- `VmRSS` — current resident set size (physical pages in RAM)
- `Threads` — number of threads (sleep is single-threaded: 1)
- `SigBlk`, `SigIgn`, `SigCgt` — blocked, ignored, and caught signal bitmasks in hex

**Verification**:
```bash
# Verify the state is S (sleeping), not R (running) or D (uninterruptible)
grep "^State" /proc/$SLEEP_PID/status
# Expected: State:	S (sleeping)

# Verify PPid is your current shell
grep "^PPid" /proc/$SLEEP_PID/status
echo "My shell PID: $$"
# Expected: PPid matches $$ (your shell PID)
```

---

### Step 1.3 — Inspect open file descriptors

```bash
# List all file descriptors open by the sleep process
ls -la /proc/$SLEEP_PID/fd/
```

**What's happening**: Each entry in `fd/` is a symlink. fd/0 is stdin, fd/1 is stdout, fd/2 is stderr. For a shell-launched process these typically point to the terminal device (e.g., `/dev/pts/0`). If a process has opened files, sockets, or pipes, they appear as additional entries. The count of entries is the process's open file descriptor count — each descriptor consumes a kernel `struct file` object and counts against the per-process `ulimit -n` (open files limit, default 1024 or 65536 depending on configuration).

**Verification**:
```bash
ls /proc/$SLEEP_PID/fd | wc -l
# Expected: 3 (stdin, stdout, stderr — sleep opens nothing else)
readlink /proc/$SLEEP_PID/fd/0
# Expected: a path like /dev/pts/0 or /dev/tty or similar terminal device
```

---

### Step 1.4 — Inspect virtual memory mappings

```bash
cat /proc/$SLEEP_PID/maps
```

**What's happening**: Each line is one virtual memory area (VMA). Columns are: `start-end`, `permissions` (r=read, w=write, x=execute, p=private/COW, s=shared), `offset`, `device`, `inode`, `pathname`. You will see:
- The `sleep` binary's text segment: `r-xp` (read + execute, private/COW)
- The `sleep` binary's data segment: `r--p` or `rw-p`
- `libc.so.6` and `ld-linux.so` mapped in (dynamic linking)
- The stack: `[stack]`
- `[vvar]` and `[vdso]`: virtual dynamic shared objects for fast syscalls (gettimeofday, clock_gettime)

**Verification**:
```bash
grep "r-xp" /proc/$SLEEP_PID/maps
# Expected: at least one r-xp line for the sleep binary and libc text segments
grep "\[stack\]" /proc/$SLEEP_PID/maps
# Expected: one line for the stack VMA
```

---

### Step 1.5 — Inspect namespace membership

```bash
ls -la /proc/$SLEEP_PID/ns/
```

**What's happening**: Each entry is a symlink to a namespace inode. The inode number in brackets uniquely identifies the namespace instance. Two processes sharing the same namespace will have symlinks with the same inode number. This is how you verify whether two processes are in the same PID namespace, network namespace, etc.

```bash
# Compare the sleep process's namespaces to your shell's namespaces
ls -la /proc/$$/ns/

# Are sleep and your shell in the same PID namespace?
readlink /proc/$SLEEP_PID/ns/pid
readlink /proc/$$/ns/pid
# Expected: same inode number — both processes are in the host PID namespace
```

**Cleanup for this step**:
```bash
kill $SLEEP_PID
wait $SLEEP_PID 2>/dev/null
```

---

## Exercise 2: Signal Delivery — SIGTERM and PID 1 Behavior

This exercise demonstrates why PID 1 signal handling matters for containers.

### Step 2.1 — Register and verify a SIGTERM handler in a shell script

```bash
# Create a script that registers a SIGTERM handler
cat > /tmp/signal-test.sh << 'EOF'
#!/bin/sh
# PID 1 behavior test: register SIGTERM handler

RECEIVED=0

# Register SIGTERM handler
trap 'echo "[PID $$] Caught SIGTERM — starting graceful shutdown"; RECEIVED=1; exit 0' TERM
trap 'echo "[PID $$] Caught SIGINT — exiting"' INT

echo "[PID $$] Running. Send SIGTERM with: kill -TERM $$"
echo "[PID $$] Signal handler registered for SIGTERM"

# Show the caught signal bitmask — bit 14 should be set if SIGTERM is caught
grep SigCgt /proc/$$/status

# Loop waiting for signal
COUNT=0
while [ $RECEIVED -eq 0 ]; do
  sleep 0.5
  COUNT=$((COUNT + 1))
  if [ $COUNT -ge 20 ]; then
    echo "[PID $$] Timeout — no signal received in 10 seconds"
    break
  fi
done

echo "[PID $$] Exiting cleanly"
EOF
chmod +x /tmp/signal-test.sh
```

```bash
# Run the script in the background and send it SIGTERM
/tmp/signal-test.sh &
SCRIPT_PID=$!
sleep 1

# Send SIGTERM
kill -TERM $SCRIPT_PID
wait $SCRIPT_PID 2>/dev/null
echo "Exit code: $?"
```

**What's happening**: The `trap` command installs a signal handler for SIGTERM. The `grep SigCgt /proc/$$/status` line shows the signal bitmask while inside the script — bit 14 (SIGTERM) should be set. When SIGTERM arrives, the shell runs the trap body before exiting. This is what a well-behaved PID 1 entrypoint should do.

**Verification**:
```bash
# Expected output includes:
# "[PID XXXXX] Caught SIGTERM — starting graceful shutdown"
# Exit code: 0
```

---

### Step 2.2 — Demonstrate SIGTERM ignored by shell PID 1 (the Docker stop problem)

```bash
# Launch a container where sh is PID 1 and does NOT handle SIGTERM
# This simulates the broken "shell form" Dockerfile entrypoint

docker run -d --name sigterm-test ubuntu:22.04 \
  sh -c "echo 'Shell is PID 1'; sleep 9999"

# Check what PID 1 is inside the container
docker exec sigterm-test cat /proc/1/cmdline | tr '\0' ' '
# Expected: /bin/sh -c echo 'Shell is PID 1'; sleep 9999

# Check PID 1's signal caught mask
docker exec sigterm-test grep SigCgt /proc/1/status
# SigCgt: 0000000000000000 means NO signal handlers registered
# Bit 14 (SIGTERM) is 0 — SIGTERM will be ignored

# Time how long docker stop takes
time docker stop sigterm-test
# Expected: approximately 10 seconds (the default stop timeout)
```

**What's happening**: The shell has no SIGTERM handler, so SIGTERM is ignored. Docker waits 10 seconds and then sends SIGKILL, which cannot be caught or ignored — the container is force-killed. The `sleep 9999` child process never received SIGTERM either.

```bash
# Now compare with the exec form (application as PID 1)
docker run -d --name sigterm-exec ubuntu:22.04 sleep 9999

# Check PID 1
docker exec sigterm-exec cat /proc/1/cmdline | tr '\0' ' '
# Expected: sleep 9999 — sleep is directly PID 1

# Time this stop — sleep responds to SIGTERM immediately
time docker stop sigterm-exec
# Expected: approximately 0-1 seconds (sleep exits on SIGTERM)

docker rm -f sigterm-test sigterm-exec 2>/dev/null
```

---

### Step 2.3 — Observe zombie processes accumulating

```bash
# Create a script that spawns subprocesses without waiting for them
cat > /tmp/zombie-factory.sh << 'EOF'
#!/bin/sh
echo "[PID $$] Starting zombie factory"

# Spawn 5 child processes that exit immediately
# The parent never calls wait(), so children become zombies
for i in 1 2 3 4 5; do
  (exit 0) &    # subshell exits immediately
  echo "Spawned child for slot $i (PID $!)"
done

echo "Sleeping 10 seconds. Check ps output for zombies."
sleep 10
echo "Parent exiting — zombies will be reparented to PID 1 and reaped"
EOF
chmod +x /tmp/zombie-factory.sh

# Run it
/tmp/zombie-factory.sh &
FACTORY_PID=$!
sleep 1

# Look for zombie processes (state Z) — they will have PPID = $FACTORY_PID
ps -eo pid,ppid,stat,comm | awk -v ppid=$FACTORY_PID '$2==ppid || $3~/Z/{print}'
```

**What's happening**: Each `(exit 0) &` spawns a subshell that exits immediately. The parent shell (zombie-factory.sh) never calls `wait $!` for these children. The kernel keeps their `task_struct` entries as zombies with `stat=Z`, waiting for the parent to call `wait()`. After the parent exits, the kernel re-parents all zombies to PID 1 of the current process namespace (your init system), which calls `wait()` and cleans them up.

```bash
wait $FACTORY_PID 2>/dev/null
```

---

## Exercise 3: Inode Exhaustion on a tmpfs

This exercise creates an inode-exhausted filesystem to produce the "disk full but df -h disagrees" failure mode.

### Step 3.1 — Create a small tmpfs with a limited inode count

```bash
# Create a mount point
sudo mkdir -p /tmp/inode-test

# Mount a 10MB tmpfs with a maximum of 20 inodes
# nr_inodes limits the inode table; size limits block space
sudo mount -t tmpfs -o size=10m,nr_inodes=20 tmpfs /tmp/inode-test

echo "Mounted tmpfs with 10MB space but only 20 inodes"
df -h /tmp/inode-test
df -i /tmp/inode-test
```

**What's happening**: The tmpfs is bounded by two independent limits: 10MB of space (blocks) and 20 inodes (files). We will exhaust the inodes long before exhausting the blocks.

### Step 3.2 — Fill the inode table

```bash
# Create files until ENOSPC — we have only 20 inodes
# tmpfs uses a few inodes internally, so expect to succeed for ~15 files before failure
for i in $(seq 1 25); do
  if touch /tmp/inode-test/file-$i 2>/dev/null; then
    echo "Created file-$i"
  else
    echo "FAILED at file-$i — inode exhaustion"
    break
  fi
done

# Demonstrate the discrepancy
echo ""
echo "=== Block usage (df -h) ==="
df -h /tmp/inode-test

echo ""
echo "=== Inode usage (df -i) ==="
df -i /tmp/inode-test
```

**Verification**:
```bash
# Confirm inode usage is at or near 100%
df -i /tmp/inode-test | awk 'NR==2{print "Inode usage:", $5}'
# Expected: 95% or 100%

# Confirm block usage is near 0%
df -h /tmp/inode-test | awk 'NR==2{print "Block usage:", $5}'
# Expected: 1% or similar — essentially no blocks used

# Confirm new writes fail with ENOSPC
touch /tmp/inode-test/should-fail 2>&1
# Expected: touch: cannot touch '/tmp/inode-test/should-fail': No space left on device
```

### Step 3.3 — Show that deleting a file frees its inode

```bash
# Delete one file and verify an inode is freed
rm /tmp/inode-test/file-5
df -i /tmp/inode-test | awk 'NR==2{print "Free inodes after deletion:", $4}'

# Now you can create a new file
touch /tmp/inode-test/new-file
echo "Successfully created new-file after freeing an inode"
```

**Cleanup**:
```bash
sudo umount /tmp/inode-test
sudo rmdir /tmp/inode-test
```

---

## Exercise 4: Linux Capabilities — Container vs Privileged

This exercise compares the capability sets between a regular Docker container and a privileged one, and attempts syscalls that require specific capabilities.

### Step 4.1 — Compare capability bitmasks

```bash
# Check capabilities of a regular container
echo "=== Regular container capability sets ==="
docker run --rm ubuntu:22.04 grep -E "^Cap(Prm|Eff|Bnd)" /proc/1/status

# Check capabilities of a privileged container
echo ""
echo "=== Privileged container capability sets ==="
docker run --rm --privileged ubuntu:22.04 grep -E "^Cap(Prm|Eff|Bnd)" /proc/1/status
```

**What's happening**: The `CapEff` field is a hex bitmask of the process's effective capabilities — the capabilities currently active for permission checks. A regular container has a reduced set; a privileged container has the full set (`000001ffffffffff` or similar representing all ~40 capabilities).

```bash
# Install capsh in the container to decode the bitmask
echo ""
echo "=== Decoded capabilities in a regular container ==="
docker run --rm ubuntu:22.04 sh -c "
  apt-get install -q -y libcap2-bin 2>/dev/null | tail -1
  capsh --print 2>/dev/null | grep Current
"
```

**Verification**:
```bash
# The regular container should NOT have CAP_SYS_ADMIN (bit 21) or CAP_NET_ADMIN (bit 12)
# Run: printf '%d\n' $((0x<CapEff_value> & (1 << 21)))  # should be 0 for regular container
# Replace <CapEff_value> with the actual hex from the regular container

REGULAR_CAPEFF=$(docker run --rm ubuntu:22.04 grep CapEff /proc/1/status | awk '{print $2}')
echo "Regular container CapEff: 0x$REGULAR_CAPEFF"
printf "Has CAP_NET_ADMIN (bit 12): %d\n" $(( 0x$REGULAR_CAPEFF & (1 << 12) ))
printf "Has CAP_SYS_ADMIN (bit 21): %d\n" $(( 0x$REGULAR_CAPEFF & (1 << 21) ))
# Expected: both 0 — neither capability is in the effective set
```

---

### Step 4.2 — Attempt CAP_NET_ADMIN operations — observe EPERM

```bash
# Attempt to modify a network interface in a regular container
echo "=== Attempting ip link set promisc on in regular container ==="
docker run --rm ubuntu:22.04 sh -c "
  apt-get install -q -y iproute2 2>/dev/null | tail -1
  ip link set lo promisc on 2>&1
  echo 'Exit code: '$?
"
# Expected: RTNETLINK answers: Operation not permitted
# Exit code: 2 (or similar non-zero)

# Same operation in a container with CAP_NET_ADMIN explicitly granted
echo ""
echo "=== Same operation with CAP_NET_ADMIN added ==="
docker run --rm --cap-add=NET_ADMIN ubuntu:22.04 sh -c "
  apt-get install -q -y iproute2 2>/dev/null | tail -1
  ip link set lo promisc on 2>&1
  echo 'Exit code: '$?
  ip link show lo | grep promisc
"
# Expected: exits cleanly; ip link show lo includes PROMISC flag
```

---

### Step 4.3 — Attempt CAP_SYS_ADMIN operations — mount

```bash
# Attempt to mount a tmpfs in a regular container
echo "=== Attempting mount in regular container ==="
docker run --rm ubuntu:22.04 sh -c "
  mkdir -p /mnt/test
  mount -t tmpfs tmpfs /mnt/test 2>&1
  echo 'Exit code: '$?
"
# Expected: mount: /mnt/test: permission denied.
# Exit code: 32

# Same with CAP_SYS_ADMIN
echo ""
echo "=== Same operation with CAP_SYS_ADMIN added ==="
docker run --rm --cap-add=SYS_ADMIN ubuntu:22.04 sh -c "
  mkdir -p /mnt/test
  mount -t tmpfs tmpfs /mnt/test 2>&1
  echo 'Exit code: '$?
  df -h /mnt/test | tail -1
"
# Expected: exit code 0, df shows the tmpfs mounted
```

**What's happening**: The Docker default seccomp profile allows the `mount` syscall (it is not in the blocked list), but the kernel's capability check runs before the syscall executes. Without `CAP_SYS_ADMIN`, the capability check fails and the kernel returns EPERM before the mount operation begins. Adding `--cap-add=SYS_ADMIN` places the capability in the container's permitted and effective sets, and the mount succeeds.

---

### Step 4.4 — Use strace to observe the failing syscall (requires privileged or strace-capable container)

```bash
# Run strace inside a container to see the EPERM at the syscall level
docker run --rm --cap-add=SYS_PTRACE \
  --security-opt seccomp=unconfined \
  ubuntu:22.04 sh -c "
    apt-get install -q -y strace iproute2 2>/dev/null | tail -1
    # Trace only the ioctl and socket syscalls (ip link set uses SIOCSIFFLAGS ioctl)
    strace -e trace=ioctl,socket ip link set lo promisc on 2>&1 | grep -E 'ioctl|EPERM|promisc'
  "
```

**What's happening**: `ip link set lo promisc on` calls the `ioctl()` syscall with the `SIOCSIFFLAGS` request code. Without `CAP_NET_ADMIN`, the kernel returns `-1 EPERM`. strace shows you exactly which syscall failed and with which error, making capability debugging unambiguous.

---

## Exercise 5: Process Lifecycle — fork and exec at the strace Level

### Step 5.1 — Trace fork and exec for a simple command

```bash
# On Linux, strace -f traces all child processes too (follows fork)
# -e trace=process,execve limits output to process-related syscalls

strace -f -e trace=process,execve ls /tmp 2>&1 | head -40
```

**What's happening**: You will see:
1. `execve("/bin/ls", [...], [...])` — the shell calling execve to start ls
2. The ls process making `openat`, `getdents64` etc. syscalls
3. `exit_group(0)` — ls exits with code 0

For commands that fork (like running a shell script), you will see `clone()` calls with flags like `CLONE_VM|CLONE_FS|CLONE_FILES|SIGCHLD`.

```bash
# Trace a command that forks to show COW in action
strace -f -e trace=clone,execve,mmap,mprotect sh -c "sleep 0" 2>&1 | head -60
```

**Verification**:
```bash
# Confirm clone() is used for fork (not the older fork() syscall)
strace -e trace=clone bash -c "exit 0" 2>&1 | grep clone
# Modern kernels use clone3() or clone() with flags instead of fork()
```

---

## Exercise 6: /proc Network Information Without netstat

### Step 6.1 — Read socket state directly from /proc/net

```bash
# Start a process that listens on a port
docker run -d --name net-test -p 8080:8080 \
  python:3.11-alpine python3 -m http.server 8080 2>/dev/null

# Wait for it to start
sleep 2

# Get the PID of the python process inside the container
PYTHON_PID=$(docker inspect net-test --format '{{.State.Pid}}')
echo "Python container PID on host: $PYTHON_PID"

# Read TCP socket state from /proc/<pid>/net/tcp (or /proc/net/tcp on host)
# All addresses are in hex little-endian: 00000000:1F90 = 0.0.0.0:8080
cat /proc/$PYTHON_PID/net/tcp6 2>/dev/null || cat /proc/$PYTHON_PID/net/tcp
```

**What's happening**: `/proc/<pid>/net/tcp` lists all TCP sockets visible in the network namespace of that process. Each line includes the local and remote addresses in hex, the connection state (0A = LISTEN, 01 = ESTABLISHED), and the socket inode number. This is what `ss` and `netstat` read internally.

```bash
# Decode the hex address — 8080 decimal = 0x1F90
printf '%d\n' 0x1F90
# Expected: 8080

docker rm -f net-test 2>/dev/null
```

---

## Cleanup

```bash
# Kill any leftover background processes from this lab
jobs -p | xargs kill 2>/dev/null

# Remove temporary files
rm -f /tmp/signal-test.sh /tmp/zombie-factory.sh

# Remove Docker containers (if any remain)
docker rm -f sigterm-test sigterm-exec net-test 2>/dev/null || true
```

---

## Key Takeaways

1. **/proc is the authoritative source of process truth**: everything the kernel knows about a process — state, memory maps, file descriptors, namespaces, capabilities, signal masks — is available in /proc without any additional tooling. In a container debugging scenario where no tools are installed, /proc is your first and often only resource.

2. **PID 1 signal handling determines container stop latency**: a shell script as PID 1 with no SIGTERM handler causes every pod termination and rolling update to wait the full grace period. Fix this at the Dockerfile level with exec-form ENTRYPOINT or the `exec` shell builtin, not at the Kubernetes level with short grace periods (which just reduces the window for graceful shutdown).

3. **df -h and df -i measure different things**: block exhaustion and inode exhaustion are independent failure modes with identical ENOSPC symptoms. Always check both. Kubernetes's default eviction configuration watches block usage but not inode usage — add `--eviction-hard=nodefs.inodesFree<5%` to the kubelet arguments for production nodes.

4. **UID 0 is necessary but not sufficient for privileged operations**: the capability check in the kernel is orthogonal to the UID check. A container running as root will still receive EPERM for operations that require capabilities dropped by the runtime. Decode the CapEff bitmask with `capsh --decode=<hex>` to determine what the process can actually do, then add only the specific required capability in the pod's securityContext rather than escalating to `privileged: true`.

5. **Zombies are a symptom of missing wait() calls, not a separate problem**: any process that forks children must call wait() to reap them. A shell entrypoint that spawns subprocesses in the background without waiting is a zombie factory. Use tini or dumb-init for any container that runs as PID 1 and is expected to spawn child processes.

6. **strace is the bridge between "permission denied" and understanding why**: when a syscall fails with EPERM, strace shows you exactly which syscall, what arguments, and what error. Without strace you are guessing whether the failure is from a missing capability, a seccomp filter, an AppArmor profile, or a MAC policy. The output of `strace -e trace=ioctl,open,socket <command>` narrows the failure to a single line.
