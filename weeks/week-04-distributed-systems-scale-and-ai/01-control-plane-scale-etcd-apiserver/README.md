# Control Plane Scale: etcd, API Server, Watch Scalability, and Controller Sharding

## What you should be able to do

- Explain the etcd write path end-to-end, including Raft consensus, write amplification, WAL, BoltDB, and compaction, and state what each step costs at scale.
- Explain how the API server watch cache works, how fan-out to N controllers is handled, and what triggers a relist storm.
- Describe API Priority and Fairness: what a FlowSchema is, how PriorityLevels bound concurrency, and how to diagnose throttling of critical controllers.
- Propose concrete architectural changes (separate etcd clusters, controller sharding, status update coalescing, watch bookmark pinning) to scale a cluster past 5,000 nodes.
- Debug the four most common control-plane performance failures using real `kubectl`, `etcdctl`, and metrics commands.

## Mental Model

A production Kubernetes control plane at scale is a distributed write-ahead log (etcd) with a caching read fan-out layer (the API server watch cache) sitting in front of it. Every cluster object that changes must traverse both layers: the write is linearized through Raft, durably committed to disk via fsync, replicated to all etcd members, and only then does the API server fan it out to every controller and kubelet watching that resource type. At 1,000 nodes this feels instantaneous. At 5,000 nodes with 150,000 pods and 50 controllers all watching the same resources simultaneously, every one of these steps becomes a potential queue that backs up.

The key insight is that the API server and etcd form two distinct bottlenecks with different shapes. etcd is a write bottleneck: it is bounded by fsync latency (disk IOPS) and by Raft round-trip time across members. Every object modification, every status patch, and every lease renewal is a serialized write through a single leader. If your controllers are sending 10,000 status updates per second cluster-wide, that load lands entirely on the etcd leader's disk and network. The practical limit for a well-tuned etcd cluster on local NVMe is around 10,000-15,000 writes per second with sub-10ms p99 commit latency. Above that, latency climbs, watch events back up, and controllers start falling behind.

The API server is a read fan-out and admission bottleneck. Reads (GETs, LISTs) are served from the watch cache in memory — they almost never touch etcd. But writes must transit the admission chain (webhook round-trips, CEL evaluation) before reaching etcd, and the watch cache must then fan out the resulting event to every long-running watch connection. In a cluster with 500 long-lived watchers (controllers, kubelet informers, audit webhooks), a single Pod status change triggers 500 goroutines to push the event. The memory pressure from large watch caches and many concurrent watchers is why production API servers routinely run with 16-32 GB of RAM.

Controller architecture amplifies or absorbs this load. A naive controller that updates its status on every reconcile — even when nothing changed — generates one etcd write per reconcile. If that controller runs 20 worker goroutines reconciling 10,000 objects every 30 seconds, it generates ~6,600 writes per minute just for status. At scale, multiple such controllers compete for the same etcd write budget. The solution is a combination of idempotent reconciliation (write only when state actually differs), write coalescing (batch status updates), and controller sharding (partition the object space across multiple controller replicas so no single process is reconciling all 10,000 objects simultaneously).

Kubernetes 1.28+ provides the tooling to manage all of this: API Priority and Fairness (APF) bounds per-flow concurrency at the API server, watch bookmarks prevent relist storms when connections are interrupted, lease-based controller sharding in controller-runtime provides a standard sharding primitive, and separate etcd clusters for high-churn resource groups (Events, leases, Pods) reduce cross-contamination of write load. Understanding which knob controls which bottleneck — and being able to read the metrics that expose the backpressure — is the operational skill that distinguishes staff-level platform engineering from basic cluster management.

## Key Concepts

- **Raft consensus**: The distributed consensus algorithm etcd uses to ensure all members agree on the log order. A write is only confirmed after a quorum (majority) of members has persisted the entry to their WAL. In a three-member cluster, the leader sends each write to both followers and waits for at least one acknowledgment before responding to the client. Leader election uses randomized timeouts (`heartbeat-interval` defaults to 100ms, `election-timeout` defaults to 1000ms). Raft is the source of etcd's write serialization — there is exactly one leader processing writes at any moment.

- **WAL (Write-Ahead Log)**: The on-disk sequential log that etcd appends to before applying entries to the BoltDB b-tree. Every entry is written and fsync'd to WAL before the commit response is sent to the client. WAL is the primary disk I/O bottleneck: fsync latency on spinning disk is 5-10ms per write; on local NVMe it is 100-500µs. Sequential writes make WAL efficient, but each fsync is a hard synchronization barrier that serializes throughput. The WAL is segmented into 64MB files and rotated as it grows.

- **BoltDB (bbolt)**: The b-tree embedded database that etcd uses as its storage backend for committed log entries. After a Raft entry is committed (quorum has acknowledged it), etcd applies it to the BoltDB b-tree, which is the authoritative data store that serves read queries. BoltDB uses copy-on-write b-tree pages. When etcd deletes or overwrites a key, BoltDB marks pages as free but does not return them to the OS — they accumulate as internal fragmentation, inflating the DB file size until explicit defragmentation is run.

- **etcd compaction**: The process by which etcd discards old revisions of objects. etcd stores every version of every key — each write creates a new revision entry. Without compaction, the DB grows without bound. The API server sets `--etcd-compaction-interval` (default 5 minutes) to periodically compact up to the current revision. After compaction, clients that try to watch from a revision older than the compaction point receive a `410 Gone` response, forcing a relist. Compaction is followed by defragmentation (`etcdctl defrag`) to actually recover disk space from BoltDB's free-page pool.

