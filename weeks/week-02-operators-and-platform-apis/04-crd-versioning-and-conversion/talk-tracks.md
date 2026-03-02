# Talk Tracks: CRD Versioning & Conversion Webhooks

## Q: Explain CRD versioning in one minute.

**Answer:**

CRD versioning allows your custom APIs to evolve over time while maintaining backwards compatibility, just like Kubernetes core APIs evolved from Deployment v1beta1 to v1. You define multiple versions in the CRD spec, but exactly one is the storage version—the version persisted to etcd. All other versions are served versions that clients can use. When a client reads or writes using a version different from storage, the API server converts on the fly. For simple structural changes, conversion is automatic. For complex changes like restructuring fields, you must deploy a conversion webhook that transforms objects between versions. The critical requirement is round-trip fidelity—converting v1→v2→v1 must yield the original object, or you'll lose data. Use annotations to preserve data that doesn't fit in the target schema.

**If they push deeper:**

When you change the storage version, existing objects in etcd remain in the old version until they're rewritten. This creates a mixed-version state where some objects are stored in v1alpha1 and others in v1beta1. The storage version migrator controller can rewrite all objects to the new storage version in a controlled fashion. Without this, you rely on lazy migration—objects are migrated when they're next updated. This can leave stale objects in the old version indefinitely if they're never modified. Also, the served flag controls whether a version can be used by clients. Deprecating a version means setting served: false, which immediately blocks new requests in that version but doesn't affect stored objects.

## Q: What is the difference between storage version and served versions?

**Answer:**

The storage version is the single version that's persisted to etcd. It's marked with storage: true in the CRD's versions array. Only one version can be the storage version at a time. All objects are stored in this version, regardless of which version the client used to create them.

Served versions are versions that clients can read and write, marked with served: true. A CRD can have multiple served versions. When a client creates an object using v1alpha1 and the storage version is v1beta1, the API server validates the v1alpha1 request, converts it to v1beta1, stores v1beta1 in etcd, then converts it back to v1alpha1 for the response. All of this happens transparently.

You can serve multiple versions simultaneously for backwards compatibility. Old clients continue using v1alpha1, new clients use v1beta1, and the API server handles conversion. Eventually, you deprecate the old version by setting served: false, which blocks new requests. But you can't remove the version definition entirely until all stored objects are migrated to a newer version, because the API server needs the schema to deserialize etcd data.

**If they push deeper:**

There's a subtle ordering requirement when changing storage versions. You can't directly change storage: true from v1alpha1 to v1beta1 in a single CRD update if conversion isn't set up, because the API server won't know how to convert existing objects. The safe sequence is: 1) Add v1beta1 as served: true, storage: false, 2) Deploy conversion webhook, 3) Update CRD to set conversion: Webhook, 4) Migrate existing objects to v1beta1, 5) Change storage: true to v1beta1 and storage: false on v1alpha1, 6) Optionally deprecate v1alpha1 by setting served: false. Skipping steps causes API server errors or data loss.

## Q: When do you need a conversion webhook versus automatic conversion?

**Answer:**

Kubernetes CRDs have only two conversion strategies: `None` and `Webhook`. The `None` strategy changes only the `apiVersion` field and prunes unknown fields — it does NOT perform automatic field mapping or renaming. If v1alpha1 has field `foo` and v1beta1 renames it to `bar`, the `None` strategy will drop `foo` when converting to v1beta1, resulting in data loss. Even simple field renaming requires a webhook.

You need a conversion webhook for any schema change beyond identical schemas with different version strings. Examples: field renaming (foo → bar), restructuring (single field → array), semantic transformation (string "5m" → integer 300), or any case where fields differ between versions. In practice, if your versions have any schema differences, you need a webhook.

The key question is: are the schemas identical across versions? If yes, `None` works. If no — even for simple field renames — you need a webhook.

**If they push deeper:**

The `x-kubernetes-preserve-unknown-fields` OpenAPI annotation is a schema validation feature, not a conversion feature. Setting it to `true` prevents the API server from pruning unknown fields during validation, which can help with additive schema changes (adding optional fields) when using `conversion.strategy: None`. However, it does NOT enable automatic field mapping or renaming between versions. Note that if `spec.preserveUnknownFields` is `true` at the CRD level, `conversion.strategy` MUST be `None` — you cannot use webhook conversion. For production CRDs, prefer explicit schemas and webhooks over preserve-unknown-fields, as you lose validation on unrecognized fields.

## Q: What is round-trip fidelity and why does it matter?

**Answer:**

Round-trip fidelity means converting an object from version A to version B and back to version A produces the exact original object. This is critical because the API server may convert objects multiple times during a single request. For example, if a client reads a resource in v1alpha1 but the storage version is v1beta1, the API server reads from etcd in v1beta1, converts to v1alpha1, and returns it. If the client updates that object, the API server converts v1alpha1 back to v1beta1 and writes to etcd. If conversion isn't round-trip safe, data is lost during this cycle.

