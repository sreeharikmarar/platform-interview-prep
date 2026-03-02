# Container Internals: OCI Specs, containerd, and the Runtime Stack

## What you should be able to do

- Trace the complete path from a kubelet receiving a pod spec to a running process, naming every component, IPC boundary, and system call involved.
- Explain the OCI Image Spec and OCI Runtime Spec as distinct standards, describe the content-addressable storage model, and reason about layer deduplication on disk.
- Describe the containerd architecture — plugins, snapshotter, content store, metadata database, shim lifecycle — and explain why containerd can restart without killing containers.
- Compare gVisor and Kata Containers on isolation model, performance overhead, and the use cases that justify each in a multi-tenant platform.

## Mental Model

A container image is not a binary or a compressed archive in the traditional sense. It is a directory tree paired with a JSON configuration document, split into content-addressable tar layers and stored as opaque blobs identified only by their SHA-256 digest. When you `docker pull nginx:1.25`, you are downloading a set of compressed tarballs and two JSON documents: a manifest (which lists the layers and points to the config) and a config (which describes the environment, entrypoint, and command). Nothing about the image is a single file — it is a graph of blobs linked by digest references. This design enables automatic deduplication: if a hundred images all share the same base layer, that layer's blob is stored exactly once on disk, because its digest is identical for every image that references it.

The runtime stack that turns an image into a running process has three distinct actors with clear separation of concerns. containerd is the long-running lifecycle daemon: it owns image management, snapshot management, the content store, and the container metadata database. It speaks the CRI (Container Runtime Interface) gRPC protocol upward to kubelet, and it delegates actual process creation downward to a shim. The containerd-shim is a small per-container process that forks from containerd, then immediately orphans itself so it is parented by init (PID 1). The shim holds the container's stdio file descriptors, monitors the exit status, and reports it back to containerd. runc is the lowest layer: it reads an OCI runtime config.json, calls `clone()` with the appropriate namespace flags, configures cgroups, sets up mounts, drops capabilities, applies seccomp filters, and then exec's the user process. runc exits immediately after exec — it does not stay resident. This is why the shim must remain: something has to hold the stdio pipes and collect the exit code after runc is gone.

This three-layer decomposition is the key to understanding why Kubernetes containers survive containerd restarts. The shim, once forked, is independent of containerd. If containerd is killed and restarted, it reconnects to existing shims via their named unix socket paths (stored in the containerd state directory, typically `/run/containerd/`). The shims did not exit; they are still holding the container's stdio and monitoring its PID. This is architecturally similar to how a terminal multiplexer allows sessions to survive a client disconnect — the shim is the session server that outlives any single connection from containerd.

The pod sandbox model adds one more layer on top of this stack that is specific to Kubernetes. Before any application containers are started, kubelet instructs containerd (via CRI) to create a pod sandbox: a dedicated network namespace and IPC namespace owned by a trivial pause container. The pause container runs `/pause`, which simply sleeps forever. Its only purpose is to hold the namespace file descriptors alive — if the network namespace were created by an application container, deleting that container would destroy the namespace and break every other container in the pod. The pause container gives the namespace a stable lifetime anchored to the pod, not to any particular application container.

## Key Concepts

- **OCI Image Spec**: The Open Container Initiative specification describing how images are stored and distributed. An image consists of three artifact types: an index (also called a manifest list) that maps platform/architecture to a specific manifest, a manifest that lists the layers (as blob digests) and points to the config blob, and a config that carries the image's environment variables, entrypoint, working directory, exposed ports, and layer diff IDs in order. All three are stored as content-addressable blobs under `/var/lib/containerd/io.containerd.content.v1.content/blobs/sha256/`.

- **Content-addressable storage (CAS)**: A storage model where every artifact is addressed by a cryptographic digest of its content. The digest is both the address and the integrity check — if you retrieve a blob and its SHA-256 hash does not match the address you used to fetch it, the data was corrupted or tampered with. CAS enables deduplication across images automatically: two images that reference the same layer point to the same digest, which maps to the same on-disk blob. No copying, no symlinking — a single blob serves all references.

- **OCI Runtime Spec**: The specification for the interface between a container manager (containerd) and a low-level runtime (runc). At its core it is a `config.json` file that specifies the container's rootfs path, the process to run (args, env, uid/gid, capabilities, rlimits), the mounts to set up (bind mounts, tmpfs, proc, sysfs), the namespaces to create or join (net, pid, ipc, mount, uts, user), the cgroup path to place the container in, the seccomp profile, and SELinux or AppArmor labels. The container manager generates this config.json and calls `runc create --bundle <dir>` where `<dir>` contains `config.json` and the `rootfs/` directory.