- **Watch cache (cacher)**: An in-memory data structure inside each API server instance that maintains the authoritative state for every resource type the server manages. It is backed by a fixed-size circular ring buffer of watch events (default 100 events per resource type for most resources; Pods use a larger buffer). Clients that open a watch connection receive events from the cache ring buffer rather than from etcd directly. This is the mechanism that decouples the N-watchers fan-out from etcd: etcd sends one event per write; the watch cache fans it out to all watchers in memory.

- **API Priority and Fairness (APF)**: The Kubernetes 1.20+ mechanism that replaces the old `--max-requests-inflight` and `--max-mutating-requests-inflight` flags. APF models incoming requests as flows, assigns each flow to a `PriorityLevel` via a `FlowSchema`, and enforces per-priority-level concurrency limits with fair queuing within each level. FlowSchemas are matched in priority order (lower `matchingPrecedence` wins). PriorityLevels specify `assuredConcurrencyShares` (relative concurrency budget), `limitResponse.queuing.queues` (number of shuffle-sharding queues), and `limitResponse.queuing.queueLengthLimit`. The API server metric `apiserver_flowcontrol_current_executing_requests` shows live concurrency per priority level; `apiserver_flowcontrol_rejected_requests_total` counts dropped requests.

- **Watch bookmark**: A synthetic watch event of type `BOOKMARK` that carries the current `resourceVersion` but no object payload. The API server sends bookmark events periodically (at least every 60 seconds) to allow watchers to checkpoint their position in the event stream without receiving a real object change. When a watch connection is interrupted and the client reconnects with the bookmarked `resourceVersion`, the API server can resume streaming from the ring buffer rather than forcing a full relist. Without bookmarks, any watch reconnect within the ring buffer window costs only a buffer replay; outside the window costs a full list-from-etcd.

- **Controller sharding (lease-per-shard)**: A pattern where a controller is partitioned such that each replica only reconciles a subset of objects, typically determined by hashing the object name modulo the number of shards, or by namespace assignment. Kubernetes 1.26+ provides `leaderelection.LeaderCallbacks.OnNewLeader` hooks and the `sigs.k8s.io/controller-runtime/pkg/leaderelection` package. The canonical approach in controller-runtime 0.16+ uses `sharding.ShardingGate` or custom lease-per-shard logic where shard identity is pinned via a Lease object named `controller-shard-N`. Each shard replica holds exactly one such Lease and uses its shard index to filter events before enqueuing them.

- **Write amplification**: The ratio of bytes written to disk to bytes actually changed in the data model. In etcd, a single 1KB object update causes: one WAL append (including Raft header, CRC, and the full object payload), one BoltDB b-tree page write (BoltDB pages are 4KB; a 1KB change may rewrite multiple pages due to copy-on-write), and replication of the WAL entry to all followers (so the 1KB write physically travels at 3x or 5x in a three- or five-member cluster). This amplification is why etcd's practical write throughput is measured in object operations per second, not raw MB/s.

## Internals

### etcd Write Path: From API Server to Durable Storage

When the API server writes an object (after admission), the path through etcd proceeds in exactly this order:

1. **Optimistic concurrency check**: The API server encodes the object to protobuf and issues an etcd transaction (`Txn`) that checks the current key's `modRevision` matches the `resourceVersion` the server read during admission (the compare-and-swap). If the check fails, etcd returns a false response and the API server returns a 409 Conflict to the caller.

2. **Raft proposal**: The etcd leader appends the write to its in-memory Raft log and sends `AppendEntries` RPCs to all followers simultaneously. Each follower appends the entry to its own WAL and responds. The leader waits for quorum (N/2 + 1 acknowledgments).

3. **WAL fsync**: Each etcd member that appends the entry calls `fdatasync()` on the WAL file segment before sending the acknowledgment to the leader. This is the latency-critical step. The `etcd_disk_wal_fsync_duration_seconds` histogram tracks this. A p99 above 10ms is a warning sign; above 25ms indicates disk saturation.

4. **Commit and BoltDB apply**: Once the entry is committed (quorum acknowledged), the etcd leader applies the entry to BoltDB: it opens a writable BoltDB transaction, puts the new key-value pair at the current global revision, increments the revision counter, and commits the BoltDB transaction (which also involves an fsync to the BoltDB data file). The `etcd_disk_backend_commit_duration_seconds` histogram tracks this. This is a second fsync per write.

5. **Response to API server**: etcd returns the `PutResponse` including the new `modRevision`, which the API server uses as the object's new `resourceVersion`.

6. **Watch notification**: etcd's internal watcher subsystem, which the API server maintains a server-side watch over, receives the committed event and sends it back to the API server over the existing watch gRPC stream. The API server's watch cache (cacher) receives this event, updates its in-memory store, appends the event to the ring buffer for that resource type, and wakes all goroutines that are blocked waiting for new events to fan out to their respective watch HTTP connections.

The total round-trip for a write is: API server admission → etcd txn → Raft proposal → follower WAL fsync → leader commit → BoltDB apply → watch notification back to API server. At p50 this is 2-5ms on well-provisioned infrastructure. At p99 it should be under 25ms. When fsync latency climbs above 25ms, the entire write pipeline serializes behind it because Raft will not pipeline more than `max-inflight-msgs` (default 256) unacknowledged entries at once.

### Write Amplification and the etcd Compaction Lifecycle

Every object version in etcd is stored as a separate key in the BoltDB b-tree, keyed by `(object-key, revision)`. For a Deployment object at revision 1000 that is patched 500 times, etcd holds 500 separate revisions of that object simultaneously until compaction runs. The DB size is the sum of all live and historical revisions.

The API server compaction loop (controlled by `--etcd-compaction-interval`, default 5 minutes) issues `etcdctl compaction <revision>` which marks all revisions below the target as eligible for BoltDB garbage collection. However, BoltDB does not shrink the file on disk when it frees pages — freed pages are added to an in-memory free-page list and reused by future writes, but the file size stays the same. Only explicit defragmentation (`etcdctl defrag`) rewrites the BoltDB file, recovering disk space. In production, this means DB file size monotonically grows until defrag is run. Defrag requires a brief hold on the etcd lock during which that member does not serve reads (the API server fails over to another member), so it should be scheduled during off-peak windows.

