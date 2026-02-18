# Lab: Control Plane Scale — etcd, API Server, and Watch Scalability

This lab walks through the operational reality of Kubernetes control plane scaling using a local kind cluster. You will measure baseline API server latency, stress etcd with bulk writes, observe compaction and defrag cycles, inspect watch fan-out metrics, and apply API Priority and Fairness (APF) policies — the exact skills needed to reason about control plane bottlenecks in large production clusters.

## Prerequisites

- `kind` v0.20+ installed and in PATH
- `kubectl` 1.28+ configured
- `etcdctl` v3 installed (version must match the etcd embedded in kind — typically 3.5.x)
- `jq` for JSON parsing
- `curl` for hitting the API server metrics endpoint directly

Install etcdctl on macOS:
```bash
brew install etcd        # installs etcdctl as a companion binary
etcdctl version          # verify: API version should be 3.5.x
```

---

## Step 1: Start the kind cluster and verify etcd health

```bash
# Create a single-node kind cluster (control-plane node runs etcd inline)
kind create cluster --name cp-scale-lab --image kindest/node:v1.28.0

# Confirm the cluster is responding
kubectl cluster-info --context kind-cp-scale-lab

# Identify the etcd pod running inside the kind node
kubectl get pods -n kube-system -l component=etcd

# Copy the etcd client certificates out of the kind node for direct etcdctl access
docker cp cp-scale-lab-control-plane:/etc/kubernetes/pki/etcd/ca.crt   /tmp/etcd-ca.crt
docker cp cp-scale-lab-control-plane:/etc/kubernetes/pki/etcd/server.crt /tmp/etcd-server.crt
docker cp cp-scale-lab-control-plane:/etc/kubernetes/pki/etcd/server.key /tmp/etcd-server.key

# Verify etcd endpoint health using the certificates
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/tmp/etcd-ca.crt \
  --cert=/tmp/etcd-server.crt \
  --key=/tmp/etcd-server.key \
  endpoint health
```

**What's happening**: kind runs a full Kubernetes control plane inside a Docker container. The etcd process listens on port 2379 (client traffic) and 2380 (peer traffic) inside the container. By default kind maps port 2379 to localhost, but only if you configure `extraPortMappings` — instead, we access etcd by exec'ing through the Docker network. The PKI certificates are the same mTLS credentials that the API server itself uses; we copy them to `/tmp` for direct etcdctl access without modifying the cluster configuration.

**Observe**: The output should report `https://127.0.0.1:2379 is healthy: successfully committed proposal: took = Xms`. Any `unhealthy` status or connection refused means the kind container is not exposing port 2379 to the host — in that case use `docker exec` to run etcdctl inside the container instead.

**Verification**:
```bash
# Confirm etcd cluster membership
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/tmp/etcd-ca.crt \
  --cert=/tmp/etcd-server.crt \
  --key=/tmp/etcd-server.key \
  member list --write-out=table
```

Expected: one member with `isLeader=true` and status `started`.

---

## Step 2: Measure baseline API server latency

```bash
# Cold latency measurement — includes authentication, authorization, watch cache read
time kubectl get pods -A --context kind-cp-scale-lab

# Repeat to warm any in-process caches
time kubectl get pods -A --context kind-cp-scale-lab
time kubectl get pods -A --context kind-cp-scale-lab

# Measure a heavier list operation that forces a full etcd scan
time kubectl get events -A --context kind-cp-scale-lab
```

Now expose the API server's Prometheus metrics endpoint to examine actual histogram buckets:

```bash
# Port-forward the API server's metrics port (requires cluster-admin access, which kind provides)
kubectl port-forward -n kube-system svc/kube-apiserver 6443:6443 2>/dev/null &
# Note: the API server is not typically exposed as a Service; use the pod directly
APISERVER_POD=$(kubectl get pods -n kube-system -l component=kube-apiserver -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward -n kube-system pod/$APISERVER_POD 9443:6443 &
PFPID=$!
sleep 2

# Fetch the raw metrics (large output — the API server exposes ~400 metric families)
curl -sk --cert ~/.kube/cache/discovery/127.0.0.1_*/... https://127.0.0.1:9443/metrics 2>/dev/null | head -5

# A more reliable approach: query via kubectl proxy
kubectl proxy --port=8001 &
KPROXYPID=$!
sleep 1

# Request duration histogram — shows per-verb, per-resource latency buckets
curl -s http://localhost:8001/metrics | grep "^apiserver_request_duration_seconds_bucket" | grep 'verb="LIST"' | head -20

# Total request count broken down by resource, verb, and response code
curl -s http://localhost:8001/metrics | grep "^apiserver_request_total" | sort | head -30

# etcd request duration from the API server's perspective
curl -s http://localhost:8001/metrics | grep "^etcd_request_duration_seconds_bucket" | head -20
```

