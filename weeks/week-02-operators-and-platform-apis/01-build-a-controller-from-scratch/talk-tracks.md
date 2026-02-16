# Talk Tracks: Build a Controller from Scratch

## Q: Explain controllers in one minute.

**Answer:**

A Kubernetes controller is a continuous reconciliation loop that ensures the actual state of resources matches their desired state. Users declare intent through the spec field, and the controller continuously observes reality, compares it to spec, and takes corrective actions. The status field reports observed reality back to users. This pattern enables declarative infrastructure—you describe what you want, and controllers figure out how to get there and maintain it.

Controllers use finalizers to ensure safe deletion by blocking resource removal until external cleanup completes. They're designed to be idempotent, meaning the same reconciliation can run repeatedly without side effects. This handles retries, crashes, and controller restarts gracefully. The key insight is that controllers don't just "apply changes once"—they continuously converge reality toward intent, handling drift and failures automatically.

**If they push deeper:**

The reconcile function receives a namespace/name key whenever a watched resource changes. It reads current state from a local cache (populated by informers), compares it to desired state in the spec, performs necessary API calls or external operations, then updates the status subresource. Return values control requeuing: return an error for automatic retry with exponential backoff, or explicitly requeue after a delay for polling operations. The controller-runtime library provides shared informer factories, work queues with deduplication and rate limiting, and structured concurrency for running multiple reconcile workers.

## Q: Walk me through the internals of the reconcile loop.

**Answer:**

When a user applies a resource with `kubectl apply`, the API server validates it, persists it to etcd, and increments the `metadata.generation` field. The controller's informer detects this via a watch connection and updates its local cache. The informer then calls an event handler that enqueues the resource's namespace/name into a work queue. The work queue deduplicates keys, rate-limits, and provides exponential backoff for failures.

A worker goroutine pulls the key from the queue and invokes the Reconcile function. Reconcile first fetches the resource from cache, then follows this flow: check if `deletionTimestamp` is set—if so, perform finalizer cleanup and remove the finalizer. If not being deleted, add the finalizer if missing. Then execute domain logic: create, update, or delete external resources as needed. Finally, update the status subresource with the observed state, including setting `observedGeneration` to match `metadata.generation` and updating condition timestamps. The entire reconcile must be idempotent since it may be called multiple times for the same state.

**If they push deeper:**

The work queue implements exponential backoff—if Reconcile returns an error, the queue automatically retries with increasing delays (1s, 2s, 4s, up to a max). This prevents retry storms when downstream systems are down. The queue also deduplicates keys: if the same resource is modified 10 times while the controller is reconciling it, only one additional reconcile happens afterward. Controller-runtime provides predicates to filter events before they hit the queue—for example, only reconciling on generation changes, not status updates. For status updates specifically, the controller uses a separate status client that writes only to the `/status` subresource, which has separate RBAC permissions and avoids triggering another generation increment.

## Q: What can go wrong with controllers?

**Answer:**

The three most common failure modes are dangling finalizers, status spam, and reconciliation storms. Dangling finalizers occur when a controller crashes or is deleted before removing its finalizer from a resource, leaving it stuck in "Terminating" state forever. This is the #1 complaint from users. Mitigation includes implementing timeouts on cleanup operations, providing a manual override annotation like `force-delete: "true"`, and testing deletion flows extensively.

Status spam happens when controllers update status on every reconcile even when nothing changed, often due to updating timestamps or not comparing old vs new status. This creates unnecessary API server load, etcd write amplification, and watch event storms. The fix is to compare status before updating and only write when values actually change.

Reconciliation storms occur when a controller reconciles the same resource hundreds of times per second, usually because its own writes trigger new reconciliations, or because it's watching resources without predicates and every change triggers a reconcile. Use generation-based predicates to ignore status-only updates, and implement explicit requeue delays for polling operations rather than requeuing immediately.

**If they push deeper:**

