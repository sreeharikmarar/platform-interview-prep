# Linux Namespaces and cgroups

## What you should be able to do

- Explain each of the 8 Linux namespace types, what each one isolates, and what happens inside a container when they are combined.
- Trace how `resources.limits.memory: 256Mi` in a Pod spec translates to a kernel cgroup `memory.max` write, what the kernel does when the limit is approached, and why the OOM kill targets a specific process.
- Explain CPU throttling via the CFS bandwidth controller — how a container using 40% average CPU can still be throttled — and how to identify and fix it.
- Explain cgroups v1 vs v2: structural differences, why v2 simplifies resource accounting, and when it matters for Kubernetes (1.25+, Docker-in-Docker, nested containers).

## Mental Model

Linux provides process isolation through two orthogonal kernel primitives: namespaces and cgroups. They solve different problems and are deliberately independent of each other. A namespace answers the question "what can a process see?" — it restricts the visibility of global resources like process IDs, network interfaces, mount points, and hostnames. A cgroup answers the question "how much can a process use?" — it imposes quantitative limits on CPU time, memory, I/O bandwidth, and device access. A container is the intersection of both: a process tree that can only see what its namespaces allow and can only consume what its cgroups permit. Understanding this separation is the key to reasoning about isolation failures. A container escaping its CPU limit is a cgroup problem. A container seeing the host's process list is a namespace problem. They have entirely different debugging paths.

Namespaces are created by the `clone()` or `unshare()` system calls with flag combinations like `CLONE_NEWPID | CLONE_NEWNET | CLONE_NEWNS`. Each namespace type has an independent lifetime tracked by a file descriptor in `/proc/<pid>/ns/`. When two processes have the same inode number under `/proc/<pid>/ns/pid`, they are in the same PID namespace. When you run `kubectl exec` into a container, the container runtime calls `nsenter()` to join the existing namespaces of the container's init process rather than creating new ones. This is how `kubectl exec` shares the container's filesystem, network, and process tree without launching a new container.

cgroups work through a virtual filesystem. In cgroups v1, each resource controller (`memory`, `cpu`, `blkio`, `cpuset`, `devices`) has its own independent hierarchy rooted at `/sys/fs/cgroup/<controller>/`. You create a group by `mkdir`ing a directory in that hierarchy and write resource limits to pseudo-files like `memory.limit_in_bytes` or `cpu.cfs_quota_us`. Any process you write to `cgroup.procs` in that directory is subject to those limits. In cgroups v2, all controllers share a single unified hierarchy rooted at `/sys/fs/cgroup/`. This unification matters because in v1 you could have a process assigned to group A in the memory controller but group B in the CPU controller — leading to accounting inconsistencies that made nested virtualization and Docker-in-Docker unreliable. Kubernetes 1.25+ uses cgroups v2 by default on compatible nodes, and the kubelet's `cgroupDriver` must match what the container runtime expects.

overlayfs is the third kernel primitive that completes the container picture. It is not a namespace or a cgroup — it is a union-mount filesystem driver. A container image is stored as a stack of read-only layers (the `lower` directories), the container runtime creates a thin read-write layer on top (the `upper` directory), and overlayfs presents a merged view to the container process. When the process reads a file, overlayfs serves it from the highest layer that contains it. When the process writes to a file that exists only in a lower layer, overlayfs performs a copy-up: it copies the entire file from the lower layer to the upper layer before allowing the write. This copy-up is at file granularity, not block granularity — writing one byte to a 100 MB binary triggers a full 100 MB copy-up, which is the source of the large-file write performance problem in containers.

## Key Concepts

- **PID namespace** (`CLONE_NEWPID`): Isolates process IDs. The first process in a new PID namespace gets PID 1 and becomes the init of that namespace. Processes in child namespaces are visible in the parent (host), but processes in the parent are invisible from the child. If PID 1 in the container dies, all other processes in that PID namespace receive SIGKILL. This is why container runtimes use a minimal init process (tini, dumb-init) rather than running applications directly as PID 1.

- **Mount namespace** (`CLONE_NEWNS`): Isolates the filesystem mount table. Each process sees its own view of mounted filesystems. Critically, the mount namespace is distinct from the actual filesystem data — two processes in different mount namespaces can mount different filesystems at `/`, but they share the same underlying kernel VFS inodes. Mount propagation modes (shared, slave, private, unbindable) control whether mount/unmount events in one namespace propagate to others. Kubernetes uses private mount propagation by default so container mounts don't leak to the host.

