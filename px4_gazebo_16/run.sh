#!/usr/bin/env bash

CONTAINER_NAME="px4-sitl-16"
IMAGE_NAME="px4-sitl-16"

#---------------------------------------------
# 1) Ensure XAUTHORITY is set (host side)
#---------------------------------------------
if [[ -z "$XAUTHORITY" ]]; then
    export XAUTHORITY="$HOME/.Xauthority"
    echo "[INFO] XAUTHORITY not set. Using $XAUTHORITY"
fi

if [[ ! -f "$XAUTHORITY" ]]; then
    echo "[WARN] XAUTHORITY file '$XAUTHORITY' does not exist."
    echo "       X11 forwarding from inside Docker will probably fail."
fi

#---------------------------------------------
# 2) Check if container is running or exists
#---------------------------------------------
IS_RUNNING=$(docker ps --filter "name=^${CONTAINER_NAME}$" --format "{{.Names}}")
IS_EXISTING=$(docker ps -a --filter "name=^${CONTAINER_NAME}$" --format "{{.Names}}")

if [[ -z "$IS_RUNNING" ]]; then
    echo "[INFO] Container not running."

    # If it exists but exited → remove it (fresh run each time)
    if [[ -n "$IS_EXISTING" ]]; then
        echo "[INFO] Removing old stopped container..."
        docker rm "$CONTAINER_NAME" >/dev/null
    fi

    echo "[INFO] Starting new container..."
    exec docker run --rm -it \
        --name "$CONTAINER_NAME" \
        --net=host \
        -e DISPLAY="$DISPLAY" \
        -e XAUTHORITY="/root/.Xauthority" \
        -v /tmp/.X11-unix:/tmp/.X11-unix \
        -v "$XAUTHORITY:/root/.Xauthority:ro" \
        -v "$PWD/logs:/root/PX4-Autopilot/build/px4_sitl_default/logs" \
        "$IMAGE_NAME"
else
    echo "[INFO] Container already running → exec into it"
    exec docker exec -it "$CONTAINER_NAME" bash
fi
