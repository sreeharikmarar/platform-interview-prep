# Talk Tracks: GitOps vs Controller Reconciliation

## Q: Explain GitOps reconciliation versus controller reconciliation in one minute.

**Answer:**

GitOps and controllers are two complementary reconciliation loops in Kubernetes platforms, not competing ones. GitOps reconciles Git into the API server—tools like ArgoCD continuously sync manifests from Git repos to ensure cluster state matches the declared configuration in Git. This is declarative configuration management. Controllers reconcile the API server into the external world—they watch resources, read desired state from spec fields, and materialize side effects like provisioning cloud resources, issuing certificates, or managing databases. GitOps is Git→cluster, controllers are cluster→world. The key to making them work together is clear ownership boundaries using Server-Side Apply. GitOps owns spec fields, controllers own status fields. When both need to modify spec, like HPA changing replicas, you exclude that field from Git and let the controller own it exclusively, or use ignoreDifferences in ArgoCD to prevent drift detection on that field.

**If they push deeper:**

The confusion often arises because both are "reconciliation" but they reconcile different things. GitOps ensures cluster state equals Git state, detecting drift when someone makes a manual kubectl change. Controllers ensure external state equals cluster state, detecting drift when someone makes a manual cloud console change. These operate on different planes. The failure mode is drift wars—if ArgoCD sets Deployment.spec.replicas=3 and HPA sets it to 5, they fight in an infinite loop. The solution is field-level ownership via Server-Side Apply's managedFields, which tracks which manager owns each field. You can inspect this with kubectl get -o yaml and see metadata.managedFields showing which controller last touched each field.

## Q: What is Server-Side Apply and how does it prevent conflicts?

**Answer:**

Server-Side Apply (SSA) is a Kubernetes feature where the API server tracks field-level ownership instead of whole-object ownership. Every apply operation declares a field manager name, and the API server records which manager last set each field in metadata.managedFields. When two managers try to set the same field to different values, SSA detects this as a conflict and fails the apply with an error, preventing silent overwrites.

For example, if ArgoCD sets Deployment.spec.replicas=3 and later HPA sets it to 5, the managedFields show HPA owns spec.replicas. If ArgoCD tries to apply again with replicas=3, it conflicts with HPA's ownership and fails unless you use --force-conflicts to steal ownership. This prevents drift wars where managers silently overwrite each other in an infinite loop.

SSA has three conflict resolution modes: shared ownership (both managers set the same value, both own it), conflict error (managers set different values, fail), and forced ownership (--force-conflicts steals ownership). The default is conflict error, which is safest. You use SSA by passing --server-side to kubectl apply or using SSA-aware clients like controller-runtime.

**If they push deeper:**

managedFields is verbose JSON that tracks every field and subfield. It includes the manager name, operation type (Apply vs Update), API version, timestamp, and a FieldsV1 tree showing which fields this manager owns. When debugging conflicts, inspect managedFields to see which manager last touched the conflicting field. You can also use kubectl apply --dry-run=server --server-side to preview what fields would conflict before applying. One subtlety: SSA only works if all managers use SSA. If one manager uses client-side apply (the old default) and another uses SSA, the client-side apply overwrites the whole object, erasing managedFields and causing silent conflicts. This is why you must migrate all tooling to SSA.

## Q: How do GitOps and controllers typically divide ownership?

**Answer:**

The standard pattern is GitOps owns spec, controllers own status. GitOps tools like ArgoCD declare the desired state of resources in spec fields, while controllers read spec and update status to reflect current reality. For example, ArgoCD applies a Deployment with spec.replicas=3, and the deployment controller updates status.availableReplicas=3 once pods are running. They don't conflict because they touch different fields.

Problems arise when controllers modify spec. HorizontalPodAutoscaler changes Deployment.spec.replicas based on CPU. If this field is in Git, ArgoCD detects drift and reverts it, then HPA changes it again—drift war. The solution is to remove spec.replicas from Git, letting HPA own it exclusively. You configure ArgoCD to ignoreDifferences on that field so it doesn't report drift.

