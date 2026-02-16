# Talk Tracks: Informers, Caches & Indexers

## Q: Explain informers in one minute.

**Answer:**

Informers convert the expensive LIST+WATCH API pattern into efficient local caches. When a controller starts, the informer issues a LIST to seed the cache with current state, then opens a long-lived WATCH connection to stream incremental updates. This means controllers read from local memory instead of making API calls on every reconciliation, dramatically reducing API server load. The SharedInformerFactory ensures multiple controllers share a single watch and cache per resource type, not duplicate watches. Correctness comes from continuous reconciliation—informers provide eventually consistent caches, and controllers handle drift by reconciling reality toward desired state.

Internally, the reflector manages LIST+WATCH, feeding events into a DeltaFIFO queue that deduplicates and orders updates. Event handlers process the queue, updating the thread-safe store and triggering controller reconciliations. Custom indexers enable O(1) lookups beyond namespace/name, like finding all pods on a node. The resync period re-enqueues all cached items periodically to recover from missed events and detect external drift.

**If they push deeper:**

The reflector tracks resourceVersion from the initial LIST and uses it as the starting point for WATCH. When the watch connection breaks—due to network issues, API server restarts, or etcd compaction making the resourceVersion too old—the reflector automatically re-LISTs to get fresh state and re-WATCHes from the new resourceVersion. This handles transient failures without manual intervention. The DeltaFIFO queue compresses events: if a pod is created, updated three times, then deleted before processing completes, the queue can compress this to a single Add followed by Delete, skipping intermediate updates since the final result is deletion anyway.

## Q: Walk me through how LIST+WATCH works and why informers are necessary.

**Answer:**

Without informers, every time a controller needs to read a resource, it would issue a LIST API call to fetch all resources of that type. In a cluster with 50,000 pods, each reconciliation would transfer hundreds of megabytes from API server to controller. If 10 controllers each reconcile 100 times per second, that's 1000 LIST calls per second, overwhelming the API server and etcd.

Informers solve this by inverting the flow. At startup, the controller issues a single LIST to get all pods and their current resourceVersion. Then it opens a WATCH connection starting from that resourceVersion, which streams only incremental changes: ADDED, MODIFIED, DELETED events. The informer maintains a local in-memory cache, so controllers read from cache—a local memory lookup—instead of making API calls. The watch connection stays open indefinitely, streaming events as they happen, so the cache stays synchronized with cluster state.

The SharedInformerFactory prevents duplicate watches. If three controllers all watch Pods, without SharedInformerFactory you'd have three separate WATCH connections and three separate caches. SharedInformerFactory shares a single watch and cache among all controllers watching the same resource type. This is critical at scale—imagine watching 100 resource types across 20 controllers.

**If they push deeper:**

The WATCH protocol uses HTTP chunked transfer encoding or WebSocket to stream events indefinitely. Each event includes the resource's new state and its resourceVersion. If the watch connection closes unexpectedly—network blip, API server restart, or the resourceVersion became too old due to etcd compaction—the client detects this and issues a new LIST+WATCH. The new LIST gets fresh state, and WATCH resumes from the new resourceVersion. This is why controllers are resilient to API server restarts without losing state. The resync period provides an additional safety net: even if watch events were somehow missed, resync will eventually re-trigger reconciliation for all cached items.

## Q: What is the reflector, DeltaFIFO, and store pipeline?

**Answer:**

The informer architecture has three key components that work together. The reflector is responsible for LIST+WATCH. It issues the initial LIST to seed the cache, then opens a WATCH connection from that resourceVersion. When watch events arrive, the reflector feeds them into the DeltaFIFO queue. If watch fails, the reflector re-LISTs and re-WATCHes automatically with exponential backoff to prevent thundering herds.

DeltaFIFO is a specialized queue that handles deduplication and ordering. Delta means it stores changes, not full objects. If the same object is updated multiple times while the queue is being processed, DeltaFIFO compresses them into a single entry with the latest state. FIFO ensures events are processed in order. For example, if a pod is created then updated then deleted, these events are processed in that exact sequence, even if the update event arrived out of order.