**What's happening**: The API server exposes a `/metrics` endpoint in Prometheus text format. `apiserver_request_duration_seconds` is a histogram with labels `verb`, `resource`, `subresource`, `scope`, `component`, and response `code`. The `_bucket` lines show the cumulative count of requests whose duration fell below each `le` threshold. In production, SLO violations are detected by comparing `_bucket{le="1"}` to `_count` — the fraction of requests taking over one second.

**Observe**: At this point with an idle cluster, nearly all requests should land in the `le="0.1"` or `le="0.25"` buckets. Record the `apiserver_request_duration_seconds_count{verb="LIST"}` value — you will compare it after the stress test.

**Verification**:
```bash
# Confirm metrics endpoint is reachable and returning data
curl -s http://localhost:8001/metrics | grep -c "^apiserver_"
# Expected: 200+ distinct metric lines
```

---

## Step 3: Apply stress-deploy.yaml — bulk namespace and ConfigMap creation

```bash
# Kill the proxy from step 2 before proceeding
kill $KPROXYPID 2>/dev/null; wait $KPROXYPID 2>/dev/null

# Apply the complete stress workload (RBAC + Job)
kubectl apply -f stress-deploy.yaml --context kind-cp-scale-lab

# Watch the job progress in real time
kubectl get jobs -n default -w &
WATCHPID=$!

# Also watch namespace creation as it happens
kubectl get namespaces -w 2>/dev/null | grep "^ns-stress" &
NSWATCHPID=$!
```

Measure etcd write duration while the Job is running:

```bash
# In a second terminal or after the Job completes, measure etcd write duration histogram
kubectl proxy --port=8001 &
KPROXYPID2=$!
sleep 1

# etcd write latency from the API server's perspective
curl -s http://localhost:8001/metrics \
  | grep "^etcd_request_duration_seconds_bucket" \
  | grep 'operation="create"' \
  | head -30

# Count of etcd operations since startup
curl -s http://localhost:8001/metrics \
  | grep "^etcd_request_duration_seconds_count"
```

Wait for the Job to complete:
```bash
kubectl wait --for=condition=complete job/stress-writer --timeout=300s -n default
# If the job is not in the default namespace, it may use the serviceaccount's namespace
kubectl get jobs -A | grep stress-writer
```

Stop the watchers:
```bash
kill $WATCHPID $NSWATCHPID $KPROXYPID2 2>/dev/null
```

**What's happening**: The stress Job runs `kubectl` inside a container using a dedicated ServiceAccount with ClusterRole permissions to create namespaces and ConfigMaps. Each `kubectl create namespace` triggers a full API server write path: authentication, authorization (RBAC check), mutating admission (DefaultStorageClass, NamespaceLifecycle, etc.), schema validation, etcd write via compare-and-swap, and watch event fan-out to all informers watching the namespace resource. Creating 50 namespaces with 5 ConfigMaps each generates 300 individual write transactions to etcd. This simulates the write amplification seen when operators create per-tenant infrastructure.

**Observe**: Watch the namespace count grow in the `-w` output. If you see any `Error from server (Timeout)` messages in the Job logs, the API server is queueing requests — that is the APF system at work, which you will configure in Step 7. After completion, `kubectl get ns | grep ns-stress | wc -l` should report 50.

**Verification**:
```bash
kubectl get ns | grep "ns-stress" | wc -l
# Expected: 50

kubectl get configmaps -n ns-stress-001
# Expected: 5 ConfigMaps named stress-cm-1 through stress-cm-5
```

---

## Step 4: Observe etcd DB size growth and compaction behavior