- **runc**: The reference OCI Runtime Spec implementation, written in Go. It is a CLI binary, not a daemon. `runc create` sets up the container environment (namespaces, cgroups, mounts) but does not exec the user process — the container waits in an intermediate state. `runc start` then execs the user process inside the prepared environment and runc exits. The exec'd process has PID 1 inside the container's PID namespace (or inherits the host PID namespace if `namespaces` does not include a pid entry). After `runc start` returns, the runc binary is gone from the process table.

- **containerd-shim**: A small binary (`containerd-shim-runc-v2` for the runc runtime) that containerd forks before calling runc. The shim double-forks so it is re-parented to init and is no longer a child of containerd. It manages the container's stdio (writing logs to the log driver, proxying terminal I/O), monitors the container's PID for exit, and exposes a unix socket for containerd to reconnect after restart. The shim is the reason containers survive containerd restarts and daemon upgrades without disruption.

- **CRI (Container Runtime Interface)**: The gRPC API that kubelet uses to communicate with a container runtime. Defined in `k8s.io/cri-api`. Key RPCs: `RunPodSandbox` (create pause container + network namespace), `CreateContainer` (set up rootfs from image layers), `StartContainer` (exec the process), `StopContainer`, `RemoveContainer`, `ImagePull`, `ImageStatus`. containerd's CRI plugin implements this interface. The socket defaults to `/run/containerd/containerd.sock`. crictl is the debugging CLI for CRI.

- **Pod sandbox / pause container**: The infrastructure container created by `RunPodSandbox`. It joins the CNI network (gets the pod IP), creates the IPC namespace, and runs `/pause` — a minimal binary that does nothing except block on `pause()` system call. Every application container in the pod is created with `CreateContainer` and its network and IPC namespaces are set to the sandbox's namespaces via the `pid` and `ipc` namespace join settings in the OCI runtime config. The sandbox is the namespace anchor for the entire pod.

- **Snapshotter**: The containerd plugin responsible for assembling the container's rootfs from image layers. containerd ships multiple snapshotters: `overlayfs` (default on Linux, uses `overlay` filesystem with lower dirs as image layers and an upper writable dir), `native` (hard copy, no union mount), `devmapper` (thin-provisioned block devices), and `zfs`. The snapshotter produces a prepared directory tree that becomes the `rootfs/` inside the OCI bundle. On write, the overlayfs upper layer captures all modifications; on container removal, the upper layer is discarded while the read-only lower layers (image layers) remain unchanged.

- **Content store**: The containerd subsystem that stores raw blobs (image manifests, configs, and compressed layer tars) indexed by digest. Separate from the snapshotter: the content store holds the compressed layer data as it came from the registry; the snapshotter holds the uncompressed, mounted filesystem state ready to use as a rootfs. The content store supports garbage collection — blobs not referenced by any image manifest or snapshot can be removed with `ctr content gc`.

- **Metadata database (boltdb)**: containerd uses an embedded bbolt (BoltDB) database at `/var/lib/containerd/io.containerd.metadata.v1.bolt/meta.db` to track all containers, images, snapshots, and leases. This is the authoritative index. The actual data (blobs, snapshot directories) lives on disk; the metadata DB contains only the references and labels. If the metadata DB is lost, the content is orphaned but still exists on disk — `ctr content ls` would show nothing, but the blobs are in the CAS directory.

- **gVisor (runsc)**: A container runtime from Google that interposes a user-space kernel (the Sentry) between the application and the host kernel. The Sentry intercepts all system calls from the application and handles them within user space, only calling a limited set of host kernel syscalls for I/O (mediated through the Gofer process, which handles filesystem operations). This creates a strong isolation boundary — even a kernel exploit inside the container cannot escape through the Sentry because the Sentry is user space, not kernel space. Overhead is approximately 10-15% for CPU-bound workloads and higher for syscall-heavy or I/O-heavy workloads. Used via RuntimeClass `runsc`.

- **Kata Containers**: A container runtime that runs each container (or pod) inside a lightweight virtual machine using QEMU or Firecracker as the hypervisor. The VM has its own Linux kernel, providing hardware-enforced isolation. The container's rootfs is mounted into the VM, and the container process runs inside the VM kernel's PID namespace. The overhead is primarily VM startup latency (50-500ms, lower with Firecracker) and memory overhead per VM (the VM kernel itself consumes ~128MB+). Kata containers look like standard OCI containers to containerd but use a dedicated shim binary (`containerd-shim-kata-v2`, identified by the runtime type `io.containerd.kata.v2`). Used via RuntimeClass `kata-fc` (Firecracker) or `kata-qemu`.

