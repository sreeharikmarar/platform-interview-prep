# Lab: Container Internals — OCI Spec, containerd, and runc

This lab walks through the container stack from the bottom up. You will inspect the OCI content-addressable store directly, generate a raw OCI runtime spec with runc, explore the CRI layer with crictl, and build a container from scratch using only a static binary and runc — with no Docker, no containerd, and no kubelet involved. Each step targets a specific layer of abstraction so you can see exactly what each tool does and does not do.

## Prerequisites

- Linux host or VM (macOS does not run Linux containers natively)
- `containerd` 1.7+ installed and running (`systemctl status containerd`)
- `ctr` installed (ships with containerd)
- `crictl` 1.28+ installed
- `runc` installed (version ≥ 1.1)
- `jq` and `curl` available
- Root access (most operations require root or the `containerd` group)

> **macOS users**: Run the week-00 lab container — it has `containerd`, `ctr`, `crictl`, and `runc` pre-installed and running. This replaces the kind-node workaround:
> ```bash
> cd weeks/week-00-linux-containers-and-cloud-networking
> ./lab-start.sh --build   # first time
> ./lab-start.sh           # subsequent runs
> ```
> Inside the container, lab scripts are at `/labs/03/`. containerd starts automatically via the entrypoint.

Verify all tools are present:
```bash
containerd --version
ctr version
crictl version
runc --version
jq --version
```

---

## Step 1: Pull an image and inspect the content-addressable store

```bash
# Pull a small image into containerd's k8s.io namespace
# (k8s.io is the namespace kubelet uses; ctr defaults to "default" namespace)
ctr -n k8s.io images pull docker.io/library/alpine:3.19
```

**What's happening**: containerd fetches the image index from Docker Hub, selects the linux/amd64 manifest, downloads each layer as a compressed tar blob, stores the blobs in the content store keyed by their SHA-256 digest, and creates snapshot entries for each layer in the overlayfs snapshotter.

**Verification**:
```bash
# List images in the k8s.io namespace
ctr -n k8s.io images ls | grep alpine

# The image name maps to a manifest digest
# Note the digest column — this is the manifest's SHA-256
ctr -n k8s.io images ls --format='table {{.Name}} {{.Digest}}'
```

---

Now inspect the manifest directly from the content store:

```bash
# Find the manifest digest from the image list
MANIFEST_DIGEST=$(ctr -n k8s.io images ls | grep "alpine:3.19" | awk '{print $2}')
echo "Manifest digest: $MANIFEST_DIGEST"

# The content store lives at /var/lib/containerd/io.containerd.content.v1.content/blobs/sha256/
BLOB_DIR="/var/lib/containerd/io.containerd.content.v1.content/blobs/sha256"
DIGEST_HEX="${MANIFEST_DIGEST#sha256:}"

# Read the manifest JSON directly from the blob file
cat "${BLOB_DIR}/${DIGEST_HEX}" | jq .
```

**What's happening**: The manifest is stored as a plain file on disk at `blobs/sha256/<hex>`. The file content is exactly what the registry served. The manifest JSON lists: `mediaType` (identifies this as a manifest), `config` (digest of the config blob), and `layers` (array of layer descriptors each with a digest, size, and mediaType).

**Verification**:
```bash
# Extract and inspect the config blob
CONFIG_DIGEST=$(cat "${BLOB_DIR}/${DIGEST_HEX}" | jq -r '.config.digest' | sed 's/sha256://')
cat "${BLOB_DIR}/${CONFIG_DIGEST}" | jq '{Cmd: .config.Cmd, Entrypoint: .config.Entrypoint, Env: .config.Env, WorkingDir: .config.WorkingDir, DiffIDs: .rootfs.diff_ids}'
# Expected: shows alpine's default Cmd (/bin/sh), empty Entrypoint, and 1-2 layer diff IDs
```

---

## Step 2: Explore layer storage and deduplication

```bash
# List all blobs in the content store with their sizes
ctr -n k8s.io content ls

# Pull a second image that shares alpine as a base (if you have one)
# For demonstration, pull another alpine variant to see deduplication
ctr -n k8s.io images pull docker.io/library/alpine:3.18

# Count total blobs — if alpine 3.19 and 3.18 share layers, the count
# increases by less than the full layer set of the second image
ctr -n k8s.io content ls | wc -l
```

**What's happening**: Each blob is stored exactly once. When alpine:3.18 is pulled, containerd checks the content store for each blob digest before fetching. Any blob already present is skipped. The registry returns the digest in the manifest, and containerd checks the local CAS — if found, the `pull` skips the download entirely. This is content-addressable deduplication: same content = same digest = same file on disk.

