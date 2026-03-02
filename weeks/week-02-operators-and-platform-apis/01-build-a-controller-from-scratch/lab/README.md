# Lab: Build a ConfigMapReplicator Controller

## Overview

In this lab, you'll build a complete Kubernetes controller from scratch using controller-runtime. The controller watches a custom resource called `ConfigMapReplicator` that replicates ConfigMaps across namespaces. This simple but practical example demonstrates all core controller patterns: spec/status contracts, finalizers, idempotent reconciliation, status conditions, and observedGeneration tracking.

## Learning Objectives

By completing this lab, you will:

- Implement a complete Reconcile loop with all production patterns
- Design and implement clear spec/status contracts
- Use finalizers to ensure safe deletion
- Update status conditions correctly
- Handle idempotency and controller restarts
- Test your controller with real Kubernetes resources

## Prerequisites

- Go 1.22+ installed
- kind or other Kubernetes cluster (1.25+)
- kubectl installed and configured
- kubebuilder installed (optional, but helpful)

## Architecture

The `ConfigMapReplicator` CRD allows users to specify a source ConfigMap and a list of target namespaces. The controller watches ConfigMapReplicator resources and ensures the source ConfigMap is replicated to all target namespaces.

```yaml
apiVersion: platform.example.com/v1alpha1
kind: ConfigMapReplicator
metadata:
  name: replicate-app-config
  namespace: default
spec:
  sourceConfigMap:
    name: app-config
    namespace: default
  targetNamespaces:
  - dev
  - staging
  - prod
status:
  observedGeneration: 1
  conditions:
  - type: Ready
    status: "True"
    lastTransitionTime: "2024-01-15T10:30:00Z"
    reason: ReplicationSucceeded
    message: "ConfigMap replicated to 3 namespaces"
  replicatedTo:
  - namespace: dev
    lastSyncTime: "2024-01-15T10:30:00Z"
  - namespace: staging
    lastSyncTime: "2024-01-15T10:30:00Z"
  - namespace: prod
    lastSyncTime: "2024-01-15T10:30:00Z"
```

## Part 1: Setup Project Structure

### Step 1: Create Project Directory

```bash
mkdir -p configmap-replicator
cd configmap-replicator

# Initialize Go module — replace with your own module path
go mod init configmap-replicator
```

### Step 2: Install Dependencies

```bash
go get sigs.k8s.io/controller-runtime@v0.17.0
go get k8s.io/api@v0.29.0
go get k8s.io/apimachinery@v0.29.0
go get k8s.io/client-go@v0.29.0
```

### Step 3: Create Directory Structure

```bash
mkdir -p api/v1alpha1
mkdir -p controllers
mkdir -p config/crd
mkdir -p config/samples
```

## Part 2: Define the API

Create the CRD types in `api/v1alpha1/configmapreplicator_types.go`:

```go
package v1alpha1

import (
    metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// ConfigMapReplicatorSpec defines the desired state of ConfigMapReplicator
type ConfigMapReplicatorSpec struct {
    // SourceConfigMap specifies the ConfigMap to replicate
    SourceConfigMap SourceConfigMap `json:"sourceConfigMap"`

    // TargetNamespaces is the list of namespaces to replicate the ConfigMap to
    // +kubebuilder:validation:MinItems=1
    TargetNamespaces []string `json:"targetNamespaces"`
}

// SourceConfigMap identifies the ConfigMap to replicate
type SourceConfigMap struct {
    // Name of the ConfigMap
    Name string `json:"name"`

    // Namespace of the ConfigMap
    Namespace string `json:"namespace"`
}

// ReplicationStatus tracks replication to a single namespace
type ReplicationStatus struct {
    // Namespace where ConfigMap was replicated
    Namespace string `json:"namespace"`

    // LastSyncTime is the last time the ConfigMap was synced
    LastSyncTime metav1.Time `json:"lastSyncTime"`
}

// ConfigMapReplicatorStatus defines the observed state of ConfigMapReplicator
type ConfigMapReplicatorStatus struct {
    // ObservedGeneration reflects the generation of the most recently observed ConfigMapReplicator
    ObservedGeneration int64 `json:"observedGeneration,omitempty"`

    // Conditions represent the latest available observations of the ConfigMapReplicator's state
    Conditions []metav1.Condition `json:"conditions,omitempty"`

    // ReplicatedTo tracks which namespaces the ConfigMap has been replicated to
    ReplicatedTo []ReplicationStatus `json:"replicatedTo,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:scope=Namespaced
