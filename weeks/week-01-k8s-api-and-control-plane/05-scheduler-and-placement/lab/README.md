# Lab: Scheduler & Placement

This lab demonstrates scheduler filter phase behavior through taints/tolerations, node affinity, and pod anti-affinity.

## Prerequisites

- Running Kubernetes cluster with at least 2 nodes
- kubectl 1.22+

## Step-by-Step Instructions

### 1. Taint all nodes to simulate dedicated workloads

```bash
kubectl taint nodes --all role=dedicated:NoSchedule
```

**What's happening**: Adding a taint with effect NoSchedule means pods without a matching toleration won't schedule on any node. This simulates dedicated node pools (GPU, high-memory, etc.).

**Verification**:
```bash
kubectl get nodes -o json | jq '.items[].spec.taints'
```

Expected: All nodes have the `role=dedicated:NoSchedule` taint.

---

### 2. Try to create a pod without toleration

```bash
kubectl apply -f lab/pod-no-toleration.yaml
```

**What's happening**: This pod has no tolerations, so the scheduler's TaintToleration filter plugin will exclude all nodes.

**Verification**:
```bash
kubectl get pod no-toleration
# Should show Pending state

kubectl describe pod no-toleration | grep Events -A 10
# Should show: "0/N nodes are available: N node(s) had untolerated taint"
```

**Observe**: The pod is stuck in Pending because all nodes failed the filter phase.

---

### 3. Create a pod with matching toleration

```bash
kubectl apply -f lab/pod-with-toleration.yaml
```

**What's happening**: This pod's spec includes:
```yaml
tolerations:
- key: role
  operator: Equal
  value: dedicated
  effect: NoSchedule
```

The TaintToleration filter now passes, allowing the pod to schedule.

**Verification**:
```bash
kubectl get pod with-toleration -o wide
# Should show Running state with assigned node

kubectl describe pod with-toleration | grep -i toleration -A 5
```

**Observe**: Pod successfully scheduled and is running.

---

### 4. Remove taints to restore normal scheduling

```bash
kubectl taint nodes --all role:NoSchedule-
```

**What's happening**: The trailing `-` removes the taint. Now the no-toleration pod should schedule.

**Verification**:
```bash
kubectl get pod no-toleration -w
# Watch it transition from Pending to Running

# Check node assignment
kubectl get pod no-toleration -o jsonpath='{.spec.nodeName}'
```

**Observe**: Previously-pending pod now schedules normally.

---

### 5. Test node affinity - label a node

```bash
# Get node names
kubectl get nodes

# Label one node with disktype=ssd
kubectl label nodes <node-name> disktype=ssd
```

**What's happening**: Node labels are used by NodeAffinity filter to match pod requirements.

**Verification**:
```bash
kubectl get nodes --show-labels | grep disktype
```

---

### 6. Create a pod with required node affinity

```bash
kubectl apply -f lab/pod-node-affinity.yaml
```

**What's happening**: This pod requires nodes with disktype=ssd via requiredDuringSchedulingIgnoredDuringExecution. Only the labeled node passes the NodeAffinity filter.

**Verification**:
```bash
kubectl get pod node-affinity-pod -o wide
# Check which node it's on - should be the one labeled disktype=ssd

kubectl get pod node-affinity-pod -o jsonpath='{.spec.affinity}'
```

**Observe**: Pod scheduled only on the SSD-labeled node.

**Test negative case**:
```bash
# Remove the label
kubectl label nodes <node-name> disktype-

# Delete and recreate the pod
kubectl delete pod node-affinity-pod
kubectl apply -f lab/pod-node-affinity.yaml

# Pod should be Pending now
kubectl describe pod node-affinity-pod | grep Events -A 10
# Should show: "0/N nodes are available: N node(s) didn't match Pod's node affinity"
```

---

### 7. Test pod anti-affinity - create deployment with spreading

```bash
# Restore node label first
kubectl label nodes <node-name> disktype=ssd

# Create deployment with anti-affinity
kubectl apply -f lab/deployment-anti-affinity.yaml
```