The compaction revision window is also the watch reconnect budget. The API server configures watchers to use a cache window of 100 events per type. If a controller's watch connection drops and reconnects before 100 events have elapsed in the ring buffer, it resumes without relist. But if compaction has discarded the revision the controller was watching from, the controller receives `410 Gone` and must perform a full LIST of all objects of that type from the API server. This LIST hits etcd (bypasses watch cache), causes a spike in etcd read load, and then the informer re-seeds its entire local cache from the list result. In a cluster with 100,000 pods, a single relist of all Pods is a multi-MB response that deserializes every Pod object.

### Watch Cache and Fan-Out Architecture

The watch cache is per-API-server, per-resource-type. It is not shared across API server replicas. Each API server instance maintains its own in-memory store and ring buffer for every resource type it handles. The ring buffer size is controlled by the `WATCH_CACHE_SIZES` environment variable (or `--watch-cache-sizes` in older versions) in the format `resource#size,resource#size,...`. Pods default to 1000, Nodes default to 1000, most other types default to 100.

When an event arrives from etcd, the watch cache appends it to the ring buffer and iterates over all registered `cacheWatcher` objects for that resource type. Each `cacheWatcher` corresponds to one watch HTTP connection from one client. For each watcher, the cache calls `watcher.nonblockingAdd(event)`: it attempts to push the event into the watcher's internal buffered channel (size 10 by default). If the channel is full (the client is reading too slowly), the event is dropped and the watcher is terminated — the client receives a `GONE` or `ERROR` event and must reconnect. This back-pressure mechanism prevents a slow consumer from blocking the fan-out for all other watchers.

The fan-out goroutine model works as follows: there is one goroutine per registered `cacheWatcher` that reads from the internal channel and writes events to the HTTP response stream. In a cluster with 500 controllers and kubelets all watching Pods, there are 500 such goroutines active for the Pod resource type alone. Each goroutine spends most of its time blocked on channel read; when an event arrives, all 500 goroutines wake in parallel and write their events. This is efficient in Go's scheduler because goroutines are cheap, but it does mean the API server holds 500 open HTTP connections for that resource type, each backed by memory for the event buffer.

The practical implication is that running many controller replicas watching the same resource type (e.g., 10 replicas of a controller that all independently watch Pods cluster-wide) multiplies the fan-out work by 10x and increases API server memory by 10x for that resource type's watcher set. This is why scoping controller watches with field selectors or label selectors is important: a controller that watches only Pods with `app=myapp` registers a filtered cacheWatcher that receives far fewer events and contributes less fan-out pressure than a controller watching all Pods.

### API Priority and Fairness: Flow Schema, Priority Levels, and Shuffle Sharding

APF replaces the blunt `--max-requests-inflight` knob with a multi-queue fair scheduler. The flow of a request through APF:

1. **Flow classification**: Each incoming request is matched against the ordered list of `FlowSchema` objects (sorted by `spec.matchingPrecedence`, lower number = higher priority). A FlowSchema matches on subjects (users, service accounts), resource groups, verbs, and namespaces. The first matching FlowSchema wins and assigns the request to a `PriorityLevelConfiguration` and computes a `flowDistinguisher` (typically the requesting user or namespace) for shuffle sharding.

2. **Priority level queue selection**: The assigned `PriorityLevelConfiguration` defines the total concurrency budget for requests of that level. Kubernetes ships with built-in levels: `exempt` (bypasses all limits, for system:masters and the API server itself), `node-high` (kubelet communication), `system` (system controllers), `leader-election` (leader election requests), `workload-high` (high-priority workload operations), `workload-low` (default for most operations), and `global-default` (catch-all). Each level has `assuredConcurrencyShares` that determines its share of the total API server concurrency.

3. **Shuffle sharding**: Within a priority level, requests are distributed across `queues` (default 64 queues) using shuffle sharding: the `flowDistinguisher` is hashed to select a small subset of queues (controlled by `handSize`, default 8), and the request is enqueued in the shortest of those queues. This prevents a single misbehaving flow (e.g., one service account sending 1,000 requests per second) from monopolizing all queues in a priority level. A burst of traffic from that service account fills 8 queues; other flows using different queues are unaffected.

4. **Execution**: Requests at the front of their queue are dispatched to the API server handler goroutines up to the concurrency limit. Requests that wait too long in the queue are rejected with 429 Too Many Requests and the `Retry-After` header. The rejection is counted in `apiserver_flowcontrol_rejected_requests_total{reason="queue-full"}`.

The critical failure mode is when a legitimate system controller (e.g., the namespace controller) is assigned to a FlowSchema that maps it to `workload-low`, which has low concurrency shares. If a batch job floods the cluster with workload requests, the namespace controller gets starved and cannot process namespace deletion or object cleanup, causing resource leaks. The fix is to audit FlowSchema assignments for critical system controllers and ensure they land on `system` or `leader-election` priority levels.

### Relist Storms and Watch Bookmark Optimization

A relist storm occurs when many controllers simultaneously lose their watch connections (API server restart, network partition, etcd compaction of old revisions) and all issue LIST requests at once. Each LIST is a synchronous read of all objects of a type from etcd (bypassing the watch cache). The result is:

1. N controllers each send `GET /api/v1/pods?limit=500` (paginated) to the API server.
2. The API server, for each page, queries etcd directly: `etcdctl get /registry/pods --prefix --limit=500`.
3. etcd must read potentially thousands of BoltDB pages from disk, serializing all N LIST requests through BoltDB's read lock.
4. Each LIST response deserializes potentially hundreds of megabytes of protobuf, consuming API server CPU and memory.
5. The combined LIST traffic can spike etcd read latency above 500ms, which delays ongoing watches and further degrades controller convergence.

