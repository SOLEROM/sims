#!/bin/bash
# validate.sh — staged validation of the craft_base_24 FlightGear layer.
#
#   ./validate.sh                 # static + tile math + generators + dry-runs
#   ./validate.sh --build         # + docker image build
#   ./validate.sh --image         # + image smoke (fgfs --version; needs image)
#   ./validate.sh --live          # + full headless end-to-end: boot renderer,
#                                 #   stream a pose over UDP, assert via telnet
#   ./validate.sh --all           # everything
#
# The live test proves the whole external-fdm contract with no display and no
# outer pipeline: run.sh -> docker -> xvfb -> fgfs (--fdm=external) <- UDP pose
# from feed_fdm.py, asserted through the props telnet (fg_prop.py).
set -uo pipefail
MYDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(dirname "$MYDIR")"
IMAGE="${FG_IMAGE:-fgfs-base:24}"

DO_BUILD=0; DO_IMAGE=0; DO_LIVE=0
for a in "$@"; do
    case "$a" in
        --build) DO_BUILD=1 ;;
        --image) DO_IMAGE=1 ;;
        --live)  DO_IMAGE=1; DO_LIVE=1 ;;
        --all)   DO_BUILD=1; DO_IMAGE=1; DO_LIVE=1 ;;
        *) echo "unknown arg: $a"; exit 2 ;;
    esac
done

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  [PASS] $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  [FAIL] $*"; }
step() { echo; echo "== $* =="; }