Another subtle failure mode is race conditions during concurrent reconciles. If `MaxConcurrentReconciles` is greater than 1, multiple workers can reconcile different resources simultaneously, which is safe. However, some operators mistakenly reconcile the same resource concurrently, causing lost updates or inconsistent external state. Controller-runtime's work queue prevents this by default—the same key won't be processed by multiple workers simultaneously.

There's also the "forgotten requeue" problem: if reconciliation succeeds but the resource isn't in its final state yet (e.g., provisioning a database that takes 5 minutes), you must return `ctrl.Result{RequeueAfter: 30*time.Second}` to check back later. Forgetting this leaves resources in transitional states forever. Always requeue when you're waiting for external systems.

## Q: How would you debug a controller that's not reconciling?

**Answer:**

Start by checking if the controller is running and healthy: `kubectl get pods -n controller-namespace` and check the logs for panics or errors. Then verify the controller is watching the right resources—check the SetupWithManager function to confirm the resource types and predicates. Use controller metrics if available: `workqueue_depth` shows how many reconciles are queued, `controller_runtime_reconcile_total` shows reconcile count and errors.

If the resource isn't being reconciled at all, check if informer caches are synced—controller-runtime waits for caches before starting reconciles. You can also check the resource's `metadata.generation` vs `status.observedGeneration`—if they're different, the controller hasn't processed the latest spec yet. Check for rate limiting: if the controller is returning errors repeatedly, exponential backoff may have it waiting minutes between retries.

If reconciles are happening but not having the expected effect, add detailed logging in the Reconcile function to trace the code path. Check RBAC permissions—controllers often fail silently if they can't read/write certain resources. Finally, check for conflicts with other controllers: multiple controllers modifying the same fields can cause constant churn.

**If they push deeper:**

For advanced debugging, you can use kubectl with high verbosity: `kubectl -v=8 get database my-db` shows all API calls, including watch events. This helps identify if watch connections are breaking. For informer cache issues, check if the controller's namespace filtering is too restrictive—if you're watching cluster-scoped resources but the informer is namespace-scoped, watches won't work. Also verify the controller has the correct API server endpoint—in multi-cluster setups, controllers sometimes connect to the wrong cluster.

## Q: How would you apply this in a platform engineering context?

**Answer:**

Controllers are the foundation of platform abstraction. For example, at my last company we built a DatabaseClaim controller where developers create a simple CRD specifying engine type and size, and the controller provisions the actual cloud database, configures backups, creates credentials in Vault, and writes connection strings to a Secret. This abstracted away 50+ steps of database provisioning into a single kubectl apply.

Another common pattern is building Ingress or Gateway controllers that reconcile Kubernetes resources into cloud load balancers or API gateways. The controller watches Ingress objects, translates them to cloud-specific APIs, and updates the Ingress status with the load balancer endpoint. This lets developers use portable Kubernetes APIs while the platform handles vendor-specific details.

For multi-tenant platforms, we used controllers to enforce policy: a namespace controller that watches Namespace resources and automatically applies ResourceQuotas, NetworkPolicies, and RBAC bindings based on labels. This ensures all tenants get consistent security posture without manual setup. The key is designing clear CRD contracts that hide complexity while giving developers the right level of control.

**If they push deeper:**

One advanced pattern is the "composite controller" used by Crossplane: a single CRD (like PostgreSQLInstance) that the controller breaks into multiple lower-level resources (Database, Subnet, SecurityGroup, etc.). The controller watches the composite and reconciles each component resource, tracking their status back to the parent. This enables hierarchical infrastructure as code.

Another pattern is "ownership with inheritance": using owner references and label selectors to create resource hierarchies. For example, a Tenant CRD owns multiple Namespace resources, which own their own Deployment resources. When you delete the Tenant, garbage collection cascades down. The challenge is handling circular dependencies and ensuring proper cleanup order with finalizers and deletionPropagation policies.

## Q: How do finalizers actually work under the hood?

**Answer:**

