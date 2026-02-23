# Linux Processes, Signals, and the Filesystem

## What you should be able to do

- Explain the fork/exec/clone syscall sequence at the kernel level, including copy-on-write page table semantics, address space replacement, and how namespace flags passed to clone() establish isolation boundaries.
- Explain why `docker stop` takes 10 seconds and what the kernel does with signal delivery when PID 1 is a shell wrapper rather than the actual application process.
- Diagnose inode exhaustion independently from block exhaustion, explain why `df -h` shows free space while writes fail, and identify which filesystem types are vulnerable.
- Reason about Linux capabilities as fine-grained decomposition of root privilege, understand which capabilities are dropped by the container runtime by default, and explain the EPERM failure mode when a workload assumes capabilities it does not have.

## Mental Model

The Linux kernel exposes all system resources through three unified abstractions: the process table, the virtual filesystem, and the permission model. Everything a container does — starting a process, reading a file, opening a network socket, setting a timer — is ultimately one or more syscalls against these three abstractions. The container runtime does not create a new operating system; it calls `clone()` with namespace flags to give the process its own view of the process table (PID namespace), filesystem hierarchy (mount namespace), network stack (network namespace), and hostname (UTS namespace). The kernel mechanisms underneath remain identical. Understanding what those mechanisms are at the syscall level is what distinguishes engineers who can debug container behavior from those who can only describe it.

Process creation in Linux is built on two primitives: `fork()`, which duplicates the calling process, and `exec()`, which replaces the duplicated process's address space with a new program. These are separate operations by design. `fork()` creates an exact copy of the parent, but uses copy-on-write (COW) semantics: both parent and child initially share the same physical pages, marked read-only. A write fault on any shared page causes the kernel to allocate a new physical page, copy the content, and remap it. This makes `fork()` fast regardless of the process's RSS because no data is copied until modified. `exec()` then calls `execve()` which replaces the entire address space — code, stack, heap — with the new binary's pages loaded from disk (via the page cache). The process retains the same PID but the running program is completely replaced. The `clone()` syscall generalizes both: it creates a new execution context and accepts flags that control which kernel namespaces are shared or copied. This is the entry point for container isolation.

PID 1 has special responsibilities in every Linux process namespace. The init process (PID 1) receives orphaned child processes automatically — when a parent process exits without calling `wait()`, the kernel re-parents its children to PID 1. Init must call `wait()` to collect these orphans; if it does not, they become zombie processes that occupy kernel process table entries, hold file descriptors open, and consume PID namespace slots. The second critical responsibility is signal forwarding: by default, the kernel does not deliver SIGTERM or SIGINT to PID 1 unless an explicit signal handler is registered for them. A shell script running as PID 1 in a container will silently ignore SIGTERM — which is exactly what Kubernetes sends before SIGKILL. The 10-second `terminationGracePeriodSeconds` timeout expires, the kubelet escalates to SIGKILL, and the container is force-killed without graceful shutdown.

The Virtual Filesystem (VFS) is the kernel's abstract interface to all filesystem implementations. When a process calls `open("/etc/passwd", O_RDONLY)`, the VFS lookup path traverses the dentry cache (a tree of cached directory entries), resolves the inode (the metadata structure representing a file), and calls the filesystem-specific operations to return a file descriptor. This indirection is what allows the kernel to serve a single directory tree that spans ext4 on a real disk, overlayfs for container layers, tmpfs for ephemeral scratch space, procfs for process metadata, and sysfs for kernel subsystem state. Each of these filesystems registers its own operations table with the VFS. Bind mounts re-attach any filesystem subtree at any mount point in the hierarchy, which is how Kubernetes volume mounts inject Secrets and ConfigMaps into container mount namespaces without copying files — the same inode is visible in both the host mount namespace and the container's.

## Key Concepts

- **fork()**: A syscall that duplicates the calling process. Returns 0 in the child, the child PID in the parent. Page tables are duplicated with all pages marked copy-on-write — no physical pages are copied until a write fault occurs. The child inherits open file descriptors, signal masks, and all namespace memberships of the parent.

- **exec() / execve()**: A syscall that replaces the calling process's address space with a new binary. Arguments are the path to the executable, the argv array, and the envp array. The process retains its PID but loses all previous memory mappings, signal handlers (reverted to defaults), and memory-mapped files. File descriptors remain open unless marked with `FD_CLOEXEC`.

- **clone()**: The generalization of fork() that accepts a flags bitmask. Flags include `CLONE_NEWPID` (new PID namespace), `CLONE_NEWNS` (new mount namespace), `CLONE_NEWNET` (new network namespace), `CLONE_NEWUTS` (new hostname/domain namespace), `CLONE_NEWUSER` (new user namespace), `CLONE_NEWIPC` (new IPC namespace). Container runtimes call clone() with a combination of these flags to establish isolated execution contexts.

