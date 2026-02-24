#!/usr/bin/env bash
set -euo pipefail

# Start containerd in the background (needed for topic 03 — CRI / crictl exercises)
containerd &>/var/log/containerd.log &

# Wait for the containerd socket (up to 5 seconds)
for i in $(seq 1 10); do
  if [ -S /run/containerd/containerd.sock ]; then
    break
  fi
  sleep 0.5
done

if [ -S /run/containerd/containerd.sock ]; then
  echo "containerd is ready"
else
  echo "WARNING: containerd did not start within 5s — topic 03 CRI exercises may not work"
fi

cat <<'BANNER'

  ┌──────────────────────────────────────────────┐
  │   Week 00 — Linux & Container Foundations    │
  │                                              │
  │   Lab directories:                           │
  │     /labs/01/  Processes, signals, /proc      │
  │     /labs/02/  cgroups & namespaces           │
  │     /labs/03/  OCI runtimes & containerd      │
  │     /labs/04/  Container networking & CNI     │
  │                                              │
  │   Tools: runc, containerd, ctr, crictl,      │
  │          docker (via host socket), strace,    │
  │          unshare, nsenter, ip, iptables       │
  └──────────────────────────────────────────────┘

BANNER

exec "$@"
