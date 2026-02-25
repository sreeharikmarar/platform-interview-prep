# Lab: CRD Versioning with Conversion Webhook

## Objective

Walk through migrating a CRD from v1alpha1 to v1beta1 with breaking schema changes, implementing a conversion webhook, testing round-trip fidelity, and performing storage version migration.

## Prerequisites

- Kubernetes cluster (kind recommended for easy teardown)
- kubectl configured
- Go 1.21+
- cert-manager installed (for webhook TLS certificates)

## Scenario

You have a `Gateway` CRD with v1alpha1 that supports a single host and port. You need to evolve to v1beta1 that supports multiple listeners. This is a breaking change requiring a conversion webhook.

## Step 1: Deploy v1alpha1 CRD and Create Resources

**gateway-v1alpha1.yaml:**

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: gateways.networking.example.com
spec:
  group: networking.example.com
  names:
    kind: Gateway
    plural: gateways
    singular: gateway
  scope: Namespaced
  versions:
  - name: v1alpha1
    served: true
    storage: true  # Initially the storage version
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            required: [host, port]
            properties:
              host:
                type: string
              port:
                type: integer
                minimum: 1
                maximum: 65535
          status:
            type: object
            properties:
              ready:
                type: boolean
    subresources:
      status: {}
    additionalPrinterColumns:
    - name: Host
      type: string
      jsonPath: .spec.host
    - name: Port
      type: integer
      jsonPath: .spec.port
    - name: Ready
      type: boolean
      jsonPath: .status.ready
```

Deploy the CRD and create some Gateway resources:

```bash
kubectl apply -f gateway-v1alpha1.yaml

# Create test gateways
kubectl create namespace gateway-demo

kubectl apply -f - <<EOF
apiVersion: networking.example.com/v1alpha1
kind: Gateway
metadata:
  name: web-gateway
  namespace: gateway-demo
spec:
  host: example.com
  port: 443
status:
  ready: true
EOF

kubectl apply -f - <<EOF
apiVersion: networking.example.com/v1alpha1
kind: Gateway
metadata:
  name: api-gateway
  namespace: gateway-demo
spec:
  host: api.example.com
  port: 8443
EOF
```

Verify:

```bash
kubectl get gateways -n gateway-demo
```

## Step 2: Add v1beta1 Version (without webhook yet)

Update the CRD to add v1beta1 as a served version. Keep v1alpha1 as storage for now.

**gateway-v1alpha1-v1beta1.yaml:**

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: gateways.networking.example.com
spec:
  group: networking.example.com
  names:
    kind: Gateway
    plural: gateways
    singular: gateway
  scope: Namespaced
  versions:
  - name: v1alpha1
    served: true
    storage: true  # Still the storage version
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            required: [host, port]
            properties:
              host:
                type: string
              port:
                type: integer
          status:
            type: object
            properties:
              ready:
                type: boolean
    subresources:
      status: {}
  - name: v1beta1
    served: true
    storage: false  # Not storage yet
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            required: [listeners]
            properties:
              listeners:
                type: array
                minItems: 1
                items:
                  type: object
                  required: [hostname, port]
                  properties:
                    hostname:
                      type: string
                    port:
                      type: integer
          status:
            type: object
            properties:
              ready:
                type: boolean
    subresources:
      status: {}
    additionalPrinterColumns:
    - name: Listeners
      type: integer
      jsonPath: .spec.listeners[*].hostname
    - name: Ready
      type: boolean
      jsonPath: .status.ready
  conversion:
    strategy: Webhook
    webhook:
      clientConfig:
        service:
          name: gateway-conversion-webhook
          namespace: gateway-system
          path: /convert
      conversionReviewVersions: ["v1"]
```

Don't apply this yet—we need to deploy the webhook first, or the API server will reject requests.

## Step 3: Implement Conversion Webhook

**webhook/main.go:**

```go
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"

	apiextensionsv1 "k8s.io/apiextensions-apiserver/pkg/apis/apiextensions/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/klog/v2"
)

const (
	v1alpha1Version = "networking.example.com/v1alpha1"
	v1beta1Version  = "networking.example.com/v1beta1"
)

type gatewayV1alpha1 struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`
	Spec              gatewayV1alpha1Spec `json:"spec"`
}

type gatewayV1alpha1Spec struct {
	Host string `json:"host"`
	Port int    `json:"port"`
}

