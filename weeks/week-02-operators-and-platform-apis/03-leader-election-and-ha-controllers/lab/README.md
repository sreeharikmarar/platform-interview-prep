# Lab: Leader Election with Multiple Replicas

## Objective

Deploy a controller with multiple replicas using leader election, observe lease acquisition and renewal, simulate leader failure, and measure failover time.

## Prerequisites

- Kubernetes cluster (kind, minikube, or cloud cluster)
- kubectl configured
- Go 1.21+ (for building the controller)

## Step 1: Deploy a Leader Election Demo Controller

Create a simple controller that does nothing except compete for leadership and log status.

**controller.go:**

```go
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/leaderelection"
	"k8s.io/client-go/tools/leaderelection/resourcelock"
	"k8s.io/klog/v2"
)

func main() {
	klog.InitFlags(nil)
	flag.Parse()

	// Get pod name and namespace from environment
	podName := os.Getenv("POD_NAME")
	namespace := os.Getenv("POD_NAMESPACE")
	if podName == "" || namespace == "" {
		klog.Fatal("POD_NAME and POD_NAMESPACE must be set")
	}

	// Build in-cluster config
	config, err := rest.InClusterConfig()
	if err != nil {
		klog.Fatalf("Failed to create config: %v", err)
	}

	client, err := kubernetes.NewForConfig(config)
	if err != nil {
		klog.Fatalf("Failed to create client: %v", err)
	}

	// Create resource lock for leader election
	lock := &resourcelock.LeaseLock{
		LeaseMeta: metav1.ObjectMeta{
			Name:      "demo-controller-leader",
			Namespace: namespace,
		},
		Client: client.CoordinationV1(),
		LockConfig: resourcelock.ResourceLockConfig{
			Identity: podName,
		},
	}

	// Start leader election
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	leaderelection.RunOrDie(ctx, leaderelection.LeaderElectionConfig{
		Lock:            lock,
		ReleaseOnCancel: true,
		LeaseDuration:   15 * time.Second,
		RenewDeadline:   10 * time.Second,
		RetryPeriod:     2 * time.Second,
		Callbacks: leaderelection.LeaderCallbacks{
			OnStartedLeading: func(ctx context.Context) {
				klog.Infof("🎉 %s became the LEADER", podName)
				runController(ctx, podName)
			},
			OnStoppedLeading: func() {
				klog.Warningf("❌ %s lost leadership, exiting", podName)
				os.Exit(0)
			},
			OnNewLeader: func(identity string) {
				if identity == podName {
					return
				}
				klog.Infof("ℹ️  New leader elected: %s", identity)
			},
		},
	})
}

func runController(ctx context.Context, identity string) {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			klog.Info("Context canceled, stopping controller")
			return
		case <-ticker.Tick:
			klog.Infof("✅ Leader %s is reconciling... (timestamp: %s)", identity, time.Now().Format(time.RFC3339))
		}
	}
}
```

**deployment.yaml:**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: leader-election-demo
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: demo-controller
  namespace: leader-election-demo
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: demo-controller-leader-election
  namespace: leader-election-demo