**Verification**:
```bash
# Show blobs sorted by size (largest first)
ctr -n k8s.io content ls | sort -k2 -h -r | head -10

# Check if the alpine layer blob is referenced by both images
# Find layer digests from each image's manifest
LAYER_DIGEST_319=$(ctr -n k8s.io images ls | grep "alpine:3.19" | awk '{print $2}' | \
  xargs -I{} bash -c "cat ${BLOB_DIR}/{#sha256:} | jq -r '.layers[0].digest'" 2>/dev/null || \
  cat "${BLOB_DIR}/${DIGEST_HEX}" | jq -r '.layers[0].digest')
echo "Alpine 3.19 layer 0: $LAYER_DIGEST_319"

# Verify the blob file exists for this digest
ls -lh "${BLOB_DIR}/${LAYER_DIGEST_319#sha256:}"
```

---

## Step 3: Inspect the snapshotter's overlay layer stack

```bash
# List snapshots — these are the uncompressed, mounted-ready layer directories
ctr -n k8s.io snapshots ls

# The overlayfs snapshotter stores snapshots here:
SNAPSHOT_DIR="/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots"
ls "$SNAPSHOT_DIR"

# Each numeric directory is a snapshot. Find the ones for alpine.
# The 'parent' column in snapshots ls shows the layer chain.
# Inspect the actual filesystem of a base layer snapshot
BASE_SNAPSHOT=$(ctr -n k8s.io snapshots ls | grep -v "^KIND" | head -2 | tail -1 | awk '{print $1}')
echo "Inspecting snapshot: $BASE_SNAPSHOT"

# Look at the filesystem inside a snapshot
SNAP_ID=$(ls "$SNAPSHOT_DIR" | head -1)
ls "$SNAPSHOT_DIR/$SNAP_ID/fs/" 2>/dev/null | head -20
```

**What's happening**: The snapshotter decompresses each layer tar and stores the contents as a real directory tree (not a tar file). For overlayfs, these directories are the lowerdir layers. When a container starts, the overlayfs mount references these directories as immutable lowerdirs and adds a fresh writable upperdir for container-specific writes.

**Verification**:
```bash
# Run a container and observe the overlayfs mount
ctr -n k8s.io run --rm docker.io/library/alpine:3.19 test-overlay sh -c \
  "cat /proc/mounts | grep overlay"
# Expected: one overlay mount with multiple lowerdir entries (each is a snapshot directory)
# The upperdir is the container's writable layer
```

---

## Step 4: Generate an OCI runtime spec with runc spec

```bash
# Create a working directory for our OCI bundle
mkdir -p /tmp/oci-demo/rootfs

# Generate a default OCI runtime spec (config.json)
cd /tmp/oci-demo
runc spec

# Inspect the generated config.json
cat /tmp/oci-demo/config.json | jq '{
  ociVersion: .ociVersion,
  process: .process | {args, env: .env[:3], user, capabilities: {bounding: .capabilities.bounding[:5]}},
  root: .root,
  mounts: [.mounts[] | select(.type == "proc" or .type == "tmpfs" or .destination == "/dev")],
  namespaces: [.linux.namespaces[].type],
  cgroupsPath: .linux.cgroupsPath
}'
```

**What's happening**: `runc spec` generates the complete OCI Runtime Spec v1.1 config.json with default values. The spec defines: `process.args` (what to execute), `root.path` (where the rootfs is), `mounts` (what to bind-mount into the container), `linux.namespaces` (which namespaces to create — by default: pid, network, ipc, uts, mount, and cgroup), `linux.cgroupsPath` (cgroup path to place this container in), and `linux.seccomp` (the seccomp filter profile — generated with a large allowlist of safe syscalls). This is exactly what containerd generates and passes to runc when starting a real container.

**Verification**:
```bash
# Show the namespace types — by default runc creates all 6 namespaces
cat /tmp/oci-demo/config.json | jq '[.linux.namespaces[].type]'
# Expected: ["pid", "ipc", "uts", "mount", "network", "cgroup"] (order may vary)

# Show the default capabilities given to a container
cat /tmp/oci-demo/config.json | jq '.process.capabilities.bounding | length'
# Expected: approximately 14 capabilities — far fewer than root's full set
```

---

## Step 5: Inspect the CRI layer with crictl

crictl speaks the CRI gRPC protocol directly to containerd, giving you the kubelet's view of the container world.

```bash
# Configure crictl to talk to containerd's CRI socket
cat > /etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF

# List pod sandboxes (these are the pause containers / pod sandboxes)
crictl pods

# List containers (application containers, distinct from sandboxes)
crictl ps -a

# Pull an image via CRI (the same path kubelet uses)
crictl pull docker.io/library/busybox:1.36

# List images as CRI sees them
crictl images | grep busybox
```