The store is the final in-memory cache—a thread-safe map keyed by namespace/name. After events pass through DeltaFIFO and event handlers, the store is updated. Controllers read from the store using listers, which provide a read-only interface. The store also maintains custom indexes for fast lookups beyond the primary key. This separation of concerns—reflector for synchronization, DeltaFIFO for ordering, store for fast reads—makes informers robust and performant.

**If they push deeper:**

DeltaFIFO has special handling for deletion. When an object is deleted, it may no longer exist in the API server, so the delete event includes the last known state, called a tombstone. The DeletionHandlingMetaNamespaceKeyFunc extracts the key from either a live object or a tombstone, which is why delete handlers use it instead of the regular MetaNamespaceKeyFunc. The store's thread safety is critical because multiple goroutines—controller workers and informer update loops—read and write concurrently. It uses read-write locks to allow concurrent reads while serializing writes.

## Q: What are custom indexers and when should you use them?

**Answer:**

By default, the informer cache is indexed only by namespace/name, which allows fast Get operations like "give me the pod default/my-pod." But controllers often need to answer questions like "give me all pods on node-1" or "give me all pods owned by this ReplicaSet." Without custom indexers, you'd have to List all pods, then iterate through them filtering by node name—an O(n) operation that scans the entire cache.

Custom indexers are secondary indexes you define at informer creation time. You provide an indexer function that extracts index keys from each object. For example, a "byNodeName" indexer would extract pod.Spec.NodeName and map it to the pod. Now you can call ByIndex("byNodeName", "node-1") and get all pods on that node in O(1) time—a direct hash lookup, no iteration. This is the same pattern as database indexes: you pay upfront cost to maintain the index, but queries become extremely fast.

The Kubernetes scheduler heavily uses custom indexers—it needs to know all pods on each node for bin-packing decisions. Owner reference lookups are another common use case: finding all pods owned by a ReplicaSet, or all services in a namespace owned by a certain controller. Any time you're doing List plus filter, consider a custom indexer instead.

**If they push deeper:**

Indexers can return multiple values for a single object. For example, a pod with multiple owner references would appear under each owner's index entry. The indexer function returns a slice of strings, and the object is indexed under each one. You can also have multiple indexes on the same cache—byNodeName, byOwner, byLabelSelector—they coexist. However, each index increases memory usage and update cost. When an object changes, all indexes must be recalculated. So don't add indexes speculatively; add them when profiling shows List+filter is a bottleneck.

## Q: What is the resync period and how does it work?

**Answer:**

The resync period controls how often all items in the cache are re-enqueued for reconciliation, even if they haven't changed. For example, if you set a 10-hour resync, every 10 hours the informer triggers OnUpdate(obj, obj) for every cached object, as if they all just changed. This causes controllers to reconcile every resource, which detects external drift—changes made outside Kubernetes that the controller should fix.

Resync does NOT issue a new LIST to the API server. It simply walks through the local cache and re-triggers event handlers. So it doesn't add API server load, but it does add controller reconciliation load. The default in controller-runtime is 10 hours, which is a reasonable balance for most controllers. If your controller manages cloud resources that users might modify directly, a shorter resync like 1 hour makes sense. If your controller only manages Kubernetes resources that can't be modified externally, you could disable resync entirely with period 0.

The tradeoff is drift detection speed versus CPU and API load. Shorter resync means faster drift detection but more reconciliations. Longer resync means less load but slower detection. In practice, most controllers rely on watches for immediate updates and use resync as a safety net for missed events or network glitches.

**If they push deeper:**

There's a subtle interaction between resync and watch failures. If your watch connection breaks and stays broken for 15 minutes, then reconnects, the reflector re-LISTs and you get fresh state. But if the watch breaks for only 5 seconds, you might miss events that happened during that window. Resync guarantees that even missed events will eventually be processed, at most one resync period later. This is why completely disabling resync is risky unless you have other mechanisms for drift detection, like periodic status checks or alerts on cloud resource changes.

## Q: How do informers reduce API server load compared to polling?

**Answer:**