The watch bookmark mechanism directly mitigates this. Starting in Kubernetes 1.16 (GA in 1.24), clients can request bookmark events by adding `allowWatchBookmarks=true` to their watch request. The API server periodically (every 60 seconds) sends synthetic BOOKMARK events with the current `resourceVersion` and no object payload. Informers in client-go 0.24+ automatically track the last received bookmark revision. On reconnect, the informer sends a watch starting from that revision. If the API server's ring buffer still contains events back to that revision, the watch resumes without a relist. The informer only relists if it receives 410 Gone (revision compacted) or if the revision is so old it has fallen out of the ring buffer.

The practical tuning: increase ring buffer sizes for high-churn resources (Pods, Endpoints, Leases) using `--watch-cache-sizes=pods#10000,endpoints#5000,leases#1000`. Larger ring buffers hold more events and reduce the likelihood of a reconnecting controller finding its revision compacted out.

### Controller Sharding Patterns

When a single controller replica cannot keep up with the reconciliation demand for a large object set, sharding distributes the work. Three dominant patterns:

**Namespace-hash sharding**: Each controller replica is assigned a shard index (0 to N-1). The controller's event filter hashes the object's namespace name using a deterministic hash function (fnv32a is standard) modulo N. Objects whose namespace hash matches the shard index are processed; others are skipped. The shard index is typically embedded in the controller's Deployment as an environment variable or computed from the controller pod's ordinal (StatefulSet). Failure of one shard means that shard's namespace subset is unreconciled until the pod restarts; cross-shard objects are never misrouted because the hash is deterministic.

```go
// Shard filter in event handler (controller-runtime predicate pattern)
func (p *ShardPredicate) Generic(e event.GenericEvent) bool {
    h := fnv.New32a()
    h.Write([]byte(e.Object.GetNamespace()))
    return int(h.Sum32())%p.TotalShards == p.ShardIndex
}
```

**Label-based sharding**: Objects are assigned to shards via an explicit label (`controller.example.com/shard: "2"`). The controller watches only objects with its assigned shard label using a label selector watch. This is simpler to implement (no hash logic) and allows manual rebalancing by changing labels. The downside: unlabeled objects are orphaned; labeling must be handled by a separate admission webhook or a shard-assigner controller.

**Lease-per-shard with dynamic partitioning**: Each shard is represented by a Kubernetes Lease object in a dedicated namespace (e.g., `controller-shards/shard-0`, `controller-shards/shard-1`). Controller replicas compete to hold leases. A replica holding `shard-0` processes objects with `hash % N == 0`. If a replica crashes, its lease expires (TTL defined by `spec.leaseDurationSeconds`) and another idle replica acquires it, immediately beginning to reconcile the orphaned shard. This pattern enables N active replicas and M standby replicas, where standbys acquire leases from crashed actives within `leaseDurationSeconds` (typically 15-30 seconds). controller-runtime 0.16 provides `sharding.IndexerFunc` and `sharding.ShardingGate` as building blocks for this pattern.

### Separate etcd Clusters for Resource Group Isolation

A common scaling intervention is to move high-churn, low-criticality resources to a separate etcd cluster. The API server supports `--etcd-servers-overrides` in the format `group/resource#endpoints`:

```
--etcd-servers-overrides=/events#https://events-etcd-0:2379,https://events-etcd-1:2379
--etcd-servers-overrides=coordination.k8s.io/leases#https://leases-etcd-0:2379
```

The motivation: Kubernetes Events (`/api/v1/events`) are extremely high-write-rate objects — every pod phase change, scheduler decision, and kubelet action generates events. Events have short retention windows (1 hour default) and are not critical for correctness (no controller reconciles based on Event objects). By isolating Events to their own etcd cluster, you protect the main etcd cluster from Event write load. A busy cluster might generate 50,000 events per hour; isolating them removes that entire write budget from the critical etcd cluster.

Similarly, `coordination.k8s.io/leases` are written by every kubelet every 10 seconds (node heartbeat), by every controller leader every few seconds, and by every instance using leader election. In a 5,000-node cluster, kubelets alone generate 500 lease renewals per second. Isolating leases to their own etcd cluster (which can be tuned for high write throughput with smaller, faster hardware) prevents heartbeat writes from competing with the 409-sensitive optimistic locks of critical objects like Deployments and PersistentVolumeClaims.

The standard split for large clusters:

- **Primary etcd cluster**: all core API resources except Events and Leases (Pods, Deployments, Services, ConfigMaps, Secrets, etc.)
- **Events etcd cluster**: `/api/v1/events` — write-heavy, retention-limited, non-critical
- **Coordination etcd cluster**: `coordination.k8s.io/leases` — high-frequency heartbeats, small payloads, high write rate
- **CRD etcd cluster** (optional, for very large CRD deployments): custom resources that have their own high write rates

## Architecture Diagram