// +kubebuilder:printcolumn:name="Ready",type="string",JSONPath=".status.conditions[?(@.type=='Ready')].status"
// +kubebuilder:printcolumn:name="Age",type="date",JSONPath=".metadata.creationTimestamp"

// ConfigMapReplicator is the Schema for the configmapreplicators API
type ConfigMapReplicator struct {
    metav1.TypeMeta   `json:",inline"`
    metav1.ObjectMeta `json:"metadata,omitempty"`

    Spec   ConfigMapReplicatorSpec   `json:"spec,omitempty"`
    Status ConfigMapReplicatorStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// ConfigMapReplicatorList contains a list of ConfigMapReplicator
type ConfigMapReplicatorList struct {
    metav1.TypeMeta `json:",inline"`
    metav1.ListMeta `json:"metadata,omitempty"`
    Items           []ConfigMapReplicator `json:"items"`
}

func init() {
    SchemeBuilder.Register(&ConfigMapReplicator{}, &ConfigMapReplicatorList{})
}
```

Create the scheme registration in `api/v1alpha1/groupversion_info.go`:

```go
// Package v1alpha1 contains API types for the platform.example.com group.
//
// +kubebuilder:object:generate=true
// +groupName=platform.example.com
package v1alpha1

import (
    "k8s.io/apimachinery/pkg/runtime/schema"
    "sigs.k8s.io/controller-runtime/pkg/scheme"
)

var (
    GroupVersion  = schema.GroupVersion{Group: "platform.example.com", Version: "v1alpha1"}
    SchemeBuilder = &scheme.Builder{GroupVersion: GroupVersion}
    AddToScheme   = SchemeBuilder.AddToScheme
)
```

The `+groupName` marker is required — `controller-gen` uses it to determine the API group when generating the CRD. Without it, the generated CRD will have an empty group and fail validation.

## Part 3: Implement the Controller

Create the controller in `controllers/configmapreplicator_controller.go`:

```go
package controllers

import (
    "context"
    "fmt"
    "strings"
    "time"

    corev1 "k8s.io/api/core/v1"
    apierrors "k8s.io/apimachinery/pkg/api/errors"
    "k8s.io/apimachinery/pkg/api/meta"
    metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
    "k8s.io/apimachinery/pkg/runtime"
    ctrl "sigs.k8s.io/controller-runtime"
    "sigs.k8s.io/controller-runtime/pkg/client"
    "sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
    "sigs.k8s.io/controller-runtime/pkg/log"

    platformv1alpha1 "configmap-replicator/api/v1alpha1"
)

const configMapReplicatorFinalizer = "platform.example.com/finalizer"

// ConfigMapReplicatorReconciler reconciles ConfigMapReplicator objects by replicating
// a source ConfigMap to a set of target namespaces.
type ConfigMapReplicatorReconciler struct {
    client.Client
    Scheme *runtime.Scheme
}

// Reconcile ensures the source ConfigMap is replicated to all target namespaces
// declared in the ConfigMapReplicator spec.
func (r *ConfigMapReplicatorReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    log := log.FromContext(ctx)

    // Fetch the ConfigMapReplicator
    replicator := &platformv1alpha1.ConfigMapReplicator{}
    if err := r.Get(ctx, req.NamespacedName, replicator); err != nil {
        return ctrl.Result{}, client.IgnoreNotFound(err)
    }

    // --- Pattern 1: Finalizer Handling ---
    if !replicator.DeletionTimestamp.IsZero() {
        if controllerutil.ContainsFinalizer(replicator, configMapReplicatorFinalizer) {
            if err := r.deleteReplicatedConfigMaps(ctx, replicator); err != nil {
                return ctrl.Result{}, fmt.Errorf("delete replicated configmaps: %w", err)
            }
            controllerutil.RemoveFinalizer(replicator, configMapReplicatorFinalizer)
            if err := r.Update(ctx, replicator); err != nil {
                return ctrl.Result{}, fmt.Errorf("remove finalizer: %w", err)
            }
        }
        return ctrl.Result{}, nil
    }

    // Add finalizer if missing
    if !controllerutil.ContainsFinalizer(replicator, configMapReplicatorFinalizer) {
        controllerutil.AddFinalizer(replicator, configMapReplicatorFinalizer)
        if err := r.Update(ctx, replicator); err != nil {
            return ctrl.Result{}, fmt.Errorf("add finalizer: %w", err)
        }
    }

    // --- Pattern 2: Idempotent Reconciliation ---
    sourceConfigMap := &corev1.ConfigMap{}
    err := r.Get(ctx, client.ObjectKey{
        Name:      replicator.Spec.SourceConfigMap.Name,
        Namespace: replicator.Spec.SourceConfigMap.Namespace,
    }, sourceConfigMap)
    if err != nil {
        if apierrors.IsNotFound(err) {
            meta.SetStatusCondition(&replicator.Status.Conditions, metav1.Condition{
                Type:    "Ready",
                Status:  metav1.ConditionFalse,
                Reason:  "SourceNotFound",
                Message: fmt.Sprintf("Source ConfigMap %s/%s not found", replicator.Spec.SourceConfigMap.Namespace, replicator.Spec.SourceConfigMap.Name),
            })
            if err := r.Status().Update(ctx, replicator); err != nil {
                log.Error(err, "unable to update status")
            }
            return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
        }
        return ctrl.Result{}, err
    }

    replicatedTo := make([]platformv1alpha1.ReplicationStatus, 0, len(replicator.Spec.TargetNamespaces))
    var failedNamespaces []string
    for _, targetNS := range replicator.Spec.TargetNamespaces {
        targetConfigMap := &corev1.ConfigMap{
            ObjectMeta: metav1.ObjectMeta{
                Name:      sourceConfigMap.Name,
                Namespace: targetNS,
            },
        }

        _, err := controllerutil.CreateOrUpdate(ctx, r.Client, targetConfigMap, func() error {
            targetConfigMap.Data = sourceConfigMap.Data
            targetConfigMap.BinaryData = sourceConfigMap.BinaryData
            if targetConfigMap.Labels == nil {
                targetConfigMap.Labels = make(map[string]string)
            }
            targetConfigMap.Labels["platform.example.com/replicated-from"] =
                fmt.Sprintf("%s.%s", sourceConfigMap.Namespace, sourceConfigMap.Name)
            return nil
        })
        if err != nil {
            log.Error(err, "failed to replicate", "namespace", targetNS)
            failedNamespaces = append(failedNamespaces, targetNS)
            continue
        }
        replicatedTo = append(replicatedTo, platformv1alpha1.ReplicationStatus{
            Namespace:    targetNS,
            LastSyncTime: metav1.Now(),
        })
    }

    // --- Pattern 3: Status Conditions ---
    replicator.Status.ReplicatedTo = replicatedTo
    if len(failedNamespaces) > 0 {
        meta.SetStatusCondition(&replicator.Status.Conditions, metav1.Condition{
            Type:    "Ready",
            Status:  metav1.ConditionFalse,
            Reason:  "PartialFailure",
            Message: fmt.Sprintf("Failed to replicate to: %s", strings.Join(failedNamespaces, ", ")),
        })
    } else {
        meta.SetStatusCondition(&replicator.Status.Conditions, metav1.Condition{
            Type:    "Ready",
            Status:  metav1.ConditionTrue,
            Reason:  "ReplicationSucceeded",
            Message: fmt.Sprintf("ConfigMap replicated to %d namespaces", len(replicatedTo)),
        })
    }
    replicator.Status.ObservedGeneration = replicator.Generation

    if err := r.Status().Update(ctx, replicator); err != nil {
        return ctrl.Result{}, err
    }

    return ctrl.Result{}, nil
}

func (r *ConfigMapReplicatorReconciler) deleteReplicatedConfigMaps(ctx context.Context, replicator *platformv1alpha1.ConfigMapReplicator) error {
    for _, targetNS := range replicator.Spec.TargetNamespaces {
        cm := &corev1.ConfigMap{}
        err := r.Get(ctx, client.ObjectKey{
            Name:      replicator.Spec.SourceConfigMap.Name,
            Namespace: targetNS,
        }, cm)
        if apierrors.IsNotFound(err) {
            continue
        }
        if err != nil {
            return fmt.Errorf("get configmap %s/%s: %w", targetNS, replicator.Spec.SourceConfigMap.Name, err)
        }
        if err := r.Delete(ctx, cm); err != nil && !apierrors.IsNotFound(err) {
            return fmt.Errorf("delete configmap %s/%s: %w", targetNS, replicator.Spec.SourceConfigMap.Name, err)
        }
    }
    return nil
}

// SetupWithManager registers the controller with the manager.
func (r *ConfigMapReplicatorReconciler) SetupWithManager(mgr ctrl.Manager) error {
    return ctrl.NewControllerManagedBy(mgr).
        For(&platformv1alpha1.ConfigMapReplicator{}).
        Complete(r)
}
```

## Part 3b: Create main.go

Create the entrypoint in `main.go`:

```go
package main

import (
    "os"

    "k8s.io/apimachinery/pkg/runtime"
    utilruntime "k8s.io/apimachinery/pkg/util/runtime"
    clientgoscheme "k8s.io/client-go/kubernetes/scheme"
    ctrl "sigs.k8s.io/controller-runtime"
    "sigs.k8s.io/controller-runtime/pkg/log/zap"

    platformv1alpha1 "configmap-replicator/api/v1alpha1"
    "configmap-replicator/controllers"
)

func main() {
    scheme := runtime.NewScheme()
    utilruntime.Must(clientgoscheme.AddToScheme(scheme))
    utilruntime.Must(platformv1alpha1.AddToScheme(scheme))

    ctrl.SetLogger(zap.New())
    log := ctrl.Log.WithName("setup")

    mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
        Scheme: scheme,
    })
    if err != nil {
        log.Error(err, "unable to create manager")
        os.Exit(1)
    }

    if err := (&controllers.ConfigMapReplicatorReconciler{
        Client: mgr.GetClient(),
        Scheme: mgr.GetScheme(),
    }).SetupWithManager(mgr); err != nil {
        log.Error(err, "unable to create controller")
        os.Exit(1)
    }

    log.Info("Starting manager")
    if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
        log.Error(err, "problem running manager")
        os.Exit(1)
    }
}
```

## Part 4: Generate CRD Manifest

Use controller-gen to generate the CRD YAML from the kubebuilder markers in the types file:

```bash
# Install controller-gen if not already installed
go install sigs.k8s.io/controller-tools/cmd/controller-gen@latest

