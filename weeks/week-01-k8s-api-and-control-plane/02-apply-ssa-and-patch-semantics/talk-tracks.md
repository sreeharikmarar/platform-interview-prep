# Talk Tracks

## Q: Explain this in one minute.

**Answer:**

Server-Side Apply solves multi-actor object management by moving merge logic into the API server and tracking field ownership in metadata.managedFields. Each client specifies a fieldManager identifier when applying - the server records which manager owns which fields. When you apply a manifest, the server compares your fields against existing ownership: if you own the field or it's unowned, your value is applied; if another manager owns it, you get a 409 Conflict unless you use force. This enables safe collaboration - the platform team manages infrastructure fields via Terraform, GitOps controllers manage application config, and tenants manage their routing rules without conflicts. Unlike legacy client-side apply which tracked state in an annotation and allowed silent overwrites, SSA provides explicit conflict detection and per-field granularity. It uses Strategic Merge Patch semantics to merge arrays by merge keys, making it safe to update one container without replacing the entire container list.

## Q: Walk me through the internals.

**Answer:**

When you send a server-side apply request, you include the fieldManager parameter and Content-Type application/apply-patch+yaml. The API server reads the current object from etcd and its managedFields array. For each field in your apply patch, the server checks the fieldsV1 map in managedFields to see who owns it. If the owner matches your fieldManager or there's no owner, the server updates the value and records your ownership. If a different manager owns it, the server returns 409 Conflict with details about which field and which manager. If you specify force: true, the server removes the other manager's ownership claim and assigns it to you. After ownership calculation, the server merges your patch with the current object using Strategic Merge Patch rules from the OpenAPI schema - for arrays with patchMergeKey like containers by name, it merges element-by-element rather than replacing. Finally, it writes the updated object and managedFields to etcd and notifies watchers. The managedFields entry includes your manager name, operation type (Apply vs Update), apiVersion, timestamp, and a fieldsV1 structure encoding the set of fields you own using a compact representation.

## Q: What can go wrong?

**Answer:**

Field ownership conflicts happen when two managers try to claim the same field without coordinating. For example, if kubectl and Flux both manage spec.replicas on a Deployment, every reconcile produces 409 Conflict. This blocks GitOps pipelines and creates drift between Git and cluster state. The blast radius is limited to affected objects but can cascade if CI/CD depends on successful applies. Second, array merge semantics surprise users - if you apply a manifest updating one container but forget to include the merge key field name, or use JSON Merge Patch instead of Strategic, you replace the entire container array and delete sidecars injected by service mesh or monitoring. This causes runtime failures that are hard to diagnose because the manifest looks correct. Third, drift detection loops occur when a controller applies a partial manifest that doesn't include fields managed by other actors or defaulted by admission - every reconcile the controller sees "drift" and reapplies, even though nothing changed, wasting API server capacity and making logs noisy.

## Q: How would you debug it?

**Answer:**

For conflicts, I inspect managedFields to identify which manager owns the conflicting field: `kubectl get deploy nginx -o json | jq '.metadata.managedFields[] | {manager, fields: .fieldsV1}'`. I check if the conflict is legitimate (two teams actually managing the same field) or accidental (migration from client-side to server-side apply). If legitimate, I coordinate with the other team to define ownership boundaries - maybe platform owns resources and limits while app teams own replicas. If accidental, I use force on one manager to establish clear ownership. For array issues, I verify the patchStrategy for the field using kubectl explain and ensure my manifest includes merge key fields. I test patches with --dry-run=server to preview changes before applying. For drift loops, I watch the object's resourceVersion: if it increments rapidly with no visible changes, I compare managedFields before and after the controller's apply to see which fields are thrashing. I check if the controller includes all fields it manages in the apply or relies on server defaults, and fix the controller to apply complete manifests.

## Q: How would you apply this in a platform engineering context?

**Answer:**

SSA is essential for multi-tenant platforms where multiple actors manage shared infrastructure. For ingress controllers, the platform team manages the Ingress resource structure via Terraform with fieldManager "terraform-platform" - they own TLS certificates, load balancer annotations, and infrastructure-level configuration. Tenant teams manage routing rules via GitOps with fieldManager "flux-tenant-retail" - they own path-based routing rules and backend service references without conflicting with platform config. Admission webhooks enforce that tenants can't claim platform-owned fields. For database operators, the operator uses SSA with fieldManager "postgres-operator" to own status fields and computed spec fields like storage class, while application teams own connection pool settings and replica counts, preventing the operator from overwriting user preferences. In multi-cluster federation, a hub controller uses SSA to replicate namespace-scoped resources to spoke clusters with fieldManager "federation-controller", and if cluster admins manually edit those resources, they get explicit conflicts rather than silent overwrites that cause configuration drift. For cost allocation, I use SSA to inject billing labels with fieldManager "cost-controller" that tenants cannot modify, ensuring accurate chargeback even if tenants update their application labels. SSA's field-level ownership makes it safe to have platform automation, tenant GitOps, and manual admin changes coexist without coordination.