type gatewayV1beta1 struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`
	Spec              gatewayV1beta1Spec `json:"spec"`
}

type gatewayV1beta1Spec struct {
	Listeners []listener `json:"listeners"`
}

type listener struct {
	Hostname string `json:"hostname"`
	Port     int    `json:"port"`
}

func convert(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, fmt.Sprintf("failed to read body: %v", err), http.StatusBadRequest)
		return
	}

	review := apiextensionsv1.ConversionReview{}
	if err := json.Unmarshal(body, &review); err != nil {
		http.Error(w, fmt.Sprintf("failed to unmarshal: %v", err), http.StatusBadRequest)
		return
	}

	convertedObjects := []runtime.RawExtension{}
	for _, obj := range review.Request.Objects {
		converted, err := convertObject(obj.Raw, review.Request.DesiredAPIVersion)
		if err != nil {
			klog.Errorf("Conversion failed: %v", err)
			review.Response = &apiextensionsv1.ConversionResponse{
				UID:    review.Request.UID,
				Result: metav1.Status{Status: "Failure", Message: err.Error()},
			}
			writeResponse(w, review)
			return
		}
		convertedObjects = append(convertedObjects, runtime.RawExtension{Raw: converted})
	}

	review.Response = &apiextensionsv1.ConversionResponse{
		UID:              review.Request.UID,
		ConvertedObjects: convertedObjects,
		Result:           metav1.Status{Status: "Success"},
	}

	writeResponse(w, review)
}

func convertObject(raw []byte, desiredVersion string) ([]byte, error) {
	var obj map[string]interface{}
	if err := json.Unmarshal(raw, &obj); err != nil {
		return nil, err
	}

	currentVersion := obj["apiVersion"].(string)

	if currentVersion == desiredVersion {
		return raw, nil // No conversion needed
	}

	switch {
	case currentVersion == v1alpha1Version && desiredVersion == v1beta1Version:
		return convertV1alpha1ToV1beta1(raw)
	case currentVersion == v1beta1Version && desiredVersion == v1alpha1Version:
		return convertV1beta1ToV1alpha1(raw)
	default:
		return nil, fmt.Errorf("conversion from %s to %s not supported", currentVersion, desiredVersion)
	}
}

func convertV1alpha1ToV1beta1(raw []byte) ([]byte, error) {
	var v1alpha1 gatewayV1alpha1
	if err := json.Unmarshal(raw, &v1alpha1); err != nil {
		return nil, err
	}

	v1beta1 := gatewayV1beta1{
		TypeMeta: metav1.TypeMeta{
			APIVersion: v1beta1Version,
			Kind:       "Gateway",
		},
		ObjectMeta: v1alpha1.ObjectMeta,
		Spec: gatewayV1beta1Spec{
			Listeners: []listener{
				{Hostname: v1alpha1.Spec.Host, Port: v1alpha1.Spec.Port},
			},
		},
	}

	return json.Marshal(v1beta1)
}

func convertV1beta1ToV1alpha1(raw []byte) ([]byte, error) {
	var v1beta1 gatewayV1beta1
	if err := json.Unmarshal(raw, &v1beta1); err != nil {
		return nil, err
	}

	v1alpha1 := gatewayV1alpha1{
		TypeMeta: metav1.TypeMeta{
			APIVersion: v1alpha1Version,
			Kind:       "Gateway",
		},
		ObjectMeta: v1beta1.ObjectMeta,
		Spec: gatewayV1alpha1Spec{
			Host: v1beta1.Spec.Listeners[0].Hostname,
			Port: v1beta1.Spec.Listeners[0].Port,
		},
	}

	// Preserve extra listeners for round-trip fidelity
	if len(v1beta1.Spec.Listeners) > 1 {
		extraListeners, _ := json.Marshal(v1beta1.Spec.Listeners[1:])
		if v1alpha1.Annotations == nil {
			v1alpha1.Annotations = make(map[string]string)
		}
		v1alpha1.Annotations["gateway.example.com/extra-listeners"] = string(extraListeners)
	}

	return json.Marshal(v1alpha1)
}

func writeResponse(w http.ResponseWriter, review apiextensionsv1.ConversionReview) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(review)
}

func main() {
	http.HandleFunc("/convert", convert)
	klog.Info("Starting conversion webhook on :8443")
	klog.Fatal(http.ListenAndServeTLS(":8443", "/certs/tls.crt", "/certs/tls.key", nil))
}
```

Build and push the webhook image:

```bash
cd webhook
docker build -t your-registry/gateway-conversion-webhook:v1 .
docker push your-registry/gateway-conversion-webhook:v1
```

## Step 4: Deploy Webhook with TLS Certificates

Install cert-manager if not already installed:

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.0/cert-manager.yaml
```

Create the webhook deployment and certificate:

```bash
kubectl create namespace gateway-system

kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: gateway-conversion-webhook-cert
  namespace: gateway-system
spec:
  secretName: gateway-conversion-webhook-tls
  dnsNames:
  - gateway-conversion-webhook.gateway-system.svc
  - gateway-conversion-webhook.gateway-system.svc.cluster.local
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
EOF

kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gateway-conversion-webhook
  namespace: gateway-system