# Generate DeepCopy methods (required for runtime.Object interface)
controller-gen object paths=./api/...

# Generate CRD YAML
controller-gen crd paths=./api/... output:crd:artifacts:config=./config/crd
```

## Part 5: Run the Controller

### Step 1: Install CRD

```bash
kubectl apply -f config/crd/platform.example.com_configmapreplicators.yaml

# Verify CRD is installed
kubectl get crd configmapreplicators.platform.example.com
```

### Step 2: Create Test Namespaces

```bash
kubectl create namespace dev
kubectl create namespace staging
kubectl create namespace prod
```

### Step 3: Create Source ConfigMap

```bash
kubectl create configmap app-config \
  --from-literal=database.host=postgres.example.com \
  --from-literal=database.port=5432 \
  --from-literal=app.env=production \
  -n default
```

### Step 4: Run Controller Locally

```bash
# Resolve all transitive dependencies
go mod tidy

# Run controller (it will use your current kubeconfig)
go run main.go
```

You should see output like:
```
2024-01-15T10:30:00.000Z	INFO	Starting manager
2024-01-15T10:30:00.000Z	INFO	Starting controller	{"controller": "configmapreplicator"}
```

### Step 5: Create ConfigMapReplicator Resource

In another terminal:

```bash
kubectl apply -f config/samples/sample-replicator.yaml
```

Sample content:
```yaml
apiVersion: platform.example.com/v1alpha1
kind: ConfigMapReplicator
metadata:
  name: replicate-app-config
  namespace: default