- **PID 1 zombie reaping**: When a parent process exits without calling `wait()`, the kernel re-parents its children to the PID 1 process in the namespace. PID 1 must call `wait()` (or `waitpid()` with `WNOHANG` in a loop) to reap these orphans. Unreapable zombies persist in the kernel's process table, consuming a slot, until the namespace exits. A container where PID 1 is a shell script will accumulate zombies from any subprocess that does not have its own wait() loop.

- **Process states**: `RUNNING` (R) — actively executing on a CPU or runnable on the run queue. `SLEEPING` (S) — interruptible sleep, waiting on I/O or an event, will wake on a signal. `UNINTERRUPTIBLE SLEEP` (D) — blocked on kernel I/O (typically NFS or disk), cannot be interrupted by signals — this state causes processes to be unkillable until the I/O completes. `ZOMBIE` (Z) — process has exited, kernel retains the task_struct for the parent to call wait(); the process has no resource usage except the table entry. `STOPPED` (T) — suspended by SIGSTOP or being traced by ptrace.

- **SIGTERM vs SIGKILL**: SIGTERM (signal 15) is catchable and ignorable — the process can install a handler, perform cleanup, and exit gracefully. SIGKILL (signal 9) is delivered directly by the kernel and cannot be caught, blocked, or ignored — the process is unconditionally destroyed. Kubernetes sends SIGTERM first, waits `terminationGracePeriodSeconds` (default 30), then sends SIGKILL. If PID 1 is a shell wrapper (e.g., `sh -c "java -jar app.jar"`), it ignores SIGTERM by default and does not forward it to the child Java process, so the container always takes the full grace period before being force-killed.

- **sigprocmask and pending signals**: Every process has a signal mask (the set of blocked signals) and a set of pending signals — signals that have been sent but not yet delivered because they are masked. When a masked signal arrives, the kernel sets a bit in `task_struct.pending.signal`. When the signal is unblocked, it is delivered. Signals are not queued (except real-time signals): if the same signal is sent 10 times while blocked, only one delivery occurs when unblocked. Signal handlers are registered per-signal via `sigaction()`.

- **VFS layer**: The Virtual Filesystem Switch is the kernel abstraction that presents a uniform interface (open, read, write, close, stat, mount) across all filesystem types. The VFS manages the dentry cache (recently accessed directory entries), the inode cache (recently accessed file metadata), and the page cache (recently accessed file data). Each concrete filesystem (ext4, xfs, overlayfs, tmpfs, proc, sys, cgroup) registers a set of operation function pointers with the VFS. The `mount()` syscall binds a filesystem instance to a mount point in the directory tree.

- **Inodes and dentries**: An inode is the kernel's representation of a file or directory — it stores permissions, owner, size, timestamps, and a map of block pointers (for regular files) or directory entries (for directories). An inode does not store a filename; filenames are stored in directory entries (dentries) that map names to inode numbers. A hard link is two dentries pointing to the same inode. A symlink is a separate inode of type `S_IFLNK` whose content is a path string. Inode numbers are unique within a filesystem, not across the entire system. Inode exhaustion occurs when a filesystem runs out of inode table slots even if block space remains.

- **Linux capabilities**: The kernel decomposes root privilege into discrete units. `CAP_NET_BIND_SERVICE` allows binding to ports below 1024. `CAP_NET_ADMIN` allows network interface configuration, routing table modification, and packet filtering (iptables requires this). `CAP_SYS_ADMIN` is the broadest capability — it covers mounting filesystems, setting namespaces, loading kernel modules, and dozens of other operations. Container runtimes drop most capabilities by default: Docker drops `CAP_SYS_ADMIN`, `CAP_NET_ADMIN`, `CAP_SYS_PTRACE`, and 11 others. A workload receiving `EPERM` despite running as root typically lacks a required capability in its bounding set.

- **seccomp BPF**: Secure Computing with BPF allows a process (or container runtime) to attach a BPF program that is evaluated for every syscall before the syscall executes. The BPF program returns a verdict: `SCMP_ACT_ALLOW`, `SCMP_ACT_ERRNO` (return a specific error), or `SCMP_ACT_KILL` (terminate the process). Docker's default seccomp profile blocks approximately 44 syscalls including `ptrace`, `mount`, `kexec_load`, `perf_event_open`, `add_key`, and `keyctl`. Kubernetes pods run with the default container runtime seccomp profile unless `securityContext.seccompProfile` is set explicitly. `SCMP_ACT_ERRNO(EPERM)` is the typical behavior for blocked syscalls, making them indistinguishable from capability failures without strace.

