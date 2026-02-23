# Week 00: Linux, Containers & Cloud Networking Foundations

## Overview

This week covers the foundational Linux primitives and cloud networking concepts that underpin everything in weeks 01-04. Containers are not a kernel primitive — they are an orchestration of cgroups, namespaces, overlayfs, and signal delivery. Kubernetes networking assumes a flat pod network that only makes sense once you understand veth pairs, bridges, and CNI. Cloud-provider cluster provisioning (VPC-native mode, secondary CIDR ranges, SNAT) is where most production IP exhaustion failures originate.

Senior/staff platform engineering interviews probe these foundations to distinguish candidates who can debug below the Kubernetes abstraction layer from those who cannot.

## Learning Objectives

By the end of this week, you should be able to:

- Trace a container from `docker run` down to `clone()`, cgroups writes, and overlayfs mounts
- Explain PID 1 signal handling and why poorly-written entrypoints cause slow rolling updates
- Map `resources.limits.memory: 256Mi` to the exact cgroup knob that triggers OOM kill
- Diagnose CPU throttling in pods that appear to use well below their CPU limit
- Walk through the OCI image spec layer-by-layer and explain content-addressable storage
- Describe the containerd → shim → runc execution chain and why containerd can restart without killing containers
- Trace a packet from pod A on node 1 to pod B on node 2 through veth, bridge, and VXLAN
- Design VPC subnetting for a 500-node GKE cluster with correct CIDR math and exhaustion headroom

## Topics

1. **Linux Processes, Signals & Filesystem** — fork/exec, PID 1, signal delivery, VFS, /proc, capabilities, seccomp
2. **cgroups & Namespaces** — the two orthogonal primitives that combine to form containers; v1 vs v2, OOM kill chain, CPU throttling, overlayfs
3. **Container Internals, OCI Runtime & containerd** — image spec, runtime spec, containerd → shim → runc chain, CRI, pause container, gVisor/Kata
4. **Container Networking, CNI & the Pod Network Model** — veth pairs, bridges, iptables, CNI spec, overlay vs underlay, eBPF, kube-proxy modes
5. **Cloud Networking — VPC, Subnets, SNAT/DNAT & K8s IP Planning** — VPC-native mode, primary/secondary ranges, Cloud NAT, IP exhaustion diagnosis

## Suggested Study Order

1. **Linux Processes** first — establishes syscall-level understanding of how programs run
2. **cgroups & Namespaces** second — builds on processes to add isolation and resource limits
3. **Container Internals** third — combines cgroups + namespaces + overlayfs into the full container runtime stack
4. **Container Networking** fourth — extends namespace concepts to network isolation and the pod model
5. **Cloud Networking** fifth — lifts networking to VPC/cloud level and connects to Kubernetes IP planning

Each topic takes 2-3 hours including reading, lab, and talk track practice.

## Connection to Platform Engineering

These foundations appear in nearly every platform engineering scenario:

- **Slow rolling updates**: Understanding PID 1 signal handling explains why `docker stop` takes 30 seconds when the entrypoint is a shell wrapper — the container runtime sends SIGTERM but bash ignores it, falling through to SIGKILL after the grace period
- **Pod OOMKilled mysteries**: Tracing `resources.limits.memory` through cgroup `memory.max` to the kernel's OOM kill chain explains why the sidecar (not the app) gets killed
- **CPU throttling at low utilization**: CFS bandwidth controller enforces quota per period — a multi-threaded app can exhaust its quota in 10ms and be throttled for the remaining 90ms, appearing throttled at 40% average utilization
- **Container image optimization**: Understanding content-addressable layers, overlayfs copy-on-write, and the containerd content store explains why multi-stage builds and layer ordering matter for pull performance
- **CNI troubleshooting**: When pods are stuck in `ContainerCreating`, understanding the CNI binary → IPAM → veth → bridge chain tells you exactly where to look
- **Cluster IP exhaustion**: The #1 operational failure in under-planned GKE clusters — understanding primary vs secondary ranges, max-pods-per-node allocation, and VPC peering overlap constraints lets you design for 2x headroom

## Prerequisites

- Linux machine or VM (labs use `unshare`, `nsenter`, `/proc`, cgroup filesystem)
- Docker or containerd installed for container runtime labs
- `kubectl` and a running cluster for CNI and IP planning exercises
- Familiarity with basic Linux commands (`ps`, `ip`, `iptables`)