Another pattern is splitting resources. Instead of both GitOps and controllers modifying the same Deployment, GitOps manages the Deployment without HPA, and a separate controller creates the HPA dynamically based on annotations. For example, the Deployment has annotation autoscaling.example.com/enabled: "true", and a controller watches for this annotation and creates an HPA. Now GitOps never touches HPA, the controller owns it.

**If they push deeper:**

A third pattern is annotation-driven coordination. GitOps sets annotations or labels, and controllers read them to decide behavior. For instance, cert-manager reads cert-manager.io/cluster-issuer from Ingress annotations and creates a Certificate. The Ingress itself is managed by GitOps, but the Certificate is controller-owned. This is cleaner than having GitOps directly manage Certificates because the controller can handle renewal, rotation, and edge cases. The general principle is: GitOps manages the declarative intent, controllers manage the operational machinery. Overlap should be minimal and explicit.

## Q: Walk me through a drift war scenario and how to fix it.

**Answer:**

Scenario: A Deployment in Git has spec.replicas: 3, and ArgoCD auto-sync is enabled. Someone deploys an HPA that scales the Deployment to 5 replicas based on CPU load. ArgoCD detects drift—cluster has replicas=5 but Git says 3—and auto-syncs, resetting to 3. HPA sees CPU load is still high and scales back to 5. ArgoCD syncs again to 3. This repeats forever, causing constant pod churn and instability.

Detection: ArgoCD shows the Deployment as constantly out-of-sync. Kubernetes events show rapid scale-up and scale-down. Checking metadata.managedFields reveals two managers fighting over spec.replicas: argocd-controller and horizontal-pod-autoscaler.

Fix: Remove spec.replicas from the Deployment manifest in Git, or add it to ArgoCD's ignoreDifferences:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
spec:
  ignoreDifferences:
  - group: apps
    kind: Deployment
    jsonPointers:
    - /spec/replicas