- **AppArmor and SELinux**: Mandatory Access Control (MAC) frameworks that enforce security policy independently of discretionary access control (DAC, i.e., file permission bits and capabilities). AppArmor uses path-based profiles: a profile for a container process restricts which file paths it can read/write/execute, which capabilities it can use, and which network operations it can perform. SELinux uses labels — every file, socket, and process is labeled, and policy rules permit or deny operations based on source label, target label, and operation class. MAC enforcement happens after capability checks and independently of them. A process with `CAP_SYS_ADMIN` can still be blocked by a MAC policy that denies the specific operation.

- **D state (uninterruptible sleep) and its container implications**: A process in `D` state cannot be killed. It is blocked inside the kernel waiting for I/O to complete — typically a network filesystem call (NFS, CIFS) that is timing out, or a block device with failed storage. `kill -9` has no effect. The only resolution is for the I/O to complete, for the filesystem to be unmounted (which may also block), or for the machine to reboot. In containers, persistent D-state processes block pod deletion — `kubectl delete pod` hangs because the container cannot be stopped, and `terminationGracePeriodSeconds` is irrelevant when the process cannot receive signals.

## Internals

### Process Lifecycle: From fork() to First Child Instruction

The lifecycle of a process from creation to first instruction in the child involves five kernel transitions:

1. **Parent calls fork() (or clone())**: The kernel allocates a new `task_struct` for the child process. The PID namespace assigns the next available PID to the child. The memory management descriptor (`mm_struct`) is duplicated: all virtual memory areas (VMAs) are copied, but the page table entries for writable pages are changed to read-only in both parent and child. The physical pages themselves are not copied. Open file descriptors are duplicated (incrementing reference counts on the underlying `struct file` objects). The child's `task_struct.state` is set to `TASK_RUNNING` and it is placed on the CPU run queue.

2. **fork() returns**: In the parent, the kernel returns the child's PID. In the child, the kernel returns 0. At this point both processes are identical except for the return value and their PIDs. Any write to a shared page — in either process — triggers a page fault, the fault handler detects the COW flag on the VMA, allocates a new page, copies content, and updates the page table to point to the new page. The original page remains mapped in the other process.

3. **Child calls execve()**: The kernel resolves the path to the binary, verifies execute permission, reads the ELF header to identify the interpreter (dynamic linker), and begins loading segments. All current VMAs are unmapped and the process's page tables are torn down. New VMAs are created for the text segment (read + execute), data segment (read + write), and BSS (zero-initialized). The stack is re-initialized with argv and envp. Signal handlers are reset to their default dispositions (SIG_DFL). The `AT_ENTRY` ELF field sets the instruction pointer to the dynamic linker or the binary's entry point.

4. **Dynamic linker executes**: For dynamically linked binaries, the kernel transfers control to `ld.so` (the dynamic linker). `ld.so` reads the binary's `.dynamic` section, loads each required shared library (e.g., `libc.so.6`) into the address space by `mmap()`-ing it, resolves symbol relocations (filling in the PLT/GOT entries for function calls that cross library boundaries), calls each library's `_init()` function, and then transfers control to the binary's `main()`.

5. **First instruction in the program**: The process's `%rip` register now points to `main()` (or the C runtime's `_start` which calls `main()`). The executable is running. No process data from the parent survived except: the PID, open file descriptors (unless `FD_CLOEXEC` was set), the current working directory, and namespace memberships. Every page fault hereafter loads fresh data from the ELF binary's segments via the page cache.

### Signal Delivery: From kill() to Handler Execution

Signal delivery is asynchronous relative to the target process's user-space execution but is always synchronous with a kernel entry point:

1. **Signal is sent**: A process calls `kill(pid, signum)` or the kernel generates an internal signal (e.g., SIGSEGV on page fault, SIGCHLD on child exit). The kernel looks up the target `task_struct` and calls `send_signal()`. If the signal is not blocked by the target's signal mask (`task_struct.blocked`), it is added to `task_struct.pending.signal` (a bitmap for standard signals). For blocked signals, the same pending bit is set; the signal waits there until unblocked.

2. **Delivery point**: The kernel does not interrupt the target mid-instruction. Signal delivery happens at specific safe points: when the process returns from a syscall to user space, or when an interrupt returns to user space (the `iret`/`sysretq` path). The kernel's `do_signal()` routine checks the pending set on every return-to-userspace transition. If there is a pending, non-blocked signal with a registered handler, delivery begins.

3. **Handler invocation**: The kernel modifies the process's user-space stack, pushing a signal frame that includes the saved register state and the `siginfo_t` structure. The kernel redirects the instruction pointer to the signal handler function. When the handler returns (via the special `sigreturn` syscall), the kernel pops the signal frame and restores the original register state, resuming execution exactly where the process was interrupted.