spec:
  replicas: 2
  selector:
    matchLabels:
      app: gateway-conversion-webhook
  template:
    metadata:
      labels:
        app: gateway-conversion-webhook
    spec:
      containers:
      - name: webhook
        image: your-registry/gateway-conversion-webhook:v1
        ports:
        - containerPort: 8443
        volumeMounts:
        - name: certs
          mountPath: /certs
          readOnly: true
      volumes:
      - name: certs
        secret:
          secretName: gateway-conversion-webhook-tls
---
apiVersion: v1
kind: Service
metadata:
  name: gateway-conversion-webhook
  namespace: gateway-system
spec:
  ports:
  - port: 443
    targetPort: 8443
  selector:
    app: gateway-conversion-webhook
EOF
```

Wait for the webhook to be ready:

```bash
kubectl wait --for=condition=available --timeout=120s deployment/gateway-conversion-webhook -n gateway-system
```

## Step 5: Update CRD to Use Webhook

Now apply the updated CRD with both versions and webhook conversion:

```bash
kubectl apply -f gateway-v1alpha1-v1beta1.yaml
```

## Step 6: Test Conversion

Read existing v1alpha1 resources in v1beta1:

```bash
kubectl get gateway web-gateway -n gateway-demo -o yaml
# Should show apiVersion: networking.example.com/v1alpha1

# Request the object at the v1beta1 version (triggers conversion)
kubectl get gateways.v1beta1.networking.example.com web-gateway -n gateway-demo -o yaml
# Should show apiVersion: networking.example.com/v1beta1 with listeners array
```

Create a new resource in v1beta1:

```bash
kubectl apply -f - <<EOF
apiVersion: networking.example.com/v1beta1
kind: Gateway
metadata:
  name: multi-gateway
  namespace: gateway-demo
spec:
  listeners:
  - hostname: a.example.com
    port: 80
  - hostname: b.example.com
    port: 443
EOF
```

Read it in v1alpha1:

```bash
kubectl get gateways.v1alpha1.networking.example.com multi-gateway -n gateway-demo -o yaml
```

You should see:
- Only the first listener in spec.host and spec.port
- An annotation `gateway.example.com/extra-listeners` containing the second listener

## Step 7: Migrate Storage Version

Update the CRD to change the storage version to v1beta1:

```bash
# Edit the CRD to swap storage flags
kubectl patch crd gateways.networking.example.com --type=json -p='[
  {"op": "replace", "path": "/spec/versions/0/storage", "value": false},
  {"op": "replace", "path": "/spec/versions/1/storage", "value": true}
]'
```

Now new objects are stored in v1beta1, but existing objects remain in v1alpha1 in etcd.

Migrate all objects by reading and writing them:

```bash
kubectl get gateways --all-namespaces -o json | \
  jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"' | \
  while read ns name; do
    echo "Migrating $ns/$name"
    kubectl get gateway -n "$ns" "$name" -o json | kubectl replace -f -
  done
```

## Step 8: Verify Round-Trip Fidelity

Create a gateway with multiple listeners in v1beta1, read it in v1alpha1, then update it, and verify no data is lost:

```bash
# Create in v1beta1
kubectl apply -f - <<EOF
apiVersion: networking.example.com/v1beta1
kind: Gateway
metadata:
  name: roundtrip-test
  namespace: gateway-demo
spec:
  listeners:
  - hostname: x.example.com
    port: 80
  - hostname: y.example.com
    port: 443
EOF

# Read in v1alpha1 (triggers v1beta1 → v1alpha1 conversion)
kubectl get gateways.v1alpha1.networking.example.com roundtrip-test -n gateway-demo -o yaml

# Update status in v1alpha1 (triggers v1alpha1 → v1beta1 conversion on write)
kubectl patch gateway roundtrip-test -n gateway-demo --subresource=status --type=merge -p '{"status":{"ready":true}}'

# Read in v1beta1 and verify both listeners still exist
kubectl get gateway roundtrip-test -n gateway-demo -o jsonpath='{.spec.listeners}' | jq .
```

You should see both listeners preserved, demonstrating round-trip fidelity via the annotation.

## Step 9: Test Webhook Failure

Simulate webhook unavailability:

```bash
kubectl scale deployment gateway-conversion-webhook -n gateway-system --replicas=0
```

Try to read a gateway in a different version:

```bash
kubectl get gateways.v1beta1.networking.example.com web-gateway -n gateway-demo -o yaml
```

You should get an error like "conversion webhook failed: connection refused."

Restore the webhook:

```bash
kubectl scale deployment gateway-conversion-webhook -n gateway-system --replicas=2
```

## Clean Up

```bash
kubectl delete namespace gateway-demo gateway-system
kubectl delete crd gateways.networking.example.com
```

## Key Takeaways

- Storage version is where objects are persisted; served versions are what clients can use
- Conversion webhooks enable complex schema transformations between versions
- Round-trip fidelity requires preserving all data, even if it doesn't fit the target schema (use annotations)
- Webhook outages block all API access—HA is critical
- Storage version migration rewrites all objects to the new version
- Test conversion in both directions and verify no data loss
