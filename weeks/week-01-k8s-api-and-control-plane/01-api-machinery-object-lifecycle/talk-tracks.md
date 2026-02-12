# Talk Tracks

## Q: Explain this in one minute.

**Answer:**

Kubernetes is fundamentally a declarative system built on three pillars: an API server that validates and persists desired state to etcd, a watch mechanism that streams state changes to interested clients, and independent controllers that reconcile actual state toward desired state. When you kubectl apply a manifest, the API server authenticates you, checks RBAC authorization, runs admission webhooks for policy enforcement, validates the schema, and persists to etcd using optimistic locking via resourceVersion. The watch cache then notifies all controllers watching that resource type. Controllers use Informers to maintain local caches and enqueue work when relevant objects change. The reconciliation loop is level-triggered and idempotent - it reads current state, compares to desired state, and takes action only when they differ. This architecture enables eventual consistency, resilience to component failures, and extensibility through custom resources and controllers.

## Q: Walk me through the internals.

**Answer:**

The request path starts with authentication - the API server tries authn plugins in order (client certs, bearer tokens, OIDC) to establish identity. Next, RBAC authorizers check if the user/group has permission for the requested verb on that API group and resource. Then mutating admission webhooks run sequentially and can modify the object - ServiceAccount admission injects tokens, custom webhooks inject sidecars. The API server validates the object against its OpenAPI v3 schema from the CRD or built-in types. Validating admission webhooks then run and can reject but not modify. If all checks pass, the API server serializes the object and writes to etcd using CompareAndSwap, checking resourceVersion for optimistic concurrency control. After persistence, the watch cache (cacher) notifies all active watchers. On the client side, Informers maintain a long-lived watch connection, store events in a local cache indexed by namespace/name, and invoke registered event handlers. Controllers' handlers extract the object key and enqueue it in a rate-limited work queue. Worker goroutines dequeue keys and call the reconcile function, which reads from the Informer cache, computes the delta, and applies changes by calling the API server, starting the cycle again.

## Q: What can go wrong?

**Answer:**

First, admission webhook failures can block the entire write path. If a webhook times out or is unavailable and has failurePolicy Fail, all matching creates and updates are rejected cluster-wide. This is especially dangerous with broad selectors - I've seen production outages where a misconfigured webhook matching all resources prevented even kubectl operations. Second, etcd performance degradation creates cascading failures. When disk I/O is slow or the database grows beyond 8GB without defragmentation, API server latency spikes affect all operations. Controllers fall behind because their watch caches lag, status updates delay, and the scheduler can't bind pods quickly. Third, controller hot loops occur when non-idempotent reconciliation logic writes to the object on every pass, triggering new watch events infinitely. This exhausts API server capacity and can OOMKill the controller. Detection uses workqueue depth metrics and checking if observedGeneration keeps up with generation.

## Q: How would you debug it?

**Answer:**

I start by identifying symptoms - are writes slow, reads slow, or specific resources stuck? For admission failures, I check API server logs for webhook timeouts and inspect ValidatingWebhookConfiguration/MutatingWebhookConfiguration to verify failurePolicy, timeoutSeconds, and selector scope. I test if the webhook service and endpoints exist and if the pod is healthy. For etcd issues, I examine the etcd_disk_backend_commit_duration_seconds metric - p99 should be under 25ms. I check database size with etcdctl endpoint status and run defrag if it's bloated. For controller issues, I look at workqueue_depth and workqueue_retries_total metrics, dump controller logs filtering for the stuck resource key, and compare metadata.generation to status.observedGeneration. I also inspect the object's managedFields to see which controller owns which fields. Finally, I trace a specific object through kubectl get with -o yaml, checking resourceVersion progression, events, and status conditions to see where the pipeline is stuck.

## Q: How would you apply this in a platform engineering context?

**Answer:**

In multi-tenant platforms, understanding the API machinery is critical for building reliable operators and debugging cross-team issues. When building a database operator that provisions RDS instances, the operator watches DatabaseClaim CRs using Informers, and the reconciliation must handle eventual consistency - after creating the RDS instance via AWS API, the operator writes status.endpoint but that update might not be visible to other controllers immediately due to watch lag. I use resourceVersion to implement conditional updates preventing lost writes when multiple reconcilers touch the same object. For multi-cluster config propagation, hub-spoke patterns use this same watch mechanism - a hub controller watches Namespace objects with team labels, computes desired Role and RoleBinding per cluster, and writes them to spoke cluster API servers. Each spoke cluster's Informer picks up changes and reconciles local RBAC. Generation and observedGeneration are essential for detecting configuration drift - if a GitOps controller's observedGeneration lags behind generation, I know it hasn't processed the latest spec change, maybe due to validation errors or rate limiting. For cost optimization, I build controllers that watch Pod and Node objects, aggregate metrics, and write CostReport CRs with per-tenant usage. Understanding that etcd is the source of truth helps me design proper backup strategies - etcd snapshots capture all cluster state, but resourceVersion progression must be tracked to implement incremental backups and point-in-time recovery.