**What's happening**: This deployment has podAntiAffinity with topologyKey kubernetes.io/hostname, meaning no two replicas should be on the same node.

**Verification**:
```bash
kubectl get pods -o wide -l app=spread

# Count pods per node
kubectl get pods -l app=spread -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort | uniq -c
```

**Observe**: If you have 3 replicas and 2+ nodes, they should spread across nodes. If replicas > nodes, excess pods stay Pending due to anti-affinity.

---

### 8. Test topology spread constraints

```bash
kubectl apply -f lab/deployment-topology-spread.yaml
```

**What's happening**: TopologySpreadConstraints with maxSkew: 1 ensures at most 1 pod difference between nodes.

**Verification**:
```bash
kubectl get pods -o wide -l app=topology-spread

# Check distribution
kubectl get pods -l app=topology-spread -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort | uniq -c
```

**Observe**: Pods distribute evenly across nodes. If one node has 2 pods and another has 1, the next pod must go to the less-populated node.

---

### 9. Simulate resource pressure

```bash
# Get node allocatable resources
kubectl describe nodes | grep -A 5 "Allocatable:"

# Create a pod requesting most of a node's CPU
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: resource-hog
spec:
  containers:
  - name: stress
    image: polinux/stress
    resources:
      requests:
        cpu: "2000m"  # Adjust based on your node capacity
        memory: "2Gi"
    command: ["stress"]
    args: ["--cpu", "2", "--timeout", "600s"]
EOF

# Try to create another pod with large requests
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: resource-hog-2
spec:
  containers:
  - name: stress
    image: polinux/stress
    resources:
      requests:
        cpu: "2000m"
        memory: "2Gi"
    command: ["sleep", "3600"]
EOF
```

**What's happening**: If your cluster doesn't have enough total allocatable resources, the second pod fails NodeResourcesFit filter.

**Verification**:
```bash
kubectl describe pod resource-hog-2 | grep Events -A 10
# Should show: "Insufficient cpu" or "Insufficient memory"
```

---

### 10. Test PriorityClass and preemption

```bash
# Create PriorityClasses
kubectl apply -f - <<EOF
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: high-priority
value: 1000
globalDefault: false
description: "High priority for critical workloads"
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: low-priority
value: 100
globalDefault: false
description: "Low priority for batch jobs"
EOF

# Create low-priority pod consuming resources
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: low-priority-pod
spec:
  priorityClassName: low-priority
  containers:
  - name: nginx
    image: nginx:1.25
    resources:
      requests:
        cpu: "1000m"
        memory: "1Gi"
EOF

# Wait for it to run
kubectl wait --for=condition=ready pod/low-priority-pod --timeout=60s

# Create high-priority pod that causes preemption
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: high-priority-pod
spec:
  priorityClassName: high-priority
  containers:
  - name: nginx
    image: nginx:1.25
    resources:
      requests:
        cpu: "1500m"
        memory: "1Gi"
EOF

# Watch preemption happen
kubectl get pods -w
```

**What's happening**: If the cluster lacks resources for the high-priority pod, the scheduler preempts the low-priority pod to make room.

**Verification**:
```bash
kubectl get events --sort-by='.lastTimestamp' | grep -i preempt
```

---

## Cleanup

```bash
kubectl delete pods --all
kubectl delete deployments --all
kubectl delete priorityclasses high-priority low-priority
kubectl label nodes --all disktype-
kubectl taint nodes --all role:NoSchedule-
```

---

## Key Takeaways

1. **Taints repel pods** unless they have matching tolerations
2. **Node affinity** pulls pods to nodes with specific labels
3. **Pod anti-affinity** spreads pods across topology domains
4. **Topology spread constraints** enforce even distribution with maxSkew
5. **Resource requests** are hard constraints - pods won't schedule without sufficient capacity
6. **PriorityClass** determines scheduling order and enables preemption
7. **Scheduler is pessimistic** - decisions are based on state at scheduling time

## Extension Ideas

- Write a custom scheduler using the scheduler framework
- Implement a scheduler extender webhook for custom logic
- Explore scheduler profiles for multiple scheduling policies
- Use descheduler to rebalance pods after cluster changes