**What's happening**: crictl uses the CRI gRPC API (`ImageService` and `RuntimeService` services) defined in `k8s.io/cri-api`. This is a different interface than `ctr` which uses containerd's internal API. kubelet only ever calls `RunPodSandbox`, `CreateContainer`, `StartContainer`, `StopContainer`, `RemoveContainer`, `ImagePull`, `ListImages`, and related status calls. crictl exposes these same calls in a debuggable CLI form.

**Verification**:
```bash
# Inspect a running sandbox (if any pods are running)
SANDBOX_ID=$(crictl pods -q | head -1)
if [ -n "$SANDBOX_ID" ]; then
  crictl inspectp $SANDBOX_ID | jq '{
    state: .status.state,
    createdAt: .status.createdAt,
    namespace: .status.labels["io.kubernetes.pod.namespace"],
    podName: .status.labels["io.kubernetes.pod.name"],
    ip: .status.network.ip
  }'
fi

# Inspect a running container (if any are running)
CONTAINER_ID=$(crictl ps -q | head -1)
if [ -n "$CONTAINER_ID" ]; then
  crictl inspect $CONTAINER_ID | jq '{
    state: .status.state,
    image: .status.image.image,
    pid: .info.pid
  }'
fi
```

---

## Step 6: Examine the containerd metadata database

```bash
# The boltdb metadata file is the authoritative index of all containerd state
ls -lh /var/lib/containerd/io.containerd.metadata.v1.bolt/meta.db

# ctr provides a way to inspect various metadata objects
# List all containers in the k8s.io namespace (these are running container records)
ctr -n k8s.io containers ls

# List all tasks (tasks = running processes / containers with PIDs)
ctr -n k8s.io tasks ls

# If any task is running, inspect its details
TASK_ID=$(ctr -n k8s.io tasks ls -q | head -1)
if [ -n "$TASK_ID" ]; then
  ctr -n k8s.io tasks ps $TASK_ID
  # Shows all processes inside the container
fi
```

**What's happening**: containerd's boltdb stores labels, container metadata, image manifests, snapshot references, and lease information. The actual data (blobs, snapshot directories) lives on the filesystem; boltdb is the index. `ctr containers ls` reads from boltdb, not from the running process table — it shows containers that have been created (config stored in boltdb) whether or not they are running. `ctr tasks ls` shows currently running tasks (containers with active PIDs).

**Verification**:
```bash
# Show the raw size of the boltdb metadata file
# In a cluster with many pods, this grows to several MB
du -sh /var/lib/containerd/io.containerd.metadata.v1.bolt/meta.db

# List all containerd namespaces (default, k8s.io, moby for Docker integration)
ctr namespaces ls
```

---

## Step 7: Run a container with runc directly (no containerd)

This step runs a real container using only runc — no containerd, no kubelet, no CRI. You need to provide the rootfs and the config.json manually.

```bash
# Create the rootfs by extracting a minimal Alpine filesystem
mkdir -p /tmp/runc-demo/rootfs

# Extract the Alpine layer directly from the content store blob
# Find the layer blob digest from the manifest we inspected earlier
ALPINE_MANIFEST=$(cat "${BLOB_DIR}/${DIGEST_HEX}" 2>/dev/null)
if [ -z "$ALPINE_MANIFEST" ]; then
  # Re-derive the digest
  MANIFEST_DIGEST=$(ctr -n k8s.io images ls | grep "alpine:3.19" | awk '{print $2}')
  DIGEST_HEX="${MANIFEST_DIGEST#sha256:}"
  BLOB_DIR="/var/lib/containerd/io.containerd.content.v1.content/blobs/sha256"
  ALPINE_MANIFEST=$(cat "${BLOB_DIR}/${DIGEST_HEX}")
fi

LAYER_DIGEST=$(echo "$ALPINE_MANIFEST" | jq -r '.layers[0].digest' | sed 's/sha256://')
echo "Layer digest: $LAYER_DIGEST"

# Extract the compressed tar layer into rootfs/
# The blob is a gzip-compressed tar
zcat "${BLOB_DIR}/${LAYER_DIGEST}" | tar -xf - -C /tmp/runc-demo/rootfs/

# Verify the rootfs has a real Linux filesystem layout
ls /tmp/runc-demo/rootfs/

# Generate the OCI config.json
cd /tmp/runc-demo
runc spec

# Modify the spec: change the command to run a simple echo
# and disable the network namespace (no CNI available here) for simplicity
python3 -c "
import json
with open('config.json') as f:
    spec = json.load(f)
# Change the process to run a simple command
spec['process']['args'] = ['/bin/sh', '-c', 'echo Hello from inside runc; uname -a; cat /etc/alpine-release']
# Remove the terminal requirement (we are not interactive)
spec['process']['terminal'] = False
# Write back
with open('config.json', 'w') as f:
    json.dump(spec, f, indent=2)
print('config.json updated')
"

# Run the container
# 'run' = create + start + delete in one command
runc run demo-container
```