4. **Async-signal-safe restriction**: Because signal handlers can execute at any point during user-space code, they must only call async-signal-safe functions — functions that do not use global state that could be in an inconsistent state at the point of interruption. Functions like `printf()`, `malloc()`, `fopen()` are NOT async-signal-safe (they use internal locks). Only a small set of functions (`write()`, `read()`, `signal()`, `_exit()`, `sigprocmask()`) are guaranteed safe. This is why container entrypoint signal handlers should call `_exit()` directly rather than going through `exit()`.

5. **SIGCHLD and wait()**: When a child process exits, the kernel sends SIGCHLD to the parent. If the parent has `SA_NOCLDWAIT` set or calls `waitpid()`, the kernel immediately cleans up the child's `task_struct`. Without this, the child enters zombie state. The zombie has no resources — no memory, no CPU time — but it holds a PID namespace slot and a `task_struct` entry. The kernel keeps it there precisely so the parent can call `wait()` to collect the exit status. PID 1 must have a working SIGCHLD handler (or call `wait()` in a loop) to prevent zombie accumulation.

### Filesystem: VFS Lookup, Page Cache, and Inode Exhaustion

Every file access in Linux traverses the VFS stack in a consistent sequence:

1. **Path resolution (namei)**: The kernel starts at the root dentry (or the current working directory dentry for relative paths). Each path component is looked up in the dentry cache (`dcache`) using a hash of (parent dentry, name). On a cache hit, the next dentry is returned immediately from memory. On a miss, the kernel calls the parent directory's `iop->lookup()` method, which reads the directory from disk (or the underlying filesystem), finds the entry, allocates a new dentry, and populates it with the inode number. This is the `namei` (name-to-inode) operation that every file operation starts with.

2. **Inode retrieval**: Once the dentry is found, it points to an inode (via `dentry->d_inode`). If the inode is in the inode cache (`icache`), it is returned immediately. Otherwise the filesystem's `super_operations->alloc_inode()` is called to allocate a new inode, and `iop->getattr()` fills it by reading the on-disk inode block. The inode contains permissions, owner UID/GID, file size, number of hard links, and the block map (for regular files) or device number (for device files).

3. **Page cache and data access**: For a `read()` call, the kernel checks the page cache — an in-memory cache of file content keyed by (inode, offset). If the page is cached, the data is copied to the user buffer directly. On a miss, the filesystem's `address_space_operations->readpage()` method issues an I/O request to the block layer, waits for the page to load, then serves the data. Write operations via `write()` place dirty pages in the page cache and mark them dirty; they are written back to disk asynchronously by the kernel's writeback daemon (`kworker/u*:*`) based on dirty ratio thresholds or explicit `fsync()` calls.

4. **Inode exhaustion**: Every filesystem has a fixed number of inode table slots, determined at format time (`mkfs.ext4 -i bytes-per-inode`). The default inode ratio on ext4 is one inode per 16KB of capacity. A filesystem with many small files (logs, package manager cache entries, container layer files) can exhaust all inodes while still having substantial free block space. `df -h` reports block usage — it will show 60% used. `df -i` reports inode usage — it will show 100%. Any attempt to create a new file, even in a near-empty directory, fails with `ENOSPC` (no space left on device) because no new inodes can be allocated. tmpfs and ramfs do not have this problem (inodes are dynamic), but ext4 on container overlay layers is vulnerable.

5. **overlayfs inode accounting**: Container image layers use overlayfs, which stacks a read-only lower layer (the image) over a read-write upper layer (the container writable layer). Each file visible in the overlayfs mount consumes an inode in the overlay's upper directory on the underlying host filesystem. When a container unpacks a large number of small files (e.g., a Python environment with thousands of `.pyc` files, or a Node.js `node_modules` with tens of thousands of small files), the host filesystem's inode table can be exhausted, preventing new containers from starting.

## Architecture Diagram

