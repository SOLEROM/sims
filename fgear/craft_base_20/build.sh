#!/bin/bash
set -euo pipefail

# Always work from the directory where this script resides
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DOCKERFILE="Dockerfile.base"
IMAGE_NAME="fgfs-base:20"

docker build \
  -f "$DOCKERFILE" \
  -t "$IMAGE_NAME" \
  .

echo "Done. Built image: $IMAGE_NAME"
