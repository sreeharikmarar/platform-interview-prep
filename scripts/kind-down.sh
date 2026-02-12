#!/usr/bin/env bash
set -euo pipefail
CLUSTER_NAME="${1:-prep}"
kind delete cluster --name "$CLUSTER_NAME"