```bash
# Check current etcd database size and compaction state
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/tmp/etcd-ca.crt \
  --cert=/tmp/etcd-server.crt \
  --key=/tmp/etcd-server.key \
  endpoint status --write-out=table
```

The table output shows these critical columns:

| Column | Meaning |
|--------|---------|
| `DB SIZE` | Total size of the etcd data file on disk (includes historical revisions not yet compacted) |
| `DB SIZE IN USE` | Bytes currently in active use (post-compaction live data) |
| `RAFT TERM` | Leader election term; increments on each new leader election |
| `RAFT INDEX` | Total number of raft log entries applied |
| `LEADER` | Which member is current leader |

```bash
# Check the etcd revision — this is the global monotonically-increasing write counter
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/tmp/etcd-ca.crt \
  --cert=/tmp/etcd-server.crt \
  --key=/tmp/etcd-server.key \
  endpoint status --write-out=json | jq '.[0].Status.header.revision'

# Count how many distinct keys exist (namespaces, configmaps, pods, etc.)
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/tmp/etcd-ca.crt \
  --cert=/tmp/etcd-server.crt \
  --key=/tmp/etcd-server.key \
  get / --prefix --keys-only | wc -l

# List all namespace keys in etcd to see raw storage layout
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/tmp/etcd-ca.crt \
  --cert=/tmp/etcd-server.crt \
  --key=/tmp/etcd-server.key \
  get /registry/namespaces/ --prefix --keys-only | head -20

# Observe auto-compaction: check if the API server has triggered compaction
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/tmp/etcd-ca.crt \
  --cert=/tmp/etcd-server.crt \
  --key=/tmp/etcd-server.key \
  get /registry/namespaces/ns-stress-001 --print-value-only | strings | head -5
```

**What's happening**: etcd stores every version of every key — until compaction removes old revisions. The API server configures etcd with `--auto-compaction-mode=periodic` and `--auto-compaction-retention=5m` (default in kubeadm/kind clusters). This means every 5 minutes etcd discards all revisions older than 5 minutes, reclaiming space from the DB file. However, the file size as reported by the OS does not shrink after compaction — it only shrinks after a `defrag` (Step 8). The gap between `DB SIZE` and `DB SIZE IN USE` represents free pages that can be reclaimed by defrag.

The `/registry/` prefix is Kubernetes's convention for all resource storage in etcd. Resources are stored as protobuf-encoded blobs. The path structure is: `/registry/<group>/<resource-plural>/<namespace>/<name>` for namespaced resources, or `/registry/<group>/<resource-plural>/<name>` for cluster-scoped resources. Namespaces themselves live at `/registry/namespaces/<name>`.

**Observe**: After the stress Job, `DB SIZE` should be noticeably larger than a fresh cluster (typically 5-20 MB vs. 2-4 MB baseline). `DB SIZE IN USE` should be close to `DB SIZE` before compaction fires. After auto-compaction runs (wait 5-10 minutes or trigger it manually below), `DB SIZE IN USE` drops while `DB SIZE` stays the same — that free space is reclaimed in Step 8.

**Verification**:
```bash
# Trigger a manual compact to the current revision (simulates what auto-compact does)
CURRENT_REV=$(ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/tmp/etcd-ca.crt \
  --cert=/tmp/etcd-server.crt \
  --key=/tmp/etcd-server.key \
  endpoint status --write-out=json | jq '.[0].Status.header.revision')

ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/tmp/etcd-ca.crt \
  --cert=/tmp/etcd-server.crt \
  --key=/tmp/etcd-server.key \
  compact $CURRENT_REV

# Re-check status — DB SIZE IN USE should now be lower than DB SIZE
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/tmp/etcd-ca.crt \
  --cert=/tmp/etcd-server.crt \
  --key=/tmp/etcd-server.key \
  endpoint status --write-out=table
```

---

## Step 5: Observe watch fan-out via apiserver_registered_watchers

```bash
# Start a proxy to reach the API server metrics
kubectl proxy --port=8001 &
KPROXYPID3=$!
sleep 1

# Check the number of registered watchers per resource type
# This is how many open watch connections the API server is maintaining
curl -s http://localhost:8001/metrics \
  | grep "^apiserver_registered_watchers" \
  | sort -t'=' -k3 -rn \
  | head -20
```

Open additional watch streams to simulate the fan-out load:

```bash
# Open watches against several resource types in the background
kubectl get configmaps -A --watch > /dev/null &
W1=$!
kubectl get namespaces --watch > /dev/null &
W2=$!
kubectl get pods -A --watch > /dev/null &
W3=$!
kubectl get pods -A --watch > /dev/null &
W4=$!
sleep 3

# Re-check the registered watchers metric after opening new watches
curl -s http://localhost:8001/metrics \
  | grep "^apiserver_registered_watchers" \
  | sort -t'=' -k3 -rn \
  | head -20

# Also check watch cache capacity and current size
curl -s http://localhost:8001/metrics \
  | grep "^apiserver_watch_cache" \
  | head -20

# Check the number of inflight requests (watch streams count as inflight)
curl -s http://localhost:8001/metrics \
  | grep "^apiserver_current_inflight_requests"
```

Stop the simulated watchers:
```bash
kill $W1 $W2 $W3 $W4 2>/dev/null
kill $KPROXYPID3 2>/dev/null
```

**What's happening**: Every `kubectl get --watch`, every controller informer, and every operator's SharedInformerFactory registers a long-lived watch stream with the API server. The API server maintains an in-memory watch cache per resource type with a configurable size (default: `--watch-cache-sizes` per resource, typically 100-1000 events). When any object changes, the API server must fan out the event to every registered watcher. In a cluster with 50 controllers each watching Pods, a single Pod update generates 50 outbound event writes — this is the fan-out amplification that limits scale.

The `apiserver_registered_watchers` metric breaks this down by resource `group`, `version`, and `resource`. In production clusters with many operators, it is normal to see dozens of watchers per resource type. The actual bottleneck is CPU for serialization and network bandwidth for transmitting watch events, not the number of watchers per se.

**Observe**: After opening the background watch commands, `apiserver_registered_watchers{resource="configmaps"}` and `{resource="namespaces"}` should each increase by the number of new watchers you opened. The `apiserver_watch_cache_capacity` shows how many events the ring buffer can hold before the oldest are evicted, triggering a client relist.

**Verification**:
```bash
kubectl proxy --port=8001 &
TMPPRX=$!
sleep 1
curl -s http://localhost:8001/metrics | grep "apiserver_registered_watchers" | grep "pods"
kill $TMPPRX 2>/dev/null
# Expected: a nonzero count reflecting the kube-controller-manager and scheduler watching pods
```

---

## Step 6: Simulate a relist storm — understand 410 Gone and informer recovery

This step does not require running commands that break the cluster; instead it explains the mechanism precisely and shows how to observe the symptoms.

```bash
# First, understand the current watch cache window size
kubectl proxy --port=8001 &
KPROXYPID4=$!
sleep 1

# The watch cache stores a ring buffer of recent events.
# watch_cache_capacity is the ring buffer size per resource type.
curl -s http://localhost:8001/metrics \
  | grep "^apiserver_watch_cache_capacity"

# watch_cache_events_dispatched_total shows how many events have been sent to watchers
curl -s http://localhost:8001/metrics \
  | grep "^apiserver_watch_cache_events_dispatched_total" \
  | head -10

# The 410 Gone error is surfaced here — when a watcher's resourceVersion falls
# outside the watch cache window, the API server returns HTTP 410.
# client-go reflectors log this as: "watch of ... ended with: very short watch"
# and then trigger a full relist (List + new Watch from revision 0).

# Simulate a workload that generates rapid churn to age out old revisions
for i in $(seq 1 20); do
  kubectl create configmap churn-$i -n default --from-literal=key=value$i 2>/dev/null
done

# Delete them immediately to generate DELETED events (also ages the watch cache)
for i in $(seq 1 20); do
  kubectl delete configmap churn-$i -n default 2>/dev/null
done

# Check if any relist events are visible in API server audit log (if audit logging is on)
# In kind, audit logging is not enabled by default, but you can check the event count
curl -s http://localhost:8001/metrics \
  | grep "reflector_watch_duration_seconds" 2>/dev/null | head -5

# Count total LIST requests — each relist appears as a LIST verb
curl -s http://localhost:8001/metrics \
  | grep 'apiserver_request_total.*verb="LIST"'

kill $KPROXYPID4 2>/dev/null
```

