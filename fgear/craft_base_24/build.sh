#!/bin/bash
# Build the generic FlightGear base image (craft_base_24).
#
#   ./build.sh                                   # lean base, no scenery
#   SCENERY_TILES="e030n30 e030n20" ./build.sh   # bake world scenery tiles in
#   AIRCRAFT_ZIPS="Rascal" ./build.sh            # bake extra aircraft in
#   IMAGE_NAME=myproj-fgfs:1 ./build.sh          # custom tag
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DOCKERFILE="Dockerfile.base"
IMAGE_NAME="${IMAGE_NAME:-fgfs-base:24}"

DOCKER_BUILDKIT=1 docker build \
    -f "$DOCKERFILE" \
    --build-arg SCENERY_TILES="${SCENERY_TILES:-}" \
    --build-arg AIRCRAFT_ZIPS="${AIRCRAFT_ZIPS:-}" \
    -t "$IMAGE_NAME" \
    .

echo "Done. Built image: $IMAGE_NAME"