Example: a Gateway object in v1beta1 has 3 listeners. When converted to v1alpha1, which only supports a single host, the conversion takes the first listener and discards the rest. Converting back to v1beta1 only has 1 listener—2 are lost. A controller reading in v1alpha1 and writing status doesn't know about the other listeners, so they're silently deleted.

To preserve round-trip fidelity, use annotations to store data that doesn't fit in the target version. When converting v1beta1→v1alpha1, store the extra listeners in an annotation like gateway.example.com/extra-listeners. When converting v1alpha1→v1beta1, restore them from the annotation. This ensures no data is lost, even when moving between incompatible schemas.

**If they push deeper:**

The Kubernetes API machinery actually enforces round-trip testing for core resources. Every API type has round-trip tests that fuzz conversion by generating random objects, converting them through all versions, and asserting the final result matches the original. You should do the same for CRDs. Property-based testing is ideal—use a tool like github.com/leanovate/gopter to generate thousands of random test cases and verify round-trip fidelity. Catching edge cases in tests prevents silent data loss in production. Also, be careful with defaulting—if your webhook applies defaults during conversion, round-tripping may spuriously add fields that weren't in the original. Idempotent defaulting is key.

## Q: Walk me through the conversion webhook request/response flow.

**Answer:**

When the API server needs to convert an object, it sends an HTTPS POST to your webhook with a ConversionReview object. The request contains the UID (for correlation), the desiredAPIVersion (target version), and a list of objects in the current version that need conversion. The webhook processes each object, converts it to the desired version, and returns a ConversionReview response with the converted objects.

The webhook must be implemented as an HTTPS server, typically running in-cluster as a Deployment with a Service. The CRD's conversion.webhook.clientConfig points to this Service. The API server validates the webhook's TLS certificate, so you must configure cert-manager or another CA to issue certificates. The certificate's CN or SAN must match the Service DNS name, like gateway-conversion-webhook.gateway-system.svc.

The webhook must handle conversion in both directions. If you have v1alpha1 and v1beta1, the webhook receives requests to convert v1alpha1→v1beta1 when a client creates in v1alpha1, and v1beta1→v1alpha1 when a client reads in v1alpha1 but the object is stored in v1beta1. Implement both directions in the same webhook server, typically as a switch statement on desiredAPIVersion.

The webhook can process multiple objects in a single request. The API server batches objects for efficiency. Your webhook should iterate through the input objects, convert each one, and return them in the same order.

**If they push deeper:**

The webhook timeout is 10 seconds by default. If conversion takes longer, the API request fails. Keep webhook logic fast—no external API calls, database queries, or expensive computations. If you must do complex validation, do it in a separate validating webhook, not in the conversion webhook. The conversion webhook should only transform data, not validate it. Also, the webhook must be idempotent. The API server may retry the same request multiple times on transient failures, so converting the same object twice must yield the same result. This means you can't use side effects like incrementing counters or calling external APIs during conversion.

## Q: What happens if the conversion webhook is down?

**Answer:**

If the webhook is unreachable, all reads and writes to the CRD fail with an error like "conversion webhook failed: connection refused." This is catastrophic because even reading existing objects requires conversion. If your storage version is v1beta1 and a client tries to list objects in v1alpha1, the API server must convert each object from v1beta1 to v1alpha1 via the webhook. If the webhook is down, the list request fails.

Mitigation strategies: run the webhook with multiple replicas and a PodDisruptionBudget to ensure availability during node maintenance. Use a Service with multiple endpoints so requests are load-balanced. Monitor webhook latency and error rate with metrics. Set up alerts for webhook downtime. Test failure scenarios—deliberately take down the webhook in a staging environment and verify you can roll back.

The rollback plan is to update the CRD's conversion strategy from Webhook back to None, but this only works if all objects are in the same version. If you have a mixed-version state, you're stuck—you must restore the webhook to regain API access. This is why testing and HA are critical.

**If they push deeper:**

There's an interesting failure mode during cluster upgrades. If the API server restarts and your webhook isn't ready yet, the API server buffers requests and retries. But if the webhook takes too long to become available, the API server times out and fails requests. To handle this, ensure your webhook starts quickly and has a liveness probe. Also, consider using a ValidatingWebhookConfiguration failurePolicy: Ignore for non-critical webhooks, but conversion webhooks don't have this option—they're always required. Another edge case: if the webhook's TLS certificate expires, the API server rejects connections even if the webhook is running. Monitor certificate expiration and rotate before expiry.

## Q: How do you plan a migration from v1alpha1 to v1beta1 with breaking changes?

**Answer:**

A safe migration plan has multiple stages to avoid breaking existing clients and controllers. Here's the sequence:

**Phase 1 - Add new version:** Deploy v1beta1 as a served version alongside v1alpha1. Keep v1alpha1 as the storage version initially. Deploy the conversion webhook so the API server can convert between versions. At this point, both versions work, but everything is still stored in v1alpha1.