- **OCI Distribution Spec**: The API that container registries implement for push and pull operations. Pull is a sequence of HTTP calls: `GET /v2/<name>/manifests/<tag>` to retrieve the manifest (by tag or digest), then `GET /v2/<name>/blobs/<digest>` for each blob (layers, config). Layers are served as gzip-compressed tar streams. Promotion of an image across registry repositories is done by copying manifests and blobs by digest — no re-compression needed because the digest remains the same.

- **RuntimeClass**: A Kubernetes resource (`node.k8s.io/v1 RuntimeClass`) that maps a runtime handler name to a container runtime configured on the node. Pods specify `spec.runtimeClassName: kata-fc` to opt into Kata. kubelet reads the RuntimeClass, looks up the handler name (e.g., `kata-fc`), and passes it to containerd's CRI endpoint as the `runtime_handler` field in `RunPodSandbox`. containerd maps the handler name to a configured shim binary in its config (`/etc/containerd/config.toml`).

## Internals

### containerd Architecture — Plugins, Snapshotter, and Shim Lifecycle

containerd is structured as a plugin host. Every major subsystem is a plugin with a defined interface: the content plugin manages blob storage, the snapshotter plugin manages filesystem layers, the images plugin tracks image metadata, the containers plugin tracks container metadata, the tasks plugin manages running containers, the events plugin streams lifecycle events, and the CRI plugin translates Kubernetes CRI gRPC calls into calls on the above plugins. This architecture means you can swap the snapshotter or add a new runtime by registering a plugin without forking containerd.

When kubelet calls `RunPodSandbox` on the CRI gRPC endpoint (default socket: `/run/containerd/containerd.sock`), containerd's CRI plugin performs these steps in order:

1. Resolve the sandbox image (pause image): check the content store for the manifest and config, pull if missing.
2. Prepare the sandbox snapshot: call the snapshotter to create a writable overlayfs layer on top of the pause image's read-only layers.
3. Generate the OCI runtime bundle: construct a `config.json` for the pause container, specifying the network namespace (initially a new namespace — CNI will configure it next), IPC namespace, mounts, and seccomp profile.
4. Call the CNI plugin chain (via the CRI plugin's CNI implementation) to configure the network namespace: assign the pod IP, set up veth pairs, configure iptables NAT rules. This happens after the namespace is created but before the sandbox container starts.
5. Fork the containerd-shim (`containerd-shim-runc-v2`) for the sandbox container. The shim double-forks and writes its PID and socket path to the containerd state directory (`/run/containerd/io.containerd.runtime.v2.task/<namespace>/<id>/`).
6. The shim calls `runc create` on the OCI bundle.
7. The shim then calls `runc start` to exec the pause process.
8. containerd returns the sandbox ID to kubelet.

For each application container, `CreateContainer` + `StartContainer` follow a similar pattern but the OCI config references the sandbox's existing network and IPC namespaces via namespace join (using the `/proc/<sandbox-pid>/ns/net` path in the config's `namespaces` array) rather than creating new ones.

If containerd crashes and restarts, it reads all shim socket paths from the state directory and reconnects to each existing shim. The shims did not exit. Containers are still running. kubelet's watch on containerd's event stream reconnects automatically and re-syncs pod states. This zero-downtime restart capability is a core design goal of containerd.

### runc Execution Path — clone, Namespace Bootstrap, and exec

runc's execution is split into two phases separated by a FIFO (`exec.fifo` in the container state directory) to allow the parent (the shim) to set up cgroup membership before the user process starts.

`runc create` performs these steps:

1. Parse `config.json`. Validate that the rootfs path exists.
2. Fork a child process. This child is the container "init" (the runc init process, not the container's PID 1 yet). The child calls `clone()` with the namespace flags from config.json: `CLONE_NEWNS` (mount), `CLONE_NEWUTS` (hostname), `CLONE_NEWIPC`, `CLONE_NEWPID`, and optionally `CLONE_NEWNET` and `CLONE_NEWUSER` (user namespaces for rootless containers). After clone, the child is inside the new namespaces.
3. Inside the new mount namespace, the child pivots the root to the bundle's `rootfs/` directory using `pivot_root()` (preferred over `chroot` because it changes the mount namespace root cleanly without leaving the old root accessible). It then bind-mounts `/proc`, `/sys`, `/dev`, and any additional mounts from config.json.
4. The child sets cgroup membership by writing its PID to the cgroup path specified in config.json (or via cgroupv2 `cgroup.procs`). The shim's parent process handles cgroup creation if needed.
5. The child drops capabilities to the set specified in `process.capabilities.bounding` and `process.capabilities.effective`. It applies seccomp filters via `prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, ...)`. It sets the uid/gid from `process.user`.
6. The child then blocks on opening the `exec.fifo` FIFO for writing, waiting for `runc start`.

`runc start` opens the `exec.fifo` for reading, which unblocks the init process. The runc init process calls `exec()` to replace itself with the user's process binary (the `args[0]` from config.json). This exec is the moment PID 1 inside the container's PID namespace becomes the user process. runc itself exits after sending the start signal.

The runc init process and the eventual exec'd process share the same PID — because exec replaces the process image in-place. The container's PID 1 in the host PID namespace is the shim's child process (the one that called `clone()`). This is the host-visible PID that systemd or cgroup v2 controllers manage.

### Image Pull and Layer Extraction — Registry API, Snapshotter Assembly, and GC

When containerd pulls an image (either via a `ctr images pull` command or because kubelet requests an image via CRI `PullImage`), the sequence is:

1. **Manifest fetch**: containerd sends `GET /v2/<repository>/manifests/<tag>` to the registry. The registry responds with a manifest JSON document and a `Content-Type` header of `application/vnd.oci.image.manifest.v1+json` (OCI) or `application/vnd.docker.distribution.manifest.v2+json` (Docker). The manifest contains a list of layer descriptors, each with a `digest` (sha256 hash of the compressed layer tar) and a `mediaType`.

2. **Config fetch**: containerd fetches the config blob at the digest referenced in the manifest's `config` field. The config is a JSON document containing the image's `Cmd`, `Entrypoint`, `Env`, `WorkingDir`, `ExposedPorts`, and the `rootfs.diff_ids` array — the sha256 hashes of each layer's *uncompressed* content (for integrity verification after decompression).

3. **Layer fetch and store**: For each layer descriptor in the manifest, containerd checks the content store for a blob at that digest. If absent, it fetches the compressed tar from the registry (`GET /v2/<repo>/blobs/<digest>`) and streams it to the content store, verifying the compressed digest as bytes arrive. The layer is stored as a compressed blob in the CAS directory. containerd does not decompress at this stage.

4. **Snapshot preparation (extraction)**: After all blobs are present in the content store, containerd calls the snapshotter's `Prepare` method for each layer in order. The snapshotter decompresses the tar and applies it as a new snapshot layer, building up the overlay stack. The decompressed content is placed in the snapshotter's working directory (e.g., `/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/<id>/fs/`). As the tar is decompressed, the snapshotter computes the SHA-256 hash of the uncompressed content on the fly and verifies it against the corresponding entry in `rootfs.diff_ids` from the config. Each snapshot is a read-only layer referenced by its parent, forming a chain from the base layer to the top layer.

5. **Container rootfs assembly**: When a container is started, the snapshotter's `Prepare` method is called one more time to create a new *writable* snapshot on top of the image's top read-only layer. For overlayfs, this writable snapshot is the overlay's upperdir. The overlay mount uses all read-only snapshot dirs as lowerdir in order. The result is a merged directory tree presented to runc as the bundle's rootfs.

6. **Garbage collection**: containerd's GC runs periodically and after delete operations. A blob in the content store is eligible for GC when no lease, no container metadata, and no image manifest references its digest. GC is mark-and-sweep: it walks all reachable digests starting from image manifests, then removes all unreachable blobs. Snapshots are also GC'd: a snapshot is removed when no container or image-prepare task references it. `ctr content gc` and `ctr snapshots gc` trigger manual GC cycles.

## Architecture Diagram

```
  kubelet
    │
    │ gRPC (CRI: RunPodSandbox, CreateContainer, StartContainer)
    ▼
  ┌─────────────────────────────────────────────────────────────────────────────┐
  │                        containerd (daemon)                                  │
  │                                                                             │
  │  ┌──────────────┐  ┌────────────────┐  ┌───────────────┐  ┌─────────────┐  │
  │  │  CRI Plugin  │  │ Content Store  │  │  Snapshotter  │  │  Metadata   │  │
  │  │ (gRPC server)│  │ (CAS blobs)    │  │ (overlayfs)   │  │  (boltdb)   │  │
  │  │              │  │                │  │               │  │             │  │
  │  │ RunPodSandbox│  │ sha256/<digest>│  │ snapshots/    │  │ containers  │  │
  │  │ CreateCtr    │  │ ← pulls from   │  │ <id>/fs/      │  │ images      │  │
  │  │ StartCtr     │  │   registry     │  │ <upper>/      │  │ snapshots   │  │
  │  └──────┬───────┘  └────────────────┘  └───────┬───────┘  └─────────────┘  │
  │         │                                       │                           │
  │         │ fork shim                             │ overlayfs lowerdir stack  │
  └─────────┼─────────────────────────────────────┼─────────────────────────-──┘
            │                                       │
            ▼                                       ▼
  ┌────────────────────────┐           ┌──────────────────────────────┐
  │  containerd-shim-runc  │           │  OCI Bundle                  │
  │  (per-container, stays │           │  /run/containerd/.../<id>/   │
  │   resident after runc  │           │  ├── config.json             │
  │   exits)               │           │  └── rootfs/  ◄──────────── overlayfs
  │                        │           │       (merged image layers   │
  │  - holds stdio pipes   │           │        + writable upper)     │
  │  - monitors exit code  │           └──────────────────────────────┘
  │  - unix socket for     │                        │
  │    containerd reconnect│                        │ runc create / runc start
  └──────────┬─────────────┘                        │
             │                                      ▼
             │ calls runc                 ┌────────────────────────┐
             └──────────────────────────► │  runc (exits after     │
                                          │  exec)                 │
                                          │                        │
                                          │  1. clone() with ns    │
                                          │     flags              │
                                          │  2. pivot_root()       │
                                          │  3. mount /proc /sys   │
                                          │  4. cgroup membership  │
                                          │  5. drop capabilities  │
                                          │  6. seccomp filter     │
                                          │  7. exec(user process) │
                                          │  8. runc exits         │
                                          └────────────────────────┘
                                                      │
                                                      ▼
                                          ┌────────────────────────┐
                                          │  container process     │
                                          │  (user's PID 1)        │
                                          │  inside namespaces:    │
                                          │  - PID namespace       │
                                          │  - mount namespace     │
                                          │  - network namespace   │
                                          │  - IPC namespace       │
                                          │  in cgroup hierarchy   │
                                          └────────────────────────┘

  Image Layer Stack (OCI Image Spec):
  ┌─────────────────────────────────────────────────────────────────┐
  │  Registry                         Disk (content-addressable)   │
  │                                                                 │
  │  index.json  (multiarch)          blobs/sha256/                 │
  │    └► manifest.json               ├── <manifest digest>         │
  │         ├── config digest         ├── <config digest>           │
  │         ├── layer[0] digest  ──►  ├── <layer0 compressed tar>   │
  │         ├── layer[1] digest  ──►  ├── <layer1 compressed tar>   │
  │         └── layer[2] digest  ──►  └── <layer2 compressed tar>   │
  │                                                                 │
  │  Snapshotter (overlayfs) view:                                  │
  │                                                                 │
  │  writable upper (container-specific) ← writes go here          │
  │  ─────────────────────────────────── overlayfs merge           │
  │  layer[2] read-only snapshot (top image layer)                  │
  │  layer[1] read-only snapshot                                    │
  │  layer[0] read-only snapshot (base)                             │
  └─────────────────────────────────────────────────────────────────┘

  Pod Sandbox Model:
  ┌─────────────────────────────────────────────────────────────────┐
  │  Pod                                                            │
  │  ┌──────────────────────────────────────────────────────────┐  │
  │  │  pause container (sandbox)                               │  │
  │  │  - owns network namespace (pod IP)                       │  │
  │  │  - owns IPC namespace                                    │  │
  │  │  - runs /pause (sleeps forever via pause() syscall)      │  │
  │  └──────────────────────────────────────────────────────────┘  │
  │  ┌───────────────────────┐  ┌───────────────────────────────┐  │
  │  │  container-A          │  │  container-B                  │  │
  │  │  joins sandbox netns  │  │  joins sandbox netns          │  │
  │  │  joins sandbox ipcns  │  │  joins sandbox ipcns          │  │
  │  │  own mount namespace  │  │  own mount namespace          │  │
  │  └───────────────────────┘  └───────────────────────────────┘  │
  └─────────────────────────────────────────────────────────────────┘
```

## Failure Modes & Debugging

### 1. Image Pull Failure — Registry Auth, Network, or Content Store Corruption

**Symptoms**: Pod stuck in `ImagePullBackOff` or `ErrImagePull`. `kubectl describe pod` shows events: `Failed to pull image: ... unauthorized: authentication required` or `... connection refused` or `... blob unknown`. `ctr images pull` returns an error. The image is partially present on disk (some blobs exist, manifest missing or corrupt).

**Root Cause**: Image pull failures cluster into three categories. Authentication failure: the kubelet's image pull secret is wrong, expired, or not referenced in the pod spec; the registry returns 401 and containerd logs `unauthorized`. Network failure: a transient connection error or DNS resolution failure during blob download leaves the content store with an incomplete image — the manifest was written but a layer blob is missing. Content store corruption: a crash during a blob write left a blob file that exists on disk but whose content does not match its digest; containerd detects the mismatch at next pull and fails with a `digest mismatch` error. The corrupted blob blocks subsequent pulls because containerd finds the blob in the store (by path) and trusts it without re-verifying, then fails when the snapshotter tries to decompress it.

**Blast Radius**: All pods scheduling onto nodes that cannot pull the image are stuck in `ImagePullBackOff`. If the image is a sidecar injected by a webhook (e.g., an Istio proxy), this can block all pod creation cluster-wide. Registry authentication failures during a credential rotation window can simultaneously affect all nodes attempting to pull new images, causing a cluster-wide scheduling stall.

**Mitigation**: Use image pull secrets with explicit `imagePullPolicy: IfNotPresent` for stable image tags to avoid re-pulling unnecessarily. Cache images in a registry mirror co-located in the same region. Monitor `kube_pod_container_status_waiting_reason{reason="ImagePullBackOff"}` metric. For content store corruption, remove the corrupt blob explicitly (`ctr content rm <digest>`) and re-pull. For credential expiry, automate secret rotation via external-secrets-operator and ensure registry tokens have appropriate TTL.

**Debugging**:
```bash
# Describe the pod to see pull error details
kubectl describe pod <pod-name> -n <namespace> | grep -A20 "Events:"

# Check containerd's view of images on the node
# (exec into the node or use a DaemonSet with hostPath /run/containerd)
ctr -n k8s.io images ls | grep <image-name>

# Pull the image manually with verbose output to see which blob fails
ctr -n k8s.io images pull --debug <image:tag> 2>&1 | tail -30

# List all blobs in the content store and check for size 0 (incomplete writes)
ctr -n k8s.io content ls | awk '{if ($2 == "0B") print $0}'

# Verify a specific blob's digest matches its stored content
ctr -n k8s.io content get <digest> | sha256sum
# The output hash should match the digest value after "sha256:"

# Check registry authentication (test the pull secret directly)
kubectl get secret <pull-secret> -n <namespace> -o jsonpath='{.data.\.dockerconfigjson}' | \
  base64 -d | jq '.auths'

# Check containerd logs on the node for the pull error
journalctl -u containerd --since "10 minutes ago" | grep -i "pull\|image\|digest"
```

---

### 2. Shim Leak — Orphaned Shim After runc Crash

**Symptoms**: `kubectl delete pod` hangs — the pod is in `Terminating` state indefinitely. `ctr -n k8s.io tasks ls` shows a task in `STOPPED` state. The container process is gone but the shim process is still visible in the host process table (`ps aux | grep containerd-shim`). containerd logs show repeated attempts to wait on the task. Node resource usage does not decrease after pod deletion.

**Root Cause**: runc crashed during container startup or during `runc delete` — the cleanup sequence that removes the cgroup and namespace entries. The shim holds the container's task state. If the shim exits abnormally (OOM-killed, SIGKILL from outside containerd), containerd loses the connection to the task and cannot determine the exit status. The pod Terminating state is driven by kubelet waiting for the CRI `RemoveContainer` call to succeed, but containerd's `tasks.Delete` call fails because the shim is gone. In some failure modes the shim is still alive but stuck — its internal goroutine blocked on a read from the container's stdio that will never arrive because the container's pty or pipe was closed.

**Blast Radius**: The affected pod holds the node's network namespace and cgroup resources. The pod's IP is not released back to the CNI IPAM pool, so the IP is leaked. If the node is running near its pod limit, the leaked pod slot prevents new pods from being scheduled. Repeated shim leaks (e.g., from an application that frequently OOM-crashes) can accumulate cgroup hierarchies that are never cleaned up, increasing kernel memory usage.

**Mitigation**: Set `terminationGracePeriodSeconds` to a conservative value (30-60 seconds). Monitor for pods stuck in `Terminating` longer than the termination grace period (`kube_pod_deletion_timestamp` metric). The containerd state directory cleanup (`ctr -n k8s.io tasks delete --force <task-id>`) is the emergency recovery path. Implement node-level health checks that alert when containerd task state diverges from kubelet pod state. containerd 1.7+ improved shim recovery with better reconnection logic.

**Debugging**:
```bash
# Find pods stuck in Terminating
kubectl get pods -A --field-selector=status.phase=Running | grep Terminating

# Check the containerd task state for the stuck pod
# The task ID is the container ID from kubectl
CONTAINER_ID=$(kubectl get pod <pod-name> -n <namespace> \
  -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's/containerd:\/\///')
ctr -n k8s.io tasks ls | grep "$CONTAINER_ID"

# List shim processes on the node
ps aux | grep "containerd-shim" | grep -v grep

# Check if the shim process for the container is alive
# The shim process name includes the container ID
ps aux | grep "$CONTAINER_ID"

# Inspect the containerd state directory for orphaned sockets
ls /run/containerd/io.containerd.runtime.v2.task/k8s.io/

# Force-delete the containerd task (recovery procedure)
ctr -n k8s.io tasks delete --force "$CONTAINER_ID"

# After task deletion, force-remove the container metadata
ctr -n k8s.io containers delete "$CONTAINER_ID"

# Force-remove the pod if kubelet hasn't reconciled yet
kubectl delete pod <pod-name> -n <namespace> --force --grace-period=0

# Check containerd logs for shim connection errors
journalctl -u containerd --since "30 minutes ago" | grep -i "shim\|task\|exit"
```

---

### 3. Sandbox Creation Failure — Missing Pause Image or CNI Error

**Symptoms**: Pod stuck in `ContainerCreating` state. `kubectl describe pod` shows events like `Failed to create pod sandbox: rpc error: code = Unknown desc = failed to create containerd task: ... image not found` or `networkPlugin cni failed to set up pod ... network: ... exec: ... plugin returned error`. No application containers start — the pod never progresses past sandbox creation. `crictl pods` shows the sandbox in `NotReady` state.

**Root Cause**: Two distinct failure modes. Pause image missing: the node cannot pull the `registry.k8s.io/pause:3.9` (or cluster-configured pause image) because the node has no internet access, the image was not pre-loaded, or the pull secret for a private mirror is wrong. This blocks `RunPodSandbox` because containerd must start the pause container before configuring the network. CNI failure: the CNI plugin binary is absent from `/opt/cni/bin/`, the CNI config in `/etc/cni/net.d/` is malformed, the CNI plugin itself encounters an error (IP pool exhausted, IPAM database locked, prerequisite kernel module not loaded), or the CNI binary returns a non-zero exit code. CNI is called synchronously during sandbox creation; any CNI error causes `RunPodSandbox` to fail.

**Blast Radius**: All new pods on the affected node fail to start. Existing pods are unaffected (they already have network namespaces). If the CNI failure is due to IP exhaustion, the blast radius extends to all nodes using the same IP range — no new pods can be scheduled cluster-wide until IPs are released. For pause image failures, nodes in an air-gapped environment that were not pre-loaded with the pause image are completely unable to run pods after restart.

**Mitigation**: Pre-load the pause image on all nodes during node bootstrap (`ctr images pull registry.k8s.io/pause:3.9` in the node startup script). Configure containerd with `sandbox_image` in `/etc/containerd/config.toml` to use a private mirror and ensure the mirror is reachable from nodes. Monitor IP pool utilization via the CNI IPAM backend metrics (Calico: `ipam_blocks_per_node`, Flannel: IPAM annotations on nodes). Alert on `kube_pod_container_status_waiting_reason{reason="ContainerCreating"}` persisting beyond 2 minutes.

**Debugging**:
```bash
# Describe the pod for event details
kubectl describe pod <pod-name> -n <namespace> | grep -A30 "Events:"

# Check the pause image status on the node
# (must be on the node or exec through a DaemonSet)
ctr -n k8s.io images ls | grep pause

# Pull the pause image manually if missing
ctr -n k8s.io images pull registry.k8s.io/pause:3.9

# Check crictl for sandbox state (CRI-level view)
crictl pods | grep <pod-name>

# Get sandbox ID and inspect it
SANDBOX_ID=$(crictl pods | grep <pod-name> | awk '{print $1}')
crictl inspectp $SANDBOX_ID | jq '.status.state'

# Check the CNI configuration on the node
ls -la /etc/cni/net.d/
cat /etc/cni/net.d/*.conf* 2>/dev/null || cat /etc/cni/net.d/*.conflist 2>/dev/null

# Verify CNI plugin binaries are present
ls -la /opt/cni/bin/

# Check kubelet logs for CNI errors
journalctl -u kubelet --since "10 minutes ago" | grep -i "cni\|sandbox\|network" | tail -20

# Check containerd logs for RunPodSandbox errors
journalctl -u containerd --since "10 minutes ago" | grep -i "sandbox\|pause\|cni" | tail -20

# Test CNI plugin directly (requires knowing the network namespace path)
# ip netns list   # list network namespaces
# ip netns exec <nsname> ip addr  # inspect IP assignment
```

---

### 4. gVisor Syscall Panic — Unimplemented Syscall

**Symptoms**: Container using `runtimeClassName: gvisor` crashes immediately or after a specific operation. `kubectl logs` shows a kernel panic or signal 31 (SIGSYS). The application's error message references a syscall number or name: `bad system call`, `operation not supported`, or specific Go runtime errors like `signal: bad system call`. The container's exit code is 159 (128 + SIGSYS). The Sentry's log (accessible on the node under `/tmp/runsc.*/` or via containerd task log) shows `ERROR: sentry: Starting sandbox ... Sentry returned error: E(...) unimplemented call: ...`.

**Root Cause**: gVisor's Sentry implements approximately 230 of the ~400+ Linux system calls available in the host kernel. Calls that are missing or only partially implemented (e.g., `io_uring`, certain `ioctl` variants, `perf_event_open`, `bpf`, some `setsockopt` options) cause the Sentry to either return `ENOSYS` (which may cause the application to handle it gracefully) or to deliver SIGSYS to the calling process (if the seccomp profile inside gVisor is configured to kill on unimplemented calls). Applications with complex kernel dependencies — databases using `io_uring` for I/O, eBPF-based observability agents, network programming using `SO_ATTACH_FILTER` — are common failure cases.

**Blast Radius**: Affects only the individual container using the gVisor runtime. Other containers on the same node and other pods are unaffected because gVisor's isolation is at the container level — the Sentry is per-container (or per-pod if configured in pod-shared mode). The failure is deterministic and reproducible: the same syscall will always fail.

**Mitigation**: Test applications against gVisor in a non-production environment before scheduling them onto gVisor nodes. Check the gVisor compatibility documentation for the application's language runtime (Go, Java, Python) and dependencies. For databases, benchmark whether gVisor overhead is acceptable before committing. Provide an escape hatch: use a separate node pool without gVisor for workloads that are incompatible, controlled via `nodeSelector` or `nodeAffinity` on the RuntimeClass. Enable `--debug` on `runsc` temporarily to capture the full Sentry log with the offending syscall name.

**Debugging**:
```bash
# Check pod status and exit code
kubectl get pod <pod-name> -n <namespace> -o jsonpath='{.status.containerStatuses[0].state}'

# Check pod logs — may show "bad system call" or application-specific error
kubectl logs <pod-name> -n <namespace>

# Describe pod to see OOMKilled vs. SIGSYS (exit code 159 = SIGSYS)
kubectl describe pod <pod-name> -n <namespace> | grep -E "Exit Code|Reason|Signal"

# On the node: find the runsc log directory (requires node access)
ls /tmp/runsc.*/
# Log files are named like: boot.log, sandbox.log, gofer.log
cat /tmp/runsc.*/boot.log 2>/dev/null | grep -i "unimplemented\|syscall\|error" | tail -20

# Identify the exact unimplemented syscall
cat /tmp/runsc.*/sandbox.log 2>/dev/null | grep "Unimplemented" | head -10

# Run the container image with plain runc to confirm the same workload works outside gVisor
# (create a test pod with runtimeClassName omitted or set to the default)
kubectl run test-runc --image=<same-image> --restart=Never -- <same-command>
kubectl logs test-runc
kubectl delete pod test-runc

# Verify the RuntimeClass is correctly configured on the node
kubectl get runtimeclass gvisor -o yaml
kubectl describe node <node> | grep -i "runtime\|gvisor"

# Check containerd handler configuration for gVisor
# On the node: /etc/containerd/config.toml should have:
# [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.gvisor]
#   runtime_type = "io.containerd.runsc.v1"
```

## What to commit

- This README in `03-container-internals-oci-and-runtimes/README.md`
- Talk tracks, lab README, and lab script in the corresponding subdirectories