```
Signal delivery path:
======================

  user space                        kernel space
  ──────────────────────────────────────────────────────────────────
  application code                  syscall or interrupt
  executing ...                     ──────────────────────
        │                           │
        │  write to shared page     │  page fault → COW
        │ ◄── page fault ──────────►│  allocate new page
        │                           │  copy old page to new page
        │                           │  remap VMA
        │
  return from syscall ─────────────►  do_signal() called
                                    ↓
                                    any pending + unblocked signals?
                                    ↓ yes
                                    push signal frame onto user stack
                                    (saves: rip, rsp, rflags, regs)
                                    redirect rip → handler address
                                    ↓
  ◄─── handler executes ───────────  return to user space
  signal_handler() {
    // async-signal-safe ops only
    write(fd, msg, len);
    _exit(0);                       ──── sigreturn() ────────────────►
  }                                                                    │
  OR                                                                   │
  handler returns normally                                             │
                                    pop signal frame
                                    restore saved registers
                                    resume original rip
  ◄─── original code resumes ─────  return to user space


VFS layer stack:
=================

  process
    │  open("/var/log/app.log")
    ▼
  ┌──────────────────────────────────────────────────────────────┐
  │                    VFS (Virtual Filesystem Switch)           │
  │                                                              │
  │  path resolution:  dentry cache ──► inode cache             │
  │                    (hash: parent + name)   (hash: ino num)   │
  │                                                              │
  │  cache miss → filesystem-specific lookup()                   │
  └───────────────────────────┬──────────────────────────────────┘
                              │ dispatch by filesystem type
          ┌───────────────────┼───────────────────────────────┐
          ▼                   ▼                               ▼
     ┌─────────┐       ┌──────────────┐               ┌──────────┐
     │  ext4   │       │  overlayfs   │               │  tmpfs   │
     │ (disk)  │       │ (containers) │               │ (memory) │
     └────┬────┘       └──────┬───────┘               └────┬─────┘
          │                   │  upper layer (rw)           │
          │              ┌────┴────────────────────┐       │
          │              │     lower layer (ro)     │       │
          │              │  (container image layers)│       │
          │              └─────────────────────────┘       │
          │                                                  │
          ▼                   ▼                              ▼
  ┌───────────────────────────────────────────────────────────────┐
  │                   Page Cache                                  │
  │  (inode, page_offset) → cached page data                      │
  │  dirty pages → writeback daemon → disk                        │
  └───────────────────────────────────────────────────────────────┘


  procfs view of process state:
  ┌─────────────────────────────────────┐
  │  /proc/<pid>/                        │
  │    status       ─ state, Pid, PPid  │
  │    fd/          ─ open file descs   │
  │    maps         ─ virtual memory    │
  │    cgroup       ─ cgroup membership │
  │    ns/          ─ namespace links   │
  │    status       ─ capabilities      │
  └─────────────────────────────────────┘
```

## Failure Modes & Debugging

### 1. PID 1 SIGTERM Ignored — Containers Always Take the Full Grace Period

**Symptoms**: Rolling deployments for a Deployment always take exactly `terminationGracePeriodSeconds` (e.g., 30 seconds) per pod regardless of how quickly the application stops. `kubectl describe pod` shows `Terminating` for 30 seconds followed by container removal. The application logs show no graceful shutdown sequence (no "received SIGTERM, draining connections" messages).

**Root Cause**: The container's entrypoint is a shell script or uses a shell `ENTRYPOINT` form (e.g., `ENTRYPOINT ["sh", "-c", "exec java -jar app.jar"]`). The shell process becomes PID 1 in the container's PID namespace. When the kubelet sends SIGTERM to the container, it delivers the signal to PID 1 — the shell. The shell's default disposition for SIGTERM is to ignore it (the POSIX spec says `sh` ignores SIGTERM if it is non-interactive). The actual application process (Java, Node, Python) is a child of the shell at PID 2+. SIGTERM is not automatically forwarded by the shell to its children. The application never receives SIGTERM, the grace period expires, and the kubelet sends SIGKILL, which kills everything in the container's PID namespace.

**Blast Radius**: Every deployment rollout and pod deletion takes the maximum grace period. In a deployment with 20 replicas and `maxUnavailable: 1`, a rollout takes 20 × 30 seconds = 10 minutes. Batch jobs and CronJobs that are preempted never flush their work buffers. StatefulSets with graceful shutdown logic (draining connections, checkpointing state) never execute that logic.

**Mitigation**:
- Use the exec form of ENTRYPOINT/CMD in the Dockerfile: `ENTRYPOINT ["java", "-jar", "app.jar"]` — this starts the application as PID 1 directly, no shell wrapper.
- If a shell wrapper is necessary, use `exec` to replace the shell with the application: `exec java -jar app.jar`. The `exec` syscall replaces the shell process with the Java process at the same PID.
- Use `tini` (a minimal init designed for containers) as PID 1: it has proper signal forwarding and zombie reaping. `docker run --init` uses `tini`. In Kubernetes, set `shareProcessNamespace: false` and use a custom entrypoint wrapper.
- Set `preStop` lifecycle hooks for applications that need to drain before shutdown — this buys time independently of signal handling.

