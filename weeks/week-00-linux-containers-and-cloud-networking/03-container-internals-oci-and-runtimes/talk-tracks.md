# Talk Tracks

## Q: Explain this in one minute.

**Answer:**

A container is a Linux process — or a tree of processes — running inside a set of kernel namespaces with resource limits enforced by cgroups, and with a filesystem view assembled from image layers by a union mount. The OCI Image Spec defines how images are stored: as content-addressable blobs (layers as gzip tars, a manifest listing those blobs, a config describing the runtime environment) where every artifact is identified by its SHA-256 digest. The OCI Runtime Spec defines the interface for starting a container: a config.json describing rootfs path, process arguments, namespaces to create, cgroups to join, capabilities to drop, and seccomp filters to apply. In Kubernetes the runtime stack is: kubelet calls containerd's CRI gRPC endpoint, containerd forks a containerd-shim per container, the shim calls runc, runc calls clone() with the namespace flags, pivots root into the image's overlayfs rootfs, sets up cgroups and seccomp, and then exec's the user process and exits. runc is ephemeral — it exits immediately after exec. The shim stays resident to hold stdio pipes and collect the exit code. containerd can restart without killing any running container because the shims are independent processes.

---

## Q: Trace kubelet receiving a pod spec to a running process — name every component and IPC boundary.

**Answer:**

kubelet receives the pod spec from the API server via its SharedInformer watch on Pods. It calls the container runtime via gRPC over the CRI socket at `/run/containerd/containerd.sock`. The first call is `RunPodSandbox` — containerd's CRI plugin creates the pause container. It resolves the pause image (`registry.k8s.io/pause:3.9`) from the content store, calls the snapshotter (overlayfs) to assemble the pause rootfs, generates an OCI bundle (config.json + rootfs directory), then forks a `containerd-shim-runc-v2` process. The shim double-forks to orphan itself under init and writes its socket path to `/run/containerd/io.containerd.runtime.v2.task/k8s.io/<sandbox-id>/shim.sock`. The shim calls `runc create` (execing runc as a child) which calls `clone()` with `CLONE_NEWNET|CLONE_NEWNS|CLONE_NEWIPC|CLONE_NEWUTS|CLONE_NEWPID`, creates the network namespace, then blocks. containerd then calls the CNI plugin chain (exec'd as a binary under `/opt/cni/bin/`) to configure the network namespace: assign the pod IP, create veth pairs, configure iptables. CNI returns success, containerd calls `runc start` via the shim which execs the pause process — PID 1 in the pod's PID namespace. kubelet now calls `CreateContainer` for each app container: containerd prepares a new writable overlayfs snapshot on top of the image layers, forks a new shim, calls `runc create` on the app container's OCI bundle — this time the config.json's namespaces array includes joins to the sandbox's existing netns and ipcns via `/proc/<pause-pid>/ns/net` path. `runc start` execs the application binary. Every IPC boundary is: kubelet ↔ containerd via gRPC, containerd ↔ shim via unix socket, shim ↔ runc via fork/exec, runc ↔ kernel via system calls (clone, mount, exec), containerd ↔ CNI via exec.

---

## Q: Two images share a base layer — how much disk space do they use?

**Answer:**