**What's happening**: The watch cache is a ring buffer. When a new event arrives and the buffer is full, the oldest event is dropped. Any watcher that tries to resume from a `resourceVersion` pointing to a dropped event receives an HTTP `410 Gone` response. This is a deliberate design choice — the API server does not keep unlimited history. The client-go `Reflector` handles this by catching the 410, performing a full List with `resourceVersion=""` (latest state from etcd), then re-establishing a watch from the new resourceVersion. This List-then-Watch sequence is a "relist" or "relist storm" when many controllers trigger it simultaneously.

Relist storms occur in production when:
1. The API server restarts (all watch connections break simultaneously)
2. A network partition heals (informers reconnect en masse)
3. Very high object churn ages out watch cache entries faster than clients can keep up
4. A `--watch-cache-sizes` value is set too low for the churn rate of a high-traffic resource

The blast radius is significant: each relist triggers a full List of all objects of that type, which is an etcd range scan. If 30 controllers all relist Pods simultaneously after an API server restart, the API server receives 30 concurrent List requests each reading potentially thousands of Pod objects. This is the "thundering herd" problem at the Kubernetes level.

**Observe**: In a cluster with many controllers and operators, you can watch for relist in the controller manager logs:
```bash
kubectl logs -n kube-system -l component=kube-controller-manager --tail=50 \
  | grep -i "relist\|410\|watch.+ended\|reflector"
```

Look for lines like:
```
W ... reflector.go:535] watch of *v1.Pod ended with: very short watch (0s) ...
W ... reflector.go:561] failed to list *v1.Pod: the server has timed out...
I ... reflector.go:225] Starting reflector *v1.Pod...
```

The appearance of `Starting reflector` after a watch error always indicates a relist cycle.

**Verification**:
```bash
# Confirm the churn configmaps were cleaned up
kubectl get configmaps -n default | grep "churn-" | wc -l
# Expected: 0 (all deleted)
```

---

## Step 7: Apply API Priority and Fairness — create a custom FlowSchema

```bash
# First, inspect the existing APF configuration
kubectl get prioritylevelconfigurations
kubectl get flowschemas

# Show the default priority levels and their concurrency shares
kubectl get prioritylevelconfigurations -o custom-columns=\
'NAME:.metadata.name,TYPE:.spec.type,SHARES:.spec.limited.nominalConcurrencyShares'

# Show which flowschemas match which priority levels
kubectl get flowschemas -o custom-columns=\
'NAME:.metadata.name,PL:.spec.priorityLevelConfiguration.name,MATCHING-PREC:.spec.matchingPrecedence'
```

Apply the custom priority level and flow schema:

```bash
kubectl apply -f apiserver-priority-level.yaml --context kind-cp-scale-lab

# Verify the new PriorityLevelConfiguration was created
kubectl get prioritylevelconfigurations platform-controllers -o yaml

# Verify the new FlowSchema was created
kubectl get flowschemas platform-controllers -o yaml

# Check the full ordered list — lower matchingPrecedence number = higher priority
kubectl get flowschemas \
  --sort-by='.spec.matchingPrecedence' \
  -o custom-columns='NAME:.metadata.name,PREC:.spec.matchingPrecedence,PL:.spec.priorityLevelConfiguration.name'
```

Observe APF metrics:

```bash
kubectl proxy --port=8001 &
KPROXYPID5=$!
sleep 1

# Per-priority-level: current seat usage and queue depth
curl -s http://localhost:8001/metrics \
  | grep "apiserver_flowcontrol_current_executing_seats" \
  | grep "platform-controllers"

# Queue depth — how many requests are waiting (should be 0 at rest)
curl -s http://localhost:8001/metrics \
  | grep "apiserver_flowcontrol_current_inqueue_requests" \
  | head -10

# Dispatched requests per priority level — shows actual traffic routing through APF
curl -s http://localhost:8001/metrics \
  | grep "apiserver_flowcontrol_dispatched_requests_total" \
  | head -10

# Rejected requests — these appear when a priority level's queue overflows
curl -s http://localhost:8001/metrics \
  | grep "apiserver_flowcontrol_rejected_requests_total"

kill $KPROXYPID5 2>/dev/null
```