**What's happening**: runc reads `config.json` and `rootfs/` from the current bundle directory. It calls `clone()` with the namespace flags from the spec, `pivot_root()` into the rootfs, sets up the mounts (/proc, /sys, /dev), applies seccomp and capabilities, and exec's `/bin/sh`. There is no daemon, no registry, no kubelet. The container runs and exits. This is the absolute minimum required to run a container on Linux.

**Verification**:
```bash
# Expected output: three lines
# Hello from inside runc
# Linux ... (kernel version of the host, shared since runc uses host kernel)
# 3.19.x (alpine release version — from the filesystem we extracted)
```

---

## Step 8: Observe the shim process lifecycle

If you have a Kubernetes cluster (via kind or otherwise), this step shows the shim process tree.

```bash
# Start a long-running pod
kubectl run shim-demo --image=alpine:3.19 -- sleep 300

# Wait for the pod to be Running
kubectl wait --for=condition=Ready pod/shim-demo --timeout=30s

# Get the container ID
CONTAINER_ID=$(kubectl get pod shim-demo \
  -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's/containerd:\/\///')
echo "Container ID: $CONTAINER_ID"

# Find the shim process on the node (inside the kind container if using kind)
# The shim process is named containerd-shim-runc-v2
ps aux | grep "containerd-shim" | grep -v grep

# Find the specific shim for our container
ps aux | grep "$CONTAINER_ID" | grep -v grep

# Show the shim's parent PID — should be 1 (init) because the shim double-forked
SHIM_PID=$(ps aux | grep "containerd-shim" | grep "$CONTAINER_ID" | awk '{print $2}' | head -1)
if [ -n "$SHIM_PID" ]; then
  echo "Shim PID: $SHIM_PID"
  cat /proc/$SHIM_PID/status | grep PPid
  # Expected: PPid: 1  (re-parented to init)
fi

# Show the sleep process running inside the container
# This is the container's PID 1 (or child of the shim in some configurations)
ps aux | grep "sleep 300" | grep -v grep
```

**What's happening**: The shim (`containerd-shim-runc-v2`) process is parented to PID 1 (init/systemd), not to containerd. runc has already exited — it is not in the process table. The sleep process is the application process, running inside the container's PID namespace but visible from the host with a host-PID-namespace PID (since the container does not hide its processes from the host's view).

**Verification**:
```bash
# Restart containerd and verify the container is still running
systemctl restart containerd
sleep 5
kubectl get pod shim-demo
# Expected: pod is still Running — the shim maintained the container through the restart

# Clean up
kubectl delete pod shim-demo
```

---

## Cleanup

```bash
# Remove the oci-demo bundle
rm -rf /tmp/oci-demo

# Remove the runc-demo bundle
rm -rf /tmp/runc-demo

# Remove the pulled images from containerd
ctr -n k8s.io images rm docker.io/library/alpine:3.19 2>/dev/null
ctr -n k8s.io images rm docker.io/library/alpine:3.18 2>/dev/null
ctr -n k8s.io images rm docker.io/library/busybox:1.36 2>/dev/null

# Run containerd GC to clean up orphaned blobs and snapshots
ctr content gc 2>/dev/null || true

# If using kind
kind delete cluster --name oci-lab 2>/dev/null || true
```

---

## Key Takeaways

1. **The OCI content store is just a directory of SHA-256-named files**: every image artifact (manifest, config, compressed layer) is a file at `blobs/sha256/<hex>`. Layer deduplication is free because two images referencing the same digest reference the same file.

2. **The snapshotter holds the uncompressed filesystem, not the content store**: the content store has compressed tars; the snapshotter has the extracted directory trees ready to use as overlayfs lowerdirs. These are two separate storage systems with different GC lifecycles.

3. **runc is a one-shot CLI tool**: it reads config.json, sets up namespaces, cgroups, mounts, and seccomp, exec's the process, and exits. It has no daemon mode. The shim is what stays alive after runc exits.

4. **CRI is the API boundary between kubelet and containerd**: crictl speaks exactly what kubelet speaks. Every kubectl action that affects pods translates into CRI calls. Understanding CRI calls is essential for debugging "ContainerCreating" hangs.

5. **The pause container is the namespace anchor, not a security feature**: it holds the network and IPC namespaces for the pod's lifetime. All application containers join those namespaces at creation time, which is why they share the pod IP.

6. **containerd restart does not kill containers**: the shim's double-fork design ensures the shim is re-parented to init and survives containerd restarts. containerd reconnects to shims by reading socket paths from the state directory on restart.

7. **From a Linux kernel perspective, a container is just a process with restricted namespace visibility**: `runc run` in step 7 demonstrated that the minimum requirements are a rootfs directory and a config.json — no daemon, no registry, no orchestration layer.