## Q: What's the difference between Strategic Merge Patch and JSON Merge Patch?

**Answer:**

Strategic Merge Patch is Kubernetes-specific and uses schema metadata to merge arrays intelligently, while JSON Merge Patch is a standard RFC that treats all arrays as atomic values to replace. For example, if a Deployment has two containers (nginx and sidecar) and you patch to update nginx's image, Strategic Merge Patch uses the patchMergeKey "name" to identify which container to update, leaving sidecar untouched. JSON Merge Patch would replace the entire containers array, deleting sidecar. Strategic Merge also supports patchStrategy directives like "retainKeys" to delete fields not mentioned in the patch. The trade-off is complexity - Strategic Merge requires schema annotations and isn't usable outside Kubernetes, while JSON Merge Patch is simple and standard but more dangerous for arrays. In practice, SSA uses Strategic Merge semantics by default, giving you the best of both worlds: intelligent array merging plus field ownership tracking.

## Q: When should you use force in Server-Side Apply?

**Answer:**

Force should be used sparingly and intentionally, primarily during ownership migrations or when you're certain you need to take over fields from another manager. Common valid scenarios: migrating from client-side to server-side apply (force once to establish SSA ownership), migrating between GitOps tools (old tool's manager to new tool's manager), or recovering from a misconfigured controller that claimed fields it shouldn't manage. Never use force in automated reconciliation loops without human approval, because it can silently break other controllers' invariants. For example, if your controller force-applies and steals spec.replicas from HorizontalPodAutoscaler, the HPA will thrash trying to set replicas but keep losing ownership. Instead, design systems with clear ownership boundaries from the start, use admission webhooks to prevent managers from claiming fields outside their scope, and coordinate ownership changes via runbooks rather than force.

## Q: How does SSA handle CRDs and custom resources?

**Answer:**

SSA works with CRDs just like built-in types, using the OpenAPI v3 schema defined in the CRD. If your CRD specifies patchStrategy and patchMergeKey for arrays (via x-kubernetes-patch-strategy and x-kubernetes-patch-merge-key extensions), SSA respects them for intelligent array merging. If you don't specify, arrays default to atomic replacement like JSON Merge Patch. This means CRD authors need to think carefully about merge semantics when designing schemas - for example, a list of allowed users should probably have patchMergeKey on username to allow adding users without replacing the whole list. The managedFields tracking is automatic and doesn't require CRD changes, but merge behavior depends on schema annotations. One gotcha: if you update your CRD to change array merge strategies, existing managedFields entries still reference the old schema's apiVersion, which can cause unexpected behavior until all managers reapply with the new version.

## Q: How do you migrate a large fleet from client-side to server-side apply?

**Answer:**

Migration requires careful planning to avoid conflicts and downtime. First, I audit all automation using kubectl get with dry-run to identify which fieldManagers currently own which resources - client-side apply uses "kubectl-client-side-apply" or custom manager names. Second, I update all automation tools (Terraform, Flux, ArgoCD, custom controllers) to use --server-side flag with consistent fieldManager names per team, and test in dev clusters to verify no unexpected conflicts. Third, I use a phased rollout by namespace or resource type - start with non-critical namespaces, apply with --server-side --force-conflicts once to transfer ownership from client-side to server-side, and monitor for issues. The force flag is necessary during migration because client-side apply creates managedFields entries with operation "Update" that conflict with SSA's operation "Apply". Fourth, after successful migration, I clean up the kubectl.kubernetes.io/last-applied-configuration annotations which are no longer needed and can grow large. Finally, I update CI/CD pipelines to enforce --server-side in all kubectl commands and add admission webhooks that reject applies using deprecated client-side mode. I monitor apiserver_request_total metrics filtering for /apply vs /patch endpoints to track migration progress and ensure all teams have switched over.

## Q: What are the performance implications of managedFields growth?

**Answer:**

managedFields grows with the number of distinct fieldManagers that have ever touched an object and the number of fields they own. Each entry includes manager name, operation type, timestamp, apiVersion, and the fieldsV1 structure encoding owned fields. In large objects with many fields and frequent manager changes, managedFields can become several kilobytes, increasing etcd storage, API response payload size, and client memory. I've seen objects where managedFields was larger than the actual spec and status combined. To mitigate, I design systems with minimal fieldManager diversity - use one manager per automation tool rather than per-user or per-invocation. For example, all Flux reconciliations should use "flux-system" not "flux-run-12345". I also avoid unnecessary force applies which create new managedFields entries. For monitoring, I track etcd object size distribution and alert when objects exceed reasonable thresholds. In extreme cases, I use kubectl replace with the object stripped of managedFields to reset ownership, but this is risky because it removes conflict protection. The Kubernetes API server periodically garbage collects unused managedFields entries, but this only happens for managers that haven't touched the object in a long time.