```

This tells ArgoCD to ignore replicas when detecting drift. HPA owns the field, ArgoCD doesn't touch it. Alternatively, remove the HPA or disable auto-sync and handle scaling manually.

**If they push deeper:**

There's a subtle issue with removing fields from Git: it doesn't tell kubectl to "unset" the field, it just stops managing it. If the field exists in the cluster, it persists. So if you remove spec.replicas from Git, the cluster object still has the last value Git set. To truly let HPA own it, you'd need to either never set it in Git (omit it entirely so it defaults), or set it to a safe initial value knowing HPA will override it. Also, ignoreDifferences is per-resource or per-field. You can ignore specific fields on specific resources, or use wildcards to ignore a field across all resources of a type. But overuse makes debugging hard—you lose visibility into what's actually in the cluster versus Git.

## Q: How do you handle deletion ordering between GitOps and controllers?

**Answer:**

Kubernetes uses finalizers to control deletion order. A finalizer is a string in metadata.finalizers that blocks deletion until a controller removes it. When an object is deleted, Kubernetes sets metadata.deletionTimestamp but doesn't remove the object from etcd until all finalizers are cleared. Controllers watch for deletionTimestamp, perform cleanup (delete cloud resources, revoke certificates, etc.), then remove their finalizer.

GitOps interacts with this as follows: when you remove a manifest from Git, ArgoCD deletes the object from the cluster. If the object has finalizers, deletion blocks. ArgoCD waits for the object to be fully deleted before marking the sync as complete. If the controller handling the finalizer is slow or broken, the sync hangs indefinitely.

To control deletion order, ArgoCD has sync waves. You annotate resources with argocd.argoproj.io/sync-wave: "N", and ArgoCD applies them in numeric order. For deletion, waves are processed in reverse—highest wave deletes first. So if Deployment has wave 0 and Namespace has wave -1, Namespace deletes last, ensuring Deployment is cleaned up first.

Another issue is circular dependencies. If resource A has a finalizer waiting for B to delete, and B has a finalizer waiting for A, both are stuck forever. You must design finalizer logic to avoid cycles.

**If they push deeper:**

There's a failure mode where the controller managing a finalizer is deleted before cleaning up resources. For example, you delete the cert-manager controller while Certificates exist with cert-manager.io/finalizer. The Certificates are stuck in Terminating forever because no controller will remove the finalizer. The manual fix is kubectl patch to remove finalizers, but this skips cleanup—cloud resources may leak. The robust solution is to drain finalizers before deleting controllers: scale down the controller, wait for it to process all finalizers, verify no resources have that finalizer, then delete the controller. ArgoCD doesn't handle this automatically, so you need pre-delete hooks or manual steps.

## Q: What is the difference between client-side apply and server-side apply?

**Answer:**

Client-side apply is the old default in kubectl. The client reads the current object from the API server, performs a three-way merge with the desired YAML and the last-applied-configuration annotation, then sends the merged result to the API server. The API server treats this as a normal update with no awareness of field ownership. This causes silent overwrites—if two managers apply different values for the same field, the last one wins, overwriting the previous value with no error.

Server-side apply (SSA) moves the merge logic to the API server and adds field-level ownership tracking. The client sends the desired YAML with a field manager name. The API server merges it into the current object, records which fields this manager owns in metadata.managedFields, and detects conflicts if another manager owns a field being modified. Conflicts fail by default, preventing silent overwrites.

SSA is strictly better than client-side apply for multi-manager scenarios. The downside is it changes the API contract—some tools and controllers don't support SSA yet. You enable SSA with kubectl apply --server-side, and in controller-runtime by using the SSA patch strategy. Once you switch to SSA, you should use it for all applies to avoid mixing modes.

**If they push deeper:**

One subtle issue is the last-applied-configuration annotation. Client-side apply stores the last applied YAML in kubectl.kubernetes.io/last-applied-configuration. This annotation can grow to hundreds of KB for large objects, hitting the 1 MB object size limit. SSA doesn't use this annotation—it relies on managedFields, which is more efficient. Migrating from client-side to server-side apply can be tricky if you have objects with large last-applied-configuration annotations. You should remove them during migration using kubectl annotate --overwrite. Also, managedFields can grow large too, especially if many managers touch the object. Kubernetes periodically compacts managedFields by merging entries from the same manager, but this isn't perfect.

## Q: How do you debug field manager conflicts in production?

**Answer:**

Start by inspecting metadata.managedFields on the conflicting resource. kubectl get <resource> -o yaml shows managedFields as a large JSON block. Look for multiple managers claiming ownership of the same field. The fieldsV1 tree shows exactly which fields each manager owns.

Example debugging flow:
1. User reports ArgoCD sync failing with "field conflict"
2. kubectl get deployment my-app -o yaml | grep -A 50 managedFields
3. See two managers: argocd-controller and my-custom-controller both own spec.template.metadata.labels
4. Check when each manager last touched it: time field shows timestamps
5. Identify which manager should own the field
6. Fix: remove the field from Git (if controller should own it), or update controller to not modify it (if GitOps should own it)

For temporary fixes, use kubectl apply --force-conflicts --server-side to steal ownership. This makes the current manager the owner, evicting the previous owner. But this is dangerous—you may break the other manager's logic. Only use it when you're certain the other manager should no longer own the field.

**If they push deeper:**

There's a useful tool called kubectl-slice that can extract managedFields into a readable format, showing which manager owns which field tree. Also, ArgoCD has a feature to display field manager conflicts in the UI—it shows which fields are causing drift and which managers are involved. You can configure ArgoCD to ignore specific managers when detecting drift, which is useful for known-safe controllers. For example, ignore kubernetes if built-in controllers are setting fields, or ignore kube-controller-manager for status updates. The challenge is finding the right balance—too many ignores and you lose drift detection, too few and you get false positives.

## Q: What are sync waves and sync hooks in ArgoCD?

**Answer:**

Sync waves control the order in which ArgoCD applies resources. You annotate resources with argocd.argoproj.io/sync-wave: "N", and ArgoCD applies them in ascending numeric order. Wave 0 is default. Lower waves apply first, so wave -1 applies before wave 0, and wave 1 applies after wave 0. This ensures dependencies are created before dependents.

Example: Namespace has wave -1, ConfigMap has wave 0, Deployment has wave 1. ArgoCD creates Namespace first, waits for it to be ready, then creates ConfigMap, waits, then creates Deployment. For deletion, waves are reversed—Deployment deletes first, then ConfigMap, then Namespace.

Sync hooks are resources that run during specific sync phases: PreSync, Sync, PostSync, SyncFail. You create a Job or Pod annotated with argocd.argoproj.io/hook: PreSync, and ArgoCD runs it before syncing other resources. This is useful for migrations, database schema updates, or pre-flight checks.

Example PreSync hook:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: db-migrate
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: HookSucceeded
spec:
  template:
    spec:
      containers:
      - name: migrate
        image: my-app:v2
        command: ["./migrate.sh"]
```