rules:
- apiGroups: ["coordination.k8s.io"]
  resources: ["leases"]
  verbs: ["get", "create", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: demo-controller-leader-election
  namespace: leader-election-demo
subjects:
- kind: ServiceAccount
  name: demo-controller
  namespace: leader-election-demo
roleRef:
  kind: Role
  name: demo-controller-leader-election
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-controller
  namespace: leader-election-demo
spec:
  replicas: 3
  selector:
    matchLabels:
      app: demo-controller
  template:
    metadata:
      labels:
        app: demo-controller
    spec:
      serviceAccountName: demo-controller
      containers:
      - name: controller
        image: your-registry/leader-election-demo:latest
        env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        resources:
          requests:
            cpu: 100m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 128Mi
```

Build and push the container image, then apply the deployment.

## Step 2: Observe Leader Election

Watch the lease object being created and updated:

```bash
# Watch the lease in real-time
kubectl get lease demo-controller-leader -n leader-election-demo -w
```

You should see the lease's HOLDER column showing one pod name, and AGE incrementing as renewTime updates.

Inspect the lease details:

```bash
kubectl get lease demo-controller-leader -n leader-election-demo -o yaml
```

Key fields:
- `spec.holderIdentity`: The pod that currently holds the lease (the leader)
- `spec.acquireTime`: When this leader first acquired the lease
- `spec.renewTime`: Last successful renewal timestamp
- `spec.leaseDurationSeconds`: How long the lease is valid (15s)

Check controller logs to see who is leader:

```bash
# Get all pod names
kubectl get pods -n leader-election-demo

# Tail logs from all replicas
kubectl logs -n leader-election-demo -l app=demo-controller --prefix=true -f
```

You should see one replica logging "became the LEADER" and periodic reconciliation messages. The other two replicas will log "New leader elected: <pod-name>" and stay quiet.

## Step 3: Simulate Leader Failure

Delete the current leader pod and observe failover:

```bash
# Identify the current leader from the lease
LEADER=$(kubectl get lease demo-controller-leader -n leader-election-demo -o jsonpath='{.spec.holderIdentity}')
echo "Current leader: $LEADER"

# Delete the leader pod
kubectl delete pod $LEADER -n leader-election-demo

# Watch the lease to see leadership transfer
kubectl get lease demo-controller-leader -n leader-election-demo -w
```

Time the failover by watching logs:

```bash
kubectl logs -n leader-election-demo -l app=demo-controller --prefix=true -f --since=30s
```

You should see:
1. Old leader stops logging (pod is deleted)
2. After ~15-17 seconds, one of the remaining replicas logs "became the LEADER"
3. New leader starts logging reconciliation messages

The failover time is approximately `LeaseDuration + RetryPeriod = 15s + 2s = 17s`.

## Step 4: Test Graceful Shutdown

Scale the deployment to trigger a rolling update, which calls graceful shutdown:

```bash
# Trigger a rolling update by changing an annotation
kubectl patch deployment demo-controller -n leader-election-demo -p '{"spec":{"template":{"metadata":{"annotations":{"restarted-at":"'$(date +%s)'"}}}}}'

# Watch the lease during the rollout
kubectl get lease demo-controller-leader -n leader-election-demo -w
```

With `ReleaseOnCancel: true`, the old leader releases the lease immediately on shutdown. A new replica should acquire leadership within `RetryPeriod = 2s`, much faster than the hard-failure case.

## Step 5: Experiment with Tuning Parameters

Edit the controller code to use tighter parameters for faster failover:

```go
leaderelection.RunOrDie(ctx, leaderelection.LeaderElectionConfig{
    Lock:            lock,
    ReleaseOnCancel: true,
    LeaseDuration:   5 * time.Second,  // Tightened from 15s
    RenewDeadline:   3 * time.Second,  // Tightened from 10s
    RetryPeriod:     1 * time.Second,  // Tightened from 2s
    // ... callbacks unchanged
})
```

Rebuild, redeploy, and repeat the leader failure test. Failover should now complete in ~6 seconds instead of ~17 seconds. However, you may see more frequent leadership flapping if the cluster is under load.

## Step 6: Observe Split-Brain Prevention

Simulate a network partition by adding iptables rules on the leader's node (requires node access):

```bash
# This requires SSH access to the node running the leader pod
# Block egress to API server from the leader pod
iptables -A OUTPUT -p tcp --dport 6443 -j DROP
```

The leader will fail to renew the lease. After `LeaseDuration`, a new leader will be elected. The old leader will detect renewal failure and call `OnStoppedLeading`, exiting the process. Check logs to confirm the old leader exited.

Remove the iptables rule to restore connectivity:

```bash
iptables -D OUTPUT -p tcp --dport 6443 -j DROP
```

The crashed pod will be restarted by the Deployment controller and become a non-leader standby.

## Expected Outcomes

- You should see exactly one leader at all times (check lease holderIdentity)
- Failover on hard crash takes `~LeaseDuration + RetryPeriod` seconds
- Graceful shutdown with `ReleaseOnCancel: true` reduces failover to `~RetryPeriod` seconds
- Tighter parameters reduce failover time but increase API load and sensitivity to transient issues
- The old leader always exits when it loses leadership, preventing split-brain

## Clean Up

```bash
kubectl delete namespace leader-election-demo
```

## Key Takeaways

- Leader election prevents duplicate reconciliation work when running multiple controller replicas
- The Lease object in `coordination.k8s.io/v1` stores leadership state with optimistic concurrency
- Failover time is tunable via `LeaseDuration`, `RenewDeadline`, and `RetryPeriod`
- Graceful shutdown with lease release enables fast failover during rolling updates
- Controllers must exit immediately when they lose leadership to prevent split-brain
