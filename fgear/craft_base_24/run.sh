#!/bin/bash
# run.sh — host-side docker runner for the generic FlightGear layer (craft_base_24).
#
#   ./run.sh                      # standalone FG window (default bridge net)
#   ./run.sh bash                 # debug shell inside the image
#   ID=2 FG_MODE=external-fdm FG_NET=container:px4-sitl-2 ./run.sh
#                                 # renderer joining agent 2's netns
#
# Knobs (all env, all optional):
#   ID              instance id. Suffixes the container name (fgfs_$ID), the
#                   NavCache volume and the window title. Unset = single instance.
#   FG_IMAGE        image tag (default fgfs-base:24)
#   FG_MODE         standalone | external-fdm (forwarded to fgfs_runner.sh)
#   FG_NET          docker network: "" = default bridge | host |
#                   container:<name> (join that container's netns — the
#                   multi-agent model: one netns owner per agent, everyone else
#                   joins it). external-fdm with no FG_NET defaults to host so
#                   the UDP pose feed + telnet are reachable out of the box.
#   FG_ASSETS_DIR   project asset dir mounted into FG_ROOT (see layout below)
#   FG_ENV_FILE     optional --env-file passed to docker
#   FGFS_GPU        render backend: intel|host (host-X hardware GL, no
#                   passthrough) | 1/auto (NVIDIA passthrough only if a real
#                   nvidia runtime exists, else host-X GL) | 0/sw (llvmpipe —
#                   SLOW and does not render the ortho ground; last resort)
#   FG_HOME_VOL     NavCache volume name ("" disables; default fgfs_home_${ID:-0})
#   FG_DOCKER_DRYRUN=1  print the docker command instead of running it
#
# FG_ASSETS_DIR layout (all pieces optional):
#   Orthophotos/            -> Scenery/Orthophotos          (dir mount)
#   Models/                 -> Models/proj                  (dir mount)
#   Objects/<d10>/<d1>/*.stg -> Scenery/Objects/...         (per-file mounts)
#   Nasal/*.nas             -> Nasal/<name>                 (per-file mounts)
#   Protocol/*.xml          -> Protocol/<name>              (per-file mounts)
#   AI/**                   -> AI/...                       (per-file mounts)
# Per-FILE mounts are deliberate for trees FG already populates (Nasal, Protocol,
# AI, Objects): a directory mount there would SHADOW the stock files.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FG_IMAGE="${FG_IMAGE:-fgfs-base:24}"
FG_ROOT_DIR="${FG_ROOT_DIR:-/usr/share/games/flightgear}"
NAME="fgfs${ID:+_$ID}"
FG_MODE="${FG_MODE:-standalone}"

## bash first-arg overrides the entrypoint for a debug shell
if [ "${1:-}" = "bash" ]; then
    shift
    exec docker run --rm -it --entrypoint /bin/bash "$FG_IMAGE" "$@"
fi

# ---------------------------------------------------------------------------
# network mode. external-fdm needs its UDP/telnet ports reachable, so with no
# explicit FG_NET it defaults to host networking (single instance). Multi-agent
# setups pass FG_NET=container:<netns-owner> instead (identical internal ports
# across agents on purpose — isolation is by netns, never by renumbering).
# ---------------------------------------------------------------------------
NET_ARGS=()
if [ -z "${FG_NET:-}" ] && [ "$FG_MODE" = "external-fdm" ]; then
    echo "[INFO] FG_MODE=external-fdm with no FG_NET -> defaulting to --net=host"
    FG_NET=host
fi
case "${FG_NET:-}" in
    "")            : ;;
    host)          NET_ARGS=(--net=host) ;;
    container:*|bridge:*) NET_ARGS=(--network "${FG_NET/bridge:/}") ;;
    *)             NET_ARGS=(--network "$FG_NET") ;;
esac

