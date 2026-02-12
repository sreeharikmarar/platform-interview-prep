#!/usr/bin/env bash
set -euo pipefail
CLUSTER_NAME="${1:-prep}"
K8S_VERSION="${K8S_VERSION:-v1.30.0}"
cat <<EOF | kind create cluster --name "$CLUSTER_NAME" --image "kindest/node:${K8S_VERSION}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
EOF
kubectl cluster-info
