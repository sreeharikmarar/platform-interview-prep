# Platform Interview Prep

## Project Overview
A structured Kubernetes and platform engineering interview preparation repository organized into weekly topics.

## Structure
- `weeks/` - Weekly content folders, each covering a specific domain:
  - `week-00-linux-containers-and-cloud-networking/` - Linux foundations, container internals, cloud networking
  - `week-01-k8s-api-and-control-plane/` - Kubernetes API & control plane
  - `week-02-operators-and-platform-apis/` - Operators and platform APIs
  - `week-03-service-mesh-envoy-gateways/` - Service mesh, Envoy, and gateways
  - `week-04-distributed-systems-scale-and-ai/` - Distributed systems, scale, and AI

## Content Guidelines
- Each week folder contains markdown documentation and hands-on lab exercises
- Content should be technically deep and interview-focused
- Use real-world Kubernetes examples with accurate YAML/Go/code snippets
- Organize content with clear headings and progressive depth (fundamentals -> advanced)

## Topic Layout (per week)
Each week subfolder follows this structure:
- `README.md` — concept deep-dive
- `talk-tracks.md` — interview Q&A scripts (1-min answers + walkthrough)
- `lab/README.md` — step-by-step hands-on instructions
- `lab/*.yaml` — supporting manifests / configs

## Conventions
- Use kebab-case for folder and file names
- Prefix week folders with `week-NN-`
- Write in markdown format

## Content Review Status
All 4 weeks reviewed by an expert K8s/Envoy engineer (2026-02-18). Known corrections applied:
- `week-03/.../02-traffic-management-internals/lab/envoy-priority.yaml` — rewritten to use correct single-cluster priority failover model; router filter `@type` fixed
- `week-01/.../02-apply-ssa-and-patch-semantics/lab/README.md` — stale replica counts corrected