They use the size of the shared layers plus the size of each image's unique upper layers. The OCI content store stores every blob exactly once, keyed by its SHA-256 digest. When image A and image B both reference `sha256:abc...` as their first layer, the blob at `blobs/sha256/abc...` exists once on disk. The manifest for image A and the manifest for image B both point to that digest. containerd's content store knows this: when you pull image B after image A, containerd checks the store for each blob in B's manifest before fetching from the registry. If `sha256:abc...` is already present, it is skipped. The same deduplication applies to the snapshotter: when containerd prepares the snapshot for image B, the base snapshot (the decompressed directory tree for that layer) already exists and is reused as a read-only overlayfs lowerdir. So disk usage is: (shared layer blob compressed size in content store) + (shared layer uncompressed snapshot) + (image A's unique layers) + (image B's unique layers). There is no copying. This is the key operational reason to keep base images consistent across your fleet — if 50 application images all share the same `debian:bookworm-slim` base, that base's ~80MB of blobs and ~200MB of snapshot are stored once regardless of how many images reference it.

---

## Q: What is the pause container and why does it exist?

**Answer:**

The pause container is the infrastructure container that holds the pod's shared namespaces. It runs a single binary called `/pause`, which immediately calls the `pause()` system call and blocks indefinitely — it consumes essentially zero CPU. Its existence is purely architectural: Kubernetes needs a stable anchor for the pod's network and IPC namespaces whose lifetime is tied to the pod, not to any individual application container. Without the pause container, if you wanted containers to share a network namespace, you would have to put the namespace inside one of the application containers. But then restarting that application container (due to a crash or liveness probe failure) would destroy the namespace, disconnecting all the other containers in the pod from the network. The pause container solves this by being the namespace creator and holder — application containers join its namespaces rather than owning them. When containerd creates each application container's OCI bundle, the `namespaces` section of config.json specifies `"type": "network"` with `"path": "/proc/<pause-pid>/ns/net"` instead of `"type": "network"` with `path` omitted (which would create a new namespace). This namespace join is done at clone() time by runc, before the application process starts. The result: all containers in the pod share one IP address, one set of lo/eth0 interfaces, and can use shared memory via IPC — as if they were processes on the same host.

---

## Q: Multi-tenant platform, untrusted code — what runtime options and what are the trade-offs?

**Answer:**

You have three meaningful options for running untrusted code: default runc, gVisor, and Kata Containers. Default runc uses Linux namespaces and seccomp to restrict access but the container still makes real system calls directly to the host kernel. A kernel exploit (CVE in the kernel itself) or a namespace escape can compromise the host. The attack surface is everything the host kernel exposes to unprivileged syscalls. gVisor interposes a user-space kernel (the Sentry) between the application and the host kernel. System calls from the application hit the Sentry, which handles them in user space, making only a small, auditable set of host kernel calls. This eliminates kernel exploit paths but adds 10-15% CPU overhead for compute-bound workloads and significantly higher overhead for syscall-heavy workloads (databases, anything using `io_uring`). Some syscalls are not implemented (`perf_event_open`, `bpf`), so certain applications are incompatible. Kata Containers runs each pod in a lightweight VM (Firecracker or QEMU). The VM has its own Linux kernel — a kernel exploit inside the container would compromise the VM's kernel, not the host kernel. Hardware virtualization provides the isolation boundary. Overhead is VM boot latency (50-150ms with Firecracker), ~128MB baseline memory per VM, and I/O path overhead (virtio). In practice: gVisor is the right choice for general-purpose multi-tenant workloads that are compatible, because the overhead is lower and the operational model is simpler. Kata is the right choice for high-security or compliance-mandated isolation (financial workloads, untrusted user code execution like CI runners). Both are integrated into Kubernetes via RuntimeClass so tenants can request isolation level in their pod spec.

---

## Q: Why can containerd restart without killing containers?

**Answer:**

Because the containerd-shim is designed to outlive containerd. When containerd forks a shim to manage a container, the shim immediately double-forks: it forks a child, the child calls `setsid()` to create a new session and detach from the parent's process group, and then the original shim exits. The grandchild (the shim that will actually manage the container) is now an orphan re-parented by PID 1 (init/systemd). It is no longer in containerd's process group. Its stdio file descriptors are independent. It writes its unix socket path into the containerd state directory at `/run/containerd/io.containerd.runtime.v2.task/k8s.io/<container-id>/shim.sock`. When containerd restarts, it reads all the socket paths from the state directory on disk, reconnects to each shim over its socket, re-subscribes to exit events, and rebuilds its in-memory view of all running containers. The shims — and therefore all the containers — never noticed. This is the same architectural principle as GNU Screen or tmux: the process that holds the session is independent of any client that connects to it. containerd is just a sophisticated client to the shims. You can verify this by running `systemctl restart containerd` while a container is running and observing that `docker ps` (or `ctr tasks ls`) still shows the container running with the same PID immediately after the restart.

---

## Q: What can go wrong?

**Answer:**

The most operationally significant failures are: image pull failure, shim leak, sandbox creation failure, and gVisor syscall panic. Image pull failure occurs when the content store has a partial or corrupt blob — containerd finds the blob file by path but the content does not match the expected digest. The fix is to manually remove the corrupt blob with `ctr content rm <digest>` and re-pull. Shim leaks happen when runc crashes during container cleanup — the shim still holds the task state but the cgroup and namespace entries are orphaned. The pod is stuck in Terminating because `runc delete` never completed. The fix is `ctr tasks delete --force <container-id>`. Sandbox creation fails when the pause image is not present on the node (air-gapped environments, pause image not pre-loaded) or when the CNI plugin fails (IP pool exhaustion, missing binary, misconfigured network config). The entire pod is stuck in ContainerCreating because no app containers start until the sandbox's network is configured. gVisor syscall panics are deterministic: a specific application calls a syscall the Sentry does not implement, receives SIGSYS, exits with code 159. The Sentry log in `/tmp/runsc.*/` names the offending syscall. The operational fix is to run the workload on a node without gVisor via a different RuntimeClass.

---

## Q: How would you debug it?

**Answer:**

I work from the outside in: API server event → CRI layer → containerd internals → OS. I start with `kubectl describe pod` to read the events, which identify whether the failure is at image pull, sandbox creation, container creation, or container startup. For image pull errors the event cites the exact error from the registry or content store. I then use `ctr -n k8s.io images ls` to check the image state on the node. For sandbox failures I use `crictl pods` to see the sandbox state and `crictl inspectp <sandbox-id>` for the full status, and `journalctl -u containerd` for the raw containerd error. For CNI I look at the CNI binary logs, which often write to syslog or a plugin-specific log file, and check `/etc/cni/net.d/` for the active config. For runc-level failures I look for core dumps in the bundle directory and check `journalctl -u containerd` for `runc` exit codes. For shim leaks I compare `ctr -n k8s.io tasks ls` against running shim processes with `ps aux | grep containerd-shim`. If tasks show STOPPED with a live shim process, it is a shim-containerd reconnect failure — I check for the socket file at the expected path. For gVisor I check the runsc log directory at `/tmp/runsc.*/sandbox.log` for `Unimplemented` lines naming the exact syscall that caused the panic.

---

## Q: How does the overlayfs snapshotter assemble the container rootfs?

**Answer:**

overlayfs is a union filesystem that presents a merged view of multiple directories without copying data. containerd's overlayfs snapshotter maintains a set of read-only snapshot directories, one per image layer. When preparing a container's rootfs, the snapshotter creates one additional writable directory — the upper layer — and mounts an overlayfs with all the image layers as lowerdir (colon-separated, applied in reverse layer order so the top image layer's lowerdir takes precedence) and the writable directory as upperdir. The mount looks like: `mount -t overlay overlay -o lowerdir=/snap/3/fs:/snap/2/fs:/snap/1/fs,upperdir=/snap/writable/fs,workdir=/snap/writable/work /rootfs`. Any read by the container process first checks the upperdir, then each lowerdir in order. Any write by the container is captured in the upperdir, leaving the lowerdirs completely unmodified. On container removal, the upperdir is deleted; the lowerdirs (image layer snapshots) remain because other containers or the image metadata still reference them. The snapshotter tracks all references in containerd's boltdb metadata. A snapshot is only GC'd when no container, no image manifest chain, and no active lease references it. This design means that even if 100 containers are running from the same image, the image's layer data on disk is read from a single set of snapshot directories — there is one overlay mount per container (each with its own upperdir) but one set of shared lowerdirs for all of them.

---

## Q: What is the difference between a container and a VM from the kernel's perspective?

**Answer:**

A container is a process with restricted namespace visibility and constrained resource access; it shares the host kernel. A VM is a hardware-virtualized execution environment with its own kernel that runs as a user-space process on the host. From the host kernel's perspective, a container is just a process entry in the PID table, a set of namespace file descriptors under `/proc/<pid>/ns/`, a subtree in the cgroup hierarchy, and a set of fd entries pointing to the overlayfs mount. The host kernel handles every system call the container process makes — there is no mediation layer. If the container calls `open("/etc/shadow", ...)`, that system call reaches the host kernel, which then checks namespaces, capabilities, and seccomp to decide whether to allow it. A VM, by contrast, runs under a hypervisor (KVM module in the host kernel for Kata Containers, or user-space QEMU). The VM's guest OS has its own kernel. System calls made inside the VM are handled by the guest kernel, which then makes hypercalls or VM exits to the hypervisor for hardware access. The host kernel only sees the VM as a KVM file descriptor and the QEMU/Firecracker process. This means that a kernel exploit that compromises the guest kernel in a VM cannot directly escape to the host — the hypervisor is the isolation boundary. Containers do not have this boundary: a kernel privilege escalation inside the container compromises the host kernel directly.

---

## Q: How does containerd handle multi-architecture images?

**Answer:**

Multi-architecture images use an OCI image index (previously called a manifest list). The index is a JSON document of type `application/vnd.oci.image.index.v1+json` that contains an array of manifests, each tagged with platform selectors: `os`, `architecture`, and optionally `variant` (e.g., `arm/v7` vs `arm/v8`). When containerd pulls a multi-arch image reference like `nginx:1.25`, it first fetches the index manifest. If the index is a multi-arch index, containerd selects the manifest entry whose platform matches the host's `runtime.GOARCH` and `runtime.GOOS`. It then fetches only that specific manifest and its blobs. No blobs for other architectures are downloaded. The selected manifest digest becomes the image's identifier in containerd's metadata database, and the full index is stored in the content store but only the selected manifest's layers are extracted into snapshots. Image promotion in a CI/CD pipeline works by copying all manifests and all blobs by digest from a staging registry to a production registry — the index is created last, pointing to the already-present per-architecture manifests. This is the OCI Distribution Spec's referrers API model: you never re-compress or re-tag — you copy blobs by digest and the integrity guarantee holds automatically because the digest is the content hash.