spec:
  sourceConfigMap:
    name: app-config
    namespace: default
  targetNamespaces:
  - dev
  - staging
  - prod
```

### Step 6: Verify Replication

```bash
# Check the ConfigMapReplicator status
kubectl get configmapreplicator replicate-app-config -o yaml

# Verify ConfigMaps were replicated
kubectl get configmap app-config -n dev -o yaml
kubectl get configmap app-config -n staging -o yaml
kubectl get configmap app-config -n prod -o yaml

# All should have the same data as the source ConfigMap
```

## Part 6: Test Reconciliation Behavior

### Test 1: Update Source ConfigMap

```bash
# Update the source ConfigMap
kubectl patch configmap app-config -n default \
  --type merge \
  -p '{"data":{"new.key":"new-value"}}'

# Wait a few seconds for reconciliation
sleep 5

# Verify replicas were updated
kubectl get configmap app-config -n dev -o jsonpath='{.data.new\.key}'
# Should output: new-value
```

### Test 2: Delete a Replica

```bash
# Delete one of the replicated ConfigMaps
kubectl delete configmap app-config -n dev

# Wait for reconciliation
sleep 5

# Verify it was recreated
kubectl get configmap app-config -n dev
# Should exist again
```

### Test 3: Test Finalizer

```bash
# Delete the ConfigMapReplicator
kubectl delete configmapreplicator replicate-app-config