- **Network namespace** (`CLONE_NEWNET`): Isolates network stack: network interfaces, routing tables, iptables chains, socket tables, and port bindings. Each new network namespace gets only a loopback interface. A container's `eth0` is a veth (virtual Ethernet) pair: one end lives in the container's network namespace, the other lives on the host (or in the Pod's shared network namespace in Kubernetes). Separate network namespaces means two containers can both bind port 8080 without conflict.

- **UTS namespace** (`CLONE_NEWUTS`): Isolates hostname and NIS domain name (from UNIX Time-sharing System). Gives each container its own hostname returned by `gethostname()`. This is why `hostname` inside a container returns the Pod name rather than the node name.

- **IPC namespace** (`CLONE_NEWIPC`): Isolates System V IPC mechanisms: message queues, semaphores, and shared memory segments. Also isolates POSIX message queues. Prevents containers from communicating through shared memory across namespace boundaries. Kubernetes Pods share the IPC namespace across containers in the same Pod by default (controlled by `spec.shareProcessNamespace` and IPC namespace settings), enabling sidecar-to-app shared memory communication.

- **User namespace** (`CLONE_NEWUSER`): Isolates UID/GID number spaces. A process can have UID 0 (root) inside a user namespace while mapping to an unprivileged UID (e.g., 100000) on the host. UID mapping is defined in `/proc/<pid>/uid_map` and managed by `newuidmap`/`newgidmap` binaries. Rootless containers (podman, rootless containerd/nerdctl) rely on user namespaces so a non-root user can run containers. Kubernetes 1.30+ supports user namespaces for Pods via `spec.hostUsers: false`.

- **Cgroup namespace** (`CLONE_NEWCGROUP`): Isolates the cgroup root. A process in a cgroup namespace sees its own cgroup root directory as `/`, so it cannot traverse the full cgroup hierarchy to discover its sibling containers or read host-level resource statistics. This prevents container escape via the cgroup filesystem.

- **Time namespace** (`CLONE_NEWTIME`): Isolates the `CLOCK_MONOTONIC` and `CLOCK_BOOTTIME` clocks. Added in Linux 5.6. Allows a container to have a different boot time than the host. Used for container checkpoint/restore (CRIU) to preserve uptime values across migration.

- **unshare vs nsenter**: `unshare(1)` creates new namespaces for the current process and its children (calls `unshare(2)` which calls `clone(2)` with new-namespace flags, then exec's the target program). `nsenter(1)` joins existing namespaces of a running process by opening the `/proc/<pid>/ns/<type>` file descriptor and calling `setns(2)`. This is the mechanism container runtimes use for `exec` into running containers: open `/proc/<container-pid>/ns/pid`, call `setns()`, then `fork()` the shell process.

- **cgroups v1**: Each resource controller has its own independent filesystem hierarchy under `/sys/fs/cgroup/<controller>/`. A process can be in a different cgroup group for each controller. The `cpu` controller uses `cpu.cfs_quota_us` (quota per period in microseconds) and `cpu.cfs_period_us` (period, default 100000 = 100ms). The `memory` controller uses `memory.limit_in_bytes`. Writing a PID to `cgroup.procs` in a directory subjects it to that directory's limits. Hierarchies are independent — no single "current group" concept.

- **cgroups v2**: Unified hierarchy under `/sys/fs/cgroup/`. All controllers are enabled at one root and a process is in exactly one group for all controllers simultaneously. The `cpu` controller uses `cpu.max` in the format `<quota> <period>` (e.g., `50000 100000` = 50ms per 100ms = 50% CPU). The `memory` controller uses `memory.max`. Adds `memory.current`, `memory.events`, `cpu.stat` with throttled time. Required for proper resource attribution in nested container scenarios. Kubernetes uses the `cgroup2fs` mount type when `cgroupDriver: systemd` and the node runs systemd with unified cgroup hierarchy.

- **Kubernetes cgroup hierarchy (cgroupv2, systemd driver)**: kubelet creates a slice for all pods at `kubepods.slice/`. Guaranteed QoS pods go under `kubepods-guaranteed.slice/`. Burstable pods go under `kubepods-burstable.slice/`. BestEffort pods go under `kubepods-besteffort.slice/`. Each pod gets a slice like `kubepods-burstable-pod<uid>.slice/` and each container gets a scope like `cri-containerd-<container-id>.scope`. The kubelet writes `memory.max` and `cpu.max` to the container scope and `memory.max = max` (unlimited) to the pod slice with a tighter `cpu.max` sum at the pod level. On cgroupv1 with cgroupfs driver the paths are `/sys/fs/cgroup/memory/kubepods/besteffort/pod<uid>/<container-id>/memory.limit_in_bytes`.

- **memory.max and OOM kill chain**: When a process allocates memory, the kernel checks the cgroup's `memory.current` against `memory.max`. If current is below max but close, the kernel may reclaim page cache (drop file-backed pages, swap anonymous pages if swap is configured). If reclaim cannot free enough memory and allocation would exceed `memory.max`, the kernel OOM killer runs within the cgroup scope. The kernel selects the victim using an OOM score — the highest score wins. The OOM score is `oom_score_adj + oom_score`, where `oom_score` is proportional to RSS + page cache. Kubernetes sets `oom_score_adj` based on QoS: Guaranteed pods get `-997` (very low, rarely killed), Burstable pods get a proportional score, BestEffort pods get `1000` (always killed first).

- **CFS bandwidth controller and CPU throttling**: The Completely Fair Scheduler (CFS) enforces CPU limits via the bandwidth controller. Each cgroup has a quota (microseconds of CPU per period) and a period (default 100ms = 100000 µs). Setting `cpu.max = 50000 100000` means the container can consume 50ms of CPU time every 100ms period. Throttling occurs at period boundaries: if the container has exhausted its quota partway through a period, all its threads are blocked until the next period starts. This means a container averaging 40% CPU can still be heavily throttled if its CPU usage is bursty — it consumes its 50ms quota in the first 50ms of the period and is throttled for the remaining 50ms. The metric `container_cpu_throttled_periods_total / container_cpu_usage_seconds_total` reveals this. Increase the period (to 500ms or 1s) or raise the limit to match peak (not average) usage.

- **overlayfs internals**: The overlay filesystem presents a merged view from lower directories (read-only image layers) and an upper directory (container read-write layer). VFS calls on the merged view are intercepted by the overlay driver. Reads check each layer from upper to lowest. The first match wins. Writes to files existing only in lower layers trigger `copy_up()`: the kernel copies the full file from the lower layer to the upper layer, then allows the write. `copy_up()` is atomic (writes to a temp file, then renames) to prevent torn state. Directory entries are merged — a directory can exist in both lower and upper, with the upper directory's entries taking precedence. File deletion is represented by "whiteout" entries (special device files with `0:0` device number) in the upper layer that mask the corresponding lower-layer file.

- **User namespaces and rootless containers (UID mapping)**: The `/proc/<pid>/uid_map` file contains triplets: `<container-uid-start> <host-uid-start> <count>`. A mapping of `0 100000 65536` means container UID 0 maps to host UID 100000, UID 1 maps to 101000, etc. `newuidmap <pid> <mappings...>` writes these mappings (requires that the host UID range is in `/etc/subuid` for the calling user). Inside the user namespace, `setuid(0)` and `setcap(...)` work without host root privileges. The kernel enforces that capabilities granted inside a user namespace do not apply outside it — so root inside the container cannot directly modify host files it doesn't own. The security model depends on the UID mapping: a poorly configured mapping that maps container root to host root defeats the entire protection.

## Internals

### Namespace Lifecycle: clone(), nsenter(), and Mount Propagation

When a container runtime creates a container, it calls `clone(2)` with a combination of namespace flags. For a typical OCI container: `CLONE_NEWPID | CLONE_NEWNS | CLONE_NEWNET | CLONE_NEWUTS | CLONE_NEWIPC`. The `CLONE_NEWUSER` flag is omitted in privileged container runtimes running as root. The new process starts in fresh namespaces with no network interfaces (except loopback), no mounts (inheriting from the runtime's mount namespace until the runtime sets up the container's rootfs), PID 1 identity, and its own hostname.

The container runtime then:

1. Sets up the root filesystem by calling `pivot_root(2)` or `chroot(2)` to switch the container process's mount namespace view to the container's rootfs (an overlayfs mount of the image layers).
2. Creates veth pairs: `ip link add veth0 type veth peer name eth0`. Moves one end into the container's network namespace: `ip link set eth0 netns <container-netns>`.
3. Configures the network: assigns IPs, sets up routes and iptables rules on the host side, brings up `eth0` inside the container namespace.
4. In Kubernetes, the CNI plugin handles steps 2-3 using the network namespace path `/proc/<container-pid>/ns/net`.

Mount propagation modes are set per-mount and control namespace boundary behavior. `MS_SHARED` (shared): a mount/unmount in one namespace propagates to peer namespaces sharing the same mount point. `MS_SLAVE` (slave): a mount created in the master namespace propagates into this namespace, but mounts in this namespace don't propagate out. `MS_PRIVATE` (private): mount/unmount events stay local — they never propagate in or out. Container runtimes use `MS_SLAVE` or `MS_PRIVATE` for the container's root mount to prevent container mounts from leaking to the host. Kubernetes uses `MountPropagation` in volume specs to allow optional sharing (`HostToContainer` = slave, `Bidirectional` = shared) for use cases like FUSE filesystems and CSI drivers.

User namespace UID mapping requires two kernel calls: `newuidmap <pid> 0 <host-start> <count>` to write `/proc/<pid>/uid_map` and `newgidmap` for GIDs. These are setuid binaries because writing uid_map requires privilege on the target PID or explicit allowance via `/etc/subuid`. The kernel validates that the host UID range specified in the mapping is owned by the calling user per `/etc/subuid`. After mapping is established, the container process can call `setuid(0)` and acquire ambient capabilities (`SETUID`, `SETGID`, `SYS_ADMIN` within the user namespace scope), enabling container-level root operations without host privilege escalation.

### cgroup Enforcement: memory reclaim, OOM, CFS throttling, and kubelet driver

The memory enforcement path starts at allocation. When a process calls `malloc()` which eventually calls `mmap(2)` or `brk(2)`, the kernel checks whether the resulting `memory.current` would exceed `memory.max` in any ancestor cgroup. If it would, the kernel first attempts direct reclaim: it tries to free page cache pages belonging to files accessed by processes in this cgroup, writes dirty pages to disk if needed, and swaps anonymous pages if swap is enabled. Only when reclaim fails to free sufficient memory does the kernel OOM-kill a process within the cgroup.

The OOM killer selects the victim by computing a score for each process: `oom_score = (RSS + swap + page_tables) as a fraction of total memory, scaled to 0-1000`. This score is added to `oom_score_adj` (range -1000 to +1000, set by the process). Kubernetes kubelet sets `oom_score_adj` values: `-997` for Guaranteed QoS containers (rarely killed), a value between `2` and `999` proportional to memory usage for Burstable containers, and `1000` for BestEffort containers (killed first). This means in a memory-pressured node, BestEffort pods die first, then Burstable, and Guaranteed pods are the last resort. When an OOM kill happens, the kernel logs it to the kernel ring buffer (`dmesg -T | grep -i "oom"`) and kubelet translates the container exit code (137 = killed by signal 9) to `OOMKilled` in the Pod status.

CPU enforcement via CFS bandwidth works at the scheduler level. The CFS scheduler tracks CPU time consumed by each cgroup entity in nanoseconds. At each period boundary (default 100ms), the per-cgroup quota is refilled. If a cgroup's threads have consumed the full quota before the period ends, the scheduler marks all threads in that cgroup as throttled: they are removed from the run queue until the next period. No preemption is needed — the threads voluntarily yield when the kernel's CFS scheduler records their CPU time exhausted against the quota. The key insight: `quota_per_period / period = CPU fraction`. If `cpu.max = 100000 100000` that is exactly 1 CPU, regardless of how many CPUs the node has. A container with `cpu.max = 50000 100000` gets 0.5 CPUs but if its workload is bursty — consuming 50ms in the first 50ms of each 100ms period — it will be throttled 50% of the time even at 50% average utilization.

The kubelet's `cgroupDriver` field in `/var/lib/kubelet/config.yaml` must match the container runtime's cgroup driver. Two options: `cgroupfs` means the kubelet directly creates directories under `/sys/fs/cgroup/`. `systemd` means the kubelet uses systemd D-Bus API to create systemd scopes and slices, which then map to cgroup directories. The `systemd` driver is required on nodes where systemd owns the cgroup hierarchy (standard on modern Linux with cgroups v2). Mismatch between kubelet and runtime drivers causes containers to be placed in incorrect cgroup paths, making resource accounting incorrect and sometimes causing OOM kills at the wrong cgroup level.

### overlayfs Kernel Internals: VFS Call Path and Copy-on-Write

The overlayfs filesystem registers VFS operation tables: `inode_operations`, `file_operations`, and `super_operations`. When a process opens a file on the overlay-mounted path, VFS calls `overlay_lookup()` which searches for the name first in the upper directory, then in each lower directory in order. If found in upper, the inode from upper is returned directly. If found only in lower, a synthetic inode is created that proxies operations to the lower file.

When a process writes to a file that exists only in a lower layer, VFS calls `overlay_open()` for write, which checks whether the upper directory contains a copy. If not, `copy_up()` is triggered synchronously before the write is allowed to proceed. `copy_up()` steps:

1. `mkdir -p` the parent directory chain in the upper layer, preserving metadata (permissions, ownership, xattrs).
2. `open(O_RDONLY)` the source file in the lower layer.
3. `open(O_WRONLY | O_CREAT)` a temp file in the upper layer's parent directory.
4. `sendfile()` or `copy_file_range()` to efficiently copy the full file content from lower to upper temp.
5. `fsync()` the temp file to ensure durability.
6. `rename()` the temp file to the final name in upper (atomic).
7. `chmod()`/`chown()` to replicate original metadata.

The critical detail: step 4 copies the entire file, not just the changed blocks. This is file-level copy-on-write, not block-level. A 1-byte append to a 500 MB binary triggers a 500 MB copy-up. This is why large dependency installations inside a running container are slow, and why Docker layer caching (baking the large file into the image rather than writing it at runtime) is so important for performance.

Directory handling is different from files. Overlayfs merges directory entries: an `ls` on a directory that exists in both upper and lower shows the union of both. Deletes are represented as whiteout entries: deleting `/app/config.yaml` creates `upper/app/config.yaml` as a character device with `0:0` major/minor numbers. The overlay lookup code treats any such whiteout as masking the corresponding lower-layer entry. Opaque directories (created by `mkdir` in upper over a lower directory) carry the `trusted.overlay.opaque: y` xattr, signaling that lower-layer contents of that directory should not be visible.

## Architecture Diagram

```
  Container Process (PID 42 in container = PID 8221 on host)
  ┌────────────────────────────────────────────────────────────┐
  │  NAMESPACES (what the process can see)                     │
  │                                                            │
  │  PID ns:  sees PID 1..N (its own tree only)                │
  │  Net ns:  sees eth0 (veth end), lo only                    │
  │  Mnt ns:  sees overlayfs rootfs, /proc, /sys (container)   │
  │  UTS ns:  hostname = pod-name                              │
  │  IPC ns:  isolated SysV IPC, POSIX MQ                      │
  │  User ns: UID 0 inside → UID 100000 on host (if rootless)  │
  └────────────────────────────────────────────────────────────┘

  CGROUPS (how much the process can use)
  ┌────────────────────────────────────────────────────────────┐
  │  /sys/fs/cgroup/kubepods.slice/                            │
  │    kubepods-burstable.slice/                               │
  │      kubepods-burstable-pod<uid>.slice/     ← Pod slice    │
  │        cri-containerd-<container-id>.scope/ ← Container    │
  │          memory.max         = 268435456 (256Mi)            │
  │          memory.current     = 134217728 (live RSS)         │
  │          cpu.max            = 100000 100000 (1 CPU)        │
  │          cpu.stat           throttled_usec = 12340000      │
  └────────────────────────────────────────────────────────────┘

  OVERLAYFS (what the process sees as the filesystem)
  ┌────────────────────────────────────────────────────────────┐
  │  merged/                  ← container sees this            │
  │  ├─ upper/ (rw layer)     ← writes land here               │
  │  │   └─ app/config.yaml   ← copy-up from lower if written  │
  │  ├─ lower[0]/ (image layer N, RO)                          │
  │  ├─ lower[1]/ (image layer N-1, RO)                        │
  │  ├─ lower[2]/ (base layer, RO)                             │
  │  └─ work/                 ← overlayfs internal temp dir     │
  └────────────────────────────────────────────────────────────┘

  NETWORK NAMESPACE wiring
  ┌────────────────────────────────────────────────────────────┐
  │  Host network namespace      Container network namespace    │
  │  ┌───────────────────┐       ┌───────────────────────┐     │
  │  │ veth0 (host end)  │──────▶│ eth0 (container end)  │     │
  │  │ 10.244.0.1        │ pair  │ 10.244.0.4/24         │     │
  │  └───────────────────┘       └───────────────────────┘     │
  │          │                                                  │
  │  bridge: cni0 (10.244.0.0/24)                              │
  │  iptables DNAT/MASQUERADE rules for Pod IP routing          │
  └────────────────────────────────────────────────────────────┘

  OOM Kill decision tree (per-cgroup memory pressure)
  ┌────────────────────────────────────────────────────────────┐
  │  malloc() → mmap(2) → kernel checks memory.current         │
  │                                  │                         │
  │                          current < max?                     │
  │                         /            \                      │
  │                        yes            no                    │
  │                         │              │                    │
  │                      allow       attempt reclaim            │
  │                                        │                    │
  │                                  reclaim OK?                │
  │                                 /         \                 │
  │                                yes         no               │
  │                                 │           │               │
  │                              allow     OOM kill             │
  │                                      (highest oom_score     │
  │                                       in cgroup wins)       │
  └────────────────────────────────────────────────────────────┘
```

## Failure Modes & Debugging

### 1. CPU Throttling at 40% Average Utilization

**Symptoms**: Application reports high latency (p99 spikes) but CPU usage in dashboards shows only 30-50% of the limit. Container never approaches the CPU limit by average metrics. Prometheus shows `container_cpu_throttled_periods_total` climbing. Users report timeout errors that correlate with periodic spikes, not sustained load. The application may log "context deadline exceeded" or "request timed out" at regular intervals (every 100ms is a hint).

**Root Cause**: CFS bandwidth controller throttles at period granularity (default 100ms). A container with `cpu: 500m` gets `cpu.max = 50000 100000` — it can use 50ms of CPU per 100ms period. If the application is bursty (spawns goroutines, parses a request, then idles), it may consume its 50ms quota in the first 20ms of the period, be throttled for the remaining 80ms, then start fresh. Average utilization shows 20% but the application is blocked for 80ms per period. High-cardinality workloads (Go GC pauses, JVM garbage collection, Python GIL release points) are particularly prone to this.

**Blast Radius**: Limited to the throttled container. But in a microservice chain, one throttled service causes latency spikes that cascade via timeout propagation to upstream callers. A Kubernetes liveness probe that calls the application during a throttled window may fail and trigger unnecessary pod restarts.

**Mitigation**:
- Increase `cpu.cfs_period_us` (the period): a longer period (e.g., 500ms) allows the application to use its quota as a larger burst. Set `--cpu-cfs-period` on the kubelet. Note: increasing period to 1s reduces scheduler responsiveness for all workloads.
- Increase the CPU limit to accommodate peak burst, not just average usage. Profile the application's CPU usage at the microsecond scale to understand burst width.
- Use `requests` to express baseline need but increase `limits` to 2-3x requests for bursty workloads.
- Disable CFS bandwidth throttling entirely (`--cpu-cfs-quota=false` on kubelet) for latency-sensitive workloads — this allows bursting to available node capacity at the cost of noisy-neighbor risk.

**Debugging**:
```bash
# Check throttling ratio for a specific container
NAMESPACE=my-ns
POD=my-pod
CONTAINER=my-container

# Via Prometheus (best method)
# container_cpu_throttled_periods_total / container_cpu_periods_total > 0.25 is concerning
kubectl exec -n monitoring deploy/prometheus -- \
  curl -sg 'http://localhost:9090/api/v1/query?query=rate(container_cpu_throttled_periods_total{namespace="'$NAMESPACE'",pod="'$POD'"}[5m])/rate(container_cpu_periods_total{namespace="'$NAMESPACE'",pod="'$POD'"}[5m])' \
  | jq '.data.result[].value[1]'

# Direct cgroup read (on the node)
# Find the container's cgroup path
CGROUP_PATH=$(find /sys/fs/cgroup -name "cpu.stat" | \
  xargs grep -l "$(docker inspect <container-id> --format '{{.Id}}')" 2>/dev/null | head -1 | xargs dirname)

cat "${CGROUP_PATH}/cpu.stat" | grep -E "throttled"
# throttled_usec / usage_usec ratio reveals severity

# Confirm cpu.max setting
cat "${CGROUP_PATH}/cpu.max"
# Output format: <quota> <period>   e.g. 50000 100000

# On a Kubernetes node, find container cgroup path via containerd
# containerd stores cgroup path in container metadata
crictl inspect <container-id> | jq '.info.cniResult, .info.runtimeSpec.linux.cgroupsPath'
```

---

### 2. OOM Kill Hitting the Wrong Container (Sidecar Killed Instead of App)

**Symptoms**: `kubectl describe pod` shows a sidecar container (envoy, fluentd, datadog-agent) in `OOMKilled` state with exit code 137 but the application container is healthy and well within its memory limit. The sidecar was using well below its own limit when killed. This recurs every few hours or under specific traffic patterns.

**Root Cause**: OOM kills are scoped to the cgroup that exceeded its limit, but within a Pod, the kubelet creates both a pod-level cgroup and container-level cgroups. In cgroupv1, the memory controller's `memory.limit_in_bytes` is set at the container level independently. However, the OOM killer selects victims based on `oom_score`, not on which container caused the pressure. If the application container has `oom_score_adj` set lower (Guaranteed QoS: -997) and the sidecar has a higher score (Burstable QoS: proportional score), the sidecar will be killed even if the app container caused the memory pressure. A secondary cause: the sidecar's own memory limit is set too low relative to its actual peak usage (e.g., Envoy's heap under high connection count).

**Blast Radius**: Sidecar restart in the same Pod. Depending on the sidecar's role: if it is an Envoy proxy (Istio), the pod loses network connectivity briefly (iptables rules drop traffic without proxy). If it is a log shipper, buffered logs may be lost. The application container is not restarted — only the OOM-killed container restarts.

**Mitigation**:
- Set sidecar containers to Guaranteed QoS (set `requests == limits` for CPU and memory) to lower their OOM score to -997, preventing them from being killed before the app.
- Measure the sidecar's actual peak memory usage under production load using `kubectl top`, Prometheus `container_memory_working_set_bytes`, or `cat /sys/fs/cgroup/.../memory.current`. Set limits at 2x the observed p99 peak.
- For Istio Envoy sidecars: tune `resources.limits.memory` to at least 256Mi for moderate traffic; Envoy's heap grows with connection count (roughly 5-10 KB per downstream connection plus routing table memory).

**Debugging**:
```bash
# Check OOM kill events from the kernel ring buffer on the node
kubectl debug node/<node-name> -it --image=ubuntu -- dmesg -T | grep -i "oom\|killed process" | tail -20

# Check each container's OOM score and adj (run inside the pod/on node)
# oom_score_adj: -997 = Guaranteed, 0-999 = Burstable, 1000 = BestEffort
for pid in $(ls /proc/ | grep -E '^[0-9]+$'); do
  adj=$(cat /proc/$pid/oom_score_adj 2>/dev/null)
  score=$(cat /proc/$pid/oom_score 2>/dev/null)
  comm=$(cat /proc/$pid/comm 2>/dev/null)
  [ -n "$adj" ] && echo "PID $pid ($comm): adj=$adj score=$score"
done | sort -t= -k3 -rn | head -20

# Memory usage per container (from cgroup)
kubectl exec -n <ns> <pod> -c <container> -- cat /sys/fs/cgroup/memory.current 2>/dev/null \
  || kubectl exec -n <ns> <pod> -c <container> -- cat /sys/fs/cgroup/memory/memory.usage_in_bytes

# Pod-level OOM events
kubectl get events -n <ns> --field-selector reason=OOMKilling
kubectl describe pod <pod> -n <ns> | grep -A5 "OOMKilled\|Last State"
```

---

### 3. overlay2 Inode Exhaustion

**Symptoms**: Container fails to write files with `No space left on device` (errno ENOSPC) even though `df -h` shows free disk space. `kubectl exec` into the container and `touch /tmp/test` fails. The node reports healthy disk usage in `kubectl describe node`. New pod scheduling may start failing on the affected node.

**Root Cause**: overlayfs stores directory entries in the upper layer as regular filesystem files on the host. The host filesystem (commonly ext4 or xfs formatted at ~256 inode-per-4KB-block density) has a fixed inode count set at format time. Each file and directory in any container's upper layer or image layer consumes one inode from the host filesystem's inode table, regardless of the file's size. A container running a package manager or compilation job that creates hundreds of thousands of small files (node_modules, Go build cache, Python `.pyc` files) exhausts the host's inodes even though total bytes are modest.

**Blast Radius**: The affected node cannot start new containers or allow existing containers to create new files. Pods on the node may start failing liveness checks if they try to write temp files. `kubelet` itself may fail to write status files. The node may eventually be marked `NotReady` if kubelet's own writes fail.

**Mitigation**:
- Format the container runtime's data directory (`/var/lib/containerd` or `/var/lib/docker`) on a dedicated filesystem with a high inode density. For ext4: `mkfs.ext4 -i 4096 /dev/sdX` (one inode per 4KB = maximum density). For xfs: inode count grows dynamically — xfs does not fix inodes at format time and is preferred for container workloads.
- Use multi-stage builds to discard build artifacts (node_modules, Go module cache, build tools) before the final image layer. The production image layer contains only the compiled binary, not the source tree.
- Set `ephemeral-storage` limits on containers that are known to generate many files, so the kubelet evicts them before they exhaust host inodes.
- Monitor inode usage per node: `df -i /var/lib/containerd` on each node. Alert at 80% inode usage.

**Debugging**:
```bash
# Check inode usage on the node's overlay storage device
# Run on the node via kubectl debug or SSH
df -i /var/lib/containerd
# Look at IUse% column — if 100%, inodes are exhausted even if disk is not full

# Find which directories contain the most inodes
find /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/ \
  -maxdepth 5 -type d | xargs -I{} sh -c 'echo "$(ls -1 {} | wc -l) {}"' 2>/dev/null \
  | sort -rn | head -20

# Per-container inode count via pod ephemeral storage metrics
kubectl top pod <pod> -n <ns> --containers 2>/dev/null
# or from metrics-server: storage.ephemeral is reported when enabled

# Check node for inode-exhaustion related kernel messages
kubectl debug node/<node> -it --image=ubuntu -- sh -c \
  "dmesg -T | grep -i 'no space\|inode\|ENOSPC' | tail -20"

# Check the filesystem type (xfs preferred over ext4 for containers)
kubectl debug node/<node> -it --image=ubuntu -- sh -c \
  "stat -f /host/var/lib/containerd"
```

---

### 4. Rootless Container Permission Errors (User Namespace UID Mapping)

**Symptoms**: Running a container with `runAsNonRoot: true` or `runAsUser: 1000` fails with `permission denied` when the container tries to read its own image files. Or: a rootless podman or nerdctl container exits with `newuidmap: write to uid_map failed: Operation not permitted`. Or: a container writes a file as UID 1000 but the file appears owned by UID 100999 on the host, confusing volume permission checks.

**Root Cause**: User namespace UID mapping must be configured before the container process runs. The `newuidmap` binary (setuid root) is responsible for writing the UID mapping into `/proc/<pid>/uid_map`. It only permits mappings that are allocated to the calling user in `/etc/subuid`. If `/etc/subuid` does not contain an entry for the container runtime user, or if the requested UID range is outside the allocated range, `newuidmap` fails. A secondary cause: a volume mounted from the host with files owned by host UID 1000 is accessed from a container where host UID 1000 maps to container UID 100999 — the container process running as container UID 0 (= host UID 100000) does not own those files.

**Blast Radius**: Limited to rootless container configurations. In Kubernetes clusters with `hostUsers: false` (user namespace for pods, Kubernetes 1.30+), incorrectly configured node `/etc/subuid` prevents pods from starting. In development environments using rootless podman or nerdctl, users cannot start any containers.

**Mitigation**:
- On each node, configure `/etc/subuid` and `/etc/subgid` for the container runtime user: `containerd:100000:65536` allocates UID 100000-165535 for the containerd user's containers.
- Verify `newuidmap` and `newgidmap` are installed and setuid: `ls -la $(which newuidmap)` should show `-rwsr-xr-x`.
- For volume permissions: either use init containers to `chown` files to the expected container UID, or use `fsGroup` in the Pod spec to have the kubelet `chown` the volume to the specified GID before the container starts.
- For Kubernetes user namespace pods, ensure the node is running Linux 5.12+ (required for user namespace support in containers with seccomp and userns together).

**Debugging**:
```bash
# Check /etc/subuid configuration
cat /etc/subuid
# Expected format: <user>:<start-uid>:<count>  e.g. containerd:100000:65536

# Verify newuidmap is installed and setuid
ls -la $(which newuidmap) $(which newgidmap)
# Should show -rwsr-xr-x (setuid bit set)

# Check if user namespace creation is allowed for unprivileged users
cat /proc/sys/kernel/unprivileged_userns_clone
# 1 = allowed, 0 = denied (must be 1 for rootless containers)
# On some distros this is controlled via sysctl user.max_user_namespaces

# Test UID mapping manually
unshare --user --map-root-user id
# Should return: uid=0(root) gid=0(root) groups=0(root),...
# If this fails, user namespace creation is disabled on this kernel

# Check container's UID map after start
PID=$(crictl inspect <container-id> | jq -r '.info.pid')
cat /proc/$PID/uid_map
# Format: container-uid-start  host-uid-start  count
# e.g.:   0  100000  65536

# For volume ownership issues
kubectl exec -n <ns> <pod> -- id
kubectl exec -n <ns> <pod> -- stat /path/to/volume
# Cross-reference file uid with /proc/<pid>/uid_map to find host uid
```