**Phase 2 - Migrate clients:** Update controllers and clients to use v1beta1. Test thoroughly in staging. During this phase, both versions are served, so old clients continue working. Monitor usage of v1alpha1 (API server metrics show request counts per version). Once v1alpha1 usage drops to zero, proceed.

**Phase 3 - Change storage version:** Update the CRD to set v1beta1 as storage: true and v1alpha1 as storage: false. New objects are now stored in v1beta1, but old objects remain in v1alpha1 in etcd. Use the storage version migrator controller or a migration script to rewrite all objects to v1beta1. Verify all objects are migrated by checking etcd directly or using kubectl get with --output-watch-event.

**Phase 4 - Deprecate old version:** Set v1alpha1 to served: false, which blocks new requests in that version. Existing stored objects are unaffected. Announce the deprecation to users with a grace period (e.g., 3 months). After the grace period, you can remove v1alpha1 from the CRD entirely.

**Rollback plan:** At any stage, you can roll back by switching storage versions back or re-enabling served: true. The key is to never remove the old version's schema until all objects are migrated, because the API server needs it to deserialize etcd data.

**If they push deeper:**

One subtle issue is controllers that cache the old version locally. Even if you migrate all objects in etcd to v1beta1, a controller's informer may have cached v1alpha1 objects from before the migration. When the controller reconciles, it might write back the old version, reverting the migration. To prevent this, drain controller caches by restarting controllers after storage version migration. Or use a blue-green deployment: deploy new controllers using v1beta1 before migrating storage, drain traffic from old controllers, then migrate storage. This ensures no controller writes stale cached data.

## Q: How do you test conversion webhooks?

**Answer:**

Testing conversion webhooks requires verifying correctness, performance, and failure handling. Start with unit tests for each conversion function. Test converting individual objects in both directions and assert equality. Use table-driven tests with diverse inputs: minimal objects, fully populated objects, objects with edge cases like empty arrays or null fields.

Round-trip testing is critical. For every object in version A, convert to B then back to A and assert deep equality. Use property-based testing to generate random objects and fuzz the conversion. This catches edge cases that manual tests miss.

Integration tests should deploy the webhook in a real Kubernetes cluster and exercise it via the API server. Create a CRD with multiple versions and conversion: Webhook, deploy the webhook, then create objects in v1alpha1 and read them in v1beta1. Verify the conversion happened correctly. Test failure scenarios: shut down the webhook and verify API requests fail gracefully with appropriate errors.

Performance testing ensures the webhook doesn't become a bottleneck. Measure latency for converting single objects and batches. The webhook must respond within the 10-second timeout. Load test by creating thousands of objects rapidly and monitoring webhook CPU/memory usage.

**If they push deeper:**

A sophisticated test strategy includes schema validation. The conversion webhook may produce output that passes round-trip tests but violates the target version's OpenAPI schema. For example, converting v1alpha1→v1beta1 might produce a v1beta1 object with a required field missing. The API server will reject this during validation, but your conversion unit tests might not catch it because they don't validate against the schema. Solution: in tests, use the OpenAPI schema validator to validate converted objects. Extract the schema from the CRD YAML and use a library like github.com/go-openapi/validate to assert the converted object matches the schema. This catches schema violations early.

## Q: How would you apply this in a platform engineering context?

**Answer:**

In platform engineering, CRD versioning is essential for evolving internal platform APIs without breaking teams. At my last company, we built a custom VirtualCluster CRD for multi-tenancy. The initial v1alpha1 had a simple spec with just a cluster size field. As we added features, we needed to restructure—adding node pools, scaling policies, and autoscaling config. These were breaking changes.

We evolved to v1beta1 using a conversion webhook. The webhook converted the old single-size field into a node pool with default settings, preserving round-trip fidelity by storing the original size in an annotation. This let us ship new features to v1beta1 users while keeping old automation scripts working with v1alpha1. We gave teams a 6-month migration window, during which both versions were served.

We used the storage version migrator to rewrite all VirtualCluster objects to v1beta1 in a maintenance window. This avoided lazy migration, which would leave stale objects in v1alpha1 indefinitely. We ran the migrator in dry-run mode first, verifying it would succeed, then ran it live while monitoring. After migration, we deprecated v1alpha1 by setting served: false and notified teams via changelog and Slack.

For webhook HA, we ran 3 replicas with a PodDisruptionBudget and monitored latency. We also set up alerts for webhook errors and tested failure scenarios in staging every quarter.

**If they push deeper:**

One pattern we used was version-specific defaulting. The v1beta1 API had more required fields than v1alpha1, so we couldn't simply convert without applying defaults. We implemented defaulting in the conversion webhook: when converting v1alpha1→v1beta1, missing fields were filled with sensible defaults based on cluster size. This was safe because the defaults were stored in v1beta1, and round-tripping back to v1alpha1 preserved the original minimal spec in an annotation. However, this created confusion when users viewed objects in v1beta1 and saw fields they didn't set. We documented this behavior and added printer columns to show which fields were defaulted.