Without informers, controllers would poll the API server—repeatedly calling LIST every few seconds to check for changes. This is extremely wasteful. In a cluster with 50,000 pods, each LIST returns 500 MB of data. If you poll every 5 seconds, that's 100 MB/s of bandwidth and hundreds of etcd reads per second, just for one resource type. Scale that across 100 resource types and 20 controllers, and you've overloaded the API server.

Informers use LIST+WATCH instead of polling. You LIST once at startup to seed the cache—expensive, but happens only once. Then you open a single long-lived WATCH connection that streams incremental updates. Only changed objects are sent, not the entire dataset. If only 3 pods change in a minute, only 3 WATCH events are sent, not 50,000 LIST responses. This reduces API server load by orders of magnitude.

The SharedInformerFactory amplifies these savings. Without it, every controller creates its own watch and cache, duplicating work. With it, all controllers watching Pods share a single watch and a single cache. So you go from 20 LIST calls and 20 WATCH connections down to 1 LIST and 1 WATCH. The memory savings are also significant—one 500 MB cache instead of twenty 500 MB caches.

**If they push deeper:**

There's an interesting tradeoff with WATCH at extreme scale. If you're watching 1 million objects and they all change frequently, the WATCH connection streams constant updates. At some point, WATCH traffic can exceed periodic polling traffic. But in practice, this rarely happens because most objects are stable—they change occasionally, not constantly. And even if every object changes once per day, WATCH still sends only the change events, while polling sends the entire dataset every N seconds. The watch model is fundamentally more efficient for most real-world workloads. The only time polling might make sense is if you need a snapshot exactly every N minutes and don't care about intermediate changes—but that's not how Kubernetes controllers work.

## Q: What can go wrong with informers and how do you debug them?

**Answer:**

The most common failure is watch connection loss. If the network partitions or the API server restarts, the watch connection closes. The reflector detects this and automatically re-LISTs and re-WATCHes, so no manual intervention is needed. But if this happens frequently, it indicates network instability or API server load issues. You'll see "watch closed" or "reflector error" in controller logs. The reflector_watch_duration_seconds metric shows how long watch connections stay open—short durations mean frequent reconnects.

Another issue is cache memory pressure. If you're watching large resources or many resources, the cache can grow to gigabytes. In a 5000-node cluster with 50,000 pods averaging 10 KB each, the pod cache alone is 500 MB. Add custom indexers and you can hit OOMKills. Mitigate this by using namespace-scoped or label-filtered informers to reduce cache size. Monitor controller memory usage and set appropriate limits.

Resync storms happen when all controllers resync simultaneously. If 10 controllers each watch 10,000 resources and all resync at the same time, you get 100,000 reconciliations in a few seconds, spiking CPU and API load. Stagger resync periods across controllers—10h, 11h, 12h—to spread the load.

**If they push deeper:**

Stale reads are subtle. If you read from cache immediately after controller startup, before HasSynced() returns true, the cache is empty or incomplete. Always call cache.WaitForCacheSync before starting controller workers. Also, informer caches are eventually consistent—there's a small lag between an API server write and the cache update. Controllers must handle IsNotFound errors gracefully, because a recently created object may not be in cache yet. This is why reconciliation must be idempotent and handle all edge cases.

## Q: How would you apply this in a platform engineering context?

**Answer:**

Informers are critical for building scalable platform controllers. At my last company, we built a namespace controller that watched Namespace resources and automatically created ResourceQuotas, NetworkPolicies, and RoleBindings for each namespace. Without informers, we'd have to poll the API server every few seconds to check for new namespaces. With informers, we got instant notifications via watch events and read namespace state from cache—no API calls during reconciliation.

We also used custom indexers for cross-resource lookups. For example, our ingress controller watched Ingress objects but needed to find all Services referenced by those ingresses. We added a "byIngressRef" indexer on Services so we could quickly find all services for a given ingress without scanning all services in the cluster. This was essential at scale—we had 10,000 services and 5,000 ingresses.

