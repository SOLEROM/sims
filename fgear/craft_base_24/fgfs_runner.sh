#!/bin/bash
# fgfs_runner.sh — generic in-container FlightGear launcher (craft_base_24).
#
# Two modes, selected by FG_MODE:
#
#   standalone     Plain FlightGear: FG flies its own aircraft (FDM inside FG).
#                  Good for scenery checks and interactive exploring.
#
#   external-fdm   "Drone camera" renderer: FlightGear does NO physics. The
#                  vehicle pose is streamed IN over UDP using the generic
#                  protocol 'fg_protocol' (9 tab-separated fields — see
#                  protocol/fg_protocol.xml; tools/feed_fdm.py is a reference
#                  sender). FG renders the world + a camera view that an outer
#                  pipeline can screen-grab. This is the field-proven mode.
#
# Every knob is env-driven with safe defaults; extra CLI args pass straight to
# fgfs. Special envs for validation/CI:
#   FG_DRYRUN=1    print the fully-assembled command line and exit 0.
#   FG_HEADLESS=1  wrap fgfs in xvfb-run + force software GL (no display needed).
#
# Position env: FG_HOME_LAT/LON/ALT first, PX4_HOME_LAT/LON/ALT accepted as a
# drop-in fallback so PX4-style env files work unchanged.
set -euo pipefail

FG_ROOT_DIR="${FG_ROOT_DIR:-/usr/share/games/flightgear}"
FGFS_BIN="${FGFS_BIN:-/usr/games/fgfs}"
FG_MODE="${FG_MODE:-standalone}"

# --- home / base position (strip stray spaces — env files often carry them) ---
HOME_LAT="${FG_HOME_LAT:-${PX4_HOME_LAT:-37.613544}}";  HOME_LAT="${HOME_LAT// /}"
HOME_LON="${FG_HOME_LON:-${PX4_HOME_LON:--122.357172}}"; HOME_LON="${HOME_LON// /}"
HOME_ALT="${FG_HOME_ALT:-${PX4_HOME_ALT:-5}}";          HOME_ALT="${HOME_ALT// /}"

# --- window geometry: SQUARE by default in renderer mode. A landscape window
# under a very wide FOV pushes an extreme-oblique ground wedge into frame and a
# later rescale stretches it; a square window shows the clean nadir disc. ---
CAM_W="${FG_CAM_WIDTH:-800}"
CAM_H="${FG_CAM_HEIGHT:-800}"

# --- per-instance X11 window title so multi-instance capture/placement tooling
# can target THIS window (with N>1 every FG window is otherwise just
# "FlightGear" and first-match grabs all act on instance 1). ---
FG_WINDOW_TITLE="${FG_WINDOW_TITLE:-FlightGear${ID:+-$ID}}"

# --- GL compatibility exports (FG_GL_COMPAT=0 to skip). These ship with the
# verified reference render config; they are required for llvmpipe/Xvfb runs and
# harmless on hardware GL (iris/NVIDIA already provide >=3.3). ---
if [ "${FG_GL_COMPAT:-1}" = "1" ]; then
    export OSG_WINDOW_TYPE=x11
    export OSG_GL_EXTENSION_DISABLE=GL_ARB_framebuffer_object,GL_EXT_framebuffer_object
    export MESA_GL_VERSION_OVERRIDE=3.3
    export MESA_GLSL_VERSION_OVERRIDE=330
fi

CMD=("$FGFS_BIN" --fg-root="$FG_ROOT_DIR")

case "$FG_MODE" in
standalone)
    CMD+=(
        --timeofday="${FG_TIMEOFDAY:-noon}"
        --disable-ai-models
        --disable-sound
    )
    [ -n "${FG_GEOMETRY:-}" ] && CMD+=(--geometry="$FG_GEOMETRY")
    [ -n "${FG_AIRCRAFT:-}" ] && CMD+=(--aircraft="$FG_AIRCRAFT")
    ;;