**What's happening**: API Priority and Fairness (APF) is Kubernetes's mechanism for preventing a single client from consuming all API server concurrency. Without APF, a runaway operator or CI pipeline doing `kubectl get --all-namespaces` in a loop can starve the scheduler and controller manager. APF works by assigning every request to a FlowSchema (based on user, group, namespace, or ServiceAccount identity) which maps to a PriorityLevelConfiguration that defines the concurrency share and queue behavior.

The `nominalConcurrencyShares` value is a relative weight. The sum of all active PriorityLevel shares determines the per-level concurrency seat count: `seats = (nominalConcurrencyShares / totalShares) * totalServerConcurrencyLimit`. With `totalServerConcurrencyLimit` defaulting to `max(min(3, activeRequestsInFlight), 1)` × number of CPU threads, a level with 40 shares out of 400 total shares gets 10% of API server concurrency.

**Observe**: After applying `apiserver-priority-level.yaml`, `kubectl get flowschemas` should list `platform-controllers` with `matchingPrecedence` of 900. Requests from ServiceAccounts in the `platform-system` namespace will now be classified into the `platform-controllers` PriorityLevel and consume from its quota rather than sharing the `global-default` pool. This means a misbehaving platform controller cannot starve kube-controller-manager (which uses the `system` priority level).

**Verification**:
```bash
kubectl get flowschemas platform-controllers
# Expected: NAME=platform-controllers, PRIORITYLEVEL=platform-controllers, MATCHINGPRECEDENCE=900

kubectl get prioritylevelconfigurations platform-controllers -o jsonpath='{.spec.limited.nominalConcurrencyShares}'
# Expected: 40
```

---

## Step 8: Run etcd defrag and measure DB size reduction

```bash
# Record DB size BEFORE defrag
echo "=== DB size BEFORE defrag ==="
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/tmp/etcd-ca.crt \
  --cert=/tmp/etcd-server.crt \
  --key=/tmp/etcd-server.key \
  endpoint status --write-out=table

# Run defrag — this reclaims pages freed by compaction
# WARNING: defrag briefly pauses etcd writes; never run on production without a maintenance window
echo "=== Running defrag ==="
time ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/tmp/etcd-ca.crt \
  --cert=/tmp/etcd-server.crt \
  --key=/tmp/etcd-server.key \
  defrag

# Record DB size AFTER defrag
echo "=== DB size AFTER defrag ==="
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/tmp/etcd-ca.crt \
  --cert=/tmp/etcd-server.crt \
  --key=/tmp/etcd-server.key \
  endpoint status --write-out=table
```

Compare the before and after values programmatically:

```bash
# Capture DB size as bytes before and after (re-run if you did not capture above)
DB_BEFORE=$(ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/tmp/etcd-ca.crt \
  --cert=/tmp/etcd-server.crt \
  --key=/tmp/etcd-server.key \
  endpoint status --write-out=json | jq '.[0].Status.dbSize')

# After defrag
DB_AFTER=$(ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/tmp/etcd-ca.crt \
  --cert=/tmp/etcd-server.crt \
  --key=/tmp/etcd-server.key \
  endpoint status --write-out=json | jq '.[0].Status.dbSize')

echo "DB size before: $DB_BEFORE bytes"
echo "DB size after:  $DB_AFTER bytes"
echo "Reclaimed:      $(( DB_BEFORE - DB_AFTER )) bytes"
```

Verify the API server is still healthy after defrag:

```bash
kubectl get nodes
kubectl get pods -n kube-system

# Confirm etcd is still healthy post-defrag
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/tmp/etcd-ca.crt \
  --cert=/tmp/etcd-server.crt \
  --key=/tmp/etcd-server.key \
  endpoint health
```

**What's happening**: etcd uses a memory-mapped B+ tree (bbolt). When compaction removes old revisions, the pages are marked as free internally but the OS-level file size does not decrease — the file has holes. Defrag rewrites the entire bolt database file sequentially, packing live data into a contiguous layout without the free holes. The result is a smaller DB file that fits more data per disk read. Defrag is an online operation in etcd 3.5+ but it does briefly pause writes on the defragged member. For a 3-node etcd cluster, the production procedure is to defrag one member at a time (followers first, leader last), never all simultaneously.