```
  ┌───────────────────────────────────────────────────────────────────────────┐
  │                     CONTROL PLANE (HA, 3 API Server replicas)             │
  │                                                                           │
  │  ┌──────────────┐   ┌──────────────┐   ┌──────────────┐                  │
  │  │ kube-apiserver│  │ kube-apiserver│  │ kube-apiserver│                  │
  │  │   replica 0  │  │   replica 1  │  │   replica 2  │                    │
  │  │              │  │              │  │              │                     │
  │  │ Watch Cache  │  │ Watch Cache  │  │ Watch Cache  │  (independent,     │
  │  │ (in-memory)  │  │ (in-memory)  │  │ (in-memory)  │   not shared)      │
  │  │              │  │              │  │              │                     │
  │  │ APF Queues   │  │ APF Queues   │  │ APF Queues   │                    │
  │  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘                   │
  │         │                 │                  │                            │
  │         └─────────────────┼──────────────────┘                           │
  │                           │ gRPC watch (one stream per apiserver)         │
  └───────────────────────────┼───────────────────────────────────────────────┘
                              │
        ┌─────────────────────┼──────────────────────────────────┐
        │                     │    etcd cluster (3 or 5 members)  │
        │                     ▼                                   │
        │     ┌───────────────────────────────────┐              │
        │     │           etcd LEADER             │              │
        │     │                                   │              │
        │     │  1. Txn (CAS on modRevision)      │              │
        │     │  2. Raft proposal → AppendEntries │              │
        │     │  3. WAL append + fdatasync         │              │
        │     │  4. Wait for follower ACKs (quorum)│             │
        │     │  5. BoltDB apply + fsync           │              │
        │     │  6. Send watch event to apiservers │              │
        │     └──────────┬────────────────────────┘              │
        │                │ AppendEntries (Raft replication)       │
        │         ┌──────┴──────┐                                 │
        │         ▼             ▼                                  │
        │  ┌────────────┐ ┌────────────┐                          │
        │  │etcd follower│ │etcd follower│                         │
        │  │ WAL + BoltDB│ │ WAL + BoltDB│                         │
        │  └────────────┘ └────────────┘                          │
        └──────────────────────────────────────────────────────────┘

                      Events etcd cluster             Leases etcd cluster
                    ┌─────────────────────┐         ┌─────────────────────┐
                    │ /api/v1/events      │         │ coordination.k8s.io │
                    │ (high write, low    │         │ /leases             │
                    │  criticality)       │         │ (kubelet heartbeats)│
                    └─────────────────────┘         └─────────────────────┘

  Watch fan-out (per API server, per resource type):
  ┌──────────────────────────────────────────────────────────────────────┐
  │  etcd event → Watch Cache ring buffer → cacheWatcher channel fan-out │
  │                                                                      │
  │  controller-A ◄── goroutine ◄── channel (cap 10) ◄─┐               │
  │  controller-B ◄── goroutine ◄── channel (cap 10) ◄─┤               │
  │  controller-C ◄── goroutine ◄── channel (cap 10) ◄─┤ ring buffer   │
  │  kubelet-0001 ◄── goroutine ◄── channel (cap 10) ◄─┤ (N events)    │
  │  kubelet-0002 ◄── goroutine ◄── channel (cap 10) ◄─┤               │
  │  ...          ◄── goroutine ◄── channel (cap 10) ◄─┘               │
  │  (up to 500+ concurrent watchers for high-cardinality resource types)│
  └──────────────────────────────────────────────────────────────────────┘

  Controller sharding (lease-per-shard, 4 shards):
  ┌──────────────────────────────────────────────────────────────────────┐
  │  Lease: controller-shard-0  ←─ held by ─→  controller-pod-0        │
  │  Lease: controller-shard-1  ←─ held by ─→  controller-pod-1        │
  │  Lease: controller-shard-2  ←─ held by ─→  controller-pod-2        │
  │  Lease: controller-shard-3  ←─ held by ─→  controller-pod-3        │
  │                                                                      │
  │  Object key hash % 4 == 0 → pod-0 reconciles                        │
  │  Object key hash % 4 == 1 → pod-1 reconciles                        │
  │  Object key hash % 4 == 2 → pod-2 reconciles                        │
  │  Object key hash % 4 == 3 → pod-3 reconciles                        │
  └──────────────────────────────────────────────────────────────────────┘
```

## Failure Modes & Debugging

### 1. etcd Latency Spikes / Slow fsync

**Symptoms**: API server p99 write latency climbs above 1 second. `kubectl apply` starts hanging. Controllers log `context deadline exceeded` or `etcdserver: request timed out`. Watch events stop flowing for 5-30 seconds at a time. Prometheus alerts on `etcd_disk_wal_fsync_duration_seconds` p99 exceeding 10ms. The API server logs `slow etcd request` warnings. Scheduler pod binding rate drops sharply.

**Root Cause**: The WAL fsync is the serialization point for every write. Anything that causes disk I/O latency to spike will directly translate to etcd latency. Common causes: (1) network-attached storage (EBS, GCE PD, Azure Disk) under IO burst exhaustion — provisioned IOPS consumed, throttled by cloud provider; (2) another workload on the same host competing for disk I/O (noisy neighbor, especially on hypervisors with shared storage paths); (3) etcd DB size approaching the quota (`--quota-backend-bytes`, default 8GB) — BoltDB b-tree rebalancing becomes more expensive; (4) etcd leader election — during election, the new leader must confirm its log position, causing a brief write stall (typically <1 second but can reach 3-5 seconds in degraded networks); (5) OS page cache pressure causing BoltDB writes to wait for dirty page writeback.

**Blast Radius**: Entire cluster. All API server writes serialize behind etcd. Admission webhooks that make API calls time out. Controllers cannot update status. Scheduler cannot bind pods. Node heartbeats (lease renewals) fail, causing nodes to appear `NotReady`. If the stall exceeds `node-monitor-grace-period` (default 40 seconds), the node controller begins tainting nodes and evicting pods, causing a cascading failure.

**Mitigation**:
- Provision etcd on dedicated local NVMe SSDs with consistent sub-1ms fsync. Never use network-attached storage for etcd WAL. Use separate volumes for WAL and BoltDB data directories if possible.
- Set `--quota-backend-bytes=8589934592` (8GB) and alert when the DB size exceeds 70% of quota. Schedule `etcdctl defrag` monthly or when fragmentation exceeds 30%.
- Separate high-write resources (Events, Leases) to dedicated etcd clusters to remove their I/O load.
- Use `ionice -c 1 -n 0` (real-time I/O scheduling class) for the etcd process on Linux to prioritize its disk I/O.
- Alert on `etcd_server_leader_changes_seen_total` increasing faster than 1/hour — frequent leader elections indicate network instability or resource contention.