Another pattern is using informers to cache external state. We had a controller that synchronized Kubernetes Secrets with AWS Secrets Manager. It used an informer to watch Secrets with a specific label, and when one changed, it reconciled to AWS. The informer's resync period ensured we'd detect if someone manually modified secrets in AWS—we'd reconcile every 2 hours and fix any drift. This made our platform self-healing without constant polling of AWS APIs.

**If they push deeper:**

One advanced pattern is multi-cluster informers. In a platform that spans multiple Kubernetes clusters, you can run informers against each cluster's API server and aggregate the caches. We built a global service mesh controller that watched Services and Endpoints across 5 regional clusters. It used one SharedInformerFactory per cluster, then merged the caches in memory to build a global view of service topology. This let us implement cross-cluster load balancing and failover. The key was namespacing the caches by cluster ID to avoid conflicts, and carefully managing watch connection lifecycle when clusters went down. This pattern powers tools like multicluster-scheduler and Submariner.

## Q: How does cache consistency work and what guarantees do you have?

**Answer:**

Informer caches are eventually consistent, not strongly consistent. When a user creates a pod, it's written to etcd, then the API server sends a WATCH event to the informer. There's a small lag—typically under 100 milliseconds—between the write and the cache update. If your controller reads from cache during that window, it won't see the new pod yet. This is a stale read.

Controllers must be designed to handle this. Always check for IsNotFound errors when reading from cache. If a reconciliation is triggered for a newly created object but the cache doesn't have it yet, return nil and let the watch event trigger another reconciliation in a moment. Never assume the cache is perfectly synchronized with the API server. Correctness comes from continuous reconciliation—even if you miss an event or read stale data, the next reconcile will catch it.

The cache does guarantee sequential consistency per object. If you see pod update version 100, you won't suddenly see version 99 later. ResourceVersion always increases. But you might see version 100, then nothing (stale read), then version 102 (missed version 101). This is fine because controllers reconcile the entire desired state, not just the delta. They compare current reality to desired state and take actions to converge, so missing intermediate states doesn't break correctness.

**If they push deeper:**

There's an important interaction with watch event ordering. The API server sends events in resourceVersion order, but if you have multiple informers watching different resources, there are no cross-resource ordering guarantees. For example, if a Deployment creates a ReplicaSet creates a Pod, you might see the Pod ADDED event before the ReplicaSet ADDED event, depending on network timing. Your controller must handle resources appearing in any order. This is another reason why reconciliation must be idempotent and check actual state, not assume a specific event sequence. The controller pattern's "observe-diff-act" loop is inherently robust to out-of-order events.

## Q: What happens when the API server restarts?

**Answer:**

When the API server restarts, all existing WATCH connections are closed. The reflector detects this—usually within seconds, when it tries to read from the watch connection and gets EOF or a connection error. It immediately attempts to re-LIST, which will fail because the API server is down. The reflector backs off exponentially, retrying every few seconds, then every minute, up to a maximum backoff.

Once the API server comes back up, the reflector's next retry succeeds. It issues a fresh LIST to get current state and opens a new WATCH from the new resourceVersion. The cache is updated with fresh data. If any resources were created, updated, or deleted while the API server was down, the LIST captures these changes—the cache reflects the new reality. From the controller's perspective, it just sees a brief period of reconciliation failures (because it can't reach the API server), then things resume normally.

Importantly, the cache persists during the API server downtime. Controllers can still read from cache—it's stale, but available. They can't write updates, so reconciliations will fail, but they won't crash. The controller's work queue retries failed reconciliations with exponential backoff. Once the API server is back, queued work is processed and the controller catches up. This is why controllers are resilient to transient API server failures.

**If they push deeper:**

There's a subtle edge case with resourceVersion. etcd periodically compacts old revisions. If the API server is down for hours and etcd compacts revisions, the resourceVersion the reflector was watching might no longer exist. When the reflector tries to WATCH from that resourceVersion, the API server returns "410 Gone - resourceVersion too old". The reflector handles this by issuing a fresh LIST without a resourceVersion, getting current state, and starting a new WATCH. This is why LIST+WATCH is robust to long outages—you might miss some history, but you always get back to a consistent state.