Finalizers are just string values in `metadata.finalizers` array. When a user deletes a resource, the API server checks if finalizers exist. If they do, instead of deleting the object from etcd, it sets `metadata.deletionTimestamp` to the current time and returns. The object is still readable and watchable, but it's marked for deletion.

Controllers watch for `deletionTimestamp` being set. When they see it, they perform cleanup operations like deleting external resources or removing dependent objects. Once cleanup succeeds, they remove their finalizer string from the array. When the finalizers array becomes empty, the API server garbage collects the object—it's removed from etcd and stops appearing in list/watch results.

The key insight is that finalizers block deletion but don't prevent it indefinitely—they just delay it until controllers have cleaned up. If a controller never removes its finalizer, the resource is stuck forever. That's why production controllers need timeout logic: after 10 minutes, log an error and remove the finalizer anyway to unblock deletion, even if cleanup partially failed.

**If they push deeper:**

Finalizers have a subtle interaction with owner references. If object A has an owner reference to object B, and you delete B, the garbage collector deletes A automatically—but only after B's finalizers are removed. This creates deletion chains: deleting a parent waits for all children's finalizers to complete. You can control this with `deletionPropagation`: `Foreground` waits for children, `Background` deletes parent immediately and lets children clean up asynchronously, and `Orphan` removes owner references without deleting children.

There's also a race condition risk: if a controller crashes between performing cleanup and removing the finalizer, the cleanup happens again on the next reconcile. This means cleanup must be idempotent—safe to run multiple times. For example, when deleting a cloud resource, first check if it exists, then delete. Don't assume delete always means the resource existed.

## Q: What's the difference between status conditions and simple status strings?

**Answer:**

Simple status strings like `status.phase: "Running"` are human-readable but lack structure and actionability. They don't provide timestamps for state transitions, reasons for failures, or multiple concurrent states. Conditions provide structured, machine-readable status that follows Kubernetes conventions: each condition has a type (e.g., "Ready", "Progressing"), a status ("True"/"False"/"Unknown"), a reason (machine-readable), a message (human-readable), and a lastTransitionTime timestamp.

This structure enables powerful use cases. Kubectl wait can block until a condition becomes true: `kubectl wait --for=condition=Ready database/my-db`. Monitoring systems can alert when conditions transition to false. GitOps tools like Flux use conditions to determine if a reconciliation succeeded. Multiple conditions let you express concurrent states: a resource can be "Available" (serving traffic) while "Progressing" (upgrading in the background) and "Degraded" (some replicas failed).

The reason and message fields provide debugging context. When a database fails to provision, the condition might show reason "QuotaExceeded" with message "Cannot allocate disk: project quota reached". This is far more actionable than just "phase: Failed".

**If they push deeper:**

The Kubernetes API conventions define standard condition types that should be used consistently: "Ready" means the resource is fully operational, "Progressing" means it's transitioning to desired state, "Degraded" means it's operational but impaired, and "Available" means minimum replicas are ready. Using these standard types makes your API feel native to Kubernetes and enables generic tooling.

There's an important pattern for condition updates: conditions should only transition when their meaning truly changes. Don't update lastTransitionTime on every reconcile—only when the status value changes. This prevents watch event storms and makes condition history useful for debugging. The meta.SetStatusCondition helper from apimachinery handles this correctly by comparing old and new condition status before updating timestamps.

## Q: How do you handle secrets and sensitive data in controllers?

**Answer:**

Controllers that provision external resources often need to store credentials. The standard pattern is to write credentials to a Kubernetes Secret, with the Secret name specified in the CRD spec. For example, a Database CRD might have `spec.writeConnectionSecretToRef: {name: "my-db-creds"}`. The controller provisions the database, retrieves credentials from the cloud provider, and writes them to that Secret. Applications can then mount the Secret as environment variables or files.

