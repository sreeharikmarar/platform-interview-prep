#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="week00-lab"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Build the image if --build is passed
if [[ "${1:-}" == "--build" ]]; then
  echo "Building $IMAGE_NAME image..."
  docker build \
    -t "$IMAGE_NAME" \
    -f "$SCRIPT_DIR/Dockerfile" \
    "$REPO_ROOT"
  shift
fi

# Check that the image exists
if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
  echo "Image '$IMAGE_NAME' not found. Run with --build first:"
  echo "  $0 --build"
  exit 1
fi

exec docker run -it --rm \
  --privileged \
  --hostname lab \
  --name "$IMAGE_NAME" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  "$IMAGE_NAME" \
  "$@"