**Debugging**:
```bash
# Identify PID 1 inside the container
kubectl exec <pod> -- cat /proc/1/cmdline | tr '\0' ' '
# If output is "/bin/sh -c ..." or "/bin/bash ...", PID 1 is a shell.

# Check what processes are running in the container's PID namespace
kubectl exec <pod> -- ps -ef
# If PID 1 is sh/bash and the app is PID 2+, SIGTERM forwarding is broken.

# Check if the app has a SIGTERM handler registered
# Look for sigaction or signal in strace output (requires privileged pod)
kubectl exec <pod> -- cat /proc/1/status | grep -i sig
# SigCgt shows which signals have handlers registered (bitmask, SIGTERM = bit 14)
# If bit 14 of SigCgt is 0, PID 1 has no SIGTERM handler.

# Check the Dockerfile entrypoint form (exec vs shell)
docker inspect <image> | jq '.[0].Config.Entrypoint, .[0].Config.Cmd'
# exec form: ["java", "-jar", "app.jar"]  — correct
# shell form: ["/bin/sh", "-c", "java -jar app.jar"]  — broken for SIGTERM
```

---

### 2. Zombie Accumulation with Shell PID 1

**Symptoms**: `kubectl exec <pod> -- ps aux` shows multiple processes in `Z` (zombie) state. The pod is running normally from Kubernetes's perspective (readiness probe passes, container is not restarting). Over time, `kubectl exec <pod> -- cat /proc/sys/kernel/pid_max` minus the current PID counter shows fewer available PIDs. In extreme cases, new processes inside the container fail with `EAGAIN` (cannot allocate PID) even though the container appears healthy.

**Root Cause**: The container entrypoint spawns subprocesses (cron jobs, health check scripts, cleanup scripts) that exit. Their parent (the shell PID 1) never calls `wait()` on them because the shell only waits for its direct foreground child. The exited subprocesses enter zombie state. Each zombie holds a kernel `task_struct` entry and one PID. The PID namespace has a fixed PID range (default 32768 PIDs). A container running in production for days with frequent zombie creation can exhaust this budget.

**Blast Radius**: Limited to the affected pod initially. The pod continues to function until PID exhaustion, at which point all `fork()` calls inside the container fail with `EAGAIN`. The application cannot start new threads, cannot spawn health check processes, and may crash. If the liveness probe relies on spawning a subprocess (`exec` probe type), it will fail, triggering container restart and the full zombie cycle starts over. In a multi-container pod, PID namespaces are per-container by default, so other containers are unaffected unless `shareProcessNamespace: true` is set.

**Mitigation**:
- Use a proper init system as PID 1: `tini`, `dumb-init`, or `runit`. These are designed to reap adopted zombie children.
- In Docker: `docker run --init` adds tini as PID 1.
- In Kubernetes: install `tini` in the image and set it as ENTRYPOINT: `ENTRYPOINT ["/tini", "--", "your-entrypoint.sh"]`.
- Alternatively, set `shareProcessNamespace: true` in the pod spec and run an init container that acts as a proper PID 1 (advanced pattern, rarely needed).
- Audit entrypoint scripts: ensure every `&` backgrounded subprocess is waited for with `wait $!` or `wait` at the end of the script.

**Debugging**:
```bash
# Count zombie processes in the container
kubectl exec <pod> -- ps aux | grep -c ' Z '

# Show zombie processes with their PPID (to identify the parent failing to reap)
kubectl exec <pod> -- ps -eo pid,ppid,stat,comm | awk '$3 ~ /Z/ {print}'

# Check PID namespace usage — compare current max PID to the range
kubectl exec <pod> -- cat /proc/sys/kernel/pid_max
kubectl exec <pod> -- ls /proc | grep -c '^[0-9]'
# If the second count approaches the first number, PID exhaustion is imminent.

# Inspect PID 1's signal disposition for SIGCHLD
# SigCgt bitmask bit 16 (0x10000) = SIGCHLD has a handler registered
kubectl exec <pod> -- grep SigCgt /proc/1/status
# If SigCgt is 0000000000000000, PID 1 has no signal handlers — it will not reap.
```

---

### 3. Inode Exhaustion — df -h Shows Free Space but Writes Fail

**Symptoms**: Application writes fail with `ENOSPC: no space left on device` or `OSError: [Errno 28] No space left on device`. `df -h` reports 40-60% disk utilization — clearly not full. The application log shows write failures. New files cannot be created. `kubectl exec <pod> -- touch /tmp/testfile` fails with `ENOSPC`. The node condition `DiskPressure` may not be set because the kubelet's disk eviction checks block usage, not inode usage.