For managing credentials the controller itself needs (like cloud provider API keys), use per-namespace Secrets referenced from the CRD, or a cluster-wide Secret that the controller reads at startup. In production, integrate with secret management systems like Vault, AWS Secrets Manager, or External Secrets Operator. The controller reads from the secret backend and populates Kubernetes Secrets dynamically.

Always use owner references when controllers create Secrets: `controllerutil.SetControllerReference(database, secret, scheme)`. This ensures Secrets are garbage collected when the parent resource is deleted. Also use finalizers to delete secrets from external systems before removing the Kubernetes resource—this prevents orphaned credentials.

**If they push deeper:**

There's a subtle timing issue: when provisioning a database, the database needs to exist before you can retrieve credentials. But if the controller crashes after creating the database but before writing the Secret, the Secret is lost. The solution is to store a reference to the external resource in status first: `status.providerID: "db-12345"`. On subsequent reconciles, check if providerID is set—if so, fetch credentials and create the Secret. This makes credential retrieval idempotent.

For rotating credentials, controllers can watch the Secret and regenerate credentials when a rotation annotation is added. But this is tricky: you need to update both the external system and the Secret atomically, or applications may get stale credentials. Some platforms solve this by supporting multiple active credentials simultaneously, rotating gradually. Crossplane's Connection Secret pattern is worth studying—it handles credential lifecycle well.

## Q: How do you test controllers?

**Answer:**

Controllers should be tested at multiple levels. Unit tests cover individual functions like status condition helpers and spec validation logic. Use envtest from controller-runtime to run integration tests—it spins up a real API server and etcd, so you can test the full reconcile loop without mocks. Write tests that create a resource, call Reconcile, and assert that status was updated correctly and dependent resources were created.

For external systems, use interface abstractions and mocks in tests. Define a DatabaseProvider interface with methods like CreateDatabase and DeleteDatabase, implement a real version for production and a fake for testing. Tests instantiate the controller with the fake provider and can verify the right calls were made without actually hitting cloud APIs.

Testing finalizers is critical: write a test that creates a resource, adds a finalizer, deletes the resource, calls Reconcile, and asserts that cleanup happened and the finalizer was removed. Test failure cases too: if cleanup returns an error, the finalizer should remain and Reconcile should return an error for retry.

**If they push deeper:**

For testing at scale, use chaos engineering: deploy the controller in a test cluster with hundreds of resources and randomly delete controller pods, partition networks, or inject API server latency. This reveals race conditions and reconciliation storms that don't show up in small tests. Some teams use mutation testing—automatically introducing bugs into the controller code and verifying that tests catch them.

Another important pattern is testing idempotency explicitly: write tests that call Reconcile multiple times with the same input and verify the outcome is identical. Create a resource, reconcile it to completion, then reconcile again and assert no external API calls happened. This catches bugs where controllers make duplicate resources or unnecessarily update status.

## Real-World Example: cert-manager Controller

When asked to design a controller in an interview, use this as a reference:

**Spec contract:**
```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: example-com
spec:
  secretName: example-com-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
  - example.com
  - www.example.com
```

**Status contract:**
```yaml
status:
  conditions:
  - type: Ready
    status: "True"
    lastTransitionTime: "2024-01-15T10:30:00Z"
    reason: Ready
    message: "Certificate is up to date and has not expired"
  notBefore: "2024-01-01T00:00:00Z"
  notAfter: "2024-04-01T00:00:00Z"
  renewalTime: "2024-03-01T00:00:00Z"
```

**Reconciliation logic:**
1. Check if certificate Secret exists and is valid
2. If missing or expired, create CertificateRequest resource
3. Watch CertificateRequest until it's ready
4. Copy certificate data from CertificateRequest to Secret
5. Update status with notBefore/notAfter/renewalTime
6. Requeue at renewalTime to trigger automatic renewal

**Finalizer:**
Deletes the Secret and any pending CertificateRequest resources, ensuring no orphaned credentials remain.

This shows clean spec/status separation, proper use of conditions, dependent resource management, and thoughtful UX (automatic renewal via requeue).
