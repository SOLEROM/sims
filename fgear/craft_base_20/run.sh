#!/bin/bash
set -euo pipefail
# Always work from the directory where this script resides
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DOCKERFIL="Dockerfile.base"
IMAGE_NAME="fgfs-base:20"

## bash override the entrypoint
[ "${1:-}" = bash ] && ENTRYPOINT=(--entrypoint /bin/bash) && shift || ENTRYPOINT=()

docker run --rm -it \
    -e DISPLAY="$DISPLAY" \
    -v /tmp/.X11-unix:/tmp/.X11-unix \
    --device /dev/dri:/dev/dri \
    --device /dev/snd:/dev/snd \
    "${ENTRYPOINT[@]}" \
    "$IMAGE_NAME" "$@"