**Debugging**:
```bash
# Check etcd endpoint health and DB size for each member
kubectl exec -n kube-system etcd-<control-plane-node> -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --write-out=table

# Watch fsync latency histogram in real time
kubectl exec -n kube-system etcd-<control-plane-node> -- sh -c \
  "curl -s http://127.0.0.1:2381/metrics" | \
  grep -E 'etcd_disk_wal_fsync_duration_seconds|etcd_disk_backend_commit_duration_seconds'

# Check leader changes (should be near zero over hours)
kubectl exec -n kube-system etcd-<control-plane-node> -- sh -c \
  "curl -s http://127.0.0.1:2381/metrics" | grep etcd_server_leader_changes_seen_total

# Check DB size and fragmentation per member
kubectl exec -n kube-system etcd-<control-plane-node> -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --write-out=json | jq '.[].Status | {dbSize, dbSizeInUse, leader}'

# Check API server write latency from the API server side
# (port-forward to one API server's :6443 metrics endpoint or use prometheus)
curl -sk https://localhost:6443/metrics | \
  grep 'apiserver_request_duration_seconds.*verb="CREATE\|UPDATE\|PATCH"' | head -20

# Run defrag on all members (schedule during low-traffic window; takes seconds per member)
kubectl exec -n kube-system etcd-<control-plane-node> -- etcdctl \
  --endpoints=https://etcd-0:2379,https://etcd-1:2379,https://etcd-2:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  defrag --cluster
```

### 2. Watch Cache Exhaustion and Relist Storms

**Symptoms**: Controllers log `"too old resource version"`, `"watch closed with: 410 Gone"`, or `"reflector listing and watching"` repeatedly. API server metrics show a spike in `apiserver_request_total{verb="LIST"}` that lasts 2-5 minutes. etcd read latency spikes simultaneously. Controller reconciliation loops lag by minutes rather than seconds. `kubectl get pods -A` becomes slow (it is also doing a LIST under the hood).

**Root Cause**: The ring buffer for the affected resource type has scrolled past the revision that a reconnecting watcher needs. This happens when: (1) the ring buffer size is too small for the event rate of that resource type — default 100 events means a resource type generating 100 events in less than a watch timeout period (60 seconds) will cause any reconnecting watcher to find its revision gone; (2) a mass API server restart (rolling restart, upgrade) causes all watchers to reconnect simultaneously; (3) etcd compaction runs and discards revisions that watchers are still streaming from; (4) a single high-rate object (e.g., a Pod with a status condition being updated by kubelet every second) rapidly scrolls the ring buffer.

The relist storm is the consequence: N controllers all issue `LIST /api/v1/pods` simultaneously. Each LIST forces the API server to read from etcd (bypassing watch cache for the initial list), which saturates etcd's read path and delays the compaction and Raft timers. The storm self-reinforces: slow LIST responses cause informers to retry sooner, which adds more LIST load.

**Blast Radius**: Elevated API server and etcd load lasting 2-10 minutes depending on cluster size. During the storm, new watch events may be delayed because the API server goroutine pool is saturated with LIST processing. Other operations (e.g., pod scheduling, admission webhooks) slow down due to API server queue depth growing. In extreme cases, the API server OOMs from materializing all pods into memory simultaneously for all LIST requests.

**Mitigation**:
- Increase ring buffer sizes for high-churn resources: add `--watch-cache-sizes=pods#10000,nodes#1000,endpoints#5000` to API server flags. Memory cost is approximately 500 bytes per cached event (protobuf encoding), so 10,000 pod events costs ~5MB per API server replica — well within budget.
- Ensure all controllers use client-go 0.24+ with `AllowWatchBookmarks: true` in `ListOptions` to receive periodic bookmark events and avoid needing revisions that may be compacted.
- Stagger API server rolling restarts: during an upgrade, wait 30-60 seconds between restarting each API server replica so not all watchers reconnect at once. The `--max-unavailable` setting in the API server DaemonSet (for kubeadm clusters) or the rolling update strategy for managed clusters should pause between replicas.
- Add anti-LIST rate limiting at the APF layer: create a FlowSchema that matches `verb=list` for specific resources and routes them to a `workload-low` PriorityLevel with lower concurrency, preventing LIST storms from consuming all API server concurrency.
- Run etcd compaction with a conservative retain period: `etcd --auto-compaction-mode=periodic --auto-compaction-retention=2h` (keep 2 hours of history) ensures controllers with infrequent reconnects can still resume from history.

**Debugging**:
```bash
# Watch for LIST spikes in API server request metrics
curl -sk https://localhost:6443/metrics | \
  grep 'apiserver_request_total{.*verb="LIST"' | sort -t= -k5 -rn | head -20

# Check watch cache sizes currently active (requires APIServerDiagnostics enabled)
curl -sk https://localhost:6443/debug/api/watch-cache-sizes 2>/dev/null || \
  echo "use --enable-priority-and-fairness=true and check flowcontrol API"

# Look for 410 Gone (watch cache miss) in API server access log
kubectl logs -n kube-system kube-apiserver-<node> | grep '"code":410' | head -20

# Check informer cache age from controller metrics (controller-runtime exposes this)
# workqueue_retries_total climbing fast = relist storm in progress
kubectl port-forward -n <controller-ns> deploy/<controller> 8080:8080
curl -s http://localhost:8080/metrics | grep -E 'workqueue_retries|workqueue_depth'

# Check rate of relists across all informers (client-go metric)
# reflector_list_duration_seconds bucket spiking = relist in progress
curl -s http://localhost:8080/metrics | grep reflector_list_duration_seconds

# Verify watch bookmark support in controller (look for AllowWatchBookmarks in code)
# kubectl describe should show bookmarkEnabled in watch cache status for the resource
kubectl get --raw /apis/coordination.k8s.io/v1/namespaces?watch=true\&allowWatchBookmarks=true \
  --request-timeout=5s | head -5
```