# ---------------------------------------------------------------- 1. static --
step "static checks"
for f in "$BASE"/*.sh "$MYDIR"/*.sh; do
    if bash -n "$f" 2>/dev/null; then ok "bash -n $(basename "$f")"; else bad "bash -n $(basename "$f")"; fi
done
for f in "$MYDIR"/*.py; do
    if python3 -m py_compile "$f" 2>/dev/null; then ok "py_compile $(basename "$f")"; else bad "py_compile $(basename "$f")"; fi
done

# ------------------------------------------------------------- 2. tile math --
step "tile math (SGBucket)"
if python3 "$MYDIR/fg_tiles.py" --selftest; then ok "fg_tiles selftest"; else bad "fg_tiles selftest"; fi

# ------------------------------------------------------------ 3. generators --
step "gen_objects on assets.example"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
cp "$BASE/assets.example/objects.json" "$T/"
if python3 "$MYDIR/gen_objects.py" --json "$T/objects.json" --out "$T" >/dev/null; then
    STG="$T/Objects/w130n30/w123n37/942050.stg"
    [ -f "$STG" ] && ok "computed .stg path (KSFO tile 942050)" || bad "expected $STG"
    grep -q "OBJECT_SHARED Models/proj/ortho_home.xml" "$STG" 2>/dev/null \
        && ok ".stg content (ortho_home line)" || bad ".stg content"
    [ -f "$T/objects.kml" ] && grep -q "<Polygon>" "$T/objects.kml" \
        && ok "objects.kml polygons" || bad "objects.kml"
else
    bad "gen_objects.py run"
fi

# --------------------------------------------------------------- 4. dry-runs --
step "runner dry-runs (arg assembly)"
OUT="$(FG_DRYRUN=1 FG_MODE=external-fdm ID=7 FG_HOME_LAT=37.613544 FG_HOME_LON=-122.357172 \
        bash "$BASE/fgfs_runner.sh")" || OUT=""
for want in -- "--fdm=external" "--aircraft=ufo" "--telnet=15777" \
            "fg_protocol" "--prop:/sim/title=FlightGear-7" "--geometry=800x800"; do
    [ "$want" = "--" ] && continue
    case "$OUT" in *"$want"*) ok "external-fdm has $want" ;; *) bad "external-fdm missing $want" ;; esac
done
case "$OUT" in *"--prop:/ortho/auto=0"*) ok "ortho auto defaults OFF without model" ;; \
               *) bad "ortho auto default" ;; esac
OUT2="$(FG_DRYRUN=1 FG_MODE=standalone bash "$BASE/fgfs_runner.sh")" || OUT2=""
case "$OUT2" in *"--disable-ai-models"*) ok "standalone mode assembles" ;; *) bad "standalone mode" ;; esac
OUT3="$(FG_DOCKER_DRYRUN=1 FG_HEADLESS=1 FG_MODE=external-fdm ID=7 bash "$BASE/run.sh")" || OUT3=""
for want in "--name fgfs_7" "--net=host" "fgfs_home_7:/root/.fgfs"; do
    case "$OUT3" in *"$want"*) ok "run.sh has $want" ;; *) bad "run.sh missing $want" ;; esac
done

# ------------------------------------------------------------ 5. image build --
if [ "$DO_BUILD" = 1 ]; then
    step "docker image build ($IMAGE)"
    if (cd "$BASE" && IMAGE_NAME="$IMAGE" ./build.sh >/tmp/fgbase_build.log 2>&1); then
        ok "build.sh ($IMAGE)"
    else
        bad "build.sh — see /tmp/fgbase_build.log"
    fi
fi

# ------------------------------------------------------------ 6. image smoke --
if [ "$DO_IMAGE" = 1 ]; then
    step "image smoke"
    # QT_QPA_PLATFORM=offscreen: this FG build inits Qt before printing --version
    V="$(docker run --rm -e QT_QPA_PLATFORM=offscreen "$IMAGE" fgfs --version 2>/dev/null | grep -i '^FlightGear version')"
    [ -n "$V" ] && ok "fgfs --version: $V" || bad "fgfs --version"
    docker run --rm "$IMAGE" test -f /usr/share/games/flightgear/Protocol/fg_protocol.xml \
        && ok "fg_protocol.xml baked" || bad "fg_protocol.xml baked"
    docker run --rm "$IMAGE" test -f /usr/share/games/flightgear/Nasal/addobj.nas \
        && ok "addobj.nas baked" || bad "addobj.nas baked"
fi

# ------------------------------------------------------- 7. live end-to-end --
if [ "$DO_LIVE" = 1 ]; then
    step "live headless external-fdm (boot + UDP pose + telnet assert)"
    NAME=fgfs_val
    FEED_LAT=37.700000; FEED_LON=-122.400000; FEED_ALT=60
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    ID=val FG_HEADLESS=1 FG_MODE=external-fdm FG_NET=host \
        FG_HOME_LAT=37.613544 FG_HOME_LON=-122.357172 FG_HOME_ALT=5 \
        bash "$BASE/run.sh" >/tmp/fgbase_live.log 2>&1 &
    RUNNER_PID=$!

    echo "  waiting for telnet 15777 (first run builds the NavCache — can take minutes)..."
    UP=0
    for i in $(seq 1 120); do
        if python3 "$MYDIR/fg_prop.py" get /sim/time/elapsed-sec >/dev/null 2>&1; then UP=1; break; fi
        kill -0 "$RUNNER_PID" 2>/dev/null || break
        sleep 5
    done
    if [ "$UP" = 1 ]; then
        ok "renderer up (props telnet answering)"
        python3 "$MYDIR/fg_prop.py" get /addobj/count >/dev/null 2>&1 \
            && ok "addobj.nas hook live (/addobj/count)" || bad "addobj.nas hook"
        python3 "$MYDIR/feed_fdm.py" --lat "$FEED_LAT" --lon "$FEED_LON" \
            --alt-m "$FEED_ALT" --duration 40 --hz 20 >/dev/null 2>&1 &
        FEED_PID=$!
        MOVED=0
        for i in $(seq 1 30); do
            LAT="$(python3 "$MYDIR/fg_prop.py" get /position/latitude-deg 2>/dev/null || true)"
            if [ -n "$LAT" ] && awk "BEGIN{exit !( ($LAT-$FEED_LAT)^2 < 1e-6 )}"; then MOVED=1; break; fi
            sleep 1
        done
        if [ "$MOVED" = 1 ]; then
            ok "generic-protocol pose accepted (lat -> $FEED_LAT)"
            LON="$(python3 "$MYDIR/fg_prop.py" get /position/longitude-deg 2>/dev/null || true)"
            awk "BEGIN{exit !( ($LON-($FEED_LON))^2 < 1e-6 )}" \
                && ok "longitude tracks too ($LON)" || bad "longitude ($LON)"
        else
            bad "pose feed not reflected in /position (last lat: ${LAT:-none})"
        fi
        kill "$FEED_PID" 2>/dev/null
    else
        bad "renderer never answered telnet — see /tmp/fgbase_live.log"
    fi
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    wait "$RUNNER_PID" 2>/dev/null
fi

echo
echo "==================== $PASS passed, $FAIL failed ===================="
[ "$FAIL" = 0 ]