# ---------------------------------------------------------------------------
# X authority file for the container. If the mount source doesn't exist,
# `docker run -v` silently creates it as a root-owned DIRECTORY -> X auth fails
# -> FG can't open the display -> the --rm container vanishes. Build a real
# xauth file (host part wildcarded so it's valid inside the container).
# Recreated every run to track DISPLAY. Skipped for headless runs.
# ---------------------------------------------------------------------------
X_ARGS=()
if [ "${FG_HEADLESS:-0}" != "1" ]; then
    xhost + local: >/dev/null 2>&1 || true
    XAUTH="${FG_XAUTH_FILE:-/tmp/.docker.xauth}"
    if [ -d "$XAUTH" ]; then sudo rm -rf "$XAUTH" 2>/dev/null || rm -rf "$XAUTH"; fi
    rm -f "$XAUTH" 2>/dev/null || true
    touch "$XAUTH"
    xauth -f "${XAUTHORITY:-$HOME/.Xauthority}" nlist "${DISPLAY:-:0}" 2>/dev/null \
        | sed -e 's/^..../ffff/' | xauth -f "$XAUTH" nmerge - 2>/dev/null || true
    chmod 644 "$XAUTH"
    X_ARGS=(
        --volume=/tmp/.X11-unix:/tmp/.X11-unix:rw
        -e DISPLAY="${DISPLAY:-:0}"
        -e XAUTHORITY=/tmp/.docker.xauth
        -v "$XAUTH":/tmp/.docker.xauth:ro
    )
fi

# ---------------------------------------------------------------------------
# Rendering backend (FGFS_GPU). FG renders via the host X server over the
# mounted X socket, so the container's GL follows whatever GPU the host Xorg
# uses. Hardware GL is what renders the ortho satellite ground correctly;
# llvmpipe is slow AND fails to draw it — never use sw to "fix" a GPU station.
# ---------------------------------------------------------------------------
GPU_ARGS=()
DOCKER_CMD=docker
case "${FGFS_GPU:-1}" in
    intel|host|igpu)
        # host X-server hardware GL, no passthrough (hybrid-laptop blessed path)
        : ;;
    0|sw|soft|llvmpipe)
        GPU_ARGS=(
            -e LIBGL_ALWAYS_SOFTWARE=1
            -e GALLIUM_DRIVER=llvmpipe
            -e MESA_GL_VERSION_OVERRIDE=3.3
            -e MESA_GLSL_VERSION_OVERRIDE=330
            -e __GLX_VENDOR_LIBRARY_NAME=mesa
        ) ;;
    *)
        # 1 / auto: NVIDIA passthrough only on a real nvidia host, else host X GL
        if docker info 2>/dev/null | grep -qiE 'Runtimes:.*nvidia'; then
            GPU_ARGS=(--gpus all -e NVIDIA_VISIBLE_DEVICES=all -e NVIDIA_DRIVER_CAPABILITIES=all)
        elif [ -x /usr/bin/nvidia-docker ]; then
            DOCKER_CMD=nvidia-docker
        fi ;;
esac

# ---------------------------------------------------------------------------
# Persist FG_HOME (NavCache ~166MB + autosave) across --rm runs in a per-ID
# named volume: only the first run pays the worldwide NavCache build. Per-ID so
# parallel instances never race on the same cache. `docker volume rm <vol>`
# forces a rebuild.
# ---------------------------------------------------------------------------
VOL_ARGS=()
FG_HOME_VOL="${FG_HOME_VOL-fgfs_home_${ID:-0}}"
[ -n "$FG_HOME_VOL" ] && VOL_ARGS=(-v "$FG_HOME_VOL":/root/.fgfs)

# ---------------------------------------------------------------------------
# project asset mounts (FG_ASSETS_DIR layout documented in the header)
# ---------------------------------------------------------------------------
ASSET_ARGS=()
if [ -n "${FG_ASSETS_DIR:-}" ] && [ ! -d "$FG_ASSETS_DIR" ]; then
    # a profile may wire a per-station generated dir (px4-fg does) — a station
    # that never generated it should still boot, just without project assets
    echo "[WARN] FG_ASSETS_DIR '$FG_ASSETS_DIR' does not exist — running without project assets"
    FG_ASSETS_DIR=""