### 3. APF Throttling of Critical Controllers

**Symptoms**: A specific controller stops reconciling. Its logs show `429 Too Many Requests` from the API server or `client rate limiter Wait context canceled`. The controller's `workqueue_depth` metric climbs while `workqueue_adds_total` stays flat. Meanwhile, user-facing API calls succeed normally. The controller may appear healthy (no pod restarts) but objects it manages are stuck (e.g., CertificateSigningRequests not approved, PVCs not bound). Occasionally the API server logs `flowcontrol: 429 response sent` for requests from the controller's service account.

**Root Cause**: The controller's service account has been matched by a FlowSchema that places it in a PriorityLevel with insufficient concurrency. This commonly happens when: (1) a custom controller is created without a corresponding FlowSchema, so it falls through to `global-default` which has the lowest concurrency; (2) the built-in `workload-low` priority level has been overwhelmed by user traffic (kubectl applies, CI/CD pipelines) because the concurrency shares favor user traffic over system controllers; (3) a misconfigured FlowSchema incorrectly matches system service accounts and downgrades them to a low-priority level.

The insidious aspect: APF throttling is silent from the cluster-admin perspective. The cluster is healthy, user operations work, but a specific system function (certificate approval, PVC binding, lease renewal) quietly stalls. The controller's client-go rate limiter eventually queues requests instead of sending them, consuming memory in the controller and causing object reconciliation to fall behind by hours.

**Blast Radius**: Bounded to the specific function handled by the throttled controller. If the throttled controller is the kubelet (node heartbeat denied), nodes go `NotReady` after 40 seconds. If it is the certificate controller, new nodes cannot join. If it is the PVC binder (kube-controller-manager), new pods requiring PVCs are stuck `Pending`. The blast radius is silent and delayed — it takes minutes to hours before humans notice that a cluster function has stalled.

**Mitigation**:
- Audit all custom and critical system controllers: verify they are matched by appropriate FlowSchemas. Create explicit FlowSchemas for each important service account, assigning them to `system` or a custom high-priority level.
- Use the `FlowSchema` `catchAll` precedence (10000, very low priority) as a safety net but never rely on it for critical controllers.
- Monitor `apiserver_flowcontrol_rejected_requests_total` by `flowSchema` and `priorityLevel` labels. Alert when any critical-controller FlowSchema contributes more than 0 rejections per minute.
- Monitor `apiserver_flowcontrol_current_executing_requests` by `priorityLevel` to detect saturation. If `workload-low` is always at 100% of its concurrency limit, reduce the workload using it or raise its `assuredConcurrencyShares`.
- For emergency relief: temporarily patch the controller's FlowSchema to use `exempt` priority level (which bypasses all limits). Restore after root cause analysis.

**Debugging**:
```bash
# List all FlowSchemas sorted by matching precedence to understand priority order
kubectl get flowschemas -o custom-columns=\
'NAME:.metadata.name,PRECEDENCE:.spec.matchingPrecedence,PRIORITY-LEVEL:.spec.priorityLevelConfiguration.name' \
  --sort-by='.spec.matchingPrecedence'

# Check which FlowSchema matches a specific service account's requests
# The API server adds X-Kubernetes-PF-FlowSchema header to responses (enable debug headers)
kubectl auth can-i list pods \
  --as=system:serviceaccount:<namespace>:<controller-sa> -v=8 2>&1 | \
  grep 'X-Kubernetes-PF\|FlowSchema'

# Count rejected requests by priority level (critical: this should be 0 for system controllers)
curl -sk https://localhost:6443/metrics | \
  grep apiserver_flowcontrol_rejected_requests_total

# Count current executing requests per priority level
curl -sk https://localhost:6443/metrics | \
  grep apiserver_flowcontrol_current_executing_requests

# Inspect PriorityLevelConfiguration concurrency shares
kubectl get prioritylevelconfigurations -o yaml | \
  grep -A5 'assuredConcurrencyShares\|limitResponse'

# Check if a specific controller's service account is being throttled
# Look for 429 responses in controller logs
kubectl logs -n <controller-ns> deploy/<controller> | grep -i "429\|too many requests\|rate limit" | tail -20

# Create or patch a FlowSchema to assign controller to system priority level
kubectl apply -f - <<'EOF'
apiVersion: flowcontrol.apiserver.k8s.io/v1
kind: FlowSchema
metadata:
  name: my-controller-system
spec:
  matchingPrecedence: 800
  priorityLevelConfiguration:
    name: system
  rules:
  - subjects:
    - kind: ServiceAccount
      serviceAccount:
        name: my-controller
        namespace: my-controller-ns
    resourceRules:
    - verbs: ["*"]
      apiGroups: ["*"]
      resources: ["*"]
EOF
```

### 4. etcd DB Size Exceeding Quota (mvcc: database space exceeded)

**Symptoms**: All writes to the API server fail with `etcdserver: mvcc: database space exceeded`. `kubectl apply`, `kubectl create`, `kubectl delete` all return 500 Internal Server Error. Read operations (GET, LIST, watch) continue to work. The API server logs `etcdserver: request ignored (cluster ID mismatch)` or `etcdserver: mvcc: database space exceeded`. etcd reports `NOSPACE` alarm in `etcdctl alarm list`. The cluster effectively becomes read-only — no new pods can be scheduled, no Deployments can be rolled out, no ConfigMaps can be updated.

