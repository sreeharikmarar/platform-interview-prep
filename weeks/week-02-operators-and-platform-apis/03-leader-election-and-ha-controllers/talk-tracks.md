# Talk Tracks: Leader Election & HA Controllers

## Q: Explain leader election in one minute.

**Answer:**

Leader election ensures only one controller replica performs external mutations at a time, preventing duplicate API calls, double-provisioning of cloud resources, or conflicting updates. Controllers use client-go's leaderelection library, which creates a Lease object in the cluster. Replicas compete to acquire the lease by writing their identity with a timestamp. The replica that successfully writes becomes the leader and starts its reconciliation workers. It continuously renews the lease every RenewDeadline (default 10s). Other replicas watch the lease and wait.

If the leader fails to renew—due to crash, network partition, or GC pause exceeding RenewDeadline—the lease expires after LeaseDuration (default 15s). Non-leader replicas detect this and compete to acquire the expired lease. One wins, becomes the new leader, and takes over reconciliation. Failover typically completes in 15-30 seconds depending on tuning. Crucially, the old leader must stop reconciling immediately when it loses the lease, even if it's still running, to prevent split-brain scenarios where two replicas think they're leader.

**If they push deeper:**

The Lease object is stored in etcd with optimistic concurrency control. When a replica attempts to acquire the lease, it tries to update the Lease with its identity. If another replica wrote first, the update fails with a conflict error and the loser backs off. This uses etcd's compare-and-swap semantics—only one writer can succeed. The lease holder's identity is recorded in spec.holderIdentity, typically the pod name. The lease also tracks spec.acquireTime (when leadership was first acquired) and spec.renewTime (last successful renewal). Non-leaders watch renewTime and calculate time since last renewal; if it exceeds LeaseDuration, they attempt acquisition.

## Q: Why is leader election necessary for controllers?

**Answer:**

Controllers reconcile desired state from the Kubernetes API into external reality—creating load balancers, provisioning persistent volumes, calling external APIs. Without leader election, running multiple controller replicas for high availability would cause each replica to independently perform these actions. If you have 3 replicas of a DNS controller and a Service is created, all 3 replicas would try to create DNS records, resulting in duplicate calls to the DNS provider API. Some APIs are idempotent, so duplicates are harmless, but others are not—you might create duplicate resources, exceed rate limits, or cause partial failures.

Leader election solves this by designating one replica as the leader. Only the leader runs reconciliation workers. The other replicas stay hot, watching the lease, ready to take over if the leader fails. This gives you high availability without duplicate work. The informer caches still run on all replicas, so they're fully synchronized and can take over instantly when they become leader.

Reading from cache and watching resources doesn't require leader election—multiple replicas can safely watch the same resources because reads are side-effect-free. Leader election is only needed for the reconciliation loop that performs writes or external calls.

**If they push deeper:**

There's a subtlety with status updates. Some controllers write status subresources, which are part of the Kubernetes API and idempotent—multiple writes converge to the same state. Technically, non-leader replicas could safely update status. However, most controllers still gate status writes behind leader election to avoid wasted API calls and potential race conditions where two replicas overwrite each other's status updates. For purely read-only controllers, like metrics collectors, leader election is unnecessary—every replica can independently collect and export metrics.

## Q: Walk me through Lease object internals and the acquisition flow.

**Answer:**