external-fdm)
    # Ortho satellite-ground auto-placement (Nasal addobj.nas reads /ortho/*).
    # Two hard-won rules encoded here (full trail: readme.md "render lessons"):
    #   1. The quad must be placed at RUNTIME (static .stg placement loads but
    #      never draws on this FG build) — hence the /ortho props + Nasal hook.
    #   2. Elevation is the whole game: a flat plane is only visible from ABOVE,
    #      so it must sit just BELOW the landed camera (default: HOME_ALT - 1 m).
    # FG_ORTHO_AUTO defaults to ON only when the ortho model actually exists, so
    # the lean base image never spams placement errors.
    FG_ORTHO_PATH="${FG_ORTHO_PATH:-Models/proj/ortho_home.xml}"
    if [ -z "${FG_ORTHO_AUTO:-}" ]; then
        if [ -f "$FG_ROOT_DIR/$FG_ORTHO_PATH" ]; then FG_ORTHO_AUTO=1; else FG_ORTHO_AUTO=0; fi
    fi
    ORTHO_ELEV_DEFAULT="$(awk "BEGIN{print ${HOME_ALT:-5} - ${FG_ORTHO_BELOW_CAM_M:-1.0}}")"

    CMD+=(
        --prop:/sim/title="$FG_WINDOW_TITLE"
        --prop:/ortho/auto="${FG_ORTHO_AUTO}"
        --prop:/ortho/path="${FG_ORTHO_PATH}"
        --prop:/ortho/lat="${FG_ORTHO_LAT:-$HOME_LAT}"
        --prop:/ortho/lon="${FG_ORTHO_LON:-$HOME_LON}"
        --prop:/ortho/elev-m="${FG_ORTHO_ELEV_M:-$ORTHO_ELEV_DEFAULT}"
        --prop:/ortho/elev-offset-m="${FG_ORTHO_ELEV_OFFSET_M:-1.5}"
        --prop:/sim/menubar/visibility=false
        --prop:/sim/rendering/static-lod/aimp-detailed=1
        --prop:/environment/weather-scenario="${FG_WEATHER:-Fair weather}"
        --geometry="${FG_GEOMETRY:-${CAM_W}x${CAM_H}}"
        --timeofday="${FG_TIMEOFDAY:-noon}"
        --fdm=external
        --aircraft="${FG_AIRCRAFT:-ufo}"
        --native-fdm=socket,in,10,,"${FG_FDM_PORT:-5503}",udp
        --generic=socket,in,"${FG_GENERIC_HZ:-40}",,"${FG_GENERIC_PORT:-15778}",udp,"${FG_PROTOCOL:-fg_protocol}"
        --telnet="${FG_TELNET_PORT:-15777}"
        --bpp=24
        --fov="${FG_FOV:-55}"
        --disable-anti-alias-hud
        --disable-hud-3d
        --disable-horizon-effect
        --disable-sound
        --disable-fullscreen
        --fog-disable
        --disable-specular-highlight
        --disable-terrasync
        --disable-random-objects
        --lon="$HOME_LON"
        --lat="$HOME_LAT"
        --altitude="$HOME_ALT"
        --console
        --prop:/sim/rendering/multi-sample-buffers=false
        --prop:/sim/rendering/multi-samples=0
        --prop:/sim/rendering/multithreading-mode=SingleThreaded
        --prop:/sim/rendering/photoscenery/enabled="${FG_PHOTOSCENERY:-false}"
        --prop:/sim/rendering/shader-effects="${FG_SHADER_EFFECTS:-false}"
        --prop:/sim/rendering/shaders/skydome=false
        --prop:/sim/rendering/shaders/quality-level=0
        --prop:/sim/rendering/als-filters/use-filtering=false
        --prop:/sim/rendering/als-filters/use-IR-vision=false
        --prop:/sim/rendering/vegetation-density=0
        --metar="${FG_METAR:-XXXX 012000Z 00000KT 9999 CLR 22/19 Q1013 NOSIG}"
        --disable-real-weather-fetch
    )
    [ -n "${AI_SCENARIO:-}" ] && CMD+=(--ai-scenario="$AI_SCENARIO")
    ;;

*)
    echo "ERROR: unknown FG_MODE='$FG_MODE' (standalone|external-fdm)" >&2
    exit 2
    ;;
esac

# extra args: env first (word-split on purpose), then CLI passthrough
# shellcheck disable=SC2206
[ -n "${FG_EXTRA_ARGS:-}" ] && CMD+=(${FG_EXTRA_ARGS})
CMD+=("$@")

# headless smoke-test wrapper: own Xvfb + readiness poll + software GL.
# Deliberately NOT xvfb-run: its Xvfb-ready handshake is a SIGUSR1 to the
# parent, which is silently never delivered when that parent is container
# PID 1 — xvfb-run then blocks in `wait` forever and the command never runs.
if [ "${FG_HEADLESS:-0}" = "1" ]; then
    export LIBGL_ALWAYS_SOFTWARE=1
    export GALLIUM_DRIVER=llvmpipe
    XVFB_DISPLAY="${FG_XVFB_DISPLAY:-:99}"
    Xvfb "$XVFB_DISPLAY" -screen 0 "${CAM_W}x${CAM_H}x24" -nolisten tcp &
    XVFB_PID=$!
    for _ in $(seq 1 50); do
        xdpyinfo -display "$XVFB_DISPLAY" >/dev/null 2>&1 && break
        kill -0 "$XVFB_PID" 2>/dev/null || { echo "[fgfs_runner] Xvfb died" >&2; exit 1; }
        sleep 0.2
    done
    export DISPLAY="$XVFB_DISPLAY"
    unset XAUTHORITY
fi

if [ "${FG_DRYRUN:-0}" = "1" ]; then
    printf '%q ' "${CMD[@]}"; printf '\n'
    exit 0
fi

echo "[fgfs_runner] mode=$FG_MODE title=$FG_WINDOW_TITLE home=$HOME_LAT,$HOME_LON,$HOME_ALT"
exec "${CMD[@]}"