**Root Cause**: BoltDB has grown to the quota limit set by `--quota-backend-bytes` (default 2GB in older versions, should be set to 8GB in production). The growth is caused by: (1) accumulation of historical revisions between compaction runs — if compaction is not running (misconfiguration, controller manager failure) revisions accumulate indefinitely; (2) large objects written to etcd (Helm release secrets with full chart content, large CRD instances, base64-encoded ConfigMaps with binary data) each consuming many BoltDB pages; (3) BoltDB internal fragmentation — free pages not recovered until defrag; (4) excessive write rate causing revisions to accumulate faster than compaction can keep up.

**Blast Radius**: Complete cluster write path is frozen. The cluster becomes read-only. No new pods can start. No ConfigMap or Secret changes can be applied. CI/CD pipelines fail entirely. If the cluster uses GitOps (ArgoCD, Flux), all sync operations fail with reconciliation loops logging `mvcc: database space exceeded`. This is a P0 incident — the cluster cannot self-heal because etcd's own status writes (leader heartbeats) must also go through the quota-checked path, though etcd internal writes are exempt from the `NOSPACE` alarm.

**Mitigation**:
- Prevent by setting `--quota-backend-bytes=8589934592` (8GB) on all etcd members from the start. Alert at 70% utilization (5.6GB) to trigger investigation before hitting the limit.
- Ensure `kube-controller-manager` is running (it drives etcd compaction via `--etcd-compaction-interval`). If it is down, compaction stops and revisions accumulate.
- Run regular defragmentation: monthly minimum, weekly in high-churn clusters. After defrag, DB size drops to `dbSizeInUse` (actual data without fragmentation).
- Audit large objects: Helm stores compressed chart archives as Secrets; these can be 1-3MB each and accumulate across releases. Use `helm ls --all-namespaces` and `helm history <release> -n <ns>` to identify release histories and trim with `helm history --max 3` or migrate to Helm's SQL backend.
- Set Kubernetes Event retention: Events are stored in etcd with a 1-hour TTL (controlled by `--event-ttl` on kube-apiserver, default 1h). Shortening this or moving Events to a separate etcd cluster reduces primary etcd size.

**Recovery procedure** (emergency, cluster is read-only):

```bash
# Step 1: Verify the alarm is active
kubectl exec -n kube-system etcd-<node> -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  alarm list
# Expected output: memberID:XYZ alarm:NOSPACE

# Step 2: Trigger compaction manually to the current revision
CURRENT_REV=$(kubectl exec -n kube-system etcd-<node> -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --write-out=json | jq -r '.[0].Status.header.revision')

kubectl exec -n kube-system etcd-<node> -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  compact "$CURRENT_REV"

# Step 3: Defragment all members (recovers BoltDB free pages)
kubectl exec -n kube-system etcd-<node> -- etcdctl \
  --endpoints=https://etcd-0:2379,https://etcd-1:2379,https://etcd-2:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  defrag --cluster

# Step 4: Disarm the NOSPACE alarm (only after DB size is below quota)
kubectl exec -n kube-system etcd-<node> -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  alarm disarm

# Step 5: Verify DB size is now below quota
kubectl exec -n kube-system etcd-<node> -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --write-out=table

# Step 6: Identify the largest key prefixes to prevent recurrence
kubectl exec -n kube-system etcd-<node> -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry --prefix --keys-only | \
  sed 's|/registry/||' | cut -d'/' -f1,2 | sort | uniq -c | sort -rn | head -20

# Step 7: For Helm release bloat specifically, trim history
helm ls --all-namespaces -o json | jq -r '.[] | .name + " " + .namespace' | \
  while read name ns; do
    count=$(helm history "$name" -n "$ns" --max 100 -o json 2>/dev/null | jq length)
    echo "$ns/$name: $count releases"
  done | sort -t: -k2 -rn | head -10
```

## Lightweight Lab

See [lab/README.md](lab/README.md) for the full exercise. The lab creates a kind cluster, generates artificial etcd load, and demonstrates APF throttling with real metrics.

Key commands to run immediately to build intuition:

```bash
# 1. Measure how fast kubectl list scales with object count
# Create 200 namespaces and measure LIST latency before and after
time kubectl get namespaces --request-timeout=30s | wc -l
for i in $(seq 1 200); do kubectl create ns "scale-test-$i" 2>/dev/null; done
time kubectl get namespaces --request-timeout=30s | wc -l

# 2. Watch etcd DB size grow in real time as you create objects
watch -n2 'kubectl exec -n kube-system etcd-<control-plane-node> -- \
  etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --write-out=table 2>/dev/null'

# 3. Observe fsync latency histogram from etcd metrics
kubectl exec -n kube-system etcd-<control-plane-node> -- sh -c \
  "curl -s http://127.0.0.1:2381/metrics" | \
  grep 'etcd_disk_wal_fsync_duration_seconds_bucket' | tail -15

# 4. List all FlowSchemas and their assigned priority levels
kubectl get flowschemas -o custom-columns=\
'NAME:.metadata.name,PRECEDENCE:.spec.matchingPrecedence,PRIORITY:.spec.priorityLevelConfiguration.name' \
  --sort-by='.spec.matchingPrecedence'

# 5. View live APF concurrency consumption
kubectl get --raw /metrics | grep apiserver_flowcontrol_current_executing_requests

# 6. Identify the largest key prefixes in etcd (requires exec access to etcd pod)
kubectl exec -n kube-system etcd-<control-plane-node> -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry --prefix --keys-only 2>/dev/null | \
  cut -d'/' -f1-4 | sort | uniq -c | sort -rn | head -20

# 7. Clean up test namespaces
for i in $(seq 1 200); do kubectl delete ns "scale-test-$i" --wait=false 2>/dev/null; done
```