**Root Cause**: The underlying filesystem's inode table is full. Common triggers: (1) A workload that creates large numbers of small files — a Python virtualenv with thousands of `.pyc` files, a Node.js project with a deep `node_modules` tree, or a log rotator that creates a new file per second. (2) A container workload that unpacks package archives (`.tar.gz`, `.zip`) containing many small files onto the host's overlay filesystem upper directory. (3) The host's `/var/lib/docker` or `/var/lib/containerd` directory on an ext4 filesystem formatted with the default 1-inode-per-16KB ratio, insufficient for container-heavy workloads.

**Blast Radius**: All write operations on the affected filesystem fail, regardless of available block space. If the affected filesystem is the host's root partition or the `kubelet` data directory, new containers cannot start (container runtime cannot create overlay upper directories), new pods cannot be scheduled to the node, and existing pods running on that node cannot create new files. The node does not enter `DiskPressure` condition from the kubelet's eviction manager because it checks `NodeFsAvailable` (block usage), not inode usage. This is a silent, hard-to-detect failure mode.

**Mitigation**:
- Format host filesystems with a smaller inode ratio for container workloads: `mkfs.ext4 -i 4096 /dev/xvdf` creates one inode per 4KB instead of 16KB, quadrupling inode count.
- Use XFS instead of ext4 for host OS volumes. XFS allocates inodes dynamically and does not have a fixed inode table — it cannot exhaust inodes independently of blocks (though it can still run out of inodes near max file count per XFS spec ~10^18).
- Set up kubelet eviction thresholds for inode usage: `--eviction-hard=nodefs.inodesFree<5%` evicts pods when the node filesystem drops below 5% free inodes.
- Add monitoring: alert on `node_filesystem_files_free / node_filesystem_files < 0.1` (less than 10% inodes remaining).
- For container images with large numbers of files, build layered images that keep node_modules/site-packages in the image layer (read-only lower layer) rather than copying to the writable upper layer.

**Debugging**:
```bash
# Compare block usage vs inode usage on all filesystems
df -h    # block usage (what most people check)
df -i    # inode usage (what you need to check)
# Look for any filesystem showing 100% in the iuse% column for df -i.

# Find which directory has the most files (inode consumers)
# This is slow on large filesystems but essential for root cause analysis
find / -xdev -printf '%h\n' 2>/dev/null | sort | uniq -c | sort -rn | head -20

# Count files per directory more efficiently using inode traversal
ls /proc | wc -l           # check procfs (does not consume disk inodes)
du --inodes -s /* 2>/dev/null | sort -rn | head -10
# du --inodes requires coreutils 8.25+; count inodes per top-level directory.

# Check inode count on the specific filesystem where writes are failing
stat -f /var/lib/containerd
# Fields: Files (total inodes), FFree (free inodes), FAvail (available for non-root)

# On the node (requires node-level access or privileged DaemonSet)
ssh <node> "df -i /var/lib/containerd | awk 'NR==2{print \"Inode used:\", \$5}'"

# Check if the kubelet's eviction manager is watching inode usage
kubectl describe node <node> | grep -A10 "Conditions:"
# DiskPressure: True means block eviction triggered; does NOT mean inode eviction triggered.
```

---

### 4. Capability Mismatch — EPERM Despite Running as UID 0

**Symptoms**: A container process running as root (UID 0) fails a syscall with `EPERM` (Operation not permitted) or `EACCES` (Permission denied). `id` inside the container returns `uid=0(root) gid=0(root)`. The failure occurs on operations like: `iptables -A INPUT ...`, `ip link set eth0 promisc on`, `mount /dev/sda1 /mnt`, `sysctl -w net.core.rmem_max=26214400`, loading a kernel module, or using `ptrace` to attach to another process.

**Root Cause**: The container runtime drops a large set of Linux capabilities from the container's capability bounding set even for root processes. Docker drops 14 capabilities by default including `CAP_NET_ADMIN`, `CAP_SYS_ADMIN`, `CAP_SYS_PTRACE`, `CAP_SYS_MODULE`, `CAP_AUDIT_WRITE`, `CAP_SETFCAP`, and others. A process being UID 0 is necessary but not sufficient for privileged operations — it must also hold the specific capability in its permitted and effective sets. `iptables` requires `CAP_NET_ADMIN`. `mount()` requires `CAP_SYS_ADMIN`. `ptrace()` requires `CAP_SYS_PTRACE`. Additionally, seccomp profiles may block the syscall independently of capability checks — the kernel runs capability checks first, then seccomp, so if seccomp blocks the syscall with `SCMP_ACT_ERRNO(EPERM)`, the error is indistinguishable from a capability failure without strace.