ArgoCD runs this Job before syncing the app, waits for it to succeed, then proceeds. If it fails, sync aborts.

**If they push deeper:**

Sync waves are processed sequentially—ArgoCD applies all resources in wave N, waits for them to be healthy, then moves to wave N+1. This can slow down large syncs. You can disable health checks for specific resources using argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true if you want to apply without waiting. Sync hooks are deleted by default after sync completes, but you can control this with hook-delete-policy: BeforeHookCreation, HookSucceeded, or HookFailed. Hooks are powerful but add complexity—debugging failed syncs with hooks is harder because you need to check hook logs separately.

## Q: How would you apply this in a platform engineering context?

**Answer:**

In platform engineering, you typically run GitOps for declarative infrastructure and controllers for dynamic operational tasks. At my last company, we used ArgoCD to manage all application Deployments, Services, and Ingresses from a Git monorepo. Each team had a folder, and ArgoCD ApplicationSets dynamically created apps per folder. This was the GitOps layer—teams declared desired state in YAML, ArgoCD synced it to clusters.

We also ran custom controllers for platform services. A CertificateController watched Ingresses with a tls annotation and automatically created cert-manager Certificates. A DNSController watched Services with type LoadBalancer and created DNS records in Route53. These controllers modified cluster state dynamically, outside of Git.

The key was ownership boundaries. ArgoCD owned Ingress and Service specs, controllers owned Certificate and DNSRecord resources. Controllers never modified Ingress or Service—they only read them and created separate resources. This avoided drift wars. We configured ArgoCD to ignore certain fields like Service.status.loadBalancer.ingress, which Kubernetes sets, so ArgoCD didn't report drift on cloud-assigned IPs.

For deletion, we used finalizers on Certificates to block Ingress deletion until certs were revoked, preventing dangling certificates. We used ArgoCD sync waves to delete Deployments before Namespaces, ensuring pods were cleaned up before namespace deletion, which can hang if resources are stuck.

**If they push deeper:**

One pattern we used was progressive delivery with ArgoCD and a custom controller. ArgoCD deployed Deployments with initial replicas=1. A ProgressiveRolloutController watched for a rollout.example.com/enabled annotation and gradually scaled replicas from 1→10→50→100 over an hour, monitoring error rates. If errors spiked, it rolled back. ArgoCD didn't know about this—it just saw spec.replicas changing from 1 to 100 and reported drift. We used ignoreDifferences on spec.replicas for these Deployments. The tradeoff was losing Git as the source of truth for replicas, but we accepted it because the controller provided value (safe rollouts). We logged all rollout decisions to an audit log so we had a record of what the controller did, even though it wasn't in Git.