The Lease object lives in coordination.k8s.io/v1 API group. When a controller starts with leader election enabled, it calls leaderelection.RunOrDie() from client-go. This creates or gets the Lease object in a specified namespace (often kube-system or the controller's namespace) with a specified name (often the controller name).

Acquisition flow: replica-1 tries to acquire the lease by creating the Lease object with spec.holderIdentity=replica-1, spec.leaseDurationSeconds=15, and spec.acquireTime and spec.renewTime set to now. If the Lease doesn't exist, creation succeeds and replica-1 becomes leader. If the Lease exists and holderIdentity is empty or the lease is expired (now - renewTime > leaseDurationSeconds), replica-1 attempts an update with its identity. This uses optimistic concurrency—if replica-2 updated first, replica-1's update fails with conflict and it retries later.

Once leader, replica-1 enters a renewal loop. Every RenewDeadline seconds (default 10s), it updates spec.renewTime to now. This keeps the lease fresh. If renewal fails—API server unreachable, network timeout, or conflict—replica-1 backs off and retries. If renewal fails continuously for more than LeaseDuration, replica-1 assumes it's lost leadership and stops reconciling.

Meanwhile, replica-2 and replica-3 watch the Lease object. They see holderIdentity=replica-1 and renewTime being updated every 10s. They wait. If renewTime stops updating and now - renewTime exceeds LeaseDuration, they attempt acquisition.

**If they push deeper:**

The leader election library uses the lease's resourceVersion for optimistic concurrency. When the leader renews, it reads the Lease, increments renewTime, and writes it back with the resourceVersion from the read. If another replica acquired leadership and updated the Lease between the leader's read and write, the resourceVersion has changed and the update fails. This immediately signals to the old leader that it's no longer leader, and it shuts down workers. This prevents split-brain—the old leader can't continue reconciling after losing leadership, even briefly.

## Q: What are LeaseDuration, RenewDeadline, and RetryPeriod, and how do you tune them?

**Answer:**

These three parameters control leader election timing and failover speed. LeaseDuration (default 15s) is how long a lease is valid without renewal. If the leader doesn't renew within this window, the lease expires and other replicas can acquire it. RenewDeadline (default 10s) is how often the leader attempts to renew the lease. It must be less than LeaseDuration to allow time for retries. RetryPeriod (default 2s) is how often non-leaders check if the lease is available and how often the leader retries a failed renewal.

Typical relationship: RenewDeadline < LeaseDuration, and RetryPeriod < RenewDeadline. Default values are 10s/15s/2s, meaning the leader renews every 10s, the lease expires after 15s without renewal, and replicas check every 2s. Failover time in a hard failure (leader pod crashes) is roughly LeaseDuration + RetryPeriod = 17s. In a graceful shutdown, the leader releases the lease immediately, so failover is just RetryPeriod = 2s.

Tuning for fast failover: decrease LeaseDuration to 5s, RenewDeadline to 3s, RetryPeriod to 1s. Failover time drops to ~6 seconds. But this increases API load—more frequent lease updates—and makes the system more sensitive to transient issues like network hiccups or brief GC pauses. If a leader experiences a 4-second GC pause, it loses leadership unnecessarily.

Tuning for stability: increase LeaseDuration to 60s, RenewDeadline to 40s, RetryPeriod to 10s. This tolerates longer disruptions without failover, reducing flapping. But failover time is now ~70 seconds, which may be too slow for critical controllers.

**If they push deeper:**

In production, watch for false failovers caused by node-level issues. If the leader's node is under memory pressure and experiencing swap, all processes slow down, including lease renewal. The leader may miss RenewDeadline, lose leadership, then recover and re-acquire leadership a minute later. You'll see constant leadership changes in the logs. Metrics like leader_election_slowpath_total indicate renewal failures. The fix is often infrastructure—add more memory, reduce node pressure, or tune kubelet eviction thresholds—not tightening lease parameters.

## Q: What happens during failover when the leader crashes?

**Answer:**

When the leader crashes—pod deleted, node fails, process killed—it immediately stops renewing the lease. The lease's renewTime freezes at the last successful renewal. Non-leader replicas are watching the Lease object. Every RetryPeriod (default 2s), they check if now - renewTime > LeaseDuration. Once this condition is true, they know the lease is expired and attempt to acquire it.

Multiple non-leaders may attempt acquisition simultaneously. Each tries to update the Lease with their identity. Only one succeeds due to optimistic concurrency control—the Lease's resourceVersion changes after the first write, causing subsequent writes to fail with conflict. The successful replica becomes the new leader, starts its reconciliation workers, and begins renewing the lease.

From the new leader's perspective, it immediately starts processing the work queue, which contains items that need reconciliation. If the old leader crashed mid-reconciliation, the new leader will re-reconcile those resources. Controllers must be idempotent—reconciling a resource multiple times must be safe. The new leader might duplicate some work the old leader started, but correctness is preserved because reconciliation checks current state before acting.

Total failover time is LeaseDuration (waiting for expiration) + RetryPeriod (next acquisition attempt) + time to start workers. With defaults, this is 15s + 2s + ~1s = 18s. During this window, reconciliation is paused—no controller is processing events.

**If they push deeper:**

There's a risk if the old leader hasn't actually crashed but is network-partitioned. The old leader may still be running and think it's leader, but it can't renew the lease because it can't reach the API server. Meanwhile, non-leaders see the expired lease and elect a new leader. Now two replicas think they're leader. The old leader will attempt renewal, fail, and realize it's lost leadership. The leaderelection library calls an OnStoppedLeading callback, which should immediately shut down workers. However, if there's a bug and workers don't stop, you have split-brain. This is why OnStoppedLeading must be fail-safe—log loudly and exit the process if necessary.

## Q: What are fencing tokens and how do they prevent split-brain?

**Answer:**

Fencing tokens are a distributed systems concept for preventing split-brain in leader election. The idea is that each time leadership is acquired, a monotonically increasing token (often a timestamp or sequence number) is associated with that leadership term. The leader includes this token when making external calls. The external system (database, API, cloud provider) rejects requests with stale tokens, ensuring that an old leader who thinks it's still leader can't make changes after a new leader has taken over.

In Kubernetes leader election, the fencing token is implicitly the Lease's resourceVersion or acquireTime. Each time the lease is acquired, acquireTime is set to the current time. If an old leader continues running after losing leadership, it can't successfully update the Lease—its update will fail due to resourceVersion conflict. This doesn't fully prevent external calls, though. If the controller calls an external API (AWS, GCP), there's no built-in fencing—the controller must explicitly check that it still holds the lease before making each external call, or accept that a brief split-brain is possible.

Best practice is to check leader status before expensive or dangerous operations. The leaderelection library provides an IsLeader() method. Before provisioning a load balancer, the controller should call IsLeader() and abort if false. This minimizes the window where an old leader can cause harm.

**If they push deeper:**

True fencing requires support from the external system. For example, if you're managing resources in AWS and every resource is tagged with a leadershipToken derived from the Lease's acquireTime, AWS won't prevent duplicate calls, but at least you can detect and reconcile duplicates later. A more robust approach is using idempotency tokens—every AWS API call includes a client-provided token, and duplicate calls with the same token are deduplicated by AWS. Combining idempotency tokens with leader election minimizes split-brain risks.

## Q: What are sharding patterns for controllers and when do you need them?

**Answer:**

Sharding is partitioning reconciliation work across multiple independent controller instances without leader election. Instead of 1 leader + N-1 standbys, you have N active controllers each reconciling a subset of resources. This increases throughput beyond what a single leader can handle.

The simplest sharding strategy is by namespace. Deploy one controller instance per namespace, or hash namespace names to shard IDs. Each controller watches only resources in its assigned namespaces using namespace-scoped informers. No leader election is needed because controllers don't overlap.

Another approach is label-based sharding. Tag resources with a shard label (shard=0, shard=1, etc.), and each controller watches resources with a specific shard label using label selectors. This works well for cluster-scoped resources where namespace sharding isn't applicable.

For finer-grained sharding, use consistent hashing on resource name or UID. Each controller calculates hash(resource.UID) % shardCount and reconciles only resources that hash to its shard ID. This requires watching all resources but selectively reconciling, so it doesn't save API server load, only reconciliation load.

When to shard: if a single leader can't keep up with reconciliation load, causing queue depth to grow continuously. Or if you have distinct resource groups with different SLAs—shard by priority and run high-priority shards on dedicated nodes.

**If they push deeper:**

Sharding introduces complexity. If a shard crashes, that subset of resources isn't reconciled until the shard recovers. You can combine sharding with leader election—run 3 replicas per shard, with leader election within each shard. This gives you both horizontal scaling and high availability. However, resharding is tricky. If you go from 4 shards to 5, resources will hash to different shards, causing ownership handoff. You need a migration plan: run both old and new shard topologies in parallel, drain the old shards, then remove them. Tools like cluster-proportional-autoscaler can dynamically adjust shard count based on cluster size.

## Q: How do you debug stuck or constantly flapping leader elections?

**Answer:**

Start by checking the Lease object. kubectl get lease <lease-name> -n <namespace> -o yaml shows holderIdentity (current leader), acquireTime, and renewTime. If renewTime is not updating, the leader is stuck and not renewing. Check the leader pod's logs for errors or if the pod is even running. If renewTime updates but leadership changes frequently, you have flapping.

Flapping causes: the leader is crashing and restarting (check pod restarts), the leader is experiencing GC pauses or resource starvation (check pod CPU/memory metrics), or network issues prevent reliable lease renewal (check API server latency). Metrics like leader_election_slowpath_total show how often renewal takes the slow path due to failures.

Stuck leadership: if holderIdentity points to a pod that no longer exists, the lease won't expire until LeaseDuration passes. If LeaseDuration is 60s and the pod was deleted 10s ago, you wait another 50s. You can manually delete the Lease object to force immediate re-election, but this should be a rare manual intervention, not normal operation.

For detailed debugging, enable verbose logging in the controller (--v=4). You'll see logs like "successfully acquired lease" and "failed to renew lease". Check API server logs for errors serving lease update requests. If API server is overloaded or etcd is slow, lease renewals time out, causing false failovers.

**If they push deeper:**

Watch for clock skew. If the leader's node clock drifts ahead, it sets renewTime to a future timestamp. Non-leaders calculate now - renewTime and get a negative number, thinking the lease is fresh when it's actually stale. NTP sync is critical. Also check for webhook delays. If you have admission webhooks that process Lease updates, slow webhooks delay renewal and can cause the leader to lose leadership. Lease updates should bypass most admission logic, but validating webhooks that match all resources can still interfere. Use namespaceSelector to exclude coordination.k8s.io from webhook scope.

## Q: How would you apply this in a platform engineering context?

**Answer:**

In platform engineering, leader election is essential for controllers managing external resources. At my last company, we built a cloud resource controller that watched CloudInstance CRDs and provisioned VMs in GCP. We ran 3 replicas for HA. Without leader election, all 3 replicas would try to create VMs for each CloudInstance, tripling costs and hitting GCP rate limits. With leader election, only one replica did the work, while the others stood by.

We tuned parameters based on criticality. For the CloudInstance controller, we used default 15s LeaseDuration because VM provisioning takes minutes, so a 15-second failover delay was acceptable. For a certificate controller that managed short-lived tokens, we tightened to 5s LeaseDuration because stale tokens could break production services. We monitored leader_election_master_status—a gauge that's 1 if this replica is leader, 0 otherwise—to track failovers and ensure leadership was stable.

We also used sharding for high-throughput controllers. Our DNS controller watched Service and Ingress objects across 50,000 namespaces. A single leader couldn't keep up. We sharded by namespace hash—shard 0 handled namespaces hashing to 0-999, shard 1 handled 1000-1999, etc. Each shard ran leader election independently, so we had 10 shards with 3 replicas each, giving us 10x throughput with HA.

**If they push deeper:**

One pattern we used was graceful leadership transfer for zero-downtime deploys. When rolling out a new controller version, we wanted the old leader to hand off leadership to a new replica without waiting for lease expiration. We implemented this by having the old leader call Lease.Release() on shutdown, which clears holderIdentity. New replicas detect the empty lease and acquire it immediately. This reduced failover from 15s to 2s during deploys. The leaderelection library supports this via the ReleaseOnCancel option—if the leader's context is canceled, it releases the lease before exiting. This is critical for user-facing controllers where 15-second pauses during deploys would cause alerts.