**Blast Radius**: The affected workload cannot perform its intended function. Service meshes (e.g., Istio's `istio-init` init container) require `CAP_NET_ADMIN` to set iptables rules for traffic interception. CNI plugins require `CAP_NET_ADMIN` and sometimes `CAP_SYS_ADMIN` to configure network interfaces and routes. Monitoring agents that use `perf_event_open` for eBPF require `CAP_PERFMON` (or `CAP_SYS_ADMIN` on older kernels). Privileged DaemonSets that configure host networking require `CAP_NET_ADMIN`. Incorrect capability configuration causes these platform components to silently fail to configure the node correctly.

**Mitigation**:
- Grant specific required capabilities in the pod's `securityContext.capabilities.add` instead of using `privileged: true` (which re-grants all capabilities and also defeats AppArmor and seccomp profiles).
- Audit what capabilities a workload actually needs: use `strace -e trace=process,network -f <command>` to identify failing syscalls, then map syscall to required capability.
- For platform DaemonSets that genuinely need full access, `privileged: true` is sometimes necessary, but scope it to the minimum required containers.
- Document required capabilities in the Helm chart or Kustomize overlay as explicit security context fields rather than hiding them in comments.
- Set `drop: ["ALL"]` and then explicitly `add` only the needed capabilities — defense in depth.

**Debugging**:
```bash
# Check effective capabilities of a running process inside a container
# CapEff is the effective set — these are the capabilities currently active
kubectl exec <pod> -- grep CapEff /proc/1/status
# Decode the hex bitmask to human-readable capability names
capsh --decode=00000000a80425fb   # replace with actual CapEff value

# Alternatively, use capsh directly if installed
kubectl exec <pod> -- capsh --print 2>/dev/null || \
  kubectl exec <pod> -- grep -E "Cap(Prm|Inh|Eff|Bnd)" /proc/1/status

# Check if a specific capability is present
# CAP_NET_ADMIN = bit 12, value 0x1000
# If CapEff & 0x1000 != 0, CAP_NET_ADMIN is in the effective set
printf "0x%x\n" $((0x00000000a80425fb & 0x1000))  # nonzero = has cap

# Use strace to find the failing syscall and its return code
# Requires a privileged pod or nsenter on the node
kubectl debug node/<node> -it --image=ubuntu:22.04 -- bash
nsenter --target <pid> --mount --uts --ipc --net --pid -- \
  strace -f -e trace=all -p 1 2>&1 | grep -i eperm | head -20

# Check if seccomp is blocking the syscall independently of capabilities
# seccomp violations show up in kernel audit log (requires audit daemon)
# Or check dmesg for seccomp audit events
kubectl debug node/<node> -it --image=ubuntu:22.04 -- dmesg | grep -i seccomp | tail -20

# Inspect the pod's security context to see granted capabilities
kubectl get pod <pod> -o jsonpath='{.spec.containers[*].securityContext.capabilities}'
```

## Lightweight Lab

See [lab/README.md](lab/README.md) for the full exercise. The lab explores `/proc`, traps signals, exhausts inodes on a tmpfs, and inspects capabilities — all without cluster access, just a Linux host or container.

Key commands to run immediately to build intuition:

```bash
# 1. See what PID 1 of your current shell is
cat /proc/1/cmdline | tr '\0' ' '
cat /proc/1/status | grep -E "^(State|Pid|PPid|SigCgt|CapEff)"

# 2. See every open file descriptor for your current shell process
ls -la /proc/$$/fd

# 3. See the virtual memory layout of the current shell
cat /proc/$$/maps | head -20

# 4. Check capability bitmask of the current process
grep CapEff /proc/$$/status
# Run in a Docker container to see the reduced set:
# docker run --rm ubuntu:22.04 grep CapEff /proc/1/status

# 5. Observe fork+exec at the strace level (requires strace)
strace -e trace=execve,clone,fork,vfork -f ls /tmp 2>&1 | head -30

# 6. Check inode usage on all mounted filesystems
df -i

# 7. Trigger a write to PID 1 from a subprocess (shell signal test)
# Run this in a terminal: sleep 1000 &; BGPID=$!; kill -TERM $BGPID
# In a container where sh is PID 1, SIGTERM to PID 1 is ignored:
# docker run --rm -it ubuntu:22.04 sh -c 'trap "" TERM; sleep 9999'
# docker stop <containerID>  -- will wait the full 10 seconds

# 8. Inspect the capabilities of a Docker container vs privileged container
docker run --rm ubuntu:22.04 grep CapEff /proc/1/status
docker run --rm --privileged ubuntu:22.04 grep CapEff /proc/1/status
# Compare the bitmask values: privileged will show 000001ffffffffff
```

## What to commit

- Run the lab and capture the capability bitmask output for both a regular and `--privileged` Docker container; annotate what changed and why.
- Identify three syscalls that fail in a regular container but succeed in a privileged container, and name the capability each requires.