fi
if [ -n "${FG_ASSETS_DIR:-}" ]; then
    A="$(cd "$FG_ASSETS_DIR" && pwd)"
    [ -d "$A/Orthophotos" ] && ASSET_ARGS+=(-v "$A/Orthophotos":"$FG_ROOT_DIR/Scenery/Orthophotos")
    [ -d "$A/Models" ]      && ASSET_ARGS+=(-v "$A/Models":"$FG_ROOT_DIR/Models/proj")
    if [ -d "$A/Objects" ]; then
        while IFS= read -r f; do
            ASSET_ARGS+=(-v "$f":"$FG_ROOT_DIR/Scenery/Objects/${f#"$A"/Objects/}")
        done < <(find "$A/Objects" -type f -name '*.stg')
    fi
    for d in Nasal Protocol; do
        [ -d "$A/$d" ] || continue
        while IFS= read -r f; do
            ASSET_ARGS+=(-v "$f":"$FG_ROOT_DIR/$d/$(basename "$f")")
        done < <(find "$A/$d" -maxdepth 1 -type f)
    done
    if [ -d "$A/AI" ]; then
        while IFS= read -r f; do
            ASSET_ARGS+=(-v "$f":"$FG_ROOT_DIR/AI/${f#"$A"/AI/}")
        done < <(find "$A/AI" -type f)
    fi
fi

# live-editable launcher: mount this layer's copy over the baked one
ASSET_ARGS+=(-v "$SCRIPT_DIR/fgfs_runner.sh":/usr/local/bin/fgfs_runner.sh:ro)

# ---------------------------------------------------------------------------
# env forwarding: every set FG_* knob (plus friends) goes into the container
# ---------------------------------------------------------------------------
ENV_ARGS=()
for v in ID FG_MODE FG_HOME_LAT FG_HOME_LON FG_HOME_ALT \
         PX4_HOME_LAT PX4_HOME_LON PX4_HOME_ALT \
         FG_CAM_WIDTH FG_CAM_HEIGHT FG_GEOMETRY FG_FOV FG_AIRCRAFT \
         FG_WINDOW_TITLE FG_TIMEOFDAY FG_WEATHER FG_METAR AI_SCENARIO \
         FG_FDM_PORT FG_GENERIC_PORT FG_GENERIC_HZ FG_TELNET_PORT FG_PROTOCOL \
         FG_ORTHO_AUTO FG_ORTHO_PATH FG_ORTHO_LAT FG_ORTHO_LON \
         FG_ORTHO_ELEV_M FG_ORTHO_ELEV_OFFSET_M FG_ORTHO_BELOW_CAM_M \
         FG_PHOTOSCENERY FG_SHADER_EFFECTS FG_GL_COMPAT FG_EXTRA_ARGS \
         FG_HEADLESS FG_DRYRUN; do
    [ -n "${!v:-}" ] && ENV_ARGS+=(-e "$v=${!v}")
done

ENVFILE_ARGS=()
[ -n "${FG_ENV_FILE:-}" ] && ENVFILE_ARGS=(--env-file "$FG_ENV_FILE")

# fresh container per run (matches the --rm model; a leftover name blocks reruns)
docker rm -f "$NAME" >/dev/null 2>&1 || true

# TTY only when we actually have one (scripted/CI callers don't)
TTY_ARGS=(-i); [ -t 0 ] && TTY_ARGS=(-it)

RUN_CMD=("$DOCKER_CMD" run "${TTY_ARGS[@]}" --rm --init
    --name "$NAME"
    ${NET_ARGS[@]+"${NET_ARGS[@]}"}
    ${GPU_ARGS[@]+"${GPU_ARGS[@]}"}
    ${X_ARGS[@]+"${X_ARGS[@]}"}
    ${VOL_ARGS[@]+"${VOL_ARGS[@]}"}
    ${ASSET_ARGS[@]+"${ASSET_ARGS[@]}"}
    ${ENV_ARGS[@]+"${ENV_ARGS[@]}"}
    ${ENVFILE_ARGS[@]+"${ENVFILE_ARGS[@]}"}
    -e DBUS_FATAL_WARNINGS=0
    --privileged
    "$FG_IMAGE" /usr/local/bin/fgfs_runner.sh "$@")

if [ "${FG_DOCKER_DRYRUN:-0}" = "1" ]; then
    printf '%q ' "${RUN_CMD[@]}"; printf '\n'
    exit 0
fi

exec "${RUN_CMD[@]}"