The etcd `--quota-backend-bytes` flag sets the maximum DB size. When etcd exceeds this quota (default: 8 GiB), it enters a read-only alarm state and the API server can no longer write new objects — the cluster is effectively frozen. Proactive compaction scheduling and periodic defrag are the operational controls to prevent this. Production clusters should alert at 60% of quota and defrag at scheduled maintenance windows.

**Observe**: The difference between `DB SIZE` and `DB SIZE IN USE` in the pre-defrag table shows the fragmentation. After defrag, `DB SIZE` should drop to approximately match `DB SIZE IN USE`. In a heavily churned cluster this reduction can be several gigabytes.

**Verification**:
```bash
# Ensure no etcd alarm is active (would block writes)
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/tmp/etcd-ca.crt \
  --cert=/tmp/etcd-server.crt \
  --key=/tmp/etcd-server.key \
  alarm list
# Expected: no output (no active alarms)

kubectl run verification-pod --image=busybox:1.36 --restart=Never -- sleep 5
kubectl get pod verification-pod
kubectl delete pod verification-pod
# Expected: pod creates and deletes successfully, confirming writes are working post-defrag
```

---

## Cleanup

```bash
# Delete the stress namespaces (this will take ~30-60 seconds)
kubectl get ns -o name | grep "ns-stress" | xargs kubectl delete

# Delete the stress RBAC and Job
kubectl delete -f stress-deploy.yaml --ignore-not-found

# Delete the APF resources
kubectl delete -f apiserver-priority-level.yaml --ignore-not-found

# Kill any background kubectl proxy processes
pkill -f "kubectl proxy" 2>/dev/null

# Delete the kind cluster entirely
kind delete cluster --name cp-scale-lab

# Clean up temporary etcd certificates
rm -f /tmp/etcd-ca.crt /tmp/etcd-server.crt /tmp/etcd-server.key
```

---

## Key Takeaways

1. **etcd DB SIZE vs DB SIZE IN USE are different metrics**: `DB SIZE` is the OS file size (includes free pages); `DB SIZE IN USE` is actual live data. The gap represents fragmentation reclaimed by defrag, not by compaction. Alerting on `DB SIZE` alone gives a pessimistic view — alert on both, and track `etcd_mvcc_db_total_size_in_bytes` vs `etcd_mvcc_db_total_size_in_use_in_bytes` in Prometheus.

2. **Watch fan-out is multiplicative**: with N watchers on a resource, every write to that resource generates N serialization + N network send operations. In a cluster with 50 controllers watching Pods and 10,000 Pod updates per minute, the API server performs 500,000 watch event writes per minute. This is the primary argument for using caching layers (SharedInformerFactory), coalescing status updates, and avoiding high-churn synthetic resources.

3. **410 Gone triggers relist, not an error**: when a client receives `410 Gone` on a watch, client-go's reflector performs a full List to re-sync its cache. This is expected and recoverable. The problem is when many clients relist simultaneously (relist storm), generating a burst of expensive range scans on etcd. The mitigation is staggered controller startup, exponential backoff in reflectors (client-go implements this by default), and appropriate watch cache sizing.

4. **API Priority and Fairness protects system components from user workloads**: the default FlowSchemas guarantee that `system:masters`, `kube-system` ServiceAccounts, and health probes are never starved by application traffic. Custom FlowSchemas let you give platform controllers their own concurrency budget, isolated from tenant workloads and CI pipelines. The `matchingPrecedence` field determines which FlowSchema wins when multiple schemas match a request — lower number wins.

5. **Defrag is a maintenance operation, not a monitoring metric**: you cannot tell from Prometheus alone whether defrag is needed — you must look at the ratio of `etcd_mvcc_db_total_size_in_bytes` to `etcd_mvcc_db_total_size_in_use_in_bytes`. If the ratio exceeds 1.5x, defrag has meaningful benefit. Schedule defrag in maintenance windows, defrag one member at a time in a multi-node cluster, and always verify endpoint health immediately after.

6. **etcd revision is a global clock**: every write increments the cluster-wide revision counter, regardless of which key was written. The API server uses this revision as the `resourceVersion` on Kubernetes objects. When you see `resourceVersion: "12345"` on a Pod, that number means the 12,345th write to the entire etcd cluster — not the 12,345th write to that Pod. This is why `resourceVersion` values are not sequential within a single object's history.