## Q: What's the difference between generation and resourceVersion?

**Answer:**

resourceVersion is an opaque string representing the etcd ModRevision - it changes on every update to the object, whether spec, status, labels, or annotations. It's used for optimistic concurrency control in updates and as a bookmark for watch streams. generation is spec-specific and only increments when .spec changes, staying constant for status-only updates. Controllers write status.observedGeneration after reconciling to signal they've processed that spec version. This pattern prevents unnecessary reconciliation - a controller can skip work if observedGeneration equals generation. For example, if I update a Deployment's status to add a condition, resourceVersion increments but generation stays the same, so the ReplicaSet controller doesn't recreate ReplicaSets unnecessarily.

## Q: How does eventual consistency affect troubleshooting?

**Answer:**

Eventual consistency means state changes propagate through multiple asynchronous stages, so symptoms appear delayed and potentially out of order from root causes. When debugging, I can't assume all components see the same state at the same time. For example, if a user reports "my pod isn't running," the issue might be that the Deployment was created, the Deployment controller hasn't reconciled yet, or it created a ReplicaSet but the ReplicaSet controller hasn't created Pods, or Pods exist but the Scheduler hasn't bound them, or they're bound but kubelet hasn't pulled the image yet. Each component operates on cached state from Informers, which might be seconds behind etcd. I trace through each layer checking resourceVersion and timestamps. I also watch for split-brain scenarios - if a network partition prevents a controller from watching, it operates on stale cache while new objects are created, leading to conflicts when it reconnects.

## Q: Explain how watches scale to thousands of controllers.

**Answer:**

The API server's watch cache (cacher) maintains an in-memory circular buffer of recent events per resource type, avoiding the need to stream from etcd for every watcher. When a new watch is established, if the client provides a resourceVersion within the buffer window (typically last 5 minutes of events), the server replays from memory. This allows thousands of Informers across controller pods to watch efficiently. The cacher also implements fanout - a single etcd watch populates the cache, and the cache streams to all client watchers. Watches use HTTP/2 chunked transfer encoding so the server can multiplex many streams over a single connection. On the client side, SharedInformerFactory prevents duplicate watches - if multiple controllers watch the same resource type, they share one Informer and watch connection, reducing API server load. The trade-off is memory - the watch cache can grow large in clusters with high churn, and clients maintain full copies of watched objects in their caches.

## Q: How do you handle watch connection failures and reconnection?

**Answer:**

The Reflector component in client-go implements automatic reconnection with exponential backoff. When a watch connection breaks due to network issues or API server restart, the Reflector attempts to resume from the last seen resourceVersion. If that resourceVersion is still in the API server's watch cache window, the watch resumes and replays missed events. If the resourceVersion is too old (beyond the cache window), the server returns 410 Gone, and the Reflector falls back to a full list operation to rebuild the cache, then establishes a new watch from the current resourceVersion. During the reconnection gap, the controller operates on stale cache, which is safe because reconciliation is level-triggered - when the watch reconnects and the cache updates, any drift gets corrected in the next reconcile. Controllers should implement cache sync checks using WaitForCacheSync before starting workers to ensure the initial cache population completes. For critical controllers where stale reads are unacceptable, you can bypass the cache and do live API reads, trading latency for consistency. I monitor watch connection uptime and list/watch error rates to detect chronic connectivity issues that might indicate network problems or API server instability.

## Q: What's the relationship between API priority and fairness and watch performance?

**Answer:**

API Priority and Fairness (APF) introduced in Kubernetes 1.20 replaces simple max-inflight-requests throttling with a multi-level queuing system. Each request is classified into a FlowSchema based on user, verb, and resource, then assigned to a PriorityLevel with guaranteed concurrency shares. Watch requests are treated specially - they're typically classified as high-priority long-running requests that don't count against concurrency limits the same way list/get/update do, preventing watches from being starved by burst traffic. This is critical for controller stability because watch disconnections cause cache invalidation and expensive relist operations. However, if you have thousands of watches and limited API server resources, even watches can be throttled. I monitor the apiserver_flowcontrol_rejected_requests_total metric to detect if any FlowSchemas are rejecting watches, and tune PriorityLevel concurrency shares accordingly. For platform controllers, I create custom FlowSchemas with dedicated PriorityLevels so platform infrastructure controllers get reserved API server capacity even during tenant request storms, ensuring critical reconciliation continues during incidents.