# Check that replicated ConfigMaps are being cleaned up
kubectl get configmap app-config -n dev
kubectl get configmap app-config -n staging
kubectl get configmap app-config -n prod
# All should be deleted or show "Terminating" briefly
```

### Test 4: Test ObservedGeneration

```bash
# Recreate the ConfigMapReplicator
kubectl apply -f config/samples/sample-replicator.yaml

# Check generation
kubectl get configmapreplicator replicate-app-config \
  -o jsonpath='{.metadata.generation}'
# Output: 1

# Check observedGeneration in status
kubectl get configmapreplicator replicate-app-config \
  -o jsonpath='{.status.observedGeneration}'
# Output: 1 (should match)

# Update the spec (add another namespace)
kubectl patch configmapreplicator replicate-app-config \
  --type merge \
  -p '{"spec":{"targetNamespaces":["dev","staging","prod","test"]}}'

# Check generation (should increment)
kubectl get configmapreplicator replicate-app-config \
  -o jsonpath='{.metadata.generation}'
# Output: 2

# Watch as observedGeneration catches up after reconciliation
kubectl get configmapreplicator replicate-app-config \
  -o jsonpath='{.status.observedGeneration}' -w
```

## Part 7: Observe Controller Behavior

### View Controller Logs

The controller logs show the reconciliation process:

```
2024-01-15T10:30:00.123Z INFO Reconciling ConfigMapReplicator {"namespace": "default", "name": "replicate-app-config"}
2024-01-15T10:30:00.234Z INFO Fetching source ConfigMap {"namespace": "default", "name": "app-config"}
2024-01-15T10:30:00.345Z INFO Replicating to namespace {"namespace": "dev"}
2024-01-15T10:30:00.456Z INFO Replicating to namespace {"namespace": "staging"}
2024-01-15T10:30:00.567Z INFO Replicating to namespace {"namespace": "prod"}
2024-01-15T10:30:00.678Z INFO Updated status {"generation": 1, "observedGeneration": 1}
2024-01-15T10:30:00.789Z INFO Reconciliation succeeded
```

### Watch for Reconciliation Triggers

```bash
# In one terminal, watch controller logs
go run main.go | grep "Reconciling"

# In another terminal, trigger various events
kubectl label configmapreplicator replicate-app-config test=value
# Should NOT trigger reconcile (metadata-only change)

kubectl patch configmapreplicator replicate-app-config \
  --type merge \
  -p '{"spec":{"targetNamespaces":["dev"]}}'
# SHOULD trigger reconcile (spec change)
```

## Part 8: Stretch Goals

### Challenge 1: Watch Source ConfigMap

Currently, the controller doesn't automatically sync when the source ConfigMap changes. Enhance the controller to watch the source ConfigMap and trigger reconciliation when it changes.

Hint: Use `Watches()` in SetupWithManager with `EnqueueRequestsFromMapFunc`.

### Challenge 2: Add Metrics

Add Prometheus metrics to track:
- Number of successful replications
- Number of failed replications
- Reconciliation duration

Hint: Use the `prometheus` package from controller-runtime.

### Challenge 3: Handle Namespace Creation

What happens if a target namespace doesn't exist? Enhance the controller to:
1. Detect missing namespaces
2. Update status condition with "Degraded" state
3. Automatically sync when the namespace is created later

### Challenge 4: Implement Bidirectional Sync

Make the replication bidirectional: if someone updates a replicated ConfigMap in a target namespace, sync it back to the source. This is much harder because it requires:
- Conflict resolution (what if two replicas are updated differently?)
- Preventing reconciliation loops
- Tracking the "true" source of changes

## What You Learned

This lab demonstrated core controller patterns:

1. **Spec/Status Contract**: Spec declares intent (what to replicate, where), status reports reality (what's actually replicated)

2. **Finalizers**: Safe deletion by cleaning up replicated ConfigMaps before removing the ConfigMapReplicator

3. **Idempotency**: Using CreateOrUpdate ensures replicas are created if missing, updated if they exist, with no side effects on repeated reconciliation

4. **Status Conditions**: Structured status reporting using Ready condition

5. **ObservedGeneration**: Tracking which spec version has been reconciled

6. **Reconcile Loop**: Continuous convergence of actual state toward desired state

7. **Event Filtering**: Using predicates to avoid unnecessary reconciliations

## Next Steps

- Study the full controller implementation in `controllers/configmapreplicator_controller.go`
- Experiment with breaking the controller (e.g., make reconciliation not idempotent) and observe the effects
- Try the stretch goals to deepen your understanding
- Move on to [02-informers-caches-indexers](../../02-informers-caches-indexers/lab/README.md) to learn how controllers efficiently watch resources at scale
